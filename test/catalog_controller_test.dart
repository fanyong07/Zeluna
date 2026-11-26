import 'dart:async';

import 'package:anime/src/accounts/local_account_repository.dart';
import 'package:anime/src/catalog/catalog_controller.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/domain/subject_content_type.dart';
import 'package:anime/src/recommendations/recommendations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('many concurrent details keep a bounded immutable cache', () async {
    final sizes = <int>[];
    final controller = _controller(
      _MemoryCatalogStorage(),
      publish: (snapshot) => sizes.add(snapshot.selectedSubjects.length),
      loadDetail: (subject, _) async => _detailForSubject(subject),
    );
    addTearDown(controller.dispose);
    await controller.loadForAccount(
      accountId: 'one',
      contextVersion: 1,
      services: const ExternalServiceSettings(),
      fallbackHomeFeed: _feed,
    );
    final count = CatalogController.detailCacheLimit * 4;
    final details = await Future.wait([
      for (var id = 1; id <= count; id++)
        controller.detail(_numberedSubject(id)),
    ]);
    expect(details, hasLength(count));
    expect(sizes, hasLength(count));
    expect(
      sizes.every((size) => size <= CatalogController.detailCacheLimit),
      isTrue,
    );
    expect(
      controller.snapshot.selectedSubjects,
      hasLength(CatalogController.detailCacheLimit),
    );
    expect(
      () => controller.snapshot.selectedSubjects.clear(),
      throwsUnsupportedError,
    );
  });

  test(
    'cache hits keep hot details without publishing and evictions reload',
    () async {
      final requests = <int, int>{};
      var publications = 0;
      final controller = _controller(
        _MemoryCatalogStorage(),
        publish: (_) => publications++,
        loadDetail: (subject, _) async {
          requests.update(subject.id, (count) => count + 1, ifAbsent: () => 1);
          return _detailForSubject(subject);
        },
      );
      addTearDown(controller.dispose);
      await controller.loadForAccount(
        accountId: 'one',
        contextVersion: 1,
        services: const ExternalServiceSettings(),
        fallbackHomeFeed: _feed,
      );
      for (var id = 1; id <= CatalogController.detailCacheLimit; id++) {
        await controller.detail(_numberedSubject(id));
      }
      final before = controller.snapshot;
      final publishedBefore = publications;
      final hot = await controller.detail(_numberedSubject(1));
      for (var hit = 0; hit < 100; hit++) {
        expect(
          identical(await controller.detail(_numberedSubject(1)), hot),
          isTrue,
        );
      }
      expect(identical(controller.snapshot, before), isTrue);
      expect(publications, publishedBefore);
      await controller.detail(
        _numberedSubject(CatalogController.detailCacheLimit + 1),
      );
      expect(
        controller.snapshot.selectedSubjects.values.map(
          (bundle) => bundle.subject.id,
        ),
        contains(1),
      );
      expect(
        controller.snapshot.selectedSubjects.values.map(
          (bundle) => bundle.subject.id,
        ),
        isNot(contains(2)),
      );
      // Published snapshots stay immutable, even after internal recency changes.
      expect(
        before.selectedSubjects.values.map((bundle) => bundle.subject.id),
        contains(2),
      );
      await controller.detail(_numberedSubject(2));
      expect(requests[1], 1);
      expect(requests[2], 2);
      expect(
        controller.snapshot.selectedSubjects,
        hasLength(CatalogController.detailCacheLimit),
      );
    },
  );

  for (final reload in [false, true]) {
    test(
      'late enrichment stays revoked after eviction (reload: $reload)',
      () async {
        final oldExtra = Completer<AnimeDetailBundle>();
        final newExtra = Completer<AnimeDetailBundle>();
        var enrichments = 0;
        var publications = 0;
        final controller = _controller(
          _MemoryCatalogStorage(),
          publish: (_) => publications++,
          // Deliberately reuse the same object: identity alone must not let the
          // old enrichment replace a fresh load after eviction.
          loadDetail: (subject, _) async =>
              subject.id == 1 ? _detailBundle : _detailForSubject(subject),
          enrichDetail: (bundle, _) {
            if (bundle.subject.id != 1) return Future.value(bundle);
            return ++enrichments == 1 ? oldExtra.future : newExtra.future;
          },
        );
        addTearDown(() {
          if (!oldExtra.isCompleted) oldExtra.complete(_detailBundle);
          if (!newExtra.isCompleted) newExtra.complete(_detailBundle);
          controller.dispose();
        });
        await controller.loadForAccount(
          accountId: 'one',
          contextVersion: 1,
          services: const ExternalServiceSettings(),
          fallbackHomeFeed: _feed,
        );
        for (var id = 1; id <= CatalogController.detailCacheLimit + 1; id++) {
          await controller.detail(_numberedSubject(id));
        }
        expect(
          controller.snapshot.selectedSubjects.values.map(
            (bundle) => bundle.subject.id,
          ),
          isNot(contains(1)),
        );
        if (reload) await controller.detail(_numberedSubject(1));
        final before = publications;
        oldExtra.complete(
          _detailForSubject(_subject.copyWith(summary: 'stale extras')),
        );
        await _flushAsync();
        expect(publications, before);
        expect(
          controller.snapshot.selectedSubjects,
          hasLength(CatalogController.detailCacheLimit),
        );
        if (reload) {
          expect(
            controller.snapshot.selectedSubjects.values
                .where((bundle) => bundle.subject.id == 1)
                .single,
            same(_detailBundle),
          );
          final fresh = _detailForSubject(
            _subject.copyWith(summary: 'fresh extras'),
          );
          newExtra.complete(fresh);
          await _flushAsync();
          expect(
            controller.snapshot.selectedSubjects.values
                .where((bundle) => bundle.subject.id == 1)
                .single,
            same(fresh),
          );
          expect(publications, before + 1);
        } else {
          expect(
            controller.snapshot.selectedSubjects.values.map(
              (bundle) => bundle.subject.id,
            ),
            isNot(contains(1)),
          );
        }
      },
    );
  }

  test('optional enrichment does not promote an unread cold detail', () async {
    final extra = Completer<AnimeDetailBundle>();
    final controller = _controller(
      _MemoryCatalogStorage(),
      loadDetail: (subject, _) async => _detailForSubject(subject),
      enrichDetail: (bundle, _) =>
          bundle.subject.id == 1 ? extra.future : Future.value(bundle),
    );
    addTearDown(() {
      if (!extra.isCompleted) extra.complete(_detailBundle);
      controller.dispose();
    });
    await controller.loadForAccount(
      accountId: 'one',
      contextVersion: 1,
      services: const ExternalServiceSettings(),
      fallbackHomeFeed: _feed,
    );
    for (var id = 1; id <= CatalogController.detailCacheLimit; id++) {
      await controller.detail(_numberedSubject(id));
    }
    extra.complete(_detailForSubject(_subject.copyWith(summary: 'rich')));
    await _flushAsync();
    await controller.detail(
      _numberedSubject(CatalogController.detailCacheLimit + 1),
    );
    expect(
      controller.snapshot.selectedSubjects.values.map(
        (bundle) => bundle.subject.id,
      ),
      isNot(contains(1)),
    );
  });

  test(
    'account switch resets LRU and preserves the new scope single flight',
    () async {
      final old = Completer<AnimeDetailBundle>();
      final current = Completer<AnimeDetailBundle>();
      var requests = 0;
      final controller = _controller(
        _MemoryCatalogStorage(),
        loadDetail: (subject, _) {
          if (subject.id != 1) return Future.value(_detailForSubject(subject));
          return ++requests == 1 ? old.future : current.future;
        },
      );
      addTearDown(controller.dispose);
      await controller.loadForAccount(
        accountId: 'old',
        contextVersion: 1,
        services: const ExternalServiceSettings(),
        fallbackHomeFeed: _feed,
      );
      for (var id = 2; id <= CatalogController.detailCacheLimit + 1; id++) {
        await controller.detail(_numberedSubject(id));
      }
      final obsolete = controller.detail(_subject);
      final rejected = expectLater(obsolete, throwsA(isA<AccountException>()));
      await controller.loadForAccount(
        accountId: 'new',
        contextVersion: 2,
        services: const ExternalServiceSettings(),
        fallbackHomeFeed: _feed,
      );
      final first = controller.detail(_subject);
      old.complete(_detailBundle);
      await rejected;
      final second = controller.detail(_subject);
      expect(identical(first, second), isTrue);
      current.complete(_detailBundle);
      await Future.wait([first, second]);
      for (var id = 2; id <= CatalogController.detailCacheLimit; id++) {
        await controller.detail(_numberedSubject(id));
      }
      expect(requests, 2);
      expect(
        controller.snapshot.selectedSubjects,
        hasLength(CatalogController.detailCacheLimit),
      );
      expect(
        controller.snapshot.selectedSubjects.values
            .map((bundle) => bundle.subject.id)
            .toSet(),
        {for (var id = 1; id <= CatalogController.detailCacheLimit; id++) id},
      );
    },
  );

  test(
    'clearing details revokes in-flight entries instead of resurrecting cache',
    () async {
      final pending = Completer<AnimeDetailBundle>();
      final controller = _controller(
        _MemoryCatalogStorage(),
        loadDetail: (_, _) => pending.future,
      );
      addTearDown(controller.dispose);
      await controller.loadForAccount(
        accountId: 'one',
        contextVersion: 1,
        services: const ExternalServiceSettings(),
        fallbackHomeFeed: _feed,
      );
      final request = controller.detail(_subject);
      controller.clearDetailCache();
      final assertion = expectLater(request, throwsA(isA<AccountException>()));
      pending.complete(_detailBundle);
      await assertion;
      expect(controller.snapshot.selectedSubjects, isEmpty);
    },
  );

  test('late optional metadata cannot leak across account scopes', () async {
    final extra = Completer<AnimeDetailBundle>();
    final published = <CatalogSnapshot>[];
    final controller = _controller(
      _MemoryCatalogStorage(),
      publish: published.add,
      enrichDetail: (_, _) => extra.future,
    );
    addTearDown(controller.dispose);
    await controller.loadForAccount(
      accountId: 'a',
      contextVersion: 1,
      services: const ExternalServiceSettings(),
      fallbackHomeFeed: _feed,
    );
    final before = controller.snapshot.homeCandidates;
    await controller.detail(_subject);
    expect(identical(controller.snapshot.homeCandidates, before), isTrue);
    await controller.loadForAccount(
      accountId: 'b',
      contextVersion: 2,
      services: const ExternalServiceSettings(),
      fallbackHomeFeed: _otherFeed,
    );
    extra.complete(_detailBundle);
    await _flushAsync();
    expect(controller.snapshot.selectedSubjects, isEmpty);
    expect(published, hasLength(1));
  });

  test('ready detail and playback do not wait for optional metadata', () async {
    final enrichment = Completer<AnimeDetailBundle>();
    final prefetched = <AnimeSubject>[];
    final controller = _controller(
      _MemoryCatalogStorage(),
      enrichDetail: (_, _) => enrichment.future,
      prefetchPlayback: (subject, _) => prefetched.add(subject),
    );
    addTearDown(() {
      if (!enrichment.isCompleted) enrichment.complete(_detailBundle);
      controller.dispose();
    });
    await controller.loadForAccount(
      accountId: 'one',
      contextVersion: 1,
      services: const ExternalServiceSettings(),
      fallbackHomeFeed: _feed,
    );
    var ready = false;
    final detail = controller.detail(_subject).then((value) {
      ready = true;
      return value;
    });
    await Future<void>.delayed(Duration.zero);
    expect(
      ready,
      isTrue,
      reason: 'blocked Bangumi extras must not block episodes',
    );
    expect(prefetched, hasLength(1));
    expect((await detail).episodes, isNotEmpty);
    enrichment.complete(_detailBundle);
  });

  test('simultaneous detail readers share the same network request', () async {
    final base = Completer<AnimeDetailBundle>();
    var requests = 0;
    final controller = _controller(
      _MemoryCatalogStorage(),
      loadDetail: (_, _) {
        requests++;
        return base.future;
      },
    );
    addTearDown(controller.dispose);
    await controller.loadForAccount(
      accountId: 'one',
      contextVersion: 1,
      services: const ExternalServiceSettings(),
      fallbackHomeFeed: _feed,
    );
    final first = controller.detail(_subject);
    final second = controller.detail(_subject);
    base.complete(_detailBundle);
    await Future.wait([first, second]);
    expect(requests, 1);
  });

  test(
    'schedule never invents weekdays from historical catalogue dates',
    () async {
      final controller = _controller(
        _MemoryCatalogStorage(),
        loadHome: (_, _) async => [_subject],
      );
      addTearDown(controller.dispose);
      await controller.loadForAccount(
        accountId: 'test',
        contextVersion: 1,
        services: const ExternalServiceSettings(),
        fallbackHomeFeed: _feed,
      );
      final schedule = await controller.weeklySchedule();
      expect(schedule.values.expand((items) => items), isEmpty);
    },
  );

  test(
    'schedule uses the calendar loader rather than home recommendations',
    () async {
      final controller = _controller(
        _MemoryCatalogStorage(),
        loadHome: (_, _) async => throw StateError('must not load home'),
        loadSchedule: () async => {
          2: [_subject],
        },
      );
      addTearDown(controller.dispose);
      await controller.loadForAccount(
        accountId: 'one',
        contextVersion: 1,
        services: const ExternalServiceSettings(),
        fallbackHomeFeed: _feed,
      );
      expect((await controller.weeklySchedule())[2]!.single.id, _subject.id);
    },
  );

  test('query response is discarded after an account switch', () async {
    final pending = Completer<CatalogPageResult>();
    final controller = _controller(
      _MemoryCatalogStorage(),
      loadQuery: (_, _, _) => pending.future,
    );
    addTearDown(controller.dispose);
    await controller.loadForAccount(
      accountId: 'one',
      contextVersion: 1,
      services: const ExternalServiceSettings(),
      fallbackHomeFeed: _feed,
    );
    final response = controller.queryCatalog(
      const CatalogQuery(contentType: SubjectContentType.anime, year: 2026),
    );
    await controller.loadForAccount(
      accountId: 'two',
      contextVersion: 2,
      services: const ExternalServiceSettings(),
      fallbackHomeFeed: _feed,
    );
    final assertion = expectLater(response, throwsA(isA<AccountException>()));
    pending.complete(CatalogPageResult(subjects: [_subject]));
    await assertion;
  });

  test(
    'late detail from an old account cannot publish into the new scope',
    () async {
      final storage = _MemoryCatalogStorage();
      final detail = Completer<AnimeDetailBundle>();
      final published = <CatalogSnapshot>[];
      final controller = _controller(
        storage,
        publish: published.add,
        loadDetail: (_, _) => detail.future,
      );
      addTearDown(controller.dispose);

      await controller.loadForAccount(
        accountId: 'account-a',
        contextVersion: 1,
        services: const ExternalServiceSettings(),
        fallbackHomeFeed: _feed,
      );
      final oldDetail = controller.detail(_subject);
      await _flushAsync();
      await controller.loadForAccount(
        accountId: 'account-b',
        contextVersion: 2,
        services: const ExternalServiceSettings(),
        fallbackHomeFeed: _otherFeed,
      );
      detail.complete(_detailBundle);

      await expectLater(oldDetail, throwsA(isA<AccountException>()));
      expect(controller.snapshot.homeFeed.hero.id, _otherSubject.id);
      expect(controller.snapshot.selectedSubjects, isEmpty);
      expect(published, isEmpty);
    },
  );

  test(
    'late home refresh neither writes nor publishes after account switch',
    () async {
      final storage = _MemoryCatalogStorage();
      final pending = {
        for (final type in SubjectContentType.values)
          type: Completer<List<AnimeSubject>>(),
      };
      final published = <CatalogSnapshot>[];
      final controller = _controller(
        storage,
        publish: published.add,
        loadHome: (type, _) => pending[type]!.future,
      );
      addTearDown(() {
        for (final completer in pending.values) {
          if (!completer.isCompleted) completer.complete(const []);
        }
        controller.dispose();
      });

      await controller.loadForAccount(
        accountId: 'account-a',
        contextVersion: 1,
        services: const ExternalServiceSettings(),
        fallbackHomeFeed: _feed,
      );
      final refresh = controller.refreshHome();
      await _flushAsync();
      await controller.loadForAccount(
        accountId: 'account-b',
        contextVersion: 2,
        services: const ExternalServiceSettings(),
        fallbackHomeFeed: _otherFeed,
      );
      pending[SubjectContentType.anime]!.complete(const [_subject]);
      pending[SubjectContentType.series]!.complete(const []);
      pending[SubjectContentType.movie]!.complete(const []);
      await refresh;

      expect(
        storage.values,
        isNot(contains(CatalogController.homeFeedCacheKey)),
      );
      expect(controller.snapshot.homeFeed.hero.id, _otherSubject.id);
      expect(published, isEmpty);
    },
  );

  test(
    'backend endpoint changes invalidate catalog caches and loaders',
    () async {
      final storage = _MemoryCatalogStorage();
      final seenEndpoints = <String>[];
      final controller = _controller(
        storage,
        search: (_, services) async {
          seenEndpoints.add(services.playbackBackendEndpoint);
          return const [];
        },
      );
      addTearDown(controller.dispose);
      for (final key in const [
        CatalogController.homeFeedCacheKey,
        CatalogController.animeMetadataCacheKey,
        CatalogController.seriesMetadataCacheKey,
        CatalogController.movieMetadataCacheKey,
      ]) {
        storage.values[key] = {'old': true};
      }

      const initial = ExternalServiceSettings();
      await controller.loadForAccount(
        accountId: 'account-a',
        contextVersion: 1,
        services: initial,
        fallbackHomeFeed: _feed,
      );
      final changed = initial.copyWith(
        playbackBackendEndpoint: 'https://catalog-next.example',
        playbackBackendSelfHosted: true,
      );
      await controller.applyServices(changed, contextVersion: 1);
      await controller.search('test');

      expect(
        storage.deletedKeys.toSet(),
        containsAll({
          CatalogController.homeFeedCacheKey,
          CatalogController.animeMetadataCacheKey,
          CatalogController.seriesMetadataCacheKey,
          CatalogController.movieMetadataCacheKey,
        }),
      );
      expect(seenEndpoints.single, 'https://catalog-next.example');
    },
  );

  test(
    'settings invalidation waits for an older cache write before deleting',
    () async {
      final storage = _MemoryCatalogStorage();
      final controller = _controller(
        storage,
        loadHome: (type, _) async =>
            type == SubjectContentType.anime ? const [_subject] : const [],
      );
      addTearDown(() {
        storage.releaseWrite();
        controller.dispose();
      });
      const initial = ExternalServiceSettings();
      await controller.loadForAccount(
        accountId: 'account-a',
        contextVersion: 1,
        services: initial,
        fallbackHomeFeed: _feed,
      );
      storage.blockNextWrite();
      final refresh = controller.refreshHome();
      await _waitUntil(() => storage.blockedKey != null);
      final changed = initial.copyWith(
        playbackBackendEndpoint: 'https://catalog-next.example',
        playbackBackendSelfHosted: true,
      );
      final invalidate = controller.applyServices(changed, contextVersion: 1);
      await _flushAsync();
      storage.releaseWrite();
      await Future.wait([refresh, invalidate]);

      expect(
        storage.values,
        isNot(contains(CatalogController.homeFeedCacheKey)),
      );
    },
  );

  test(
    'ranking evidence is shared while the composed home cache is account scoped',
    () async {
      final storage = _MemoryCatalogStorage();
      final controller = _controller(
        storage,
        loadCandidates: (type, _) async => type == SubjectContentType.anime
            ? [
                CatalogCandidate(
                  subject: _subject,
                  evidence: CatalogRankingEvidence(
                    batchId: 'bangumi:anime:test',
                    rankedAt: DateTime.utc(2026, 8, 2, 12),
                    globalScore: 0.8,
                    lists: const [
                      CatalogRankingListEntry(
                        provider: 'bangumi',
                        kind: 'heat',
                        rank: 1,
                      ),
                    ],
                  ),
                ),
              ]
            : const [],
      );
      addTearDown(controller.dispose);

      await controller.loadForAccount(
        accountId: 'account-a',
        contextVersion: 1,
        services: const ExternalServiceSettings(),
        fallbackHomeFeed: _feed,
      );
      await controller.refreshHome();

      expect(
        storage.values,
        contains('account.account-a.${CatalogController.homeFeedCacheKey}'),
      );
      expect(
        storage.values,
        isNot(contains(CatalogController.homeFeedCacheKey)),
      );
      final metadata = storage.values[CatalogController.animeMetadataCacheKey];
      expect(metadata, isA<Map>());
      expect(
        ((metadata as Map)['rankings'] as List).single['globalScore'],
        0.8,
      );

      await controller.loadForAccount(
        accountId: 'account-b',
        contextVersion: 2,
        services: const ExternalServiceSettings(),
        fallbackHomeFeed: _otherFeed,
      );
      expect(
        controller
            .cachedCandidates(SubjectContentType.anime)
            .first
            .evidence
            .batchId,
        'bangumi:anime:test',
      );
    },
  );

  test(
    'one empty or failed type does not block the other home groups',
    () async {
      final storage = _MemoryCatalogStorage();
      final published = <CatalogSnapshot>[];
      final controller = _controller(
        storage,
        publish: published.add,
        loadCandidates: (type, _) async => switch (type) {
          SubjectContentType.anime => const [],
          SubjectContentType.series => throw StateError('series unavailable'),
          SubjectContentType.movie => [
            CatalogCandidate(
              subject: _movieSubject,
              evidence: const CatalogRankingEvidence(globalScore: 0.9),
            ),
          ],
        },
      );
      addTearDown(controller.dispose);

      await controller.loadForAccount(
        accountId: null,
        contextVersion: 1,
        services: const ExternalServiceSettings(),
        fallbackHomeFeed: _feed,
      );
      await controller.refreshHome();

      expect(published, hasLength(1));
      expect(
        controller.snapshot.homeFeed.movieHighlights,
        contains(_movieSubject),
      );
      expect(
        controller
            .cachedCandidates(SubjectContentType.movie)
            .single
            .evidence
            .globalScore,
        0.9,
      );
    },
  );

  test('a complete 120-item series or movie cache remains fresh', () async {
    final storage = _MemoryCatalogStorage();
    final movies = [
      for (var index = 0; index < 120; index++)
        CatalogCandidate(
          subject: AnimeSubject(
            id: 10000 + index,
            title: 'Movie $index',
            originalTitle: 'Movie $index',
            summary: '',
            coverUrl: null,
            bannerUrl: null,
            date: '2026-01-01',
            platform: 'Movie',
            language: 'en',
            region: 'US',
            status: 'released',
            categories: const [],
            tags: const [],
            totalEpisodes: 1,
            source: 'tmdb:movie:${10000 + index}',
          ),
          contentType: SubjectContentType.movie,
        ),
    ];
    final writer = _controller(
      storage,
      loadCandidates: (type, _) async =>
          type == SubjectContentType.movie ? movies : const [],
    );
    await writer.loadForAccount(
      accountId: 'account-a',
      contextVersion: 1,
      services: const ExternalServiceSettings(),
      fallbackHomeFeed: _feed,
    );
    await writer.refreshHome();
    writer.dispose();

    var refreshCalls = 0;
    final reader = _controller(
      storage,
      loadCandidates: (type, _) async {
        if (type == SubjectContentType.movie) refreshCalls++;
        return const [];
      },
    );
    addTearDown(reader.dispose);
    await reader.loadForAccount(
      accountId: 'account-b',
      contextVersion: 2,
      services: const ExternalServiceSettings(),
      fallbackHomeFeed: _otherFeed,
    );

    expect(await reader.movieSubjects(), hasLength(120));
    await _flushAsync();
    expect(refreshCalls, 0);
  });

  test('Bangumi calendar evidence drives the new-anime ordering', () async {
    final storage = _MemoryCatalogStorage();
    final calendar = CatalogCandidate(
      subject: _subject,
      evidence: const CatalogRankingEvidence(
        globalScore: 0.1,
        lists: [
          CatalogRankingListEntry(
            provider: 'bangumi',
            kind: 'calendar',
            rank: 1,
          ),
        ],
      ),
    );
    final popular = CatalogCandidate(
      subject: _otherSubject,
      evidence: const CatalogRankingEvidence(globalScore: 1),
    );
    final controller = _controller(
      storage,
      loadCandidates: (type, _) async =>
          type == SubjectContentType.anime ? [popular, calendar] : const [],
    );
    addTearDown(controller.dispose);
    await controller.loadForAccount(
      accountId: null,
      contextVersion: 1,
      services: const ExternalServiceSettings(),
      fallbackHomeFeed: _feed,
    );
    await controller.refreshHome();

    expect(controller.snapshot.homeFeed.recent.first.id, _subject.id);
  });

  test('successful category refresh replaces stale candidates', () async {
    final storage = _MemoryCatalogStorage();
    final writer = _controller(
      storage,
      loadCandidates: (type, _) async => type == SubjectContentType.anime
          ? [CatalogCandidate(subject: _subject)]
          : const [],
    );
    await writer.loadForAccount(
      accountId: 'account-a',
      contextVersion: 1,
      services: const ExternalServiceSettings(),
      fallbackHomeFeed: _feed,
    );
    await writer.refreshHome();
    writer.dispose();

    final reader = _controller(
      storage,
      loadCandidates: (type, _) async => type == SubjectContentType.anime
          ? [CatalogCandidate(subject: _otherSubject)]
          : const [],
    );
    addTearDown(reader.dispose);
    await reader.loadForAccount(
      accountId: 'account-b',
      contextVersion: 2,
      services: const ExternalServiceSettings(),
      fallbackHomeFeed: _otherFeed,
    );
    await reader.invalidateMetadataCache('anime');

    final refreshed = await reader.discoverSubjects(waitForRefresh: true);
    expect(refreshed.map((item) => item.id), [_otherSubject.id]);
    expect(
      reader
          .cachedCandidates(SubjectContentType.anime)
          .map((item) => item.subject.id),
      [_otherSubject.id],
    );
  });

  test(
    'catalog dedup keeps direct identity and preferred Chinese metadata',
    () {
      const direct = AnimeSubject(
        id: 1,
        title: 'Example Show',
        originalTitle: 'Example Show',
        summary: 'No metadata.',
        coverUrl: null,
        bannerUrl: null,
        date: '2026-01-01',
        platform: 'Movie',
        language: '日语',
        region: '日本',
        status: '连载中',
        categories: [],
        tags: [],
        totalEpisodes: 1,
        source: 'archive:item',
      );
      const bangumi = AnimeSubject(
        id: 99,
        title: '示例动画',
        originalTitle: 'Example Show',
        summary: '这是一段完整的中文简介。',
        coverUrl: null,
        bannerUrl: null,
        date: '2026-01-01',
        platform: 'Movie',
        language: '日语',
        region: '日本',
        status: '连载中',
        categories: [],
        tags: [],
        totalEpisodes: 1,
        source: 'bangumi',
      );
      final merged = uniqueCatalogSubjects([
        direct,
        bangumi,
      ], preferChinese: true).single;

      expect(merged.source, 'archive:item');
      expect(merged.title, '示例动画');
      expect(merged.summary, '这是一段完整的中文简介。');
    },
  );
}

