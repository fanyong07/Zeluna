import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/rules/rule_plugin_repository.dart';
import 'package:anime/src/rules/rule_security.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const verifiedMediaHosts = {
    'zeluna:recommended:fantuan': ['play.modujx10.com'],
    'zeluna:recommended:sorani': ['www.sorani-vids.xyz'],
    'zeluna:recommended:aikanbot': [
      'v.gsuus.com',
      'gs.gszyi.com',
      'play.xluuss.com',
      'g.xlzyd.com',
      'play.hhuus.com',
      'p.hhwenjian.com',
      'vv.jisuzyv.com',
      'p.jisuts.com',
      'yzzy.play-cdn19.com',
    ],
  };
  for (final entry in verifiedMediaHosts.entries) {
    test('${entry.key} permits audited media without page privileges', () {
      final rule = const RulePluginRepository().byId(entry.key)!;
      final policy = RuleUrlPolicy(rule.effectiveManifest);
      for (final host in entry.value) {
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
            policy.allows(Uri.https(other, '/video'), RuleUrlPurpose.media),
            isFalse,
          );
        }
      }
      for (final host in [
        '127.0.0.1',
        '10.0.0.1',
        '169.254.169.254',
        'localhost',
        'unlisted.example',
        'gsuus.com',
        'other.gsuus.com',
      ]) {
        expect(
          policy.allows(Uri.https(host, '/video'), RuleUrlPurpose.media),
          isFalse,
          reason: 'Not an audited public media endpoint',
        );
      }
    });
  }

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
          'v.gsuus.com',
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
