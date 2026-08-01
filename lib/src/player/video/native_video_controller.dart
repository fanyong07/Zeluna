import 'dart:async';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Owns the native media-kit objects and every subscription/timer tied to
/// their lifetime. UI code may subscribe through [track], but it never disposes
/// individual native resources itself.
final class NativeVideoController {
  NativeVideoController() : player = Player() {
    surfaceController = VideoController(player);
  }

  final Player player;
  late final VideoController surfaceController;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Timer? _firstFrameTimer;
  Timer? _resumeSeekTimer;
  bool _disposed = false;

  bool get isDisposed => _disposed;
  bool get hasFirstFrameTimer => _firstFrameTimer != null;
  bool get hasResumeSeekTimer => _resumeSeekTimer != null;
  Timer? get firstFrameTimer => _firstFrameTimer;
  Timer? get resumeSeekTimer => _resumeSeekTimer;

  void track(StreamSubscription<dynamic> subscription) {
    if (_disposed) {
      unawaited(subscription.cancel());
      return;
    }
    _subscriptions.add(subscription);
  }

  void replaceFirstFrameTimer(Timer? timer) {
    _firstFrameTimer?.cancel();
    _firstFrameTimer = _disposed ? null : timer;
    if (_disposed) timer?.cancel();
  }

  void clearFirstFrameTimer() {
    _firstFrameTimer?.cancel();
    _firstFrameTimer = null;
  }

  void replaceResumeSeekTimer(Timer? timer) {
    _resumeSeekTimer?.cancel();
    _resumeSeekTimer = _disposed ? null : timer;
    if (_disposed) timer?.cancel();
  }

  void clearResumeSeekTimer() {
    _resumeSeekTimer?.cancel();
    _resumeSeekTimer = null;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    clearFirstFrameTimer();
    clearResumeSeekTimer();
    final subscriptions = List.of(_subscriptions);
    _subscriptions.clear();
    await Future.wait(subscriptions.map((item) => item.cancel()));
    await player.dispose();
  }
}
