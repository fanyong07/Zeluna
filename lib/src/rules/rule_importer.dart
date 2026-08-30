import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../core/identity/stable_identity.dart';
import '../core/network/network_http_client.dart';
import '../core/network/network_security.dart';
import 'csp_rule_support.dart';
import 'rule_models.dart';

class RuleImporter {
  const RuleImporter({
    http.Client? client,
    this.timeout = const Duration(seconds: 12),
    this.maxFileBytes = 5 * 1024 * 1024,
  }) : _client = client;

  final http.Client? _client;
  final Duration timeout;
  final int maxFileBytes;

  static String kazumiRuleId(String name) {
    final normalized = name.trim().toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9_-]+'),
      '-',
    );
    final key = normalized.replaceAll(RegExp(r'^-+|-+$'), '');
    return 'kazumi:${key.isEmpty ? _hash(name.trim()) : key}';
  }

  Future<RuleImportBundle> importFromUrl(String url) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null ||
        !const {'http', 'https'}.contains(uri.scheme.toLowerCase()) ||
        uri.host.isEmpty) {
      throw const FormatException('请输入完整的 http/https JSON 文件地址。');
    }
    if (_isGitHubHtmlPage(uri)) {
      throw const FormatException(
        'GitHub 仓库首页或代码页面不是规则文件。请使用 raw JSON 地址，或下载 JSON 后从本地/剪贴板导入。',
      );
    }
    final policy = NetworkRequestPolicy(
      service: NetworkServiceKind.rulePage,
      httpsOnly: false,
      allowPrivateNetwork: false,
      maxResponseBytes: maxFileBytes,
      requestTimeout: timeout,
    );
    policy.ensureUriAllowed(uri);
    final ownedClient = _client == null;
    final client = _client ?? createNetworkHttpClient(policy);
    try {
      final request = http.Request('GET', uri)
        ..headers['Accept'] = 'application/json, text/plain;q=0.9';
      final response = await client.send(request).timeout(timeout);
      if (response.statusCode >= 300 && response.statusCode < 400) {
        final location = response.headers['location']?.trim() ?? '';
        if (location.isNotEmpty) {
          policy.ensureUriAllowed(uri.resolve(location));
        }
        final subscription = response.stream.listen(null);
        await subscription.cancel();
        throw const FormatException('规则导入地址发生重定向，已停止访问。');
      }
      if (response.statusCode < 200 || response.statusCode >= 400) {
        throw FormatException('仓库请求失败：HTTP ${response.statusCode}');
      }
      _validateRuleResponseType(response.headers['content-type']);
      final declaredLength = int.tryParse(
        response.headers['content-length']?.trim() ?? '',
      );
      if (declaredLength != null && declaredLength > maxFileBytes) {
        throw FormatException(
          '规则文件超过 ${_byteSizeLabel(maxFileBytes)} 读取上限，已停止下载。',
        );
      }
      final text = await _readRuleResponseText(
        response.stream,
        maxFileBytes,
      ).timeout(timeout);
      return importFromText(text, sourceUrl: uri.toString());
    } on NetworkSecurityException catch (error) {
      throw FormatException(error.message);
    } finally {
      if (ownedClient) client.close();
    }
  }

  RuleImportBundle importFromText(String text, {String sourceUrl = ''}) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) throw const FormatException('导入内容为空。');
    final decoded = _decodeRuleJson(trimmed);
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
    if (map['sites'] is List) return _parseTvBoxSites(map, sourceUrl);
    for (final key in const ['rules', 'plugins', 'items', 'data']) {
      final value = map[key];
      if (value is List) return _parseRuleList(value, sourceUrl);
    }
    final repositoryLinks = _parseRepositoryLinks(map, sourceUrl);
    if (repositoryLinks.isNotEmpty) return repositoryLinks;
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
    final version = source['version']?.toString() ?? '1.0';
    final description = args['description']?.toString() ?? '';
    final tier = _intFromAny(args['tier'], fallback: index);
    final groupId = _importGroupId(sourceUrl, factoryId);
    final engine = switch (factoryId) {
      'web-selector' => 'animeko-web-selector',
      'rss' => 'animeko-rss',
      _ => 'animeko-$factoryId',
    };
    final id = stableRuleKey(
      ruleId: 'animeko:$factoryId:${name.toLowerCase()}',
      engine: engine,
      sourceRepository: baseUrl,
      contentHash: stableDigest('$version|$searchUrl'),
    );
    final legacySeed = '$sourceUrl:$factoryId:$name:$searchUrl:$index';

    if (factoryId == 'web-selector') {
      return RulePlugin(
        id: id,
        name: name,
        version: version,
        source: RuleSourceKind.custom,
        contentType: RuleContentType.anime,
        engine: engine,
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
        groupId: groupId,
        priority: tier,
        legacyIds: ['custom:animeko:${_hash(legacySeed)}'],
        note: description.trim().isEmpty
            ? '从 Animeko web-selector 源导入，可直接尝试解析在线播放地址。'
            : description,
      );
    }

    if (factoryId == 'rss') {
      return RulePlugin(
        id: id,
        name: name,
        version: version,
        source: RuleSourceKind.custom,
        contentType: RuleContentType.anime,
        engine: engine,
        updatedAt: DateTime.now(),
        qualityScore: 50,
        tags: const ['Animeko', 'RSS', 'BT'],
        baseUrl: baseUrl,
        searchUrl: searchUrl,
        searchable: searchUrl.trim().isNotEmpty,
        quickSearch: true,
        filterable: false,
        installedByDefault: false,
        groupId: groupId,
        priority: tier,
        legacyIds: ['custom:animeko-rss:${_hash(legacySeed)}'],
        unsupportedReason:
            '这是 BT/RSS 资源订阅，不是 mp4/m3u8 在线播放源；当前播放器没有下载或 BT 边下边播能力，所以不能直接启用播放。',
        note: description.trim().isEmpty
            ? '从 Animeko RSS/BT 源导入，仅作为资源信息保留。'
            : description,
      );
    }

    return RulePlugin(
      id: id,
      name: name,
      version: version,
      source: RuleSourceKind.custom,
      contentType: RuleContentType.anime,
      engine: engine,
      updatedAt: DateTime.now(),
      qualityScore: 40,
      tags: const ['Animeko', '暂不支持'],
      baseUrl: baseUrl,
      searchUrl: searchUrl,
      searchable: searchUrl.trim().isNotEmpty,
      quickSearch: false,
      filterable: false,
      installedByDefault: false,
      groupId: groupId,
      priority: tier,
      legacyIds: ['custom:animeko-unsupported:${_hash(legacySeed)}'],
      unsupportedReason: '这类来源暂时不支持。',
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
    final subjectJsonPathIndexed =
        searchConfig['selectorSubjectFormatJsonPathIndexed'] is Map
        ? (searchConfig['selectorSubjectFormatJsonPathIndexed'] as Map)
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
      subjectJsonPathIndexed: AnimekoSubjectJsonPathIndexedConfig.fromJson(
        subjectJsonPathIndexed,
      ),
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
      final ext = map['ext'];
      final extMap = ext is Map
          ? ext.cast<String, dynamic>()
          : <String, dynamic>{};
      final isJsonApi =
          type?.toString() == '1' &&
          (api.startsWith('http://') || api.startsWith('https://'));
      final isXmlApi =
          type?.toString() == '0' &&
          (api.startsWith('http://') || api.startsWith('https://'));
      final isXbpq = api.toLowerCase().contains('xbpq');
      final isDrpy =
          type?.toString() == '3' &&
          RegExp(r'drpy2(?:\.min)?\.js', caseSensitive: false).hasMatch(api);
      final drpyRuntimeUrl = isDrpy
          ? _normalizeDrpyUrl(_resolveImportReference(api, sourceUrl))
          : '';
      final drpyInlineSource = isDrpy ? _drpyInlineSource(ext) : '';
      final drpyExtUrl = isDrpy && drpyInlineSource.isEmpty
          ? _normalizeDrpyUrl(
              _resolveImportReference(ext?.toString() ?? '', sourceUrl),
            )
          : '';
      final isAndroidCsp = type?.toString() == '3' && isAndroidCspApi(api);
      final engine = isJsonApi
          ? 'tvbox-json-api'
          : isXmlApi
          ? 'tvbox-xml-api'
          : isXbpq
          ? 'XBPQ'
          : isDrpy
          ? 'drpy-js'
          : isAndroidCsp
          ? 'android-csp'
          : api.trim().isNotEmpty
          ? api.trim()
          : 'tvbox-${type ?? 'site'}';
      final contentTypes = _tvBoxContentTypes(
        map,
        supportsDirectLookup: isJsonApi || isXmlApi || isDrpy || isAndroidCsp,
      );
      final rawConfig = <String, dynamic>{
        'site': map,
        if (isDrpy) ...{
          'sourceUrl': sourceUrl,
          'runtimeUrl': drpyRuntimeUrl,
          'extUrl': drpyExtUrl,
          if (drpyInlineSource.isNotEmpty) 'inlineSource': drpyInlineSource,
          'originalRuntime': api,
          'originalExt': ext,
        },
        if (isAndroidCsp) 'sourceUrl': sourceUrl,
        if (root.containsKey('spider')) 'spider': root['spider'],
        if (root.containsKey('jar')) 'jar': root['jar'],
        if (root.containsKey('jars')) 'jars': root['jars'],
        if (root.containsKey('parses')) 'parses': root['parses'],
        if (root.containsKey('flags')) 'flags': root['flags'],
      };
      final cspMd5 = isAndroidCsp ? androidCspSpiderMd5(rawConfig) : null;
      final cspUnsupportedReason = isAndroidCsp
          ? androidCspUnsupportedReason(rawConfig, fallbackApi: api)
          : null;
      final baseId =
          'custom:tvbox:${_hash('$sourceUrl:${map['key'] ?? map['name'] ?? api}')}';
      for (var index = 0; index < contentTypes.length; index++) {
        final contentType = contentTypes[index];
        final merged = <String, dynamic>{
          ...extMap,
          'id': index == 0 ? baseId : '$baseId:$contentType',
          'name': map['name'] ?? map['key'] ?? 'TVBox 规则',
          'source': 'tvbox',
          'engine': engine,
          'contentType': contentType,
          'baseUrl': isJsonApi || isXmlApi || isAndroidCsp
              ? isAndroidCsp && cspMd5 != null
                    ? androidCspPinnedBase(cspMd5)
                    : api
              : extMap['主页url'] ?? extMap['baseUrl'] ?? '',
          'searchUrl': isJsonApi || isXmlApi
              ? api
              : extMap['搜索url'] ?? extMap['searchUrl'] ?? '',
          'searchable': searchable,
          'quickSearch': !isXmlApi,
          'filterable': false,
          'priority': isXmlApi ? 180 : 100,
          'groupId': _importGroupId(sourceUrl, 'tvbox'),
          'requestHeaders': {
            ..._requestHeadersFromRaw(map),
            ..._requestHeadersFromRaw(extMap),
          },
          'tags': [
            'TVBox',
            if (isJsonApi) 'JSON API',
            if (isXmlApi) 'XML API',
            if (isXbpq) 'XBPQ',
            if (isDrpy) 'drpy2',
            if (isAndroidCsp) 'Android CSP',
          ],
          'rawConfig': rawConfig,
          'unsupportedReason': ?cspUnsupportedReason,
          'note': sourceUrl.isEmpty ? '从 TVBox 配置导入。' : '从 $sourceUrl 导入。',
        };
        final rule = _ruleFromMap(merged, sourceUrl);
        if (rule != null) rules.add(rule);
      }
    }
    if (rules.isEmpty &&
        (root.containsKey('spider') ||
            root.containsKey('jar') ||
            root.containsKey('jars') ||
            root.containsKey('parses'))) {
      final rule = _ruleFromMap({
        'id': 'custom:tvbox-root:${_hash('$sourceUrl:${jsonEncode(root)}')}',
        'name': root['name'] ?? root['title'] ?? 'TVBox 仓库配置',
        'source': 'tvbox',
        'contentType': 'anime',
        'engine': 'tvbox-spider',
        'baseUrl': '',
        'searchUrl': '',
        'searchable': false,
        'quickSearch': false,
        'filterable': false,
        'rawConfig': root,
        'note': sourceUrl.isEmpty ? '从 TVBox 配置导入。' : '从 $sourceUrl 导入。',
      }, sourceUrl);
      if (rule != null) rules.add(rule);
    }
    return rules;
  }

  List<RulePlugin> _parseRepositoryLinks(
    Map<String, dynamic> root,
    String sourceUrl,
  ) {
    const keys = [
      'urls',
      'warehouses',
      'stores',
      'repositories',
      'storeHouse',
      'docks',
      'repos',
    ];
    final rules = <RulePlugin>[];
    for (final key in keys) {
      final value = root[key];
      if (value is! List) continue;
      for (var index = 0; index < value.length; index++) {
        final item = value[index];
        final map = item is Map
            ? item.cast<String, dynamic>()
            : <String, dynamic>{'url': item.toString()};
        final url =
            map['url']?.toString() ??
            map['api']?.toString() ??
            map['address']?.toString() ??
            '';
        final name =
            map['name']?.toString() ??
            map['title']?.toString() ??
            '仓库入口 ${index + 1}';
        final rule = _ruleFromMap({
          ...map,
          'id': 'custom:repository:${_hash('$sourceUrl:$key:$name:$url')}',
          'name': name,
          'engine': 'repository-link',
          'baseUrl': url,
          'searchUrl': '',
          'searchable': false,
          'quickSearch': false,
          'filterable': false,
          'rawConfig': map,
          'note': '从聚合仓库配置导入。',
        }, sourceUrl);
        if (rule != null) rules.add(rule);
      }
    }
    return rules;
  }

  RulePlugin? _ruleFromMap(Map<String, dynamic> raw, String sourceUrl) {
    final normalized = _normalizeRuleMap(raw, sourceUrl);
    final rule = RulePlugin.fromJson(normalized);
    if (rule.id.trim().isEmpty || rule.name.trim().isEmpty) return null;
    final preservesNativeId =
        rule.source == RuleSourceKind.kazumi && rule.id.startsWith('kazumi:');
    return rule.copyWith(
      id: rule.id.startsWith('custom:') || preservesNativeId
          ? rule.id
          : 'custom:${rule.id}',
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
        raw['baseURL']?.toString() ??
        raw['url']?.toString() ??
        raw['主页url']?.toString() ??
        '';
    final searchUrl =
        raw['searchUrl']?.toString() ??
        raw['searchURL']?.toString() ??
        raw['搜索url']?.toString() ??
        raw['search']?.toString() ??
        '';
    final explicitEngine = raw['engine']?.toString() ?? '';
    final fallbackEngine = raw['type']?.toString() ?? '';
    final engine = explicitEngine.isNotEmpty ? explicitEngine : fallbackEngine;
    final isXbpq =
        engine.toLowerCase().contains('xbpq') ||
        raw.containsKey('playArray') ||
        raw.containsKey('播放数组');
    final isKazumi =
        raw['source']?.toString().toLowerCase().contains('kazumi') == true ||
        engine.toLowerCase().contains('native') ||
        engine.toLowerCase().contains('kazumi') ||
        raw.containsKey('chapterRoads') ||
        raw.containsKey('baseURL') ||
        raw.containsKey('searchMode') ||
        raw.containsKey('chapterMode');
    final id =
        raw['id']?.toString() ??
        raw['key']?.toString() ??
        (isKazumi
            ? kazumiRuleId(name)
            : 'user:${_hash('$sourceUrl:$name:$baseUrl:$searchUrl')}');
    final contentType =
        raw['contentType'] ??
        raw['category'] ??
        (isKazumi ? raw['type'] : null) ??
        _contentTypeFromText('$name ${raw['tags']}');
    final searchable =
        raw['searchable'] ??
        (isKazumi
            ? searchUrl.trim().isNotEmpty ||
                  raw['searchMode']?.toString().toLowerCase() == 'api'
            : true);
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
      'contentType': contentType,
      'engine': raw['engine'] ?? (isXbpq ? 'XBPQ' : 'native'),
      'updatedAt':
          raw['updatedAt'] ??
          raw['lastUpdate'] ??
          DateTime.now().toIso8601String(),
      'qualityScore': raw['qualityScore'] ?? 60,
      'tags': raw['tags'] is List
          ? raw['tags']
          : [if (isKazumi) '番剧' else '用户导入'],
      'baseUrl': baseUrl,
      'searchUrl': searchUrl,
      'searchable': searchable,
      'quickSearch': raw['quickSearch'] ?? true,
      'filterable': raw['filterable'] ?? false,
      'requiresWebView':
          raw['requiresWebView'] ??
          raw['useWebView'] ??
          raw['useWebview'] ??
          false,
      'kazumi': raw['kazumi'] ?? (isKazumi ? _kazumiFromFlat(raw) : null),
      'xbpq': raw['xbpq'] ?? (isXbpq ? _xbpqFromFlat(raw) : null),
      'requestHeaders': raw['requestHeaders'] ?? _requestHeadersFromRaw(raw),
      'rawConfig': raw['rawConfig'] ?? raw,
      'groupId': raw['groupId'] ?? (isKazumi ? 'repo:kazumi-rules' : ''),
      'note': raw['note'] ?? raw['description'] ?? '从用户规则仓库导入。',
    };
  }

  Map<String, String> _requestHeadersFromRaw(Map<String, dynamic> raw) {
    final result = <String, String>{};
    for (final key in const ['headers', 'header', '请求头']) {
      final value = raw[key];
      if (value is! Map) continue;
      for (final entry in value.entries) {
        final name = entry.key.toString().trim();
        final headerValue = entry.value?.toString().trim() ?? '';
        if (name.isNotEmpty && headerValue.isNotEmpty) {
          result[name] = headerValue;
        }
      }
    }
    final cookie = raw['cookie'] ?? raw['cookies'];
    if (cookie != null && cookie.toString().trim().isNotEmpty) {
      result['Cookie'] = cookie.toString().trim();
    }
    final authorization = raw['authorization'] ?? raw['Authorization'];
    if (authorization != null && authorization.toString().trim().isNotEmpty) {
      result['Authorization'] = authorization.toString().trim();
    }
    return result;
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
      'apiLevel': raw['apiLevel'] ?? raw['api'],
      'multipleSources': raw['multipleSources'] ?? raw['muliSources'],
      'useWebView': raw['useWebView'] ?? raw['useWebview'],
      'useNativePlayer': raw['useNativePlayer'],
      'usePost': raw['usePost'],
      'useLegacyParser': raw['useLegacyParser'],
      'adBlocker': raw['adBlocker'],
      'searchMode': raw['searchMode'],
      'chapterMode': raw['chapterMode'],
      'searchApiConfig': raw['searchApiConfig'],
      'chapterApiConfig': raw['chapterApiConfig'],
      'antiCrawlerConfig': raw['antiCrawlerConfig'],
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
        map.containsKey('baseURL') ||
        map.containsKey('searchUrl') ||
        map.containsKey('searchURL') ||
        map.containsKey('chapterRoads') ||
        map.containsKey('searchApiConfig') ||
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

  List<String> _tvBoxContentTypes(
    Map<String, dynamic> site, {
    required bool supportsDirectLookup,
  }) {
    final categories = site['categories'];
    final text =
        [site['name'], site['group'], if (categories is List) ...categories]
            .whereType<Object>()
            .map((item) => item.toString())
            .join(' ')
            .toLowerCase();
    final types = <String>[];
    if (RegExp(r'番剧|动漫|动画|anime').hasMatch(text)) types.add('anime');
    if (RegExp(
      r'电视剧|连续剧|国产剧|大陆剧|港剧|台剧|韩剧|日剧|泰剧|欧美剧|剧集|series',
    ).hasMatch(text)) {
      types.add('series');
    }
    if (RegExp(r'电影|影片|影院|movie|动作片|喜剧片|爱情片|科幻片|剧情片|恐怖片|纪录片').hasMatch(text)) {
      types.add('movie');
    }
    if (types.isNotEmpty) return types;
    if (supportsDirectLookup) return const ['anime', 'series', 'movie'];
    return [_contentTypeFromText(text)];
  }
}

