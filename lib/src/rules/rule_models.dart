import 'package:flutter/foundation.dart';

import 'csp_rule_support.dart';
import 'rule_security.dart';

enum RuleContentType {
  anime('番剧'),
  series('电视剧'),
  movie('电影');

  const RuleContentType(this.label);

  final String label;

  factory RuleContentType.fromJson(Object? value) {
    final text = value?.toString().trim().toLowerCase() ?? '';
    if (text.contains('movie') || text.contains('电影')) {
      return RuleContentType.movie;
    }
    if (text.contains('series') ||
        text.contains('tv') ||
        text.contains('剧集') ||
        text.contains('电视剧')) {
      return RuleContentType.series;
    }
    return RuleContentType.anime;
  }
}

enum RuleSourceKind {
  kazumi('KazumiRules'),
  tvbox('TVBox'),
  custom('用户仓库');

  const RuleSourceKind(this.label);

  final String label;

  factory RuleSourceKind.fromJson(Object? value) {
    final text = value?.toString().trim().toLowerCase() ?? '';
    if (text.contains('kazumi')) return RuleSourceKind.kazumi;
    if (text.contains('tvbox') || text.contains('tv box')) {
      return RuleSourceKind.tvbox;
    }
    return RuleSourceKind.custom;
  }
}

enum RuleExecutionStatus {
  executable('可执行'),
  needsWebView('需手动验证'),
  needsPrivateAuth('需授权'),
  missingConfig('缺少配置'),
  unsupportedEngine('暂不支持');

  const RuleExecutionStatus(this.label);

  final String label;

  bool get isExecutable => this == RuleExecutionStatus.executable;
}

class RulePlugin {
  const RulePlugin({
    required this.id,
    required this.name,
    required this.version,
    required this.source,
    required this.contentType,
    required this.engine,
    required this.updatedAt,
    required this.qualityScore,
    required this.tags,
    required this.baseUrl,
    required this.searchUrl,
    required this.searchable,
    required this.quickSearch,
    required this.filterable,
    this.requiresWebView = false,
    this.requiresCaptcha = false,
    this.requiresPrivateAuth = false,
    this.installedByDefault = false,
    this.kazumi,
    this.xbpq,
    this.animeko,
    this.requestHeaders = const {},
    this.rawConfig = const {},
    this.groupId = '',
    this.priority = 100,
    this.unsupportedReason,
    this.note = '',
    this.legacyIds = const [],
    this.permissionManifest,
  });

  final String id;
  final String name;
  final String version;
  final RuleSourceKind source;
  final RuleContentType contentType;
  final String engine;
  final DateTime updatedAt;
  final int qualityScore;
  final List<String> tags;
  final String baseUrl;
  final String searchUrl;
  final bool searchable;
  final bool quickSearch;
  final bool filterable;
  final bool requiresWebView;
  final bool requiresCaptcha;
  final bool requiresPrivateAuth;
  final bool installedByDefault;
  final KazumiParserConfig? kazumi;
  final XbpqParserConfig? xbpq;
  final AnimekoWebSelectorConfig? animeko;
  final Map<String, String> requestHeaders;
  final Map<String, dynamic> rawConfig;
  final String groupId;
  final int priority;
  final String? unsupportedReason;
  final String note;
  final List<String> legacyIds;
  final RulePermissionManifest? permissionManifest;

  String get sourceLabel => source.label;

  String get contentLabel => contentType.label;

  RulePermissionManifest get effectiveManifest {
    final declared = permissionManifest;
    final fallbackDomains = ruleDomainsFromUrls([baseUrl, searchUrl]);
    bool hasHeader(String name) =>
        requestHeaders.keys.any((key) => key.toLowerCase() == name);
    final contentHash = ruleSecurityContentHash({
      'id': id,
      'version': version,
      'engine': engine,
      'baseUrl': baseUrl,
      'searchUrl': searchUrl,
      'kazumi': kazumi?.toJson(),
      'xbpq': xbpq?.toJson(),
      'animeko': animeko == null ? null : {...animeko!.toJson(), 'cookies': ''},
      'requestHeaders': ruleHeadersForPersistence(requestHeaders),
      'rawConfig': ruleConfigForPersistence(rawConfig),
    });
    return RulePermissionManifest(
      id: id,
      name: name,
      version: version,
      engine: engine,
      contentTypes: [contentType.name],
      sourceRepository:
          declared?.sourceRepository ??
          rawConfig['sourceRepository']?.toString().trim() ??
          '',
      contentHash: contentHash,
      signature: declared?.signature ?? '',
      trustLevel: declared?.trustLevel ?? RuleTrustLevel.untrusted,
      pageDomains: declared == null
          ? fallbackDomains
          : normalizeRuleDomains(declared.pageDomains),
      mediaDomains: declared == null
          ? fallbackDomains
          : normalizeRuleDomains(declared.mediaDomains),
      javascript:
          declared?.javascript ??
          requiresWebView ||
              requiresCaptcha ||
              kazumi?.useWebView == true ||
              engine.toLowerCase() == 'animeko-web-selector',
      webViewSniffing:
          declared?.webViewSniffing ??
          requiresWebView || engine.toLowerCase() == 'animeko-web-selector',
      cookiePolicy:
          declared?.cookiePolicy ??
          (hasHeader('cookie') || (animeko?.cookies.trim().isNotEmpty ?? false)
              ? RuleCookiePolicy.taskScoped
              : RuleCookiePolicy.none),
      cleartextHttp:
          declared?.cleartextHttp ??
          [
            baseUrl,
            searchUrl,
          ].any((value) => Uri.tryParse(value)?.scheme.toLowerCase() == 'http'),
      customReferer: declared?.customReferer ?? true,
      customOrigin: declared?.customOrigin ?? hasHeader('origin'),
      customUserAgent:
          declared?.customUserAgent ??
          hasHeader('user-agent') ||
              (animeko?.videoUserAgent.trim().isNotEmpty ?? false),
      minimumCoreVersion: declared?.minimumCoreVersion ?? '1.0.0',
    );
  }

