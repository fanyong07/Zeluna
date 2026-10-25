import 'dart:io';

import 'package:anime/src/rules/bundled_kazumi_rules.dart';
import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/rules/rule_plugin_repository.dart';
import 'package:anime/src/rules/rule_security.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    test(
      'Kazumi defaults skip migrated sources but retain their inventory on ${platform.name}',
      () {
        debugDefaultTargetPlatformOverride = platform;
        const repository = RulePluginRepository();
        final state = repository.defaultState();
        final enabled = repository.playbackRulesFor(
          state,
          RuleContentType.anime,
        );
        expect(bundledKazumiRules.map((rule) => rule.id).toSet(), {
          'kazumi:mxdm',
          'kazumi:xfdmneo',
          'kazumi:moonci',
        });
        for (final rule in bundledKazumiRules) {
          expect(state.installedIds, contains(rule.id));
          final migrated = rule.id != 'kazumi:mxdm';
          expect(enabled.map((item) => item.id).contains(rule.id), !migrated);
          expect(rule.executionStatus.isExecutable, !migrated);
          if (migrated) {
            expect(rule.unsupportedReason, contains('迁移'));
            expect(rule.quickSearch, isFalse);
          }
          expect(rule.engine, 'native');
          expect(rule.requiresCaptcha, isFalse);
          expect(rule.requiresWebView, isFalse);
          final permissions = rule.effectiveManifest;
          expect(permissions.javascript, isFalse);
          expect(permissions.webViewSniffing, isFalse);
          expect(permissions.cookiePolicy, RuleCookiePolicy.none);
          expect(permissions.cleartextHttp, isFalse);
          expect(permissions.pageDomains, hasLength(1));
          expect(permissions.mediaDomains, isNotEmpty);
          expect(
            permissions.mediaDomains.any((host) => host.contains('*')),
            isFalse,
          );
          expect(permissions.sourceRepository, contains(bundledKazumiRevision));
          expect(
            repository
                .playbackRulesFor(state, RuleContentType.movie)
                .map((item) => item.id),
            isNot(contains(rule.id)),
          );
          final disabled = repository.normalizeState(
            state.copyWith(enabledIds: {...state.enabledIds}..remove(rule.id)),
          );
          expect(
            repository
                .playbackRulesFor(disabled, RuleContentType.anime)
                .map((item) => item.id),
            isNot(contains(rule.id)),
          );
        }
      },
    );
  }
  test('failed CDN samples are not silently granted media permissions', () {
    final rules = {for (final rule in bundledKazumiRules) rule.id: rule};
    expect(
      rules['kazumi:mxdm']!.effectiveManifest.mediaDomains,
      isNot(contains('bfikuncdn.com')),
    );
    expect(rules['kazumi:moonci']!.effectiveManifest.mediaDomains, [
      'play.xfvod.pro',
    ]);
  });
  test('upstream license ships with the application', () {
    final notice = File(
      'assets/licenses/KazumiRules-LICENSE.txt',
    ).readAsStringSync();
    expect(notice, contains('Copyright (c) 2024 Predidit'));
    expect(
      File('pubspec.yaml').readAsStringSync(),
      contains('assets/licenses/KazumiRules-LICENSE.txt'),
    );
  });
}