Object? _decodeRuleJson(String text) {
  try {
    return jsonDecode(text);
  } on FormatException {
    return jsonDecode(_sanitizeTvBoxJson(text));
  }
}

String _sanitizeTvBoxJson(String text) {
  final output = StringBuffer();
  var inString = false;
  var escaped = false;
  var index = text.startsWith('\uFEFF') ? 1 : 0;

  while (index < text.length) {
    final char = text[index];
    if (inString) {
      if (escaped) {
        output.write(char);
        escaped = false;
      } else if (char == r'\') {
        output.write(char);
        escaped = true;
      } else if (char == '"') {
        output.write(char);
        inString = false;
      } else if (char.codeUnitAt(0) < 0x20) {
        output.write(
          '\\u${char.codeUnitAt(0).toRadixString(16).padLeft(4, '0')}',
        );
      } else {
        output.write(char);
      }
      index++;
      continue;
    }
    if (char == '"') {
      output.write(char);
      inString = true;
      index++;
      continue;
    }
    if (char == '/' && index + 1 < text.length) {
      final next = text[index + 1];
      if (next == '/') {
        index += 2;
        while (index < text.length &&
            text[index] != '\n' &&
            text[index] != '\r') {
          index++;
        }
        continue;
      }
      if (next == '*') {
        index += 2;
        while (index + 1 < text.length &&
            !(text[index] == '*' && text[index + 1] == '/')) {
          if (text[index] == '\n' || text[index] == '\r') {
            output.write(text[index]);
          }
          index++;
        }
        index = index + 1 < text.length ? index + 2 : text.length;
        continue;
      }
    }
    if (char == ',') {
      var next = index + 1;
      while (next < text.length && text[next].trim().isEmpty) {
        next++;
      }
      if (next < text.length && (text[next] == '}' || text[next] == ']')) {
        index++;
        continue;
      }
    }
    output.write(char);
    index++;
  }
  return output.toString();
}

