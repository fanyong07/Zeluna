import 'dart:async';

import 'package:hive_ce_flutter/hive_flutter.dart';

import '../accounts/account_controller.dart';
import '../accounts/local_account_repository.dart';
import '../core/identity/stable_identity.dart';
import '../rules/rule_importer.dart';
import '../rules/rule_models.dart';
import '../rules/rule_plugin_repository.dart';
import '../rules/rule_security.dart';
import 'source_catalog_models.dart';
import 'source_catalog_repository.dart';
import 'source_rule_bridge.dart';

abstract interface class SourceStorage {
  Object? get(String key);

  Future<void> put(String key, Object? value);
}

final class HiveSourceStorage implements SourceStorage {
  const HiveSourceStorage(this._box);

  final Box<dynamic> _box;

  @override
  Object? get(String key) => _box.get(key);

  @override
  Future<void> put(String key, Object? value) => _box.put(key, value);
}

typedef SourceSnapshotPublisher = void Function(SourceSnapshot snapshot);

final class SourceSnapshot {
  const SourceSnapshot({
    this.rulePlugins = const RulePluginState(),
    this.sourceCatalog = const SourceCatalogState(),
  });

  final RulePluginState rulePlugins;
  final SourceCatalogState sourceCatalog;

  SourceSnapshot copyWith({
    RulePluginState? rulePlugins,
    SourceCatalogState? sourceCatalog,
  }) => SourceSnapshot(
    rulePlugins: rulePlugins ?? this.rulePlugins,
    sourceCatalog: sourceCatalog ?? this.sourceCatalog,
  );
}

final class RuleRepositoryRefreshResult {
  const RuleRepositoryRefreshResult({
    required this.repositoryCount,
    required this.refreshedCount,
    required this.failedCount,
    required this.ruleCount,
  });

  final int repositoryCount;
  final int refreshedCount;
  final int failedCount;
  final int ruleCount;

  bool get hasRemoteRepositories => repositoryCount > 0;
}

/// Owns account-scoped rule inventory, permissions, source-catalog state,
/// ordered persistence, repository imports, and guarded source hydration.
///
/// Network imports finish outside the mutation queue. Their captured account
/// scope is checked again before applying, so a slow old-account request can
/// never write into the newly selected account.
final class SourceController {
  SourceController({
    required SourceStorage storage,
    required SourceCatalogRepository catalogRepository,
    required SourceRuleBridge sourceRuleBridge,
    required SourceSnapshotPublisher publishSnapshot,
    RuleImporter importer = const RuleImporter(),
    DateTime Function()? now,
  }) : _storage = storage,
       _catalogRepository = catalogRepository,
       _sourceRuleBridge = sourceRuleBridge,
       _publishSnapshot = publishSnapshot,
       _importer = importer,
       _now = now ?? DateTime.now;

  final SourceStorage _storage;
  final SourceCatalogRepository _catalogRepository;
  final SourceRuleBridge _sourceRuleBridge;
  final SourceSnapshotPublisher _publishSnapshot;
  final RuleImporter _importer;
  final DateTime Function() _now;
  static const _subscriptionRefreshInterval = Duration(hours: 6);

  SourceSnapshot _snapshot = const SourceSnapshot();
  String? _accountId;
  var _contextVersion = 0;
  var _loaded = false;
  var _loadVersion = 0;
  var _hydrationVersion = 0;
  Future<void> _mutationQueue = Future<void>.value();
  Timer? _subscriptionRefreshTimer;

  SourceSnapshot get snapshot => _snapshot;
  String? get accountId => _accountId;
  int get contextVersion => _contextVersion;
  bool get isLoaded => _loaded;

  Future<void> settleWrites() => _mutationQueue;

  RulePluginRepository repositoryFor(RulePluginState state) =>
      RulePluginRepository(extraRules: state.customRules);

