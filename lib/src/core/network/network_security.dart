import 'dart:async';

import 'package:http/http.dart' as http;

enum NetworkServiceKind {
  accountBackend,
  officialPlaybackBackend,
  selfHostedPlaybackBackend,
  rulePage,
  mediaResource,
  metadataApi,
}

class NetworkSecurityException implements Exception {
  const NetworkSecurityException(this.message);

  final String message;

  @override
  String toString() => 'NetworkSecurityException: $message';
}

class NetworkRequestPolicy {
  const NetworkRequestPolicy({
    required this.service,
    required this.httpsOnly,
    required this.allowPrivateNetwork,
    required this.maxResponseBytes,
    required this.requestTimeout,
    this.allowSyntheticDns = false,
    this.allowLiteralBenchmarkAddress = false,
    this.rejectRedirects = true,
  });

  factory NetworkRequestPolicy.forService(
    NetworkServiceKind service, {
    bool allowInsecureSelfHosted = false,
  }) {
    return switch (service) {
      NetworkServiceKind.accountBackend => const NetworkRequestPolicy(
        service: NetworkServiceKind.accountBackend,
        httpsOnly: true,
        allowPrivateNetwork: false,
        maxResponseBytes: 1024 * 1024,
        requestTimeout: Duration(seconds: 15),
        allowSyntheticDns: true,
      ),
      NetworkServiceKind.officialPlaybackBackend => const NetworkRequestPolicy(
        service: NetworkServiceKind.officialPlaybackBackend,
        httpsOnly: true,
        allowPrivateNetwork: false,
        maxResponseBytes: 8 * 1024 * 1024,
        requestTimeout: Duration(seconds: 20),
        allowSyntheticDns: true,
      ),
      NetworkServiceKind.selfHostedPlaybackBackend => NetworkRequestPolicy(
        service: NetworkServiceKind.selfHostedPlaybackBackend,
        httpsOnly: !allowInsecureSelfHosted,
        allowPrivateNetwork: true,
        maxResponseBytes: 8 * 1024 * 1024,
        requestTimeout: const Duration(seconds: 20),
      ),
      NetworkServiceKind.rulePage => const NetworkRequestPolicy(
        service: NetworkServiceKind.rulePage,
        httpsOnly: true,
        allowPrivateNetwork: false,
        maxResponseBytes: 4 * 1024 * 1024,
        requestTimeout: Duration(seconds: 12),
        rejectRedirects: false,
      ),
      NetworkServiceKind.mediaResource => const NetworkRequestPolicy(
        service: NetworkServiceKind.mediaResource,
        httpsOnly: false,
        allowPrivateNetwork: false,
        maxResponseBytes: 512 * 1024,
        requestTimeout: Duration(seconds: 12),
        rejectRedirects: false,
      ),
      NetworkServiceKind.metadataApi => const NetworkRequestPolicy(
        service: NetworkServiceKind.metadataApi,
        httpsOnly: true,
        allowPrivateNetwork: false,
        maxResponseBytes: 8 * 1024 * 1024,
        requestTimeout: Duration(seconds: 15),
        allowSyntheticDns: true,
      ),
    };
  }

  final NetworkServiceKind service;
  final bool httpsOnly;
  final bool allowPrivateNetwork;
  final int maxResponseBytes;
  final Duration requestTimeout;
  final bool allowSyntheticDns;
  final bool allowLiteralBenchmarkAddress;
  final bool rejectRedirects;

  bool get allowsCleartext => !httpsOnly;

  void ensureUriAllowed(Uri uri) {
    final scheme = uri.scheme.toLowerCase();
    if (!uri.hasAuthority ||
        uri.host.trim().isEmpty ||
        uri.userInfo.isNotEmpty ||
        (scheme != 'https' && scheme != 'http')) {
      throw const NetworkSecurityException(
        'Network requests require a credential-free HTTP(S) URL.',
      );
    }
    if (httpsOnly && scheme != 'https') {
      throw NetworkSecurityException('${service.name} requires HTTPS.');
    }
    final host = uri.host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
    if (host == 'localhost' ||
        host.endsWith('.localhost') ||
        host.endsWith('.local')) {
      if (!allowPrivateNetwork) {
        throw const NetworkSecurityException(
          'Local-network destinations are not allowed for this service.',
        );
      }
    }
    if (!allowPrivateNetwork &&
        _isBlockedLiteralHost(
          host,
          allowBenchmarkAddress: allowLiteralBenchmarkAddress,
        )) {
      throw const NetworkSecurityException(
        'Private or special-purpose network destinations are blocked.',
      );
    }
  }

