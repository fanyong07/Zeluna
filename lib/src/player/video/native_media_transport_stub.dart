import 'package:media_kit/media_kit.dart';

import '../../core/network/media_request_headers.dart';

/// Non-IO platforms retain their existing playback transport.
class NativeMediaTransport {
  Future<Media> prepare(
    String resource, {
    required Map<String, String> headers,
    String format = '',
    bool publicHttpOnly = false,
  }) async =>
      Media(resource, httpHeaders: effectiveMediaRequestHeaders(headers));

  Future<void> dispose() async {}
}
