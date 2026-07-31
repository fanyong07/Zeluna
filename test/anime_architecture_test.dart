import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anime/src/data/external_service_repository.dart';
import 'package:anime/src/data/playback_source_repository.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/rules/rule_importer.dart';
import 'package:anime/src/rules/rule_playback_resolver.dart';
import 'package:anime/src/rules/rule_plugin_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('super-resolution notices stay in the playback settings panel', () {
    final source = File('lib/src/player/player_page.dart').readAsStringSync();
    final surfaceGetter = RegExp(
      r'String\? get _surfaceMessage \{([\s\S]*?)\n  \}',
    ).firstMatch(source);

    expect(surfaceGetter, isNotNull);
    expect(
      surfaceGetter!.group(1),
      isNot(contains('_superResolutionStatusMessage')),
    );
    expect(source, isNot(contains('_showPlayerToast(message);')));
    expect(source, contains('_SuperResolutionPanelNotice(message: notice)'));
  });

  test(
    'playback source framework returns lines for one episode only',
    () async {
      const subject = AnimeSubject(
        id: 1,
        title: '测试番剧',
        originalTitle: 'Test Anime',
        summary: 'summary',
        coverUrl: null,
        bannerUrl: null,
        date: '2026-01-01',
        platform: 'TV',
        language: '日语',
        region: '日本',
        status: '全12集',
        categories: [AnimeCategory(name: '动画')],
        tags: [AnimeTag(name: 'TV')],
        totalEpisodes: 12,
      );
      const episode = AnimeEpisode(
        id: 101,
        subjectId: 1,
        number: 1,
        title: '',
        airdate: '2026-01-01',
        duration: '24:00',
        description: '第一集',
      );

      final lines = await const EmptyPlaybackSourceRepository().linesForEpisode(
        subject,
        episode,
      );

      expect(lines, hasLength(1));
      expect(lines.single.episodeId, episode.id);
      expect(lines.single.available, isFalse);
      expect(lines.single.message, '暂时没有可用的播放地址。');
    },
  );

  test(
    'subtitle and danmaku frameworks use public sources without keys',
    () async {
      const subject = AnimeSubject(
        id: 1,
        title: '测试番剧',
        originalTitle: 'Test Anime',
        summary: 'summary',
        coverUrl: null,
        bannerUrl: null,
        date: '2026-01-01',
        platform: 'TV',
        language: '日语',
        region: '日本',
        status: '全12集',
        categories: [AnimeCategory(name: '动画')],
        tags: [AnimeTag(name: 'TV')],
        totalEpisodes: 12,
      );
      const episode = AnimeEpisode(
        id: 101,
        subjectId: 1,
        number: 1,
        title: '',
        airdate: '2026-01-01',
        duration: '24:00',
        description: '第一集',
      );

      final repo = ExternalServiceRepository();
      final subtitles = await repo.searchSubtitles(
        subject,
        episode,
        const ExternalServiceSettings(),
      );
      final danmaku = await repo.matchDanmaku(
        subject,
        episode,
        const ExternalServiceSettings(dandanplayDanmakuEnabled: false),
      );

      expect(subtitles.single.provider, 'Bilibili');
      expect(subtitles.single.message, contains('B 站'));
      expect(danmaku.single.provider, 'Bilibili');
      expect(danmaku.single.message, contains('B 站'));
    },
  );

  test('external service settings keep third-party tokens out of JSON', () {
    const settings = ExternalServiceSettings();
    final json = settings.toJson();

    expect(settings.mediaMetadataEnabled, isTrue);
    expect(settings.mediaMetadataProvider, 'TMDB + Cinemeta + TVMaze');
    expect(settings.tmdbEnabled, isTrue);
    expect(settings.cinemetaEnabled, isTrue);
    expect(settings.watchHubEnabled, isFalse);
    expect(settings.peerTubeEnabled, isTrue);
    expect(settings.wikimediaCommonsEnabled, isTrue);
    expect(settings.publicCollectionSyncEnabled, isTrue);
    expect(settings.bilibiliSubtitleEnabled, isTrue);
    expect(settings.dandanplayDanmakuEnabled, isTrue);
    expect(settings.bilibiliDanmakuEnabled, isTrue);
    expect(json, contains('dandanplayDanmakuEnabled'));
    expect(json, contains('dandanplayAppId'));
    expect(json, contains('dandanplayAppSecret'));
    expect(json, contains('cinemetaEnabled'));
    expect(json, contains('watchHubEnabled'));
    expect(json['watchHubEnabled'], isFalse);
    expect(json, contains('peerTubeEnabled'));
    expect(json, contains('wikimediaCommonsEnabled'));
    expect(json['tmdbEnabled'], isTrue);
    expect(json, isNot(contains('tmdbLanguage')));
    expect(json, isNot(contains('tmdbToken')));
    expect(json, isNot(contains('tmdbApiKey')));
    expect(json, isNot(contains('traktEnabled')));
    expect(json, isNot(contains('openSubtitlesEnabled')));
    expect(json, isNot(contains('dandanplayEnabled')));

    final migrated = ExternalServiceSettings.fromJson({
      ...json,
      'watchHubEnabled': true,
    });
    expect(migrated.watchHubEnabled, isFalse);
  });

  test('danmaku stays off until the user opts in', () {
    expect(const DanmakuSettings().enabled, isFalse);
    expect(DanmakuSettings.fromJson(const {}).enabled, isFalse);
    expect(DanmakuSettings.fromJson(const {'enabled': true}).enabled, isTrue);
  });

  test('playback settings persist shortcut configuration', () {
    const settings = PlaybackSettings(
      superResolution: true,
      keyboardShortcutsEnabled: false,
      shortcutPlayPause: false,
      shortcutSeek: false,
      shortcutVolume: false,
      shortcutFullscreen: false,
      shortcutMute: false,
      shortcutReload: false,
    );

    final json = settings.toJson();
    final restored = PlaybackSettings.fromJson(json);

    expect(restored.superResolution, isTrue);
    expect(restored.keyboardShortcutsEnabled, isFalse);
    expect(restored.shortcutPlayPause, isFalse);
    expect(restored.shortcutSeek, isFalse);
    expect(restored.shortcutVolume, isFalse);
    expect(restored.shortcutFullscreen, isFalse);
    expect(restored.shortcutMute, isFalse);
    expect(restored.shortcutReload, isFalse);
  });

  test('dandanplay danmaku source parses matched episode results', () async {
    const subject = AnimeSubject(
      id: 1,
      title: '葬送的芙莉莲',
      originalTitle: 'Frieren',
      summary: 'summary',
      coverUrl: null,
      bannerUrl: null,
      date: '2023-09-29',
      platform: 'TV',
      language: '日语',
      region: '日本',
      status: '全28集',
      categories: [AnimeCategory(name: '动画')],
      tags: [AnimeTag(name: 'TV')],
      totalEpisodes: 28,
    );
    const episode = AnimeEpisode(
      id: 101,
      subjectId: 1,
      number: 1,
      title: '',
      airdate: '2023-09-29',
      duration: '24:00',
      description: '第一集',
    );
    final repo = ExternalServiceRepository(
      client: MockClient((request) async {
        if (request.url.path == '/api/v2/search/episodes') {
          expect(_headerValue(request, 'X-AppId'), 'app');
          expect(_headerValue(request, 'X-Timestamp'), isNotEmpty);
          expect(_headerValue(request, 'X-Signature'), isNotEmpty);
          expect(request.headers.keys, isNot(contains('X-AppSecret')));
          return http.Response(
            jsonEncode({
              'animes': [
                {
                  'animeTitle': '葬送的芙莉莲',
                  'episodes': [
                    {'episodeId': 12345, 'episodeTitle': '第1话 冒险结束'},
                  ],
                },
              ],
            }),
            200,
          );
        }
        if (request.url.path == '/api/v2/comment/12345') {
          return http.Response(jsonEncode({'count': 321, 'comments': []}), 200);
        }
        return http.Response(jsonEncode({'count': 321, 'comments': []}), 200);
      }),
    );

    final danmaku = await repo.matchDanmaku(
      subject,
      episode,
      const ExternalServiceSettings(
        dandanplayAppId: 'app',
        dandanplayAppSecret: 'secret',
        bilibiliDanmakuEnabled: false,
      ),
    );

    expect(danmaku.single.provider, '弹弹play');
    expect(danmaku.single.message, isNot(contains('凭证')));
    expect(danmaku.single.message, isNot(contains('需要')));
  });

  test(
    'verified built-in rules are installed and enabled by default',
    () async {
      const repository = RulePluginRepository();
      final state = repository.defaultState();
      final source = RulePlaybackSourceRepository(
        repository: repository,
        ruleState: state,
        resolver: RulePlaybackResolver(
          client: MockClient((_) async => http.Response('not found', 404)),
        ),
      );
      const episode = AnimeEpisode(
        id: 101,
        subjectId: 1,
        number: 1,
        title: '',
        airdate: '2026-01-01',
        duration: '24:00',
        description: '第一集',
      );

      final animeLines = await source.linesForEpisode(_animeSubject, episode);
      final seriesLines = await source.linesForEpisode(_seriesSubject, episode);
      final movieLines = await source.linesForEpisode(_movieSubject, episode);

      expect(repository.rulesFor(RuleContentType.anime), hasLength(3));
      expect(repository.rulesFor(RuleContentType.series), isEmpty);
      expect(repository.rulesFor(RuleContentType.movie), hasLength(2));
      expect(state.installedIds, contains('zeluna:recommended:fantuan'));
      expect(state.installedIds, contains('zeluna:recommended:aikanbot'));
      expect(state.installedIds, contains('zeluna:recommended:sorani'));
      expect(state.installedIds, contains('zeluna:recommended:dbku'));
      expect(state.installedIds, contains('zeluna:recommended:nivod'));
      expect(state.enabledIds, contains('zeluna:recommended:fantuan'));
      expect(state.enabledIds, contains('zeluna:recommended:aikanbot'));
      expect(state.enabledIds, contains('zeluna:recommended:sorani'));
      expect(state.enabledIds, contains('zeluna:recommended:dbku'));
      expect(state.enabledIds, contains('zeluna:recommended:nivod'));
      expect(animeLines, isNotEmpty);
      expect(seriesLines, hasLength(1));
      expect(movieLines, isNotEmpty);
    },
  );

  test('rule importer persists user repository rules as real plugins', () {
    final bundle = const RuleImporter().importFromText('''
{
  "name": "测试仓库",
  "rules": [
    {
      "id": "demo",
      "name": "Demo Rule",
      "source": "custom",
      "contentType": "anime",
      "engine": "native",
      "baseUrl": "https://example.com",
      "searchUrl": "https://example.com/search?wd=@keyword",
      "kazumi": {
        "searchList": "//div",
        "searchName": "//a",
        "searchResult": "//a",
        "chapterRoads": "//ul",
        "chapterResult": "//li/a"
      }
    }
  ]
}
''');
    final repository = RulePluginRepository(extraRules: bundle.rules);

    expect(bundle.name, '测试仓库');
    expect(bundle.rules.single.id, 'custom:demo');
    expect(repository.byId('custom:demo'), isNotNull);
    expect(
      repository.rulesFor(RuleContentType.anime).map((rule) => rule.name),
      contains('Demo Rule'),
    );
  });

  test('rule playback source uses quick and expanded lookup modes', () async {
    final requestedHosts = <String>[];
    final rules = List.generate(
      10,
      (index) => _animekoLookupRule(
        id: 'custom:animeko:bulk$index',
        name: 'Bulk $index',
        host: 'rule$index.example',
        groupId: 'repo:creamycake-css1',
        priority: index,
      ),
    );
    final repository = RulePluginRepository(extraRules: rules);
    final source = RulePlaybackSourceRepository(
      repository: repository,
      ruleState: RulePluginState(
        installedIds: rules.map((rule) => rule.id).toSet(),
        enabledIds: rules.map((rule) => rule.id).toSet(),
        customRules: rules,
      ),
      resolver: RulePlaybackResolver(
        client: MockClient((request) async {
          requestedHosts.add(request.url.host);
          return http.Response('not found', 404);
        }),
      ),
    );

    final quickLines = await source.linesForEpisode(_animeSubject, _episode);

    final quickHosts = requestedHosts.toSet().toList(growable: false);
    expect(quickHosts, hasLength(6));
    expect(quickHosts, [
      'rule0.example',
      'rule1.example',
      'rule2.example',
      'rule3.example',
      'rule4.example',
      'rule5.example',
    ]);
    expect(
      quickLines.map((line) => line.providerName),
      isNot(contains('Bulk 6')),
    );

    requestedHosts.clear();
    final expandedLines = await source.linesForEpisodeMode(
      _animeSubject,
      _episode,
      expandAll: true,
    );

    final expandedHosts = requestedHosts.toSet().toList(growable: false);
    expect(expandedHosts, hasLength(10));
    expect(expandedHosts, [
      for (var index = 0; index < 10; index++) 'rule$index.example',
    ]);
    expect(expandedHosts.last, 'rule9.example');
    expect(expandedLines.map((line) => line.providerName), contains('Bulk 9'));
  });

  test(
    'rule playback source preserves public-only safety through latency copy and cache',
    () async {
      RulePlaybackSourceRepository.clearRuntimeCaches();
      addTearDown(RulePlaybackSourceRepository.clearRuntimeCaches);
      final rule = _animekoLookupRule(
        id: 'custom:public-only-copy',
        name: 'Public only copy',
        host: 'public-only.example',
        groupId: 'test:public-only-copy',
        priority: 0,
      );
      final repository = RulePluginRepository(extraRules: [rule]);
      final source = RulePlaybackSourceRepository(
        repository: repository,
        ruleState: RulePluginState(
          installedIds: {rule.id},
          enabledIds: {rule.id},
          customRules: [rule],
        ),
        resolver: _PublicOnlyLineResolver(),
        cacheNamespace: 'test:public-only-copy',
      );

      final first = await source.linesForEpisode(_animeSubject, _episode);
      final cached = await source.linesForEpisode(_animeSubject, _episode);

      expect(first.single.latency, isNotNull);
      expect(first.single.publicHttpOnly, isTrue);
      expect(cached.single.publicHttpOnly, isTrue);
    },
  );

  test(
    'quick rule lookup returns a fast playable line without waiting for slow rules',
    () async {
      final rules = List.generate(
        5,
        (index) => _animekoLookupRule(
          id: 'custom:animeko:quick-performance-$index',
          name: 'Quick performance $index',
          host: 'quick-performance-$index.example',
          groupId: 'group:$index',
          priority: index == 4 ? -100 : index,
          quickSearch: index != 4,
        ),
      );
      final resolver = _DelayedRulePlaybackResolver(
        delays: {
          rules[0].id: const Duration(milliseconds: 600),
          rules[1].id: const Duration(milliseconds: 20),
          rules[2].id: const Duration(milliseconds: 600),
          rules[3].id: const Duration(milliseconds: 600),
          rules[4].id: Duration.zero,
        },
        availableRuleIds: {rules[1].id},
      );
      final source = RulePlaybackSourceRepository(
        repository: RulePluginRepository(extraRules: rules),
        ruleState: RulePluginState(
          installedIds: rules.map((rule) => rule.id).toSet(),
          enabledIds: rules.map((rule) => rule.id).toSet(),
          customRules: rules,
        ),
        resolver: resolver,
      );

      final stopwatch = Stopwatch()..start();
      final lines = await source.linesForEpisode(_animeSubject, _episode);
      stopwatch.stop();

      expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 500)));
      expect(resolver.calls, hasLength(4));
      expect(resolver.calls, isNot(contains(rules[4].id)));
      expect(resolver.maxActive, 4);
      expect(
        lines.where((line) => line.available).map((line) => line.providerId),
        contains(rules[1].id),
      );

      await Future<void>.delayed(const Duration(milliseconds: 650));
      resolver.calls.clear();
      const nextEpisode = AnimeEpisode(
        id: 102,
        subjectId: 1,
        number: 2,
        title: '',
        airdate: '2026-01-08',
        duration: '24:00',
        description: 'second episode',
      );
      await source.linesForEpisode(_animeSubject, nextEpisode);
      expect(resolver.calls.first, rules[1].id);
      await Future<void>.delayed(const Duration(milliseconds: 650));
    },
  );

  test(
    'quick and expanded rule lookups keep verification caches separate',
    () async {
      final rule = _animekoLookupRule(
        id: 'custom:animeko:verification-cache',
        name: 'Verification cache',
        host: 'verification-cache.example',
        groupId: 'verification-cache',
        priority: 0,
      );
      final resolver = _DelayedRulePlaybackResolver(
        delays: {rule.id: Duration.zero},
        availableRuleIds: {rule.id},
      );
      final source = RulePlaybackSourceRepository(
        repository: RulePluginRepository(extraRules: [rule]),
        ruleState: RulePluginState(
          installedIds: {rule.id},
          enabledIds: {rule.id},
          customRules: [rule],
        ),
        resolver: resolver,
      );

      await source.linesForEpisode(_animeSubject, _episode);
      await source.linesForEpisodeMode(
        _animeSubject,
        _episode,
        expandAll: true,
      );

      expect(resolver.calls, [rule.id, rule.id]);
      expect(resolver.verifyPlayableCalls, [false, true]);
    },
  );

  test('rule lookup caches isolate accounts and skip private rules', () async {
    RulePlaybackSourceRepository.clearRuntimeCaches();
    addTearDown(RulePlaybackSourceRepository.clearRuntimeCaches);
    final baseRule = _animekoLookupRule(
      id: 'custom:animeko:account-cache',
      name: 'Account cache',
      host: 'account-cache.example',
      groupId: 'account-cache',
      priority: 0,
    );
    final resolver = _DelayedRulePlaybackResolver(
      delays: {baseRule.id: Duration.zero},
      availableRuleIds: {baseRule.id},
    );

    RulePlaybackSourceRepository sourceFor(
      RulePlugin rule,
      String cacheNamespace,
    ) {
      return RulePlaybackSourceRepository(
        repository: RulePluginRepository(extraRules: [rule]),
        ruleState: RulePluginState(
          installedIds: {rule.id},
          enabledIds: {rule.id},
          customRules: [rule],
        ),
        resolver: resolver,
        cacheNamespace: cacheNamespace,
      );
    }

    final accountA = sourceFor(baseRule, 'account-a:1');
    await accountA.linesForEpisode(_animeSubject, _episode);
    await accountA.linesForEpisode(_animeSubject, _episode);
    expect(resolver.calls, [baseRule.id]);

    final accountB = sourceFor(baseRule, 'account-b:1');
    await accountB.linesForEpisode(_animeSubject, _episode);
    expect(resolver.calls, [baseRule.id, baseRule.id]);

    final changedConfig = baseRule.copyWith(
      requestHeaders: const {'X-Variant': 'new-config'},
    );
    await sourceFor(
      changedConfig,
      'account-a:1',
    ).linesForEpisode(_animeSubject, _episode);
    expect(resolver.calls, [baseRule.id, baseRule.id, baseRule.id]);

    final privateRule = baseRule.copyWith(
      requestHeaders: const {'Cookie': 'session=private'},
    );
    final privateSource = sourceFor(privateRule, 'account-private:1');
    await privateSource.linesForEpisode(_animeSubject, _episode);
    await privateSource.linesForEpisode(_animeSubject, _episode);
    expect(resolver.calls, [
      baseRule.id,
      baseRule.id,
      baseRule.id,
      baseRule.id,
      baseRule.id,
    ]);
  });

  test('successful episode cache survives Chinese title enrichment', () async {
    final rule = _animekoLookupRule(
      id: 'custom:animeko:title-enrichment-cache',
      name: 'Title enrichment cache',
      host: 'title-enrichment-cache.example',
      groupId: 'title-enrichment-cache',
      priority: 0,
    );
    final resolver = _DelayedRulePlaybackResolver(
      delays: {rule.id: Duration.zero},
      availableRuleIds: {rule.id},
    );
    final source = RulePlaybackSourceRepository(
      repository: RulePluginRepository(extraRules: [rule]),
      ruleState: RulePluginState(
        installedIds: {rule.id},
        enabledIds: {rule.id},
        customRules: [rule],
      ),
      resolver: resolver,
      cacheNamespace: 'title-enrichment-cache-test',
    );

    await source.linesForEpisode(_animeSubject, _episode);
    await source.linesForEpisode(
      AnimeSubject.fromJson({..._animeSubject.toJson(), 'title': '测试番剧（中文增强）'}),
      _episode,
    );

    expect(resolver.calls, [rule.id]);
  });

  test(
    'quick lookup budget cancels unfinished rule waves instead of caching them',
    () async {
      final rules = List.generate(
        8,
        (index) => _animekoLookupRule(
          id: 'custom:animeko:budget-$index',
          name: 'Budget $index',
          host: 'budget-$index.example',
          groupId: 'budget-group:$index',
          priority: index,
        ),
      );
      final resolver = _DelayedRulePlaybackResolver(
        delays: {
          for (var index = 0; index < rules.length; index++)
            rules[index].id: index < 4
                ? Duration.zero
                : const Duration(milliseconds: 500),
        },
      );
      final source = RulePlaybackSourceRepository(
        repository: RulePluginRepository(extraRules: rules),
        ruleState: RulePluginState(
          installedIds: rules.map((rule) => rule.id).toSet(),
          enabledIds: rules.map((rule) => rule.id).toSet(),
          customRules: rules,
        ),
        resolver: resolver,
        quickLookupBudget: const Duration(milliseconds: 120),
      );

      final stopwatch = Stopwatch()..start();
      await source.linesForEpisode(_animeSubject, _episode);
      stopwatch.stop();

      expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 350)));
      expect(resolver.calls, hasLength(8));
      expect(resolver.verifyPlayableCalls, everyElement(isFalse));

      await Future<void>.delayed(const Duration(milliseconds: 550));
      resolver.calls.clear();
      resolver.verifyPlayableCalls.clear();
      await source.linesForEpisode(_animeSubject, _episode);
      expect(resolver.calls, [
        rules[4].id,
        rules[5].id,
        rules[6].id,
        rules[7].id,
      ]);
    },
  );

  test(
    'expanded rule lookup scans every rule with bounded concurrency',
    () async {
      final rules = List.generate(
        52,
        (index) => _animekoLookupRule(
          id: 'custom:animeko:expanded-performance-$index',
          name: 'Expanded performance $index',
          host: 'expanded-performance-$index.example',
          groupId: 'expanded-group:$index',
          priority: index,
        ),
      );
      final resolver = _DelayedRulePlaybackResolver(
        delays: {
          for (final rule in rules) rule.id: const Duration(milliseconds: 8),
        },
      );
      final source = RulePlaybackSourceRepository(
        repository: RulePluginRepository(extraRules: rules),
        ruleState: RulePluginState(
          installedIds: rules.map((rule) => rule.id).toSet(),
          enabledIds: rules.map((rule) => rule.id).toSet(),
          customRules: rules,
        ),
        resolver: resolver,
      );

      final lines = await source.linesForEpisodeMode(
        _animeSubject,
        _episode,
        expandAll: true,
      );

      expect(resolver.calls, hasLength(52));
      expect(resolver.maxActive, 6);
      expect(lines, hasLength(52));
      expect(lines.last.providerId, rules.last.id);
    },
  );

  test(
    'progressive lookup emits a fast line before slower sources and completes the inventory',
    () async {
      final rules = List.generate(
        3,
        (index) => _animekoLookupRule(
          id: 'custom:animeko:progressive-$index',
          name: 'Progressive $index',
          host: 'progressive-$index.example',
          groupId: 'progressive-group:$index',
          priority: index,
        ),
      );
      final resolver = _DelayedRulePlaybackResolver(
        delays: {
          rules[0].id: const Duration(milliseconds: 15),
          rules[1].id: const Duration(milliseconds: 90),
          rules[2].id: const Duration(milliseconds: 150),
        },
        availableRuleIds: rules.map((rule) => rule.id).toSet(),
      );
      final source = RulePlaybackSourceRepository(
        repository: RulePluginRepository(extraRules: rules),
        ruleState: RulePluginState(
          installedIds: rules.map((rule) => rule.id).toSet(),
          enabledIds: rules.map((rule) => rule.id).toSet(),
          customRules: rules,
        ),
        resolver: resolver,
        cacheNamespace: 'progressive-test',
      );
      final updates = <PlaybackLineLookupUpdate>[];
      final stopwatch = Stopwatch()..start();
      Duration? firstUpdateAt;

      await source.lineUpdatesForEpisode(_animeSubject, _episode).listen((
        update,
      ) {
        updates.add(update);
        firstUpdateAt ??= stopwatch.elapsed;
      }).asFuture<void>();
      stopwatch.stop();

      expect(firstUpdateAt, isNotNull);
      expect(firstUpdateAt!, lessThan(const Duration(milliseconds: 80)));
      expect(updates.first.phase, PlaybackLineLookupPhase.discovery);
      expect(updates.first.lines.where((line) => line.available), hasLength(1));
      expect(updates.first.lines.single.latency, isNotNull);
      expect(updates.last.isComplete, isTrue);
      expect(updates.last.lines.where((line) => line.available), hasLength(3));
      expect(resolver.calls, hasLength(6));
      expect(
        resolver.verifyPlayableCalls.where((value) => value),
        hasLength(3),
      );
    },
  );

  test(
    'progressive verification removes an optimistic provider result',
    () async {
      final rule = _animekoLookupRule(
        id: 'custom:animeko:progressive-removed',
        name: 'Progressive removed',
        host: 'progressive-removed.example',
        groupId: 'progressive-removed',
        priority: 0,
      );
      final resolver = _DelayedRulePlaybackResolver(
        delays: {rule.id: Duration.zero},
        availableRuleIds: {rule.id},
        emptyVerifiedRuleIds: {rule.id},
      );
      final source = RulePlaybackSourceRepository(
        repository: RulePluginRepository(extraRules: [rule]),
        ruleState: RulePluginState(
          installedIds: {rule.id},
          enabledIds: {rule.id},
          customRules: [rule],
        ),
        resolver: resolver,
        cacheNamespace: 'progressive-removal-test',
      );
      final updates = await source
          .lineUpdatesForEpisode(_animeSubject, _episode)
          .toList();

      expect(updates.first.lines.single.providerId, rule.id);
      final verified = updates.firstWhere(
        (update) => update.phase == PlaybackLineLookupPhase.verification,
      );
      expect(verified.resolvedProviderId, rule.id);
      expect(verified.lines, isEmpty);
      expect(updates.last.isComplete, isTrue);
      expect(updates.last.lines, isEmpty);
    },
  );

  test(
    'progressive discovery resumes after short time slices and scans every rule',
    () async {
      final rules = List.generate(
        14,
        (index) => _animekoLookupRule(
          id: 'custom:animeko:progressive-slice-$index',
          name: 'Progressive slice $index',
          host: 'progressive-slice-$index.example',
          groupId: 'progressive-slice-group:$index',
          priority: index,
        ),
      );
      final resolver = _DelayedRulePlaybackResolver(
        delays: {
          for (final rule in rules) rule.id: const Duration(milliseconds: 20),
        },
        availableRuleIds: {rules.last.id},
      );
      final source = RulePlaybackSourceRepository(
        repository: RulePluginRepository(extraRules: rules),
        ruleState: RulePluginState(
          installedIds: rules.map((rule) => rule.id).toSet(),
          enabledIds: rules.map((rule) => rule.id).toSet(),
          customRules: rules,
        ),
        resolver: resolver,
        progressiveDiscoveryTimeSlice: const Duration(milliseconds: 3),
        progressiveVerificationTimeSlice: const Duration(milliseconds: 3),
        progressiveDiscoveryRuleTimeout: const Duration(milliseconds: 200),
        progressiveVerificationRuleTimeout: const Duration(milliseconds: 200),
        cacheNamespace: 'progressive-slice-test',
      );

      final updates = await source
          .lineUpdatesForEpisode(_animeSubject, _episode)
          .toList();
      final discoveryUpdates = updates
          .where((update) => update.phase == PlaybackLineLookupPhase.discovery)
          .toList(growable: false);
      final discoveryRuleIds = <String>[
        for (var index = 0; index < resolver.calls.length; index++)
          if (!resolver.verifyPlayableCalls[index]) resolver.calls[index],
      ];
      final verifiedRuleIds = <String>[
        for (var index = 0; index < resolver.calls.length; index++)
          if (resolver.verifyPlayableCalls[index]) resolver.calls[index],
      ];

      expect(discoveryUpdates, hasLength(rules.length));
      expect(discoveryUpdates.last.completedRules, rules.length);
      expect(
        discoveryUpdates.map((update) => update.totalRules),
        everyElement(rules.length),
      );
      expect(discoveryRuleIds.toSet(), rules.map((rule) => rule.id).toSet());
      expect(verifiedRuleIds, [rules.last.id]);
      expect(resolver.maxActive, 6);
      expect(updates.last.isComplete, isTrue);
      expect(updates.last.completedRules, rules.length);
      expect(updates.last.totalRules, rules.length);
      expect(
        updates.last.lines
            .singleWhere((line) => line.providerId == rules.last.id)
            .available,
        isTrue,
      );
    },
  );

  test(
    'progressive verification only revisits providers with available candidates',
    () async {
      final rules = List.generate(
        4,
        (index) => _animekoLookupRule(
          id: 'custom:animeko:progressive-candidates-$index',
          name: 'Progressive candidates $index',
          host: 'progressive-candidates-$index.example',
          groupId: 'progressive-candidates-group:$index',
          priority: index,
        ),
      );
      final candidateIds = {rules[0].id, rules[2].id};
      final resolver = _DelayedRulePlaybackResolver(
        delays: {for (final rule in rules) rule.id: Duration.zero},
        availableRuleIds: candidateIds,
      );
      final source = RulePlaybackSourceRepository(
        repository: RulePluginRepository(extraRules: rules),
        ruleState: RulePluginState(
          installedIds: rules.map((rule) => rule.id).toSet(),
          enabledIds: rules.map((rule) => rule.id).toSet(),
          customRules: rules,
        ),
        resolver: resolver,
        cacheNamespace: 'progressive-candidates-test',
      );

      final updates = await source
          .lineUpdatesForEpisode(_animeSubject, _episode)
          .toList();
      final verificationUpdates = updates
          .where(
            (update) => update.phase == PlaybackLineLookupPhase.verification,
          )
          .toList(growable: false);
      final verifiedRuleIds = <String>[
        for (var index = 0; index < resolver.calls.length; index++)
          if (resolver.verifyPlayableCalls[index]) resolver.calls[index],
      ];

      expect(verifiedRuleIds.toSet(), candidateIds);
      expect(verifiedRuleIds, hasLength(candidateIds.length));
      expect(verificationUpdates, hasLength(candidateIds.length));
      expect(
        verificationUpdates.map((update) => update.totalRules),
        everyElement(candidateIds.length),
      );
      expect(verificationUpdates.last.completedRules, candidateIds.length);
      expect(updates.last.isComplete, isTrue);
    },
  );

  test(
    'progressive rule timeout stays visible as an unavailable line',
    () async {
      final rule = _animekoLookupRule(
        id: 'custom:animeko:progressive-timeout',
        name: 'Progressive timeout',
        host: 'progressive-timeout.example',
        groupId: 'progressive-timeout',
        priority: 0,
      );
      final resolver = _DelayedRulePlaybackResolver(
        delays: {rule.id: const Duration(milliseconds: 60)},
        availableRuleIds: {rule.id},
      );
      final source = RulePlaybackSourceRepository(
        repository: RulePluginRepository(extraRules: [rule]),
        ruleState: RulePluginState(
          installedIds: {rule.id},
          enabledIds: {rule.id},
          customRules: [rule],
        ),
        resolver: resolver,
        progressiveDiscoveryTimeSlice: const Duration(milliseconds: 2),
        progressiveDiscoveryRuleTimeout: const Duration(milliseconds: 8),
        cacheNamespace: 'progressive-timeout-test',
      );

      final updates = await source
          .lineUpdatesForEpisode(_animeSubject, _episode)
          .toList();
      final timeoutUpdate = updates.firstWhere(
        (update) => update.phase == PlaybackLineLookupPhase.discovery,
      );
      final timeoutLine = updates.last.lines.single;

      expect(timeoutUpdate.completedRules, 1);
      expect(timeoutUpdate.totalRules, 1);
      expect(timeoutUpdate.timedOut, isTrue);
      expect(timeoutLine.providerId, rule.id);
      expect(timeoutLine.available, isFalse);
      expect(timeoutLine.url, isNull);
      expect(timeoutLine.message, contains('检索超时'));
      expect(updates.last.isComplete, isTrue);
      expect(updates.last.timedOut, isTrue);
      expect(resolver.verifyPlayableCalls, everyElement(isFalse));
    },
  );

  test('cancelling progressive lookup stops dispatching new rules', () async {
    final rules = List.generate(
      10,
      (index) => _animekoLookupRule(
        id: 'custom:animeko:cancel-$index',
        name: 'Cancel $index',
        host: 'cancel-$index.example',
        groupId: 'cancel-group:$index',
        priority: index,
      ),
    );
    final resolver = _DelayedRulePlaybackResolver(
      delays: {
        rules.first.id: const Duration(milliseconds: 10),
        for (final rule in rules.skip(1))
          rule.id: const Duration(milliseconds: 120),
      },
      availableRuleIds: rules.map((rule) => rule.id).toSet(),
    );
    final source = RulePlaybackSourceRepository(
      repository: RulePluginRepository(extraRules: rules),
      ruleState: RulePluginState(
        installedIds: rules.map((rule) => rule.id).toSet(),
        enabledIds: rules.map((rule) => rule.id).toSet(),
        customRules: rules,
      ),
      resolver: resolver,
      cacheNamespace: 'progressive-cancel-test',
    );
    final firstUpdate = Completer<void>();
    final cancellationToken = RulePlaybackCancellationToken();
    final subscription = source
        .lineUpdatesForEpisode(
          _animeSubject,
          _episode,
          cancellationToken: cancellationToken,
        )
        .listen((_) {
          if (!firstUpdate.isCompleted) firstUpdate.complete();
        });

    await firstUpdate.future;
    await subscription.cancel();
    final callsAtCancellation = resolver.calls.length;
    await Future<void>.delayed(const Duration(milliseconds: 180));

    expect(cancellationToken.isCancelled, isTrue);
    expect(callsAtCancellation, lessThan(rules.length));
    expect(resolver.calls, hasLength(callsAtCancellation));
    expect(resolver.verifyPlayableCalls, everyElement(isFalse));
  });
}

