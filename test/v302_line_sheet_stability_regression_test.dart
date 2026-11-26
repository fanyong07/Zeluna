import 'package:anime/src/data/playback_source_repository.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/player/player_page.dart';
import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/rules/rule_playback_resolver.dart';
import 'package:anime/src/rules/rule_plugin_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'expanded line lookup bounds total rules, caps WebView rules, prioritizes direct APIs, and skips empty rules in verification',
    () async {
      final directRules = List.generate(
        18,
        (i) => _directApiRule(
          id: 'custom:tvbox:direct-$i',
          name: 'Direct API $i',
          host: 'direct-$i.example.com',
          priority: 100 + i,
        ),
      );
      final webViewRules = List.generate(
        27,
        (i) => _webViewRule(
          id: 'custom:animeko:webview-$i',
          name: 'WebView Site $i',
          host: 'webview-$i.example.com',
          priority: 10 + i,
        ),
      );
      final allRules = <RulePlugin>[...webViewRules, ...directRules];
      final candidateIds = {directRules[0].id, directRules[1].id};
      final resolver = _CountingResolver(availableIds: candidateIds);
      final state = _approvedState(allRules);
      final source = RulePlaybackSourceRepository(
        repository: RulePluginRepository(extraRules: allRules),
        ruleState: state,
        resolver: resolver,
        cacheNamespace: 'v302-bounded-expanded-lookup',
      );

      final updates = await source
          .lineUpdatesForEpisode(_sampleSubject, _sampleEpisode)
          .toList();

      expect(updates.last.isComplete, isTrue);
      expect(resolver.discoveryCalls.length, lessThanOrEqualTo(24));

      final webViewDiscoveryCount = resolver.discoveryCalls
          .where((id) => id.startsWith('custom:animeko:webview-'))
          .length;
      final directDiscoveryCount = resolver.discoveryCalls
          .where((id) => id.startsWith('custom:tvbox:direct-'))
          .length;
      expect(webViewDiscoveryCount, lessThanOrEqualTo(6));
      expect(directDiscoveryCount, 18);

      // Large inventories must NOT re-query empty/failed rules in verification.
      expect(resolver.verificationCalls.toSet(), candidateIds);
      expect(resolver.verificationCalls, hasLength(candidateIds.length));
    },
  );

  testWidgets(
    'PlaybackSourcePanel renders large line lists lazily via SliverList',
    (tester) async {
      final lines = List.generate(
        120,
        (i) => PlaybackLine(
          id: 'line-$i',
          episodeId: _sampleEpisode.id,
          providerId: 'provider-$i',
          providerName: '源站 $i',
          title: '线路 $i',
          quality: '1080P',
          format: 'HLS',
          url: 'https://cdn$i.example.com/stream.m3u8',
          available: true,
          clientVerified: true,
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: SizedBox(
              width: 390,
              height: 600,
              child: PlaybackSourcePanel(
                lines: lines,
                selected: lines.first,
                failedLineIds: const {},
                scanning: false,
                completedRules: 24,
                totalRules: 24,
                onSelected: (_) {},
                onPickLocal: () async {},
                onOpenNetwork: (_, _) async {},
                onSearch: () async {},
              ),
            ),
          ),
        ),
      );

      expect(find.byType(CustomScrollView), findsOneWidget);
      expect(find.byKey(const ValueKey('line-0')), findsOneWidget);
      // Off-screen row #119 must not be eagerly inflated.
      expect(find.byKey(const ValueKey('line-119')), findsNothing);
    },
  );
}

const _sampleSubject = AnimeSubject(
  id: 302001,
  title: '测试番剧',
  originalTitle: 'Test Anime',
  summary: '',
  ratingScore: 9.0,
  date: '2026-01-01',
  platform: 'TV',
  region: '日本',
  language: '日语',
  coverUrl: '',
  bannerUrl: '',
  totalEpisodes: 12,
  status: '已完结',
  source: 'bangumi',
  categories: [],
  tags: [],
);

const _sampleEpisode = AnimeEpisode(
  id: 30200101,
  subjectId: 302001,
  number: 1,
  title: '第 1 集',
  airdate: '2026-01-01',
  duration: '24:00',
  description: '',
);

RulePlugin _directApiRule({
  required String id,
  required String name,
  required String host,
  required int priority,
}) {
  return RulePlugin(
    id: id,
    name: name,
    version: '1.0',
    source: RuleSourceKind.tvbox,
    contentType: RuleContentType.anime,
    engine: 'tvbox-json-api',
    updatedAt: DateTime.utc(2026, 11, 22),
    qualityScore: 60,
    tags: const ['TVBox', 'JSON API'],
    baseUrl: 'https://$host/api.php/provide/vod',
    searchUrl: 'https://$host/api.php/provide/vod',
    searchable: true,
    quickSearch: true,
    filterable: false,
    priority: priority,
    groupId: 'repo:lunatv',
  );
}

RulePlugin _webViewRule({
  required String id,
  required String name,
  required String host,
  required int priority,
}) {
  return RulePlugin(
    id: id,
    name: name,
    version: '1.0',
    source: RuleSourceKind.custom,
    contentType: RuleContentType.anime,
    engine: 'animeko-web-selector',
    updatedAt: DateTime.utc(2026, 11, 22),
    qualityScore: 80,
    tags: const ['Animeko'],
    baseUrl: 'https://$host/',
    searchUrl: 'https://$host/search?wd={keyword}',
    searchable: true,
    quickSearch: false,
    filterable: false,
    requiresWebView: true,
    priority: priority,
    groupId: 'repo:animeko',
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

RulePluginState _approvedState(List<RulePlugin> rules) {
  final ids = rules.map((r) => r.id).toSet();
  return RulePluginState(
    installedIds: ids,
    enabledIds: ids,
    customRules: rules,
    approvedPermissionDigests: {
      for (final r in rules)
        if (r.effectiveManifest.requiresApproval)
          r.id: r.effectiveManifest.permissionDigest,
    },
  );
}

class _CountingResolver extends RulePlaybackResolver {
  _CountingResolver({required this.availableIds});

  final Set<String> availableIds;
  final List<String> discoveryCalls = <String>[];
  final List<String> verificationCalls = <String>[];

  @override
  Future<List<PlaybackLine>> resolveRule({
    required RulePlugin rule,
    required AnimeSubject subject,
    required AnimeEpisode episode,
    bool verifyPlayable = false,
    RulePlaybackCancellationToken? cancellationToken,
  }) async {
    if (verifyPlayable) {
      verificationCalls.add(rule.id);
    } else {
      discoveryCalls.add(rule.id);
    }
    if (!availableIds.contains(rule.id)) {
      return const <PlaybackLine>[];
    }
    return <PlaybackLine>[
      PlaybackLine(
        id: '${rule.id}:ep:${episode.id}',
        episodeId: episode.id,
        providerId: rule.id,
        providerName: rule.name,
        title: '${rule.name} 线路',
        quality: '1080P',
        format: 'HLS',
        url: 'https://stream.example.com/${rule.id}.m3u8',
        available: true,
        clientVerified: verifyPlayable,
      ),
    ];
  }
}
