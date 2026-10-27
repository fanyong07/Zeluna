import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';

import '../../core/network/media_request_headers.dart';
import '../../core/network/network_http_client.dart';
import '../../core/network/network_security.dart';
import '../../rules/rule_http_policy.dart';

/// Android's bundled FFmpeg TLS stack can reject streams that Dart's verified
/// TLS stack can read. Relay HLS/progressive bytes locally, not through a server.
/// The capability URL and upstream credentials exist only for this open.
class NativeMediaTransport {
  NativeMediaBridge? _bridge;
  int _generation = 0;
  bool _disposed = false;

  Future<Media> prepare(
    String resource, {
    required Map<String, String> headers,
    String format = '',
    bool publicHttpOnly = false,
  }) async {
    if (_disposed) throw StateError('Media transport is disposed.');
    final generation = ++_generation;
    final previous = _bridge;
    _bridge = null;
    await previous?.dispose();
    final uri = Uri.tryParse(resource);
    final effectiveHeaders = effectiveMediaRequestHeaders(headers);
    // DASH has its own URL templates; do not rewrite it as an HLS playlist.
    final relay =
        Platform.isAndroid &&
        uri != null &&
        const {'http', 'https'}.contains(uri.scheme) &&
        format.toUpperCase() != 'DASH' &&
        !uri.path.toLowerCase().endsWith('.mpd');
    if (_disposed || generation != _generation) {
      throw StateError('Media open was replaced.');
    }
    if (!relay) return Media(resource, httpHeaders: effectiveHeaders);
    final bridge = await NativeMediaBridge.start(
      uri,
      headers: effectiveHeaders,
      playlist: const {'HLS', 'M3U8'}.contains(format.toUpperCase()),
      publicHttpOnly: publicHttpOnly,
    );
    if (_disposed || generation != _generation) {
      await bridge.dispose();
      throw StateError('Media open was replaced.');
    }
    _bridge = bridge;
    // Never send source credentials to the local HTTP listener.
    return Media(bridge.uri.toString());
  }

  Future<void> dispose() async {
    _disposed = true;
    _generation++;
    final bridge = _bridge;
    _bridge = null;
    await bridge?.dispose();
  }
}

/// A fixed-capability, loopback-only relay. No arbitrary URL query parameter,
/// directory, cache, account endpoint or public listener is exposed.
class NativeMediaBridge {
  NativeMediaBridge._(this._server, this._policy, this._clientFactory);

  static const maxPlaylistBytes = 4 * 1024 * 1024;
  static const maxResources = 16384;
  static const maxConcurrentRequests = 12;
  static const _idleTimeout = Duration(seconds: 30);
  final HttpServer _server;
  final NetworkRequestPolicy _policy;
  final http.Client Function()? _clientFactory;
  final String _token = base64UrlEncode(
    List.generate(32, (_) => Random.secure().nextInt(256)),
  ).replaceAll('=', '');
  final _resources = <String, _Resource>{};
  final _resourceIds = <String, String>{};
  final _transfers = <_Transfer>{};
  // One lease per active transfer; only completely consumed responses return
  // to this per-open pool. A cancelled request never closes a peer's socket.
  final _idleClients = <http.Client>[];
  bool _disposed = false;
  late final Uri uri;

  /// [clientFactory] replaces only the wire for deterministic tests; URL and
  /// credential policies, redirect handling and byte limits stay enabled.
  static Future<NativeMediaBridge> start(
    Uri source, {
    Map<String, String> headers = const {},
    bool playlist = false,
    bool publicHttpOnly = false,
    http.Client Function()? clientFactory,
  }) async {
    final policy = NetworkRequestPolicy(
      service: NetworkServiceKind.mediaResource,
      httpsOnly: false,
      allowPrivateNetwork: false,
      maxResponseBytes: mediaDownloadMaxResponseBytes,
      requestTimeout: _idleTimeout,
      allowSyntheticDns: !publicHttpOnly,
      allowLiteralBenchmarkAddress: !publicHttpOnly,
      rejectRedirects: false,
    );
    policy.ensureUriAllowed(source);
    policy.ensureHeadersAllowed(source, headers);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.idleTimeout = _idleTimeout;
    final bridge = NativeMediaBridge._(server, policy, clientFactory);
    bridge.uri = bridge._register(source, headers, playlist: playlist);
    server.listen(bridge._handle, onError: (Object _) {});
    return bridge;
  }

