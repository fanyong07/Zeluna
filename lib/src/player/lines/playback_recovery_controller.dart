import 'dart:async';

/// Owns every timer that may initiate playback recovery. Callbacks are
/// cancelled together so no recovery work can outlive its playback page.
final class PlaybackRecoveryController {
  Timer? _stallWatchdogTimer;
  Timer? _backupLookupTimer;
  Timer? _currentLineRetryTimer;
  bool _disposed = false;

  Timer? get backupLookupTimer => _backupLookupTimer;
  bool get isDisposed => _disposed;

  void startStallWatchdog(Duration interval, void Function() onTick) {
    _stallWatchdogTimer?.cancel();
    if (_disposed) return;
    _stallWatchdogTimer = Timer.periodic(interval, (_) {
      if (!_disposed) onTick();
    });
  }

  void replaceBackupLookupTimer(Timer? timer) {
    _backupLookupTimer?.cancel();
    _backupLookupTimer = _disposed ? null : timer;
    if (_disposed) timer?.cancel();
  }

  void cancelBackupLookup() {
    _backupLookupTimer?.cancel();
    _backupLookupTimer = null;
  }

  void scheduleCurrentLineRetry(
    Duration delay,
    FutureOr<void> Function() retry,
  ) {
    _currentLineRetryTimer?.cancel();
    if (_disposed) return;
    _currentLineRetryTimer = Timer(delay, () {
      _currentLineRetryTimer = null;
      if (!_disposed) unawaited(Future<void>.sync(retry));
    });
  }

  void cancelCurrentLineRetry() {
    _currentLineRetryTimer?.cancel();
    _currentLineRetryTimer = null;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _stallWatchdogTimer?.cancel();
    _stallWatchdogTimer = null;
    cancelBackupLookup();
    cancelCurrentLineRetry();
  }
}
