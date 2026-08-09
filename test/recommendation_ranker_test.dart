import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/domain/subject_content_type.dart';
import 'package:anime/src/recommendations/recommendations.dart';
import 'package:flutter_test/flutter_test.dart';

AnimeSubject _subject(int id, SubjectContentType type, {String? category}) =>
    AnimeSubject(
      id: id,
      title: '${type.name} $id',
      originalTitle: '${type.name} original $id',
      summary: '',
      coverUrl: null,
      bannerUrl: null,
      date: '2026-01-01',
      platform: switch (type) {
        SubjectContentType.anime => 'TV',
        SubjectContentType.series => 'Series',
        SubjectContentType.movie => 'Movie',
      },
      language: 'ja',
      region: 'JP',
      status: '',
      categories: category == null ? const [] : [AnimeCategory(name: category)],
      tags: const [],
      totalEpisodes: 12,
      source: switch (type) {
        SubjectContentType.anime => 'bangumi',
        SubjectContentType.series => 'tmdb:tv:$id',
        SubjectContentType.movie => 'tmdb:movie:$id',
      },
    );

CatalogCandidate _candidate(
  int id,
  SubjectContentType type, {
  double score = 0.5,
  Set<String> features = const {'tag:neutral'},
  String? workKey,
  String? category,
}) => CatalogCandidate(
  subject: _subject(id, type, category: category),
  contentType: type,
  workKey: workKey ?? '${type.name}-$id',
  features: features,
  evidence: CatalogRankingEvidence(globalScore: score),
);

RecommendationEvent _event(
  RecommendationEventType type,
  String workKey,
  DateTime at, {
  SubjectContentType contentType = SubjectContentType.anime,
  Set<String> features = const {'tag:fantasy'},
}) => RecommendationEvent(
  type: type,
  workKey: workKey,
  occurredAt: at,
  contentType: contentType,
  features: features,
);

RecommendationSnapshot _snapshot({
  required DateTime now,
  List<RecommendationEvent> behaviors = const [],
  List<RecommendationServedEvent> served = const [],
  String? accountId = 'account-a',
}) => RecommendationSnapshot(
  accountId: accountId,
  contextVersion: 1,
  behaviors: behaviors,
  served: served,
  profile: RecommendationProfile.fromEvents(
    behaviors: behaviors,
    served: served,
    now: now,
  ),
  generatedAt: now,
);

List<CatalogCandidate> _catalog({int perType = 16}) => [
  for (final type in SubjectContentType.values)
    for (var i = 0; i < perType; i++)
      _candidate(type.index * 1000 + i, type, score: 1 - i / (perType * 2)),
];