const _animeSubject = AnimeSubject(
  id: 1,
  title: '测试番剧',
  originalTitle: 'Test Anime',
  summary: 'summary',
  coverUrl: null,
  bannerUrl: null,
  date: '2026-01-01',
  platform: 'TV',
  language: '日语',
  region: '日本',
  status: '全12集',
  categories: [AnimeCategory(name: '动画')],
  tags: [AnimeTag(name: '番剧')],
  totalEpisodes: 12,
);

const _seriesSubject = AnimeSubject(
  id: 169,
  title: 'Breaking Bad',
  originalTitle: 'Breaking Bad',
  summary: 'summary',
  coverUrl: null,
  bannerUrl: null,
  date: '2008-01-20',
  platform: 'Scripted',
  language: 'English',
  region: 'United States',
  status: 'Ended',
  categories: [AnimeCategory(name: 'Drama')],
  tags: [AnimeTag(name: 'TVMaze')],
  totalEpisodes: 62,
  source: 'tvmaze',
);

const _movieSubject = AnimeSubject(
  id: 2875,
  title: 'Inception',
  originalTitle: 'Inception',
  summary: 'summary',
  coverUrl: null,
  bannerUrl: null,
  date: '2010-07-08',
  platform: 'Movie',
  language: 'English',
  region: 'United States',
  status: '电影',
  categories: [AnimeCategory(name: '电影')],
  tags: [AnimeTag(name: 'Wikidata')],
  totalEpisodes: 1,
  source: 'wikidata',
);