  RuleExecutionStatus get executionStatus {
    if (requiresPrivateAuth || _reasonNeedsPrivateAuth(unsupportedReason)) {
      return RuleExecutionStatus.needsPrivateAuth;
    }
    if (requiresWebView ||
        requiresCaptcha ||
        kazumi?.useWebView == true ||
        (kazumi?.antiCrawlerConfig.isNotEmpty ?? false) ||
        _reasonNeedsWebView(unsupportedReason)) {
      return RuleExecutionStatus.needsWebView;
    }

    final normalizedEngine = engine.toLowerCase();
    if (normalizedEngine == 'android-csp' &&
        (kIsWeb || defaultTargetPlatform != TargetPlatform.android)) {
      return RuleExecutionStatus.unsupportedEngine;
    }
    if (normalizedEngine == 'drpy-js' &&
        (kIsWeb ||
            !const {
              TargetPlatform.android,
              TargetPlatform.windows,
            }.contains(defaultTargetPlatform))) {
      return RuleExecutionStatus.unsupportedEngine;
    }
    final knownEngine = switch (normalizedEngine) {
      'native' ||
      'xbpq' ||
      'drpy-js' ||
      'android-csp' ||
      'animeko-web-selector' ||
      'aikanbot-api' ||
      'sorani-api' ||
      'tvbox-json-api' ||
      'tvbox-xml-api' => true,
      _ => false,
    };
    if (!knownEngine) return RuleExecutionStatus.unsupportedEngine;
    if (unsupportedReason != null || !searchable) {
      return RuleExecutionStatus.missingConfig;
    }

    final complete = switch (normalizedEngine) {
      'native' => _hasCompleteKazumiConfig(this),
      'xbpq' => _hasCompleteXbpqConfig(this),
      'drpy-js' => _hasCompleteDrpyConfig(this),
      'android-csp' => _hasCompleteAndroidCspConfig(this),
      'animeko-web-selector' => _hasCompleteAnimekoConfig(this),
      'aikanbot-api' => _hasHttpEndpoint(baseUrl),
      'sorani-api' => _hasHttpEndpoint(baseUrl),
      'tvbox-json-api' || 'tvbox-xml-api' => _hasHttpEndpoint(baseUrl),
      _ => false,
    };
    return complete
        ? RuleExecutionStatus.executable
        : RuleExecutionStatus.missingConfig;
  }

  bool get canResolveNatively => executionStatus.isExecutable;

  String get updateLabel {
    final month = '${updatedAt.month}'.padLeft(2, '0');
    final day = '${updatedAt.day}'.padLeft(2, '0');
    final hour = '${updatedAt.hour}'.padLeft(2, '0');
    final minute = '${updatedAt.minute}'.padLeft(2, '0');
    final second = '${updatedAt.second}'.padLeft(2, '0');
    return '${updatedAt.year}-$month-$day $hour:$minute:$second';
  }

