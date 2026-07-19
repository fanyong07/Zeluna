import 'dart:async';
import 'dart:io';

import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/data/bangumi_metadata_repository.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/rules/rule_importer.dart';
import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/rules/rule_playback_resolver.dart';
import 'package:anime/src/sources/source_catalog_models.dart';
import 'package:anime/src/sources/source_catalog_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('controller startup does not wait for remote home metadata', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'anime-controller-fast-start-',
    );
    Hive.init(tempDirectory.path);
    final settings = await Hive.openBox<dynamic>('anime.settings.v2');
    await settings.put('services', _bangumiOnlyServices.toJson());
    await settings.close();

    final repository = _ControlledBangumiMetadataRepository();
    final container = ProviderContainer(
      overrides: [
        bangumiMetadataRepositoryProvider.overrideWithValue(repository),
        sourceCatalogRepositoryProvider.overrideWithValue(
          const _EmptySourceCatalogRepository(),
        ),
      ],
    );
    addTearDown(() async {
      if (!repository.homeFeedCompleter.isCompleted) {
        repository.homeFeedCompleter.complete(_homeFeed);
      }
      if (!repository.discoveryCompleter.isCompleted) {
        repository.discoveryCompleter.complete(const [_homeSubject]);
      }
      container.dispose();
      await Hive.close();
      if (await tempDirectory.exists()) {
        await tempDirectory.delete(recursive: true);
      }
    });

    final initial = await container
        .read(animeControllerProvider.future)
        .timeout(const Duration(milliseconds: 500));

    expect(initial.homeFeed.hero.title, _homeSubject.title);
    await Future<void>.delayed(Duration.zero);
    expect(repository.homeFeedStarted, isTrue);
    repository.homeFeedCompleter.complete(_homeFeed);
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });

  test(
    'anime discovery is immediate and rejects series or movie items',
    () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'anime-controller-anime-filter-',
      );
      Hive.init(tempDirectory.path);
      final settings = await Hive.openBox<dynamic>('anime.settings.v2');
      await settings.put('services', _bangumiOnlyServices.toJson());
      await settings.close();

      final repository = _ControlledBangumiMetadataRepository(
        immediateHomeFeed: true,
      );
      final container = ProviderContainer(
        overrides: [
          bangumiMetadataRepositoryProvider.overrideWithValue(repository),
          sourceCatalogRepositoryProvider.overrideWithValue(
            const _EmptySourceCatalogRepository(),
          ),
        ],
      );
      addTearDown(() async {
        if (!repository.discoveryCompleter.isCompleted) {
          repository.discoveryCompleter.complete(const [_homeSubject]);
        }
        container.dispose();
        await Hive.close();
        if (await tempDirectory.exists()) {
          await tempDirectory.delete(recursive: true);
        }
      });

      await container.read(animeControllerProvider.future);
      final controller = container.read(animeControllerProvider.notifier);
      final initial = await controller.discoverSubjects().timeout(
        const Duration(milliseconds: 500),
      );

      expect(initial.map((item) => item.source), everyElement('bangumi'));
      expect(repository.discoveryStarted, isTrue);

      final refreshedFuture = controller.discoverSubjects(waitForRefresh: true);
      repository.discoveryCompleter.complete(const [
        _animeMovieSubject,
        _seriesSubject,
        _movieSubject,
      ]);
      final refreshed = await refreshedFuture;

      expect(refreshed.map((item) => item.source), contains('jikan'));
      expect(refreshed.map((item) => item.source), isNot(contains('tvmaze')));
      expect(refreshed.map((item) => item.source), isNot(contains('wikidata')));
    },
  );

  test('opening detail prefetches the first episode rule lookup', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'anime-controller-line-prefetch-',
    );
    Hive.init(tempDirectory.path);
    final settings = await Hive.openBox<dynamic>('anime.settings.v2');
    await settings.put('services', _offlineServices.toJson());
    await settings.close();

    final resolver = _BlockingRulePlaybackResolver();
    final container = ProviderContainer(
      overrides: [
        bangumiMetadataRepositoryProvider.overrideWithValue(
          _DetailBangumiMetadataRepository(),
        ),
        sourceCatalogRepositoryProvider.overrideWithValue(
          const _EmptySourceCatalogRepository(),
        ),
        rulePlaybackResolverProvider.overrideWithValue(resolver),
      ],
    );
    addTearDown(() async {
      if (!resolver.result.isCompleted) resolver.result.complete(const []);
      container.dispose();
      await Hive.close();
      if (await tempDirectory.exists()) {
        await tempDirectory.delete(recursive: true);
      }
    });

    await container.read(animeControllerProvider.future);
    final detail = await container
        .read(animeControllerProvider.notifier)
        .detail(_homeSubject)
        .timeout(const Duration(milliseconds: 500));

    expect(detail.episodes, hasLength(1));
    await resolver.called.future.timeout(const Duration(milliseconds: 500));
    expect(resolver.calls, greaterThanOrEqualTo(1));
    expect(resolver.verifyPlayableCalls, everyElement(isFalse));
  });

  test(
    'controller installs only selected imported rules without enabling them',
    () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'anime-controller-rule-import-',
      );
      Hive.init(tempDirectory.path);
      final settings = await Hive.openBox<dynamic>('anime.settings.v2');
      await settings.put('services', _offlineServices.toJson());
      await settings.close();

      final container = ProviderContainer(
        overrides: [
          bangumiMetadataRepositoryProvider.overrideWithValue(
            _FakeBangumiMetadataRepository(),
          ),
          sourceCatalogRepositoryProvider.overrideWithValue(
            const _EmptySourceCatalogRepository(),
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await Hive.close();
        if (await tempDirectory.exists()) {
          await tempDirectory.delete(recursive: true);
        }
      });

      await container.read(animeControllerProvider.future);
      final imported = const RuleImporter().importFromText(_twoSafeRulesJson);
      final selected = imported.rules.first;
      final omitted = imported.rules.last;

      final result = await container
          .read(animeControllerProvider.notifier)
          .importSelectedRulePlugins(
            repositoryName: imported.name,
            rules: [selected],
            sourceUrl: 'https://example.com/selected-rules.json',
          );
      final state = container.read(animeControllerProvider).requireValue;

      expect(result.ruleCount, 1);
      expect(result.installedCount, 1);
      expect(
        state.rulePlugins.customRules.map((rule) => rule.id),
        contains(selected.id),
      );
      expect(
        state.rulePlugins.customRules.map((rule) => rule.id),
        isNot(contains(omitted.id)),
      );
      expect(state.rulePlugins.installedIds, contains(selected.id));
      expect(state.rulePlugins.installedIds, isNot(contains(omitted.id)));
      expect(state.rulePlugins.enabledIds, isNot(contains(selected.id)));
    },
  );

  test(
    'controller reports and stores only effective unique imported rules',
    () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'anime-controller-rule-dedup-import-',
      );
      Hive.init(tempDirectory.path);
      final settings = await Hive.openBox<dynamic>('anime.settings.v2');
      await settings.put('services', _offlineServices.toJson());
      await settings.close();

      final container = ProviderContainer(
        overrides: [
          bangumiMetadataRepositoryProvider.overrideWithValue(
            _FakeBangumiMetadataRepository(),
          ),
          sourceCatalogRepositoryProvider.overrideWithValue(
            const _EmptySourceCatalogRepository(),
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await Hive.close();
        if (await tempDirectory.exists()) {
          await tempDirectory.delete(recursive: true);
        }
      });

      await container.read(animeControllerProvider.future);
      final older = _duplicateImportRule(
        id: 'user:duplicate-old',
        version: '1.0',
        updatedAt: DateTime(2026, 1, 1),
      );
      final newer = _duplicateImportRule(
        id: 'user:duplicate-new',
        version: '2.0',
        updatedAt: DateTime(2026, 7, 1),
      );

      final result = await container
          .read(animeControllerProvider.notifier)
          .importSelectedRulePlugins(
            repositoryName: '重复规则仓库',
            rules: [older, newer],
            sourceUrl: 'https://example.com/duplicate-rules.json',
          );
      final state = container.read(animeControllerProvider).requireValue;

      expect(result.ruleCount, 2);
      expect(result.installedCount, 1);
      expect(state.rulePlugins.customRules, hasLength(1));
      expect(state.rulePlugins.customRules.single.id, newer.id);
      expect(state.rulePlugins.installedIds, contains(newer.id));
      expect(state.rulePlugins.installedIds, isNot(contains(older.id)));
      expect(state.rulePlugins.repositories.single.ruleCount, 1);
    },
  );

  test(
    'refreshing the same Kazumi repository replaces rules and history',
    () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'anime-controller-kazumi-refresh-',
      );
      Hive.init(tempDirectory.path);
      final settings = await Hive.openBox<dynamic>('anime.settings.v2');
      await settings.put('services', _offlineServices.toJson());
      await settings.put(
        'rulePlugins',
        RulePluginState(
          installedIds: const {'kazumi:working'},
          customRules: [
            const RuleImporter()
                .importFromText('''
                {
                  "id": "kazumi:working",
                  "name": "working",
                  "version": "1.0",
                  "source": "kazumi",
                  "baseURL": "https://old.example/",
                  "searchURL": "https://old.example/search?wd=@keyword",
                  "chapterRoads": "//ul",
                  "chapterResult": "//a"
                }
                ''')
                .rules
                .single,
          ],
          repositories: [
            RuleRepositoryRecord(
              id: 'url:legacy-hash',
              name: 'KazumiRules',
              url:
                  'https://raw.githubusercontent.com/Predidit/KazumiRules/main/index.json',
              importedAt: DateTime(2026, 7, 1),
              ruleCount: 1,
            ),
          ],
        ).toJson(),
      );
      await settings.close();

      final container = ProviderContainer(
        overrides: [
          bangumiMetadataRepositoryProvider.overrideWithValue(
            _FakeBangumiMetadataRepository(),
          ),
          sourceCatalogRepositoryProvider.overrideWithValue(
            const _EmptySourceCatalogRepository(),
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await Hive.close();
        if (await tempDirectory.exists()) {
          await tempDirectory.delete(recursive: true);
        }
      });

      await container.read(animeControllerProvider.future);
      final updated = const RuleImporter()
          .importFromText('''
          {
            "id": "kazumi:working",
            "name": "working",
            "version": "2.0",
            "source": "kazumi",
            "baseURL": "https://new.example/",
            "searchURL": "https://new.example/search?wd=@keyword",
            "chapterRoads": "//ul",
            "chapterResult": "//a"
          }
        ''')
          .rules
          .single;
      await container
          .read(animeControllerProvider.notifier)
          .importSelectedRulePlugins(
            repositoryName: 'KazumiRules',
            rules: [updated],
            sourceUrl:
                'https://raw.githubusercontent.com/Predidit/KazumiRules/main/index.json',
          );

      final state = container.read(animeControllerProvider).requireValue;
      final matchingRules = state.rulePlugins.customRules.where(
        (rule) => rule.id == 'kazumi:working',
      );
      expect(matchingRules, hasLength(1));
      expect(matchingRules.single.version, '2.0');
      expect(matchingRules.single.baseUrl, 'https://new.example/');
      expect(state.rulePlugins.repositories, hasLength(1));
      expect(
        state.rulePlugins.repositories.single.id,
        isNot('url:legacy-hash'),
      );
    },
  );

  test('controller lets the user enable an imported custom engine', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'anime-controller-custom-engine-',
    );
    Hive.init(tempDirectory.path);
    final settings = await Hive.openBox<dynamic>('anime.settings.v2');
    await settings.put('services', _offlineServices.toJson());
    await settings.close();

    final container = ProviderContainer(
      overrides: [
        bangumiMetadataRepositoryProvider.overrideWithValue(
          _FakeBangumiMetadataRepository(),
        ),
        sourceCatalogRepositoryProvider.overrideWithValue(
          const _EmptySourceCatalogRepository(),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await Hive.close();
      if (await tempDirectory.exists()) {
        await tempDirectory.delete(recursive: true);
      }
    });

    await container.read(animeControllerProvider.future);
    final bundle = const RuleImporter().importFromText('''
      {
        "sites": [
          {
            "key": "custom-drpy",
            "name": "Custom DRPY",
            "type": 3,
            "api": "csp_DRPY",
            "ext": "https://example.com/rule.js"
          }
        ],
        "spider": "https://example.com/spider.jar"
      }
    ''');
    final rule = bundle.rules.single;
    final controller = container.read(animeControllerProvider.notifier);
    await controller.importSelectedRulePlugins(
      repositoryName: bundle.name,
      rules: [rule],
      sourceUrl: 'https://example.com/tvbox.json',
    );
    await controller.toggleRulePlugin(rule.id, true);

    var state = container.read(animeControllerProvider).requireValue;
    expect(state.rulePlugins.installedIds, contains(rule.id));
    expect(state.rulePlugins.enabledIds, contains(rule.id));
    expect(
      state.rulePlugins.customRules.single.rawConfig['spider'],
      'https://example.com/spider.jar',
    );

    await controller.setAllInstalledRulePluginsEnabled(false);
    state = container.read(animeControllerProvider).requireValue;
    expect(state.rulePlugins.enabledIds, isEmpty);

    await controller.setAllInstalledRulePluginsEnabled(true);
    state = container.read(animeControllerProvider).requireValue;
    expect(state.rulePlugins.enabledIds, state.rulePlugins.installedIds);
  });

  test(
    'bulk playback switch also controls bridged external source rules',
    () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'anime-controller-source-bridge-',
      );
      Hive.init(tempDirectory.path);
      final settings = await Hive.openBox<dynamic>('anime.settings.v2');
      await settings.put('services', _offlineServices.toJson());
      await settings.close();

      final container = ProviderContainer(
        overrides: [
          bangumiMetadataRepositoryProvider.overrideWithValue(
            _FakeBangumiMetadataRepository(),
          ),
          sourceCatalogRepositoryProvider.overrideWithValue(
            const _TvBoxSourceCatalogRepository(),
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await Hive.close();
        if (await tempDirectory.exists()) {
          await tempDirectory.delete(recursive: true);
        }
      });

      await container.read(animeControllerProvider.future);
      final controller = container.read(animeControllerProvider.notifier);
      var state = container.read(animeControllerProvider).requireValue;
      expect(state.sourceCatalog.activePlaybackRuleCount, 3);
      expect(state.sourceCatalog.sources.single.enabled, isTrue);

      await controller.setAllInstalledRulePluginsEnabled(false);
      state = container.read(animeControllerProvider).requireValue;
      expect(state.sourceCatalog.activePlaybackRuleCount, 0);
      expect(state.sourceCatalog.sources.single.enabled, isFalse);

      await controller.setAllInstalledRulePluginsEnabled(true);
      state = container.read(animeControllerProvider).requireValue;
      expect(state.sourceCatalog.activePlaybackRuleCount, 3);
      expect(state.sourceCatalog.sources.single.enabled, isTrue);
    },
  );
}

