import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../sources/source_catalog_models.dart';
import 'rule_importer.dart';
import 'rule_models.dart';

enum TvBoxXbpqHydrationStatus {
  hydrated,
  inlineExecutable,
  inlineIncomplete,
  rejectedReference,
  fetchFailed,
  invalidConfig,
}

class TvBoxXbpqSiteHydration {
  const TvBoxXbpqSiteHydration({
    required this.siteKey,
    required this.siteName,
    required this.status,
    required this.rules,
    required this.executableRules,
    required this.message,
    this.resolvedUrl,
  });

  final String siteKey;
  final String siteName;
  final TvBoxXbpqHydrationStatus status;
  final List<RulePlugin> rules;
  final List<RulePlugin> executableRules;
  final String message;
  final Uri? resolvedUrl;

  bool get hasExecutableRule => executableRules.isNotEmpty;
}

class TvBoxXbpqHydrationResult {
  const TvBoxXbpqHydrationResult({required this.sites});

  final List<TvBoxXbpqSiteHydration> sites;

  List<RulePlugin> get rules => [for (final site in sites) ...site.rules];

  List<RulePlugin> get executableRules => [
    for (final site in sites) ...site.executableRules,
  ];
}

class TvBoxXbpqHydrator {
  TvBoxXbpqHydrator({
    http.Client? client,
    RuleImporter importer = const RuleImporter(),
    this.timeout = const Duration(seconds: 8),
    this.maxFileBytes = 512 * 1024,
    this.maxSites = 16,
    this.successCacheTtl = const Duration(minutes: 30),
    this.failureCacheTtl = const Duration(minutes: 2),
    DateTime Function()? clock,
  }) : assert(maxFileBytes > 0),
       assert(maxSites >= 0),
       _client = client ?? http.Client(),
       _ownsClient = client == null,
       _importer = importer,
       _clock = clock ?? DateTime.now;

  final http.Client _client;
  final bool _ownsClient;
  final RuleImporter _importer;
  final DateTime Function() _clock;
  final Duration timeout;
  final int maxFileBytes;
  final int maxSites;
  final Duration successCacheTtl;
  final Duration failureCacheTtl;
  final Map<String, _CachedFetch> _cache = {};
  final Map<String, Future<_JsonFetch>> _inFlight = {};

  Future<TvBoxXbpqHydrationResult> hydrateSource(VideoSource source) async {
    if (source.kind != VideoSourceKind.tvBox) {
      return const TvBoxXbpqHydrationResult(sites: []);
    }
    final rawSites = source.rawConfig['sites'];
    if (rawSites is! List) {
      return const TvBoxXbpqHydrationResult(sites: []);
    }

    final sites = rawSites
        .whereType<Map>()
        .map(_stringKeyedMap)
        .where(_isXbpqSite)
        .toList(growable: false);
    final results = <Future<TvBoxXbpqSiteHydration>>[];
    for (var index = 0; index < sites.length; index++) {
      final site = sites[index];
      results.add(
        index < maxSites
            ? _hydrateSiteSafely(source, site, index)
            : Future.value(
                _siteResult(
                  source,
                  site,
                  index,
                  status: TvBoxXbpqHydrationStatus.rejectedReference,
                  message: 'XBPQ 站点数量超过 $maxSites 条安全上限，未继续拉取。',
                ),
              ),
      );
    }
    return TvBoxXbpqHydrationResult(sites: await Future.wait(results));
  }

  void clearCache() {
    _cache.clear();
    _inFlight.clear();
  }

  void close() {
    if (_ownsClient) _client.close();
  }

  Future<TvBoxXbpqSiteHydration> _hydrateSiteSafely(
    VideoSource source,
    Map<String, dynamic> site,
    int index,
  ) async {
    try {
      return await _hydrateSite(source, site, index);
    } catch (_) {
      return _siteResult(
        source,
        site,
        index,
        status: TvBoxXbpqHydrationStatus.rejectedReference,
        message: 'XBPQ 站点配置包含无法解析的 URL 或字段，已隔离跳过。',
      );
    }
  }

