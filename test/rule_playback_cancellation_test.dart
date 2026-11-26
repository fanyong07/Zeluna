import 'package:anime/src/rules/rule_playback_cancellation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'cancellation is idempotent and callback failure does not stop others',
    () {
      final token = RulePlaybackCancellationToken();
      final calls = <String>[];
      token.register(() {
        calls.add('first');
        throw StateError('failed request cancellation');
      });
      token.register(() => calls.add('second'));
      expect(token.isCancelled, isFalse);
      token.cancel();
      token.cancel();
      expect(token.isCancelled, isTrue);
      expect(calls, ['first', 'second']);
    },
  );

  test('completed requests can unregister without cancelling other work', () {
    final token = RulePlaybackCancellationToken();
    final calls = <String>[];
    final unregister = token.register(() => calls.add('finished'));
    token.register(() => calls.add('active'));
    unregister();
    unregister();
    token.cancel();
    expect(calls, ['active']);
  });

  test('late registration immediately cancels instead of reviving work', () {
    final token = RulePlaybackCancellationToken()..cancel();
    var calls = 0;
    final unregister = token.register(() => calls++);
    token.register(() => throw StateError('late cancellation'));
    unregister();
    token.cancel();
    expect(calls, 1);
  });

  test('reentrant registration and cancellation run each callback once', () {
    final token = RulePlaybackCancellationToken();
    final calls = <String>[];
    token.register(() {
      calls.add('outer');
      token.register(() => calls.add('inner'));
      token.cancel();
    });
    token.cancel();
    expect(calls, ['outer', 'inner']);
  });
}
