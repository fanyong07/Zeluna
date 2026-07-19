import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/sources/source_catalog_models.dart';
import 'package:anime/src/sources/source_rule_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
