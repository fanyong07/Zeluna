import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'csp_rule_support.dart';
import 'rule_models.dart';
import 'rule_security.dart';

class RulePluginRepository {
  const RulePluginRepository({this.extraRules = const []});

  final List<RulePlugin> extraRules;

  static final _RuleCollection _builtInCollection = _collectRules(
    _verifiedBuiltInRules,
    const [],
  );

  static final List<({List<RulePlugin> extraRules, _RuleCollection collection})>
  _recentCollections = [];

  _RuleCollection get _collection {
    if (extraRules.isEmpty) return _builtInCollection;
    for (final entry in _recentCollections) {
      if (identical(entry.extraRules, extraRules)) {
        return entry.collection;
      }
    }
    final built = _collectRules(_verifiedBuiltInRules, extraRules);
    _recentCollections.insert(0, (extraRules: extraRules, collection: built));
    if (_recentCollections.length > 4) {
      _recentCollections.removeLast();
    }
    return built;
  }

  List<RulePlugin> get allRules => _collection.rules;

  List<RulePlugin> rulesFor(RuleContentType type) {
    return allRules
        .where((rule) => rule.supportsContentType(type))
        .toList(growable: false);
  }

  List<RulePlugin> installedRules(RulePluginState state) {
    final collection = _collection;
    return collection.rules
        .where((rule) => collection.anyAliasIn(rule.id, state.installedIds))
        .toList(growable: false);
  }

  List<RulePlugin> enabledRulesFor(
    RulePluginState state,
    RuleContentType type,
  ) {
    final collection = _collection;
    return collection.rules
        .where(
          (rule) =>
              rule.supportsContentType(type) &&
              collection.anyAliasIn(rule.id, state.installedIds) &&
              collection.anyAliasIn(rule.id, state.enabledIds) &&
              canEnableRule(rule, state),
        )
        .toList(growable: false);
  }

  List<RulePlugin> playbackRulesFor(
    RulePluginState state,
    RuleContentType type,
  ) {
    return enabledRulesFor(state, type)
        .where(
          (rule) =>
              rule.searchable &&
              rule.canResolveNatively &&
              _canExecuteOnCurrentPlatform(rule),
        )
        .toList(growable: false);
  }

  RulePluginState defaultState() {
    final collection = _collection;
    final installed = {
      for (final rule in collection.rules)
        if (collection
            .aliasRules(rule.id)
            .any((candidate) => candidate.installedByDefault))
          rule.id,
    };
    final enabled = {
      for (final rule in allRules)
        if (installed.contains(rule.id) &&
            rule.effectiveManifest.trustLevel == RuleTrustLevel.official &&
            rule.canResolveNatively &&
            _canExecuteOnCurrentPlatform(rule))
          rule.id,
    };
    return RulePluginState(
      installedIds: installed,
      enabledIds: enabled,
      customRules: collection.rules
          .where((rule) => extraRules.any((extra) => extra.id == rule.id))
          .toList(growable: false),
    );
  }

  RulePlugin? byId(String id) => _collection.byId(id);

  /// Resolves a whole import against one canonicalized inventory.
  Map<String, RulePlugin> byIds(Iterable<String> ids) {
    final collection = _collection;
    return {for (final id in ids) id: ?collection.byId(id)};
  }

  bool canEnableRule(RulePlugin rule, RulePluginState state) {
    final manifest = rule.effectiveManifest;
    if (!isRuleCoreVersionCompatible(manifest.minimumCoreVersion)) {
      return false;
    }
    return !manifest.requiresApproval ||
        state.approvedPermissionDigests[rule.id] == manifest.permissionDigest;
  }

  RulePluginState normalizeState(RulePluginState state) {
    final collection = _collection;
    final installed = collection.canonicalizeIds(state.installedIds);
    final approvedPermissionDigests = <String, String>{};
    for (final entry in state.approvedPermissionDigests.entries) {
      final canonicalId = collection.canonicalIdByAlias[entry.key];
      final rule = canonicalId == null
          ? null
          : collection.byCanonicalId[canonicalId];
      if (rule != null &&
          entry.value == rule.effectiveManifest.permissionDigest) {
        approvedPermissionDigests[canonicalId!] = entry.value;
      }
    }
    final approvedState = state.copyWith(
      approvedPermissionDigests: approvedPermissionDigests,
    );
    final enabled = collection
        .canonicalizeIds(state.enabledIds)
        .where(
          (id) =>
              installed.contains(id) &&
              (collection.byCanonicalId[id]?.canResolveNatively ?? false) &&
              canEnableRule(collection.byCanonicalId[id]!, approvedState) &&
              _canExecuteOnCurrentPlatform(collection.byCanonicalId[id]!),
        )
        .toSet();
    final customIds = extraRules.map((rule) => rule.id).toSet();
    final customRules = collection.rules
        .where((rule) => customIds.contains(rule.id))
        .toList(growable: false);
    return state.copyWith(
      installedIds: installed,
      enabledIds: enabled,
      uninstalledIds: {
        for (final id in state.uninstalledIds)
          collection.canonicalIdByAlias[id] ?? id,
      }.difference(installed),
      approvedPermissionDigests: approvedPermissionDigests,
      customRules: customRules,
      repositories: _deduplicateRepositories(state.repositories),
    );
  }
}

