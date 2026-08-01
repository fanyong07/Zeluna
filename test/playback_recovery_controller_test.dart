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
}
