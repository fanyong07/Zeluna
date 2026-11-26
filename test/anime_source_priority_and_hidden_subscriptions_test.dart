import 'package:anime/src/data/playback_source_repository.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/playback/local_route_ranker.dart';
import 'package:anime/src/playback/playback_discovery_controller.dart';
import 'package:anime/src/player/playback_line_display.dart';
import 'package:anime/src/rules/bundled_community_subscriptions.dart';
import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/rules/rule_playback_resolver.dart';
import 'package:anime/src/rules/rule_plugin_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  tearDown(() {
    LocalRouteRanker.instance.resetForTesting();
    RulePlaybackSourceRepository.clearRuntimeCaches();
  });

  test(
    'anime quick lookup prioritizes dedicated anime rules over TVBox resource sites',
    () async {
      final requestedHosts = <String>[];
      final tvboxResourceRules = List.generate(
        8,
        (i) => _rule(
          id: 'custom:tvbox:resource-$i',
          name: '测试资源$i',
          engine: 'tvbox',
          host: 'resource-$i.example',
          groupId: 'repo:lunatv',
          priority:
              1, // Even with higher static priority, anime demotes resource sites
          contentType: RuleContentType.anime,
        ),
      );
      final dedicatedAnimeRules = List.generate(
        12,
        (i) => _rule(
          id: 'custom:animeko:site-$i',
          name: '专属动漫$i',
          engine: 'animeko-http',
          host: 'anime-$i.example',
          groupId: i < 6 ? 'repo:kazumi' : 'repo:animeko',
          priority: 20 + i,
          contentType: RuleContentType.anime,
        ),
      );
      final allRules = [...tvboxResourceRules, ...dedicatedAnimeRules];
      final repo = RulePlaybackSourceRepository(
        repository: RulePluginRepository(extraRules: allRules),
        ruleState: _approvedState(allRules),
        resolver: RulePlaybackResolver(
          client: MockClient((request) async {
            requestedHosts.add(request.url.host);
            return http.Response('not found', 404);
          }),
        ),
        cacheNamespace: 'anime-priority-test',
      );

      await repo.linesForEpisode(_animeSubject, _episode);

      final hosts = requestedHosts.toSet();
      expect(hosts, hasLength(12));
      expect(
        hosts.where((host) => host.startsWith('anime-')),
        hasLength(12),
        reason:
            'Dedicated anime rules should fill all 12 quick lookup slots first.',
      );
      expect(
        hosts.where((host) => host.startsWith('resource-')),
        isEmpty,
        reason:
            'TVBox 某某资源 sites should stay fallback-only when dedicated anime rules fill quick lookup.',
      );
    },
  );

  test(
    'anime falls back to TVBox resource rules when dedicated anime rules are scarce',
    () async {
      final requestedHosts = <String>[];
      final rules = [
        _rule(
          id: 'custom:tvbox:ikun',
          name: 'iKun资源',
          engine: 'tvbox',
          host: 'ikun.example',
          groupId: 'repo:lunatv',
          priority: 1,
          contentType: RuleContentType.anime,
        ),
        _rule(
          id: 'custom:animeko:sakura',
          name: '樱花动漫',
          engine: 'animeko-http',
          host: 'sakura.example',
          groupId: 'repo:animeko',
          priority: 20,
          contentType: RuleContentType.anime,
        ),
      ];
      final repo = RulePlaybackSourceRepository(
        repository: RulePluginRepository(extraRules: rules),
        ruleState: _approvedState(rules),
        resolver: RulePlaybackResolver(
          client: MockClient((request) async {
            requestedHosts.add(request.url.host);
            return http.Response('not found', 404);
          }),
        ),
        cacheNamespace: 'anime-fallback-test',
      );

      await repo.linesForEpisode(_animeSubject, _episode);

      expect(
        requestedHosts.toSet(),
        containsAll(['sakura.example', 'ikun.example']),
      );
    },
  );

  test(
    'series quick lookup keeps TVBox resource rules active at normal priority',
    () async {
      final requestedHosts = <String>[];
      final rules = [
        _rule(
          id: 'custom:tvbox:series-ikun',
          name: 'iKun资源',
          engine: 'tvbox',
          host: 'series-ikun.example',
          groupId: 'repo:lunatv',
          priority: 1,
          contentType: RuleContentType.series,
        ),
        ...List.generate(
          12,
          (i) => _rule(
            id: 'custom:series:site-$i',
            name: '剧集站$i',
            engine: 'animeko-http',
            host: 'series-site-$i.example',
            groupId: 'repo:series',
            priority: 20 + i,
            contentType: RuleContentType.series,
          ),
        ),
      ];
      final repo = RulePlaybackSourceRepository(
        repository: RulePluginRepository(extraRules: rules),
        ruleState: _approvedState(rules),
        resolver: RulePlaybackResolver(
          client: MockClient((request) async {
            requestedHosts.add(request.url.host);
            return http.Response('not found', 404);
          }),
        ),
        cacheNamespace: 'series-priority-test',
      );

      await repo.linesForEpisode(_seriesSubject, _episode);
      expect(requestedHosts, contains('series-ikun.example'));
    },
  );

  test(
    'dedicated anime sites rank ahead of 某某资源 sites in both startup and display order',
    () {
      const resourceFast = PlaybackLine(
        id: 'ikun',
        episodeId: 1,
        providerId: 'custom:tvbox:ikun',
        providerName: 'iKun资源',
        title: 'iKun资源',
        quality: '1080P',
        format: 'HLS',
        url: 'https://vip.lzcdn.test/ep1.m3u8',
        available: true,
        serverVerified: true,
        latency: Duration(milliseconds: 180),
      );
      const haohuaFast = PlaybackLine(
        id: 'haohua',
        episodeId: 1,
        providerId: 'aggregate.maccms',
        providerName: '豪华',
        title: '豪华',
        quality: '1080P',
        format: 'HLS',
        url: 'https://hh.cdn.test/ep1.m3u8',
        available: true,
        serverVerified: true,
        latency: Duration(milliseconds: 220),
      );
      const ageAnime = PlaybackLine(
        id: 'age',
        episodeId: 1,
        providerId: 'crawler.age',
        providerName: 'AGE动漫',
        title: 'AGE动漫',
        quality: '1080P',
        format: 'HLS',
        url: 'https://age.cdn.test/ep1.m3u8',
        available: true,
        serverVerified: true,
        latency: Duration(milliseconds: 380),
      );
      const sakuraAnime = PlaybackLine(
        id: 'sakura',
        episodeId: 1,
        providerId: 'crawler.yhdmm',
        providerName: '樱花动漫',
        title: '樱花动漫',
        quality: '1080P',
        format: 'HLS',
        url: 'https://sakura.cdn.test/ep1.m3u8',
        available: true,
        serverVerified: true,
        latency: Duration(milliseconds: 410),
      );

      final ranker = LocalRouteRanker.instance;
      expect(LocalRouteRanker.isResourceCollectionLine(resourceFast), isTrue);
      expect(LocalRouteRanker.isResourceCollectionLine(haohuaFast), isTrue);
      expect(LocalRouteRanker.isResourceCollectionLine(ageAnime), isFalse);
      expect(ranker.cleanlinessTierOf(ageAnime), RouteCleanlinessTier.clean);
      expect(ranker.cleanlinessTierOf(sakuraAnime), RouteCleanlinessTier.clean);
      expect(
        ranker.cleanlinessTierOf(resourceFast),
        RouteCleanlinessTier.cleanable,
      );
      expect(
        ranker.cleanlinessTierOf(haohuaFast),
        RouteCleanlinessTier.cleanable,
      );

      final startup = rankPlaybackLinesForStartup([
        resourceFast,
        haohuaFast,
        sakuraAnime,
        ageAnime,
      ]);
      expect(startup.map((l) => l.id).toList(), [
        'age',
        'sakura',
        'ikun',
        'haohua',
      ]);

      final display = sortPlaybackLinesForDisplay([
        resourceFast,
        haohuaFast,
        sakuraAnime,
        ageAnime,
      ]);
      expect(display.map((l) => l.id).toList(), [
        'age',
        'sakura',
        'ikun',
        'haohua',
      ]);
    },
  );

  test(
    'bundled community visibility filters hide internal seeds but keep user rules',
    () {
      const managedUrl = 'zeluna://managed/default-rules';
      const externalManagedUrl = 'https://managed-sub.example/feed.json';
      final seededRule = _rule(
        id: 'custom:tvbox:ikun',
        name: 'iKun资源',
        engine: 'tvbox',
        host: 'ikun.example',
        groupId: 'repo:managed',
        priority: 1,
        contentType: RuleContentType.anime,
        sourceRepository: externalManagedUrl,
      ).copyWith(managedInternal: true);
      final repoMatchedRule = _rule(
        id: 'custom:tvbox:legacy-managed',
        name: '旧资源',
        engine: 'tvbox',
        host: 'legacy.example',
        groupId: 'repo:managed',
        priority: 2,
        contentType: RuleContentType.anime,
        sourceRepository: externalManagedUrl,
      );
      final userRule = _rule(
        id: 'custom:user:my-anime',
        name: '自建动漫源',
        engine: 'animeko-http',
        host: 'my-anime.example',
        groupId: 'repo:user',
        priority: 10,
        contentType: RuleContentType.anime,
        sourceRepository: 'https://my.example/rules.json',
      );
      final repos = [
        RuleRepositoryRecord(
          id: 'bundled',
          name: '托管源',
          url: externalManagedUrl,
          importedAt: DateTime(2026, 11, 22),
          ruleCount: 50,
          managedInternal: true,
        ),
        RuleRepositoryRecord(
          id: 'user',
          name: '我的仓库',
          url: 'https://my.example/rules.json',
          importedAt: DateTime(2026, 11, 22),
          ruleCount: 1,
        ),
      ];

      expect(isBundledCommunitySubscriptionUrl(managedUrl), isTrue);
      expect(isBundledCommunityRule(seededRule), isTrue);
      expect(
        isBundledCommunityRule(repoMatchedRule, repositories: repos),
        isTrue,
      );
      expect(isBundledCommunityRule(userRule, repositories: repos), isFalse);
      expect(
        visibleUserRules([
          seededRule,
          repoMatchedRule,
          userRule,
        ], repositories: repos).map((r) => r.id),
        ['custom:user:my-anime'],
      );
      expect(visibleUserRuleRepositories(repos).map((r) => r.id), ['user']);
    },
  );
}

