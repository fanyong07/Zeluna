import 'dart:convert';
import 'dart:collection';

import '../rules/rule_importer.dart';
import '../rules/rule_models.dart';
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
  const SourceRuleBridge({this.importer = const RuleImporter()});

  final RuleImporter importer;

  SourceRuleBridgeResult build(SourceCatalogState catalog) {
    final availableRules = <String, RulePlugin>{};
    final activeRules = <String, RulePlugin>{};
    final counts = <String, int>{};

    for (final source in catalog.sources) {
      if (source.kind != VideoSourceKind.tvBox || source.rawConfig.isEmpty) {
        counts[source.id] = 0;
        continue;
      }
      final sourceRules = _rulesForSource(source);
      counts[source.id] = sourceRules.length;
      for (final rule in sourceRules) {
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

  List<RulePlugin> _rulesForSource(VideoSource source) {
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
      if (!_canParticipateInPlayback(rule)) continue;
      final bridged = rule.copyWith(
        id: 'catalog:${source.id}:${rule.id}',
        groupId: 'catalog:${source.id}',
        priority: rule.priority,
        requestHeaders: {...source.headers, ...rule.requestHeaders},
        note: '由自动规则包“${source.displayName}”接入播放查源。',
      );
      final key = _dedupeKey(bridged);
      final existing = unique[key];
      unique[key] = existing == null
          ? bridged
          : _preferMoreCompleteRule(existing, bridged);
    }
    return unique.values.toList(growable: false);
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
