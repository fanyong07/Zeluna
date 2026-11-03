import 'dart:async';
import 'dart:collection';

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
  final _bufferSamples = Queue<({DateTime end, Duration blocked})>();
  final _bufferEpisodes = Queue<DateTime>();
  DateTime? _bufferObservationStarted;
  DateTime? _lastBufferSample;
  bool _wasBuffering = false;
  bool lastRecoveryWasRepeatedBuffering = false;
  bool _autoSwitching = false;
  Future<void> Function(Duration resumePosition)? _pendingAutoSwitchAttempt;
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
    _resetBufferHealth();
  }

  void notePlaybackProgress(Duration value) {
    if (_disposed) return;
    final movedForward = value > _lastProgressPosition;
    final jumpedBackward =
        _lastProgressPosition - value > const Duration(seconds: 1);
    if (!movedForward && !jumpedBackward) return;
    if (jumpedBackward) _resetBufferHealth();
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
    if (_disposed) return false;
    final now = _now();
    final suppressedUntil = _stallSuppressedUntil;
    if (recoveryBlocked ||
        !appInForeground ||
        !playing ||
        loading ||
        playbackFailed ||
        position <= Duration.zero ||
        (duration > Duration.zero &&
            duration - position <= const Duration(seconds: 3)) ||
        (suppressedUntil != null && now.isBefore(suppressedUntil))) {
      _lastProgressAt = now;
      _lastProgressPosition = position;
      _resetBufferHealth();
      return false;
    }
    final lastRecovery = _lastStallRecoveryAt;
    final sinceLastRecovery = lastRecovery == null
        ? const Duration(days: 365)
        : now.difference(lastRecovery);
    final repeatedBuffering = _recordBufferHealth(
      now,
      buffering &&
          playbackBufferedAhead(position: position, buffer: buffer) <=
              playbackStallBufferThreshold,
    );
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
    if (!shouldRecover && !repeatedBuffering) return false;
    _lastStallRecoveryAt = now;
    resetStallWatchdog(
      position: position,
      grace: playbackStallRecoveryCooldown,
    );
    lastRecoveryWasRepeatedBuffering = repeatedBuffering;
    return true;
  }

  void _resetBufferHealth() {
    _bufferSamples.clear();
    _bufferEpisodes.clear();
    _bufferObservationStarted = null;
    _lastBufferSample = null;
    _wasBuffering = false;
  }

  // The existing one-second watchdog also catches a route that downloads a
  // second of video between repeated three/four-second stalls. Short progress
  // resets the continuous-stall clock, but must not erase this bounded window.
  bool _recordBufferHealth(DateTime now, bool buffering) {
    const window = Duration(seconds: 20);
    final previous = _lastBufferSample;
    if (previous != null &&
        now.difference(previous) > const Duration(seconds: 3)) {
      _resetBufferHealth();
    }
    _bufferObservationStarted ??= now;
    final last = _lastBufferSample;
    if (last != null && _wasBuffering) {
      _bufferSamples.add((end: now, blocked: now.difference(last)));
    }
    if (buffering && !_wasBuffering) _bufferEpisodes.add(now);
    _lastBufferSample = now;
    _wasBuffering = buffering;
    final cutoff = now.subtract(window);
    while (_bufferSamples.isNotEmpty &&
        !_bufferSamples.first.end.isAfter(cutoff)) {
      _bufferSamples.removeFirst();
    }
    while (_bufferEpisodes.isNotEmpty &&
        _bufferEpisodes.first.isBefore(cutoff)) {
      _bufferEpisodes.removeFirst();
    }
    final blocked = _bufferSamples.fold<Duration>(Duration.zero, (sum, sample) {
      final start = sample.end.subtract(sample.blocked);
      return sum +
          (start.isBefore(cutoff)
              ? sample.end.difference(cutoff)
              : sample.blocked);
    });
    return buffering &&
        now.difference(_bufferObservationStarted!) >=
            const Duration(seconds: 12) &&
        _bufferEpisodes.length >= 3 &&
        blocked >= const Duration(seconds: 8);
  }

  Future<void> runAutoSwitch({
    Duration? resumePosition,
    required Future<void> Function(Duration resumePosition) attempt,
  }) async {
    if (_disposed) return;
    if (_autoSwitching) {
      _pendingAutoSwitchAttempt = attempt;
      final pending = playbackRecoveryPosition(resumePosition ?? Duration.zero);
      if (pending > (_pendingAutoSwitchResumePosition ?? Duration.zero)) {
        _pendingAutoSwitchResumePosition = pending;
      }
      return;
    }
    final targetResumePosition = playbackRecoveryPosition(
      resumePosition ?? _pendingAutoSwitchResumePosition ?? Duration.zero,
    );
    clearPendingAutoSwitch();
    _autoSwitching = true;
    try {
      await attempt(targetResumePosition);
    } finally {
      _autoSwitching = false;
      if (_pendingAutoSwitchAttempt != null && !_disposed) {
        scheduleMicrotask(() {
          // Keep pending work revocable until dispatch, including manual resets.
          final pendingAttempt = _pendingAutoSwitchAttempt;
          if (_disposed || pendingAttempt == null) return;
          final pendingResumePosition = _pendingAutoSwitchResumePosition;
          clearPendingAutoSwitch();
          unawaited(
            runAutoSwitch(
              resumePosition: pendingResumePosition,
              attempt: pendingAttempt,
            ),
          );
        });
      }
    }
  }

  void clearPendingAutoSwitch() {
    _pendingAutoSwitchAttempt = null;
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