  Future<SourceSnapshot> loadForAccount({
    required String? accountId,
    required int contextVersion,
  }) {
    _subscriptionRefreshTimer?.cancel();
    final loadVersion = ++_loadVersion;
    return _enqueue(() async {
      _loaded = false;
      _accountId = accountId;
      _contextVersion = contextVersion;
      _hydrationVersion++;

      final rulePlugins = _restoreRulePlugins(
        _storage.get(
          AccountController.settingsKeyFor(accountId, 'rulePlugins'),
        ),
      );
      final enabledOverrides = _enabledOverridesFromJson(
        _storage.get(
          AccountController.settingsKeyFor(accountId, 'sourceEnabled'),
        ),
      );
      SourceCatalogState loadedCatalog;
      try {
        loadedCatalog = await _catalogRepository.loadCatalog(
          enabledOverrides: enabledOverrides,
        );
      } catch (error) {
        loadedCatalog = SourceCatalogState.failed(error);
      }
      if (loadVersion != _loadVersion ||
          _accountId != accountId ||
          _contextVersion != contextVersion) {
        throw const AccountException('账号已切换，请重新打开线路管理');
      }
      final bridge = _sourceRuleBridge.build(loadedCatalog);
      _snapshot = SourceSnapshot(
        rulePlugins: rulePlugins,
        sourceCatalog: bridge.attachTo(loadedCatalog),
      );
      _loaded = true;
      return _snapshot;
    });
  }

