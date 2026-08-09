import 'package:anime/src/player/playback_performance_trace.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('playback trace emits an anonymous monotonic attempt timeline', () {
    var now = DateTime.utc(2026, 8, 1, 12);
    final events = <Map<String, Object?>>[];
    final trace = PlaybackPerformanceTrace(
      attemptId: 'attempt-1',
      clock: () => now,
      sink: events.add,
    );

    trace.record('play_requested');
    now = now.add(const Duration(milliseconds: 375));
    trace.record(
      'first_frame',
      fields: const <String, Object?>{
        'provider': 'zeluna:primary',
        'format': 'hls',
      },
    );

    expect(events, hasLength(2));
    expect(events[0]['attempt_id'], 'attempt-1');
    expect(events[0]['elapsed_ms'], 0);
    expect(events[1]['elapsed_ms'], 375);
    expect(events[1]['provider'], 'zeluna:primary');
    expect(events[1], isNot(contains('url')));
    expect(events[1], isNot(contains('account')));
    expect(events[1], isNot(contains('headers')));
  });

  test(
    'playback trace records buffering duration without duplicate starts',
    () {
      var now = DateTime.utc(2026, 8, 1, 12);
      final events = <Map<String, Object?>>[];
      final trace = PlaybackPerformanceTrace(
        attemptId: 'attempt-buffering',
        clock: () => now,
        sink: events.add,
      );

      trace.recordBufferingChanged(
        buffering: true,
        fields: const {'provider': 'zeluna:primary'},
      );
      trace.recordBufferingChanged(buffering: true);
      now = now.add(const Duration(milliseconds: 840));
      trace.recordBufferingChanged(
        buffering: false,
        fields: const {'outcome': 'resumed'},
      );
      trace.recordBufferingChanged(buffering: false);

      expect(events.map((event) => event['event']), [
        'buffering_started',
        'buffering_ended',
      ]);
      expect(events.last['buffering_ms'], 840);
      expect(events.last['outcome'], 'resumed');
    },
  );

  test('playback trace drops sensitive fields and URL-shaped values', () {
    final events = <Map<String, Object?>>[];
    final trace = PlaybackPerformanceTrace(
      attemptId: 'attempt-redaction',
      clock: () => DateTime.utc(2026, 8, 1, 12),
      sink: events.add,
    );

    trace.record(
      'failure',
      fields: const <String, Object?>{
        'provider': 'zeluna:primary',
        'media_url': 'https://signed.example/video.m3u8?token=secret',
        'headers': {'Cookie': 'secret'},
        'access_token': 'secret',
        'authorization': 'Bearer secret',
        'referer': 'https://signed.example/private',
        'message': 'https://signed.example/private',
        'attempt_id': 'spoofed',
        'event': 'spoofed',
        'elapsed_ms': 999,
      },
    );

    expect(events.single['provider'], 'zeluna:primary');
    expect(events.single, isNot(contains('media_url')));
    expect(events.single, isNot(contains('headers')));
    expect(events.single, isNot(contains('access_token')));
    expect(events.single, isNot(contains('authorization')));
    expect(events.single, isNot(contains('referer')));
    expect(events.single, isNot(contains('message')));
    expect(events.single['attempt_id'], 'attempt-redaction');
    expect(events.single['event'], 'failure');
    expect(events.single['elapsed_ms'], 0);
  });

  test('playback trace drops signed queries and credential-shaped strings', () {
    final events = <Map<String, Object?>>[];
    final trace = PlaybackPerformanceTrace(
      attemptId: 'attempt-query-redaction',
      clock: () => DateTime.utc(2026, 8, 1, 12),
      sink: events.add,
    );

    trace.record(
      'warmup_failed',
      fields: const <String, Object?>{
        'reason_code': '/video.m3u8?expires=123&signature=private',
        'detail_code': 'Bearer private-credential',
        'status_code': 'https%3A%2F%2Fsigned.example%2Fvideo',
        'raw_exception': 'ClientException: token=private',
        'line_count': 2,
      },
    );

    expect(events.single, isNot(contains('reason_code')));
    expect(events.single, isNot(contains('detail_code')));
    expect(events.single, isNot(contains('status_code')));
    expect(events.single, isNot(contains('raw_exception')));
    expect(events.single['line_count'], 2);
  });

  test('continuity trace accepts only exact events and allowed fields', () {
    final events = <Map<String, Object?>>[];
    final trace = PlaybackPerformanceTrace(
      attemptId: 'attempt-continuity',
      clock: () => DateTime.utc(2026, 8, 1, 12),
      sink: events.add,
    );

    trace.recordContinuity(
      PlaybackContinuityTraceEvent.nextWarmupPrimaryReady,
      fields: const <String, Object?>{
        'provider': 'zeluna:primary',
        'line_count': 2,
        'next_episode_number': 12,
        'error_type': 'ClientException',
      },
    );
    trace.recordContinuity('unregistered_continuity_event');

    expect(events, hasLength(1));
    expect(
      events.single['event'],
      PlaybackContinuityTraceEvent.nextWarmupPrimaryReady,
    );
    expect(events.single['provider'], 'zeluna:primary');
    expect(events.single['line_count'], 2);
    expect(events.single, isNot(contains('next_episode_number')));
    expect(events.single, isNot(contains('error_type')));
  });

  test('continuity trace event registry matches the required matrix', () {
    expect(PlaybackContinuityTraceEvent.values, <String>{
      'next_warmup_started',
      'next_warmup_primary_ready',
      'next_warmup_fallback_ready',
      'next_warmup_refresh_started',
      'next_warmup_refresh_completed',
      'next_warmup_failed',
      'next_warmup_cancelled',
      'episode_transition_warmup_hit',
      'episode_transition_warmup_miss',
      'episode_transition_primary_open',
      'episode_transition_primary_failed',
      'episode_transition_fallback_hit',
      'episode_transition_fallback_failed',
    });
  });

  test('playback trace can be disabled and is bounded per attempt', () {
    final events = <Map<String, Object?>>[];
    final trace = PlaybackPerformanceTrace(
      attemptId: 'attempt-bounded',
      sink: events.add,
      maxEvents: 2,
    );
    trace.record('one');
    trace.record('two');
    trace.record('three');
    expect(events, hasLength(2));

    final disabled = PlaybackPerformanceTrace(
      attemptId: 'attempt-disabled',
      sink: events.add,
      enabled: false,
    );
    disabled.record('ignored');
    expect(events, hasLength(2));
  });
}
