import 'dart:convert';

import 'package:flutter/foundation.dart';

typedef PlaybackTraceSink = void Function(Map<String, Object?> event);

/// Emits a small anonymous timeline for one playback attempt. It deliberately
/// excludes media URLs, titles, account identifiers and request headers.
class PlaybackPerformanceTrace {
  PlaybackPerformanceTrace({
    PlaybackTraceSink? sink,
    DateTime Function()? clock,
    String? attemptId,
  }) : _sink = sink ?? _debugSink,
       _clock = clock ?? DateTime.now,
       attemptId = attemptId ?? _nextAttemptId(clock ?? DateTime.now) {
    _startedAt = _clock();
  }

  static int _sequence = 0;

  final PlaybackTraceSink _sink;
  final DateTime Function() _clock;
  final String attemptId;
  late final DateTime _startedAt;

  void record(String event, {Map<String, Object?> fields = const {}}) {
    final now = _clock();
    _sink(<String, Object?>{
      'attempt_id': attemptId,
      'event': event,
      'elapsed_ms': now.difference(_startedAt).inMilliseconds,
      ...fields,
    });
  }

  static String _nextAttemptId(DateTime Function() clock) {
    final sequence = _sequence++;
    return '${clock().microsecondsSinceEpoch.toRadixString(36)}-'
        '${sequence.toRadixString(36)}';
  }

  static void _debugSink(Map<String, Object?> event) {
    debugPrint('playback_trace ${jsonEncode(event)}');
  }
}
