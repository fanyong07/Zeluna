import 'package:anime/src/player/video/web_video_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('replacing a web startup watchdog cancels the previous attempt', (
    tester,
  ) async {
    final controller = WebVideoController();
    addTearDown(controller.dispose);
    final events = <WebStartupTimeoutEvent>[];

    void start(Duration softTimeout) {
      controller.startStartupWatchdog(
        isCurrent: () => true,
        waitingForReady: () => true,
        hasAlternative: () => true,
        onTimeout: events.add,
        softTimeout: softTimeout,
        hardTimeout: const Duration(milliseconds: 60),
      );
    }

    start(const Duration(milliseconds: 5));
    start(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 45));

    expect(events, hasLength(1));
    expect(events.single.phase, WebStartupTimeoutPhase.soft);
    expect(events.single.hasAlternative, isTrue);
  });

  testWidgets(
    'web startup waits until the hard timeout without an alternative',
    (tester) async {
      final controller = WebVideoController();
      addTearDown(controller.dispose);
      final events = <WebStartupTimeoutEvent>[];

      controller.startStartupWatchdog(
        isCurrent: () => true,
        waitingForReady: () => true,
        hasAlternative: () => false,
        onTimeout: events.add,
        softTimeout: const Duration(milliseconds: 5),
        hardTimeout: const Duration(milliseconds: 25),
      );
      await tester.pump(const Duration(milliseconds: 45));

      expect(events, hasLength(1));
      expect(events.single.phase, WebStartupTimeoutPhase.hard);
      expect(events.single.hasAlternative, isFalse);
    },
  );

  testWidgets('ready state and dispose prevent late web timeout callbacks', (
    tester,
  ) async {
    final controller = WebVideoController();
    var waiting = true;
    var callbacks = 0;
    controller.startStartupWatchdog(
      isCurrent: () => true,
      waitingForReady: () => waiting,
      hasAlternative: () => true,
      onTimeout: (_) => callbacks++,
      softTimeout: const Duration(milliseconds: 15),
      hardTimeout: const Duration(milliseconds: 30),
    );
    waiting = false;
    await tester.pump(const Duration(milliseconds: 25));
    controller.startStartupWatchdog(
      isCurrent: () => true,
      waitingForReady: () => true,
      hasAlternative: () => true,
      onTimeout: (_) => callbacks++,
      softTimeout: const Duration(milliseconds: 10),
      hardTimeout: const Duration(milliseconds: 20),
    );
    controller.dispose();
    await tester.pump(const Duration(milliseconds: 25));

    expect(controller.isDisposed, isTrue);
    expect(controller.startupWatchdogActive, isFalse);
    expect(callbacks, 0);
  });
}
