import 'package:anime/src/player/video/native_video_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
