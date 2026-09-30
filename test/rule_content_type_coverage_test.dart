import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/rules/rule_plugin_repository.dart';
import 'package:anime/src/rules/rule_security.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'verified multi-genre built-ins participate in all three categories',
    () {
      const repository = RulePluginRepository();
      final state = repository.defaultState();
      for (final type in RuleContentType.values) {
        expect(
          repository.playbackRulesFor(state, type).map((r) => r.id),
          containsAll([
            'zeluna:recommended:aikanbot',
            'zeluna:recommended:sorani',
          ]),
        );
      }
      expect(
        repository.byId('zeluna:recommended:fantuan')!.supportedContentTypes,
        [RuleContentType.anime, RuleContentType.movie],
      );
      expect(
        repository
            .playbackRulesFor(state, RuleContentType.movie)
            .map((rule) => rule.id),
        contains('zeluna:recommended:fantuan'),
      );
      expect(
        repository
            .playbackRulesFor(state, RuleContentType.series)
            .map((rule) => rule.id),
        isNot(contains('zeluna:recommended:fantuan')),
      );
    },
  );

  test(
    'multi-genre declarations round-trip and still require exact permission approval',
    () {
      final original = const RulePluginRepository().byId(
        'zeluna:recommended:fantuan',
      )!;
      final legacy = original.copyWith(
        id: 'custom:permission-test',
        permissionManifest: original.effectiveManifest.copyWith(
          trustLevel: RuleTrustLevel.untrusted,
          contentTypes: ['anime'],
        ),
      );
      final expanded = legacy.copyWith(
        permissionManifest: legacy.effectiveManifest.copyWith(
          contentTypes: ['anime', 'movie', 'series', 'invalid'],
        ),
      );
      final restored = RulePlugin.fromJson(expanded.toJson());
      expect(restored.supportedContentTypes, RuleContentType.values);
      expect(legacy.supportedContentTypes, [RuleContentType.anime]);
      expect(
        restored.effectiveManifest.permissionDigest,
        isNot(legacy.effectiveManifest.permissionDigest),
      );
      final repository = RulePluginRepository(extraRules: [restored]);
      final state = RulePluginState(
        installedIds: {restored.id},
        enabledIds: {restored.id},
        approvedPermissionDigests: {
          restored.id: legacy.effectiveManifest.permissionDigest,
        },
      );
      expect(repository.canEnableRule(restored, state), isFalse);
    },
  );

  test(
    'a generic rule name or primary anime category must not hide movie and series lookup',
    () {
      final rule = RulePlugin(
        id: 'audit:multi-genre',
        name: '综合动漫站',
        version: '1',
        source: RuleSourceKind.custom,
        contentType: RuleContentType.anime,
        engine: 'tvbox-json-api',
        updatedAt: DateTime(2026, 9, 29),
        qualityScore: 1,
        tags: const [],
        baseUrl: 'https://rules.example/api.php/provide/vod/',
        searchUrl: 'https://rules.example/api.php/provide/vod/',
        searchable: true,
        quickSearch: true,
        filterable: false,
        permissionManifest: const RulePermissionManifest.official(
          id: 'audit:multi-genre',
          name: '综合动漫站',
          version: '1',
          engine: 'tvbox-json-api',
          contentTypes: ['anime', 'series', 'movie'],
          pageDomains: ['rules.example'],
          mediaDomains: ['rules.example'],
        ),
      );
      final repository = RulePluginRepository(extraRules: [rule]);
      final state = RulePluginState(
        installedIds: {rule.id},
        enabledIds: {rule.id},
      );
      for (final type in RuleContentType.values) {
        expect(
          repository.playbackRulesFor(state, type).map((r) => r.id),
          contains(rule.id),
          reason:
              '${type.name} is a search target, not an exclusion based on the display category',
        );
      }
    },
  );
}
