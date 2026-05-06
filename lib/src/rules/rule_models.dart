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
    this.groupId = '',
    this.priority = 100,
    this.unsupportedReason,
    this.note = '',
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
  final String groupId;
  final int priority;
  final String? unsupportedReason;
  final String note;

  String get sourceLabel => source.label;

  String get contentLabel => contentType.label;

  bool get canResolveNatively {
    if (requiresCaptcha || requiresPrivateAuth || unsupportedReason != null) {
      return false;
    }
    final normalizedEngine = engine.toLowerCase();
    return (normalizedEngine == 'native' && kazumi != null) ||
        (normalizedEngine == 'xbpq' && xbpq != null) ||
        (normalizedEngine == 'animeko-web-selector' && animeko != null);
  }

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
    String? groupId,
    int? priority,
    String? unsupportedReason,
    String? note,
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
      groupId: groupId ?? this.groupId,
      priority: priority ?? this.priority,
      unsupportedReason: unsupportedReason ?? this.unsupportedReason,
      note: note ?? this.note,
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
    'animeko': animeko?.toJson(),
    'groupId': groupId,
    'priority': priority,
    'unsupportedReason': unsupportedReason,
    'note': note,
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
      groupId: json['groupId']?.toString() ?? '',
      priority: _intFromJson(json['priority'], fallback: 100),
      unsupportedReason: _blankToNull(json['unsupportedReason']?.toString()),
      note: json['note']?.toString() ?? json['description']?.toString() ?? '',
    );
  }
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
  });

  final String searchList;
  final String searchName;
  final String searchResult;
  final String chapterRoads;
  final String chapterResult;
  final String referer;
  final String userAgent;

  Map<String, dynamic> toJson() => {
    'searchList': searchList,
    'searchName': searchName,
    'searchResult': searchResult,
    'chapterRoads': chapterRoads,
    'chapterResult': chapterResult,
    'referer': referer,
    'userAgent': userAgent,
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
  });

  final String id;
  final String name;
  final String url;
  final DateTime importedAt;
  final int ruleCount;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'importedAt': importedAt.toIso8601String(),
    'ruleCount': ruleCount,
  };

  factory RuleRepositoryRecord.fromJson(Map<String, dynamic> json) {
    return RuleRepositoryRecord(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '用户仓库',
      url: json['url']?.toString() ?? '',
      importedAt: _dateTimeFromJson(json['importedAt']),
      ruleCount: _intFromJson(json['ruleCount']),
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
    this.customRules = const [],
    this.repositories = const [],
  });

  final Set<String> installedIds;
  final Set<String> enabledIds;
  final List<RulePlugin> customRules;
  final List<RuleRepositoryRecord> repositories;

  bool isInstalled(String id) => installedIds.contains(id);

  bool isEnabled(String id) => enabledIds.contains(id);

  RulePluginState copyWith({
    Set<String>? installedIds,
    Set<String>? enabledIds,
    List<RulePlugin>? customRules,
    List<RuleRepositoryRecord>? repositories,
  }) {
    return RulePluginState(
      installedIds: installedIds ?? this.installedIds,
      enabledIds: enabledIds ?? this.enabledIds,
      customRules: customRules ?? this.customRules,
      repositories: repositories ?? this.repositories,
    );
  }

  Map<String, dynamic> toJson() => {
    'installedIds': installedIds.toList(),
    'enabledIds': enabledIds.toList(),
    'customRules': customRules.map((rule) => rule.toJson()).toList(),
    'repositories': repositories.map((record) => record.toJson()).toList(),
  };

  factory RulePluginState.fromJson(Map<String, dynamic> json) {
    return RulePluginState(
      installedIds: _stringSet(json['installedIds']),
      enabledIds: _stringSet(json['enabledIds']),
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
