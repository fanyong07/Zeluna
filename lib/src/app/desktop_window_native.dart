import 'dart:io';

import 'package:window_manager/window_manager.dart';

/// Hands the desktop window to `window_manager` before the first frame.
///
/// This has to happen in `main()`, not lazily when the user first hits
/// fullscreen: on Windows the plugin captures the window's original style and
/// placement during initialization, and `setFullScreen` restores/replaces them
/// from that captured state. Without it the call only ever maximized the
/// window -- the title bar stayed put and the desktop showed below the player.
Future<void> initializeDesktopWindow() async {
  if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) return;
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(null, () async {
    await windowManager.show();
    await windowManager.focus();
  });
}
