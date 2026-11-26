import 'dart:convert';
import 'package:anime/src/rules/rule_importer.dart';
import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/rules/rule_plugin_repository.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> ruleJson({bool captcha = false}) => {
  'name': 'dynamic-fixture',
  'api': '9',
  'version': '1.0',
  'type': 'anime',
  'baseURL': 'https://page.example/',
  'searchURL': 'https://page.example/search?wd=@keyword',
  'useWebview': true,
  'useNativePlayer': true,
  'searchList': '//article',
  'searchName': '//a',
  'searchResult': '//a',
  'chapterRoads': '//ul',
  'chapterResult': '//a',
  'antiCrawlerConfig': {'enabled': captcha, 'captchaType': 1},
};
void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);
  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    test(
      'approved normal WebView rule participates in playback on ${platform.name}',
      () {
        debugDefaultTargetPlatformOverride = platform;
        final rule = const RuleImporter()
            .importFromText(jsonEncode(ruleJson()))
            .rules
            .single;
        final repository = RulePluginRepository(extraRules: [rule]);
        final state = RulePluginState(
          installedIds: {rule.id},
          enabledIds: {rule.id},
          approvedPermissionDigests: {
            rule.id: rule.effectiveManifest.permissionDigest,
          },
        );
        expect(rule.executionStatus, RuleExecutionStatus.executable);
        expect(
          repository
              .playbackRulesFor(state, RuleContentType.anime)
              .map((r) => r.id),
          contains(rule.id),
        );
        expect(
          repository.playbackRulesFor(
            state.copyWith(approvedPermissionDigests: {}),
            RuleContentType.anime,
          ),
          isEmpty,
        );
      },
    );
  }
  test(
    'actual anti-crawler challenge stays blocked; false does not mean a challenge',
    () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final rule = const RuleImporter()
          .importFromText(jsonEncode(ruleJson(captcha: true)))
          .rules
          .single;
      expect(rule.executionStatus, RuleExecutionStatus.needsWebView);
    },
  );
  test('no WebView runtime remains a real blocker', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final rule = const RuleImporter()
        .importFromText(jsonEncode(ruleJson()))
        .rules
        .single;
    expect(rule.executionStatus, RuleExecutionStatus.needsWebView);
  });
}
