import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Reads a local capability flag before any player is constructed. No device
/// identifiers leave Android. ARM phones and desktop keep media-kit defaults.
final class NativeVideoCompatibility {
  static final instance = NativeVideoCompatibility();
  static const _channel = MethodChannel('app.anime.anime/video-compatibility');
  bool _softwareDecode = false;

  VideoControllerConfiguration get configuration =>
      VideoControllerConfiguration(hwdec: _softwareDecode ? 'no' : null);

  Future<void> initialize() async {
    _softwareDecode = false;
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      _softwareDecode =
          await _channel
              .invokeMethod<bool>('requiresSoftwareVideoDecode')
              .timeout(const Duration(seconds: 1), onTimeout: () => false) ??
          false;
    } on MissingPluginException {
      // Older native hosts retain the library's own compatibility detection.
    } on PlatformException {
      // Capability discovery must not prevent startup.
    }
  }
}
