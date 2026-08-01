import 'dart:async';

import '../playback_line_display.dart';

/// Owns every timer that may initiate playback recovery. Callbacks are
/// cancelled together so no recovery work can outlive its playback page.
final class PlaybackRecoveryController {
  PlaybackRecoveryController({DateTime Function()? now})
    : _now = now ?? DateTime.now {
    _lastProgressAt = _now();
  }

  final DateTime Function() _now;
  Timer? _stallWatchdogTimer;
  Timer? _backupLookupTimer;
  Timer? _currentLineRetryTimer;
  Duration _lastProgressPosition = Duration.zero;
  late DateTime _lastProgressAt;
  DateTime? _lastStallRecoveryAt;
  DateTime? _stallSuppressedUntil;
  bool _autoSwitching = false;
  bool _autoSwitchRetryPending = false;
  Duration? _pendingAutoSwitchResumePosition;
  bool _disposed = false;

  Timer? get backupLookupTimer => _backupLookupTimer;
  bool get isDisposed => _disposed;
  bool get isAutoSwitching => _autoSwitching;

  void resetStallWatchdog({
    required Duration position,
    Duration grace = Duration.zero,
  }) {
    if (_disposed) return;
    final now = _now();
    _lastProgressPosition = position;
    _lastProgressAt = now;
    _stallSuppressedUntil = grace > Duration.zero ? now.add(grace) : null;
  }

  void notePlaybackProgress(Duration value) {
    if (_disposed) return;
    final movedForward = value > _lastProgressPosition;
    final jumpedBackward =
        _lastProgressPosition - value > const Duration(seconds: 1);
    if (!movedForward && !jumpedBackward) return;
    _lastProgressPosition = value;
    _lastProgressAt = _now();
  }

  bool shouldRecoverFromStall({
    required bool recoveryBlocked,
    required bool appInForeground,
    required bool playing,
    required bool buffering,
    required bool loading,
    required bool playbackFailed,
    required Duration position,
    required Duration duration,
    required Duration buffer,
  }) {
    if (_disposed || recoveryBlocked) return false;
    final now = _now();
    final suppressedUntil = _stallSuppressedUntil;
    if (suppressedUntil != null && now.isBefore(suppressedUntil)) return false;
    final lastRecovery = _lastStallRecoveryAt;
    final sinceLastRecovery = lastRecovery == null
        ? const Duration(days: 365)
        : now.difference(lastRecovery);
    final shouldRecover = playbackShouldRecoverFromStall(
      appInForeground: appInForeground,
      playing: playing,
      buffering: buffering,
      loading: loading,
      playbackFailed: playbackFailed,
      position: position,
      duration: duration,
      buffer: buffer,
      stalledFor: now.difference(_lastProgressAt),
      sinceLastRecovery: sinceLastRecovery,
    );
    if (!shouldRecover) return false;
    _lastStallRecoveryAt = now;
    resetStallWatchdog(
      position: position,
      grace: playbackStallRecoveryCooldown,
    );
    return true;
  }

  Future<void> runAutoSwitch({
    Duration? resumePosition,
    required Future<void> Function(Duration resumePosition) attempt,
  }) async {
    if (_disposed) return;
    if (_autoSwitching) {
      _autoSwitchRetryPending = true;
      final pending = playbackRecoveryPosition(resumePosition ?? Duration.zero);
      if (pending > (_pendingAutoSwitchResumePosition ?? Duration.zero)) {
        _pendingAutoSwitchResumePosition = pending;
      }
      return;
    }
    final targetResumePosition = playbackRecoveryPosition(
      resumePosition ?? _pendingAutoSwitchResumePosition ?? Duration.zero,
    );
    _pendingAutoSwitchResumePosition = null;
    _autoSwitching = true;
    try {
      await attempt(targetResumePosition);
    } finally {
      _autoSwitching = false;
      if (_autoSwitchRetryPending && !_disposed) {
        _autoSwitchRetryPending = false;
        final pendingResumePosition = _pendingAutoSwitchResumePosition;
        _pendingAutoSwitchResumePosition = null;
        scheduleMicrotask(
          () => runAutoSwitch(
            resumePosition: pendingResumePosition,
            attempt: attempt,
          ),
        );
      }
    }
  }

  void clearPendingAutoSwitch() {
    _autoSwitchRetryPending = false;
    _pendingAutoSwitchResumePosition = null;
  }

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
    clearPendingAutoSwitch();
  }
}
