import 'package:flutter_test/flutter_test.dart';
import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/rules/rule_plugin_repository.dart';
import 'package:anime/src/rules/rule_security.dart';

void main() {
  group('rule permission manifests', () {
    test('bundled rules have explicit official manifests', () {
      final rules = const RulePluginRepository().allRules;

      expect(rules, isNotEmpty);
      for (final rule in rules) {
        expect(rule.permissionManifest, isNotNull, reason: rule.id);
        expect(
          rule.effectiveManifest.trustLevel,
          RuleTrustLevel.official,
          reason: rule.id,
        );
        expect(rule.effectiveManifest.contentHash, hasLength(64));
      }
    });

    test('imported trust claims are downgraded to untrusted', () {
      final rule = RulePlugin.fromJson({
        ..._ruleJson(),
        'manifest': {
          ..._manifestJson(),
          'trustLevel': 'official',
          'signature': 'unverified-signature',
        },
      });

      expect(rule.effectiveManifest.trustLevel, RuleTrustLevel.untrusted);
      expect(rule.effectiveManifest.signature, 'unverified-signature');
    });

    test('legacy rules receive a conservative manifest', () {
      final rule = RulePlugin.fromJson(_ruleJson());

      expect(rule.effectiveManifest.trustLevel, RuleTrustLevel.untrusted);
      expect(rule.effectiveManifest.pageDomains, ['video.example.com']);
      expect(rule.effectiveManifest.mediaDomains, ['video.example.com']);
      expect(rule.effectiveManifest.javascript, isFalse);
      expect(rule.effectiveManifest.cleartextHttp, isFalse);
    });

    test('content changes invalidate the permission digest', () {
      final first = RulePlugin.fromJson({
        ..._ruleJson(),
        'rawConfig': {'selector': '.video-a'},
        'manifest': _manifestJson(),
      });
      final second = RulePlugin.fromJson({
        ..._ruleJson(),
        'rawConfig': {'selector': '.video-b'},
        'manifest': _manifestJson(),
      });

      expect(
        first.effectiveManifest.contentHash,
        isNot(second.effectiveManifest.contentHash),
      );
      expect(
        first.effectiveManifest.permissionDigest,
        isNot(second.effectiveManifest.permissionDigest),
      );
    });
  });

  group('rule URL policy', () {
    final manifest = RulePermissionManifest.fromImportedJson(_manifestJson());
    final policy = RuleUrlPolicy(manifest);

    test('keeps page and media domains separate', () {
      expect(
        policy.allows(
          Uri.parse('https://video.example.com/watch/1'),
          RuleUrlPurpose.page,
        ),
        isTrue,
      );
      expect(
        policy.allows(
          Uri.parse('https://cdn.example.net/1.m3u8'),
          RuleUrlPurpose.media,
        ),
        isTrue,
      );
      expect(
        policy.allows(
          Uri.parse('https://cdn.example.net/player'),
          RuleUrlPurpose.page,
        ),
        isFalse,
      );
    });

    test('does not accept lookalike or suffix attacker domains', () {
      for (final url in [
        'https://evil-video.example.com.attacker.test/watch',
        'https://video.example.com.attacker.test/watch',
        'https://evil-example.com/watch',
      ]) {
        expect(
          policy.allows(Uri.parse(url), RuleUrlPurpose.page),
          isFalse,
          reason: url,
        );
      }
    });

    test('rejects dangerous schemes, credentials, and local networks', () {
      for (final url in [
        'file:///private/data',
        'content://settings/system',
        'javascript:alert(1)',
        'data:text/html,<script>alert(1)</script>',
        'blob:https://video.example.com/id',
        'ftp://video.example.com/file',
        'https://user:pass@video.example.com/watch',
        'https://localhost/watch',
        'https://service.local/watch',
        'https://127.0.0.1/watch',
        'https://10.0.0.1/watch',
        'https://169.254.169.254/latest/meta-data',
        'https://[::1]/watch',
        'https://[fd00::1]/watch',
      ]) {
        expect(
          policy.allows(Uri.parse(url), RuleUrlPurpose.page),
          isFalse,
          reason: url,
        );
      }
    });

    test('rejects cleartext unless it is explicitly declared', () {
      expect(
        policy.allows(
          Uri.parse('http://video.example.com/watch'),
          RuleUrlPurpose.page,
        ),
        isFalse,
      );
      final cleartext = RuleUrlPolicy(manifest.copyWith(cleartextHttp: true));
      expect(
        cleartext.allows(
          Uri.parse('http://video.example.com/watch'),
          RuleUrlPurpose.page,
        ),
        isTrue,
      );
    });
  });

  test('header policy is case-insensitive and permission gated', () {
    final manifest = RulePermissionManifest.fromImportedJson(_manifestJson());
    final filtered = filterRuleRequestHeaders({
      'AUTHORIZATION': 'secret',
      'Proxy-Authorization': 'secret',
      'Host': 'attacker.test',
      'Connection': 'keep-alive',
      'content-LENGTH': '999',
      'X-Zeluna-Account-Token': 'secret',
      'X-Api-Token': 'secret',
      'Referer': 'https://video.example.com/',
      'Origin': 'https://video.example.com',
      'User-Agent': 'Rule Agent',
      'Cookie': 'session=task-only',
      'Accept-Language': 'zh-CN',
    }, manifest);

    expect(filtered, {
      'Referer': 'https://video.example.com/',
      'Cookie': 'session=task-only',
      'Accept-Language': 'zh-CN',
    });
  });

  test('minimum core version is enforced', () {
    expect(isRuleCoreVersionCompatible('1.0.0'), isTrue);
    expect(isRuleCoreVersionCompatible('0.9.9'), isTrue);
    expect(isRuleCoreVersionCompatible('1.0.1'), isFalse);
    expect(isRuleCoreVersionCompatible('2.0.0'), isFalse);
  });

  test('cookies and credentials are never serialized with rule state', () {
    final rule = RulePlugin.fromJson({
      ..._ruleJson(),
      'requestHeaders': {
        'Cookie': 'session=private',
        'Authorization': 'Bearer private',
        'X-Api-Token': 'private-token',
        'Referer': 'https://video.example.com/',
      },
      'rawConfig': {
        'nested': {'password': 'private-password', 'selector': '.video'},
      },
      'animeko': {
        'searchUrl': 'https://video.example.com/search?q={keyword}',
        'subjectFormatId': 'a',
        'channelFormatId': 'index-grouped',
        'cookies': 'runtime=private',
      },
    });

    final encoded = rule.toJson();
    final text = encoded.toString();
    expect(text, isNot(contains('session=private')));
    expect(text, isNot(contains('Bearer private')));
    expect(text, isNot(contains('private-token')));
    expect(text, isNot(contains('private-password')));
    expect(text, isNot(contains('runtime=private')));
    expect(encoded['requestHeaders'], {
      'Referer': 'https://video.example.com/',
    });
    expect(
      ((encoded['rawConfig'] as Map)['nested'] as Map)['selector'],
      '.video',
    );
    final restored = RulePlugin.fromJson(encoded);
    expect(
      restored.effectiveManifest.permissionDigest,
      rule.effectiveManifest.permissionDigest,
    );
  });

  group('rule approval state', () {
    test(
      'untrusted rule stays disabled until exact permissions are approved',
      () {
        final rule = RulePlugin.fromJson({
          ..._ruleJson(),
          'installedByDefault': true,
          'manifest': _manifestJson(),
        });
        final repository = RulePluginRepository(extraRules: [rule]);
        final defaults = repository.defaultState();

        expect(defaults.installedIds, contains(rule.id));
        expect(defaults.enabledIds, isNot(contains(rule.id)));

        final unapproved = repository.normalizeState(
          defaults.copyWith(enabledIds: {rule.id}),
        );
        expect(unapproved.enabledIds, isNot(contains(rule.id)));

        final approved = repository.normalizeState(
          defaults.copyWith(
            enabledIds: {rule.id},
            approvedPermissionDigests: {
              rule.id: rule.effectiveManifest.permissionDigest,
            },
          ),
        );
        expect(approved.enabledIds, contains(rule.id));
      },
    );

    test('normalization removes stale approvals after a content update', () {
      final original = RulePlugin.fromJson({
        ..._ruleJson(),
        'rawConfig': {'selector': '.old'},
        'manifest': _manifestJson(),
      });
      final updated = RulePlugin.fromJson({
        ..._ruleJson(),
        'rawConfig': {'selector': '.new'},
        'manifest': _manifestJson(),
      });
      final repository = RulePluginRepository(extraRules: [updated]);
      final normalized = repository.normalizeState(
        RulePluginState(
          installedIds: {updated.id},
          enabledIds: {updated.id},
          approvedPermissionDigests: {
            updated.id: original.effectiveManifest.permissionDigest,
          },
          customRules: [updated],
        ),
      );

      expect(normalized.enabledIds, isEmpty);
      expect(normalized.approvedPermissionDigests, isEmpty);
    });
  });
}

