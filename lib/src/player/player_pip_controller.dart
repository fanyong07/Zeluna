import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class PlayerPipController {
  PlayerPipController({required this.onChanged});

  final ValueChanged<bool> onChanged;
  static const _pip = MethodChannel('app.anime.anime/pip');
  static const _window = MethodChannel('app.anime.anime/window');
  bool get isWindows =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<bool> initialize() async {
    if (_isAndroid) {
      _pip.setMethodCallHandler((call) async {
        if (call.method == 'onPipChanged' && call.arguments is bool) {
          onChanged(call.arguments as bool);
        }
      });
      return await _invoke(_pip, 'isSupported') ?? false;
    }
    if (isWindows) {
      final active = await _invoke(_window, 'isMiniWindow');
      if (active == true) onChanged(true);
      return active != null;
    }
    return false;
  }

  Future<bool> toggle({required bool active, int? width, int? height}) async {
    if (isWindows) {
      final next = await _invoke(_window, 'setMiniWindow', !active);
      if (next != null) onChanged(next);
      return next == !active;
    }
    return _isAndroid &&
        await _invoke(_pip, 'enterPip', {
              'aspectWidth': width,
              'aspectHeight': height,
            }) ==
            true;
  }

  Future<void> exitIfActive() async {
    if (isWindows && await _invoke(_window, 'isMiniWindow') == true) {
      await _invoke(_window, 'setMiniWindow', false);
    }
  }

  static Future<bool?> _invoke(
    MethodChannel channel,
    String method, [
    Object? arguments,
  ]) async {
    try {
      return await channel.invokeMethod<bool>(method, arguments);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  void dispose() {
    if (_isAndroid) _pip.setMethodCallHandler(null);
  }
}
