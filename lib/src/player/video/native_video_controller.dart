import 'dart:async';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../playback_line_display.dart';

/// Rejects shared media-kit stream events while a media open is being
/// replaced, and after a newer open has taken ownership of the player.
final class NativeMediaEventGuard {
  int? _openSerial;
  String? _mediaUri;
  var _ready = false;

  bool get isTransitioning => _openSerial != null && !_ready;

  void beginOpen({required int openSerial, required String mediaUri}) {
    _openSerial = openSerial;
    _mediaUri = mediaUri;
    _ready = false;
  }

  void finishOpen({required int openSerial}) {
    if (_openSerial == openSerial) _ready = true;
  }

  void invalidate() {
    _openSerial = null;
    _mediaUri = null;
    _ready = false;
  }

  bool isCurrent({
    required int currentOpenSerial,
    required String? playerMediaUri,
  }) {
    return _ready &&
        _openSerial == currentOpenSerial &&
        _mediaUri != null &&
        _mediaUri == playerMediaUri;
  }

  bool acceptsValue<T>({
    required int currentOpenSerial,
    required String? playerMediaUri,
    required T eventValue,
    required T playerStateValue,
  }) {
    return isCurrent(
          currentOpenSerial: currentOpenSerial,
          playerMediaUri: playerMediaUri,
        ) &&
        eventValue == playerStateValue;
  }
}

/// Owns delayed native resume seeks and rejects work from stale media opens.
final class NativeResumeSeekController {
  NativeResumeSeekController({
    required int Function() readOpenSerial,
    required Future<void> Function(Duration) seek,
    Duration initialDelay = const Duration(milliseconds: 250),
    Duration retryDelay = const Duration(seconds: 2),
    int maxAttempts = 15,
  }) : _readOpenSerial = readOpenSerial,
       _seek = seek,
       _initialDelay = initialDelay,
       _retryDelay = retryDelay,
       _maxAttempts = maxAttempts;

  final int Function() _readOpenSerial;
  final Future<void> Function(Duration) _seek;
  final Duration _initialDelay;
  final Duration _retryDelay;
  final int _maxAttempts;

  Timer? _timer;
  Duration? _target;
  int? _openSerial;
  int _attempts = 0;
  int _generation = 0;
  bool _seeking = false;
  bool _disposed = false;

  Timer? get timer => _timer;
  Duration? get target => _target;
  int get attempts => _attempts;
  bool get isPending => _target != null;
  bool get isSeeking => _seeking;
  bool get isDisposed => _disposed;

  Duration recoveryPosition(Duration current) {
    final target = _target;
    final position = target != null && target > current ? target : current;
    return playbackRecoveryPosition(position);
  }

  void arm({required int openSerial, required Duration position}) {
    if (_disposed) return;
    cancel();
    _target = position;
    _openSerial = openSerial;
    _schedule(_initialDelay);
  }

  void nudge({bool mediaReady = false}) {
    if (_disposed || _openSerial != _readOpenSerial()) return;
    if (mediaReady) {
      _timer?.cancel();
      _timer = null;
      if (_attempts >= _maxAttempts) _attempts = 0;
    }
    _schedule(Duration.zero);
  }

  void handleProgress(Duration value) {
    final target = _target;
    if (_disposed || target == null || _openSerial != _readOpenSerial()) {
      return;
    }
    if (value >= target - const Duration(seconds: 2)) {
      cancel();
      return;
    }
    if (value > Duration.zero) nudge();
  }

  void cancel() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _target = null;
    _openSerial = null;
    _attempts = 0;
    _seeking = false;
  }

  void _schedule(Duration delay) {
    if (_disposed ||
        _target == null ||
        _seeking ||
        _attempts >= _maxAttempts ||
        _timer != null) {
      return;
    }
    _timer = Timer(delay, () {
      _timer = null;
      if (!_disposed) unawaited(_apply());
    });
  }

  Future<void> _apply() async {
    final generation = _generation;
    final position = _target;
    final serial = _openSerial;
    if (_disposed ||
        position == null ||
        serial == null ||
        serial != _readOpenSerial() ||
        _seeking ||
        _attempts >= _maxAttempts) {
      return;
    }
    _seeking = true;
    _attempts++;
    try {
      await _seek(position);
    } catch (_) {
      // Some demuxers reject seeking until duration or the first frame exists.
    } finally {
      if (generation == _generation) _seeking = false;
    }
    if (!_disposed &&
        generation == _generation &&
        serial == _readOpenSerial() &&
        _target != null) {
      _schedule(_retryDelay);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    cancel();
  }
}

enum NativeStartupTimeoutPhase { soft, hard }

final class NativePlaybackStartupSnapshot {
  const NativePlaybackStartupSnapshot({
    required this.playing,
    required this.position,
    required this.buffer,
    required this.buffering,
    required this.hasAlternative,
  });

  final bool playing;
  final Duration position;
  final Duration buffer;
  final bool buffering;
  final bool hasAlternative;
}

