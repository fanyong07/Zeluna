import 'dart:async';

import 'package:anime/src/accounts/local_account_repository.dart';
import 'package:anime/src/catalog/catalog_controller.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/domain/subject_content_type.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

CatalogController _controller(
  _MemoryCatalogStorage storage, {
  CatalogSnapshotPublisher? publish,
  CatalogSearchLoader? search,
  CatalogHomeLoader? loadHome,
  CatalogDetailLoader? loadDetail,
}) => CatalogController(
  storage: storage,
  publishSnapshot: publish ?? (_) {},
  search: search ?? (_, _) async => const [],
  loadHome: loadHome ?? (_, _) async => const [],
  loadDetail: loadDetail ?? (_, _) async => _detailBundle,
  enrichDetail: (bundle, _) async => bundle,
  prefetchPlayback: (_, _) {},
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