AnimeSubject _numberedSubject(int id) => AnimeSubject.fromJson({
  ..._subject.toJson(),
  'id': id,
  'title': 'Show $id',
  'stableKey': 'bangumi:$id',
});

AnimeDetailBundle _detailForSubject(AnimeSubject subject) => AnimeDetailBundle(
  subject: subject,
  episodes: const [_episode],
  characters: const [],
  staff: const [],
  recommendations: const [],
);

CatalogController _controller(
  _MemoryCatalogStorage storage, {
  CatalogSnapshotPublisher? publish,
  CatalogSearchLoader? search,
  CatalogHomeLoader? loadHome,
  CatalogCandidateLoader? loadCandidates,
  CatalogQueryLoader? loadQuery,
  CatalogScheduleLoader? loadSchedule,
  CatalogDetailLoader? loadDetail,
  CatalogDetailEnricher? enrichDetail,
  CatalogPlaybackPrefetcher? prefetchPlayback,
}) => CatalogController(
  storage: storage,
  publishSnapshot: publish ?? (_) {},
  search: search ?? (_, _) async => const [],
  loadHome: loadHome ?? (_, _) async => const [],
  loadCandidates: loadCandidates,
  loadQuery: loadQuery,
  loadSchedule: loadSchedule,
  loadDetail: loadDetail ?? (_, _) async => _detailBundle,
  enrichDetail: enrichDetail ?? (bundle, _) async => bundle,
  prefetchPlayback: prefetchPlayback ?? (_, _) {},
  fallbackSeries: const [],
  fallbackMovies: const [],
  now: () => DateTime.utc(2026, 8, 2, 12),
);

