import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'csp_rule_support.dart';
import 'rule_models.dart';
import 'rule_security.dart';

class RulePluginRepository {
  const RulePluginRepository({this.extraRules = const []});

  final List<RulePlugin> extraRules;

  _RuleCollection get _collection =>
      _collectRules(_verifiedBuiltInRules, extraRules);

  List<RulePlugin> get allRules => _collection.rules;

  List<RulePlugin> rulesFor(RuleContentType type) {
    return allRules
        .where((rule) => rule.contentType == type)
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
              rule.contentType == type &&
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

  RulePlugin? byId(String id) {
    final collection = _collection;
    final canonicalId = collection.canonicalIdByAlias[id] ?? id;
    return collection.byCanonicalId[canonicalId];
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
    final enabled = collection
        .canonicalizeIds(state.enabledIds)
        .where(
          (id) =>
              installed.contains(id) &&
              (collection.byCanonicalId[id]?.canResolveNatively ?? false) &&
              canEnableRule(
                collection.byCanonicalId[id]!,
                state.copyWith(
                  approvedPermissionDigests: approvedPermissionDigests,
                ),
              ) &&
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
  var priority = preferred.priority;
  for (final candidate in candidates) {
    tags.addAll(candidate.tags);
    headers.addAll(candidate.requestHeaders);
    legacyIds.addAll(candidate.legacyIds);
    installedByDefault = installedByDefault || candidate.installedByDefault;
    if (candidate.priority < priority) priority = candidate.priority;
  }
  return preferred.copyWith(
    tags: tags.toList(growable: false),
    requestHeaders: {...headers, ...preferred.requestHeaders},
    installedByDefault: installedByDefault,
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

DateTime _date(
  int year,
  int month,
  int day, [
  int hour = 0,
  int minute = 0,
  int second = 0,
]) {
  return DateTime(year, month, day, hour, minute, second);
}

const _native = 'native';
const _xbpq = 'XBPQ';
const _xyq = 'XYQHiker';
const _drpy = 'drpy-js';

/// Sources in this list are only promoted after an end-to-end media probe.
/// They remain ordinary rules: users can disable them in rule management and
/// the runtime health cache will demote a source after repeated failures.
final _verifiedBuiltInRules = <RulePlugin>[
  RulePlugin(
    id: 'zeluna:recommended:fantuan',
    name: '饭团动漫(替换)',
    version: '2026-07-28',
    source: RuleSourceKind.custom,
    contentType: RuleContentType.anime,
    engine: 'animeko-web-selector',
    updatedAt: _date(2026, 7, 28),
    qualityScore: 100,
    tags: const ['推荐', 'Animeko', '已验证'],
    baseUrl: 'https://acgpost.com/',
    searchUrl: 'https://acgpost.com/search.html?wd={keyword}',
    searchable: true,
    quickSearch: true,
    filterable: false,
    installedByDefault: true,
    priority: 0,
    animeko: const AnimekoWebSelectorConfig(
      searchUrl: 'https://acgpost.com/search.html?wd={keyword}',
      searchRemoveSpecial: true,
      subjectFormatId: 'a',
      channelFormatId: 'index-grouped',
      defaultResolution: '720P',
      subjectA: AnimekoSubjectAConfig(
        selectLists: 'body > main > div > div.mt-2-5 > div > div > div > a',
        preferShorterName: true,
      ),
      channelFlattened: AnimekoChannelFlattenedConfig(
        selectChannelNames:
            'body > main > div > div.row.mt-1-25.mb-5 > div > div > div > ul > li > button',
        matchChannelName: r'^(?<ch>.+?)(\d+)?$',
        selectEpisodeLists: '.anime-episode',
        selectEpisodesFromList: 'a',
        matchEpisodeSortFromName: r'第\s*(?<ep>.+)\s*[话集]',
      ),
      enableNestedUrl: true,
      matchNestedUrl: r'^.+(m3u8|vip|xigua\.php).+\?',
      matchVideoUrl:
          r'(^http(s)?:\/\/(?!.*http(s)?:\/\/)(?!.*google-analytics).+((\.mp4)|(\.mkv)|(m3u8)).*(\?.+)?)|(akamaized)|(bilivideo.com)|(.+player\/\?url=(?<v>.+))',
      cookies: 'quality=1080',
      videoUserAgent:
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/58.0.3029.110 Safari/537.3',
    ),
    permissionManifest: const RulePermissionManifest.official(
      id: 'zeluna:recommended:fantuan',
      name: '饭团动漫(替换)',
      version: '2026-07-28',
      engine: 'animeko-web-selector',
      contentTypes: ['anime'],
      pageDomains: ['acgpost.com'],
      mediaDomains: ['acgpost.com'],
      javascript: true,
      webViewSniffing: true,
      cookiePolicy: RuleCookiePolicy.taskScoped,
      customReferer: true,
      customUserAgent: true,
    ),
  ),
  RulePlugin(
    id: 'zeluna:recommended:aikanbot',
    name: '爱看机器人',
    version: '2026-07-28',
    source: RuleSourceKind.custom,
    contentType: RuleContentType.anime,
    engine: 'aikanbot-api',
    updatedAt: _date(2026, 7, 28),
    qualityScore: 92,
    tags: const ['推荐', '网页聚合', '已验证'],
    baseUrl: 'https://www1.aikanbot.com',
    searchUrl: 'https://www1.aikanbot.com/search?q={keyword}',
    searchable: true,
    quickSearch: true,
    filterable: false,
    installedByDefault: true,
    priority: 1,
    requestHeaders: const {'Referer': 'https://www1.aikanbot.com/'},
    permissionManifest: const RulePermissionManifest.official(
      id: 'zeluna:recommended:aikanbot',
      name: '爱看机器人',
      version: '2026-07-28',
      engine: 'aikanbot-api',
      contentTypes: ['anime'],
      pageDomains: ['www1.aikanbot.com'],
      mediaDomains: ['www1.aikanbot.com'],
      customReferer: true,
    ),
    note: '通过站点公开的页面播放清单接口获取 HLS，客户端不加载广告播放器。',
  ),
  RulePlugin(
    id: 'zeluna:recommended:sorani',
    name: '青空次元',
    version: '2026-07-28',
    source: RuleSourceKind.custom,
    contentType: RuleContentType.anime,
    engine: 'sorani-api',
    updatedAt: _date(2026, 7, 28),
    qualityScore: 90,
    tags: const ['推荐', '番剧', '已验证'],
    baseUrl: 'https://api.sorani.cc/sorani-cms',
    searchUrl: 'https://www.sorani.net/',
    searchable: true,
    quickSearch: true,
    filterable: false,
    installedByDefault: true,
    priority: 2,
    rawConfig: const {'lineCode': 'anime_jp_m3u8'},
    permissionManifest: const RulePermissionManifest.official(
      id: 'zeluna:recommended:sorani',
      name: '青空次元',
      version: '2026-07-28',
      engine: 'sorani-api',
      contentTypes: ['anime'],
      pageDomains: ['api.sorani.cc', 'www.sorani.net'],
      mediaDomains: ['api.sorani.cc'],
      customReferer: true,
    ),
    note: '播放时从公开接口获取短时 HLS 清单，并在客户端验证媒体分片。',
  ),
  RulePlugin(
    id: 'zeluna:recommended:dbku',
    name: '独播库',
    version: '2026-07-28',
    source: RuleSourceKind.custom,
    contentType: RuleContentType.movie,
    engine: _xbpq,
    updatedAt: _date(2026, 7, 28),
    qualityScore: 88,
    tags: const ['推荐', '电影', '已验证'],
    baseUrl: 'https://www.dbku.tv',
    searchUrl: 'https://www.dbku.tv/vodsearch/-------------.html?wd={wd}',
    searchable: true,
    quickSearch: true,
    filterable: false,
    installedByDefault: true,
    priority: 3,
    xbpq: const XbpqParserConfig(
      searchArray: '<li class="clearfix">&&</li>',
      searchTitle: '">&&</a>',
      searchLink: 'href="&&"',
      playArray: '<ul class="myui-content__list&&</ul>',
      playList: '<li&&</li>',
      playTitle: '">&&</a>',
      playLink: 'href="&&"',
    ),
    permissionManifest: const RulePermissionManifest.official(
      id: 'zeluna:recommended:dbku',
      name: '独播库',
      version: '2026-07-28',
      engine: 'XBPQ',
      contentTypes: ['movie'],
      pageDomains: ['www.dbku.tv'],
      mediaDomains: ['www.dbku.tv'],
      customReferer: true,
    ),
    note: '播放页提供经页面编码的 HLS 地址，客户端会先解码并验证清单与分片。',
  ),
  RulePlugin(
    id: 'zeluna:recommended:nivod',
    name: '泥视频',
    version: '2026-07-28',
    source: RuleSourceKind.custom,
    contentType: RuleContentType.movie,
    engine: _xbpq,
    updatedAt: _date(2026, 7, 28),
    qualityScore: 87,
    tags: const ['推荐', '电影', '已验证'],
    baseUrl: 'https://www.nivod.vip',
    searchUrl: 'https://www.nivod.vip/s/-------------/?wd={wd}',
    searchable: true,
    quickSearch: true,
    filterable: false,
    installedByDefault: true,
    priority: 4,
    xbpq: const XbpqParserConfig(
      searchArray: 'class="module-card-item-title">&&</div>',
      searchTitle: '<strong>&&</strong>',
      searchLink: 'href="&&"',
      playArray: '<div class="module-play-list-content&&</div>',
      playList: '<a&&</a>',
      playTitle: '><span>&&</span>',
      playLink: 'href="&&"',
    ),
    permissionManifest: const RulePermissionManifest.official(
      id: 'zeluna:recommended:nivod',
      name: '泥视频',
      version: '2026-07-28',
      engine: 'XBPQ',
      contentTypes: ['movie'],
      pageDomains: ['www.nivod.vip'],
      mediaDomains: ['www.nivod.vip'],
      customReferer: true,
    ),
    note: '播放页提供 HLS 清单地址，客户端会验证清单与首个媒体分片。',
  ),
];

@Deprecated('Built-in playback sites are served by the backend.')
final legacyCuratedRuleDefinitions = <RulePlugin>[
  RulePlugin(
    id: 'kazumi:omofun03',
    name: 'omofun03',
    version: '1.1',
    source: RuleSourceKind.kazumi,
    contentType: RuleContentType.anime,
    engine: _native,
    updatedAt: _date(2026, 4, 26, 13, 1, 23),
    qualityScore: 96,
    tags: const ['native', '多线路', '番剧'],
    baseUrl: 'https://omofun03.top/',
    searchUrl: 'https://omofun03.top/vod/search.html?wd=@keyword',
    searchable: true,
    quickSearch: true,
    filterable: true,
    requiresWebView: true,
    installedByDefault: true,
    kazumi: const KazumiParserConfig(
      searchList: '//div[1]/div[2]/div/div/div[2]/div//div',
      searchName: '//div[2]/div[1]/a/strong',
      searchResult: '//div[3]/a[2]',
      chapterRoads: '//div/div[2]/div/div[2]//div',
      chapterResult: '//div/div/a',
    ),
    note: 'KazumiRules 中更新时间最新，字段完整，支持多线路和原生播放。',
  ),
  RulePlugin(
    id: 'kazumi:enlie',
    name: 'enlie',
    version: '1.0',
    source: RuleSourceKind.kazumi,
    contentType: RuleContentType.anime,
    engine: _native,
    updatedAt: _date(2026, 3, 11, 12, 26, 14),
    qualityScore: 90,
    tags: const ['native', '番剧'],
    baseUrl: 'https://enlienli.link/',
    searchUrl: 'https://enlienli.link/vod/search.html?wd=@keyword',
    searchable: true,
    quickSearch: true,
    filterable: true,
    installedByDefault: true,
    kazumi: const KazumiParserConfig(
      searchList: '//div[1]/div[2]/div/div/div[2]/div/div',
      searchName: '//div[2]/div[1]/a',
      searchResult: '//div[2]/div[1]/a',
      chapterRoads: '//div/div[2]/div/div[2]/div/div/div',
      chapterResult: '//a',
    ),
    note: '规则较新且不依赖验证码，适合作为番剧备用源。',
  ),
  RulePlugin(
    id: 'kazumi:xfdmneo',
    name: 'xfdmneo',
    version: '1.1',
    source: RuleSourceKind.kazumi,
    contentType: RuleContentType.anime,
    engine: _native,
    updatedAt: _date(2026, 3, 8, 18, 0, 2),
    qualityScore: 88,
    tags: const ['native', '番剧'],
    baseUrl: 'https://dm1.xfdm.pro/',
    searchUrl: 'https://dm1.xfdm.pro/search.html?wd=@keyword',
    searchable: true,
    quickSearch: true,
    filterable: true,
    installedByDefault: true,
    kazumi: const KazumiParserConfig(
      searchList: "//div[@class='public-list-box search-box flex rel']",
      searchName: '//div[3]/div[1]/div[1]',
      searchResult: '//div[3]/div[2]/a[1]',
      chapterRoads: "//ul[@class='anthology-list-play size']",
      chapterResult: '//li/a',
    ),
    note: '字段完整，更新时间靠前，作为无验证码备用规则保留。',
  ),
  RulePlugin(
    id: 'kazumi:lmm',
    name: 'LMM',
    version: '2.0',
    source: RuleSourceKind.kazumi,
    contentType: RuleContentType.anime,
    engine: _native,
    updatedAt: _date(2026, 3, 7, 17, 42, 43),
    qualityScore: 82,
    tags: const ['native', 'captcha', '多线路'],
    baseUrl: 'https://www.lmm85.com/',
    searchUrl: 'https://www.lmm85.com/vod/search.html?wd=@keyword',
    searchable: true,
    quickSearch: true,
    filterable: true,
    requiresWebView: true,
    requiresCaptcha: true,
    installedByDefault: true,
    kazumi: const KazumiParserConfig(
      searchList: '//div[1]/div/div/section/div//div',
      searchName: '//div/div[2]/h6/a',
      searchResult: '//div/div[2]/h6/a',
      chapterRoads: '//div[1]/div[2]/div/div[1]/section[2]/div//div',
      chapterResult: '//div[2]/div/a',
    ),
    unsupportedReason: '该规则启用了验证码验证，需要 WebView 手动处理，解析器不会绕过验证码。',
    note: '规则完整但带验证码，安装后作为手动备用源使用。',
  ),
  RulePlugin(
    id: 'kazumi:girigirilove',
    name: 'giriGiriLove',
    version: '2.1',
    source: RuleSourceKind.kazumi,
    contentType: RuleContentType.anime,
    engine: _native,
    updatedAt: _date(2026, 3, 7, 17, 32, 31),
    qualityScore: 81,
    tags: const ['native', 'captcha', '多线路'],
    baseUrl: 'https://anime.girigirilove.top',
    searchUrl:
        'https://anime.girigirilove.top/search/-------------/?wd=@keyword',
    searchable: true,
    quickSearch: true,
    filterable: true,
    requiresWebView: true,
    requiresCaptcha: true,
    installedByDefault: true,
    kazumi: const KazumiParserConfig(
      searchList: "//div[@class='vod-detail style-detail cor4 search-list']",
      searchName: '//div/div[2]/a',
      searchResult: '//div/div[2]/a',
      chapterRoads: "//ul[@class='anthology-list-play size']",
      chapterResult: '//li/a',
    ),
    unsupportedReason: '该规则启用了反爬验证，需要 WebView 手动处理，解析器不会绕过验证。',
    note: '字段完整但启用反爬验证，保留为可安装番剧规则。',
  ),
  RulePlugin(
    id: 'kazumi:xfdm',
    name: 'xfdm',
    version: '2.0',
    source: RuleSourceKind.kazumi,
    contentType: RuleContentType.anime,
    engine: _native,
    updatedAt: _date(2026, 3, 7, 17, 5, 45),
    qualityScore: 80,
    tags: const ['native', 'captcha'],
    baseUrl: 'https://dm.xifanacg.com/',
    searchUrl: 'https://dm.xifanacg.com/search.html?wd=@keyword',
    searchable: true,
    quickSearch: true,
    filterable: true,
    requiresWebView: true,
    requiresCaptcha: true,
    installedByDefault: true,
    kazumi: const KazumiParserConfig(
      searchList: "//div[@class='vod-detail style-detail cor4 search-list']",
      searchName: '//div/div[2]/a/h3',
      searchResult: '//div/div[2]/a',
      chapterRoads: "//ul[@class='anthology-list-play size']",
      chapterResult: '//li/a',
    ),
    unsupportedReason: '该规则启用了反爬验证，需要 WebView 手动处理，解析器不会绕过验证。',
    note: 'KazumiRules 已列入索引，作为番剧规则的兜底线路。',
  ),
  RulePlugin(
    id: 'kazumi:mxdm',
    name: 'MXdm',
    version: '2.3',
    source: RuleSourceKind.kazumi,
    contentType: RuleContentType.anime,
    engine: _native,
    updatedAt: _date(2026, 2, 24, 21, 15, 41),
    qualityScore: 78,
    tags: const ['native', '番剧'],
    baseUrl: 'https://www.dcc3.com/',
    searchUrl: 'https://www.dcc3.com/search/?wd=@keyword',
    searchable: true,
    quickSearch: true,
    filterable: true,
    installedByDefault: true,
    kazumi: const KazumiParserConfig(
      searchList: '//div[3]/ul/li',
      searchName: '//h3/a',
      searchResult: '//h3/a',
      chapterRoads: '//div[4]/div/div/ul',
      chapterResult: '//li/a',
    ),
    note: '版本号较高，不带验证码，作为可安装备用规则。',
  ),
  RulePlugin(
    id: 'tvbox:hanjukankan',
    name: '韩剧看看',
    version: '1.0',
    source: RuleSourceKind.tvbox,
    contentType: RuleContentType.series,
    engine: _xbpq,
    updatedAt: _date(2026, 3, 7, 12, 0, 0),
    qualityScore: 94,
    tags: const ['XBPQ', '韩剧', '剧集'],
    baseUrl: 'https://www.hanjukankan.com/',
    searchUrl: 'https://www.hanjukankan.com/xvse{wd}abcdefghig{pg}klm.html',
    searchable: true,
    quickSearch: true,
    filterable: true,
    installedByDefault: true,
    xbpq: const XbpqParserConfig(
      searchArray: 'module-card-item-class&&</a>',
      searchTitle: 'title="&&"',
      searchLink: 'href="&&"',
      playArray: 'module-play-list-content&&</div>',
      playList: '<a&&/a>',
      playTitle: '>&&</',
      playLink: 'href="&&"',
      lineArray: 'module-tab-item&&</div>',
      lineTitle: '>&&</',
      jumpPlayLink: 'var player_*"url":"&&"',
    ),
    note: '分类明确区分韩国剧集、韩国电影、韩国综艺，优先归入电视剧规则。',
  ),
  RulePlugin(
    id: 'tvbox:meijutt',
    name: '美剧天天',
    version: '1.0',
    source: RuleSourceKind.tvbox,
    contentType: RuleContentType.series,
    engine: 'csp',
    updatedAt: _date(2026, 3, 7, 12, 0, 0),
    qualityScore: 90,
    tags: const ['美剧', '剧集', '可搜索'],
    baseUrl: 'https://www.meijutt.net',
    searchUrl: '',
    searchable: true,
    quickSearch: true,
    filterable: true,
    installedByDefault: true,
    unsupportedReason: '该规则属于 TVBox CSP，需要接入 CSP 执行器后才能解析。',
    note: 'TVBox 配置中的美剧专用源，未携带私密授权信息。',
  ),
  RulePlugin(
    id: 'tvbox:ddys',
    name: '低端影视',
    version: '1.0',
    source: RuleSourceKind.tvbox,
    contentType: RuleContentType.series,
    engine: _drpy,
    updatedAt: _date(2026, 3, 7, 12, 0, 0),
    qualityScore: 86,
    tags: const ['drpy-js', '剧集', '电影'],
    baseUrl: 'https://ddys.pro',
    searchUrl: '',
    searchable: true,
    quickSearch: true,
    filterable: true,
    installedByDefault: false,
    unsupportedReason: '该规则属于 drpy-js，需要接入 JS 规则执行器后才能解析。',
    note: '综合影视源，优先在电视剧频道使用，电影频道另配专用电影源。',
  ),
  RulePlugin(
    id: 'tvbox:dianyingxiansheng',
    name: '电影先生',
    version: '1.0',
    source: RuleSourceKind.tvbox,
    contentType: RuleContentType.movie,
    engine: _xbpq,
    updatedAt: _date(2026, 3, 7, 12, 0, 0),
    qualityScore: 94,
    tags: const ['XBPQ', '电影', '电视剧'],
    baseUrl: 'https://dianyi.ng',
    searchUrl: 'https://dianyi.ng/search--------------.html?wd={wd}',
    searchable: true,
    quickSearch: true,
    filterable: true,
    installedByDefault: true,
    xbpq: const XbpqParserConfig(
      searchArray: '<div class="module-item-pic">&&</div>',
      searchTitle: 'title="&&"',
      searchLink: 'href="&&"',
      playArray: '<div class="scroll-content">&&</div>',
      playList: '<a&&/a>',
      playTitle: '<span>&&</span>',
      playLink: 'href="&&"',
      lineArray: 'data-dropdown-value=&&</div>',
      lineTitle: '<span>&&</small>',
      jumpPlayLink: 'var player_*"url":"&&"',
    ),
    note: '分类内含电影/电视剧/动漫/综艺，这里仅把电影规则归入电影频道。',
  ),
  RulePlugin(
    id: 'tvbox:dygang',
    name: '电影港',
    version: '1.0',
    source: RuleSourceKind.tvbox,
    contentType: RuleContentType.movie,
    engine: _xyq,
    updatedAt: _date(2026, 3, 7, 12, 0, 0),
    qualityScore: 92,
    tags: const ['XYQHiker', '电影', '磁力'],
    baseUrl: 'https://www.dygang.tv',
    searchUrl: 'https://www.dygang.tv/e/search/index123.php',
    searchable: true,
    quickSearch: true,
    filterable: true,
    installedByDefault: true,
    unsupportedReason: '该规则主要返回磁力/下载链接，不作为在线播放线路解析。',
    note: '电影分类完整，包含最新电影、经典高清、国配电影、4K 等频道。',
  ),
  RulePlugin(
    id: 'tvbox:new6v',
    name: '新6V',
    version: '1.0',
    source: RuleSourceKind.tvbox,
    contentType: RuleContentType.movie,
    engine: 'csp',
    updatedAt: _date(2026, 3, 7, 12, 0, 0),
    qualityScore: 88,
    tags: const ['电影', '可搜索'],
    baseUrl: 'https://www.66ss.org',
    searchUrl: '',
    searchable: true,
    quickSearch: true,
    filterable: true,
    installedByDefault: false,
    unsupportedReason: '该规则属于 TVBox CSP，需要接入 CSP 执行器后才能解析。',
    note: 'TVBox 中较常见的电影源，不需要本地授权信息。',
  ),
  RulePlugin(
    id: 'tvbox:kuba',
    name: '酷吧电影',
    version: '1.0',
    source: RuleSourceKind.tvbox,
    contentType: RuleContentType.movie,
    engine: 'csp',
    updatedAt: _date(2026, 3, 7, 12, 0, 0),
    qualityScore: 84,
    tags: const ['电影', '可搜索'],
    baseUrl: 'https://www.kubady2.com',
    searchUrl: '',
    searchable: true,
    quickSearch: true,
    filterable: true,
    installedByDefault: false,
    unsupportedReason: '该规则属于 TVBox CSP，需要接入 CSP 执行器后才能解析。',
    note: '电影向资源站，保留为可安装备用源。',
  ),
];
