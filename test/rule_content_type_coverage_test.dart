import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/rules/rule_plugin_repository.dart';
import 'package:anime/src/rules/rule_security.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'verified multi-genre rules participate in declared categories only',
    () {
      final allThree = _multiGenreRule(
        id: 'fixture:all-three',
        contentTypes: const ['anime', 'series', 'movie'],
      );
      final animeAndMovie = _multiGenreRule(
        id: 'fixture:anime-movie',
        contentTypes: const ['anime', 'movie'],
      );
      final repository = RulePluginRepository(
        extraRules: [allThree, animeAndMovie],
      );
      final state = RulePluginState(
        installedIds: {allThree.id, animeAndMovie.id},
        enabledIds: {allThree.id, animeAndMovie.id},
      );
      for (final type in RuleContentType.values) {
        expect(
          repository.playbackRulesFor(state, type).map((r) => r.id),
          contains(allThree.id),
        );
      }
      expect(animeAndMovie.supportedContentTypes, [
        RuleContentType.anime,
        RuleContentType.movie,
      ]);
      expect(
        repository
            .playbackRulesFor(state, RuleContentType.movie)
            .map((rule) => rule.id),
        contains(animeAndMovie.id),
      );
      expect(
        repository
            .playbackRulesFor(state, RuleContentType.series)
            .map((rule) => rule.id),
        isNot(contains(animeAndMovie.id)),
      );
    },
  );

  test(
    'multi-genre declarations round-trip and still require exact permission approval',
    () {
      final original = _multiGenreRule(
        id: 'custom:permission-test',
        contentTypes: const ['anime'],
      );
      final legacy = original.copyWith(
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
      final rule = _multiGenreRule(
        id: 'audit:multi-genre',
        contentTypes: const ['anime', 'series', 'movie'],
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

RulePlugin _multiGenreRule({
  required String id,
  required List<String> contentTypes,
}) {
  final host = '${id.replaceAll(':', '-')}.rules.example';
  return RulePlugin(
    id: id,
    name: '综合测试源-$id',
    version: '1',
    source: RuleSourceKind.custom,
    contentType: RuleContentType.anime,
    engine: 'tvbox-json-api',
    updatedAt: DateTime(2026, 9, 29),
    qualityScore: 1,
    tags: const [],
    baseUrl: 'https://$host/api.php/provide/vod/',
    searchUrl: 'https://$host/api.php/provide/vod/',
    searchable: true,
    quickSearch: true,
    filterable: false,
    permissionManifest: RulePermissionManifest.official(
      id: id,
      name: '综合测试源-$id',
      version: '1',
      engine: 'tvbox-json-api',
      contentTypes: contentTypes,
      pageDomains: [host],
      mediaDomains: [host],
    ),
  );
}