RulePlugin _duplicateImportRule({
  required String id,
  required String version,
  required DateTime updatedAt,
}) {
  return RulePlugin(
    id: id,
    name: '重复线路',
    version: version,
    source: RuleSourceKind.custom,
    contentType: RuleContentType.anime,
    engine: 'native',
    updatedAt: updatedAt,
    qualityScore: 80,
    tags: const ['native'],
    baseUrl: 'https://duplicate-import.example/',
    searchUrl: 'https://duplicate-import.example/search?wd=@keyword',
    searchable: true,
    quickSearch: true,
    filterable: false,
    kazumi: const KazumiParserConfig(
      searchList: '//div',
      searchName: '//a',
      searchResult: '//a',
      chapterRoads: '//ul',
      chapterResult: '//li/a',
    ),
  );
}

const _offlineServices = ExternalServiceSettings(
  mediaMetadataEnabled: false,
  cinemetaEnabled: false,
  peerTubeEnabled: false,
  wikimediaCommonsEnabled: false,
  anilistEnabled: false,
  jikanEnabled: false,
  kitsuEnabled: false,
  bangumiEnabled: false,
  publicCollectionSyncEnabled: false,
);

const _bangumiOnlyServices = ExternalServiceSettings(
  mediaMetadataEnabled: false,
  cinemetaEnabled: false,
  peerTubeEnabled: false,
  wikimediaCommonsEnabled: false,
  anilistEnabled: false,
  jikanEnabled: false,
  kitsuEnabled: false,
  bangumiEnabled: true,
  publicCollectionSyncEnabled: false,
);

