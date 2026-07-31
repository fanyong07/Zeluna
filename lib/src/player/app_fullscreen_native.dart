import 'dart:async';
import 'dart:io';

import 'package:window_manager/window_manager.dart';

class AppFullscreenController {
  Stream<bool> get changes => const Stream<bool>.empty();

  Future<bool> setEnabled(bool enabled) async {
    if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) {
      return enabled;
    }
    await windowManager.ensureInitialized();
    await windowManager.setFullScreen(enabled);
    return windowManager.isFullScreen();
  }

  Future<bool> isEnabled() async {
    if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) {
      return false;
    }
    await windowManager.ensureInitialized();
    return windowManager.isFullScreen();
  }

  void dispose() {}
}
