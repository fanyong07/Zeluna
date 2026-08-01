import 'dart:async';

import '../web_stream_player.dart';

/// Owns imperative browser-player commands and the startup watchdog that must
/// never survive the associated playback page.
final class WebVideoController {
  WebVideoController() : surfaceController = WebStreamPlayerController();

  final WebStreamPlayerController surfaceController;
  Timer? _startupTimer;
  bool _disposed = false;

  Timer? get startupTimer => _startupTimer;
  bool get isDisposed => _disposed;

  void replaceStartupTimer(Timer? timer) {
    _startupTimer?.cancel();
    _startupTimer = _disposed ? null : timer;
    if (_disposed) timer?.cancel();
  }

  void cancelStartupTimer() {
    _startupTimer?.cancel();
    _startupTimer = null;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    cancelStartupTimer();
  }
}