  RulePlugin copyWith({
    String? id,
    String? name,
    String? version,
    RuleSourceKind? source,
    RuleContentType? contentType,
    String? engine,
    DateTime? updatedAt,
    int? qualityScore,
    List<String>? tags,
    String? baseUrl,
    String? searchUrl,
    bool? searchable,
    bool? quickSearch,
    bool? filterable,
    bool? requiresWebView,
    bool? requiresCaptcha,
    bool? requiresPrivateAuth,
    bool? installedByDefault,
    KazumiParserConfig? kazumi,
    XbpqParserConfig? xbpq,
    AnimekoWebSelectorConfig? animeko,
    Map<String, String>? requestHeaders,
    Map<String, dynamic>? rawConfig,
    String? groupId,
    int? priority,
    String? unsupportedReason,
    String? note,
    List<String>? legacyIds,
    RulePermissionManifest? permissionManifest,
  }) {
    return RulePlugin(
      id: id ?? this.id,
      name: name ?? this.name,
      version: version ?? this.version,
      source: source ?? this.source,
      contentType: contentType ?? this.contentType,
      engine: engine ?? this.engine,
      updatedAt: updatedAt ?? this.updatedAt,
      qualityScore: qualityScore ?? this.qualityScore,
      tags: tags ?? this.tags,
      baseUrl: baseUrl ?? this.baseUrl,
      searchUrl: searchUrl ?? this.searchUrl,
      searchable: searchable ?? this.searchable,
      quickSearch: quickSearch ?? this.quickSearch,
      filterable: filterable ?? this.filterable,
      requiresWebView: requiresWebView ?? this.requiresWebView,
      requiresCaptcha: requiresCaptcha ?? this.requiresCaptcha,
      requiresPrivateAuth: requiresPrivateAuth ?? this.requiresPrivateAuth,
      installedByDefault: installedByDefault ?? this.installedByDefault,
      kazumi: kazumi ?? this.kazumi,
      xbpq: xbpq ?? this.xbpq,
      animeko: animeko ?? this.animeko,
      requestHeaders: requestHeaders ?? this.requestHeaders,
      rawConfig: rawConfig ?? this.rawConfig,
      groupId: groupId ?? this.groupId,
      priority: priority ?? this.priority,
      unsupportedReason: unsupportedReason ?? this.unsupportedReason,
      note: note ?? this.note,
      legacyIds: legacyIds ?? this.legacyIds,
      permissionManifest: permissionManifest ?? this.permissionManifest,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'version': version,
    'source': source.name,
    'contentType': contentType.name,
    'engine': engine,
    'updatedAt': updatedAt.toIso8601String(),
    'qualityScore': qualityScore,
    'tags': tags,
    'baseUrl': baseUrl,
    'searchUrl': searchUrl,
    'searchable': searchable,
    'quickSearch': quickSearch,
    'filterable': filterable,
    'requiresWebView': requiresWebView,
    'requiresCaptcha': requiresCaptcha,
    'requiresPrivateAuth': requiresPrivateAuth,
    'installedByDefault': installedByDefault,
    'kazumi': kazumi?.toJson(),
    'xbpq': xbpq?.toJson(),
    'animeko': animeko == null ? null : {...animeko!.toJson(), 'cookies': ''},
    'requestHeaders': ruleHeadersForPersistence(requestHeaders),
    'rawConfig': ruleConfigForPersistence(rawConfig),
    'groupId': groupId,
    'priority': priority,
    'unsupportedReason': unsupportedReason,
    'note': note,
    if (legacyIds.isNotEmpty) 'legacyIds': legacyIds,
    'manifest': effectiveManifest.toJson(),
  };

  factory RulePlugin.fromJson(Map<String, dynamic> json) {
    final engine = json['engine']?.toString().trim();
    final hasKazumi = json['kazumi'] is Map || json.containsKey('chapterRoads');
    final hasXbpq = json['xbpq'] is Map || json.containsKey('playArray');
    final hasAnimeko = json['animeko'] is Map;
    final normalizedEngine = engine == null || engine.isEmpty
        ? hasAnimeko
              ? 'animeko-web-selector'
              : hasXbpq
              ? 'XBPQ'
              : 'native'
        : engine;
    final kazumiJson = json['kazumi'];
    final xbpqJson = json['xbpq'];
    final animekoJson = json['animeko'];
    final manifestJson = json['manifest'];
    return RulePlugin(
      id: json['id']?.toString() ?? '',
      name:
          json['name']?.toString() ??
          json['title']?.toString() ??
          json['key']?.toString() ??
          '',
      version: json['version']?.toString() ?? '1.0',
      source: RuleSourceKind.fromJson(json['source'] ?? json['sourceKind']),
      contentType: RuleContentType.fromJson(
        json['contentType'] ?? json['category'] ?? json['typeLabel'],
      ),
      engine: normalizedEngine,
      updatedAt: _dateTimeFromJson(json['updatedAt']),
      qualityScore: _intFromJson(json['qualityScore'], fallback: 60),
      tags: _stringList(json['tags']),
      baseUrl: json['baseUrl']?.toString() ?? json['url']?.toString() ?? '',
      searchUrl: json['searchUrl']?.toString() ?? '',
      searchable: _boolFromJson(json['searchable'], fallback: true),
      quickSearch: _boolFromJson(json['quickSearch'], fallback: true),
      filterable: _boolFromJson(json['filterable'], fallback: false),
      requiresWebView: _boolFromJson(json['requiresWebView']),
      requiresCaptcha: _boolFromJson(json['requiresCaptcha']),
      requiresPrivateAuth: _boolFromJson(json['requiresPrivateAuth']),
      installedByDefault: _boolFromJson(json['installedByDefault']),
      kazumi: kazumiJson is Map
          ? KazumiParserConfig.fromJson(kazumiJson.cast<String, dynamic>())
          : hasKazumi
          ? KazumiParserConfig.fromJson(json)
          : null,
      xbpq: xbpqJson is Map
          ? XbpqParserConfig.fromJson(xbpqJson.cast<String, dynamic>())
          : hasXbpq
          ? XbpqParserConfig.fromJson(json)
          : null,
      animeko: animekoJson is Map
          ? AnimekoWebSelectorConfig.fromJson(
              animekoJson.cast<String, dynamic>(),
            )
          : null,
      requestHeaders: _stringMapFromJson(json['requestHeaders']),
      rawConfig: _dynamicMapFromJson(json['rawConfig']),
      groupId: json['groupId']?.toString() ?? '',
      priority: _intFromJson(json['priority'], fallback: 100),
      unsupportedReason: _blankToNull(json['unsupportedReason']?.toString()),
      note: json['note']?.toString() ?? json['description']?.toString() ?? '',
      legacyIds: _stringList(json['legacyIds']),
      permissionManifest: manifestJson is Map
          ? RulePermissionManifest.fromImportedJson(
              manifestJson.cast<String, dynamic>(),
            )
          : null,
    );
  }
}

bool _hasCompleteKazumiConfig(RulePlugin rule) {
  final config = rule.kazumi;
  if (config == null ||
      !_hasHttpEndpoint(rule.baseUrl) ||
      !_hasHttpEndpoint(rule.searchUrl)) {
    return false;
  }
  return _allPresent([
    config.searchList,
    config.searchName,
    config.searchResult,
    config.chapterRoads,
    config.chapterResult,
  ]);
}

bool _hasCompleteXbpqConfig(RulePlugin rule) {
  final config = rule.xbpq;
  if (config == null ||
      !_hasHttpEndpoint(rule.baseUrl) ||
      !_hasHttpEndpoint(rule.searchUrl)) {
    return false;
  }
  return _allPresent([
    config.searchArray,
    config.searchTitle,
    config.searchLink,
    config.playList,
    config.playLink,
  ]);
}

bool _hasCompleteDrpyConfig(RulePlugin rule) {
  final inlineSource = rule.rawConfig['inlineSource']?.toString().trim() ?? '';
  if (inlineSource.isNotEmpty) return true;
  final extUrl = rule.rawConfig['extUrl']?.toString() ?? '';
  return _hasHttpEndpoint(extUrl);
}

bool _hasCompleteAndroidCspConfig(RulePlugin rule) =>
    isAuditedAndroidCspConfig(rule.rawConfig, fallbackApi: rule.engine);

bool _hasCompleteAnimekoConfig(RulePlugin rule) {
  final config = rule.animeko;
  if (config == null ||
      !_hasHttpEndpoint(rule.baseUrl) ||
      !_hasHttpEndpoint(config.searchUrl)) {
    return false;
  }

  final hasSubjectSelector = switch (config.subjectFormatId.toLowerCase()) {
    'indexed' => _allPresent([
      config.subjectIndexed.selectNames,
      config.subjectIndexed.selectLinks,
    ]),
    'json-path-indexed' => _allPresent([
      config.subjectJsonPathIndexed.selectNames,
      config.subjectJsonPathIndexed.selectLinks,
    ]),
    _ => config.subjectA.selectLists.trim().isNotEmpty,
  };
  final hasEpisodeSelector = switch (config.channelFormatId.toLowerCase()) {
    'no-channel' => config.channelNoChannel.selectEpisodes.trim().isNotEmpty,
    _ => _allPresent([
      config.channelFlattened.selectEpisodeLists,
      config.channelFlattened.selectEpisodesFromList,
    ]),
  };
  return hasSubjectSelector && hasEpisodeSelector;
}

bool _allPresent(Iterable<String> values) =>
    values.every((value) => value.trim().isNotEmpty);

bool _hasHttpEndpoint(String value) {
  final uri = Uri.tryParse(value.trim());
  return uri != null &&
      const {'http', 'https'}.contains(uri.scheme.toLowerCase()) &&
      uri.host.isNotEmpty;
}

bool _reasonNeedsWebView(String? reason) {
  final text = reason?.toLowerCase() ?? '';
  return text.contains('webview') ||
      text.contains('验证码') ||
      text.contains('反爬') ||
      text.contains('人机验证');
}

bool _reasonNeedsPrivateAuth(String? reason) {
  final text = reason?.toLowerCase() ?? '';
  return text.contains('私密授权') ||
      text.contains('需要授权') ||
      text.contains('需要登录') ||
      text.contains('private auth');
}

class AnimekoWebSelectorConfig {
  const AnimekoWebSelectorConfig({
    required this.searchUrl,
    required this.subjectFormatId,
    required this.channelFormatId,
    required this.matchVideoUrl,
    this.rawBaseUrl = '',
    this.searchUseOnlyFirstWord = false,
    this.searchRemoveSpecial = false,
    this.preferShortest = false,
    this.defaultResolution = '',
    this.subjectA = const AnimekoSubjectAConfig(),
    this.subjectIndexed = const AnimekoSubjectIndexedConfig(),
    this.subjectJsonPathIndexed = const AnimekoSubjectJsonPathIndexedConfig(),
    this.channelFlattened = const AnimekoChannelFlattenedConfig(),
    this.channelNoChannel = const AnimekoChannelNoChannelConfig(),
    this.enableNestedUrl = false,
    this.matchNestedUrl = '',
    this.cookies = '',
    this.videoReferer = '',
    this.videoUserAgent = '',
  });