const _episode = AnimeEpisode(
  id: 101,
  subjectId: 1,
  number: 1,
  title: '',
  airdate: '2026-01-01',
  duration: '24:00',
  description: '第一集',
);

RulePlugin _animekoLookupRule({
  required String id,
  required String name,
  required String host,
  required String groupId,
  required int priority,
  bool quickSearch = true,
}) {
  return RulePlugin(
    id: id,
    name: name,
    version: '2',
    source: RuleSourceKind.custom,
    contentType: RuleContentType.anime,
    engine: 'animeko-web-selector',
    updatedAt: DateTime(2026, 5, 6),
    qualityScore: 80,
    tags: const ['Animeko', 'CSS'],
    baseUrl: 'https://$host/',
    searchUrl: 'https://$host/search?wd={keyword}',
    searchable: true,
    quickSearch: quickSearch,
    filterable: false,
    groupId: groupId,
    priority: priority,
    animeko: AnimekoWebSelectorConfig(
      searchUrl: 'https://$host/search?wd={keyword}',
      subjectFormatId: 'a',
      channelFormatId: 'index-grouped',
      subjectA: const AnimekoSubjectAConfig(selectLists: '.result a'),
      channelFlattened: const AnimekoChannelFlattenedConfig(
        selectEpisodeLists: '.playlist',
        selectEpisodesFromList: 'a',
        matchEpisodeSortFromName: r'(?<ep>\d+)',
      ),
      matchVideoUrl: r'(?<v>https?:\/\/.+\.(m3u8|mp4))',
    ),
  );
}

