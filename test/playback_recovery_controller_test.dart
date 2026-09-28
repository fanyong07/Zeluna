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

  test('a blocked recovery never triggers while the user pause is active', () {
    var now = DateTime.utc(2026, 1, 1);
    final controller = PlaybackRecoveryController(now: () => now);
    addTearDown(controller.dispose);
    controller.resetStallWatchdog(position: const Duration(minutes: 2));
    now = now.add(const Duration(minutes: 1));

    expect(
      controller.shouldRecoverFromStall(
        recoveryBlocked: true,
        appInForeground: true,
        playing: true,
        buffering: true,
        loading: false,
        playbackFailed: false,
        position: const Duration(minutes: 2),
        duration: const Duration(minutes: 20),
        buffer: const Duration(minutes: 2),
      ),
      isFalse,
    );
  });

  test('queued recovery keeps the new manual selection epoch', () async {
    final controller = PlaybackRecoveryController();
    final oldVerification = Completer<void>();
    addTearDown(() {
      controller.dispose();
      if (!oldVerification.isCompleted) oldVerification.complete();
    });
    var epoch = 0;
    final oldEpoch = epoch;
    var oldAttempts = 0;
    final recoveredPositions = <Duration>[];
    final running = controller.runAutoSwitch(
      attempt: (_) async {
        oldAttempts++;
        if (oldEpoch != epoch) return;
        await oldVerification.future;
        if (oldEpoch != epoch) return;
        fail('The old automatic open must lose ownership after selection');
      },
    );
    expect(controller.isAutoSwitching, isTrue);

    // PlayerPage's manual selection invalidates the old epoch and pending work.
    epoch++;
    controller.clearPendingAutoSwitch();
    final selectedEpoch = epoch;
    // The manually selected line fails before the old verification completes.
    await controller.runAutoSwitch(
      resumePosition: const Duration(seconds: 37),
      attempt: (position) async {
        if (selectedEpoch != epoch) return;
        recoveredPositions.add(position);
      },
    );
    expect(recoveredPositions, isEmpty);
    oldVerification.complete();
    await running;
    await Future<void>.delayed(Duration.zero);

    expect(
      recoveredPositions,
      [const Duration(seconds: 37)],
      reason: 'Retry the new selection, not the old epoch-bound closure',
    );
    expect(oldAttempts, 1);
    expect(controller.isAutoSwitching, isFalse);
  });

  test(
    'concurrent auto switches use latest attempt at furthest position',
    () async {
      final controller = PlaybackRecoveryController();
      addTearDown(controller.dispose);
      final firstAttempt = Completer<void>();
      final attempts = <({String owner, Duration position})>[];

      final running = controller.runAutoSwitch(
        resumePosition: const Duration(minutes: 1),
        attempt: (position) {
          attempts.add((owner: 'active', position: position));
          return firstAttempt.future;
        },
      );
      await controller.runAutoSwitch(
        resumePosition: const Duration(minutes: 3),
        attempt: (position) async =>
            attempts.add((owner: 'superseded', position: position)),
      );
      await controller.runAutoSwitch(
        resumePosition: const Duration(minutes: 2),
        attempt: (position) async =>
            attempts.add((owner: 'latest', position: position)),
      );
      firstAttempt.complete();
      await running;
      await Future<void>.delayed(Duration.zero);

      expect(attempts, [
        (owner: 'active', position: const Duration(minutes: 1)),
        (owner: 'latest', position: const Duration(minutes: 3)),
      ]);
      expect(controller.isAutoSwitching, isFalse);
    },
  );

  for (final cleanup in ['clear', 'dispose']) {
    test(
      '$cleanup cancels pending recovery after the active attempt finishes',
      () async {
        final controller = PlaybackRecoveryController();
        addTearDown(controller.dispose);
        final firstAttempt = Completer<void>();
        var pendingCalls = 0;
        final running = controller.runAutoSwitch(
          attempt: (_) => firstAttempt.future,
        );
        await controller.runAutoSwitch(
          resumePosition: const Duration(seconds: 23),
          attempt: (_) async => pendingCalls++,
        );
        // Both continuations observe completion before the queued retry is drained.
        final cleared = firstAttempt.future.then((_) {
          expect(controller.isAutoSwitching, isFalse);
          if (cleanup == 'dispose') {
            controller.dispose();
          } else {
            controller.clearPendingAutoSwitch();
          }
        });
        firstAttempt.complete();
        await cleared;
        await running;
        await Future<void>.delayed(Duration.zero);

        expect(pendingCalls, 0);
        expect(controller.isAutoSwitching, isFalse);
        expect(controller.isDisposed, cleanup == 'dispose');
      },
    );
  }

  for (final replaceBeforeCompletion in [false, true]) {
    test(
      'clear resets callback and position replacement=$replaceBeforeCompletion',
      () async {
        final controller = PlaybackRecoveryController();
        addTearDown(controller.dispose);
        final firstAttempt = Completer<void>();
        final positions = <Duration>[];
        var cancelledCalls = 0;
        final running = controller.runAutoSwitch(
          attempt: (_) => firstAttempt.future,
        );
        await controller.runAutoSwitch(
          resumePosition: const Duration(minutes: 9),
          attempt: (_) async => cancelledCalls++,
        );
        controller.clearPendingAutoSwitch();
        if (replaceBeforeCompletion) {
          await controller.runAutoSwitch(
            attempt: (position) async => positions.add(position),
          );
        }
        firstAttempt.complete();
        await running;
        await Future<void>.delayed(Duration.zero);
        if (!replaceBeforeCompletion) {
          expect(positions, isEmpty);
          await controller.runAutoSwitch(
            attempt: (position) async => positions.add(position),
          );
        }

        expect(cancelledCalls, 0);
        expect(positions, [Duration.zero]);
        expect(controller.isAutoSwitching, isFalse);
      },
    );
  }

  test('stall watchdog reset does not discard pending recovery', () async {
    final controller = PlaybackRecoveryController();
    addTearDown(controller.dispose);
    final firstAttempt = Completer<void>();
    final positions = <Duration>[];
    final running = controller.runAutoSwitch(
      attempt: (_) => firstAttempt.future,
    );
    await controller.runAutoSwitch(
      resumePosition: const Duration(seconds: 13),
      attempt: (position) async => positions.add(position),
    );
    controller.resetStallWatchdog(position: const Duration(seconds: 4));
    firstAttempt.complete();
    await running;
    await Future<void>.delayed(Duration.zero);

    expect(positions, [const Duration(seconds: 13)]);
    expect(controller.isAutoSwitching, isFalse);
  });

  test('active failure still drains the latest pending recovery', () async {
    final controller = PlaybackRecoveryController();
    addTearDown(controller.dispose);
    final firstAttempt = Completer<void>();
    final positions = <Duration>[];
    final running = controller.runAutoSwitch(
      attempt: (_) => firstAttempt.future,
    );
    final failure = expectLater(running, throwsStateError);
    await controller.runAutoSwitch(
      resumePosition: const Duration(seconds: 29),
      attempt: (position) async => positions.add(position),
    );
    firstAttempt.completeError(StateError('old verification failed'));
    await failure;
    await Future<void>.delayed(Duration.zero);

    expect(positions, [const Duration(seconds: 29)]);
    expect(controller.isAutoSwitching, isFalse);
  });

  test(
    'a new active request supersedes an undrained pending callback',
    () async {
      final controller = PlaybackRecoveryController();
      final firstAttempt = Completer<void>();
      final manualAttempt = Completer<void>();
      addTearDown(() {
        controller.dispose();
        if (!firstAttempt.isCompleted) firstAttempt.complete();
        if (!manualAttempt.isCompleted) manualAttempt.complete();
      });
      var oldPendingCalls = 0;
      var manualCalls = 0;
      final running = controller.runAutoSwitch(
        attempt: (_) => firstAttempt.future,
      );
      await controller.runAutoSwitch(attempt: (_) async => oldPendingCalls++);
      late Future<void> manual;
      final takeover = firstAttempt.future.then((_) {
        expect(controller.isAutoSwitching, isFalse);
        manual = controller.runAutoSwitch(
          attempt: (_) {
            manualCalls++;
            return manualAttempt.future;
          },
        );
      });
      firstAttempt.complete();
      await takeover;
      await running;
      await Future<void>.delayed(Duration.zero);
      expect(controller.isAutoSwitching, isTrue);
      expect(oldPendingCalls, 0);
      manualAttempt.complete();
      await manual;
      await Future<void>.delayed(Duration.zero);

      expect(oldPendingCalls, 0);
      expect(manualCalls, 1);
      expect(controller.isAutoSwitching, isFalse);
    },
  );

  for (final latestPosition in <Duration?>[
    null,
    const Duration(seconds: -1),
    const Duration(seconds: 2),
  ]) {
    test(
      'latest position $latestPosition retains the furthest queued position',
      () async {
        final controller = PlaybackRecoveryController();
        addTearDown(controller.dispose);
        final firstAttempt = Completer<void>();
        final positions = <Duration>[];
        final running = controller.runAutoSwitch(
          attempt: (_) => firstAttempt.future,
        );
        await controller.runAutoSwitch(
          resumePosition: const Duration(seconds: 19),
          attempt: (_) async => fail('This pending callback was superseded'),
        );
        await controller.runAutoSwitch(
          resumePosition: latestPosition,
          attempt: (position) async => positions.add(position),
        );
        firstAttempt.complete();
        await running;
        await Future<void>.delayed(Duration.zero);

        expect(positions, [const Duration(seconds: 19)]);
        expect(controller.isAutoSwitching, isFalse);
      },
    );
  }

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