class _FakeBangumiMetadataRepository extends BangumiMetadataRepository {
  _FakeBangumiMetadataRepository()
    : super(client: MockClient((_) async => http.Response('not found', 404)));

  @override
  Future<AnimeHomeFeed> homeFeed() async => _homeFeed;

  @override
  AnimeHomeFeed fallbackHomeFeed() => _homeFeed;
}

class _DetailBangumiMetadataRepository extends _FakeBangumiMetadataRepository {
  @override
  Future<AnimeDetailBundle> detail(int subjectId) async =>
      const AnimeDetailBundle(
        subject: _homeSubject,
        episodes: [
          AnimeEpisode(
            id: 101,
            subjectId: 1,
            number: 1,
            title: '第一集',
            airdate: '2026-01-01',
            duration: '24:00',
            description: '',
          ),
        ],
        characters: [],
        staff: [],
        recommendations: [],
      );
}

class _BlockingRulePlaybackResolver extends RulePlaybackResolver {
  final called = Completer<void>();
  final result = Completer<List<PlaybackLine>>();
  final verifyPlayableCalls = <bool>[];
  var calls = 0;

  @override
  Future<List<PlaybackLine>> resolveRule({
    required RulePlugin rule,
    required AnimeSubject subject,
    required AnimeEpisode episode,
    bool verifyPlayable = true,
  }) {
    calls++;
    verifyPlayableCalls.add(verifyPlayable);
    if (!called.isCompleted) called.complete();
    return result.future;
  }
}

