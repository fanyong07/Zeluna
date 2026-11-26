import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/rules/rule_plugin_repository.dart';
import 'package:anime/src/rules/rule_security.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('audited media CDN grants permit media without page privileges', () {
    final rule = RulePlugin(
      id: 'fixture:cdn-policy',
      name: 'CDN Policy Fixture',
      version: '1.0',
      source: RuleSourceKind.custom,
      contentType: RuleContentType.anime,
      engine: 'tvbox-json-api',
      updatedAt: DateTime(2026, 10, 5),
      qualityScore: 90,
      tags: const [],
      baseUrl: 'https://api.source.example/vod',
      searchUrl: 'https://api.source.example/vod',
      searchable: true,
      quickSearch: true,
      filterable: false,
      permissionManifest: const RulePermissionManifest.official(
        id: 'fixture:cdn-policy',
        name: 'CDN Policy Fixture',
        version: '1.0',
        engine: 'tvbox-json-api',
        contentTypes: ['anime', 'series', 'movie'],
        pageDomains: ['api.source.example'],
        mediaDomains: [
          'api.source.example',
          'cdn1.media.example',
          'cdn2.media.example',
        ],
        customReferer: true,
      ),
    );
    final policy = RuleUrlPolicy(rule.effectiveManifest);
    for (final host in ['cdn1.media.example', 'cdn2.media.example']) {
      expect(
        policy.allows(Uri.https(host, '/video'), RuleUrlPurpose.media),
        isTrue,
        reason: 'Audited manifest/key/segment host $host',
      );
      expect(
        policy.allows(Uri.https(host, '/player'), RuleUrlPurpose.page),
        isFalse,
        reason: 'Media grant must not grant script/page access',
      );
      for (final other in ['$host.attacker.test', 'evil-$host']) {
        expect(
          policy.allows(Uri.https(other, '/player'), RuleUrlPurpose.page),
          isFalse,
        );
      }
    }
    for (final host in [
      '127.0.0.1',
      '10.0.0.1',
      '169.254.169.254',
      'localhost',
    ]) {
      expect(
        policy.allows(Uri.https(host, '/video'), RuleUrlPurpose.media),
        isFalse,
        reason: 'Private/loopback SSRF target must always be blocked',
      );
    }
    for (final host in [
      'unlisted.example',
      'media.example',
      'other.media.example',
    ]) {
      expect(
        policy.allows(Uri.https(host, '/player'), RuleUrlPurpose.page),
        isFalse,
        reason: 'Unlisted hosts never receive page/script privileges',
      );
    }
  });

  test('CDN change needs exact fresh approval and does not upgrade trust', () {
    final original = RulePlugin.fromJson({
      'id': 'local:test',
      'name': 'Imported source',
      'version': '1',
      'engine': 'tvbox-json-api',
      'contentType': 'anime',
      'baseUrl': 'https://api.example.test/',
    });
    final updated = original.copyWith(
      permissionManifest: original.effectiveManifest.copyWith(
        mediaDomains: [
          ...original.effectiveManifest.mediaDomains,
          'cdn.example.test',
        ],
      ),
    );
    final state = RulePluginState(
      installedIds: {original.id},
      approvedPermissionDigests: {
        original.id: original.effectiveManifest.permissionDigest,
      },
    );
    final repo = RulePluginRepository(extraRules: [updated]);
    expect(updated.effectiveManifest.trustLevel, RuleTrustLevel.untrusted);
    expect(repo.canEnableRule(updated, state), isFalse);
    final approved = state.copyWith(
      approvedPermissionDigests: {
        updated.id: updated.effectiveManifest.permissionDigest,
      },
    );
    expect(repo.canEnableRule(updated, approved), isTrue);
    expect(
      repo.canEnableRule(
        updated.copyWith(
          permissionManifest: updated.effectiveManifest.copyWith(
            mediaDomains: [
              ...updated.effectiveManifest.mediaDomains,
              'another.example',
            ],
          ),
        ),
        approved,
      ),
      isFalse,
    );
  });
}