  final String searchUrl;
  final String rawBaseUrl;
  final bool searchUseOnlyFirstWord;
  final bool searchRemoveSpecial;
  final bool preferShortest;
  final String subjectFormatId;
  final String channelFormatId;
  final String defaultResolution;
  final AnimekoSubjectAConfig subjectA;
  final AnimekoSubjectIndexedConfig subjectIndexed;
  final AnimekoSubjectJsonPathIndexedConfig subjectJsonPathIndexed;
  final AnimekoChannelFlattenedConfig channelFlattened;
  final AnimekoChannelNoChannelConfig channelNoChannel;
  final bool enableNestedUrl;
  final String matchNestedUrl;
  final String matchVideoUrl;
  final String cookies;
  final String videoReferer;
  final String videoUserAgent;

  Map<String, dynamic> toJson() => {
    'searchUrl': searchUrl,
    'rawBaseUrl': rawBaseUrl,
    'searchUseOnlyFirstWord': searchUseOnlyFirstWord,
    'searchRemoveSpecial': searchRemoveSpecial,
    'preferShortest': preferShortest,
    'subjectFormatId': subjectFormatId,
    'channelFormatId': channelFormatId,
    'defaultResolution': defaultResolution,
    'subjectA': subjectA.toJson(),
    'subjectIndexed': subjectIndexed.toJson(),
    'subjectJsonPathIndexed': subjectJsonPathIndexed.toJson(),
    'channelFlattened': channelFlattened.toJson(),
    'channelNoChannel': channelNoChannel.toJson(),
    'enableNestedUrl': enableNestedUrl,
    'matchNestedUrl': matchNestedUrl,
    'matchVideoUrl': matchVideoUrl,
    'cookies': cookies,
    'videoReferer': videoReferer,
    'videoUserAgent': videoUserAgent,
  };

