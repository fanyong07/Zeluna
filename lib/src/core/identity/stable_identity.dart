import 'dart:convert';

import 'package:crypto/crypto.dart';

const stableIdentityVersion = 'v1';

const _volatilePlaybackHeaders = <String>{
  'connection',
  'content-length',
  'if-range',
  'range',
};

const _sensitiveHeaderNames = <String>{
  'authorization',
  'cookie',
  'cookie2',
  'proxy-authorization',
  'x-api-key',
  'x-auth-token',
  'x-access-token',
  'access-token',
  'api-key',
};

String stableDigest(String value) =>
    sha256.convert(utf8.encode(value)).toString();

String stableSubjectKey({
  required String source,
  required Object identifier,
  String? mediaType,
}) {
  final normalizedSource = source.trim().toLowerCase();
  final normalizedIdentifier = identifier.toString().trim();
  if (normalizedSource == 'bangumi') {
    return 'bangumi:$normalizedIdentifier';
  }
  final sourceParts = normalizedSource.split(':');
  if (sourceParts.firstOrNull == 'bangumi' && sourceParts.length >= 2) {
    return 'bangumi:${sourceParts[1]}';
  }
  if (sourceParts.firstOrNull == 'tmdb') {
    final rawType = sourceParts.length >= 2
        ? sourceParts[1]
        : (mediaType ?? '').trim().toLowerCase();
    final normalizedType = rawType == 'series' ? 'tv' : rawType;
    final providerIdentifier = sourceParts.length >= 3
        ? sourceParts[2]
        : normalizedIdentifier;
    if ((normalizedType == 'tv' || normalizedType == 'movie') &&
        providerIdentifier.isNotEmpty) {
      return 'tmdb:$normalizedType:$providerIdentifier';
    }
  }
  if (sourceParts.firstOrNull == 'archive' && sourceParts.length >= 2) {
    return _genericSubjectKey(
      source: 'archive',
      identifier: sourceParts.skip(1).join(':'),
    );
  }
  if (sourceParts.firstOrNull == 'm3u-channel' && sourceParts.length >= 3) {
    return _genericSubjectKey(
      source: 'm3u-channel:${sourceParts[1]}',
      identifier: sourceParts.skip(2).join(':'),
    );
  }
  if (sourceParts.firstOrNull == 'cinemeta' && sourceParts.length >= 3) {
    return _genericSubjectKey(
      source: 'cinemeta:${sourceParts[1]}',
      identifier: sourceParts.skip(2).join(':'),
    );
  }
  return _genericSubjectKey(
    source: normalizedSource,
    identifier: normalizedIdentifier,
    mediaType: mediaType,
  );
}

String _genericSubjectKey({
  required String source,
  required String identifier,
  String? mediaType,
}) {
  final canonical = _frameIdentityParts([
    source,
    identifier,
    (mediaType ?? '').trim().toLowerCase(),
  ]);
  return 'subject:$stableIdentityVersion:${stableDigest('subject|$stableIdentityVersion|$canonical')}';
}

String stableEpisodeKey({
  required String subjectKey,
  required Object normalizedNumber,
}) =>
    '$stableIdentityVersion|${subjectKey.trim()}|episode:${_normalizeNumber(normalizedNumber)}';

String stablePlaybackLineKey({
  required String providerId,
  required String episodeKey,
  required String uri,
  Map<String, String> headers = const {},
}) {
  final canonical = _frameIdentityParts([
    providerId.trim(),
    episodeKey.trim(),
    canonicalIdentityUri(uri),
    stableHeaderFingerprint(headers),
  ]);
  return 'line:$stableIdentityVersion:${stableDigest('line|$stableIdentityVersion|$canonical')}';
}

String stableDownloadTaskKey({
  required String subjectKey,
  required String episodeKey,
  String providerId = '',
}) {
  final canonical = _frameIdentityParts([
    subjectKey.trim(),
    episodeKey.trim(),
    providerId.trim(),
  ]);
  return 'download:$stableIdentityVersion:${stableDigest('download|$stableIdentityVersion|$canonical')}';
}

