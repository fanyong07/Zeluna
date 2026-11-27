import 'dart:async';

import 'package:flutter/foundation.dart';

enum SleepTimerMode { off, endOfEpisode, timed }

class SleepTimerController extends ChangeNotifier {
  SleepTimerController({required this.onTriggered});

  final VoidCallback onTriggered;
  SleepTimerMode _mode = SleepTimerMode.off;
  Duration? _countdown;
  Timer? _deadline;
  Timer? _ticks;

  SleepTimerMode get mode => _mode;
  bool get isActive => _mode != SleepTimerMode.off;
  Duration? get countdownDuration => _countdown;
  Duration? get remaining {
    if (_countdown == null) return null;
    final left = _countdown! - Duration(seconds: _ticks!.tick);
    return left.isNegative ? Duration.zero : left;
  }

  String get badgeLabel {
    if (_mode != SleepTimerMode.timed) return isActive ? '播完本集' : '';
    final seconds = (remaining!.inMilliseconds / 1000).ceil().clamp(0, 86400);
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  void _cancel() {
    _deadline?.cancel();
    _ticks?.cancel();
    _countdown = null;
  }

  void setOff() {
    _cancel();
    _mode = SleepTimerMode.off;
    notifyListeners();
  }

  void setEndOfEpisode() {
    _cancel();
    _mode = SleepTimerMode.endOfEpisode;
    notifyListeners();
  }

  void startCountdown(Duration duration) {
    assert(duration > Duration.zero);
    _cancel();
    _mode = SleepTimerMode.timed;
    _countdown = duration;
    _deadline = Timer(duration, () {
      setOff();
      onTriggered();
    });
    _ticks = Timer.periodic(
      const Duration(seconds: 1),
      (_) => notifyListeners(),
    );
    notifyListeners();
  }

  bool consumeEndOfEpisode() {
    if (_mode != SleepTimerMode.endOfEpisode) return false;
    setOff();
    return true;
  }

  @override
  void dispose() {
    _cancel();
    super.dispose();
  }
}