  Uri _register(
    Uri target,
    Map<String, String> headers, {
    bool playlist = false,
  }) {
    _policy.ensureUriAllowed(target);
    _policy.ensureHeadersAllowed(target, headers);
    final sorted = headers.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final key = jsonEncode([
      target.toString(),
      playlist,
      {for (final entry in sorted) entry.key: entry.value},
    ]);
    var id = _resourceIds[key];
    if (id == null) {
      if (_resources.length >= maxResources) {
        throw const NetworkSecurityException('Media resource limit reached.');
      }
      id =
          '${_resources.length}${playlist || target.path.toLowerCase().endsWith('.m3u8') ? '.m3u8' : ''}';
      _resourceIds[key] = id;
      _resources[id] = _Resource(target, Map.unmodifiable(headers), playlist);
    }
    return Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: _server.port,
      pathSegments: [_token, id],
    );
  }

  Future<void> _handle(HttpRequest request) async {
    // Handle peer disconnects even while waiting for upstream headers.
    unawaited(request.response.done.then<void>((_) {}, onError: (Object _) {}));
    final parts = request.uri.pathSegments;
    final resource =
        parts.length == 2 && parts.first == _token && !request.uri.hasQuery
        ? _resources[parts.last]
        : null;
    if (_disposed ||
        resource == null ||
        !const {'GET', 'HEAD'}.contains(request.method) ||
        request.headers.value('origin') != null ||
        request.headers.value('host') != '127.0.0.1:${_server.port}') {
      await _reject(request, 404);
      return;
    }
    if (_transfers.length >= maxConcurrentRequests) {
      await _reject(request, 503);
      return;
    }
    final transfer = _Transfer(_leaseClient(), _releaseClient);
    var upstreamComplete = false;
    _transfers.add(transfer);
    unawaited(
      request.response.done.then<void>(
        (_) => transfer.cancel(),
        onError: (Object _) => transfer.cancel(),
      ),
    );
    try {
      var target = resource.uri;
      var headers = Map<String, String>.from(resource.headers);
      // Ask for identity encoding so byte-range/content-length semantics survive.
      headers.removeWhere((name, _) => name.toLowerCase() == 'accept-encoding');
      headers['Accept-Encoding'] = 'identity';
      final range = request.headers.value('range');
      if (!resource.playlist &&
          !target.path.toLowerCase().endsWith('.m3u8') &&
          range != null) {
        if (!RegExp(r'^bytes=(?:\d+-\d*|-\d+)$').hasMatch(range)) {
          await _reject(request, 416);
          return;
        }
        headers['Range'] = range;
        final ifRange = request.headers.value('if-range');
        if (ifRange != null) headers['If-Range'] = ifRange;
      }
      late http.StreamedResponse response;
      for (var redirects = 0; ; redirects++) {
        if (transfer.cancelled) return;
        response = await transfer.client.send(
          http.Request(request.method, target)..headers.addAll(headers),
        );
        transfer.reader = StreamIterator(response.stream);
        if (transfer.cancelled) {
          await transfer.reader!.cancel();
          return;
        }
        if (!const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
          break;
        }
        final location = response.headers['location'];
        if (redirects >= 5 || location == null || location.isEmpty) {
          throw const NetworkSecurityException('Media redirect limit reached.');
        }
        await transfer.reader!.cancel();
        final next = target.resolve(location);
        headers = _childHeaders(target, next, headers);
        _policy.ensureUriAllowed(next);
        _policy.ensureHeadersAllowed(next, headers);
        target = next;
      }
      final reader = transfer.reader!;
      request.response.headers.set('cache-control', 'no-store');
      if (response.statusCode != 200 && response.statusCode != 206) {
        await _reject(request, response.statusCode == 416 ? 416 : 502);
        return;
      }
      if (request.method == 'HEAD') {
        request.response.statusCode = response.statusCode;
        _copyMediaHeaders(response, request.response);
        // HEAD has no body. Do not reuse a connection with unexpected bytes.
        upstreamComplete = !await reader.moveNext().timeout(_idleTimeout);
        return;
      }
      final prefix = <int>[];
      while (prefix.length < 16 &&
          await reader.moveNext().timeout(_idleTimeout)) {
        prefix.addAll(reader.current);
      }
      final textPrefix = utf8
          .decode(prefix.take(64).toList(), allowMalformed: true)
          .replaceFirst('\uFEFF', '')
          .trimLeft();
      final hls = textPrefix.startsWith('#EXTM3U');
      if (hls) {
        final bytes = <int>[...prefix];
        if (bytes.length > maxPlaylistBytes) {
          throw const FormatException('Playlist too large.');
        }
        while (await reader.moveNext().timeout(_idleTimeout)) {
          if (bytes.length + reader.current.length > maxPlaylistBytes) {
            throw const FormatException('Playlist too large.');
          }
          bytes.addAll(reader.current);
        }
        final rewritten = _rewritePlaylist(utf8.decode(bytes), target, headers);
        request.response.statusCode = 200;
        request.response.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
        );
        request.response.add(utf8.encode(rewritten));
      } else {
        if (resource.playlist) {
          throw const FormatException('Expected HLS playlist.');
        }
        request.response.statusCode = response.statusCode;
        _copyMediaHeaders(response, request.response);
        request.response.add(prefix);
        await request.response.flush();
        while (await reader.moveNext().timeout(_idleTimeout)) {
          if (transfer.cancelled) return;
          request.response.add(reader.current);
          await request.response.flush();
        }
      }
      upstreamComplete = true;
    } catch (_) {
      // Runtime exceptions may contain signed URLs. Return a generic status only.
      try {
        request.response.statusCode = 502;
      } catch (_) {}
    } finally {
      await transfer.finish(reusable: upstreamComplete);
      _transfers.remove(transfer);
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  http.Client _leaseClient() {
    if (_idleClients.isNotEmpty) return _idleClients.removeLast();
    final wire = _clientFactory?.call();
    return wire == null
        ? createNetworkHttpClient(_policy)
        : PolicyHttpClient(inner: wire, policy: _policy);
  }

  void _releaseClient(http.Client client, bool reusable) {
    if (!_disposed && reusable && _idleClients.length < maxConcurrentRequests) {
      _idleClients.add(client);
    } else {
      client.close();
    }
  }

  String _rewritePlaylist(String text, Uri base, Map<String, String> headers) {
    var nextIsPlaylist = false;
    String child(String value, {required bool playlist}) {
      final target = base.resolve(value);
      return _register(
        target,
        _childHeaders(base, target, headers),
        playlist: playlist,
      ).toString();
    }

    return text
        .split('\n')
        .map((line) {
          final trimmed = line.trim();
          if (trimmed.isEmpty) return line;
          if (!trimmed.startsWith('#')) {
            final value = child(trimmed, playlist: nextIsPlaylist);
            nextIsPlaylist = false;
            return value;
          }
          if (trimmed.startsWith('#EXT-X-STREAM-INF:')) nextIsPlaylist = true;
          final playlistAttribute = RegExp(
            r'^#EXT-X-(?:MEDIA|I-FRAME-STREAM-INF|RENDITION-REPORT):',
          ).hasMatch(trimmed);
          return line.replaceAllMapped(
            RegExp(r'URI="([^"]+)"'),
            (m) => 'URI="${child(m[1]!, playlist: playlistAttribute)}"',
          );
        })
        .join('\n');
  }

  static Map<String, String> _childHeaders(
    Uri from,
    Uri to,
    Map<String, String> headers,
  ) => ruleChildHeaders(from, to, headersForNetworkRedirect(from, to, headers));

  static void _copyMediaHeaders(
    http.StreamedResponse source,
    HttpResponse target,
  ) {
    for (final name in const [
      'content-type',
      'content-range',
      'accept-ranges',
    ]) {
      final value = source.headers[name];
      if (value != null) target.headers.set(name, value);
    }
    if (!source.headers.containsKey('content-encoding') &&
        source.contentLength != null) {
      target.contentLength = source.contentLength!;
    }
  }

  static Future<void> _reject(HttpRequest request, int status) async {
    try {
      request.response.statusCode = status;
      request.response.headers.set('cache-control', 'no-store');
      await request.response.close();
    } catch (_) {}
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _resources.clear();
    _resourceIds.clear();
    for (final client in _idleClients) {
      client.close();
    }
    _idleClients.clear();
    await Future.wait(_transfers.toList().map((transfer) => transfer.cancel()));
    await _server.close(force: true);
  }
}

class _Resource {
  const _Resource(this.uri, this.headers, this.playlist);
  final Uri uri;
  final Map<String, String> headers;
  final bool playlist;
}

class _Transfer {
  _Transfer(this.client, this._release);
  final http.Client client;
  final void Function(http.Client, bool) _release;
  StreamIterator<List<int>>? reader;
  bool cancelled = false;
  bool _finished = false;

  Future<void> cancel() async {
    // response.done can arrive after a successful lease was handed back. It
    // must not close that lease once a later transfer has acquired it.
    if (_finished) return;
    cancelled = true;
    await finish(reusable: false);
  }

  Future<void> finish({required bool reusable}) async {
    if (_finished) return;
    _finished = true;
    try {
      await reader?.cancel();
    } catch (_) {
      reusable = false;
    }
    _release(client, reusable && !cancelled);
  }
}
