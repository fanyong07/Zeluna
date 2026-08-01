import 'dart:async';

import '../playback_line_display.dart';
import '../web_stream_player.dart';

enum WebStartupTimeoutPhase { soft, hard }

final class WebStartupTimeoutEvent {
  const WebStartupTimeoutEvent({
    required this.phase,
    required this.hasAlternative,
  });

  final WebStartupTimeoutPhase phase;
  final bool hasAlternative;
}

/// Owns imperative browser-player commands and the startup watchdog that must
/// never survive the associated playback page.
final class WebVideoController {
  WebVideoController() : surfaceController = WebStreamPlayerController();

  final WebStreamPlayerController surfaceController;
  Timer? _startupTimer;
  var _startupGeneration = 0;
  bool _disposed = false;

  bool get startupWatchdogActive => _startupTimer != null;
  bool get isDisposed => _disposed;

  void startStartupWatchdog({
    required bool Function() isCurrent,
    required bool Function() waitingForReady,
    required bool Function() hasAlternative,
    required void Function(WebStartupTimeoutEvent event) onTimeout,
    Duration softTimeout = const Duration(seconds: 7),
    Duration hardTimeout = const Duration(seconds: 25),
  }) {
    cancelStartupWatchdog();
    if (_disposed) return;
    assert(softTimeout > Duration.zero);
    assert(hardTimeout >= softTimeout);
    final generation = _startupGeneration;
    _startupTimer = Timer(softTimeout, () {
      _startupTimer = null;
      if (_disposed || generation != _startupGeneration || !isCurrent()) {
        return;
      }
      final waiting = waitingForReady();
      if (!webPlaybackStartupTimedOut(waitingForReady: waiting)) return;
      final alternative = hasAlternative();
      if (webPlaybackShouldSwitchAtSoftTimeout(
        waitingForReady: waiting,
        hasAlternative: alternative,
      )) {
        onTimeout(
          WebStartupTimeoutEvent(
            phase: WebStartupTimeoutPhase.soft,
            hasAlternative: alternative,
          ),
        );
        return;
      }
      _startupTimer = Timer(hardTimeout - softTimeout, () {
        _startupTimer = null;
        if (_disposed || generation != _startupGeneration || !isCurrent()) {
          return;
        }
        final stillWaiting = waitingForReady();
        if (!webPlaybackStartupTimedOut(waitingForReady: stillWaiting)) {
          return;
        }
        onTimeout(
          WebStartupTimeoutEvent(
            phase: WebStartupTimeoutPhase.hard,
            hasAlternative: hasAlternative(),
          ),
        );
      });
    });
  }

  void cancelStartupWatchdog() {
    _startupGeneration++;
    _startupTimer?.cancel();
    _startupTimer = null;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    cancelStartupWatchdog();
  }
}
