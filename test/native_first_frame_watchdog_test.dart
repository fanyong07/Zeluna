import 'package:anime/src/player/video/native_video_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native media events stay blocked across stop and open transitions', () {
    final guard = NativeMediaEventGuard();
    guard.beginOpen(openSerial: 4, mediaUri: 'https://media.test/ep2.mp4');

    expect(guard.isTransitioning, isTrue);
    expect(
      guard.acceptsValue(
        currentOpenSerial: 4,
        playerMediaUri: 'https://media.test/ep2.mp4',
        eventValue: true,
        playerStateValue: true,
      ),
      isFalse,
    );

    guard.finishOpen(openSerial: 4);
    expect(guard.isTransitioning, isFalse);
    expect(
      guard.acceptsValue(
        currentOpenSerial: 4,
        playerMediaUri: 'https://media.test/ep2.mp4',
        eventValue: const Duration(seconds: 1),
        playerStateValue: const Duration(seconds: 1),
      ),
      isTrue,
    );
  });

  test('native media events reject stale serial, uri, and state values', () {
    final guard = NativeMediaEventGuard()
      ..beginOpen(openSerial: 8, mediaUri: 'https://media.test/ep2.mp4')
      ..finishOpen(openSerial: 8);

    expect(
      guard.acceptsValue(
        currentOpenSerial: 9,
        playerMediaUri: 'https://media.test/ep2.mp4',
        eventValue: true,
        playerStateValue: true,
      ),
      isFalse,
    );
    expect(
      guard.acceptsValue(
        currentOpenSerial: 8,
        playerMediaUri: 'https://media.test/ep1.mp4',
        eventValue: true,
        playerStateValue: true,
      ),
      isFalse,
    );
    expect(
      guard.acceptsValue(
        currentOpenSerial: 8,
        playerMediaUri: 'https://media.test/ep2.mp4',
        eventValue: true,
        playerStateValue: false,
      ),
      isFalse,
    );
    expect(
      guard.acceptsValue(
        currentOpenSerial: 8,
        playerMediaUri: 'https://media.test/ep2.mp4',
        eventValue: const Duration(minutes: 22),
        playerStateValue: Duration.zero,
      ),
      isFalse,
    );
  });

  testWidgets(
    'native position progress confirms first frame and cancels timeout',
    (tester) async {
      final watchdog = NativeFirstFrameWatchdog();
      addTearDown(watchdog.dispose);
      final events = <NativeStartupTimeoutEvent>[];
      watchdog.start(
        isCurrent: () => true,
        readSnapshot: () => _snapshot(hasAlternative: true),
        onTimeout: events.add,
        softTimeout: const Duration(milliseconds: 15),
        hardTimeout: const Duration(milliseconds: 35),
        pollInterval: const Duration(milliseconds: 5),
      );

      expect(
        watchdog.handleProgress(
          previousPosition: Duration.zero,
          currentPosition: const Duration(milliseconds: 1),
        ),
        isTrue,
      );
      await tester.pump(const Duration(milliseconds: 30));

      expect(watchdog.isActive, isFalse);
      expect(events, isEmpty);
    },
  );

  testWidgets('native startup emits a soft timeout when a fallback is ready', (
    tester,
  ) async {
    final watchdog = NativeFirstFrameWatchdog();
    addTearDown(watchdog.dispose);
    final events = <NativeStartupTimeoutEvent>[];
    watchdog.start(
      isCurrent: () => true,
      readSnapshot: () => _snapshot(hasAlternative: true),
      onTimeout: events.add,
      softTimeout: const Duration(milliseconds: 10),
      hardTimeout: const Duration(milliseconds: 40),
      pollInterval: const Duration(milliseconds: 5),
    );
    await tester.pump(const Duration(milliseconds: 25));

    expect(events, hasLength(1));
    expect(events.single.phase, NativeStartupTimeoutPhase.soft);
    expect(events.single.hasAlternative, isTrue);
  });

  testWidgets('native buffer progress defers recovery until the hard timeout', (
    tester,
  ) async {
    final watchdog = NativeFirstFrameWatchdog();
    addTearDown(watchdog.dispose);
    final events = <NativeStartupTimeoutEvent>[];
    watchdog.start(
      isCurrent: () => true,
      readSnapshot: () =>
          _snapshot(buffer: const Duration(seconds: 2), hasAlternative: true),
      onTimeout: events.add,
      softTimeout: const Duration(milliseconds: 5),
      hardTimeout: const Duration(milliseconds: 25),
      pollInterval: const Duration(milliseconds: 5),
    );
    await tester.pump(const Duration(milliseconds: 45));

    expect(events, hasLength(1));
    expect(events.single.phase, NativeStartupTimeoutPhase.hard);
  });

  testWidgets('dispose prevents native first-frame timeout callbacks', (
    tester,
  ) async {
    final watchdog = NativeFirstFrameWatchdog();
    var callbacks = 0;
    watchdog.start(
      isCurrent: () => true,
      readSnapshot: () => _snapshot(hasAlternative: true),
      onTimeout: (_) => callbacks++,
      softTimeout: const Duration(milliseconds: 10),
      hardTimeout: const Duration(milliseconds: 20),
      pollInterval: const Duration(milliseconds: 5),
    );
    watchdog.dispose();
    await tester.pump(const Duration(milliseconds: 25));

    expect(watchdog.isDisposed, isTrue);
    expect(watchdog.isActive, isFalse);
    expect(callbacks, 0);
  });
}

NativePlaybackStartupSnapshot _snapshot({
  Duration position = Duration.zero,
  Duration buffer = Duration.zero,
  bool hasAlternative = false,
}) {
  return NativePlaybackStartupSnapshot(
    playing: true,
    position: position,
    buffer: buffer,
    buffering: false,
    hasAlternative: hasAlternative,
  );
}