  void ensureHeadersAllowed(Uri uri, Map<String, String> headers) {
    if (uri.scheme.toLowerCase() != 'http') return;
    final sensitive = headers.keys.where(isSensitiveNetworkHeader).toList();
    if (sensitive.isNotEmpty) {
      throw const NetworkSecurityException(
        'Credentials and cookies cannot be sent over cleartext HTTP.',
      );
    }
  }
}

class PolicyHttpClient extends http.BaseClient {
  PolicyHttpClient({
    required http.Client inner,
    required this.policy,
    bool ownsInner = true,
  }) : _inner = inner,
       _ownsInner = ownsInner;

  final http.Client _inner;
  final bool _ownsInner;
  final NetworkRequestPolicy policy;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    policy.ensureUriAllowed(request.url);
    policy.ensureHeadersAllowed(request.url, request.headers);
    request
      ..followRedirects = false
      ..maxRedirects = 0;
    final response = await _inner.send(request).timeout(policy.requestTimeout);
    if (policy.rejectRedirects && _isRedirect(response.statusCode)) {
      final location = response.headers['location']?.trim() ?? '';
      if (location.isNotEmpty) {
        policy.ensureUriAllowed(request.url.resolve(location));
      }
      await _cancelResponse(response);
      throw const NetworkSecurityException(
        'Automatic API redirects are disabled by network policy.',
      );
    }
    final contentLength = response.contentLength;
    if (contentLength != null && contentLength > policy.maxResponseBytes) {
      await _cancelResponse(response);
      throw const NetworkSecurityException(
        'Network response exceeds the configured safety limit.',
      );
    }
    return http.StreamedResponse(
      _boundedStream(response.stream, policy.maxResponseBytes),
      response.statusCode,
      contentLength: contentLength,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() {
    if (_ownsInner) _inner.close();
  }
}

/// Follows a small, explicit redirect chain for streaming GET/HEAD requests.
///
/// The wrapped [PolicyHttpClient] still validates every network connection.
/// This layer additionally validates each redirect target before the next
/// request is created and removes credentials when the origin changes.
class RedirectingNetworkHttpClient extends http.BaseClient {
  RedirectingNetworkHttpClient({
    required http.Client inner,
    required this.policy,
    this.maxRedirects = 5,
    bool ownsInner = true,
  }) : _inner = inner,
       _ownsInner = ownsInner;

  final http.Client _inner;
  final bool _ownsInner;
  final NetworkRequestPolicy policy;
  final int maxRedirects;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final method = request.method.toUpperCase();
    if (method != 'GET' && method != 'HEAD') {
      throw const NetworkSecurityException(
        'Streaming redirect client only supports GET and HEAD requests.',
      );
    }
    var currentUri = request.url;
    var currentHeaders = Map<String, String>.from(request.headers);
    for (var redirectCount = 0; ; redirectCount++) {
      policy.ensureUriAllowed(currentUri);
      policy.ensureHeadersAllowed(currentUri, currentHeaders);
      final hopRequest = http.Request(method, currentUri)
        ..headers.addAll(currentHeaders)
        ..persistentConnection = request.persistentConnection;
      final response = await _inner.send(hopRequest);
      if (!_isRedirect(response.statusCode)) {
        return http.StreamedResponse(
          response.stream,
          response.statusCode,
          contentLength: response.contentLength,
          request: response.request ?? hopRequest,
          headers: response.headers,
          isRedirect: response.isRedirect,
          persistentConnection: response.persistentConnection,
          reasonPhrase: response.reasonPhrase,
        );
      }

      final location = response.headers['location']?.trim() ?? '';
      if (location.isEmpty) {
        await _cancelResponse(response);
        throw const NetworkSecurityException(
          'Media redirect response did not provide a target.',
        );
      }
      if (redirectCount >= maxRedirects) {
        await _cancelResponse(response);
        throw const NetworkSecurityException('Media redirect limit reached.');
      }
      final nextUri = currentUri.resolve(location);
      final nextHeaders = headersForNetworkRedirect(
        currentUri,
        nextUri,
        currentHeaders,
      );
      policy.ensureUriAllowed(nextUri);
      policy.ensureHeadersAllowed(nextUri, nextHeaders);
      await _cancelResponse(response);
      currentUri = nextUri;
      currentHeaders = nextHeaders;
    }
  }