final class _MemoryCatalogStorage implements CatalogStorage {
  final Map<String, Object?> values = {};
  final List<String> writeKeys = [];
  final List<String> deletedKeys = [];
  Completer<void>? _nextGate;
  Completer<void>? _activeGate;
  String? blockedKey;

  @override
  Object? get(String key) => values[key];

  @override
  Future<void> put(String key, Object? value) async {
    writeKeys.add(key);
    final gate = _nextGate;
    if (gate != null) {
      _nextGate = null;
      _activeGate = gate;
      blockedKey = key;
      await gate.future;
      _activeGate = null;
      blockedKey = null;
    }
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    deletedKeys.add(key);
    values.remove(key);
  }

  void blockNextWrite() => _nextGate = Completer<void>();

  void releaseWrite() {
    final gate = _activeGate ?? _nextGate;
    if (gate != null && !gate.isCompleted) gate.complete();
    _nextGate = null;
  }
}

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('condition was not reached');
}

Future<void> _flushAsync() async {
  for (var attempt = 0; attempt < 10; attempt++) {
    await Future<void>.delayed(Duration.zero);
  }
}

const _subject = AnimeSubject(
  id: 1,
  title: 'Example Show',
  originalTitle: 'Example Show',
  summary: 'summary',
  coverUrl: null,
  bannerUrl: null,
  date: '2026-01-01',
  platform: 'TV',
  language: '日语',
  region: '日本',
  status: '连载中',
  categories: [],
  tags: [],
  totalEpisodes: 1,
);