Map<String, dynamic> _ruleJson() => {
  'id': 'imported:example',
  'name': 'Example',
  'version': '1.0',
  'source': 'custom',
  'contentType': 'anime',
  'engine': 'aikanbot-api',
  'updatedAt': '2026-08-01T00:00:00Z',
  'qualityScore': 80,
  'tags': <String>[],
  'baseUrl': 'https://video.example.com/',
  'searchUrl': 'https://video.example.com/search?q={keyword}',
  'searchable': true,
  'quickSearch': true,
  'filterable': false,
};

Map<String, dynamic> _manifestJson() => {
  'id': 'imported:example',
  'name': 'Example',
  'version': '1.0',
  'engine': 'aikanbot-api',
  'contentTypes': ['anime'],
  'sourceRepository': 'https://rules.example.org/index.json',
  'contentHash': 'claimed-but-untrusted',
  'signature': '',
  'trustLevel': 'untrusted',
  'pageDomains': ['video.example.com'],
  'mediaDomains': ['cdn.example.net'],
  'javascript': false,
  'webViewSniffing': false,
  'cookiePolicy': 'taskScoped',
  'cleartextHttp': false,
  'customReferer': true,
  'customOrigin': false,
  'customUserAgent': false,
  'minimumCoreVersion': '1.0.0',
};
