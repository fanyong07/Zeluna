import 'dart:convert';
import 'dart:collection';

import '../rules/rule_importer.dart';
import '../rules/rule_models.dart';
import '../rules/tvbox_xbpq_hydrator.dart';
import 'source_catalog_models.dart';

class SourceRuleBridgeResult {
  const SourceRuleBridgeResult({
    required this.rules,
    required this.ruleCountsBySource,
    required this.availableRuleCount,
  });

  final List<RulePlugin> rules;
  final Map<String, int> ruleCountsBySource;
  final int availableRuleCount;

  SourceCatalogState attachTo(SourceCatalogState catalog) {
    return catalog.copyWith(
      playbackRuleCounts: ruleCountsBySource,
      availablePlaybackRuleCount: availableRuleCount,
      activePlaybackRuleCount: rules.length,
      loadError: catalog.loadError,
    );
  }
}

class SourceRuleBridge {
  const SourceRuleBridge({
    this.importer = const RuleImporter(),
    this.xbpqHydrator,
  });

  final RuleImporter importer;
  final TvBoxXbpqHydrator? xbpqHydrator;

  SourceRuleBridgeResult build(SourceCatalogState catalog) {
    return _buildFromSourceRules(catalog, [
      for (final source in catalog.sources) _rulesForSource(source),
    ]);
  }

  Future<SourceRuleBridgeResult> buildHydrated(
    SourceCatalogState catalog,
  ) async {
    final hydrator = xbpqHydrator;
    if (hydrator == null) return build(catalog);
    final sourceRules = await Future.wait([
      for (final source in catalog.sources)
        _rulesForSourceWithHydration(source, hydrator),
    ]);
    return _buildFromSourceRules(catalog, sourceRules);
  }

  bool mayContributePlaybackRules(VideoSource source) {
    if (source.kind != VideoSourceKind.tvBox || source.rawConfig.isEmpty) {
      return false;
    }
    if (_rulesForSource(source).isNotEmpty) return true;
    final sites = source.rawConfig['sites'];
    if (sites is! List) return false;
    return sites.whereType<Map>().any((site) {
      final api = site['api']?.toString().trim().toLowerCase() ?? '';
      if (api != 'csp_xbpq') return false;
      final ext = site['ext'];
      return ext is Map || (ext?.toString().trim().isNotEmpty ?? false);
    });
  }

  SourceRuleBridgeResult _buildFromSourceRules(
    SourceCatalogState catalog,
    List<List<RulePlugin>> sourceRules,
  ) {
    final availableRules = <String, RulePlugin>{};
    final activeRules = <String, RulePlugin>{};
    final counts = <String, int>{};

    for (var index = 0; index < catalog.sources.length; index++) {
      final source = catalog.sources[index];
      final rules = index < sourceRules.length
          ? sourceRules[index]
          : const <RulePlugin>[];
      counts[source.id] = rules.length;
      for (final rule in rules) {
        final key = _dedupeKey(rule);
        final available = availableRules[key];
        availableRules[key] = available == null
            ? rule
            : _preferMoreCompleteRule(available, rule);
        if (source.enabled) {
          final active = activeRules[key];
          activeRules[key] = active == null
              ? rule
              : _preferMoreCompleteRule(active, rule);
        }
      }
    }

    return SourceRuleBridgeResult(
      rules: activeRules.values.toList(growable: false),
      ruleCountsBySource: counts,
      availableRuleCount: availableRules.length,
    );
  }

  Future<List<RulePlugin>> _rulesForSourceWithHydration(
    VideoSource source,
    TvBoxXbpqHydrator hydrator,
  ) async {
    final baseline = _rulesForSource(source);
    if (source.kind != VideoSourceKind.tvBox || source.rawConfig.isEmpty) {
      return baseline;
    }

    TvBoxXbpqHydrationResult hydration;
    try {
      hydration = await hydrator.hydrateSource(source);
    } catch (_) {
      return baseline;
    }

    final unique = <String, RulePlugin>{};
    for (final rule in [...baseline, ...hydration.executableRules]) {
      final bridged = _bridgeRule(source, rule);
      if (!_canParticipateInPlayback(bridged)) continue;
      final key = _dedupeKey(bridged);
      final existing = unique[key];
      unique[key] = existing == null
          ? bridged
          : _preferMoreCompleteRule(existing, bridged);
    }
    return unique.values.toList(growable: false);
  }