  factory AnimekoWebSelectorConfig.fromJson(Map<String, dynamic> json) {
    final subjectAJson = json['subjectA'];
    final subjectIndexedJson = json['subjectIndexed'];
    final subjectJsonPathIndexedJson = json['subjectJsonPathIndexed'];
    final channelFlattenedJson = json['channelFlattened'];
    final channelNoChannelJson = json['channelNoChannel'];
    return AnimekoWebSelectorConfig(
      searchUrl: json['searchUrl']?.toString() ?? '',
      rawBaseUrl: json['rawBaseUrl']?.toString() ?? '',
      searchUseOnlyFirstWord: _boolFromJson(json['searchUseOnlyFirstWord']),
      searchRemoveSpecial: _boolFromJson(json['searchRemoveSpecial']),
      preferShortest: _boolFromJson(json['preferShortest']),
      subjectFormatId: json['subjectFormatId']?.toString() ?? 'a',
      channelFormatId: json['channelFormatId']?.toString() ?? 'index-grouped',
      defaultResolution: json['defaultResolution']?.toString() ?? '',
      subjectA: subjectAJson is Map
          ? AnimekoSubjectAConfig.fromJson(subjectAJson.cast<String, dynamic>())
          : const AnimekoSubjectAConfig(),
      subjectIndexed: subjectIndexedJson is Map
          ? AnimekoSubjectIndexedConfig.fromJson(
              subjectIndexedJson.cast<String, dynamic>(),
            )
          : const AnimekoSubjectIndexedConfig(),
      subjectJsonPathIndexed: subjectJsonPathIndexedJson is Map
          ? AnimekoSubjectJsonPathIndexedConfig.fromJson(
              subjectJsonPathIndexedJson.cast<String, dynamic>(),
            )
          : const AnimekoSubjectJsonPathIndexedConfig(),
      channelFlattened: channelFlattenedJson is Map
          ? AnimekoChannelFlattenedConfig.fromJson(
              channelFlattenedJson.cast<String, dynamic>(),
            )
          : const AnimekoChannelFlattenedConfig(),
      channelNoChannel: channelNoChannelJson is Map
          ? AnimekoChannelNoChannelConfig.fromJson(
              channelNoChannelJson.cast<String, dynamic>(),
            )
          : const AnimekoChannelNoChannelConfig(),
      enableNestedUrl: _boolFromJson(json['enableNestedUrl']),
      matchNestedUrl: json['matchNestedUrl']?.toString() ?? '',
      matchVideoUrl: json['matchVideoUrl']?.toString() ?? '',
      cookies: json['cookies']?.toString() ?? '',
      videoReferer: json['videoReferer']?.toString() ?? '',
      videoUserAgent: json['videoUserAgent']?.toString() ?? '',
    );
  }
}

class AnimekoSubjectAConfig {
  const AnimekoSubjectAConfig({
    this.selectLists = '',
    this.preferShorterName = false,
  });

  final String selectLists;
  final bool preferShorterName;

  Map<String, dynamic> toJson() => {
    'selectLists': selectLists,
    'preferShorterName': preferShorterName,
  };

  factory AnimekoSubjectAConfig.fromJson(Map<String, dynamic> json) {
    return AnimekoSubjectAConfig(
      selectLists: json['selectLists']?.toString() ?? '',
      preferShorterName: _boolFromJson(json['preferShorterName']),
    );
  }
}

class AnimekoSubjectIndexedConfig {
  const AnimekoSubjectIndexedConfig({
    this.selectNames = '',
    this.selectLinks = '',
    this.preferShorterName = false,
  });

  final String selectNames;
  final String selectLinks;
  final bool preferShorterName;

  Map<String, dynamic> toJson() => {
    'selectNames': selectNames,
    'selectLinks': selectLinks,
    'preferShorterName': preferShorterName,
  };