const _otherSubject = AnimeSubject(
  id: 2,
  title: 'Other Show',
  originalTitle: 'Other Show',
  summary: 'summary',
  coverUrl: null,
  bannerUrl: null,
  date: '2026-01-02',
  platform: 'TV',
  language: '日语',
  region: '日本',
  status: '连载中',
  categories: [],
  tags: [],
  totalEpisodes: 1,
);

const _movieSubject = AnimeSubject(
  id: 3,
  title: 'Example Movie',
  originalTitle: 'Example Movie',
  summary: 'summary',
  coverUrl: null,
  bannerUrl: 'https://image.example/movie.jpg',
  date: '2026-08-01',
  platform: 'Movie',
  language: 'en',
  region: 'US',
  status: 'released',
  categories: [],
  tags: [],
  totalEpisodes: 1,
  source: 'tmdb:movie:3',
);

const _episode = AnimeEpisode(
  id: 101,
  subjectId: 1,
  number: 1,
  title: '第一集',
  airdate: '2026-01-01',
  duration: '24:00',
  description: '',
);

const _feed = AnimeHomeFeed(
  hero: _subject,
  recent: [_subject],
  recommended: [_subject],
  index: [_subject],
  categories: [],
  tags: [],
);

const _otherFeed = AnimeHomeFeed(
  hero: _otherSubject,
  recent: [_otherSubject],
  recommended: [_otherSubject],
  index: [_otherSubject],
  categories: [],
  tags: [],
);

const _detailBundle = AnimeDetailBundle(
  subject: _subject,
  episodes: [_episode],
  characters: [],
  staff: [],
  recommendations: [],
  watchLinks: [],
);