  List<RulePlugin> _rulesForSource(VideoSource source) {
    if (source.kind != VideoSourceKind.tvBox || source.rawConfig.isEmpty) {
      return const [];
    }
    RuleImportBundle bundle;
    try {
      bundle = importer.importFromText(
        jsonEncode(source.rawConfig),
        sourceUrl: source.importUrl.trim().isEmpty
            ? source.baseUrl
            : source.importUrl,
      );
    } on FormatException {
      return const [];
    }

    final unique = <String, RulePlugin>{};
    for (final rule in bundle.rules) {
      // XBPQ must always pass through TvBoxXbpqHydrator first. Importing a
      // complete inline config here would bypass its script/private-host
      // checks during the synchronous catalog build.
      if (rule.engine.toLowerCase() == 'xbpq') continue;
      if (!_canParticipateInPlayback(rule)) continue;
      final bridged = _bridgeRule(source, rule);
      final key = _dedupeKey(bridged);
      final existing = unique[key];
      unique[key] = existing == null
          ? bridged
          : _preferMoreCompleteRule(existing, bridged);
    }
    return unique.values.toList(growable: false);
  }

  RulePlugin _bridgeRule(VideoSource source, RulePlugin rule) {
    final prefix = 'catalog:${source.id}:';
    final groupId = 'catalog:${source.id}';
    return rule.copyWith(
      id: rule.id.startsWith(prefix) ? rule.id : '$prefix${rule.id}',
      groupId: rule.groupId == groupId ? rule.groupId : groupId,
      priority: rule.priority,
      requestHeaders: {...source.headers, ...rule.requestHeaders},
      note: rule.note.trim().isEmpty
          ? '由自动规则包“${source.displayName}”接入播放查源。'
          : rule.note,
    );
  }
}

bool _canParticipateInPlayback(RulePlugin rule) {
  if (!rule.searchable || !rule.canResolveNatively) return false;
  if (rule.engine.toLowerCase() != 'xbpq') return true;
  final config = rule.xbpq;
  if (config == null) return false;
  return config.searchArray.trim().isNotEmpty &&
      config.searchTitle.trim().isNotEmpty &&
      config.searchLink.trim().isNotEmpty &&
      config.playList.trim().isNotEmpty &&
      config.playLink.trim().isNotEmpty;
}

String _dedupeKey(RulePlugin rule) {
  final endpoint = _canonicalEndpoint(rule.baseUrl);
  final search = _canonicalEndpoint(rule.searchUrl);
  final parser = rule.engine.toLowerCase() == 'xbpq'
      ? jsonEncode(rule.xbpq?.toJson() ?? const <String, dynamic>{})
      : '';
  return '${rule.contentType.name}|${rule.engine.toLowerCase()}|$endpoint|$search|$parser';
}

String _canonicalEndpoint(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    return value.trim().toLowerCase().replaceAll(RegExp(r'/+$'), '');
  }
  final query = SplayTreeMap<String, String>.from(uri.queryParameters)
    ..remove('ac')
    ..remove('wd')
    ..remove('ids');
  final path = uri.path.replaceAll(RegExp(r'/+$'), '');
  return uri
      .replace(
        scheme: uri.scheme.toLowerCase(),
        host: uri.host.toLowerCase(),
        path: path,
        queryParameters: query,
        fragment: '',
      )
      .toString();
}

RulePlugin _preferMoreCompleteRule(RulePlugin first, RulePlugin second) {
  final preferSecond =
      second.requestHeaders.length > first.requestHeaders.length ||
      (second.requestHeaders.length == first.requestHeaders.length &&
          second.qualityScore > first.qualityScore);
  final preferred = preferSecond ? second : first;
  return preferred.copyWith(
    requestHeaders: {...first.requestHeaders, ...second.requestHeaders},
  );
}