  factory AnimekoSubjectIndexedConfig.fromJson(Map<String, dynamic> json) {
    return AnimekoSubjectIndexedConfig(
      selectNames: json['selectNames']?.toString() ?? '',
      selectLinks: json['selectLinks']?.toString() ?? '',
      preferShorterName: _boolFromJson(json['preferShorterName']),
    );
  }
}

class AnimekoSubjectJsonPathIndexedConfig {
  const AnimekoSubjectJsonPathIndexedConfig({
    this.selectNames = '',
    this.selectLinks = '',
    this.preferShorterName = false,
  });

  final String selectNames;
  final String selectLinks;
  final bool preferShorterName;

  Map<String, dynamic> toJson() => {
    'selectNames': selectNames,
    'selectLinks': selectLinks,
    'preferShorterName': preferShorterName,
  };

  factory AnimekoSubjectJsonPathIndexedConfig.fromJson(
    Map<String, dynamic> json,
  ) {
    return AnimekoSubjectJsonPathIndexedConfig(
      selectNames: json['selectNames']?.toString() ?? '',
      selectLinks: json['selectLinks']?.toString() ?? '',
      preferShorterName: _boolFromJson(json['preferShorterName']),
    );
  }
}

class AnimekoChannelFlattenedConfig {
  const AnimekoChannelFlattenedConfig({
    this.selectChannelNames = '',
    this.matchChannelName = '',
    this.selectEpisodeLists = '',
    this.selectEpisodesFromList = '',
    this.selectEpisodeLinksFromList = '',
    this.matchEpisodeSortFromName = '',
  });

  final String selectChannelNames;
  final String matchChannelName;
  final String selectEpisodeLists;
  final String selectEpisodesFromList;
  final String selectEpisodeLinksFromList;
  final String matchEpisodeSortFromName;

  Map<String, dynamic> toJson() => {
    'selectChannelNames': selectChannelNames,
    'matchChannelName': matchChannelName,
    'selectEpisodeLists': selectEpisodeLists,
    'selectEpisodesFromList': selectEpisodesFromList,
    'selectEpisodeLinksFromList': selectEpisodeLinksFromList,
    'matchEpisodeSortFromName': matchEpisodeSortFromName,
  };

  factory AnimekoChannelFlattenedConfig.fromJson(Map<String, dynamic> json) {
    return AnimekoChannelFlattenedConfig(
      selectChannelNames: json['selectChannelNames']?.toString() ?? '',
      matchChannelName: json['matchChannelName']?.toString() ?? '',
      selectEpisodeLists: json['selectEpisodeLists']?.toString() ?? '',
      selectEpisodesFromList: json['selectEpisodesFromList']?.toString() ?? '',
      selectEpisodeLinksFromList:
          json['selectEpisodeLinksFromList']?.toString() ?? '',
      matchEpisodeSortFromName:
          json['matchEpisodeSortFromName']?.toString() ?? '',
    );
  }
}

class AnimekoChannelNoChannelConfig {
  const AnimekoChannelNoChannelConfig({
    this.selectEpisodes = '',
    this.selectEpisodeLinks = '',
    this.matchEpisodeSortFromName = '',
  });

  final String selectEpisodes;
  final String selectEpisodeLinks;
  final String matchEpisodeSortFromName;

  Map<String, dynamic> toJson() => {
    'selectEpisodes': selectEpisodes,
    'selectEpisodeLinks': selectEpisodeLinks,
    'matchEpisodeSortFromName': matchEpisodeSortFromName,
  };

  factory AnimekoChannelNoChannelConfig.fromJson(Map<String, dynamic> json) {
    return AnimekoChannelNoChannelConfig(
      selectEpisodes: json['selectEpisodes']?.toString() ?? '',
      selectEpisodeLinks: json['selectEpisodeLinks']?.toString() ?? '',
      matchEpisodeSortFromName:
          json['matchEpisodeSortFromName']?.toString() ?? '',
    );
  }
}

class KazumiParserConfig {
  const KazumiParserConfig({
    required this.searchList,
    required this.searchName,
    required this.searchResult,
    required this.chapterRoads,
    required this.chapterResult,
    this.referer = '',
    this.userAgent = '',
    this.apiLevel = '',
    this.multipleSources = false,
    this.useWebView = false,
    this.useNativePlayer = true,
    this.usePost = false,
    this.useLegacyParser = false,
    this.adBlocker = false,
    this.searchMode = '',
    this.chapterMode = '',
    this.searchApiConfig = const {},
    this.chapterApiConfig = const {},
    this.antiCrawlerConfig = const {},
  });

  final String searchList;
  final String searchName;
  final String searchResult;
  final String chapterRoads;
  final String chapterResult;
  final String referer;
  final String userAgent;
  final String apiLevel;
  final bool multipleSources;
  final bool useWebView;
  final bool useNativePlayer;
  final bool usePost;
  final bool useLegacyParser;
  final bool adBlocker;
  final String searchMode;
  final String chapterMode;
  final Map<String, dynamic> searchApiConfig;
  final Map<String, dynamic> chapterApiConfig;
  final Map<String, dynamic> antiCrawlerConfig;

