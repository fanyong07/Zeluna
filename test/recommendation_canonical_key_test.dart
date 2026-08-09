import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/recommendations/recommendations.dart';
import 'package:flutter_test/flutter_test.dart';

AnimeSubject _subject({
  required int id,
  required String title,
  required String originalTitle,
  required String date,
  required String source,
  String platform = 'TV',
}) => AnimeSubject(
  id: id,
  title: title,
  originalTitle: originalTitle,
  summary: '',
  coverUrl: null,
  bannerUrl: null,
  date: date,
  platform: platform,
  language: 'ja',
  region: 'JP',
  status: '',
  categories: const <AnimeCategory>[AnimeCategory(name: '奇幻')],
  tags: const <AnimeTag>[AnimeTag(name: '冒险')],
  totalEpisodes: 12,
  source: source,
);

void main() {
  test('provider stable identity precedes title and year fallback', () {
    final bangumi = _subject(
      id: 1,
      title: '葬送的芙莉莲',
      originalTitle: 'Sousou no Frieren',
      date: '2023-09-29',
      source: 'bangumi',
    );
    final tmdb = _subject(
      id: 209867,
      title: 'Frieren: Beyond Journey’s End',
      originalTitle: 'SOUSOU-NO-FRIEREN',
      date: '2023-09-29',
      source: 'tmdb:tv:209867',
    );

    expect(canonicalWorkKey(bangumi), isNot(canonicalWorkKey(tmdb)));
  });

  test(
    'title, year and type conservatively unify records without stable IDs',
    () {
      final first = _subject(
        id: 1,
        title: '葬送的芙莉莲',
        originalTitle: 'Sousou no Frieren',
        date: '2023-09-29',
        source: '',
      );
      final second = _subject(
        id: 2,
        title: 'Frieren: Beyond Journey’s End',
        originalTitle: 'SOUSOU-NO-FRIEREN',
        date: '2023-09-29',
        source: '',
      );

      expect(canonicalWorkKey(first), canonicalWorkKey(second));
    },
  );

  test(
    'explicit external identity wins over provider and title differences',
    () {
      final first = _subject(
        id: 1,
        title: 'Title A',
        originalTitle: '',
        date: '2024',
        source: 'bangumi',
      );
      final second = _subject(
        id: 2,
        title: 'Completely Different',
        originalTitle: '',
        date: '2025',
        source: 'tmdb:tv:2',
      );

      expect(
        canonicalWorkKey(first, externalIds: const {'imdb': 'tt1234567'}),
        canonicalWorkKey(second, externalIds: const {'imdb_id': 'TT1234567'}),
      );
    },
  );

  test('release year and content type prevent unsafe title collisions', () {
    final series = _subject(
      id: 1,
      title: 'The Journey',
      originalTitle: '',
      date: '2024',
      source: 'tmdb:tv:1',
    );
    final remake = _subject(
      id: 2,
      title: 'The Journey',
      originalTitle: '',
      date: '2025',
      source: 'tmdb:tv:2',
    );
    final movie = _subject(
      id: 3,
      title: 'The Journey',
      originalTitle: '',
      date: '2024',
      source: 'tmdb:movie:3',
      platform: 'Movie',
    );

    expect(canonicalWorkKey(series), isNot(canonicalWorkKey(remake)));
    expect(canonicalWorkKey(series), isNot(canonicalWorkKey(movie)));
  });

  test('recommendation features include stable year and local metadata', () {
    final subject = _subject(
      id: 8,
      title: 'Feature Test',
      originalTitle: '',
      date: '2024-04-01',
      source: 'bangumi',
    );

    expect(
      recommendationFeaturesForSubject(subject),
      containsAll(<String>{
        'year:2024',
        'language:ja',
        'region:jp',
        'platform:tv',
      }),
    );
  });

  test('new ranking batches replace historical scores and list positions', () {
    final first = CatalogRankingEvidence.fromJson({
      'ranking': {
        'batchId': 'batch-1',
        'rankedAt': '2026-08-09T00:00:00Z',
        'globalScore': 0.95,
        'lists': [
          {'provider': 'bangumi', 'kind': 'rank', 'rank': 1},
        ],
      },
    });
    final second = CatalogRankingEvidence.fromJson({
      'batchId': 'batch-2',
      'rankedAt': '2026-08-10T00:00:00Z',
      'globalScore': 0.42,
      'lists': [
        {'provider': 'bangumi', 'kind': 'rank', 'rank': 48},
        {'provider': 'tmdb', 'kind': 'trending', 'rank': 3},
      ],
    });

    final merged = first.merge(second);
    expect(merged.batchId, 'batch-2');
    expect(merged.rankedAt, DateTime.utc(2026, 8, 10));
    expect(merged.chartScore, 0.42);
    expect(merged.lists, hasLength(2));
    expect(
      merged.lists.singleWhere((item) => item.provider == 'bangumi').rank,
      48,
    );
    expect(
      CatalogRankingEvidence.fromJson(merged.toJson()).toJson(),
      merged.toJson(),
    );

    final currentCandidate = CatalogCandidate(
      subject: _subject(
        id: 10,
        title: 'Current metadata',
        originalTitle: 'Same Work',
        date: '2026-01-01',
        source: 'bangumi',
      ),
      workKey: 'same-work',
      evidence: second,
    );
    final historicalCandidate = CatalogCandidate(
      subject: _subject(
        id: 10,
        title: 'Historical metadata',
        originalTitle: 'Same Work',
        date: '2026-01-01',
        source: 'bangumi',
      ),
      workKey: 'same-work',
      evidence: first,
    );
    final candidate = currentCandidate.merge(historicalCandidate);
    expect(candidate.subject.title, 'Current metadata');
    expect(candidate.evidence.chartScore, 0.42);
  });

  test('new provider batches replace only that provider evidence', () {
    CatalogRankingEvidence evidence({
      required String provider,
      required String batch,
      required DateTime at,
      required int rank,
      required double score,
    }) => CatalogRankingEvidence(
      batchId: batch,
      rankedAt: at,
      globalScore: score,
      lists: [
        CatalogRankingListEntry(provider: provider, kind: 'heat', rank: rank),
      ],
    );

    final bangumi = evidence(
      provider: 'bangumi',
      batch: 'bangumi-1',
      at: DateTime.utc(2026, 8, 8),
      rank: 8,
      score: 0.7,
    );
    final tmdb = evidence(
      provider: 'tmdb',
      batch: 'tmdb-1',
      at: DateTime.utc(2026, 8, 9),
      rank: 3,
      score: 0.8,
    );
    final newerBangumi = evidence(
      provider: 'bangumi',
      batch: 'bangumi-2',
      at: DateTime.utc(2026, 8, 10),
      rank: 21,
      score: 0.5,
    );

    final merged = bangumi.merge(tmdb).merge(newerBangumi);
    expect(merged.batchId, 'bangumi-2');
    expect(merged.chartScore, 0.5);
    expect(merged.lists, hasLength(2));
    expect(
      merged.lists.singleWhere((item) => item.provider == 'bangumi').rank,
      21,
    );
    expect(merged.lists.singleWhere((item) => item.provider == 'tmdb').rank, 3);
  });
}