  @override
  void close() {
    if (_ownsInner) _inner.close();
  }
}

bool isSensitiveNetworkHeader(String name) {
  final normalized = name.trim().toLowerCase();
  return normalized == 'authorization' ||
      normalized == 'proxy-authorization' ||
      normalized == 'cookie' ||
      normalized == 'set-cookie' ||
      normalized.contains('token') ||
      normalized.contains('api-key') ||
      normalized.contains('apikey') ||
      normalized.contains('secret') ||
      normalized.contains('signature') ||
      normalized.contains('credential');
}

Map<String, String> headersForNetworkRedirect(
  Uri from,
  Uri to,
  Map<String, String> headers,
) {
  if (_sameOrigin(from, to)) return Map<String, String>.from(headers);
  return {
    for (final entry in headers.entries)
      if (!isSensitiveNetworkHeader(entry.key)) entry.key: entry.value,
  };
}

bool _sameOrigin(Uri first, Uri second) =>
    first.scheme.toLowerCase() == second.scheme.toLowerCase() &&
    first.host.toLowerCase() == second.host.toLowerCase() &&
    first.port == second.port;

bool _isRedirect(int status) =>
    status == 301 ||
    status == 302 ||
    status == 303 ||
    status == 307 ||
    status == 308;

Future<void> _cancelResponse(http.StreamedResponse response) async {
  final subscription = response.stream.listen(null);
  await subscription.cancel();
}

Stream<List<int>> _boundedStream(
  Stream<List<int>> source,
  int maxBytes,
) async* {
  var total = 0;
  await for (final chunk in source) {
    total += chunk.length;
    if (total > maxBytes) {
      throw const NetworkSecurityException(
        'Decompressed network response exceeds the configured safety limit.',
      );
    }
    yield chunk;
  }
}

bool _isBlockedLiteralHost(String host, {required bool allowBenchmarkAddress}) {
  final ipv4 = _parseIpv4(host);
  if (ipv4 != null) {
    return _isBlockedIpv4(ipv4, allowBenchmarkAddress: allowBenchmarkAddress);
  }
  if (!host.contains(':')) return false;
  final normalized = host.toLowerCase();
  if (normalized == '::' || normalized == '::1') return true;
  if (normalized.startsWith('fc') || normalized.startsWith('fd')) return true;
  if (normalized.startsWith('fe8') ||
      normalized.startsWith('fe9') ||
      normalized.startsWith('fea') ||
      normalized.startsWith('feb') ||
      normalized.startsWith('ff')) {
    return true;
  }
  final mapped = RegExp(r'::ffff:(\d+\.\d+\.\d+\.\d+)$').firstMatch(normalized);
  final mappedIpv4 = mapped == null ? null : _parseIpv4(mapped.group(1)!);
  return mappedIpv4 == null ||
      _isBlockedIpv4(mappedIpv4, allowBenchmarkAddress: allowBenchmarkAddress);
}

List<int>? _parseIpv4(String host) {
  final parts = host.split('.');
  if (parts.length != 4) return null;
  final bytes = <int>[];
  for (final part in parts) {
    if (part.isEmpty || (part.length > 1 && part.startsWith('0'))) return null;
    final value = int.tryParse(part);
    if (value == null || value < 0 || value > 255) return null;
    bytes.add(value);
  }
  return bytes;
}

bool _isBlockedIpv4(List<int> bytes, {required bool allowBenchmarkAddress}) {
  final first = bytes[0];
  final second = bytes[1];
  final third = bytes[2];
  return first == 0 ||
      first == 10 ||
      first == 127 ||
      (first == 100 && second >= 64 && second <= 127) ||
      (first == 169 && second == 254) ||
      (first == 172 && second >= 16 && second <= 31) ||
      (first == 192 && second == 0 && third == 0) ||
      (first == 192 && second == 0 && third == 2) ||
      (first == 192 && second == 168) ||
      (!allowBenchmarkAddress &&
          first == 198 &&
          (second == 18 || second == 19)) ||
      (first == 198 && second == 51 && third == 100) ||
      (first == 203 && second == 0 && third == 113) ||
      first >= 224;
}
