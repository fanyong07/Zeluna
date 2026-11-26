import 'dart:convert';

import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/rules/bundled_community_subscriptions.dart';
import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/rules/rule_plugin_page.dart';
import 'package:anime/src/sources/source_catalog_models.dart';
import 'package:anime/src/sources/source_catalog_repository.dart';
import 'package:anime/src/sources/source_controller.dart';
import 'package:anime/src/sources/source_rule_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'remote bootstrap loads managed subscriptions from /api/v3/rules/bootstrap and returns empty when offline',
    () async {
      final requestedUris = <Uri>[];
      final repo = BundledCommunitySubscriptionRepository(
        client: MockClient((request) async {
          requestedUris.add(request.url);
          return http.Response.bytes(
            utf8.encode(jsonEncode(_sampleBootstrapPayload())),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );

      final empty = await repo.loadSeed(backendBaseUrl: '');
      expect(empty.isEmpty, isTrue);
      expect(requestedUris, isEmpty);

      final seed = await repo.loadSeed(
        backendBaseUrl: 'https://api.zeluna.example/',
      );
      expect(
        requestedUris.single.toString(),
        'https://api.zeluna.example/api/v3/rules/bootstrap',
      );
      expect(seed.version, currentCommunitySubscriptionSeedVersion);
      expect(seed.bundles, hasLength(2));
      for (final bundle in seed.bundles) {
        expect(bundle.managedInternal, isTrue);
        expect(bundle.rules.every((r) => r.managedInternal), isTrue);
      }

      // Offline / HTTP 500 degrades gracefully to empty.
      final offlineRepo = BundledCommunitySubscriptionRepository(
        client: MockClient((_) async => http.Response('err', 503)),
      );
      final failed = await offlineRepo.loadSeed(
        backendBaseUrl: 'https://api.zeluna.example',
      );
      expect(failed.isEmpty, isTrue);
    },
  );

  test(
    'SourceController silently provisions managed rules on fresh start and upgrades legacy accounts',
    () async {
      final seedRepo = BundledCommunitySubscriptionRepository(
        client: MockClient(
          (_) async => http.Response.bytes(
            utf8.encode(jsonEncode(_sampleBootstrapPayload())),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      );
      final storage = _MemorySourceStorage();
      final controller = SourceController(
        storage: storage,
        catalogRepository: const _EmptyCatalogRepository(),
        sourceRuleBridge: const SourceRuleBridge(),
        publishSnapshot: (_) {},
        communitySubscriptions: seedRepo,
        resolveBootstrapEndpoint: () => 'https://api.zeluna.example',
        now: () => DateTime.utc(2026, 11, 26),
      );
      addTearDown(controller.dispose);

      // 1. Fresh account installs & enables all managed bootstrap rules.
      final fresh = await controller.loadForAccount(
        accountId: 'fresh-account',
        contextVersion: 1,
      );
      final state = fresh.rulePlugins;
      expect(
        state.communitySeedVersion,
        currentCommunitySubscriptionSeedVersion,
      );
      expect(state.repositories, hasLength(2));
      expect(state.repositories.every((r) => r.managedInternal), isTrue);
      expect(state.repositories.every((r) => !r.autoRefresh), isTrue);
      expect(
        state.installedIds,
        containsAll(['managed:anime:sakura', 'managed:tvbox:resource1']),
      );
      expect(
        state.enabledIds,
        containsAll(['managed:anime:sakura', 'managed:tvbox:resource1']),
      );
      expect(state.customRules.every((r) => r.managedInternal), isTrue);

      // 2. Manual disable & uninstall choices persist across reloads.
      await controller.toggleRulePlugin('managed:anime:sakura', false);
      await controller.uninstallRulePlugin('managed:tvbox:resource1');
      final reloaded = await controller.loadForAccount(
        accountId: 'fresh-account',
        contextVersion: 2,
      );
      expect(
        reloaded.rulePlugins.enabledIds,
        isNot(contains('managed:anime:sakura')),
      );
      expect(
        reloaded.rulePlugins.installedIds,
        isNot(contains('managed:tvbox:resource1')),
      );

      // 3. Reset re-enables managed bootstrap rules.
      await controller.resetRulePlugins();
      expect(
        controller.snapshot.rulePlugins.enabledIds,
        containsAll(['managed:anime:sakura', 'managed:tvbox:resource1']),
      );

      // 4. Legacy v3.0.7 account (communitySeedVersion == 2 without managedInternal)
      //    upgrades cleanly: marks managed rules hidden and prunes stale dead rules.
      final staleDeadRule = _sampleRule(
        id: 'managed:tvbox:dead-stale',
        name: '已失效死链站',
        host: 'dead.example',
        sourceUrl: 'https://managed-sub.example/feed.json',
      );
      final legacyState = RulePluginState(
        communitySeedVersion: 2,
        installedIds: {'managed:tvbox:dead-stale', 'managed:tvbox:resource1'},
        enabledIds: {'managed:tvbox:dead-stale', 'managed:tvbox:resource1'},
        customRules: [
          staleDeadRule,
          _sampleRule(
            id: 'managed:tvbox:resource1',
            name: '资源站1',
            host: 'res1.example',
            sourceUrl: 'https://managed-sub.example/feed.json',
          ),
        ],
        repositories: [
          RuleRepositoryRecord(
            id: 'legacy-sub',
            name: '旧托管订阅',
            url: 'https://managed-sub.example/feed.json',
            importedAt: DateTime.utc(2026, 11, 20),
            ruleCount: 2,
            autoRefresh: true,
            managedInternal: false,
          ),
        ],
      );
      storage.values['account.legacy-v307.rulePlugins'] = legacyState.toJson();
      final upgraded = await controller.loadForAccount(
        accountId: 'legacy-v307',
        contextVersion: 3,
      );
      expect(
        upgraded.rulePlugins.communitySeedVersion,
        currentCommunitySubscriptionSeedVersion,
      );
      expect(
        upgraded.rulePlugins.customRules.any(
          (r) => r.id == 'managed:tvbox:dead-stale',
        ),
        isFalse,
      );
      expect(
        upgraded.rulePlugins.repositories.every((r) => r.managedInternal),
        isTrue,
      );
      expect(
        upgraded.rulePlugins.customRules.every((r) => r.managedInternal),
        isTrue,
      );
    },
  );

  testWidgets(
    'RuleManagementPage hides managed bootstrap subscriptions and rules while keeping them active',
    (tester) async {
      tester.view.physicalSize = const Size(430, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final seedRepo = BundledCommunitySubscriptionRepository(
        client: MockClient(
          (_) async => http.Response.bytes(
            utf8.encode(jsonEncode(_sampleBootstrapPayload())),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      );
      final storage = _MemorySourceStorage();
      final sourceController = SourceController(
        storage: storage,
        catalogRepository: const _EmptyCatalogRepository(),
        sourceRuleBridge: const SourceRuleBridge(),
        publishSnapshot: (_) {},
        communitySubscriptions: seedRepo,
        resolveBootstrapEndpoint: () => 'https://api.zeluna.example',
        now: () => DateTime.utc(2026, 11, 26),
      );
      addTearDown(sourceController.dispose);
      final seeded = (await tester.runAsync(
        () => sourceController.loadForAccount(
          accountId: 'ui-test',
          contextVersion: 1,
        ),
      ))!;

      // Underlying engine still keeps managed subscriptions installed and enabled.
      expect(seeded.rulePlugins.repositories, hasLength(2));
      expect(seeded.rulePlugins.enabledIds, hasLength(2));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            animeControllerProvider.overrideWith(
              () => _SeededUiAnimeController(seeded.rulePlugins),
            ),
          ],
          child: const MaterialApp(home: RuleManagementPage()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('开源社区订阅'), findsNothing);
      expect(find.textContaining('托管动漫源'), findsNothing);
      expect(find.textContaining('资源站1'), findsNothing);
      expect(find.textContaining('managed-sub.example'), findsNothing);
    },
  );
}

Map<String, dynamic> _sampleBootstrapPayload() {
  final animeRule = _sampleRule(
    id: 'managed:anime:sakura',
    name: '托管动漫源',
    host: 'anime.example',
    sourceUrl: 'zeluna://managed/default-rules',
    managedInternal: true,
  );
  final resourceRule = _sampleRule(
    id: 'managed:tvbox:resource1',
    name: '资源站1',
    host: 'res1.example',
    sourceUrl: 'https://managed-sub.example/feed.json',
    managedInternal: true,
  );
  return {
    'schema': 'zeluna-client-rules-v1',
    'version': currentCommunitySubscriptionSeedVersion,
    'generatedAt': '2026-11-26T00:00:00Z',
    'includeOptionalBuiltInRules': false,
    'subscriptions': [
      {
        'name': 'Zeluna 内置推荐规则',
        'sourceUrl': 'zeluna://managed/default-rules',
        'managedInternal': true,
        'rules': [animeRule.toJson()],
      },
      {
        'name': '托管聚合源',
        'sourceUrl': 'https://managed-sub.example/feed.json',
        'managedInternal': true,
        'rules': [resourceRule.toJson()],
      },
    ],
  };
}

RulePlugin _sampleRule({
  required String id,
  required String name,
  required String host,
  required String sourceUrl,
  bool managedInternal = false,
}) {
  final base = RulePlugin(
    id: id,
    name: name,
    version: '1.0',
    source: RuleSourceKind.custom,
    contentType: RuleContentType.anime,
    engine: 'tvbox-json-api',
    updatedAt: DateTime.utc(2026, 11, 26),
    qualityScore: 80,
    tags: const ['测试'],
    baseUrl: 'https://$host/api.php/provide/vod',
    searchUrl: 'https://$host/api.php/provide/vod',
    searchable: true,
    quickSearch: true,
    filterable: false,
    managedInternal: managedInternal,
    note: '从 $sourceUrl 导入。',
  );
  return base.copyWith(
    permissionManifest: base.effectiveManifest.copyWith(
      sourceRepository: sourceUrl,
    ),
  );
}

class _MemorySourceStorage implements SourceStorage {
  final Map<String, Object?> values = {};

  @override
  Object? get(String key) => values[key];

  @override
  Future<void> put(String key, Object? value) async {
    values[key] = value;
  }
}

class _EmptyCatalogRepository extends SourceCatalogRepository {
  const _EmptyCatalogRepository();

  @override
  Future<SourceCatalogState> loadCatalog({
    Map<String, bool> enabledOverrides = const {},
  }) async => const SourceCatalogState();
}

class _SeededUiAnimeController extends AnimeController {
  _SeededUiAnimeController(this._rulePlugins);

  final RulePluginState _rulePlugins;

  @override
  Future<AnimeState> build() async => AnimeState(
    homeFeed: const AnimeHomeFeed(
      hero: AnimeSubject(
        id: 1,
        title: '测试',
        originalTitle: 'Test',
        summary: '',
        coverUrl: null,
        bannerUrl: null,
        date: null,
        platform: '',
        language: '',
        region: '',
        status: '',
        categories: [],
        tags: [],
        totalEpisodes: 1,
      ),
      recent: [],
      recommended: [],
      index: [],
      categories: [],
      tags: [],
    ),
    rulePlugins: _rulePlugins,
  );
}