  Map<String, dynamic> toJson() => {
    'searchList': searchList,
    'searchName': searchName,
    'searchResult': searchResult,
    'chapterRoads': chapterRoads,
    'chapterResult': chapterResult,
    'referer': referer,
    'userAgent': userAgent,
    'apiLevel': apiLevel,
    'multipleSources': multipleSources,
    'useWebView': useWebView,
    'useNativePlayer': useNativePlayer,
    'usePost': usePost,
    'useLegacyParser': useLegacyParser,
    'adBlocker': adBlocker,
    'searchMode': searchMode,
    'chapterMode': chapterMode,
    'searchApiConfig': searchApiConfig,
    'chapterApiConfig': chapterApiConfig,
    'antiCrawlerConfig': antiCrawlerConfig,
  };

  factory KazumiParserConfig.fromJson(Map<String, dynamic> json) {
    return KazumiParserConfig(
      searchList: json['searchList']?.toString() ?? '',
      searchName: json['searchName']?.toString() ?? '',
      searchResult: json['searchResult']?.toString() ?? '',
      chapterRoads: json['chapterRoads']?.toString() ?? '',
      chapterResult: json['chapterResult']?.toString() ?? '',
      referer: json['referer']?.toString() ?? '',
      userAgent: json['userAgent']?.toString() ?? '',
      apiLevel: json['apiLevel']?.toString() ?? json['api']?.toString() ?? '',
      multipleSources: _boolFromJson(
        json['multipleSources'] ?? json['muliSources'],
      ),
      useWebView: _boolFromJson(json['useWebView'] ?? json['useWebview']),
      useNativePlayer: _boolFromJson(json['useNativePlayer'], fallback: true),
      usePost: _boolFromJson(json['usePost']),
      useLegacyParser: _boolFromJson(json['useLegacyParser']),
      adBlocker: _boolFromJson(json['adBlocker']),
      searchMode: json['searchMode']?.toString() ?? '',
      chapterMode: json['chapterMode']?.toString() ?? '',
      searchApiConfig: _dynamicMapFromJson(json['searchApiConfig']),
      chapterApiConfig: _dynamicMapFromJson(json['chapterApiConfig']),
      antiCrawlerConfig: _dynamicMapFromJson(json['antiCrawlerConfig']),
    );
  }
}

class XbpqParserConfig {
  const XbpqParserConfig({
    required this.searchArray,
    required this.searchTitle,
    required this.searchLink,
    required this.playArray,
    required this.playList,
    required this.playTitle,
    required this.playLink,
    this.lineArray = '',
    this.lineTitle = '',
    this.jumpPlayLink = '',
    this.reverseEpisodes = false,
    this.searchPostBody = '',
    this.encoding = 'UTF-8',
  });

  final String searchArray;
  final String searchTitle;
  final String searchLink;
  final String playArray;
  final String playList;
  final String playTitle;
  final String playLink;
  final String lineArray;
  final String lineTitle;
  final String jumpPlayLink;
  final bool reverseEpisodes;
  final String searchPostBody;
  final String encoding;

  Map<String, dynamic> toJson() => {
    'searchArray': searchArray,
    'searchTitle': searchTitle,
    'searchLink': searchLink,
    'playArray': playArray,
    'playList': playList,
    'playTitle': playTitle,
    'playLink': playLink,
    'lineArray': lineArray,
    'lineTitle': lineTitle,
    'jumpPlayLink': jumpPlayLink,
    'reverseEpisodes': reverseEpisodes,
    'searchPostBody': searchPostBody,
    'encoding': encoding,
  };

  factory XbpqParserConfig.fromJson(Map<String, dynamic> json) {
    return XbpqParserConfig(
      searchArray: json['searchArray']?.toString() ?? '',
      searchTitle: json['searchTitle']?.toString() ?? '',
      searchLink: json['searchLink']?.toString() ?? '',
      playArray: json['playArray']?.toString() ?? '',
      playList: json['playList']?.toString() ?? '',
      playTitle: json['playTitle']?.toString() ?? '',
      playLink: json['playLink']?.toString() ?? '',
      lineArray: json['lineArray']?.toString() ?? '',
      lineTitle: json['lineTitle']?.toString() ?? '',
      jumpPlayLink: json['jumpPlayLink']?.toString() ?? '',
      reverseEpisodes: _boolFromJson(json['reverseEpisodes']),
      searchPostBody: json['searchPostBody']?.toString() ?? '',
      encoding: json['encoding']?.toString() ?? 'UTF-8',
    );
  }
}

class RuleRepositoryRecord {
  const RuleRepositoryRecord({
    required this.id,
    required this.name,
    required this.url,
    required this.importedAt,
    required this.ruleCount,
    this.legacyIds = const [],
  });

  final String id;
  final String name;
  final String url;
  final DateTime importedAt;
  final int ruleCount;
  final List<String> legacyIds;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'importedAt': importedAt.toIso8601String(),
    'ruleCount': ruleCount,
    if (legacyIds.isNotEmpty) 'legacyIds': legacyIds,
  };

