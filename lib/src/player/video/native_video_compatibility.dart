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

  /// Called only when the user copies diagnostics; never queried or uploaded
  /// as an identifier. Explicit allowlist prevents additional native fields.
  Future<Map<String, Object?>> diagnosticEnvironment() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return const {};
    }
    try {
      final raw = await _channel
          .invokeMapMethod<String, dynamic>('playbackDiagnostics')
          .timeout(const Duration(seconds: 1), onTimeout: () => null);
      return {
        if (raw?['android_api'] is int) 'android_api': raw!['android_api'],
        if (raw?['primary_abi'] is String) 'primary_abi': raw!['primary_abi'],
        'software_decoder': _softwareDecode,
      };
    } on MissingPluginException {
      return const {};
    } on PlatformException {
      return const {};
    }
  }

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
