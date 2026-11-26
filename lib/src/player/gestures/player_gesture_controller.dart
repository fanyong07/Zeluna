import 'dart:async';

import 'package:flutter/widgets.dart';

/// Owns focus and transient chrome timers used by keyboard, pointer and touch
/// gestures.
final class PlayerGestureController {
  PlayerGestureController()
    : shortcutFocusNode = FocusNode(debugLabel: 'player-shortcuts');

  final FocusNode shortcutFocusNode;
  Timer? _controlsHideTimer;
  bool _disposed = false;

  Timer? get controlsHideTimer => _controlsHideTimer;
  bool get isDisposed => _disposed;

  void replaceControlsHideTimer(Timer? timer) {
    _controlsHideTimer?.cancel();
    _controlsHideTimer = _disposed ? null : timer;
    if (_disposed) timer?.cancel();
  }

  void cancelControlsHideTimer() {
    _controlsHideTimer?.cancel();
    _controlsHideTimer = null;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    cancelControlsHideTimer();
    shortcutFocusNode.dispose();
  }
}