bool _canExecuteOnCurrentPlatform(RulePlugin rule) {
  if (rule.engine.toLowerCase() != 'drpy-js') return true;
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.windows;
}

class _RuleCollection {
  const _RuleCollection({
    required this.rules,
    required this.byCanonicalId,
    required this.canonicalIdByAlias,
    required this.aliasesByCanonicalId,
    required this.rulesByCanonicalId,
  });

  final List<RulePlugin> rules;
  final Map<String, RulePlugin> byCanonicalId;
  final Map<String, String> canonicalIdByAlias;
  final Map<String, Set<String>> aliasesByCanonicalId;
  final Map<String, List<RulePlugin>> rulesByCanonicalId;

  RulePlugin? byId(String id) => byCanonicalId[canonicalIdByAlias[id] ?? id];

  bool anyAliasIn(String canonicalId, Set<String> ids) {
    final aliases = aliasesByCanonicalId[canonicalId] ?? {canonicalId};
    return aliases.any(ids.contains);
  }

  Iterable<RulePlugin> aliasRules(String canonicalId) =>
      rulesByCanonicalId[canonicalId] ?? const <RulePlugin>[];

  Set<String> canonicalizeIds(Set<String> ids) {
    final canonicalIds = <String>{};
    for (final id in ids) {
      final canonicalId = canonicalIdByAlias[id];
      if (canonicalId != null) canonicalIds.add(canonicalId);
    }
    return canonicalIds;
  }
}

_RuleCollection _collectRules(
  List<RulePlugin> curated,
  List<RulePlugin> extra,
) {
  final exactById = <String, RulePlugin>{};
  for (final rule in [...curated, ...extra]) {
    final existing = exactById[rule.id];
    exactById[rule.id] = existing == null ? rule : _preferRule(existing, rule);
  }

  final groups = <String, List<RulePlugin>>{};
  for (final rule in exactById.values) {
    groups.putIfAbsent(_semanticRuleKey(rule), () => []).add(rule);
  }

  final rules = <RulePlugin>[];
  final byCanonicalId = <String, RulePlugin>{};
  final canonicalIdByAlias = <String, String>{};
  final aliasesByCanonicalId = <String, Set<String>>{};
  final rulesByCanonicalId = <String, List<RulePlugin>>{};
  for (final candidates in groups.values) {
    var preferred = candidates.first;
    for (final candidate in candidates.skip(1)) {
      preferred = _preferRule(preferred, candidate);
    }
    final merged = _mergeRuleMetadata(preferred, candidates);
    rules.add(merged);
    byCanonicalId[merged.id] = merged;
    aliasesByCanonicalId[merged.id] = {
      for (final candidate in candidates) candidate.id,
      for (final candidate in candidates)
        for (final legacyId in candidate.legacyIds) legacyId,
      merged.id,
    };
    rulesByCanonicalId[merged.id] = List.unmodifiable(candidates);
    for (final candidate in candidates) {
      canonicalIdByAlias[candidate.id] = merged.id;
      for (final legacyId in candidate.legacyIds) {
        canonicalIdByAlias[legacyId] = merged.id;
      }
    }
  }
  return _RuleCollection(
    rules: List.unmodifiable(rules),
    byCanonicalId: Map.unmodifiable(byCanonicalId),
    canonicalIdByAlias: Map.unmodifiable(canonicalIdByAlias),
    aliasesByCanonicalId: Map.unmodifiable(aliasesByCanonicalId),
    rulesByCanonicalId: Map.unmodifiable(rulesByCanonicalId),
  );
}

String _semanticRuleKey(RulePlugin rule) {
  final base = _canonicalRuleEndpoint(rule.baseUrl);
  final search = _canonicalRuleEndpoint(rule.searchUrl);
  final name = _canonicalRuleName(rule.name, fallback: rule.id);
  final engine = rule.engine.trim().toLowerCase();
  final parser = switch (engine) {
    'drpy-js' => _drpyRuleIdentity(rule),
    'android-csp' => _androidCspRuleIdentity(rule),
    _ => '',
  };
  return '${rule.contentType.name}|$engine|$name|$base|$search|$parser';
}

String _drpyRuleIdentity(RulePlugin rule) {
  final extUrl = rule.rawConfig['extUrl']?.toString().trim() ?? '';
  if (extUrl.isNotEmpty) return 'ext:${_canonicalRuleEndpoint(extUrl)}';

  final inline = rule.rawConfig['inlineSource']?.toString().trim() ?? '';
  if (inline.isNotEmpty) {
    return 'inline:${sha256.convert(utf8.encode(inline))}';
  }

  // Incomplete imported rules still belong to the user's inventory. Keeping
  // their ids distinct prevents unrelated same-name entries from disappearing
  // before a future runtime/config update can make them executable.
  return 'missing:${rule.id}';
}

