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
    this.enabled = true,
    this.maxEvents = 128,
  }) : _sink = sink ?? _debugSink,
       _clock = clock ?? DateTime.now,
       attemptId = attemptId ?? _nextAttemptId(clock ?? DateTime.now) {
    _startedAt = _clock();
  }

  static int _sequence = 0;

  final PlaybackTraceSink _sink;
  final DateTime Function() _clock;
  final String attemptId;
  final bool enabled;
  final int maxEvents;
  late final DateTime _startedAt;
  DateTime? _bufferingStartedAt;
  var _eventCount = 0;

  void record(String event, {Map<String, Object?> fields = const {}}) {
    final now = _clock();
    _emit(event, now, fields);
  }

  void recordBufferingChanged({
    required bool buffering,
    Map<String, Object?> fields = const {},
  }) {
    final now = _clock();
    if (buffering) {
      if (_bufferingStartedAt != null) return;
      _bufferingStartedAt = now;
      _emit('buffering_started', now, fields);
      return;
    }
    final startedAt = _bufferingStartedAt;
    if (startedAt == null) return;
    _bufferingStartedAt = null;
    _emit('buffering_ended', now, <String, Object?>{
      ...fields,
      'buffering_ms': now.difference(startedAt).inMilliseconds,
    });
  }

  void _emit(String event, DateTime now, Map<String, Object?> fields) {
    if (!enabled || _eventCount >= maxEvents) return;
    _eventCount++;
    _sink(<String, Object?>{
      ..._safeFields(fields),
      'attempt_id': attemptId,
      'event': event,
      'elapsed_ms': now.difference(_startedAt).inMilliseconds,
    });
  }

  static Map<String, Object?> _safeFields(Map<String, Object?> fields) {
    const blockedMarkers = <String>{
      'url',
      'header',
      'cookie',
      'token',
      'authorization',
      'account',
      'email',
      'password',
      'referer',
      'origin',
      'user-agent',
      'signature',
      'secret',
      'private',
      'title',
    };
    final safe = <String, Object?>{};
    for (final entry in fields.entries) {
      final key = entry.key.trim();
      final normalizedKey = key.toLowerCase();
      if (key.isEmpty || blockedMarkers.any(normalizedKey.contains)) continue;
      final value = entry.value;
      if (value is String) {
        final normalizedValue = value.trim();
        if (normalizedValue.contains('://')) continue;
        safe[key] = normalizedValue.length <= 160
            ? normalizedValue
            : normalizedValue.substring(0, 160);
      } else if (value == null || value is num || value is bool) {
        safe[key] = value;
      }
    }
    return safe;
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
