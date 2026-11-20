import 'package:media_kit/media_kit.dart';

import '../../core/network/media_request_headers.dart';
import 'media_transport_failure.dart';

/// Non-IO platforms retain their existing playback transport.
class NativeMediaTransport {
  Future<Media> prepare(
    String resource, {
    required Map<String, String> headers,
    String format = '',
    bool publicHttpOnly = false,
    Uri? privateLibraryOrigin,
    bool forceLocalBridge = false,
    bool cleanHlsManifest = true,
    void Function(MediaTransportFailure)? onFailure,
  }) async {
    if (privateLibraryOrigin != null) {
      throw UnsupportedError(
        'Private media libraries require a native client.',
      );
    }
    return Media(resource, httpHeaders: effectiveMediaRequestHeaders(headers));
  }

  Future<void> dispose() async {}
}
