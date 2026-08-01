import 'dart:async';

import 'package:anime/src/accounts/local_account_repository.dart';
import 'package:anime/src/rules/rule_importer.dart';
import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/rules/rule_security.dart';
import 'package:anime/src/sources/source_catalog_models.dart';
import 'package:anime/src/sources/source_catalog_repository.dart';
import 'package:anime/src/sources/source_controller.dart';
import 'package:anime/src/sources/source_rule_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('loads rule and source state from the selected account scope', () async {
    final storage = _MemorySourceStorage({
      'account.account-a.rulePlugins': RulePluginState(
        installedIds: {_importedRule.id},
        customRules: [_importedRule],
      ).toJson(),
      'account.account-a.sourceEnabled': const {'source:fixture': false},
    });
    final published = <SourceSnapshot>[];
    final controller = SourceController(
      storage: storage,
      catalogRepository: const _FixtureCatalogRepository(),
      sourceRuleBridge: const SourceRuleBridge(),
      publishSnapshot: published.add,
    );

    final accountA = await controller.loadForAccount(
      accountId: 'account-a',
      contextVersion: 1,
    );

    expect(
      accountA.rulePlugins.customRules.map((rule) => rule.id),
      contains(_importedRule.id),
    );
    expect(
      accountA.sourceCatalog.sourceById('source:fixture')!.enabled,
      isFalse,
    );
    expect(accountA.sourceCatalog.activePlaybackRuleCount, 0);

    final accountB = await controller.loadForAccount(
      accountId: 'account-b',
      contextVersion: 2,
    );

    expect(accountB.rulePlugins.customRules, isEmpty);
    expect(
      accountB.sourceCatalog.sourceById('source:fixture')!.enabled,
      isTrue,
    );
    expect(accountB.sourceCatalog.activePlaybackRuleCount, 3);
    expect(
      published,
      isEmpty,
      reason: 'scope loading is published atomically by the app owner',
    );
  });

  test(
    'imported trust claims stay disabled until their digest is approved',
    () async {
      final storage = _MemorySourceStorage();
      final controller = SourceController(
        storage: storage,
        catalogRepository: const _EmptyCatalogRepository(),
        sourceRuleBridge: const SourceRuleBridge(),
        publishSnapshot: (_) {},
        now: () => DateTime.utc(2026, 8, 1),
      );
      await controller.loadForAccount(
        accountId: 'account-a',
        contextVersion: 1,
      );

      final result = await controller.importSelectedRulePlugins(
        repositoryName: '测试仓库',
        rules: [_officialClaimingRule],
        sourceUrl: 'https://rules.example/index.json',
      );
      var state = controller.snapshot.rulePlugins;
      final imported = state.customRules.singleWhere(
        (rule) => rule.id == _officialClaimingRule.id,
      );

      expect(result.installedCount, 1);
      expect(imported.effectiveManifest.trustLevel, RuleTrustLevel.untrusted);
      expect(state.installedIds, contains(imported.id));
      expect(state.enabledIds, isNot(contains(imported.id)));

      await controller.toggleRulePlugin(imported.id, true);
      state = controller.snapshot.rulePlugins;
      expect(state.enabledIds, isNot(contains(imported.id)));

      await controller.setAllInstalledRulePluginsEnabled(true);
      state = controller.snapshot.rulePlugins;
      expect(state.enabledIds, isNot(contains(imported.id)));

      await controller.approveRulePluginPermissionsAndEnable(imported.id);
      state = controller.snapshot.rulePlugins;
      expect(state.enabledIds, contains(imported.id));
      expect(
        state.approvedPermissionDigests[imported.id],
        imported.effectiveManifest.permissionDigest,
      );
      final persisted = storage.values['account.account-a.rulePlugins'];
      expect(persisted, isA<Map<String, dynamic>>());
    },
  );

  test(
    'a slow repository import cannot write into a newer account scope',
    () async {
      final storage = _MemorySourceStorage();
      final importer = _DeferredRuleImporter();
      final controller = SourceController(
        storage: storage,
        catalogRepository: const _EmptyCatalogRepository(),
        sourceRuleBridge: const SourceRuleBridge(),
        publishSnapshot: (_) {},
        importer: importer,
      );
      await controller.loadForAccount(
        accountId: 'account-a',
        contextVersion: 1,
      );

      final import = controller.importRuleRepositoryUrl(
        'https://rules.example/index.json',
      );
      final rejected = expectLater(import, throwsA(isA<AccountException>()));
      await importer.started.future;
      await controller.loadForAccount(
        accountId: 'account-b',
        contextVersion: 2,
      );
      importer.response.complete(
        RuleImportBundle(
          name: '旧账号仓库',
          rules: [_officialClaimingRule],
          sourceUrl: 'https://rules.example/index.json',
        ),
      );
      await rejected;

      expect(controller.snapshot.rulePlugins.customRules, isEmpty);
      expect(storage.values['account.account-b.rulePlugins'], isNull);
    },
  );

  test('stale hydration is discarded after an account switch', () async {
    final storage = _MemorySourceStorage();
    final bridge = _DeferredSourceRuleBridge();
    final controller = SourceController(
      storage: storage,
      catalogRepository: const _FixtureCatalogRepository(),
      sourceRuleBridge: bridge,
      publishSnapshot: (_) {},
    );
    await controller.loadForAccount(accountId: 'account-a', contextVersion: 1);

    final hydration = controller.setVideoSourcesEnabled({
      'source:fixture',
    }, true);
    await bridge.started.future;
    await controller.loadForAccount(accountId: 'account-b', contextVersion: 2);
    bridge.response.complete(
      SourceRuleBridgeResult(
        rules: [_hydratedRule],
        ruleCountsBySource: {'source:fixture': 1},
        availableRuleCount: 1,
      ),
    );
    await hydration;

    expect(controller.accountId, 'account-b');
    expect(controller.snapshot.sourceCatalog.activePlaybackRuleCount, 0);
    expect(
      controller.snapshot.sourceCatalog.playbackRuleCountFor('source:fixture'),
      0,
    );
  });

  test(
    'source writes finish in their captured scope before scope loading',
    () async {
      final storage = _GatedSourceStorage();
      final controller = SourceController(
        storage: storage,
        catalogRepository: const _FixtureCatalogRepository(),
        sourceRuleBridge: const SourceRuleBridge(),
        publishSnapshot: (_) {},
      );
      await controller.loadForAccount(
        accountId: 'account-a',
        contextVersion: 1,
      );

      final disabling = controller.setVideoSourcesEnabled({
        'source:fixture',
      }, false);
      await storage.writeStarted.future;
      final switching = controller.loadForAccount(
        accountId: 'account-b',
        contextVersion: 2,
      );
      expect(controller.accountId, 'account-a');
      storage.releaseWrite.complete();
      await disabling;
      await switching;

      expect(storage.values['account.account-a.sourceEnabled'], {
        'source:fixture': false,
      });
      expect(storage.values['account.account-b.sourceEnabled'], isNull);
      expect(
        controller.snapshot.sourceCatalog.sourceById('source:fixture')!.enabled,
        isTrue,
      );
    },
  );

  test('mutations are rejected while a new account scope is loading', () async {
    final storage = _MemorySourceStorage();
    final repository = _DeferredSwitchCatalogRepository();
    final controller = SourceController(
      storage: storage,
      catalogRepository: repository,
      sourceRuleBridge: const SourceRuleBridge(),
      publishSnapshot: (_) {},
    );
    await controller.loadForAccount(accountId: 'account-a', contextVersion: 1);

    final switching = controller.loadForAccount(
      accountId: 'account-b',
      contextVersion: 2,
    );
    await repository.switchStarted.future;
    expect(
      () => controller.importSelectedRulePlugins(
        repositoryName: '过期页面操作',
        rules: [_officialClaimingRule],
      ),
      throwsA(isA<StateError>()),
    );
    repository.releaseSwitch.complete();
    await switching;

    expect(controller.accountId, 'account-b');
    expect(controller.snapshot.rulePlugins.customRules, isEmpty);
    expect(storage.values['account.account-b.rulePlugins'], isNull);
  });
}

