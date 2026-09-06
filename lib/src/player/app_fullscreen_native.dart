import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

const _windowsWindowChannel = MethodChannel('app.anime.anime/window');

class AppFullscreenController {
  Stream<bool> get changes => const Stream<bool>.empty();

  Future<bool> setEnabled(bool enabled) async {
    if (Platform.isWindows) {
      return await _windowsWindowChannel.invokeMethod<bool>(
            'setFullscreen',
            enabled,
          ) ??
          false;
    }
    if (!Platform.isLinux && !Platform.isMacOS) return enabled;
    await windowManager.setFullScreen(enabled);
    return windowManager.isFullScreen();
  }

  Future<bool> isEnabled() async {
    if (Platform.isWindows) {
      return await _windowsWindowChannel.invokeMethod<bool>('isFullscreen') ??
          false;
    }
    if (!Platform.isLinux && !Platform.isMacOS) return false;
    return windowManager.isFullScreen();
  }

  void dispose() {}
}
