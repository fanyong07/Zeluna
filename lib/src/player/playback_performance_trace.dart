import 'dart:convert';

import 'package:flutter/foundation.dart';

typedef PlaybackTraceSink = void Function(Map<String, Object?> event);

abstract final class PlaybackContinuityTraceEvent {
  static const nextWarmupStarted = 'next_warmup_started';
  static const nextWarmupPrimaryReady = 'next_warmup_primary_ready';
  static const nextWarmupFallbackReady = 'next_warmup_fallback_ready';
  static const nextWarmupRefreshStarted = 'next_warmup_refresh_started';
  static const nextWarmupRefreshCompleted = 'next_warmup_refresh_completed';
  static const nextWarmupFailed = 'next_warmup_failed';
  static const nextWarmupCancelled = 'next_warmup_cancelled';
  static const episodeTransitionWarmupHit = 'episode_transition_warmup_hit';
  static const episodeTransitionWarmupMiss = 'episode_transition_warmup_miss';
  static const episodeTransitionPrimaryOpen = 'episode_transition_primary_open';
  static const episodeTransitionPrimaryFailed =
      'episode_transition_primary_failed';
  static const episodeTransitionFallbackHit = 'episode_transition_fallback_hit';
  static const episodeTransitionFallbackFailed =
      'episode_transition_fallback_failed';

  static const values = <String>{
    nextWarmupStarted,
    nextWarmupPrimaryReady,
    nextWarmupFallbackReady,
    nextWarmupRefreshStarted,
    nextWarmupRefreshCompleted,
    nextWarmupFailed,
    nextWarmupCancelled,
    episodeTransitionWarmupHit,
    episodeTransitionWarmupMiss,
    episodeTransitionPrimaryOpen,
    episodeTransitionPrimaryFailed,
    episodeTransitionFallbackHit,
    episodeTransitionFallbackFailed,
  };
}

const _playbackContinuityTraceFieldKeys = <String>{
  'provider',
  'preferred_provider',
  'elapsed_ms',
  'remaining_ms_bucket',
  'cache_age_ms',
  'warmup_age_bucket',
  'line_count',
  'fallback_count',
  'reason_code',
};

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

  void recordContinuity(
    String event, {
    Map<String, Object?> fields = const {},
  }) {
    if (!PlaybackContinuityTraceEvent.values.contains(event)) return;
    record(
      event,
      fields: <String, Object?>{
        for (final entry in fields.entries)
          if (_playbackContinuityTraceFieldKeys.contains(entry.key))
            entry.key: entry.value,
      },
    );
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
      'credential',
      'exception',
      'message',
      'stack',
    };
    final safe = <String, Object?>{};
    for (final entry in fields.entries) {
      final key = entry.key.trim();
      final normalizedKey = key.toLowerCase();
      if (key.isEmpty || blockedMarkers.any(normalizedKey.contains)) continue;
      final value = entry.value;
      if (value is String) {
        final normalizedValue = value.trim();
        if (_containsSensitiveValue(normalizedValue)) continue;
        safe[key] = normalizedValue.length <= 160
            ? normalizedValue
            : normalizedValue.substring(0, 160);
      } else if (value == null || value is num || value is bool) {
        safe[key] = value;
      }
    }
    return safe;
  }

  static bool _containsSensitiveValue(String value) {
    final normalized = value.toLowerCase();
    if (normalized.contains('://') ||
        normalized.contains('http%3a%2f%2f') ||
        normalized.contains('https%3a%2f%2f')) {
      return true;
    }
    if (RegExp(r'[?&][^&=\s]+=').hasMatch(value)) return true;
    return RegExp(
      r'(^|[\s,;])(?:bearer\s+|(?:access[_-]?token|refresh[_-]?token|authorization|cookie|password|secret|signature)\s*[:=])',
      caseSensitive: false,
    ).hasMatch(value);
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
