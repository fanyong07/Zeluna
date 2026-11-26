import 'dart:convert';

const _maxProxySessionHeaders = 24;
const _maxProxySessionHeaderNameBytes = 128;
const _maxProxySessionHeaderValueBytes = 8 * 1024;
const _maxProxySessionHeaderBytes = 16 * 1024;

const _allowedProxySessionHeaders = <String, String>{
  'user-agent': 'user-agent',
  'referer': 'referer',
  'origin': 'origin',
  'authorization': 'authorization',
  'cookie': 'cookie',
};

const _forbiddenProxySessionHeaders = <String>{
  'host',
  'content-length',
  'connection',
  'keep-alive',
  'proxy-authenticate',
  'proxy-authorization',
  'proxy-connection',
  'te',
  'trailer',
  'transfer-encoding',
  'upgrade',
  'expect',
};

final _headerNamePattern = RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$");
final _unsafeHeaderValuePattern = RegExp(r'[\x00-\x1f\x7f]');

Map<String, String> sanitizeProxySessionHeaders(Map<String, String> headers) {
  final result = <String, String>{};
  var acceptedBytes = 0;
  for (final entry in headers.entries) {
    final name = _proxySessionHeaderName(entry.key);
    if (name == null || result.length >= _maxProxySessionHeaders) continue;
    final value = entry.value.trim();
    final valueBytes = utf8.encode(value).length;
    if (value.isEmpty ||
        valueBytes > _maxProxySessionHeaderValueBytes ||
        _unsafeHeaderValuePattern.hasMatch(value) ||
        result.containsKey(name)) {
      continue;
    }
    final headerBytes = utf8.encode(name).length + valueBytes;
    if (acceptedBytes + headerBytes > _maxProxySessionHeaderBytes) continue;
    result[name] = value;
    acceptedBytes += headerBytes;
  }
  return result;
}

String? _proxySessionHeaderName(String value) {
  final normalized = value.trim().toLowerCase();
  if (normalized.isEmpty ||
      utf8.encode(normalized).length > _maxProxySessionHeaderNameBytes ||
      !_headerNamePattern.hasMatch(normalized) ||
      _forbiddenProxySessionHeaders.contains(normalized) ||
      normalized.startsWith('x-forwarded-') ||
      normalized == 'x-real-ip' ||
      normalized.startsWith('x-upstream-')) {
    return null;
  }
  final allowed = _allowedProxySessionHeaders[normalized];
  if (allowed != null) return allowed;
  return normalized.startsWith('x-') && normalized.length > 2
      ? normalized
      : null;
}
