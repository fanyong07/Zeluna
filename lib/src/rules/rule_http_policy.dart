import 'package:flutter/foundation.dart';

// HTTP routing and origin-bound credentials shared by page requests and media
// probes. No client, cache, cancellation or playback state lives here.

bool isRuleHttpRedirect(int statusCode) =>
    statusCode == 301 ||
    statusCode == 302 ||
    statusCode == 303 ||
    statusCode == 307 ||
    statusCode == 308;

Uri? ruleProxyUpstreamUri(Uri uri) {
  if (uri.path != '/media-proxy') return null;
  final rawTarget = uri.queryParameters['url'];
  final target = rawTarget == null ? null : Uri.tryParse(rawTarget);
  if (target == null ||
      !const {'http', 'https'}.contains(target.scheme.toLowerCase()) ||
      target.host.isEmpty) {
    return null;
  }
  return target;
}

String ruleRequestCacheKey(
  String method,
  Uri uri,
  Map<String, String> headers, {
  String body = '',
}) {
  final normalizedHeaders = headers.entries.toList(growable: false)
    ..sort(
      (left, right) =>
          left.key.toLowerCase().compareTo(right.key.toLowerCase()),
    );
  final headerKey = normalizedHeaders
      .map((entry) => '${entry.key.toLowerCase()}:${entry.value}')
      .join('\n');
  return '$method\n$uri\n$headerKey\n$body';
}

Uri ruleRequestUri(Uri target) {
  return _ruleRequestUriForPlatform(target, isWeb: kIsWeb, baseUri: Uri.base);
}

Uri _ruleRequestUriForPlatform(
  Uri target, {
  required bool isWeb,
  required Uri baseUri,
}) {
  if (!isWeb) return target;
  if (!const {'http', 'https'}.contains(baseUri.scheme.toLowerCase())) {
    return target;
  }
  final host = target.host.toLowerCase();
  if (host == 'localhost' || host == '127.0.0.1' || host == '::1') {
    return target;
  }
  return baseUri.resolve(
    '/media-proxy?url=${Uri.encodeQueryComponent(target.toString())}',
  );
}

Map<String, String> ruleRequestHeaders(
  Uri target,
  Map<String, String> headers,
) {
  return _ruleRequestHeadersForPlatform(
    target,
    headers,
    isWeb: kIsWeb,
    baseUri: Uri.base,
  );
}

Map<String, String> _ruleRequestHeadersForPlatform(
  Uri target,
  Map<String, String> headers, {
  required bool isWeb,
  required Uri baseUri,
}) {
  if (!isWeb) return headers;
  final requestUri = _ruleRequestUriForPlatform(
    target,
    isWeb: true,
    baseUri: baseUri,
  );
  final usesMediaProxy =
      requestUri.path == '/media-proxy' && requestUri.origin == baseUri.origin;
  if (!usesMediaProxy) return headers;
  const upstreamNames = <String, String>{
    'user-agent': 'X-Upstream-User-Agent',
    'referer': 'X-Upstream-Referer',
    'authorization': 'X-Upstream-Authorization',
    'cookie': 'X-Upstream-Cookie',
  };
  const blockedCredentialHeaders = {
    'x-appid',
    'x-timestamp',
    'x-signature',
    'x-upstream-x-appid',
    'x-upstream-x-timestamp',
    'x-upstream-x-signature',
  };
  final result = <String, String>{};
  for (final entry in headers.entries) {
    final normalizedName = entry.key.toLowerCase();
    if (blockedCredentialHeaders.contains(normalizedName)) continue;
    final upstreamName = upstreamNames[normalizedName];
    if (upstreamName != null && entry.value.trim().isNotEmpty) {
      result[upstreamName] = entry.value;
    } else {
      result[entry.key] = entry.value;
    }
  }
  return result;
}

@visibleForTesting
Uri ruleRequestUriForWebTest(Uri target, Uri baseUri) =>
    _ruleRequestUriForPlatform(target, isWeb: true, baseUri: baseUri);

@visibleForTesting
Map<String, String> ruleRequestHeadersForWebTest(
  Uri target,
  Map<String, String> headers,
  Uri baseUri,
) => _ruleRequestHeadersForPlatform(
  target,
  headers,
  isWeb: true,
  baseUri: baseUri,
);

Map<String, String> withoutRuleHeader(
  Map<String, String> headers,
  String name,
) {
  final normalized = name.toLowerCase();
  return {
    for (final entry in headers.entries)
      if (entry.key.toLowerCase() != normalized) entry.key: entry.value,
  };
}

const _originBoundMediaHeaders = <String>{
  'authorization',
  'proxy-authorization',
  'cookie',
  'cookie2',
  'api-key',
  'x-api-key',
  'access-token',
  'x-auth-token',
  'x-access-token',
  'x-appid',
  'x-timestamp',
  'x-signature',
  'x-upstream-authorization',
  'x-upstream-cookie',
  'x-upstream-x-appid',
  'x-upstream-x-timestamp',
  'x-upstream-x-signature',
};

Map<String, String> withoutRuleCredentials(Map<String, String> headers) => {
  for (final entry in headers.entries)
    if (!_originBoundMediaHeaders.contains(entry.key.toLowerCase()))
      entry.key: entry.value,
};

Map<String, String> ruleChildHeaders(
  Uri credentialSourceUri,
  Uri childUri,
  Map<String, String> headers,
) {
  if (_sameMediaOrigin(credentialSourceUri, childUri)) return headers;
  return withoutRuleCredentials(headers);
}

bool _sameMediaOrigin(Uri left, Uri right) {
  final leftOrigin = _normalizedMediaOrigin(ruleProxyUpstreamUri(left) ?? left);
  final rightOrigin = _normalizedMediaOrigin(
    ruleProxyUpstreamUri(right) ?? right,
  );
  return leftOrigin != null && leftOrigin == rightOrigin;
}

String? _normalizedMediaOrigin(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https' || uri.host.isEmpty) return null;
  final port = uri.hasPort ? uri.port : (scheme == 'https' ? 443 : 80);
  return '$scheme://${uri.host.toLowerCase()}:$port';
}
