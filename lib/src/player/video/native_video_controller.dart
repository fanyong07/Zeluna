import 'dart:async';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../playback_line_display.dart';

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
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Timer? _firstFrameTimer;
  bool _disposed = false;

  bool get isDisposed => _disposed;
  bool get hasFirstFrameTimer => _firstFrameTimer != null;
  Timer? get firstFrameTimer => _firstFrameTimer;

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

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    clearFirstFrameTimer();
    resumeSeek.dispose();
    final subscriptions = List.of(_subscriptions);
    _subscriptions.clear();
    await Future.wait(subscriptions.map((item) => item.cancel()));
    await player.dispose();
  }
}