class _ControlledBangumiMetadataRepository extends BangumiMetadataRepository {
  _ControlledBangumiMetadataRepository({this.immediateHomeFeed = false})
    : super(client: MockClient((_) async => http.Response('not found', 404)));

  final bool immediateHomeFeed;
  final homeFeedCompleter = Completer<AnimeHomeFeed>();
  final discoveryCompleter = Completer<List<AnimeSubject>>();
  bool homeFeedStarted = false;
  bool discoveryStarted = false;

  @override
  AnimeHomeFeed fallbackHomeFeed() => _homeFeed;

  @override
  Future<AnimeHomeFeed> homeFeed() {
    homeFeedStarted = true;
    if (immediateHomeFeed) return Future.value(_homeFeed);
    return homeFeedCompleter.future;
  }

  @override
  Future<List<AnimeSubject>> discoverySubjects() {
    discoveryStarted = true;
    return discoveryCompleter.future;
  }
}

class _EmptySourceCatalogRepository extends SourceCatalogRepository {
  const _EmptySourceCatalogRepository();

  @override
  Future<SourceCatalogState> loadCatalog({
    Map<String, bool> enabledOverrides = const {},
  }) async => const SourceCatalogState();
}

class _TvBoxSourceCatalogRepository extends SourceCatalogRepository {
  const _TvBoxSourceCatalogRepository();