RulePlugin _rule({
  required String id,
  required String name,
  required String engine,
  required String host,
  required String groupId,
  required int priority,
  required RuleContentType contentType,
  String sourceRepository = '',
}) {
  final isTvbox = engine == 'tvbox' || engine.startsWith('tvbox-');
  final base = RulePlugin(
    id: id,
    name: name,
    source: RuleSourceKind.custom,
    contentType: contentType,
    engine: isTvbox ? 'tvbox-json-api' : 'animeko-web-selector',
    version: '1.0',
    baseUrl: isTvbox ? 'https://$host/api.php/provide/vod' : 'https://$host',
    searchUrl: isTvbox
        ? 'https://$host/api.php/provide/vod'
        : 'https://$host/search?wd={keyword}',
    searchable: true,
    quickSearch: true,
    filterable: false,
    qualityScore: 80,
    tags: const ['测试'],
    groupId: groupId,
    priority: priority,
    updatedAt: DateTime.utc(2026, 11, 22),
    note: sourceRepository.isEmpty ? '' : '从 $sourceRepository 导入。',
    animeko: isTvbox
        ? null
        : AnimekoWebSelectorConfig(
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
  if (sourceRepository.isEmpty) return base;
  return base.copyWith(
    permissionManifest: base.effectiveManifest.copyWith(
      sourceRepository: sourceRepository,
    ),
  );
}

RulePluginState _approvedState(List<RulePlugin> rules) {
  return RulePluginState(
    installedIds: {for (final r in rules) r.id},
    enabledIds: {for (final r in rules) r.id},
    approvedPermissionDigests: {
      for (final r in rules) r.id: r.effectiveManifest.permissionDigest,
    },
    customRules: rules,
  );
}

const _animeSubject = AnimeSubject(
  id: 548156,
  title: '青之箱 第二季',
  originalTitle: 'アオのハコ 第2期',
  summary: '',
  coverUrl: null,
  bannerUrl: null,
  date: '2026-04-01',
  platform: 'TV',
  language: '日语',
  region: '日本',
  status: '连载中',
  categories: [AnimeCategory(name: '动画')],
  tags: [],
  totalEpisodes: 26,
);

const _seriesSubject = AnimeSubject(
  id: 9001,
  source: 'tmdb:series:9001',
  title: '测试美剧',
  originalTitle: 'Test Series',
  summary: '',
  coverUrl: null,
  bannerUrl: null,
  date: '2026-04-01',
  platform: '剧集',
  language: '英语',
  region: '美国',
  status: '连载中',
  categories: [AnimeCategory(name: '美剧')],
  tags: [],
  totalEpisodes: 10,
);

const _episode = AnimeEpisode(
  id: 1,
  subjectId: 548156,
  number: 1,
  title: '第1集',
  airdate: '2026-04-01',
  duration: '24:00',
  description: '',
);