void main() {
  test('cold start returns 8/8/8 with ten percent stable exploration', () {
    final now = DateTime(2026, 8, 9, 9);
    final result = rankCatalog(
      candidates: _catalog(),
      snapshot: _snapshot(now: now),
      now: now,
    );

    expect(result.mature, isFalse);
    expect(result.quotas, {
      SubjectContentType.anime: 8,
      SubjectContentType.series: 8,
      SubjectContentType.movie: 8,
    });
    expect(result.ordered, hasLength(24));
    expect(result.explorationCount, 2);
  });

  test('interleaving scans past a same-genre queue head', () {
    final ordered = interleaveRecommendationCandidates({
      SubjectContentType.anime: [
        _candidate(1, SubjectContentType.anime, category: '奇幻'),
        _candidate(2, SubjectContentType.anime, category: '奇幻'),
        _candidate(3, SubjectContentType.anime, category: '科幻'),
      ],
    }, seed: 'genre-test');

    expect(ordered.map((item) => item.subject.categories.single.name), [
      '奇幻',
      '科幻',
      '奇幻',
    ]);
  });

  test('cold, warming and mature stages use 90/0, 75/15 and 55/35 blends', () {
    final now = DateTime(2026, 8, 9);
    final candidate = _candidate(
      5000,
      SubjectContentType.anime,
      score: 0.8,
      features: const {'tag:fantasy'},
    );
    final cold = rankCatalog(
      candidates: [candidate],
      snapshot: _snapshot(now: now),
      now: now,
    ).ordered.single;
    final warmingEvents = [
      _event(RecommendationEventType.favorite, 'seed', now),
    ];
    final warming = rankCatalog(
      candidates: [candidate],
      snapshot: _snapshot(now: now, behaviors: warmingEvents),
      now: now,
    ).ordered.single;
    final matureEvents = [
      for (var i = 0; i < 3; i++)
        _event(RecommendationEventType.favorite, 'seed-$i', now),
    ];
    final mature = rankCatalog(
      candidates: [candidate],
      snapshot: _snapshot(now: now, behaviors: matureEvents),
      now: now,
    ).ordered.single;

    expect(
      cold.score,
      closeTo(cold.chartScore * 0.90 + cold.explorationScore * 0.10, 0.000001),
    );
    expect(
      warming.score,
      closeTo(
        warming.chartScore * 0.75 +
            warming.personalizationScore * 0.15 +
            warming.explorationScore * 0.10,
        0.000001,
      ),
    );
    expect(
      mature.score,
      closeTo(
        mature.chartScore * 0.55 +
            mature.personalizationScore * 0.35 +
            mature.explorationScore * 0.10,
        0.000001,
      ),
    );
  });

  test('mature quotas remain 4..12 and follow type preference', () {
    final now = DateTime(2026, 8, 9);
    final events = [
      for (var i = 0; i < 3; i++)
        _event(
          RecommendationEventType.following,
          'seed-$i',
          now,
          contentType: SubjectContentType.anime,
        ),
    ];
    final result = rankCatalog(
      candidates: _catalog(),
      snapshot: _snapshot(now: now, behaviors: events),
      now: now,
    );

    expect(result.mature, isTrue);
    expect(result.quotas[SubjectContentType.anime], 12);
    for (final quota in result.quotas.values) {
      expect(quota, inInclusiveRange(4, 12));
    }
    expect(result.quotas.values.reduce((a, b) => a + b), 24);
    expect(result.explorationCount, 2);
  });

  test('warming profiles also use flexible 4..12 type quotas', () {
    final now = DateTime(2026, 8, 9);
    final result = rankCatalog(
      candidates: _catalog(perType: 20),
      snapshot: _snapshot(
        now: now,
        behaviors: [
          _event(
            RecommendationEventType.favorite,
            'favorite-series',
            now,
            contentType: SubjectContentType.series,
          ),
        ],
      ),
      now: now,
    );

    expect(result.mature, isFalse);
    expect(result.quotas[SubjectContentType.series], 12);
    expect(result.quotas[SubjectContentType.anime], 6);
    expect(result.quotas[SubjectContentType.movie], 6);
  });

  test(
    'same account/date/nonce is deterministic regardless of time of day',
    () {
      final candidates = _catalog();
      final morning = DateTime(2026, 8, 9, 8);
      final evening = DateTime(2026, 8, 9, 22);
      List<String> run(DateTime now, int nonce) => rankCatalog(
        candidates: candidates,
        snapshot: _snapshot(now: now),
        now: now,
        nonce: nonce,
      ).ordered.map((item) => item.candidate.workKey).toList();

      expect(run(morning, 7), run(evening, 7));
      expect(run(morning, 7), isNot(run(morning, 8)));
    },
  );

  test('nonce and date each replace at least 25% of top 24 from 60 works', () {
    final candidates = <CatalogCandidate>[
      for (final type in SubjectContentType.values)
        for (var i = 0; i < 20; i++)
          _candidate(type.index * 1000 + i, type, score: 0.7),
    ];
    final day = DateTime(2026, 8, 9);
    Set<String> run(DateTime now, int nonce) => rankCatalog(
      candidates: candidates,
      snapshot: _snapshot(now: now),
      now: now,
      nonce: nonce,
    ).ordered.map((item) => item.candidate.workKey).toSet();
    final baseline = run(day, 0);
    final nonceChanged = run(day, 1);
    final dateChanged = run(day.add(const Duration(days: 1)), 0);

    expect(baseline.difference(nonceChanged).length, greaterThanOrEqualTo(6));
    expect(baseline.difference(dateChanged).length, greaterThanOrEqualTo(6));
  });

  test('different account profiles produce isolated top recommendations', () {
    final now = DateTime(2026, 8, 9);
    final candidates = <CatalogCandidate>[
      for (var index = 0; index < 24; index++)
        _candidate(
          index,
          SubjectContentType.anime,
          score: 0.5,
          features: const {'tag:fantasy'},
        ),
      for (var index = 24; index < 48; index++)
        _candidate(
          index,
          SubjectContentType.anime,
          score: 0.5,
          features: const {'tag:romance'},
        ),
    ];
    Set<String> run(String accountId, String feature) => rankCatalog(
      candidates: candidates,
      snapshot: _snapshot(
        now: now,
        accountId: accountId,
        behaviors: [
          _event(
            RecommendationEventType.favorite,
            'profile-$accountId',
            now,
            features: {'tag:$feature'},
          ),
        ],
      ),
      now: now,
    ).ordered.map((item) => item.candidate.workKey).toSet();

    final fantasy = run('account-fantasy', 'fantasy');
    final romance = run('account-romance', 'romance');
    expect(fantasy, hasLength(12));
    expect(romance, hasLength(12));
    expect(fantasy.intersection(romance), isEmpty);
  });

  test('warm local ranking of 360 candidates completes within 100ms', () {
    final now = DateTime(2026, 8, 9);
    final candidates = _catalog(perType: 120);
    final snapshot = _snapshot(
      now: now,
      behaviors: [
        for (var index = 0; index < 3; index++)
          _event(RecommendationEventType.favorite, 'profile-$index', now),
      ],
    );
    rankCatalog(candidates: candidates, snapshot: snapshot, now: now);

    final stopwatch = Stopwatch()..start();
    final result = rankCatalog(
      candidates: candidates,
      snapshot: snapshot,
      now: now,
      nonce: 1,
    );
    stopwatch.stop();

    expect(result.ordered, hasLength(24));
    expect(stopwatch.elapsedMilliseconds, lessThan(100));
  });

  test('full-list APIs re-rank without homepage truncation', () {
    final now = DateTime(2026, 8, 9);
    final candidates = [
      for (var i = 0; i < 20; i++)
        _candidate(i, SubjectContentType.series, score: 0.5),
    ];
    final snapshot = _snapshot(now: now);

    expect(
      rankAllCandidates(candidates: candidates, snapshot: snapshot, now: now),
      hasLength(20),
    );
    expect(
      rankCatalogForType(
        type: SubjectContentType.series,
        candidates: candidates,
        snapshot: snapshot,
        now: now,
      ),
      hasLength(20),
    );
  });

  test(
    'full-list recommendations downrank known works without hiding them',
    () {
      final now = DateTime(2026, 8, 9);
      final ranked = rankAllCandidates(
        candidates: [
          _candidate(
            1,
            SubjectContentType.series,
            workKey: 'known',
            score: 0.9,
          ),
          _candidate(
            2,
            SubjectContentType.series,
            workKey: 'fresh',
            score: 0.9,
          ),
        ],
        snapshot: _snapshot(
          now: now,
          behaviors: [
            _event(
              RecommendationEventType.favorite,
              'known',
              now,
              contentType: SubjectContentType.series,
            ),
          ],
        ),
        now: now,
      );

      expect(ranked, hasLength(2));
      expect(ranked.first.candidate.workKey, 'fresh');
      expect(ranked.last.candidate.workKey, 'known');
    },
  );

  test('not interested, known works and canonical duplicates are excluded', () {
    final now = DateTime(2026, 8, 9);
    final events = [
      _event(RecommendationEventType.favorite, 'known', now),
      _event(RecommendationEventType.notInterested, 'blocked', now),
    ];
    final result = rankCatalog(
      candidates: [
        _candidate(1, SubjectContentType.anime, workKey: 'known'),
        _candidate(2, SubjectContentType.anime, workKey: 'blocked'),
        _candidate(3, SubjectContentType.anime, workKey: 'duplicate'),
        _candidate(
          4,
          SubjectContentType.anime,
          workKey: 'duplicate',
          score: 0.9,
        ),
      ],
      snapshot: _snapshot(now: now, behaviors: events),
      now: now,
    );

    expect(result.ordered.single.candidate.workKey, 'duplicate');
    expect(result.ordered.single.chartScore, 0.9);
  });

  test('recently served candidates receive a repeat penalty', () {
    final now = DateTime(2026, 8, 9, 12);
    final served = [
      RecommendationServedEvent(
        workKey: 'repeated',
        servedAt: now.subtract(const Duration(days: 1, hours: 1)),
        contentType: SubjectContentType.anime,
        surface: 'home',
      ),
    ];
    final result = rankCatalog(
      candidates: [
        _candidate(
          1,
          SubjectContentType.anime,
          workKey: 'repeated',
          score: 0.9,
        ),
        _candidate(2, SubjectContentType.anime, workKey: 'fresh', score: 0.8),
      ],
      snapshot: _snapshot(now: now, served: served),
      now: now,
    );

    expect(result.ordered.first.candidate.workKey, 'fresh');
  });

  test('same-day served records do not reorder a normal reopen', () {
    final now = DateTime(2026, 8, 9, 12);
    final candidates = _catalog(perType: 12);
    final initial = rankCatalog(
      candidates: candidates,
      snapshot: _snapshot(now: now),
      now: now,
    ).ordered.map((item) => item.candidate.workKey).toList();
    final served = [
      for (final key in initial)
        RecommendationServedEvent(
          workKey: key,
          servedAt: now.subtract(const Duration(hours: 1)),
          contentType: SubjectContentType.anime,
          surface: 'home',
        ),
    ];
    final reopened = rankCatalog(
      candidates: candidates,
      snapshot: _snapshot(now: now, served: served),
      now: now,
    ).ordered.map((item) => item.candidate.workKey).toList();

    expect(reopened, initial);
  });
}
