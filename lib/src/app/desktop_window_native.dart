import 'dart:io';

import 'package:window_manager/window_manager.dart';

/// Initializes the desktop window plugin before widgets use it.
Future<void> initializeDesktopWindow() async {
  if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) return;
  await windowManager.ensureInitialized();
}