  /// Start only after the owner has published the loaded account snapshot.
  void startSubscriptionRefresh() {
    _subscriptionRefreshTimer?.cancel();
    final scope = _scope();
    void refreshDue() {
      if (!_isCurrent(scope.accountId, scope.contextVersion)) return;
      unawaited(
        _refreshRuleRepositories(
          scope,
          dueOnly: true,
        ).then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
    }

    _subscriptionRefreshTimer = Timer.periodic(
      const Duration(hours: 1),
      (_) => refreshDue(),
    );
    refreshDue();
  }

  void dispose() {
    _subscriptionRefreshTimer?.cancel();
    _loaded = false;
    _loadVersion++;
  }

  Future<void> installRulePlugin(String id) {
    final scope = _scope();
    return _mutate(scope, () async {
      final current = _snapshot.rulePlugins;
      final repository = repositoryFor(current);
      final rule = repository.byId(id);
      final installed = {...current.installedIds, id};
      final enabled = {...current.enabledIds};
      if (rule != null &&
          rule.canResolveNatively &&
          repository.canEnableRule(rule, current)) {
        enabled.add(id);
      }
      await _replaceRulePlugins(
        scope,
        current.copyWith(
          installedIds: installed,
          enabledIds: enabled,
          uninstalledIds: {...current.uninstalledIds}..remove(id),
        ),
      );
    });
  }

  Future<void> uninstallRulePlugin(String id) {
    final scope = _scope();
    return _mutate(scope, () async {
      final current = _snapshot.rulePlugins;
      final installed = {...current.installedIds}..remove(id);
      final enabled = {...current.enabledIds}..remove(id);
      final approvals = {...current.approvedPermissionDigests}..remove(id);
      await _replaceRulePlugins(
        scope,
        current.copyWith(
          installedIds: installed,
          enabledIds: enabled,
          approvedPermissionDigests: approvals,
          uninstalledIds: {...current.uninstalledIds, id},
        ),
      );
    });
  }

  Future<void> toggleRulePlugin(String id, bool enabled) {
    final scope = _scope();
    return _mutate(scope, () async {
      final current = _snapshot.rulePlugins;
      if (!current.installedIds.contains(id)) return;
      final enabledIds = {...current.enabledIds};
      if (enabled) {
        final repository = repositoryFor(current);
        final rule = repository.byId(id);
        if (rule == null || !repository.canEnableRule(rule, current)) return;
        enabledIds.add(id);
      } else {
        enabledIds.remove(id);
      }
      await _replaceRulePlugins(
        scope,
        current.copyWith(enabledIds: enabledIds),
      );
    });
  }

  Future<void> approveRulePluginPermissionsAndEnable(String id) {
    final scope = _scope();
    return _mutate(scope, () async {
      final current = _snapshot.rulePlugins;
      if (!current.installedIds.contains(id)) return;
      final rule = repositoryFor(current).byId(id);
      if (rule == null || !rule.canResolveNatively) return;
      final approvals = {...current.approvedPermissionDigests};
      if (rule.effectiveManifest.requiresApproval) {
        approvals[id] = rule.effectiveManifest.permissionDigest;
      }
      await _replaceRulePlugins(
        scope,
        current.copyWith(
          enabledIds: {...current.enabledIds, id},
          approvedPermissionDigests: approvals,
        ),
      );
    });
  }

  Future<void> setInstalledRulePluginsEnabled(
    Iterable<String> ids,
    bool enabled,
  ) {
    final scope = _scope();
    return _mutate(scope, () async {
      final current = _snapshot.rulePlugins;
      final targets = ids.toSet().intersection(current.installedIds);
      if (targets.isEmpty) return;
      final enabledIds = {...current.enabledIds};
      if (enabled) {
        enabledIds.addAll(targets);
      } else {
        enabledIds.removeAll(targets);
      }
      await _replaceRulePlugins(
        scope,
        current.copyWith(enabledIds: enabledIds),
      );
    });
  }

  Future<RuleRepositoryRefreshResult> refreshRuleRepositories() =>
      _refreshRuleRepositories(_scope(), dueOnly: false);

  Future<RuleRepositoryRefreshResult> _refreshRuleRepositories(
    ({String? accountId, int contextVersion}) scope, {
    required bool dueOnly,
  }) async {
    if (!dueOnly) {
      await _mutate(scope, () async {
        final current = _snapshot.rulePlugins;
        final updated = _installNewRecommendedRules(current);
        if (!identical(current, updated)) {
          await _replaceRulePlugins(scope, updated);
        }
      });
    }
    _ensureScope(scope);
    final cutoff = _now().subtract(_subscriptionRefreshInterval);
    final repositories = [
      for (final record in _snapshot.rulePlugins.repositories)
        if (record.url.trim().isNotEmpty &&
            (!dueOnly ||
                (record.autoRefresh && !record.importedAt.isAfter(cutoff))))
          record,
    ];
    var refreshedCount = 0;
    var failedCount = 0;
    var ruleCount = 0;
    for (final repository in repositories) {
      _ensureScope(scope);
      try {
        final bundle = await _importer.importFromUrl(repository.url);
        final result = await _importRuleBundle(
          bundle,
          scope: scope,
          refreshing: repository,
        );
        refreshedCount++;
        ruleCount += result.installedCount;
      } on AccountException {
        rethrow;
      } catch (_) {
        failedCount++;
      }
    }
    return RuleRepositoryRefreshResult(
      repositoryCount: repositories.length,
      refreshedCount: refreshedCount,
      failedCount: failedCount,
      ruleCount: ruleCount,
    );
  }

  Future<void> setAllInstalledRulePluginsEnabled(bool enabled) async {
    final scope = _scope();
    final hydration = await _mutate(scope, () async {
      final currentRules = _snapshot.rulePlugins;
      final currentCatalog = _snapshot.sourceCatalog;
      final rulePlugins = _normalizeRulePlugins(
        currentRules.copyWith(
          enabledIds: enabled ? {...currentRules.installedIds} : <String>{},
        ),
      );
      final toggledCatalog = currentCatalog.copyWith(
        sources: [
          for (final source in currentCatalog.sources)
            currentCatalog.playbackRuleCountFor(source.id) > 0 ||
                    _sourceRuleBridge.mayContributePlaybackRules(source)
                ? source.copyWith(enabled: enabled)
                : source,
        ],
        loadError: currentCatalog.loadError,
      );
      final bridge = _sourceRuleBridge.build(toggledCatalog);
      final sourceCatalog = bridge.attachTo(toggledCatalog);
      final hydrationVersion = ++_hydrationVersion;
      _publish(
        _snapshot.copyWith(
          rulePlugins: rulePlugins,
          sourceCatalog: sourceCatalog,
        ),
      );
      await _storage.put(
        AccountController.settingsKeyFor(scope.accountId, 'rulePlugins'),
        rulePlugins.toJson(),
      );
      await _storage.put(
        AccountController.settingsKeyFor(scope.accountId, 'sourceEnabled'),
        sourceCatalog.enabledById,
      );
      return (catalog: toggledCatalog, version: hydrationVersion);
    });
    await _hydrateAndApply(hydration.catalog, hydration.version, scope);
  }

  Future<void> resetRulePlugins() {
    final scope = _scope();
    return _mutate(scope, () async {
      final current = _snapshot.rulePlugins;
      final defaults = RulePluginRepository(
        extraRules: current.customRules,
      ).defaultState();
      await _replaceRulePlugins(
        scope,
        defaults.copyWith(
          customRules: current.customRules,
          repositories: current.repositories,
        ),
      );
    });
  }

  Future<RuleImportResult> importRuleRepositoryUrl(String url) async {
    final scope = _scope();
    final bundle = await _importer.importFromUrl(url);
    _ensureScope(scope);
    return _importRuleBundle(bundle, scope: scope);
  }

  Future<RuleImportResult> importRuleRepositoryText(String text) {
    final scope = _scope();
    final bundle = _importer.importFromText(text);
    return _importRuleBundle(bundle, scope: scope);
  }

  Future<RuleImportResult> importSelectedRulePlugins({
    required String repositoryName,
    required List<RulePlugin> rules,
    String sourceUrl = '',
    bool enable = false,
  }) {
    final scope = _scope();
    return _importRuleBundle(
      RuleImportBundle(
        name: repositoryName,
        rules: List<RulePlugin>.unmodifiable(rules),
        sourceUrl: sourceUrl,
      ),
      scope: scope,
      enable: enable,
    );
  }

  Future<void> toggleVideoSource(String id, bool enabled) =>
      setVideoSourcesEnabled({id}, enabled);

  Future<void> setVideoSourcesEnabled(
    Iterable<String> ids,
    bool enabled,
  ) async {
    final scope = _scope();
    final hydration = await _mutate(scope, () async {
      final current = _snapshot.sourceCatalog;
      final sourceIds = ids.toSet();
      if (sourceIds.isEmpty ||
          !current.sources.any((source) => sourceIds.contains(source.id))) {
        return null;
      }
      final toggledCatalog = current.copyWith(
        sources: [
          for (final source in current.sources)
            sourceIds.contains(source.id)
                ? source.copyWith(enabled: enabled)
                : source,
        ],
        loadError: current.loadError,
      );
      final bridge = _sourceRuleBridge.build(toggledCatalog);
      final sourceCatalog = bridge.attachTo(toggledCatalog);
      final hydrationVersion = ++_hydrationVersion;
      _publish(_snapshot.copyWith(sourceCatalog: sourceCatalog));
      await _storage.put(
        AccountController.settingsKeyFor(scope.accountId, 'sourceEnabled'),
        sourceCatalog.enabledById,
      );
      return (catalog: toggledCatalog, version: hydrationVersion);
    });
    if (hydration == null) return;
    await _hydrateAndApply(hydration.catalog, hydration.version, scope);
  }

  Future<RuleImportResult> _importRuleBundle(
    RuleImportBundle bundle, {
    required ({String? accountId, int contextVersion}) scope,
    bool enable = false,
    RuleRepositoryRecord? refreshing,
  }) async {
    _ensureScope(scope);
    if (bundle.rules.isEmpty) {
      return RuleImportResult(
        repositoryName: bundle.name,
        ruleCount: 0,
        installedCount: 0,
      );
    }
    return _mutate(scope, () async {
      final current = _snapshot.rulePlugins;
      final sourceUrl = bundle.sourceUrl.trim();
      final recordId = sourceUrl.isEmpty
          ? 'clipboard:${_stableRuleBundleId(bundle)}'
          : 'url:${_stableRuleRepositoryId(sourceUrl)}';
      final previous = current.repositories
          .where(
            (record) =>
                record.id == recordId ||
                (sourceUrl.isNotEmpty && record.url.trim() == sourceUrl),
          )
          .firstOrNull;
      if (refreshing != null && !identical(previous, refreshing)) {
        throw StateError('订阅已被更新，请重新刷新');
      }
      bool belongsToRepository(RulePlugin rule) =>
          sourceUrl.isNotEmpty &&
          (rule.permissionManifest?.sourceRepository ??
                  rule.effectiveManifest.sourceRepository) ==
              (previous?.url.trim() ?? sourceUrl);
      final subscribed =
          sourceUrl.isNotEmpty && (enable || previous?.autoRefresh == true);
      final replaceSubscription = subscribed && (enable || refreshing != null);
      final prior = {for (final rule in current.customRules) rule.id: rule};
      final importedRules = [
        for (final rule in bundle.rules)
          // Refresh cannot take over a rule owned by another subscription or
          // add unselected entries to a legacy, install-only repository.
          if (refreshing == null ||
              (prior[rule.id] == null
                  ? subscribed
                  : belongsToRepository(prior[rule.id]!)))
            rule.copyWith(
              permissionManifest: rule.effectiveManifest.copyWith(
                sourceRepository: sourceUrl,
                contentHash: '',
                trustLevel: RuleTrustLevel.untrusted,
              ),
            ),
      ];
      final removedIds = <String>{
        if (replaceSubscription)
          for (final rule in current.customRules)
            if (belongsToRepository(rule)) rule.id,
      };
      final existing = {...prior}
        ..removeWhere((id, _) => removedIds.contains(id));
      for (final rule in importedRules) {
        existing[rule.id] = rule;
        removedIds.remove(rule.id);
      }
      final mergedCustomRules = existing.values.toList(growable: false);
      final mergedRepository = RulePluginRepository(
        extraRules: mergedCustomRules,
      );
      final matches = mergedRepository.byIds(
        importedRules.map((rule) => rule.id),
      );
      final effectiveRuleIds = <String>{};
      final approvals = {...current.approvedPermissionDigests};
      final approvedIds = <String>{};
      for (final rule in importedRules) {
        final effectiveRule = matches[rule.id];
        if (effectiveRule == null) continue;
        effectiveRuleIds.add(effectiveRule.id);
        final manifest = effectiveRule.effectiveManifest;
        if (enable &&
            effectiveRule.canResolveNatively &&
            manifest.permissionDigest ==
                rule.effectiveManifest.permissionDigest) {
          approvals[effectiveRule.id] = manifest.permissionDigest;
          approvedIds.add(effectiveRule.id);
        }
      }
      if (refreshing != null) {
        effectiveRuleIds.removeAll(current.uninstalledIds);
      }
      final repositoryRecord = RuleRepositoryRecord(
        id: recordId,
        name: bundle.name,
        url: sourceUrl,
        importedAt: _now(),
        ruleCount: effectiveRuleIds.length,
        autoRefresh: subscribed,
      );
      final repositories = [
        repositoryRecord,
        ...current.repositories.where((record) => !identical(record, previous)),
      ];
      await _replaceRulePlugins(
        scope,
        current.copyWith(
          installedIds: {
            ...current.installedIds.difference(removedIds),
            ...effectiveRuleIds,
          },
          enabledIds: {
            ...current.enabledIds.difference(removedIds),
            ...approvedIds,
          },
          approvedPermissionDigests: approvals,
          customRules: mergedCustomRules,
          repositories: repositories,
        ),
      );
      return RuleImportResult(
        repositoryName: bundle.name,
        ruleCount: bundle.rules.length,
        installedCount: effectiveRuleIds.length,
        enabledCount: _snapshot.rulePlugins.enabledIds
            .intersection(approvedIds)
            .length,
      );
    });
  }

  Future<void> _hydrateAndApply(
    SourceCatalogState catalog,
    int hydrationVersion,
    ({String? accountId, int contextVersion}) scope,
  ) async {
    if (!_isCurrent(scope.accountId, scope.contextVersion) ||
        hydrationVersion != _hydrationVersion) {
      return;
    }
    final hydrated = await _sourceRuleBridge.buildHydrated(catalog);
    if (!_isCurrent(scope.accountId, scope.contextVersion) ||
        hydrationVersion != _hydrationVersion) {
      return;
    }
    await _mutate(scope, () async {
      if (hydrationVersion != _hydrationVersion) return;
      _publish(
        _snapshot.copyWith(
          sourceCatalog: hydrated.attachTo(_snapshot.sourceCatalog),
        ),
      );
    });
  }

  Future<void> _replaceRulePlugins(
    ({String? accountId, int contextVersion}) scope,
    RulePluginState value,
  ) async {
    final normalized = _normalizeRulePlugins(value);
    _publish(_snapshot.copyWith(rulePlugins: normalized));
    await _storage.put(
      AccountController.settingsKeyFor(scope.accountId, 'rulePlugins'),
      normalized.toJson(),
    );
  }

  RulePluginState _normalizeRulePlugins(RulePluginState value) =>
      repositoryFor(value).normalizeState(value);

  RulePluginState _restoreRulePlugins(Object? value) {
    if (value is! Map) return const RulePluginRepository().defaultState();
    try {
      return _installNewRecommendedRules(
        _normalizeRulePlugins(
          RulePluginState.fromJson(value.cast<String, dynamic>()),
        ),
      );
    } catch (_) {
      return const RulePluginRepository().defaultState();
    }
  }

  RulePluginState _installNewRecommendedRules(RulePluginState state) {
    final repository = repositoryFor(state);
    final defaults = repository.defaultState();
    final missing = defaults.installedIds
        .difference(state.installedIds)
        .difference(state.uninstalledIds);
    if (missing.isEmpty) return state;
    return repository.normalizeState(
      state.copyWith(
        installedIds: {...state.installedIds, ...missing},
        enabledIds: {
          ...state.enabledIds,
          ...defaults.enabledIds.intersection(missing),
        },
      ),
    );
  }

  void _publish(SourceSnapshot value) {
    _snapshot = value;
    _publishSnapshot(value);
  }

  Future<T> _mutate<T>(
    ({String? accountId, int contextVersion}) scope,
    Future<T> Function() action,
  ) => _enqueue(() async {
    _ensureScope(scope);
    return action();
  });

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final operation = _mutationQueue.then((_) => action());
    _mutationQueue = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  ({String? accountId, int contextVersion}) _scope() {
    if (!_loaded) throw StateError('SourceController has not been loaded');
    return (accountId: _accountId, contextVersion: _contextVersion);
  }

  bool _isCurrent(String? accountId, int contextVersion) =>
      _loaded && _accountId == accountId && _contextVersion == contextVersion;

  void _ensureScope(({String? accountId, int contextVersion}) scope) {
    if (!_isCurrent(scope.accountId, scope.contextVersion)) {
      throw const AccountException('账号已切换，请在当前账号下重新操作');
    }
  }
}

Map<String, bool> _enabledOverridesFromJson(Object? value) {
  if (value is! Map) return const {};
  return {
    for (final entry in value.entries)
      if (entry.key.toString().trim().isNotEmpty && entry.value is bool)
        entry.key.toString(): entry.value as bool,
  };
}

String _stableRuleRepositoryId(String value) {
  final normalized = value.trim();
  String canonical;
  try {
    canonical = canonicalIdentityUri(normalized);
  } on FormatException {
    canonical = normalized;
  }
  return stableDigest(
    'rule-repository|$stableIdentityVersion|$canonical',
  ).substring(0, 32);
}

String _stableRuleBundleId(RuleImportBundle bundle) {
  final identities =
      bundle.rules
          .map(
            (rule) => stableRuleKey(
              ruleId: rule.id,
              engine: rule.engine,
              sourceRepository: rule.baseUrl,
              contentHash: stableDigest(
                '${rule.searchUrl}|${rule.contentType.name}|${rule.version}',
              ),
            ),
          )
          .toList(growable: false)
        ..sort();
  return stableDigest(
    'rule-bundle|$stableIdentityVersion|${bundle.name.trim()}|${identities.join('|')}',
  ).substring(0, 32);
}