  Future<TvBoxXbpqSiteHydration> _hydrateSite(
    VideoSource source,
    Map<String, dynamic> site,
    int index,
  ) async {
    final ext = site['ext'];
    if (ext is Map) {
      final rules = _importSite(source, site);
      final executable = _safeExecutableRules(rules);
      if (_containsCodeReference(ext)) {
        return _siteResult(
          source,
          site,
          index,
          status: TvBoxXbpqHydrationStatus.rejectedReference,
          message: '内联 XBPQ 配置包含脚本、JAR 或其他可执行引用。',
          rules: rules,
        );
      }
      return _siteResult(
        source,
        site,
        index,
        status: executable.isEmpty
            ? TvBoxXbpqHydrationStatus.inlineIncomplete
            : TvBoxXbpqHydrationStatus.inlineExecutable,
        message: executable.isEmpty
            ? '内联 XBPQ 配置字段不完整或指向不安全地址，保留安装但不进入播放链。'
            : '内联 XBPQ 配置字段完整，可直接执行。',
        rules: rules,
        executableRules: executable,
      );
    }

    final reference = ext?.toString().trim() ?? '';
    final catalogUrl = source.importUrl.trim().isEmpty
        ? source.baseUrl
        : source.importUrl;
    final resolved = _resolveReference(catalogUrl, reference);
    if (!resolved.isAllowed) {
      return _siteResult(
        source,
        site,
        index,
        status: TvBoxXbpqHydrationStatus.rejectedReference,
        message: resolved.message,
      );
    }

    final fetch = await _fetchJson(resolved.uri!);
    if (!fetch.isSuccess) {
      return _siteResult(
        source,
        site,
        index,
        status: TvBoxXbpqHydrationStatus.fetchFailed,
        message: fetch.message,
        resolvedUrl: resolved.uri,
      );
    }

    final hydratedSite = <String, dynamic>{...site, 'ext': fetch.value};
    final hydratedRules = _importSite(source, hydratedSite);
    final executable = _safeExecutableRules(hydratedRules);
    if (executable.isEmpty) {
      return _siteResult(
        source,
        site,
        index,
        status: TvBoxXbpqHydrationStatus.invalidConfig,
        message: '远程 JSON 字段不完整或指向不安全地址，已拒绝接入播放链。',
        resolvedUrl: resolved.uri,
      );
    }
    return _siteResult(
      source,
      hydratedSite,
      index,
      status: TvBoxXbpqHydrationStatus.hydrated,
      message: '已安全展开同源 XBPQ JSON 配置。',
      rules: hydratedRules,
      executableRules: executable,
      resolvedUrl: resolved.uri,
    );
  }

  TvBoxXbpqSiteHydration _siteResult(
    VideoSource source,
    Map<String, dynamic> site,
    int index, {
    required TvBoxXbpqHydrationStatus status,
    required String message,
    List<RulePlugin>? rules,
    List<RulePlugin> executableRules = const [],
    Uri? resolvedUrl,
  }) {
    return TvBoxXbpqSiteHydration(
      siteKey: _siteKey(site, index),
      siteName: _siteName(site, index),
      status: status,
      rules: rules ?? _importSite(source, site),
      executableRules: executableRules,
      message: message,
      resolvedUrl: resolvedUrl,
    );
  }