String? _headerValue(http.BaseRequest request, String name) {
  final normalized = name.toLowerCase();
  for (final entry in request.headers.entries) {
    if (entry.key.toLowerCase() == normalized) return entry.value;
  }
  return null;
}

class _DelayedRulePlaybackResolver extends RulePlaybackResolver {
  _DelayedRulePlaybackResolver({
    required this.delays,
    this.availableRuleIds = const {},
    this.emptyVerifiedRuleIds = const {},
  });

  final Map<String, Duration> delays;
  final Set<String> availableRuleIds;
  final Set<String> emptyVerifiedRuleIds;
  final List<String> calls = <String>[];
  final List<bool> verifyPlayableCalls = <bool>[];
  int active = 0;
  int maxActive = 0;

  @override
  Future<List<PlaybackLine>> resolveRule({
    required RulePlugin rule,
    required AnimeSubject subject,
    required AnimeEpisode episode,
    bool verifyPlayable = true,
    RulePlaybackCancellationToken? cancellationToken,
  }) async {
    calls.add(rule.id);
    verifyPlayableCalls.add(verifyPlayable);
    active++;
    if (active > maxActive) maxActive = active;
    try {
      await Future<void>.delayed(delays[rule.id] ?? Duration.zero);
      if (verifyPlayable && emptyVerifiedRuleIds.contains(rule.id)) {
        return const [];
      }
      final available = availableRuleIds.contains(rule.id);
      return [
        PlaybackLine(
          id: '${rule.id}:${episode.id}',
          episodeId: episode.id,
          providerId: rule.id,
          providerName: rule.name,
          title: '${subject.title} ${episode.number}',
          quality: available ? '1080P' : 'unknown',
          format: available ? 'HLS' : 'unknown',
          url: available
              ? 'https://${rule.id.hashCode}.example/video.m3u8'
              : null,
          available: available,
          message: available ? null : 'not found',
        ),
      ];
    } finally {
      active--;
    }
  }
}

class _PublicOnlyLineResolver extends RulePlaybackResolver {
  @override
  Future<List<PlaybackLine>> resolveRule({
    required RulePlugin rule,
    required AnimeSubject subject,
    required AnimeEpisode episode,
    bool verifyPlayable = true,
    RulePlaybackCancellationToken? cancellationToken,
  }) async {
    return [
      PlaybackLine(
        id: '${rule.id}:${episode.id}',
        episodeId: episode.id,
        providerId: rule.id,
        providerName: rule.name,
        title: episode.displayTitle,
        quality: '1080P',
        format: 'MP4',
        url: 'https://media.example/video.mp4',
        publicHttpOnly: true,
        available: true,
      ),
    ];
  }
}