bool _isGitHubHtmlPage(Uri uri) {
  final host = uri.host.toLowerCase();
  if (host != 'github.com' && host != 'www.github.com') return false;
  final segments = uri.pathSegments.where((item) => item.isNotEmpty).toList();
  if (segments.length == 2) return true;
  return segments.length >= 3 && const {'blob', 'tree'}.contains(segments[2]);
}

void _validateRuleResponseType(String? contentType) {
  final mime = contentType?.split(';').first.trim().toLowerCase() ?? '';
  if (mime.isEmpty ||
      mime == 'application/json' ||
      mime == 'application/x-json' ||
      mime == 'text/json' ||
      mime == 'text/x-json' ||
      mime == 'text/plain' ||
      mime.endsWith('+json')) {
    return;
  }
  throw FormatException('服务器返回的内容类型“$mime”不是可解析的 JSON/TXT 规则。');
}

Future<String> _readRuleResponseText(
  Stream<List<int>> stream,
  int maxFileBytes,
) async {
  final bytes = BytesBuilder(copy: false);
  var totalBytes = 0;
  await for (final chunk in stream) {
    totalBytes += chunk.length;
    if (totalBytes > maxFileBytes) {
      throw FormatException(
        '规则文件超过 ${_byteSizeLabel(maxFileBytes)} 读取上限，已停止下载。',
      );
    }
    bytes.add(chunk);
  }

  var bodyBytes = bytes.takeBytes();
  if (bodyBytes.length >= 3 &&
      bodyBytes[0] == 0xef &&
      bodyBytes[1] == 0xbb &&
      bodyBytes[2] == 0xbf) {
    bodyBytes = Uint8List.sublistView(bodyBytes, 3);
  }
  if (bodyBytes.contains(0)) {
    throw const FormatException('服务器返回了二进制内容，不是可导入的 JSON/TXT 规则。');
  }
  try {
    return utf8.decode(bodyBytes, allowMalformed: false);
  } on FormatException {
    throw const FormatException('规则文件不是有效的 UTF-8 文本，无法解析。');
  }
}