class _MemorySourceStorage implements SourceStorage {
  _MemorySourceStorage([Map<String, Object?> initial = const {}])
    : values = {...initial};

  final Map<String, Object?> values;

  @override
  Object? get(String key) => values[key];

  @override
  Future<void> put(String key, Object? value) async {
    values[key] = value;
  }
}

final class _GatedSourceStorage extends _MemorySourceStorage {
  final writeStarted = Completer<void>();
  final releaseWrite = Completer<void>();

  @override
  Future<void> put(String key, Object? value) async {
    if (!writeStarted.isCompleted) writeStarted.complete();
    await releaseWrite.future;
    await super.put(key, value);
  }
}

class _EmptyCatalogRepository extends SourceCatalogRepository {
  const _EmptyCatalogRepository();

  @override
  Future<SourceCatalogState> loadCatalog({
    Map<String, bool> enabledOverrides = const {},
  }) async => const SourceCatalogState();
}

class _FixtureCatalogRepository extends SourceCatalogRepository {
  const _FixtureCatalogRepository();

  @override
  Future<SourceCatalogState> loadCatalog({
    Map<String, bool> enabledOverrides = const {},
  }) async => const SourceCatalogState(
    version: 3,
    totalSources: 1,
    sources: [_fixtureSource],
  ).applyEnabledOverrides(enabledOverrides);
}

