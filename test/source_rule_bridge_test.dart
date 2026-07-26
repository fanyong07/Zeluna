import 'dart:convert';

import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/rules/tvbox_xbpq_hydrator.dart';
import 'package:anime/src/sources/source_catalog_models.dart';
import 'package:anime/src/sources/source_rule_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'enabled TVBox JSON source contributes playback rules for all media types',
    () {
      const source = VideoSource(
        id: 'source:tvbox',
        name: '综合 TVBox',
        kind: VideoSourceKind.tvBox,
        importUrl: 'https://example.com/tvbox.json',
        baseUrl: 'https://example.com/tvbox.json',
        supportsSearch: true,
        enabled: true,
        rawConfig: {
          'sites': [
            {
              'key': 'json-api',
              'name': '综合资源',
              'type': 1,
              'api': 'https://api.example.com/api.php/provide/vod',
              'searchable': 1,
            },
          ],
        },
      );

      final result = const SourceRuleBridge().build(
        const SourceCatalogState(totalSources: 1, sources: [source]),
      );
      final catalog = result.attachTo(
        const SourceCatalogState(totalSources: 1, sources: [source]),
      );

      expect(result.rules, hasLength(3));
      expect(result.availableRuleCount, 3);
      expect(
        result.rules.map((rule) => rule.contentType).toSet(),
        RuleContentType.values.toSet(),
      );
      expect(result.rules.every((rule) => rule.canResolveNatively), isTrue);
      expect(
        result.rules.every((rule) => rule.id.startsWith('catalog:')),
        isTrue,
      );
      expect(catalog.playbackRuleCountFor(source.id), 3);
      expect(catalog.availablePlaybackRuleCount, 3);
      expect(catalog.activePlaybackRuleCount, 3);
      expect(catalog.playbackConnectedCount, 1);
    },
  );

  test('TVBox XML source contributes native playback rules', () {
    const source = VideoSource(
      id: 'source:xml',
      name: 'XML 采集',
      kind: VideoSourceKind.tvBox,
      importUrl: 'https://example.com/tvbox.json',
      baseUrl: 'https://example.com/tvbox.json',
      rawConfig: {
        'sites': [
          {
            'key': 'xml-api',
            'name': 'XML 资源',
            'type': 0,
            'api': 'https://api.example.com/api.php/provide/vod/at/xml/',
          },
        ],
      },
    );

    final result = const SourceRuleBridge().build(
      const SourceCatalogState(totalSources: 1, sources: [source]),
    );

    expect(result.rules, hasLength(3));
    expect(
      result.rules.every((rule) => rule.engine == 'tvbox-xml-api'),
      isTrue,
    );
    expect(result.rules.every((rule) => rule.canResolveNatively), isTrue);
    expect(result.ruleCountsBySource[source.id], 3);
  });

  test(
    'disabled external source keeps its rule count but leaves playback chain',
    () {
      const source = VideoSource(
        id: 'source:tvbox',
        name: '关闭的 TVBox',
        kind: VideoSourceKind.tvBox,
        importUrl: 'https://example.com/tvbox.json',
        baseUrl: 'https://example.com/tvbox.json',
        enabled: false,
        rawConfig: {
          'sites': [
            {
              'key': 'json-api',
              'name': '电影资源',
              'type': 1,
              'api': 'https://api.example.com/api.php/provide/vod',
              'searchable': 1,
            },
          ],
        },
      );

      final result = const SourceRuleBridge().build(
        const SourceCatalogState(totalSources: 1, sources: [source]),
      );

      expect(result.rules, isEmpty);
      expect(result.ruleCountsBySource[source.id], 1);
      expect(result.availableRuleCount, 1);

      final catalog = result.attachTo(
        const SourceCatalogState(totalSources: 1, sources: [source]),
      );
      expect(catalog.availablePlaybackRuleCount, 1);
      expect(catalog.activePlaybackRuleCount, 0);
    },
  );

  test('duplicate APIs are merged and keep the richer request headers', () {
    const first = VideoSource(
      id: 'source:first',
      name: 'First',
      kind: VideoSourceKind.tvBox,
      importUrl: 'https://example.com/first.json',
      baseUrl: 'https://example.com/first.json',
      rawConfig: {
        'rules': [
          {
            'name': 'proxy',
            'hosts': ['example.com'],
          },
        ],
        'sites': [
          {
            'key': 'api-1',
            'name': '综合资源',
            'type': 1,
            'api': 'https://api.example.com/provide/vod?ac=list',
          },
        ],
      },
    );
    const second = VideoSource(
      id: 'source:second',
      name: 'Second',
      kind: VideoSourceKind.tvBox,
      importUrl: 'https://example.com/second.json',
      baseUrl: 'https://example.com/second.json',
      rawConfig: {
        'sites': [
          {
            'key': 'api-2',
            'name': '综合资源',
            'type': 1,
            'api': 'https://api.example.com/provide/vod/',
            'header': {'User-Agent': 'Mozilla/5.0'},
          },
        ],
      },
    );

    final result = const SourceRuleBridge().build(
      const SourceCatalogState(totalSources: 2, sources: [first, second]),
    );

    expect(result.rules, hasLength(3));
    expect(result.availableRuleCount, 3);
    expect(
      result.rules.every(
        (rule) => rule.requestHeaders['User-Agent'] == 'Mozilla/5.0',
      ),
      isTrue,
    );
  });

  test(
    'enabled XBPQ hydrates while disabled XBPQ stays off the network',
    () async {
      var requestCount = 0;
      final hydrator = TvBoxXbpqHydrator(
        client: MockClient((request) async {
          requestCount++;
          expect(request.url, Uri.parse('https://rules.example/xbpq.json'));
          return http.Response(
            jsonEncode(_completeXbpqConfig),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(hydrator.close);
      final bridge = SourceRuleBridge(xbpqHydrator: hydrator);
      const source = VideoSource(
        id: 'source:xbpq',
        name: 'XBPQ 源',
        kind: VideoSourceKind.tvBox,
        importUrl: 'https://rules.example/catalog.json',
        baseUrl: 'https://rules.example/catalog.json',
        headers: {'Referer': 'https://rules.example/'},
        rawConfig: {
          'sites': [
            {
              'key': 'xbpq-site',
              'name': 'XBPQ 动漫',
              'type': 3,
              'api': 'csp_XBPQ',
              'searchable': 1,
              'ext': './xbpq.json',
            },
          ],
        },
      );
      const catalog = SourceCatalogState(totalSources: 1, sources: [source]);
      final disabledCatalog = catalog.copyWith(
        sources: [source.copyWith(enabled: false)],
      );

      final disabledBeforeHydration = await bridge.buildHydrated(
        disabledCatalog,
      );
      expect(requestCount, 0);
      expect(disabledBeforeHydration.rules, isEmpty);
      expect(disabledBeforeHydration.ruleCountsBySource[source.id], 0);
      expect(disabledBeforeHydration.availableRuleCount, 0);

      final result = await bridge.buildHydrated(catalog);
      final attached = result.attachTo(catalog);

      expect(requestCount, 1);
      expect(result.rules, hasLength(1));
      final rule = result.rules.single;
      expect(rule.engine.toLowerCase(), 'xbpq');
      expect(rule.id, startsWith('catalog:source:xbpq:'));
      expect(rule.id, isNot(startsWith('catalog:source:xbpq:catalog:')));
      expect(rule.groupId, 'catalog:source:xbpq');
      expect(rule.requestHeaders['Referer'], 'https://rules.example/');
      expect(rule.requestHeaders['User-Agent'], 'XBPQ Rule UA');
      expect(attached.playbackRuleCountFor(source.id), 1);
      expect(attached.availablePlaybackRuleCount, 1);
      expect(attached.activePlaybackRuleCount, 1);

      final disabledAfterHydration = await bridge.buildHydrated(
        disabledCatalog,
      );
      expect(
        requestCount,
        1,
        reason: 'disabled sources should not visit the hydrator or its cache',
      );
      expect(disabledAfterHydration.rules, isEmpty);
      expect(disabledAfterHydration.ruleCountsBySource[source.id], 0);
      expect(disabledAfterHydration.availableRuleCount, 0);
    },
  );

  test(
    'hydrated build skips sources that cannot add hydrated playback rules',
    () async {
      final hydrator = _RecordingTvBoxXbpqHydrator();
      addTearDown(hydrator.close);
      final bridge = SourceRuleBridge(xbpqHydrator: hydrator);
      const disabledXbpq = VideoSource(
        id: 'source:disabled-xbpq',
        name: '关闭的 XBPQ',
        kind: VideoSourceKind.tvBox,
        importUrl: 'https://rules.example/catalog.json',
        baseUrl: 'https://rules.example/catalog.json',
        enabled: false,
        rawConfig: {
          'sites': [
            {
              'key': 'disabled-xbpq',
              'api': 'csp_XBPQ',
              'ext': './disabled.json',
            },
          ],
        },
      );
      const jsonApi = VideoSource(
        id: 'source:json-only',
        name: 'JSON API',
        kind: VideoSourceKind.tvBox,
        importUrl: 'https://rules.example/json.json',
        baseUrl: 'https://rules.example/json.json',
        rawConfig: {
          'sites': [
            {
              'key': 'json-api',
              'type': 1,
              'api': 'https://api.example.com/provide/vod',
            },
          ],
        },
      );
      const live = VideoSource(
        id: 'source:live',
        name: 'M3U',
        kind: VideoSourceKind.liveM3u,
        importUrl: 'https://media.example/live.m3u',
        baseUrl: 'https://media.example/live.m3u',
      );

      final result = await bridge.buildHydrated(
        const SourceCatalogState(
          totalSources: 3,
          sources: [disabledXbpq, jsonApi, live],
        ),
      );

      expect(hydrator.visitedSourceIds, isEmpty);
      expect(result.ruleCountsBySource[disabledXbpq.id], 0);
      expect(result.ruleCountsBySource[jsonApi.id], 3);
      expect(result.ruleCountsBySource[live.id], 0);
      expect(result.rules, hasLength(3));
    },
  );

  test('inline XBPQ never bypasses hydrator safety checks', () async {
    var requestCount = 0;
    final hydrator = TvBoxXbpqHydrator(
      client: MockClient((_) async {
        requestCount++;
        return http.Response('unexpected', 500);
      }),
    );
    addTearDown(hydrator.close);
    final bridge = SourceRuleBridge(xbpqHydrator: hydrator);
    const safeSource = VideoSource(
      id: 'source:xbpq-inline-safe',
      name: '安全内联 XBPQ',
      kind: VideoSourceKind.tvBox,
      importUrl: 'https://rules.example/catalog.json',
      baseUrl: 'https://rules.example/catalog.json',
      rawConfig: {
        'sites': [
          {
            'key': 'xbpq-inline-safe',
            'name': '安全内联 XBPQ',
            'type': 3,
            'api': 'csp_XBPQ',
            'ext': _completeXbpqConfig,
          },
        ],
      },
    );
    const safeCatalog = SourceCatalogState(
      totalSources: 1,
      sources: [safeSource],
    );

    final immediate = bridge.build(safeCatalog);
    expect(immediate.rules, isEmpty);
    expect(immediate.ruleCountsBySource[safeSource.id], 0);

    final hydrated = await bridge.buildHydrated(safeCatalog);
    expect(requestCount, 0);
    expect(hydrated.rules, hasLength(1));
    expect(hydrated.rules.single.canResolveNatively, isTrue);

    final unsafeSource = VideoSource(
      id: 'source:xbpq-inline-unsafe',
      name: '危险内联 XBPQ',
      kind: VideoSourceKind.tvBox,
      importUrl: safeSource.importUrl,
      baseUrl: safeSource.baseUrl,
      rawConfig: {
        'sites': [
          {
            'key': 'xbpq-inline-unsafe',
            'name': '危险内联 XBPQ',
            'type': 3,
            'api': 'csp_XBPQ',
            'ext': {..._completeXbpqConfig, 'script': './evil.js'},
          },
        ],
      },
    );
    final unsafe = await bridge.buildHydrated(
      SourceCatalogState(totalSources: 1, sources: [unsafeSource]),
    );

    expect(requestCount, 0);
    expect(unsafe.rules, isEmpty);
    expect(unsafe.ruleCountsBySource[unsafeSource.id], 0);
  });

  test('XBPQ failure is isolated from executable JSON API sources', () async {
    final hydrator = TvBoxXbpqHydrator(
      client: MockClient((_) async => http.Response('offline', 503)),
    );
    addTearDown(hydrator.close);
    final bridge = SourceRuleBridge(xbpqHydrator: hydrator);
    const xbpqSource = VideoSource(
      id: 'source:xbpq-failed',
      name: '失败 XBPQ',
      kind: VideoSourceKind.tvBox,
      importUrl: 'https://rules.example/catalog.json',
      baseUrl: 'https://rules.example/catalog.json',
      rawConfig: {
        'sites': [
          {
            'key': 'xbpq-failed',
            'name': '失败 XBPQ',
            'type': 3,
            'api': 'csp_XBPQ',
            'ext': './offline.json',
          },
        ],
      },
    );
    const jsonSource = VideoSource(
      id: 'source:json',
      name: 'JSON API',
      kind: VideoSourceKind.tvBox,
      importUrl: 'https://rules.example/json.json',
      baseUrl: 'https://rules.example/json.json',
      rawConfig: {
        'sites': [
          {
            'key': 'json',
            'name': 'JSON API',
            'type': 1,
            'api': 'https://api.example.com/provide/vod',
          },
        ],
      },
    );

    final result = await bridge.buildHydrated(
      const SourceCatalogState(
        totalSources: 2,
        sources: [xbpqSource, jsonSource],
      ),
    );

    expect(result.ruleCountsBySource[xbpqSource.id], 0);
    expect(result.ruleCountsBySource[jsonSource.id], 3);
    expect(result.rules, hasLength(3));
    expect(
      result.rules.every((rule) => rule.engine == 'tvbox-json-api'),
      isTrue,
    );
    expect(bridge.mayContributePlaybackRules(xbpqSource), isTrue);
  });
}

const _completeXbpqConfig = <String, dynamic>{
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

class _RecordingTvBoxXbpqHydrator extends TvBoxXbpqHydrator {
  final visitedSourceIds = <String>[];

  @override
  Future<TvBoxXbpqHydrationResult> hydrateSource(VideoSource source) async {
    visitedSourceIds.add(source.id);
    return const TvBoxXbpqHydrationResult(sites: []);
  }
}
