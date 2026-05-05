import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'rule_models.dart';

class RuleImporter {
  const RuleImporter({
    http.Client? client,
    this.timeout = const Duration(seconds: 12),
  }) : _client = client;

  final http.Client? _client;
  final Duration timeout;

  Future<RuleImportBundle> importFromUrl(String url) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme) {
      throw const FormatException('请输入完整的 http/https 仓库地址。');
    }
    final ownedClient = _client == null;
    final client = _client ?? http.Client();
    try {
      final response = await client.get(uri).timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 400) {
        throw FormatException('仓库请求失败：HTTP ${response.statusCode}');
      }
      return importFromText(response.body, sourceUrl: uri.toString());
    } finally {
      if (ownedClient) client.close();
    }
  }

  RuleImportBundle importFromText(String text, {String sourceUrl = ''}) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) throw const FormatException('导入内容为空。');
    final decoded = jsonDecode(trimmed);
    final name = _repositoryName(decoded, sourceUrl);
    final rules = _parseRules(decoded, sourceUrl)
        .where(
          (rule) => rule.id.trim().isNotEmpty && rule.name.trim().isNotEmpty,
        )
        .toList(growable: false);
    if (rules.isEmpty) {
      throw const FormatException('没有识别到可导入的规则。');
    }
    return RuleImportBundle(name: name, rules: rules, sourceUrl: sourceUrl);
  }

  String _repositoryName(Object? decoded, String sourceUrl) {
    if (decoded is Map) {
      final name =
          decoded['name']?.toString() ??
          decoded['title']?.toString() ??
          decoded['repository']?.toString();
      if (name != null && name.trim().isNotEmpty) return name.trim();
    }
    final uri = Uri.tryParse(sourceUrl);
    if (uri != null && uri.host.isNotEmpty) return uri.host;
    return '用户规则仓库';
  }

  List<RulePlugin> _parseRules(Object? decoded, String sourceUrl) {
    if (decoded is List) {
      return _parseRuleList(decoded, sourceUrl);
    }
    if (decoded is! Map) return const [];
    final map = decoded.cast<String, dynamic>();
    final animekoRules = _parseAnimekoMediaSources(map, sourceUrl);
    if (animekoRules.isNotEmpty) return animekoRules;
    for (final key in const ['rules', 'plugins', 'items', 'data']) {
      final value = map[key];
      if (value is List) return _parseRuleList(value, sourceUrl);
    }
    if (map['sites'] is List) return _parseTvBoxSites(map, sourceUrl);
    if (_looksLikeSingleRule(map)) {
      final rule = _ruleFromMap(map, sourceUrl);
      return rule == null ? const [] : [rule];
    }
    return const [];
  }

  List<RulePlugin> _parseAnimekoMediaSources(
    Map<String, dynamic> root,
    String sourceUrl,
  ) {
    final exported = root['exportedMediaSourceDataList'];
    final mediaSources = exported is Map
        ? exported['mediaSources']
        : root['mediaSources'];
    if (mediaSources is! List) return const [];

    final rules = <RulePlugin>[];
    for (var index = 0; index < mediaSources.length; index++) {
      final source = mediaSources[index];
      if (source is! Map) continue;
      final rule = _animekoMediaSourceFromMap(
        source.cast<String, dynamic>(),
        sourceUrl,
        index,
      );
      if (rule != null) rules.add(rule);
    }
    return rules;
  }

  RulePlugin? _animekoMediaSourceFromMap(
    Map<String, dynamic> source,
    String sourceUrl,
    int index,
  ) {
    final factoryId = source['factoryId']?.toString().trim() ?? '';
    final arguments = source['arguments'];
    if (factoryId.isEmpty || arguments is! Map) return null;

    final args = arguments.cast<String, dynamic>();
    final name = (args['name']?.toString() ?? 'Animeko 源 ${index + 1}').trim();
    if (name.isEmpty) return null;

    final searchConfig = args['searchConfig'] is Map
        ? (args['searchConfig'] as Map).cast<String, dynamic>()
        : <String, dynamic>{};
    final searchUrl = searchConfig['searchUrl']?.toString() ?? '';
    final baseUrl = _animekoBaseUrl(
      searchUrl,
      searchConfig['rawBaseUrl']?.toString() ?? '',
    );
    final idSeed = '$sourceUrl:$factoryId:$name:$searchUrl:$index';
    final version = source['version']?.toString() ?? '1.0';
    final description = args['description']?.toString() ?? '';

    if (factoryId == 'web-selector') {
      return RulePlugin(
        id: 'custom:animeko:${_hash(idSeed)}',
        name: name,
        version: version,
        source: RuleSourceKind.custom,
        contentType: RuleContentType.anime,
        engine: 'animeko-web-selector',
        updatedAt: DateTime.now(),
        qualityScore: 76,
        tags: const ['Animeko', 'CSS', '在线播放'],
        baseUrl: baseUrl,
        searchUrl: searchUrl,
        searchable: searchUrl.trim().isNotEmpty,
        quickSearch: true,
        filterable: false,
        installedByDefault: false,
        animeko: _animekoConfigFromSearchConfig(searchConfig),
        note: description.trim().isEmpty
            ? '从 Animeko web-selector 源导入，可直接尝试解析在线播放地址。'
            : description,
      );
    }

    if (factoryId == 'rss') {
      return RulePlugin(
        id: 'custom:animeko-rss:${_hash(idSeed)}',
        name: name,
        version: version,
        source: RuleSourceKind.custom,
        contentType: RuleContentType.anime,
        engine: 'animeko-rss',
        updatedAt: DateTime.now(),
        qualityScore: 50,
        tags: const ['Animeko', 'RSS', 'BT'],
        baseUrl: baseUrl,
        searchUrl: searchUrl,
        searchable: searchUrl.trim().isNotEmpty,
        quickSearch: true,
        filterable: false,
        installedByDefault: false,
        unsupportedReason:
            '这是 BT/RSS 资源订阅，不是 mp4/m3u8 在线播放源；当前播放器没有下载或 BT 边下边播能力，所以不能直接启用播放。',
        note: description.trim().isEmpty
            ? '从 Animeko RSS/BT 源导入，仅作为资源信息保留。'
            : description,
      );
    }

    return RulePlugin(
      id: 'custom:animeko-unsupported:${_hash(idSeed)}',
      name: name,
      version: version,
      source: RuleSourceKind.custom,
      contentType: RuleContentType.anime,
      engine: 'animeko-$factoryId',
      updatedAt: DateTime.now(),
      qualityScore: 40,
      tags: const ['Animeko', '暂不支持'],
      baseUrl: baseUrl,
      searchUrl: searchUrl,
      searchable: searchUrl.trim().isNotEmpty,
      quickSearch: false,
      filterable: false,
      installedByDefault: false,
      unsupportedReason: '当前还没有接入 Animeko 的 $factoryId 源执行器。',
      note: description.trim().isEmpty ? '从 Animeko 源导入。' : description,
    );
  }

  AnimekoWebSelectorConfig _animekoConfigFromSearchConfig(
    Map<String, dynamic> searchConfig,
  ) {
    final subjectA = searchConfig['selectorSubjectFormatA'] is Map
        ? (searchConfig['selectorSubjectFormatA'] as Map)
              .cast<String, dynamic>()
        : <String, dynamic>{};
    final subjectIndexed = searchConfig['selectorSubjectFormatIndexed'] is Map
        ? (searchConfig['selectorSubjectFormatIndexed'] as Map)
              .cast<String, dynamic>()
        : <String, dynamic>{};
    final channelFlattened =
        searchConfig['selectorChannelFormatFlattened'] is Map
        ? (searchConfig['selectorChannelFormatFlattened'] as Map)
              .cast<String, dynamic>()
        : <String, dynamic>{};
    final channelNoChannel =
        searchConfig['selectorChannelFormatNoChannel'] is Map
        ? (searchConfig['selectorChannelFormatNoChannel'] as Map)
              .cast<String, dynamic>()
        : <String, dynamic>{};
    final matchVideo = searchConfig['matchVideo'] is Map
        ? (searchConfig['matchVideo'] as Map).cast<String, dynamic>()
        : <String, dynamic>{};
    final videoHeaders = matchVideo['addHeadersToVideo'] is Map
        ? (matchVideo['addHeadersToVideo'] as Map).cast<String, dynamic>()
        : <String, dynamic>{};

    return AnimekoWebSelectorConfig(
      searchUrl: searchConfig['searchUrl']?.toString() ?? '',
      rawBaseUrl: searchConfig['rawBaseUrl']?.toString() ?? '',
      searchUseOnlyFirstWord: _boolFromAny(
        searchConfig['searchUseOnlyFirstWord'],
      ),
      searchRemoveSpecial: _boolFromAny(searchConfig['searchRemoveSpecial']),
      preferShortest: _boolFromAny(searchConfig['preferShortest']),
      subjectFormatId: searchConfig['subjectFormatId']?.toString() ?? 'a',
      channelFormatId:
          searchConfig['channelFormatId']?.toString() ?? 'index-grouped',
      defaultResolution: searchConfig['defaultResolution']?.toString() ?? '',
      subjectA: AnimekoSubjectAConfig.fromJson(subjectA),
      subjectIndexed: AnimekoSubjectIndexedConfig.fromJson(subjectIndexed),
      channelFlattened: AnimekoChannelFlattenedConfig.fromJson(
        channelFlattened,
      ),
      channelNoChannel: AnimekoChannelNoChannelConfig.fromJson(
        channelNoChannel,
      ),
      enableNestedUrl: _boolFromAny(matchVideo['enableNestedUrl']),
      matchNestedUrl: matchVideo['matchNestedUrl']?.toString() ?? '',
      matchVideoUrl: matchVideo['matchVideoUrl']?.toString() ?? '',
      cookies: matchVideo['cookies']?.toString() ?? '',
      videoReferer: videoHeaders['referer']?.toString() ?? '',
      videoUserAgent: videoHeaders['userAgent']?.toString() ?? '',
    );
  }

  List<RulePlugin> _parseRuleList(List<dynamic> values, String sourceUrl) {
    final rules = <RulePlugin>[];
    for (final value in values) {
      if (value is! Map) continue;
      final map = value.cast<String, dynamic>();
      final rule = _ruleFromMap(map, sourceUrl);
      if (rule != null) rules.add(rule);
    }
    return rules;
  }

  List<RulePlugin> _parseTvBoxSites(
    Map<String, dynamic> root,
    String sourceUrl,
  ) {
    final sites = root['sites'];
    if (sites is! List) return const [];
    final rules = <RulePlugin>[];
    for (final site in sites.whereType<Map>()) {
      final map = site.cast<String, dynamic>();
      final type = map['type'];
      final api = map['api']?.toString() ?? '';
      final searchable = _boolFromAny(map['searchable'], fallback: true);
      if (!searchable) continue;
      final isXbpq =
          type?.toString() == '1' || api.toLowerCase().contains('xbpq');
      if (!isXbpq) continue;
      final ext = map['ext'];
      final extMap = ext is Map
          ? ext.cast<String, dynamic>()
          : <String, dynamic>{};
      final merged = <String, dynamic>{
        ...extMap,
        'id':
            'custom:tvbox:${_hash('$sourceUrl:${map['key'] ?? map['name'] ?? api}')}',
        'name': map['name'] ?? map['key'] ?? 'TVBox 规则',
        'source': 'tvbox',
        'engine': 'XBPQ',
        'contentType': _contentTypeFromText('${map['name']} ${map['group']}'),
        'baseUrl': extMap['主页url'] ?? extMap['baseUrl'] ?? '',
        'searchUrl': extMap['搜索url'] ?? extMap['searchUrl'] ?? '',
        'searchable': searchable,
        'quickSearch': true,
        'filterable': false,
        'note': sourceUrl.isEmpty ? '从 TVBox 配置导入。' : '从 $sourceUrl 导入。',
      };
      final rule = _ruleFromMap(merged, sourceUrl);
      if (rule != null) rules.add(rule);
    }
    return rules;
  }

  RulePlugin? _ruleFromMap(Map<String, dynamic> raw, String sourceUrl) {
    final normalized = _normalizeRuleMap(raw, sourceUrl);
    final rule = RulePlugin.fromJson(normalized);
    if (rule.id.trim().isEmpty || rule.name.trim().isEmpty) return null;
    return rule.copyWith(
      id: rule.id.startsWith('custom:') ? rule.id : 'custom:${rule.id}',
      source:
          rule.source == RuleSourceKind.kazumi ||
              rule.source == RuleSourceKind.tvbox
          ? rule.source
          : RuleSourceKind.custom,
      installedByDefault: false,
    );
  }

  Map<String, dynamic> _normalizeRuleMap(
    Map<String, dynamic> raw,
    String sourceUrl,
  ) {
    final name =
        raw['name']?.toString() ??
        raw['title']?.toString() ??
        raw['key']?.toString() ??
        '用户规则';
    final baseUrl =
        raw['baseUrl']?.toString() ??
        raw['url']?.toString() ??
        raw['主页url']?.toString() ??
        '';
    final searchUrl =
        raw['searchUrl']?.toString() ??
        raw['搜索url']?.toString() ??
        raw['search']?.toString() ??
        '';
    final id =
        raw['id']?.toString() ??
        raw['key']?.toString() ??
        'user:${_hash('$sourceUrl:$name:$baseUrl:$searchUrl')}';
    final engine = raw['engine']?.toString() ?? raw['type']?.toString() ?? '';
    final isXbpq =
        engine.toLowerCase().contains('xbpq') ||
        raw.containsKey('playArray') ||
        raw.containsKey('播放数组');
    final isKazumi =
        engine.toLowerCase().contains('native') ||
        engine.toLowerCase().contains('kazumi') ||
        raw.containsKey('chapterRoads');
    return {
      ...raw,
      'id': id,
      'name': name,
      'version': raw['version'] ?? '1.0',
      'source':
          raw['source'] ??
          (isXbpq
              ? 'tvbox'
              : isKazumi
              ? 'kazumi'
              : 'custom'),
      'contentType':
          raw['contentType'] ??
          raw['category'] ??
          _contentTypeFromText('$name ${raw['tags']}'),
      'engine': raw['engine'] ?? (isXbpq ? 'XBPQ' : 'native'),
      'updatedAt': raw['updatedAt'] ?? DateTime.now().toIso8601String(),
      'qualityScore': raw['qualityScore'] ?? 60,
      'tags': raw['tags'] is List ? raw['tags'] : ['用户导入'],
      'baseUrl': baseUrl,
      'searchUrl': searchUrl,
      'searchable': raw['searchable'] ?? true,
      'quickSearch': raw['quickSearch'] ?? true,
      'filterable': raw['filterable'] ?? false,
      'kazumi': raw['kazumi'] ?? (isKazumi ? _kazumiFromFlat(raw) : null),
      'xbpq': raw['xbpq'] ?? (isXbpq ? _xbpqFromFlat(raw) : null),
      'note': raw['note'] ?? raw['description'] ?? '从用户规则仓库导入。',
    };
  }

  Map<String, dynamic> _kazumiFromFlat(Map<String, dynamic> raw) {
    return {
      'searchList': raw['searchList'],
      'searchName': raw['searchName'],
      'searchResult': raw['searchResult'],
      'chapterRoads': raw['chapterRoads'],
      'chapterResult': raw['chapterResult'],
      'referer': raw['referer'],
      'userAgent': raw['userAgent'],
    };
  }

  Map<String, dynamic> _xbpqFromFlat(Map<String, dynamic> raw) {
    return {
      'searchArray': raw['searchArray'] ?? raw['搜索数组'],
      'searchTitle': raw['searchTitle'] ?? raw['搜索标题'],
      'searchLink': raw['searchLink'] ?? raw['搜索链接'],
      'playArray': raw['playArray'] ?? raw['播放数组'],
      'playList': raw['playList'] ?? raw['播放列表'],
      'playTitle': raw['playTitle'] ?? raw['播放标题'],
      'playLink': raw['playLink'] ?? raw['播放链接'],
      'lineArray': raw['lineArray'] ?? raw['线路数组'],
      'lineTitle': raw['lineTitle'] ?? raw['线路标题'],
      'jumpPlayLink': raw['jumpPlayLink'] ?? raw['嗅探词'],
    };
  }

  bool _looksLikeSingleRule(Map<String, dynamic> map) {
    return map.containsKey('baseUrl') ||
        map.containsKey('searchUrl') ||
        map.containsKey('chapterRoads') ||
        map.containsKey('playArray') ||
        map.containsKey('主页url') ||
        map.containsKey('搜索url');
  }

  String _contentTypeFromText(String text) {
    final lower = text.toLowerCase();
    if (lower.contains('电影') || lower.contains('movie')) return 'movie';
    if (lower.contains('剧集') ||
        lower.contains('电视剧') ||
        lower.contains('series') ||
        lower.contains('tv')) {
      return 'series';
    }
    return 'anime';
  }
}

bool _boolFromAny(Object? value, {bool fallback = false}) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  final text = value?.toString().trim().toLowerCase();
  if (text == 'true' || text == '1' || text == 'yes') return true;
  if (text == 'false' || text == '0' || text == 'no') return false;
  return fallback;
}

String _hash(String value) {
  return sha1.convert(utf8.encode(value)).toString().substring(0, 12);
}

String _animekoBaseUrl(String searchUrl, String rawBaseUrl) {
  final raw = rawBaseUrl.trim();
  if (raw.isNotEmpty) return raw;
  final uri = Uri.tryParse(searchUrl);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return '';
  return uri.replace(path: '/', query: '', fragment: '').toString();
}