final class _DeferredSwitchCatalogRepository extends SourceCatalogRepository {
  var _calls = 0;
  final switchStarted = Completer<void>();
  final releaseSwitch = Completer<void>();

  @override
  Future<SourceCatalogState> loadCatalog({
    Map<String, bool> enabledOverrides = const {},
  }) async {
    _calls++;
    if (_calls == 1) return const SourceCatalogState();
    if (!switchStarted.isCompleted) switchStarted.complete();
    await releaseSwitch.future;
    return const SourceCatalogState();
  }
}

final class _DeferredRuleImporter extends RuleImporter {
  final started = Completer<void>();
  final response = Completer<RuleImportBundle>();

  @override
  Future<RuleImportBundle> importFromUrl(String url) {
    if (!started.isCompleted) started.complete();
    return response.future;
  }
}

final class _DeferredSourceRuleBridge extends SourceRuleBridge {
  final started = Completer<void>();
  final response = Completer<SourceRuleBridgeResult>();

  @override
  SourceRuleBridgeResult build(SourceCatalogState catalog) =>
      const SourceRuleBridgeResult(
        rules: [],
        ruleCountsBySource: {'source:fixture': 0},
        availableRuleCount: 0,
      );

  @override
  Future<SourceRuleBridgeResult> buildHydrated(SourceCatalogState catalog) {
    if (!started.isCompleted) started.complete();
    return response.future;
  }
}

const _fixtureSource = VideoSource(
  id: 'source:fixture',
  name: '测试源',
  kind: VideoSourceKind.tvBox,
  importUrl: 'https://catalog.example/index.json',
  baseUrl: 'https://catalog.example/index.json',
  rawConfig: {
    'sites': [
      {
        'key': 'fixture',
        'name': '测试源',
        'type': 1,
        'api': 'https://media.example/api.php/provide/vod',
      },
    ],
  },
);

final _importedRule = _rule(
  id: 'custom:persisted-source-controller',
  manifest: const RulePermissionManifest.untrusted(
    id: 'custom:persisted-source-controller',
    name: '持久化规则',
    version: '1.0',
    engine: 'tvbox-json-api',
    contentTypes: ['anime'],
    pageDomains: ['persisted.example'],
    mediaDomains: ['persisted.example'],
  ),
);

final _officialClaimingRule = _rule(
  id: 'custom:official-claim',
  manifest: const RulePermissionManifest.official(
    id: 'custom:official-claim',
    name: '自称官方规则',
    version: '1.0',
    engine: 'tvbox-json-api',
    contentTypes: ['anime'],
    pageDomains: ['rules.example'],
    mediaDomains: ['rules.example'],
  ),
);

final _hydratedRule = _rule(
  id: 'catalog:source:fixture:hydrated',
  manifest: const RulePermissionManifest.untrusted(
    id: 'catalog:source:fixture:hydrated',
    name: 'Hydrated',
    version: '1.0',
    engine: 'tvbox-json-api',
    contentTypes: ['anime'],
    pageDomains: ['media.example'],
    mediaDomains: ['media.example'],
  ),
);

RulePlugin _rule({
  required String id,
  required RulePermissionManifest manifest,
}) => RulePlugin(
  id: id,
  name: manifest.name,
  version: manifest.version,
  source: RuleSourceKind.custom,
  contentType: RuleContentType.anime,
  engine: 'tvbox-json-api',
  updatedAt: DateTime.utc(2026, 8, 1),
  qualityScore: 80,
  tags: const ['test'],
  baseUrl: 'https://media.example/api.php/provide/vod',
  searchUrl: 'https://media.example/api.php/provide/vod?wd={wd}',
  searchable: true,
  quickSearch: true,
  filterable: false,
  permissionManifest: manifest,
);