final class NativeStartupTimeoutEvent {
  const NativeStartupTimeoutEvent({
    required this.phase,
    required this.hasAlternative,
  });

  final NativeStartupTimeoutPhase phase;
  final bool hasAlternative;
}

/// Owns native first-frame timeout polling independently from page state.
final class NativeFirstFrameWatchdog {
  Timer? _timer;
  var _generation = 0;
  var _disposed = false;

  bool get isActive => _timer != null;
  bool get isDisposed => _disposed;

  void start({
    required bool Function() isCurrent,
    required NativePlaybackStartupSnapshot Function() readSnapshot,
    required void Function(NativeStartupTimeoutEvent event) onTimeout,
    Duration softTimeout = const Duration(seconds: 7),
    Duration hardTimeout = const Duration(seconds: 25),
    Duration pollInterval = const Duration(seconds: 1),
  }) {
    cancel();
    if (_disposed) return;
    assert(softTimeout > Duration.zero);
    assert(hardTimeout >= softTimeout);
    assert(pollInterval > Duration.zero);
    final generation = _generation;

    late void Function(Duration delay, Duration elapsed) schedule;
    schedule = (delay, elapsed) {
      if (_disposed || generation != _generation) return;
      _timer = Timer(delay, () {
        _timer = null;
        if (_disposed || generation != _generation || !isCurrent()) return;
        final snapshot = readSnapshot();
        if (nativePlaybackHasFirstFrame(
          playing: snapshot.playing,
          position: snapshot.position,
        )) {
          return;
        }
        final hardTimedOut = elapsed >= hardTimeout;
        if (!hardTimedOut &&
            !nativePlaybackShouldSwitchAtSoftTimeout(
              position: snapshot.position,
              buffer: snapshot.buffer,
              buffering: snapshot.buffering,
              hasAlternative: snapshot.hasAlternative,
            )) {
          final remaining = hardTimeout - elapsed;
          final nextDelay = remaining < pollInterval ? remaining : pollInterval;
          schedule(nextDelay, elapsed + nextDelay);
          return;
        }
        onTimeout(
          NativeStartupTimeoutEvent(
            phase: hardTimedOut
                ? NativeStartupTimeoutPhase.hard
                : NativeStartupTimeoutPhase.soft,
            hasAlternative: snapshot.hasAlternative,
          ),
        );
      });
    };
    schedule(softTimeout, softTimeout);
  }

  bool handleProgress({
    required Duration previousPosition,
    required Duration currentPosition,
  }) {
    if (_disposed ||
        _timer == null ||
        !nativePlaybackReachedFirstFrame(
          previousPosition: previousPosition,
          currentPosition: currentPosition,
        )) {
      return false;
    }
    cancel();
    return true;
  }

  void cancel() {
    _generation++;
    _timer?.cancel();
    _timer = null;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    cancel();
  }
}

/// Owns the native media-kit objects and every subscription/timer tied to
/// their lifetime. UI code may subscribe through [track], but it never disposes
/// individual native resources itself.
final class NativeVideoController {
  NativeVideoController({int Function()? readOpenSerial}) : player = Player() {
    surfaceController = VideoController(player);
    resumeSeek = NativeResumeSeekController(
      readOpenSerial: readOpenSerial ?? () => 0,
      seek: player.seek,
    );
  }

  final Player player;
  late final VideoController surfaceController;
  late final NativeResumeSeekController resumeSeek;
  final NativeFirstFrameWatchdog _firstFrameWatchdog =
      NativeFirstFrameWatchdog();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  bool _disposed = false;

  bool get isDisposed => _disposed;
  bool get awaitingFirstFrame => _firstFrameWatchdog.isActive;

  void track(StreamSubscription<dynamic> subscription) {
    if (_disposed) {
      unawaited(subscription.cancel());
      return;
    }
    _subscriptions.add(subscription);
  }

  void startFirstFrameWatchdog({
    required bool Function() isCurrent,
    required NativePlaybackStartupSnapshot Function() readSnapshot,
    required void Function(NativeStartupTimeoutEvent event) onTimeout,
  }) {
    if (_disposed) return;
    _firstFrameWatchdog.start(
      isCurrent: isCurrent,
      readSnapshot: readSnapshot,
      onTimeout: onTimeout,
    );
  }

  bool handlePlaybackProgress({
    required Duration previousPosition,
    required Duration currentPosition,
  }) {
    return _firstFrameWatchdog.handleProgress(
      previousPosition: previousPosition,
      currentPosition: currentPosition,
    );
  }

  void cancelFirstFrameWatchdog() {
    _firstFrameWatchdog.cancel();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _firstFrameWatchdog.dispose();
    resumeSeek.dispose();
    final subscriptions = List.of(_subscriptions);
    _subscriptions.clear();
    await Future.wait(subscriptions.map((item) => item.cancel()));
    await player.dispose();
  }
}