String _androidCspRuleIdentity(RulePlugin rule) {
  final md5 = androidCspSpiderMd5(rule.rawConfig);
  final api = androidCspApi(rule.rawConfig);
  if (md5 == null || api.isEmpty) return 'missing:${rule.id}';
  final siteKey = androidCspSiteKey(rule.rawConfig, rule.id);
  final ext = androidCspEncodedExt(rule.rawConfig);
  return '$md5|$api|$siteKey|$ext';
}

String _canonicalRuleEndpoint(String value) {
  final text = value.trim();
  if (text.isEmpty) return '';
  final uri = Uri.tryParse(text);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    return text.replaceAll(RegExp(r'/+$'), '');
  }
  final scheme = uri.scheme.toLowerCase();
  final port = uri.port;
  final includePort =
      port != 0 &&
      !((scheme == 'http' && port == 80) || (scheme == 'https' && port == 443));
  final host = uri.host.contains(':')
      ? '[${uri.host.toLowerCase()}]'
      : uri.host.toLowerCase();
  final path = uri.path == '/' ? '' : uri.path.replaceAll(RegExp(r'/+$'), '');
  final query = uri.hasQuery ? '?${uri.query}' : '';
  return '$scheme://$host${includePort ? ':$port' : ''}$path$query';
}

String _canonicalRuleName(String value, {required String fallback}) {
  final normalized = value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), '')
      .replaceAll(RegExp(r'[\[\]【】()（）{}<>《》「」『』._\-·•|/\\:：,，。!！?？]+'), '');
  return normalized.isEmpty ? fallback.trim().toLowerCase() : normalized;
}

RulePlugin _preferRule(RulePlugin first, RulePlugin second) {
  final firstRank = _ruleRank(first);
  final secondRank = _ruleRank(second);
  for (var index = 0; index < firstRank.length; index++) {
    final compared = secondRank[index].compareTo(firstRank[index]);
    if (compared > 0) return second;
    if (compared < 0) return first;
  }
  return first;
}

List<int> _ruleRank(RulePlugin rule) => [
  rule.canResolveNatively ? 1 : 0,
  rule.requiresCaptcha || rule.requiresPrivateAuth ? 0 : 1,
  rule.updatedAt.millisecondsSinceEpoch,
  rule.qualityScore,
  _ruleCompleteness(rule),
];

int _ruleCompleteness(RulePlugin rule) {
  var score = 0;
  if (rule.baseUrl.trim().isNotEmpty) score += 4;
  if (rule.searchUrl.trim().isNotEmpty) score += 4;
  if (rule.kazumi != null) score += 6;
  if (rule.xbpq != null) score += 6;
  if (rule.animeko != null) score += 6;
  score += rule.requestHeaders.length;
  score += rule.rawConfig.length.clamp(0, 12);
  return score;
}

RulePlugin _mergeRuleMetadata(
  RulePlugin preferred,
  List<RulePlugin> candidates,
) {
  final tags = <String>{...preferred.tags};
  final headers = <String, String>{};
  final legacyIds = <String>{...preferred.legacyIds};
  var installedByDefault = preferred.installedByDefault;
  var managedInternal = preferred.managedInternal;
  var priority = preferred.priority;
  for (final candidate in candidates) {
    tags.addAll(candidate.tags);
    headers.addAll(candidate.requestHeaders);
    legacyIds.addAll(candidate.legacyIds);
    installedByDefault = installedByDefault || candidate.installedByDefault;
    managedInternal = managedInternal || candidate.managedInternal;
    if (candidate.priority < priority) priority = candidate.priority;
  }
  return preferred.copyWith(
    tags: tags.toList(growable: false),
    requestHeaders: {...headers, ...preferred.requestHeaders},
    installedByDefault: installedByDefault,
    managedInternal: managedInternal,
    priority: priority,
    legacyIds: legacyIds.toList(growable: false)..sort(),
  );
}

List<RuleRepositoryRecord> _deduplicateRepositories(
  List<RuleRepositoryRecord> repositories,
) {
  final unique = <String, RuleRepositoryRecord>{};
  for (final repository in repositories) {
    final url = _canonicalRuleEndpoint(repository.url);
    final key = url.isEmpty ? repository.id : url;
    final existing = unique[key];
    if (existing == null ||
        repository.importedAt.isAfter(existing.importedAt)) {
      unique[key] = repository;
    }
  }
  return unique.values.toList(growable: false);
}

/// Built-in site catalogs are provisioned silently from the configured online
/// service at runtime rather than embedded in the open-source client.
const _verifiedBuiltInRules = <RulePlugin>[];