  List<RulePlugin> _importSite(VideoSource source, Map<String, dynamic> site) {
    try {
      final bundle = _importer.importFromText(
        jsonEncode({
          'name': source.displayName,
          'sites': [site],
        }),
        sourceUrl: source.importUrl,
      );
      return bundle.rules
          .where((rule) => rule.engine.toLowerCase() == 'xbpq')
          .map(
            (rule) => rule.copyWith(
              id: 'catalog:${source.id}:${rule.id}',
              groupId: 'catalog:${source.id}',
              requestHeaders: {...source.headers, ...rule.requestHeaders},
              note: '由自动规则包“${source.displayName}”安全展开 XBPQ JSON 后接入。',
            ),
          )
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  List<RulePlugin> _safeExecutableRules(List<RulePlugin> rules) {
    return rules
        .where(
          (rule) =>
              rule.canResolveNatively &&
              !_containsCodeReference(rule.rawConfig) &&
              _isSafeHttpUri(Uri.tryParse(rule.baseUrl)) &&
              _isSafeHttpUri(Uri.tryParse(rule.searchUrl)),
        )
        .toList(growable: false);
  }

  _ResolvedReference _resolveReference(String sourceUrl, String reference) {
    final base = Uri.tryParse(sourceUrl.trim());
    if (!_isSafeHttpUri(base)) {
      return const _ResolvedReference.rejected(
        'TVBox 配置地址不是安全的公网 HTTP/HTTPS URL。',
      );
    }
    if (reference.isEmpty) {
      return const _ResolvedReference.rejected('XBPQ ext 为空，无法展开配置。');
    }
    if (reference.contains('\\')) {
      return const _ResolvedReference.rejected('XBPQ ext 必须使用标准 URL 路径。');
    }
    if (RegExp(r'%(?![0-9a-fA-F]{2})').hasMatch(reference)) {
      return const _ResolvedReference.rejected('XBPQ ext 包含非法百分号转义。');
    }

    final relative = Uri.tryParse(reference);
    if (relative == null ||
        relative.hasScheme ||
        relative.hasAuthority ||
        reference.startsWith('//')) {
      return const _ResolvedReference.rejected('只允许与 TVBox 配置同源的相对 JSON 地址。');
    }
    if (relative.fragment.isNotEmpty || _containsParentTraversal(relative)) {
      return const _ResolvedReference.rejected('XBPQ ext 包含不允许的路径跳转或片段。');
    }

    final resolved = base!.resolveUri(relative);
    if (!_sameOrigin(base, resolved)) {
      return const _ResolvedReference.rejected('XBPQ ext 解析后跨源，已拒绝拉取。');
    }
    if (!_isSafeHttpUri(resolved)) {
      return const _ResolvedReference.rejected('XBPQ ext 指向私网或不安全地址。');
    }
    if (!resolved.path.toLowerCase().endsWith('.json')) {
      return const _ResolvedReference.rejected('只允许加载 .json 配置，脚本和 JAR 不会执行。');
    }
    return _ResolvedReference.allowed(resolved);
  }

  Future<_JsonFetch> _fetchJson(Uri uri) {
    final key = uri.toString();
    final cached = _cache[key];
    if (cached != null) {
      if (cached.expiresAt.isAfter(_clock())) return Future.value(cached.value);
      _cache.remove(key);
    }
    final active = _inFlight[key];
    if (active != null) return active;

    final request = _fetchJsonUncached(uri).then((result) {
      _cache[key] = _CachedFetch(
        result,
        _clock().add(result.isSuccess ? successCacheTtl : failureCacheTtl),
      );
      return result;
    });
    _inFlight[key] = request;
    return request.whenComplete(() {
      if (identical(_inFlight[key], request)) _inFlight.remove(key);
    });
  }

  Future<_JsonFetch> _fetchJsonUncached(Uri uri) async {
    try {
      final request = http.Request('GET', uri)
        ..followRedirects = false
        ..maxRedirects = 0
        ..headers['Accept'] = 'application/json, text/plain;q=0.8';
      final response = await _client.send(request).timeout(timeout);
      final isRedirect =
          response.statusCode >= 300 && response.statusCode < 400;
      if (isRedirect ||
          response.statusCode < 200 ||
          response.statusCode >= 300) {
        return _JsonFetch.failure(
          isRedirect
              ? 'XBPQ JSON 返回重定向，出于同源安全限制未继续访问。'
              : 'XBPQ JSON 请求失败：HTTP ${response.statusCode}',
        );
      }
      if (!_isJsonContentType(response.headers['content-type'])) {
        return const _JsonFetch.failure('服务器返回的不是 JSON/TXT 配置。');
      }
      final declaredLength = int.tryParse(
        response.headers['content-length']?.trim() ?? '',
      );
      if (declaredLength != null && declaredLength > maxFileBytes) {
        return _JsonFetch.failure('XBPQ JSON 超过 $maxFileBytes 字节读取上限。');
      }

      final bytes = await _readBytes(response.stream).timeout(timeout);
      if (bytes.contains(0)) {
        return const _JsonFetch.failure('XBPQ 响应包含二进制内容，已拒绝。');
      }
      var body = bytes;
      if (body.length >= 3 &&
          body[0] == 0xef &&
          body[1] == 0xbb &&
          body[2] == 0xbf) {
        body = Uint8List.sublistView(body, 3);
      }
      final decoded = jsonDecode(utf8.decode(body, allowMalformed: false));
      if (decoded is! Map) {
        return const _JsonFetch.failure('XBPQ JSON 根节点必须是对象。');
      }
      final map = decoded.cast<String, dynamic>();
      if (_containsCodeReference(map)) {
        return const _JsonFetch.failure('XBPQ JSON 包含脚本、JAR 或其他可执行引用。');
      }
      return _JsonFetch.success(map);
    } on TimeoutException {
      return const _JsonFetch.failure('XBPQ JSON 请求超时。');
    } on _ResponseTooLarge {
      return _JsonFetch.failure('XBPQ JSON 超过 $maxFileBytes 字节读取上限。');
    } on FormatException {
      return const _JsonFetch.failure('XBPQ 响应不是有效的 UTF-8 JSON。');
    } catch (_) {
      return const _JsonFetch.failure('XBPQ JSON 暂时无法读取。');
    }
  }

  Future<Uint8List> _readBytes(Stream<List<int>> stream) async {
    final bytes = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk in stream) {
      total += chunk.length;
      if (total > maxFileBytes) {
        throw const _ResponseTooLarge();
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }
}

bool _isXbpqSite(Map<String, dynamic> site) =>
    site['api']?.toString().trim().toLowerCase() == 'csp_xbpq';

Map<String, dynamic> _stringKeyedMap(Map<dynamic, dynamic> source) => {
  for (final entry in source.entries) entry.key.toString(): entry.value,
};

String _siteKey(Map<String, dynamic> site, int index) {
  final value = site['key']?.toString().trim() ?? '';
  return value.isEmpty ? 'xbpq:$index' : value;
}

String _siteName(Map<String, dynamic> site, int index) {
  final value = site['name']?.toString().trim() ?? '';
  return value.isEmpty ? _siteKey(site, index) : value;
}

bool _sameOrigin(Uri first, Uri second) =>
    first.scheme.toLowerCase() == second.scheme.toLowerCase() &&
    first.host.toLowerCase() == second.host.toLowerCase() &&
    _effectivePort(first) == _effectivePort(second);

int _effectivePort(Uri uri) {
  if (uri.hasPort) return uri.port;
  return uri.scheme.toLowerCase() == 'https' ? 443 : 80;
}

bool _containsParentTraversal(Uri uri) {
  try {
    for (final segment in uri.pathSegments) {
      if (segment == '..' || segment.toLowerCase() == '%2e%2e') return true;
    }
  } catch (_) {
    return true;
  }
  return false;
}

bool _isSafeHttpUri(Uri? uri) {
  if (uri == null ||
      !const {'http', 'https'}.contains(uri.scheme.toLowerCase()) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return false;
  }
  return !_isPrivateHost(uri.host);
}

bool _isPrivateHost(String value) {
  final host = value
      .toLowerCase()
      .replaceAll(RegExp(r'^\[|\]$'), '')
      .replaceAll(RegExp(r'\.+$'), '');
  if (host == 'localhost' ||
      host.endsWith('.localhost') ||
      host.endsWith('.local') ||
      host.endsWith('.internal') ||
      host.endsWith('.lan') ||
      host.endsWith('.home')) {
    return true;
  }
  if (host.contains('%')) return true;
  if (host.contains(':')) {
    final bytes = _parseIpv6Bytes(host);
    return bytes == null || _isBlockedIpv6(bytes);
  }

  if (RegExp(r'^(?:0x[0-9a-f]+|\d+)$').hasMatch(host)) return true;

  final parts = host.split('.');
  final allNumeric = parts.every((part) => RegExp(r'^\d+$').hasMatch(part));
  final allNumericLike = parts.every(
    (part) => RegExp(r'^(?:\d+|0x[0-9a-f]+)$').hasMatch(part),
  );
  if (allNumericLike && !allNumeric) return true;
  if (allNumeric && parts.length != 4) return true;
  if (parts.length != 4 || !allNumeric) return false;
  if (parts.any((part) => part.length > 1 && part.startsWith('0'))) {
    return true;
  }
  final numbers = parts.map(int.tryParse).toList(growable: false);
  if (numbers.any((part) => part == null || part < 0 || part > 255)) {
    return true;
  }
  final first = numbers[0]!;
  final second = numbers[1]!;
  final third = numbers[2]!;
  return first == 0 ||
      first == 10 ||
      first == 127 ||
      first >= 224 ||
      (first == 100 && second >= 64 && second <= 127) ||
      (first == 169 && second == 254) ||
      (first == 172 && second >= 16 && second <= 31) ||
      (first == 192 && second == 168) ||
      (first == 192 && second == 0 && third == 0) ||
      (first == 192 && second == 0 && third == 2) ||
      (first == 198 && (second == 18 || second == 19)) ||
      (first == 198 && second == 51 && third == 100) ||
      (first == 203 && second == 0 && third == 113);
}

List<int>? _parseIpv6Bytes(String host) {
  var value = host.trim().toLowerCase();
  if (value.startsWith('[') && value.endsWith(']')) {
    value = value.substring(1, value.length - 1);
  }
  if (value.isEmpty || value.contains('%')) return null;
  final compressionIndex = value.indexOf('::');
  if (compressionIndex >= 0 && value.indexOf('::', compressionIndex + 2) >= 0) {
    return null;
  }

  final hasCompression = compressionIndex >= 0;
  final leftText = hasCompression
      ? value.substring(0, compressionIndex)
      : value;
  final rightText = hasCompression ? value.substring(compressionIndex + 2) : '';
  final left = _parseIpv6Groups(leftText);
  final right = _parseIpv6Groups(rightText);
  if (left == null || right == null) return null;

  final missing = 8 - left.length - right.length;
  if ((hasCompression && missing < 1) || (!hasCompression && missing != 0)) {
    return null;
  }
  final groups = <int>[
    ...left,
    if (hasCompression) ...List<int>.filled(missing, 0),
    ...right,
  ];
  if (groups.length != 8) return null;
  return [
    for (final group in groups) ...[(group >> 8) & 0xff, group & 0xff],
  ];
}

List<int>? _parseIpv6Groups(String text) {
  if (text.isEmpty) return const [];
  final tokens = text.split(':');
  final groups = <int>[];
  for (var index = 0; index < tokens.length; index++) {
    final token = tokens[index];
    if (token.isEmpty) return null;
    if (token.contains('.')) {
      if (index != tokens.length - 1) return null;
      final ipv4 = _parseIpv4Bytes(token);
      if (ipv4 == null) return null;
      groups
        ..add((ipv4[0] << 8) | ipv4[1])
        ..add((ipv4[2] << 8) | ipv4[3]);
      continue;
    }
    if (token.length > 4 || !RegExp(r'^[0-9a-f]+$').hasMatch(token)) {
      return null;
    }
    final parsed = int.tryParse(token, radix: 16);
    if (parsed == null || parsed < 0 || parsed > 0xffff) return null;
    groups.add(parsed);
  }
  return groups;
}

List<int>? _parseIpv4Bytes(String host) {
  final parts = host.split('.');
  if (parts.length != 4) return null;
  final values = <int>[];
  for (final part in parts) {
    if (!RegExp(r'^\d{1,3}$').hasMatch(part)) return null;
    final parsed = int.tryParse(part);
    if (parsed == null || parsed < 0 || parsed > 255) return null;
    values.add(parsed);
  }
  return values;
}

bool _isBlockedIpv6(List<int> bytes) {
  if (bytes.length != 16 || bytes.every((value) => value == 0)) return true;
  final isLoopback =
      bytes.take(15).every((value) => value == 0) && bytes[15] == 1;
  if (isLoopback) return true;
  if ((bytes[0] & 0xfe) == 0xfc) return true;
  if (bytes[0] == 0xfe && (bytes[1] & 0xc0) >= 0x80) return true;
  if (bytes[0] == 0xff) return true;
  if (bytes.take(12).every((value) => value == 0) ||
      (bytes.take(10).every((value) => value == 0) &&
          bytes[10] == 0xff &&
          bytes[11] == 0xff)) {
    return true;
  }
  return false;
}

bool _isJsonContentType(String? value) {
  final mime = value?.split(';').first.trim().toLowerCase() ?? '';
  return mime == 'application/json' ||
      mime == 'application/x-json' ||
      mime == 'text/json' ||
      mime == 'text/plain' ||
      mime.endsWith('+json');
}

bool _containsCodeReference(Object? value, [String key = '']) {
  final normalizedKey = key.trim().toLowerCase();
  if (const {
    'spider',
    'jar',
    'jars',
    'script',
    'scripts',
    'javascript',
  }.contains(normalizedKey)) {
    return true;
  }
  if (value is Map) {
    return value.entries.any(
      (entry) => _containsCodeReference(entry.value, entry.key.toString()),
    );
  }
  if (value is Iterable) {
    return value.any((item) => _containsCodeReference(item, normalizedKey));
  }
  if (value is! String) return false;
  final candidate = value.split(';').first.trim();
  final uri = Uri.tryParse(candidate);
  final path = (uri?.path ?? candidate).toLowerCase();
  return RegExp(r'\.(?:js|jar|py|apk|zip)$').hasMatch(path);
}

class _ResolvedReference {
  const _ResolvedReference.allowed(this.uri) : isAllowed = true, message = '';

  const _ResolvedReference.rejected(this.message)
    : isAllowed = false,
      uri = null;

  final bool isAllowed;
  final Uri? uri;
  final String message;
}

class _JsonFetch {
  const _JsonFetch.success(this.value) : message = '';

  const _JsonFetch.failure(this.message) : value = null;

  final Map<String, dynamic>? value;
  final String message;

  bool get isSuccess => value != null;
}

class _CachedFetch {
  const _CachedFetch(this.value, this.expiresAt);

  final _JsonFetch value;
  final DateTime expiresAt;
}

class _ResponseTooLarge implements Exception {
  const _ResponseTooLarge();
}