  factory RuleRepositoryRecord.fromJson(Map<String, dynamic> json) {
    return RuleRepositoryRecord(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '用户仓库',
      url: json['url']?.toString() ?? '',
      importedAt: _dateTimeFromJson(json['importedAt']),
      ruleCount: _intFromJson(json['ruleCount']),
      legacyIds: _stringList(json['legacyIds']),
    );
  }
}

class RuleImportBundle {
  const RuleImportBundle({
    required this.name,
    required this.rules,
    this.sourceUrl = '',
  });

  final String name;
  final List<RulePlugin> rules;
  final String sourceUrl;
}

class RuleImportResult {
  const RuleImportResult({
    required this.repositoryName,
    required this.ruleCount,
    required this.installedCount,
  });

  final String repositoryName;
  final int ruleCount;
  final int installedCount;
}

class RulePluginState {
  const RulePluginState({
    this.installedIds = const {},
    this.enabledIds = const {},
    this.approvedPermissionDigests = const {},
    this.customRules = const [],
    this.repositories = const [],
  });

  final Set<String> installedIds;
  final Set<String> enabledIds;
  final Map<String, String> approvedPermissionDigests;
  final List<RulePlugin> customRules;
  final List<RuleRepositoryRecord> repositories;

  bool isInstalled(String id) => installedIds.contains(id);

  bool isEnabled(String id) => enabledIds.contains(id);

  bool hasApprovedPermissions(RulePlugin rule) {
    if (!rule.effectiveManifest.requiresApproval) return true;
    return approvedPermissionDigests[rule.id] ==
        rule.effectiveManifest.permissionDigest;
  }

  RulePluginState copyWith({
    Set<String>? installedIds,
    Set<String>? enabledIds,
    Map<String, String>? approvedPermissionDigests,
    List<RulePlugin>? customRules,
    List<RuleRepositoryRecord>? repositories,
  }) {
    return RulePluginState(
      installedIds: installedIds ?? this.installedIds,
      enabledIds: enabledIds ?? this.enabledIds,
      approvedPermissionDigests:
          approvedPermissionDigests ?? this.approvedPermissionDigests,
      customRules: customRules ?? this.customRules,
      repositories: repositories ?? this.repositories,
    );
  }

  Map<String, dynamic> toJson() => {
    'installedIds': installedIds.toList(),
    'enabledIds': enabledIds.toList(),
    'approvedPermissionDigests': approvedPermissionDigests,
    'customRules': customRules.map((rule) => rule.toJson()).toList(),
    'repositories': repositories.map((record) => record.toJson()).toList(),
  };

  factory RulePluginState.fromJson(Map<String, dynamic> json) {
    return RulePluginState(
      installedIds: _stringSet(json['installedIds']),
      enabledIds: _stringSet(json['enabledIds']),
      approvedPermissionDigests: _stringMapFromJson(
        json['approvedPermissionDigests'],
      ),
      customRules: _ruleList(json['customRules']),
      repositories: _repositoryList(json['repositories']),
    );
  }
}

Set<String> _stringSet(Object? value) {
  if (value is! List) return const {};
  return value.map((item) => item.toString()).toSet();
}

List<RulePlugin> _ruleList(Object? value) {
  if (value is! List) return const [];
  return value
      .whereType<Map>()
      .map((item) => RulePlugin.fromJson(item.cast<String, dynamic>()))
      .where((rule) => rule.id.trim().isNotEmpty)
      .toList(growable: false);
}

List<RuleRepositoryRecord> _repositoryList(Object? value) {
  if (value is! List) return const [];
  return value
      .whereType<Map>()
      .map(
        (item) => RuleRepositoryRecord.fromJson(item.cast<String, dynamic>()),
      )
      .where((record) => record.id.trim().isNotEmpty)
      .toList(growable: false);
}

DateTime _dateTimeFromJson(Object? value) {
  if (value is DateTime) return value;
  if (value is num) {
    final number = value.round();
    if (number > 100000000000) {
      return DateTime.fromMillisecondsSinceEpoch(number);
    }
    return DateTime.fromMillisecondsSinceEpoch(number * 1000);
  }
  return DateTime.tryParse(value?.toString() ?? '') ?? DateTime.now();
}

Map<String, String> _stringMapFromJson(Object? value) {
  if (value is! Map) return const {};
  return {
    for (final entry in value.entries)
      if (entry.key.toString().trim().isNotEmpty && entry.value != null)
        entry.key.toString(): entry.value.toString(),
  };
}

Map<String, dynamic> _dynamicMapFromJson(Object? value) {
  if (value is! Map) return const {};
  return value.map((key, item) => MapEntry(key.toString(), item));
}

int _intFromJson(Object? value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.round();
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

bool _boolFromJson(Object? value, {bool fallback = false}) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  final text = value?.toString().trim().toLowerCase();
  if (text == 'true' || text == '1' || text == 'yes') return true;
  if (text == 'false' || text == '0' || text == 'no') return false;
  return fallback;
}

String? _blankToNull(String? value) {
  final text = value?.trim();
  if (text == null || text.isEmpty) return null;
  return text;
}

List<String> _stringList(Object? value) {
  if (value is! List) return const [];
  return value
      .map((item) => item.toString().trim())
      .where((item) => item.isNotEmpty)
      .toList(growable: false);
}