  @override
  Future<SourceCatalogState> loadCatalog({
    Map<String, bool> enabledOverrides = const {},
  }) async {
    return const SourceCatalogState(
      totalSources: 1,
      sources: [
        VideoSource(
          id: 'source:tvbox',
          name: '测试 TVBox',
          kind: VideoSourceKind.tvBox,
          importUrl: 'https://example.com/tvbox.json',
          baseUrl: 'https://example.com/tvbox.json',
          rawConfig: {
            'sites': [
              {
                'key': 'json-api',
                'name': '综合资源',
                'type': 1,
                'api': 'https://api.example.com/provide/vod',
              },
            ],
          },
        ),
      ],
    ).applyEnabledOverrides(enabledOverrides);
  }
}

const _homeSubject = AnimeSubject(
  id: 1,
  title: '测试番剧',
  originalTitle: 'Test Anime',
  summary: '测试简介',
  coverUrl: null,
  bannerUrl: null,
  date: '2026-01-01',
  platform: 'TV',
  language: '日语',
  region: '日本',
  status: '连载中',
  categories: [AnimeCategory(name: '动画')],
  tags: [AnimeTag(name: '测试')],
  totalEpisodes: 12,
);

const _homeFeed = AnimeHomeFeed(
  hero: _homeSubject,
  recent: [_homeSubject],
  recommended: [_homeSubject],
  index: [_homeSubject],
  categories: [AnimeCategory(name: '动画')],
  tags: [AnimeTag(name: '测试')],
);

