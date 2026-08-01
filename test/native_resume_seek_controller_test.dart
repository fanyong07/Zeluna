import 'dart:async';

import 'package:anime/src/player/video/native_video_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('resume seek retries until playback reaches the target', () async {
    var openSerial = 4;
    final seeks = <Duration>[];
    final controller = NativeResumeSeekController(
      readOpenSerial: () => openSerial,
      seek: (position) async => seeks.add(position),
      initialDelay: Duration.zero,
      retryDelay: const Duration(milliseconds: 5),
      maxAttempts: 3,
    );
    addTearDown(controller.dispose);

    controller.arm(
      openSerial: openSerial,
      position: const Duration(minutes: 8),
    );
    await Future<void>.delayed(const Duration(milliseconds: 12));
    expect(seeks, isNotEmpty);
    expect(seeks.every((value) => value == const Duration(minutes: 8)), isTrue);
    expect(controller.isPending, isTrue);

    controller.handleProgress(const Duration(minutes: 7, seconds: 59));
    expect(controller.isPending, isFalse);
    final seekCount = seeks.length;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(seeks, hasLength(seekCount));
    openSerial++;
  });

  test('stale opens and disposal reject delayed seek callbacks', () async {
    var openSerial = 1;
    var seeks = 0;
    final controller = NativeResumeSeekController(
      readOpenSerial: () => openSerial,
      seek: (_) async => seeks++,
      initialDelay: const Duration(milliseconds: 10),
    );

    controller.arm(
      openSerial: openSerial,
      position: const Duration(minutes: 2),
    );
    openSerial++;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(seeks, 0);

    controller.arm(
      openSerial: openSerial,
      position: const Duration(minutes: 3),
    );
    controller.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(controller.isDisposed, isTrue);
    expect(seeks, 0);
  });

  test('recovery position preserves a pending native target', () {
    var openSerial = 2;
    final controller = NativeResumeSeekController(
      readOpenSerial: () => openSerial,
      seek: (_) async {},
      initialDelay: const Duration(hours: 1),
    );
    addTearDown(controller.dispose);

    controller.arm(
      openSerial: openSerial,
      position: const Duration(minutes: 5),
    );
    expect(
      controller.recoveryPosition(const Duration(minutes: 1)),
      const Duration(minutes: 5),
    );
    expect(
      controller.recoveryPosition(const Duration(minutes: 7)),
      const Duration(minutes: 7),
    );
    openSerial++;
  });

  test('a cancelled seek cannot disturb a newer target', () async {
    const openSerial = 9;
    final firstSeek = Completer<void>();
    var calls = 0;
    final controller = NativeResumeSeekController(
      readOpenSerial: () => openSerial,
      seek: (_) {
        calls++;
        return calls == 1 ? firstSeek.future : Future<void>.value();
      },
      initialDelay: Duration.zero,
      retryDelay: const Duration(hours: 1),
    );
    addTearDown(controller.dispose);

    controller.arm(
      openSerial: openSerial,
      position: const Duration(minutes: 2),
    );
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);

    controller.cancel();
    controller.arm(
      openSerial: openSerial,
      position: const Duration(minutes: 3),
    );
    await Future<void>.delayed(Duration.zero);
    expect(calls, 2);
    firstSeek.complete();
    await Future<void>.delayed(Duration.zero);

    expect(controller.target, const Duration(minutes: 3));
    expect(controller.isPending, isTrue);
  });
}
