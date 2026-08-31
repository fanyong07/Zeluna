import 'dart:async';
import 'dart:io';

import 'package:window_manager/window_manager.dart';

class AppFullscreenController {
  Stream<bool> get changes => const Stream<bool>.empty();

  /// window_manager is initialized in main() via initializeDesktopWindow, so
  /// there is no ensureInitialized() here -- calling it this late was why
  /// fullscreen only maximized the window.
  Future<bool> setEnabled(bool enabled) async {
    if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) {
      return enabled;
    }
    await windowManager.setFullScreen(enabled);
    return windowManager.isFullScreen();
  }

  Future<bool> isEnabled() async {
    if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) {
      return false;
    }
    return windowManager.isFullScreen();
  }

  void dispose() {}
}