String stableRuleKey({
  required String ruleId,
  required String engine,
  String sourceRepository = '',
  String contentHash = '',
}) {
  final repository = _canonicalUriOrText(sourceRepository);
  final canonical = _frameIdentityParts([
    ruleId.trim(),
    engine.trim().toLowerCase(),
    repository,
    contentHash.trim().toLowerCase(),
  ]);
  return 'rule:$stableIdentityVersion:${stableDigest('rule|$stableIdentityVersion|$canonical')}';
}

int stableInt63(String value) {
  final prefix = stableDigest(value).substring(0, 16);
  final parsed = BigInt.parse(prefix, radix: 16);
  final result = (parsed & ((BigInt.one << 63) - BigInt.one)).toInt();
  return result == 0 ? 1 : result;
}

String canonicalIdentityUri(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null || !uri.hasScheme || !uri.hasAuthority || uri.host.isEmpty) {
    throw FormatException('Identity URI must be absolute.', value);
  }
  final scheme = uri.scheme.toLowerCase();
  final defaultPort =
      (scheme == 'http' && uri.port == 80) ||
      (scheme == 'https' && uri.port == 443);
  final userInfo = uri.userInfo.isEmpty ? '' : '${uri.userInfo}@';
  final normalizedHost = uri.host.toLowerCase();
  final host = normalizedHost.contains(':')
      ? '[$normalizedHost]'
      : normalizedHost;
  final port = !defaultPort && uri.hasPort ? ':${uri.port}' : '';
  final query = uri.hasQuery ? '?${uri.query}' : '';
  return '$scheme://$userInfo$host$port${uri.path}$query';
}

String stableHeaderFingerprint(Map<String, String> headers) {
  final entries = headers.entries.toList(growable: false)
    ..sort((left, right) {
      final byName = left.key.toLowerCase().compareTo(right.key.toLowerCase());
      if (byName != 0) return byName;
      final byOriginalName = left.key.compareTo(right.key);
      if (byOriginalName != 0) return byOriginalName;
      return left.value.compareTo(right.value);
    });
  final normalized = <String, String>{};
  for (final entry in entries) {
    final name = entry.key.trim().toLowerCase();
    final rawValue = entry.value.trim();
    if (name.isEmpty ||
        rawValue.isEmpty ||
        _volatilePlaybackHeaders.contains(name)) {
      continue;
    }
    final value = switch (name) {
      'referer' || 'origin' => _canonicalUriOrText(rawValue),
      _ when _isSensitiveHeader(name) => 'sha256:${stableDigest(rawValue)}',
      _ => rawValue,
    };
    normalized[name] = value;
  }
  final canonical = _frameIdentityParts([
    for (final name in normalized.keys.toList()..sort())
      '$name=${normalized[name]}',
  ]);
  return stableDigest('headers|$stableIdentityVersion|$canonical');
}

bool _isSensitiveHeader(String name) =>
    _sensitiveHeaderNames.contains(name) ||
    name.contains('token') ||
    name.contains('secret') ||
    name.endsWith('-key');

String _canonicalUriOrText(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty) return '';
  try {
    return canonicalIdentityUri(normalized);
  } on FormatException {
    return normalized;
  }
}

String _frameIdentityParts(Iterable<String> parts) =>
    parts.map((part) => '${utf8.encode(part).length}:$part').join('|');

String _normalizeNumber(Object value) {
  final raw = value.toString().trim();
  final match = RegExp(r'^([+-]?)(\d+)(?:\.(\d+))?$').firstMatch(raw);
  if (match == null) return raw.toLowerCase();
  final integer = match.group(2)!.replaceFirst(RegExp(r'^0+(?=\d)'), '');
  final fraction = (match.group(3) ?? '').replaceFirst(RegExp(r'0+$'), '');
  final isZero = int.tryParse(integer) == 0 && fraction.isEmpty;
  final sign = match.group(1) == '-' && !isZero ? '-' : '';
  return fraction.isEmpty ? '$sign$integer' : '$sign$integer.$fraction';
}
