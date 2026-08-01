import 'dart:async';

import 'package:anime/src/player/lines/playback_recovery_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('backup and current-line retries replace older recovery work', () async {
    final controller = PlaybackRecoveryController();
    addTearDown(controller.dispose);
    var backupCallbacks = 0;
    var retryCallbacks = 0;

    controller.replaceBackupLookupTimer(
      Timer(const Duration(milliseconds: 5), () => backupCallbacks++),
    );
    controller.replaceBackupLookupTimer(
      Timer(const Duration(milliseconds: 15), () => backupCallbacks++),
    );
    controller.scheduleCurrentLineRetry(
      const Duration(milliseconds: 5),
      () => retryCallbacks++,
    );
    controller.scheduleCurrentLineRetry(
      const Duration(milliseconds: 15),
      () => retryCallbacks++,
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(backupCallbacks, 1);
    expect(retryCallbacks, 1);
  });

  test('dispose cancels every recovery callback', () async {
    final controller = PlaybackRecoveryController();
    var callbacks = 0;
    controller.startStallWatchdog(
      const Duration(milliseconds: 5),
      () => callbacks++,
    );
    controller.replaceBackupLookupTimer(
      Timer(const Duration(milliseconds: 5), () => callbacks++),
    );
    controller.scheduleCurrentLineRetry(
      const Duration(milliseconds: 5),
      () => callbacks++,
    );

    controller.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(controller.isDisposed, isTrue);
    expect(controller.backupLookupTimer, isNull);
    expect(callbacks, 0);
  });

  test('stall recovery owns progress timing, grace and cooldown', () {
    var now = DateTime.utc(2026, 1, 1);
    final controller = PlaybackRecoveryController(now: () => now);
    addTearDown(controller.dispose);
    controller.resetStallWatchdog(
      position: const Duration(minutes: 1),
      grace: const Duration(seconds: 5),
    );

    now = now.add(const Duration(seconds: 4));
    expect(
      controller.shouldRecoverFromStall(
        recoveryBlocked: false,
        appInForeground: true,
        playing: true,
        buffering: true,
        loading: false,
        playbackFailed: false,
        position: const Duration(minutes: 1),
        duration: const Duration(minutes: 20),
        buffer: const Duration(minutes: 1, seconds: 1),
      ),
      isFalse,
    );

    now = now.add(const Duration(seconds: 8));
    expect(
      controller.shouldRecoverFromStall(
        recoveryBlocked: false,
        appInForeground: true,
        playing: true,
        buffering: true,
        loading: false,
        playbackFailed: false,
        position: const Duration(minutes: 1),
        duration: const Duration(minutes: 20),
        buffer: const Duration(minutes: 1, seconds: 1),
      ),
      isTrue,
    );

    now = now.add(const Duration(seconds: 1));
    expect(
      controller.shouldRecoverFromStall(
        recoveryBlocked: false,
        appInForeground: true,
        playing: true,
        buffering: true,
        loading: false,
        playbackFailed: false,
        position: const Duration(minutes: 1),
        duration: const Duration(minutes: 20),
        buffer: const Duration(minutes: 1, seconds: 1),
      ),
      isFalse,
    );
  });

  test(
    'concurrent auto switches retry once at the furthest position',
    () async {
      final controller = PlaybackRecoveryController();
      addTearDown(controller.dispose);
      final firstAttempt = Completer<void>();
      final positions = <Duration>[];

      final running = controller.runAutoSwitch(
        resumePosition: const Duration(minutes: 1),
        attempt: (position) {
          positions.add(position);
          return positions.length == 1
              ? firstAttempt.future
              : Future<void>.value();
        },
      );
      await controller.runAutoSwitch(
        resumePosition: const Duration(minutes: 3),
        attempt: (_) async {},
      );
      await controller.runAutoSwitch(
        resumePosition: const Duration(minutes: 2),
        attempt: (_) async {},
      );
      firstAttempt.complete();
      await running;
      await Future<void>.delayed(Duration.zero);

      expect(positions, [
        const Duration(minutes: 1),
        const Duration(minutes: 3),
      ]);
    },
  );

  test('dispose prevents queued auto switch retries', () async {
    final controller = PlaybackRecoveryController();
    final firstAttempt = Completer<void>();
    var attempts = 0;
    final running = controller.runAutoSwitch(
      attempt: (_) {
        attempts++;
        return firstAttempt.future;
      },
    );
    await controller.runAutoSwitch(
      resumePosition: const Duration(minutes: 1),
      attempt: (_) async => attempts++,
    );
    controller.dispose();
    firstAttempt.complete();
    await running;
    await Future<void>.delayed(Duration.zero);

    expect(attempts, 1);
  });
}