String _byteSizeLabel(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes >= 1024 * 1024 && bytes % (1024 * 1024) == 0) {
    return '${bytes ~/ (1024 * 1024)} MB';
  }
  if (bytes % 1024 == 0) return '${bytes ~/ 1024} KB';
  return '${(bytes / 1024).toStringAsFixed(1)} KB';
}

bool _boolFromAny(Object? value, {bool fallback = false}) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  final text = value?.toString().trim().toLowerCase();
  if (text == 'true' || text == '1' || text == 'yes') return true;
  if (text == 'false' || text == '0' || text == 'no') return false;
  return fallback;
}

int _intFromAny(Object? value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.round();
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

String _hash(String value) {
  return sha1.convert(utf8.encode(value)).toString().substring(0, 12);
}

String _importGroupId(String sourceUrl, String factoryId) {
  final source = sourceUrl.trim();
  if (source.isNotEmpty) return 'repo:${_hash('$source:$factoryId')}';
  return 'clipboard:$factoryId';
}

String _resolveImportReference(String value, String sourceUrl) {
  final raw = value.trim();
  if (raw.isEmpty) return '';
  final uri = Uri.tryParse(raw);
  if (uri != null &&
      const {'http', 'https'}.contains(uri.scheme.toLowerCase()) &&
      uri.host.isNotEmpty) {
    return uri.toString();
  }
  final base = Uri.tryParse(sourceUrl.trim());
  if (base == null ||
      !const {'http', 'https'}.contains(base.scheme.toLowerCase()) ||
      base.host.isEmpty) {
    return raw;
  }
  return base.resolve(raw).toString();
}

String _normalizeDrpyUrl(String value) {
  final raw = value.trim();
  if (raw.isEmpty) return '';
  const proxyPrefix = 'https://gh-proxy.net/';
  if (raw.toLowerCase().startsWith(proxyPrefix)) {
    final target = raw.substring(proxyPrefix.length);
    final uri = Uri.tryParse(target);
    if (uri != null &&
        const {'http', 'https'}.contains(uri.scheme.toLowerCase()) &&
        uri.host.isNotEmpty) {
      return uri.toString();
    }
  }

  final uri = Uri.tryParse(raw);
  if (uri == null || uri.host.toLowerCase() != 'notabug.org') return raw;
  final segments = uri.pathSegments;
  if (segments.length < 5 ||
      segments[0].toLowerCase() != 'fantaiying' ||
      segments[1].toLowerCase() != 'ext' ||
      segments[2].toLowerCase() != 'raw' ||
      segments[3].toLowerCase() != 'main') {
    return raw;
  }
  return Uri(
    scheme: 'https',
    host: 'raw.githubusercontent.com',
    pathSegments: [
      'fantaiying7',
      'EXT',
      'refs',
      'heads',
      'main',
      ...segments.skip(4),
    ],
  ).toString();
}

String _drpyInlineSource(Object? ext) {
  if (ext is Map) {
    return 'var rule = ${jsonEncode(ext)};';
  }
  final text = ext?.toString().trim() ?? '';
  if (text.isEmpty) return '';
  if (RegExp(r'\b(?:var|let|const)\s+rule\s*=').hasMatch(text)) return text;
  if (text.startsWith('{') && text.endsWith('}')) {
    return 'var rule = $text;';
  }
  return '';
}

String _animekoBaseUrl(String searchUrl, String rawBaseUrl) {
  final raw = rawBaseUrl.trim();
  if (raw.isNotEmpty) return raw;
  final uri = Uri.tryParse(searchUrl);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return '';
  return uri.replace(path: '/', query: '', fragment: '').toString();
}
