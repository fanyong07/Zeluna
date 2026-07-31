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
}
