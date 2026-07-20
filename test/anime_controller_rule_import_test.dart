import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/data/bangumi_metadata_repository.dart';
import 'package:anime/src/data/external_service_repository.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/domain/subject_content_type.dart';
import 'package:anime/src/rules/rule_importer.dart';
import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/rules/rule_playback_resolver.dart';
import 'package:anime/src/rules/rule_plugin_repository.dart';
import 'package:anime/src/rules/tvbox_xbpq_hydrator.dart';
import 'package:anime/src/sources/external_source_adapters.dart';
import 'package:anime/src/sources/source_catalog_models.dart';
import 'package:anime/src/sources/source_catalog_repository.dart';
import 'package:anime/src/sources/source_rule_bridge.dart';
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

  test('fresh one-hour home cache skips startup metadata refresh', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'anime-controller-fresh-home-cache-',
    );
    Hive.init(tempDirectory.path);
    final settings = await Hive.openBox<dynamic>('anime.settings.v2');
    await settings.put('services', _bangumiOnlyServices.toJson());
    await settings.close();
    final library = await Hive.openBox<dynamic>('anime.library.v2');
    await library.put('metadata.cache.home', {
      'version': 2,
      'fetchedAt': DateTime.now().toUtc().toIso8601String(),
      'feed': _homeFeed.toJson(),
    });
    await library.close();

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
      container.dispose();
      await Hive.close();
      if (await tempDirectory.exists()) {
        await tempDirectory.delete(recursive: true);
      }
    });

    final initial = await container.read(animeControllerProvider.future);
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(initial.homeFeed.hero.title, _homeSubject.title);
    expect(repository.homeFeedStarted, isFalse);
  });

  test(
    'legacy home cache is shown immediately but refreshed as stale',
    () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'anime-controller-legacy-home-cache-',
      );
      Hive.init(tempDirectory.path);
      final settings = await Hive.openBox<dynamic>('anime.settings.v2');
      await settings.put('services', _bangumiOnlyServices.toJson());
      await settings.close();
      final library = await Hive.openBox<dynamic>('anime.library.v2');
      await library.put('metadata.cache.home', {
        'version': 1,
        'feed': _mixedHomeFeed.toJson(),
      });
      await library.close();

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
        container.dispose();
        await Hive.close();
        if (await tempDirectory.exists()) {
          await tempDirectory.delete(recursive: true);
        }
      });

      final initial = await container.read(animeControllerProvider.future);
      await Future<void>.delayed(Duration.zero);

      expect(initial.homeFeed.recent, hasLength(3));
      expect(repository.homeFeedStarted, isTrue);
      repository.homeFeedCompleter.complete(_homeFeed);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    },
  );

  test(
    'anime discovery is immediate and rejects series and all movie formats',
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
        _animeSeriesSubject,
        _animeMovieSubject,
        _seriesSubject,
        _movieSubject,
      ]);
      final refreshed = await refreshedFuture;

      expect(refreshed.map((item) => item.title), contains('测试动画剧集'));
      expect(refreshed.map((item) => item.title), isNot(contains('测试动画电影')));
      expect(refreshed.map((item) => item.source), isNot(contains('tvmaze')));
      expect(refreshed.map((item) => item.source), isNot(contains('wikidata')));
    },
  );

  test(
    'merged search metadata keeps shorter Chinese title and summary',
    () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'anime-controller-chinese-merge-',
      );
      Hive.init(tempDirectory.path);
      final settings = await Hive.openBox<dynamic>('anime.settings.v2');
      await settings.put('services', _mergeServices.toJson());
      await settings.close();

      final container = ProviderContainer(
        overrides: [
          bangumiMetadataRepositoryProvider.overrideWithValue(
            _ContentBangumiMetadataRepository(
              fixtureHomeFeed: _homeFeed,
              searchResults: const [_shortChineseDuplicate],
            ),
          ),
          externalServiceRepositoryProvider.overrideWithValue(
            _ContentExternalServiceRepository(
              anilistSearchResults: const [_longEnglishDuplicate],
            ),
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
      final results = await container
          .read(animeControllerProvider.notifier)
          .search('Shared Original');

      expect(results, hasLength(1));
      expect(results.single.title, _shortChineseDuplicate.title);
      expect(results.single.summary, _shortChineseDuplicate.summary);
      expect(results.single.source, 'anilist');
    },
  );

  test(
    'home anime lists stay isolated while series and movie highlights remain',
    () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'anime-controller-home-partition-',
      );
      Hive.init(tempDirectory.path);
      final settings = await Hive.openBox<dynamic>('anime.settings.v2');
      await settings.put('services', _partitionServices.toJson());
      await settings.close();

      final container = ProviderContainer(
        overrides: [
          bangumiMetadataRepositoryProvider.overrideWithValue(
            _ContentBangumiMetadataRepository(fixtureHomeFeed: _mixedHomeFeed),
          ),
          externalServiceRepositoryProvider.overrideWithValue(
            _ContentExternalServiceRepository(
              seriesResults: const [_seriesSubject],
              movieResults: const [_movieSubject],
            ),
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
      AnimeHomeFeed? refreshed;
      for (var attempt = 0; attempt < 100; attempt++) {
        final feed = container.read(animeControllerProvider).value?.homeFeed;
        if (feed != null &&
            feed.seriesHighlights.isNotEmpty &&
            feed.movieHighlights.isNotEmpty) {
          refreshed = feed;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(refreshed, isNotNull);
      final animeLists = [
        refreshed!.recent,
        refreshed.recommended,
        refreshed.index,
      ];
      for (final subjects in animeLists) {
        expect(
          subjects.map(subjectContentTypeOf),
          everyElement(SubjectContentType.anime),
        );
      }
      expect(
        refreshed.seriesHighlights.map(subjectContentTypeOf),
        everyElement(SubjectContentType.series),
      );
      expect(
        refreshed.movieHighlights.map(subjectContentTypeOf),
        everyElement(SubjectContentType.movie),
      );
    },
  );

  test(
    'weekly schedule keeps Bangumi Chinese data and never injects AniList',
    () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'anime-controller-schedule-bangumi-',
      );
      Hive.init(tempDirectory.path);
      final settings = await Hive.openBox<dynamic>('anime.settings.v2');
      await settings.put('services', _scheduleServices.toJson());
      await settings.close();
      final external = _ContentExternalServiceRepository(
        anilistTrendingResults: const [_scheduleEnglishSubject],
      );

      final container = ProviderContainer(
        overrides: [
          bangumiMetadataRepositoryProvider.overrideWithValue(
            _ContentBangumiMetadataRepository(
              fixtureHomeFeed: _homeFeed,
              scheduleResults: const {
                0: [_scheduleChineseSubject],
              },
            ),
          ),
          externalServiceRepositoryProvider.overrideWithValue(external),
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
      final controller = container.read(animeControllerProvider.notifier);
      final schedule = await controller.weeklySchedule();
      final subjects = schedule.values.expand((items) => items).toList();

      expect(subjects, hasLength(1));
      expect(subjects.single.title, '周期表中文标题');
      expect(subjects.single.summary, '周期表中文简介。');
      expect(subjects, isNot(contains(_scheduleEnglishSubject)));
      expect(external.anilistTrendingCalls, 0);
    },
  );

  test(
    'weekly schedule falls back to the existing Chinese home anime',
    () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'anime-controller-schedule-home-fallback-',
      );
      Hive.init(tempDirectory.path);
      final settings = await Hive.openBox<dynamic>('anime.settings.v2');
      await settings.put('services', _scheduleServices.toJson());
      await settings.close();
      final external = _ContentExternalServiceRepository(
        anilistTrendingResults: const [_scheduleEnglishSubject],
      );

      final container = ProviderContainer(
        overrides: [
          bangumiMetadataRepositoryProvider.overrideWithValue(
            _ContentBangumiMetadataRepository(fixtureHomeFeed: _homeFeed),
          ),
          externalServiceRepositoryProvider.overrideWithValue(external),
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
      final schedule = await container
          .read(animeControllerProvider.notifier)
          .weeklySchedule();

      expect(
        schedule.values.expand((items) => items).map((item) => item.id),
        contains(_homeSubject.id),
      );
      expect(
        schedule.values.expand((items) => items),
        isNot(contains(_scheduleEnglishSubject)),
      );
      expect(external.anilistTrendingCalls, 0);
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

  test('M3U and BT catalog sources reach their real runtime paths', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'anime-controller-external-sources-',
    );
    Hive.init(tempDirectory.path);
    final settings = await Hive.openBox<dynamic>('anime.settings.v2');
    await settings.put('services', _offlineServices.toJson());
    await settings.close();

    final m3uAdapter = M3uSourceAdapter(
      client: MockClient((request) async {
        expect(request.url.host, 'feeds.example');
        return http.Response.bytes(
          utf8.encode('''
#EXTM3U
#EXTINF:-1 group-title="央视频道",CCTV-1 综合
https://stream.example/live/cctv1.m3u8
'''),
          200,
          headers: {'content-type': 'application/x-mpegURL; charset=utf-8'},
        );
      }),
    );
    final torrentAdapter = DmhySourceAdapter(
      client: MockClient((request) async {
        expect(request.url.host, 'dmhy.org');
        return http.Response.bytes(
          utf8.encode('''
<table id="topic_list"><tbody><tr>
  <td>2026/07/18 12:30</td><td>动画</td>
  <td class="title"><a href="/topics/view/1.html">测试字幕组 CCTV 特辑</a></td>
  <td><a href="magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567">磁力</a></td>
  <td>1.2GB</td><td>12</td><td>34</td><td>56</td><td>fixture</td>
</tr></tbody></table>
'''),
          200,
          headers: {'content-type': 'text/html; charset=utf-8'},
        );
      }),
    );
    final container = ProviderContainer(
      overrides: [
        bangumiMetadataRepositoryProvider.overrideWithValue(
          _FakeBangumiMetadataRepository(),
        ),
        sourceCatalogRepositoryProvider.overrideWithValue(
          const _ExternalSourceCatalogRepository(),
        ),
        m3uSourceAdapterProvider.overrideWithValue(m3uAdapter),
        torrentSourceAdapterProvider.overrideWithValue(torrentAdapter),
      ],
    );
    addTearDown(() async {
      container.dispose();
      m3uAdapter.close();
      torrentAdapter.close();
      await Hive.close();
      if (await tempDirectory.exists()) {
        await tempDirectory.delete(recursive: true);
      }
    });

    await container.read(animeControllerProvider.future);
    final controller = container.read(animeControllerProvider.notifier);
    final search = await controller.search('CCTV');
    final live = search.singleWhere(
      (item) => item.source.startsWith('m3u-channel:'),
    );
    expect(live.title, 'CCTV-1 综合');

    final detail = await controller.detail(live);
    expect(detail.episodes, hasLength(1));
    final lines = await controller.linesForEpisode(
      detail.subject,
      detail.episodes.single,
    );
    expect(lines.single.available, isTrue);
    expect(lines.single.format, 'HLS');
    expect(lines.single.url, 'https://stream.example/live/cctv1.m3u8');

    final torrents = await controller.searchTorrentResources('CCTV');
    expect(torrents.failures, isEmpty);
    expect(torrents.items.single.title, contains('CCTV'));
    expect(torrents.items.single.requiresExternalClient, isTrue);
  });

  test(
    'library entries keep same numeric ids from different sources apart',
    () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'anime-controller-library-identity-',
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
      final controller = container.read(animeControllerProvider.notifier);
      final sameIdFromJikan = _homeSubject.copyWith(source: 'jikan');
      await controller.toggleFollowing(_homeSubject);
      await controller.toggleFollowing(sameIdFromJikan);
      await controller.addHistory(_homeSubject, null);
      await controller.addHistory(sameIdFromJikan, null);

      var current = container.read(animeControllerProvider).value!;
      expect(current.following, hasLength(2));
      expect(current.history, hasLength(2));

      await controller.toggleFollowing(_homeSubject);
      current = container.read(animeControllerProvider).value!;
      expect(current.following, hasLength(1));
      expect(current.following.single.subject.source, 'jikan');
    },
  );

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

  test(
    'controller keeps unsupported custom engines installed but disabled',
    () async {
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
      expect(state.rulePlugins.enabledIds, isNot(contains(rule.id)));
      expect(rule.executionStatus, RuleExecutionStatus.unsupportedEngine);
      expect(
        state.rulePlugins.customRules.single.rawConfig['spider'],
        'https://example.com/spider.jar',
      );

      await controller.setAllInstalledRulePluginsEnabled(false);
      state = container.read(animeControllerProvider).requireValue;
      expect(state.rulePlugins.enabledIds, isEmpty);

      await controller.setAllInstalledRulePluginsEnabled(true);
      state = container.read(animeControllerProvider).requireValue;
      final repository = RulePluginRepository(
        extraRules: state.rulePlugins.customRules,
      );
      final executableInstalledIds = state.rulePlugins.installedIds
          .where((id) => repository.byId(id)?.canResolveNatively ?? false)
          .toSet();
      expect(state.rulePlugins.enabledIds, executableInstalledIds);
      expect(state.rulePlugins.enabledIds, isNot(contains(rule.id)));
    },
  );

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

  test(
    'background XBPQ hydration respects source switches and joins playback',
    () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'anime-controller-xbpq-hydration-',
      );
      Hive.init(tempDirectory.path);
      final settings = await Hive.openBox<dynamic>('anime.settings.v2');
      await settings.put('services', _offlineServices.toJson());
      await settings.close();

      final requestStarted = Completer<void>();
      final response = Completer<http.Response>();
      var requestCount = 0;
      final hydrator = TvBoxXbpqHydrator(
        client: MockClient((request) {
          requestCount++;
          expect(request.url, Uri.parse('https://rules.example/xbpq.json'));
          if (!requestStarted.isCompleted) requestStarted.complete();
          return response.future;
        }),
      );
      final resolver = _RecordingRulePlaybackResolver();
      final container = ProviderContainer(
        overrides: [
          bangumiMetadataRepositoryProvider.overrideWithValue(
            _FakeBangumiMetadataRepository(),
          ),
          sourceCatalogRepositoryProvider.overrideWithValue(
            const _XbpqSourceCatalogRepository(),
          ),
          sourceRuleBridgeProvider.overrideWithValue(
            SourceRuleBridge(xbpqHydrator: hydrator),
          ),
          rulePlaybackResolverProvider.overrideWithValue(resolver),
        ],
      );
      addTearDown(() async {
        if (!response.isCompleted) {
          response.complete(http.Response('cancelled', 503));
        }
        container.dispose();
        hydrator.close();
        await Hive.close();
        if (await tempDirectory.exists()) {
          await tempDirectory.delete(recursive: true);
        }
      });

      final initial = await container
          .read(animeControllerProvider.future)
          .timeout(const Duration(milliseconds: 500));
      expect(initial.sourceCatalog.activePlaybackRuleCount, 0);
      expect(requestCount, 0);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        requestCount,
        0,
        reason: 'startup hydration should leave the first UI second free',
      );
      await requestStarted.future.timeout(const Duration(seconds: 2));

      final controller = container.read(animeControllerProvider.notifier);
      final disabling = controller.setAllInstalledRulePluginsEnabled(false);
      await disabling.timeout(const Duration(milliseconds: 500));
      expect(
        container
            .read(animeControllerProvider)
            .requireValue
            .sourceCatalog
            .sources
            .single
            .enabled,
        isFalse,
      );

      response.complete(
        http.Response(
          jsonEncode(_completeControllerXbpqConfig),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      var state = container.read(animeControllerProvider).requireValue;
      expect(requestCount, 1);
      expect(state.sourceCatalog.availablePlaybackRuleCount, 0);
      expect(state.sourceCatalog.activePlaybackRuleCount, 0);
      expect(state.sourceCatalog.playbackRuleCountFor('source:xbpq'), 0);

      await controller
          .setAllInstalledRulePluginsEnabled(true)
          .timeout(const Duration(milliseconds: 500));
      state = container.read(animeControllerProvider).requireValue;
      expect(
        requestCount,
        1,
        reason: 'source switch should reuse hydration cache',
      );
      expect(state.sourceCatalog.sources.single.enabled, isTrue);
      expect(state.sourceCatalog.activePlaybackRuleCount, 1);

      const episode = AnimeEpisode(
        id: 101,
        subjectId: 1,
        number: 1,
        title: '第一集',
        airdate: '2026-01-01',
        duration: '24:00',
        description: '',
      );
      final lines = await controller.linesForEpisodeMode(
        _homeSubject,
        episode,
        expandAll: true,
      );

      expect(lines, isNotEmpty);
      final xbpqRules = resolver.rules
          .where((rule) => rule.engine.toLowerCase() == 'xbpq')
          .toList(growable: false);
      expect(xbpqRules, hasLength(1));
      expect(xbpqRules.single.id, startsWith('catalog:source:xbpq:'));
      expect(
        xbpqRules.single.id,
        isNot(startsWith('catalog:source:xbpq:catalog:')),
      );
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

const _mergeServices = ExternalServiceSettings(
  mediaMetadataEnabled: false,
  cinemetaEnabled: false,
  peerTubeEnabled: false,
  wikimediaCommonsEnabled: false,
  anilistEnabled: true,
  jikanEnabled: false,
  kitsuEnabled: false,
  bangumiEnabled: true,
  preferBangumiChinese: false,
  publicCollectionSyncEnabled: false,
);

const _partitionServices = ExternalServiceSettings(
  mediaMetadataEnabled: true,
  cinemetaEnabled: true,
  peerTubeEnabled: false,
  wikimediaCommonsEnabled: false,
  anilistEnabled: false,
  jikanEnabled: false,
  kitsuEnabled: false,
  bangumiEnabled: true,
  publicCollectionSyncEnabled: false,
);

const _scheduleServices = ExternalServiceSettings(
  mediaMetadataEnabled: false,
  cinemetaEnabled: false,
  peerTubeEnabled: false,
  wikimediaCommonsEnabled: false,
  anilistEnabled: true,
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

class _RecordingRulePlaybackResolver extends RulePlaybackResolver {
  final rules = <RulePlugin>[];

  @override
  Future<List<PlaybackLine>> resolveRule({
    required RulePlugin rule,
    required AnimeSubject subject,
    required AnimeEpisode episode,
    bool verifyPlayable = true,
  }) async {
    rules.add(rule);
    return [
      PlaybackLine(
        id: 'line:${rule.id}',
        episodeId: episode.id,
        providerId: rule.id,
        providerName: rule.name,
        title: episode.displayTitle,
        quality: '自动',
        format: 'HLS',
        url: 'https://media.example/episode.m3u8',
        headers: rule.requestHeaders,
        available: true,
      ),
    ];
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

class _ContentBangumiMetadataRepository extends BangumiMetadataRepository {
  _ContentBangumiMetadataRepository({
    required this.fixtureHomeFeed,
    this.searchResults = const [],
    this.scheduleResults = const {},
  }) : super(client: MockClient((_) async => http.Response('not found', 404)));

  final AnimeHomeFeed fixtureHomeFeed;
  final List<AnimeSubject> searchResults;
  final Map<int, List<AnimeSubject>> scheduleResults;

  @override
  AnimeHomeFeed fallbackHomeFeed() => fixtureHomeFeed;

  @override
  Future<AnimeHomeFeed> homeFeed() async => fixtureHomeFeed;

  @override
  Future<Map<int, List<AnimeSubject>>> weeklySchedule() async =>
      scheduleResults;

  @override
  Future<List<AnimeSubject>> searchSubjects({
    required String keyword,
    String sort = 'match',
    Map<String, Object?> filters = const {
      'type': [2],
    },
    int limit = 24,
    int offset = 0,
  }) async => searchResults;
}

class _ContentExternalServiceRepository extends ExternalServiceRepository {
  _ContentExternalServiceRepository({
    this.anilistSearchResults = const [],
    this.anilistTrendingResults = const [],
    this.seriesResults = const [],
    this.movieResults = const [],
  }) : super(client: MockClient((_) async => http.Response('not found', 404)));

  final List<AnimeSubject> anilistSearchResults;
  final List<AnimeSubject> anilistTrendingResults;
  final List<AnimeSubject> seriesResults;
  final List<AnimeSubject> movieResults;
  var anilistTrendingCalls = 0;

  @override
  Future<List<AnimeSubject>> anilistSearch(
    String keyword, {
    int perPage = 24,
  }) async => anilistSearchResults;

  @override
  Future<List<AnimeSubject>> anilistTrending({
    int perPage = 24,
    int page = 1,
    String season = '',
    int? seasonYear,
  }) async {
    anilistTrendingCalls++;
    return anilistTrendingResults;
  }

  @override
  Future<List<AnimeSubject>> cinemetaFeed({
    required String type,
    int pages = 6,
    String genre = '',
  }) async => type == 'series' ? seriesResults : movieResults;

  @override
  Future<List<AnimeSubject>> movieMetadataFeed({
    String keyword = '',
    bool includeCinemeta = true,
    bool includeArchive = true,
    int cinemetaPages = 6,
  }) async => movieResults;
}

class _EmptySourceCatalogRepository extends SourceCatalogRepository {
  const _EmptySourceCatalogRepository();

  @override
  Future<SourceCatalogState> loadCatalog({
    Map<String, bool> enabledOverrides = const {},
  }) async => const SourceCatalogState();
}

class _ExternalSourceCatalogRepository extends SourceCatalogRepository {
  const _ExternalSourceCatalogRepository();

  @override
  Future<SourceCatalogState> loadCatalog({
    Map<String, bool> enabledOverrides = const {},
  }) async {
    return const SourceCatalogState(
      totalSources: 2,
      sources: [
        VideoSource(
          id: 'm3u:fixture',
          name: '测试直播',
          kind: VideoSourceKind.liveM3u,
          importUrl: 'https://feeds.example/live.m3u',
          baseUrl: 'https://feeds.example/live.m3u',
          enabled: true,
        ),
        VideoSource(
          id: 'torrent:fixture',
          name: '测试 BT',
          kind: VideoSourceKind.torrent,
          importUrl: 'https://dmhy.org/',
          baseUrl: 'https://dmhy.org/',
          rawConfig: {'site': 'dmhy'},
          supportsSearch: true,
          enabled: true,
        ),
      ],
    ).applyEnabledOverrides(enabledOverrides);
  }
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

class _XbpqSourceCatalogRepository extends SourceCatalogRepository {
  const _XbpqSourceCatalogRepository();

  @override
  Future<SourceCatalogState> loadCatalog({
    Map<String, bool> enabledOverrides = const {},
  }) async {
    return const SourceCatalogState(
      totalSources: 1,
      sources: [
        VideoSource(
          id: 'source:xbpq',
          name: '测试 XBPQ',
          kind: VideoSourceKind.tvBox,
          importUrl: 'https://rules.example/catalog.json',
          baseUrl: 'https://rules.example/catalog.json',
          headers: {'Referer': 'https://rules.example/'},
          rawConfig: {
            'sites': [
              {
                'key': 'xbpq-controller',
                'name': 'XBPQ 动漫',
                'type': 3,
                'api': 'csp_XBPQ',
                'searchable': 1,
                'ext': './xbpq.json',
              },
            ],
          },
        ),
      ],
    ).applyEnabledOverrides(enabledOverrides);
  }
}

const _completeControllerXbpqConfig = <String, dynamic>{
  '请求头': {'User-Agent': 'XBPQ Rule UA'},
  '主页url': 'https://media.example/',
  '搜索url': 'https://media.example/search?wd={wd}',
  '搜索数组': '<div&&</div>',
  '搜索标题': 'title="&&"',
  '搜索链接': 'href="&&"',
  '播放数组': '<section&&</section>',
  '播放列表': '<a&&/a>',
  '播放标题': '>&&<',
  '播放链接': 'href="&&"',
};

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

const _shortChineseDuplicate = AnimeSubject(
  id: 601,
  title: '共享作品',
  originalTitle: 'Shared Original',
  summary: '短中文简介。',
  coverUrl: null,
  bannerUrl: null,
  date: '2026-01-01',
  platform: 'TV',
  language: '日语',
  region: '日本',
  status: '连载中',
  categories: [AnimeCategory(name: '动画')],
  tags: [],
  totalEpisodes: 12,
  source: 'bangumi',
);

const _longEnglishDuplicate = AnimeSubject(
  id: 602,
  title: 'Shared Original',
  originalTitle: 'Shared Original',
  summary:
      'This deliberately much longer English synopsis has enough metadata to '
      'win the quality comparison, but it must not replace verified Chinese.',
  coverUrl: 'https://images.example/shared.jpg',
  bannerUrl: 'https://images.example/shared-banner.jpg',
  date: '2026-01-01',
  platform: 'TV',
  language: 'Japanese',
  region: 'Japan',
  status: 'Running',
  categories: [AnimeCategory(name: 'Animation')],
  tags: [],
  totalEpisodes: 12,
  ratingScore: 8.8,
  source: 'anilist',
);

const _scheduleEnglishSubject = AnimeSubject(
  id: 701,
  title: 'Schedule Original',
  originalTitle: 'スケジュール作品',
  summary: 'English schedule synopsis.',
  coverUrl: null,
  bannerUrl: null,
  date: '2026-07-19',
  platform: 'TV',
  language: 'Japanese',
  region: 'Japan',
  status: 'Running',
  categories: [AnimeCategory(name: 'Animation')],
  tags: [],
  totalEpisodes: 12,
  source: 'anilist',
);

const _scheduleChineseSubject = AnimeSubject(
  id: 702,
  title: '周期表中文标题',
  originalTitle: 'スケジュール作品',
  summary: '周期表中文简介。',
  coverUrl: null,
  bannerUrl: null,
  date: '2026-07-19',
  platform: 'TV',
  language: '日语',
  region: '日本',
  status: '连载中',
  categories: [AnimeCategory(name: '动画')],
  tags: [],
  totalEpisodes: 12,
  source: 'bangumi',
);

const _mixedHomeFeed = AnimeHomeFeed(
  hero: _homeSubject,
  recent: [_homeSubject, _seriesSubject, _movieSubject],
  recommended: [_seriesSubject, _homeSubject, _movieSubject],
  index: [_movieSubject, _seriesSubject, _homeSubject],
  categories: [AnimeCategory(name: '动画')],
  tags: [AnimeTag(name: '测试')],
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
  summary: '动画来源的平台标记为 Movie 时，应只进入电影频道。',
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

const _animeSeriesSubject = AnimeSubject(
  id: 5,
  title: '测试动画剧集',
  originalTitle: 'Test Anime Series',
  summary: '非电影格式的动画作品应保留在番剧频道。',
  coverUrl: null,
  bannerUrl: null,
  date: '2026-02-01',
  platform: 'TV',
  language: '日语',
  region: '日本',
  status: '连载中',
  categories: [AnimeCategory(name: '动画')],
  tags: [],
  totalEpisodes: 12,
  source: 'anilist',
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
