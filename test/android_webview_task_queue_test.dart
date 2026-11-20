import 'package:anime/src/rules/android_webview_task_queue.dart';
import 'package:anime/src/rules/rule_playback_cancellation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'quarantine drains waiters and never admits after failed native teardown',
    () async {
      final queue = AndroidWebViewTaskQueue();
      final first = await queue.acquire(timeout: const Duration(seconds: 10));
      final waiting = queue.acquire(timeout: const Duration(seconds: 10));
      queue.quarantine();
      expect(first!.cancellation.isCancelled, isTrue);
      expect(await waiting, isNull);
      first.release();
      expect(await queue.acquire(timeout: const Duration(seconds: 10)), isNull);
      queue.quarantine();
    },
  );

  testWidgets('one active lease, bounded waiting, and FIFO admission', (
    tester,
  ) async {
    final queue = AndroidWebViewTaskQueue(maxWaiting: 1);
    final first = await queue.acquire(timeout: const Duration(seconds: 10));
    var secondReady = false;
    final second = queue.acquire(timeout: const Duration(seconds: 10))
      ..then((_) => secondReady = true);
    expect(await queue.acquire(timeout: const Duration(seconds: 10)), isNull);
    await tester.pump();
    expect(secondReady, isFalse);
    first!.release();
    (await second)!.release();
  });

  testWidgets('waiting cancellation and timeout do not wait for active task', (
    tester,
  ) async {
    final queue = AndroidWebViewTaskQueue(maxWaiting: 2);
    final first = await queue.acquire(timeout: const Duration(seconds: 10));
    final token = RulePlaybackCancellationToken();
    final cancelled = queue.acquire(
      timeout: const Duration(seconds: 10),
      cancellationToken: token,
    );
    final timedOut = queue.acquire(timeout: const Duration(seconds: 1));
    token.cancel();
    expect(await cancelled, isNull);
    await tester.pump(const Duration(seconds: 1));
    expect(await timedOut, isNull);
    expect(first!.cancellation.isCancelled, isFalse);
    first.release();
    (await queue.acquire(timeout: const Duration(seconds: 1)))!.release();
  });

  testWidgets('active cancellation retains lane until teardown releases it', (
    tester,
  ) async {
    final queue = AndroidWebViewTaskQueue();
    final first = await queue.acquire(timeout: const Duration(seconds: 1));
    var admitted = false;
    final next = queue.acquire(timeout: const Duration(seconds: 5))
      ..then((_) => admitted = true);
    await tester.pump(const Duration(seconds: 1));
    expect(first!.cancellation.isCancelled, isTrue);
    expect(admitted, isFalse);
    first.release();
    (await next)!.release();
    first.release(); // idempotent: never releases another task's lane.
  });
}