const _animeMovieSubject = AnimeSubject(
  id: 2,
  title: '测试动画电影',
  originalTitle: 'Test Anime Movie',
  summary: '动画来源即使平台标记为 Movie，也应保留在番剧频道。',
  coverUrl: null,
  bannerUrl: null,
  date: '2026-02-01',
  platform: 'Movie',
  language: '日语',
  region: '日本',
  status: '已上映',
  categories: [AnimeCategory(name: '动画')],
  tags: [],
  totalEpisodes: 1,
  source: 'jikan',
);

const _seriesSubject = AnimeSubject(
  id: 3,
  title: '测试电视剧',
  originalTitle: 'Test Series',
  summary: '',
  coverUrl: null,
  bannerUrl: null,
  date: '2026-02-01',
  platform: 'Scripted',
  language: '英语',
  region: '美国',
  status: '连载中',
  categories: [AnimeCategory(name: '剧情')],
  tags: [],
  totalEpisodes: 10,
  source: 'tvmaze',
);

const _movieSubject = AnimeSubject(
  id: 4,
  title: '测试真人电影',
  originalTitle: 'Test Movie',
  summary: '',
  coverUrl: null,
  bannerUrl: null,
  date: '2026-02-01',
  platform: 'Movie',
  language: '英语',
  region: '美国',
  status: '电影',
  categories: [AnimeCategory(name: '电影')],
  tags: [],
  totalEpisodes: 1,
  source: 'wikidata',
);

const _twoSafeRulesJson = '''
{
  "name": "用户勾选规则",
  "rules": [
    {
      "id": "selected-only",
      "name": "已勾选源",
      "engine": "native",
      "baseUrl": "https://selected.example.com",
      "searchUrl": "https://selected.example.com/search?q=@keyword",
      "chapterRoads": "//ul",
      "chapterResult": "//a"
    },
    {
      "id": "not-selected",
      "name": "未勾选源",
      "engine": "native",
      "baseUrl": "https://omitted.example.com",
      "searchUrl": "https://omitted.example.com/search?q=@keyword",
      "chapterRoads": "//ul",
      "chapterResult": "//a"
    }
  ]
}
''';
