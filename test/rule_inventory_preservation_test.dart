import 'dart:convert';
import 'dart:io';

import 'package:anime/src/rules/csp_rule_support.dart';
import 'package:anime/src/rules/rule_importer.dart';
import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/rules/rule_plugin_repository.dart';
import 'package:anime/src/sources/source_catalog_models.dart';
import 'package:anime/src/sources/source_rule_bridge.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test('bundled client-side rule inventory stays empty', () {
    final catalog =
        jsonDecode(File('assets/data/sources_catalog.json').readAsStringSync())
            as Map<String, dynamic>;
    final sources = (catalog['sources'] as List).whereType<Map>().toList();
    var rawTvBoxSiteCount = 0;
    var inventoryEntryCount = 0;
    var drpySiteCount = 0;

    for (final source in sources) {
      final rawConfig = source['rawConfig'];
      final sites = rawConfig is Map && rawConfig['sites'] is List
          ? (rawConfig['sites'] as List).whereType<Map>().toList()
          : const <Map>[];
      rawTvBoxSiteCount += sites.length;
      inventoryEntryCount += sites.isEmpty ? 1 : sites.length;
      drpySiteCount += sites.where((site) {
        final api = site['api']?.toString() ?? '';
        return site['type']?.toString() == '3' &&
            RegExp(r'drpy2(?:\.min)?\.js', caseSensitive: false).hasMatch(api);
      }).length;
    }

    expect(catalog['totalSources'], 0);
    expect(sources, isEmpty);
    expect(rawTvBoxSiteCount, 0);
    expect(inventoryEntryCount, 0);
    expect(drpySiteCount, 0);
  });

  test(
    'CSP and drpy metadata survives while playback uses only current-platform rules',
    () {
      final rawConfig = <String, dynamic>{
        'spider': './jar/custom_spider.jar;md5;$qistCustomSpiderMd5',
        'sites': [
          {
            'key': 'star',
            'name': 'Star',
            'type': 3,
            'api': 'csp_Star',
            'ext': './json/star.json',
          },
          {'key': 'nini', 'name': 'NiNi', 'type': 3, 'api': 'csp_NiNi'},
          {
            'key': 'drpy',
            'name': 'drpy',
            'type': 3,
            'api': './lib/drpy2.min.js',
            'ext': {'host': 'https://drpy.example/', 'search': 'js:return [];'},
          },
        ],
      };
      final imported = const RuleImporter().importFromText(
        jsonEncode(rawConfig),
        sourceUrl: 'https://rules.example/box.json',
      );
      final allIds = imported.rules.map((rule) => rule.id).toSet();

      expect(imported.rules, hasLength(9));
      expect(
        imported.rules.where((rule) => rule.engine == 'android-csp'),
        hasLength(6),
      );
      expect(
        imported.rules.where((rule) => rule.engine == 'drpy-js'),
        hasLength(3),
      );
      expect(
        imported.rules.where((rule) => rule.name == 'NiNi'),
        hasLength(3),
        reason: 'unsupported CSP rules must remain importable metadata',
      );

      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final bridgeResult = const SourceRuleBridge().build(
        SourceCatalogState(
          totalSources: 1,
          sources: [
            VideoSource(
              id: 'source:mixed-rules',
              name: 'mixed rules',
              kind: VideoSourceKind.tvBox,
              importUrl: 'https://rules.example/box.json',
              baseUrl: 'https://rules.example/box.json',
              rawConfig: rawConfig,
            ),
          ],
        ),
      );
      expect(bridgeResult.rules, hasLength(6));
      expect(bridgeResult.rules.map((rule) => rule.engine).toSet(), {
        'android-csp',
        'drpy-js',
      });
      expect(
        bridgeResult.rules.where((rule) => rule.name == 'NiNi'),
        isEmpty,
        reason: 'unavailable metadata must not enter the playback bridge',
      );

      final restored = RulePluginState.fromJson(
        RulePluginState(
          installedIds: allIds,
          enabledIds: allIds,
          customRules: imported.rules,
        ).toJson(),
      );
      final repository = RulePluginRepository(extraRules: restored.customRules);
      var normalized = repository.normalizeState(restored);

      expect(normalized.installedIds, allIds);
      expect(normalized.customRules, hasLength(9));
      expect(normalized.enabledIds, isEmpty);
      expect(
        repository.playbackRulesFor(normalized, RuleContentType.anime),
        isEmpty,
      );
      final restoredNini = normalized.customRules.firstWhere(
        (rule) => rule.name == 'NiNi',
      );
      expect(restoredNini.rawConfig['spider'], rawConfig['spider']);
      expect((restoredNini.rawConfig['site'] as Map)['api'], 'csp_NiNi');

      final approvedRestored = RulePluginState.fromJson(
        restored
            .copyWith(
              approvedPermissionDigests: {
                for (final rule in repository.allRules)
                  rule.id: rule.effectiveManifest.permissionDigest,
              },
            )
            .toJson(),
      );

      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      normalized = repository.normalizeState(approvedRestored);
      expect(normalized.installedIds, allIds);
      expect(normalized.customRules, hasLength(9));
      expect(normalized.enabledIds, hasLength(3));
      expect(
        repository
            .playbackRulesFor(normalized, RuleContentType.anime)
            .map((rule) => rule.engine),
        ['drpy-js'],
      );

      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      normalized = repository.normalizeState(approvedRestored);
      expect(normalized.installedIds, allIds);
      expect(normalized.customRules, hasLength(9));
      expect(normalized.enabledIds, hasLength(6));
      expect(
        repository
            .playbackRulesFor(normalized, RuleContentType.anime)
            .map((rule) => rule.engine)
            .toSet(),
        {'android-csp', 'drpy-js'},
      );
      expect(
        repository
            .playbackRulesFor(normalized, RuleContentType.anime)
            .any((rule) => rule.name == 'NiNi'),
        isFalse,
      );
    },
  );

  test(
    'CSP identity keeps audited APIs and unaudited package metadata separate',
    () {
      final auditedConfig = <String, dynamic>{
        'spider': './jar/custom_spider.jar;md5;$qistCustomSpiderMd5',
        'sites': [
          {
            'key': 'star',
            'name': 'same CSP name',
            'type': 3,
            'api': 'csp_Star',
          },
          {
            'key': 'bili',
            'name': 'same CSP name',
            'type': 3,
            'api': 'csp_Bili',
          },
        ],
      };
      final bridged = const SourceRuleBridge().build(
        SourceCatalogState(
          totalSources: 1,
          sources: [
            VideoSource(
              id: 'source:audited-csp',
              name: 'audited CSP',
              kind: VideoSourceKind.tvBox,
              importUrl: 'https://rules.example/audited.json',
              baseUrl: 'https://rules.example/audited.json',
              rawConfig: auditedConfig,
            ),
          ],
        ),
      );
      final bridgedAnimeApis = bridged.rules
          .where((rule) => rule.contentType == RuleContentType.anime)
          .map((rule) => (rule.rawConfig['site'] as Map)['api'])
          .toSet();

      expect(bridged.rules, hasLength(6));
      expect(bridgedAnimeApis, {'csp_Star', 'csp_Bili'});

      RuleImportBundle importUnaudited(String md5, String sourceUrl) {
        return const RuleImporter().importFromText(
          jsonEncode({
            'spider': './jar/future.jar;md5;$md5',
            'sites': [
              {
                'key': 'future',
                'name': 'same future CSP',
                'type': 3,
                'api': 'csp_Future',
              },
            ],
          }),
          sourceUrl: sourceUrl,
        );
      }

      final first = importUnaudited(
        '11111111111111111111111111111111',
        'https://rules.example/first.json',
      );
      final second = importUnaudited(
        '22222222222222222222222222222222',
        'https://rules.example/second.json',
      );
      final customRules = [...first.rules, ...second.rules];
      final customIds = customRules.map((rule) => rule.id).toSet();
      final repository = RulePluginRepository(extraRules: customRules);
      final normalized = repository.normalizeState(
        RulePluginState(
          installedIds: customIds,
          enabledIds: customIds,
          customRules: customRules,
        ),
      );

      expect(normalized.installedIds, customIds);
      expect(normalized.customRules, hasLength(6));
      expect(normalized.enabledIds, isEmpty);
      expect(
        normalized.customRules
            .map((rule) => androidCspSpiderMd5(rule.rawConfig))
            .toSet(),
        {
          '11111111111111111111111111111111',
          '22222222222222222222222222222222',
        },
      );
    },
  );
}
