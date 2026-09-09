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

  testWidgets('exhausted resume releases stall recovery but preserves target', (
    tester,
  ) async {
    final controller = NativeResumeSeekController(
      readOpenSerial: () => 1,
      seek: (_) async {},
      initialDelay: Duration.zero,
      retryDelay: const Duration(seconds: 2),
      maxAttempts: 2,
    );
    addTearDown(controller.dispose);
    controller.arm(openSerial: 1, position: const Duration(minutes: 5));
    expect(controller.blocksStallRecovery, isTrue);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(controller.attempts, 2);
    expect(controller.blocksStallRecovery, isFalse);
    expect(
      controller.recoveryPosition(const Duration(minutes: 1)),
      const Duration(minutes: 5),
    );
    controller.nudge(mediaReady: true);
    expect(controller.blocksStallRecovery, isTrue);
    controller.dispose();
  });

  testWidgets(
    'hung native seek releases recovery without overlapping retries',
    (tester) async {
      final pendingSeek = Completer<void>();
      var calls = 0;
      final controller = NativeResumeSeekController(
        readOpenSerial: () => 1,
        seek: (_) {
          calls++;
          return pendingSeek.future;
        },
        initialDelay: Duration.zero,
      );
      addTearDown(controller.dispose);
      controller.arm(openSerial: 1, position: const Duration(minutes: 5));
      await tester.pump();
      expect(controller.blocksStallRecovery, isTrue);
      await tester.pump(const Duration(seconds: 10));
      expect(controller.blocksStallRecovery, isFalse);
      expect(controller.isSeeking, isFalse);
      expect(
        controller.recoveryPosition(Duration.zero),
        const Duration(minutes: 5),
      );
      controller.nudge(mediaReady: true);
      await tester.pump(const Duration(seconds: 30));
      expect(
        calls,
        1,
        reason: 'Do not queue commands behind the hung backend seek.',
      );
      expect(controller.blocksStallRecovery, isFalse);
      pendingSeek.complete();
      await tester.pump(const Duration(seconds: 10));
      expect(calls, 1);
      expect(controller.blocksStallRecovery, isFalse);
    },
  );

  testWidgets('old seek deadlines and completion cannot change a newer open', (
    tester,
  ) async {
    final oldSeek = Completer<void>();
    final newSeek = Completer<void>();
    var serial = 1;
    var calls = 0;
    final controller = NativeResumeSeekController(
      readOpenSerial: () => serial,
      seek: (_) => ++calls == 1 ? oldSeek.future : newSeek.future,
      initialDelay: Duration.zero,
      retryDelay: const Duration(hours: 1),
    );
    addTearDown(controller.dispose);
    controller.arm(openSerial: serial, position: const Duration(minutes: 1));
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    controller.arm(openSerial: ++serial, position: const Duration(minutes: 2));
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    expect(controller.isSeeking, isTrue);
    expect(controller.blocksStallRecovery, isTrue);
    oldSeek.completeError(StateError('old native seek failed'));
    await tester.pump();
    expect(controller.isSeeking, isTrue);
    expect(controller.target, const Duration(minutes: 2));
    newSeek.complete();
    await tester.pump();
    controller.handleProgress(const Duration(minutes: 2));
    expect(controller.isPending, isFalse);
    await tester.pump(const Duration(seconds: 10));
    expect(calls, 2);
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
