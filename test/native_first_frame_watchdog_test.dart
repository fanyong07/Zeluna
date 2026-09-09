import 'package:media_kit/media_kit.dart';
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
    'startup samples current backend buffering after early events were rejected',
    (tester) async {
      final media = Media('https://media.test/episode.m3u8');
      final guard = NativeMediaEventGuard()
        ..beginOpen(openSerial: 2, mediaUri: media.uri);
      // Buffering can arrive before the playlist confirms the media identity.
      expect(
        guard.acceptsValue(
          currentOpenSerial: 2,
          playerMediaUri: null,
          eventValue: true,
          playerStateValue: true,
        ),
        isFalse,
      );
      guard.finishOpen(openSerial: 2);
      final backend = PlayerState().copyWith(
        playlist: Playlist([media]),
        playing: true,
        buffering: true,
      );
      final watchdog = NativeFirstFrameWatchdog();
      addTearDown(watchdog.dispose);
      final events = <NativeStartupTimeoutEvent>[];
      watchdog.start(
        isCurrent: () => true,
        readSnapshot: () => guard.readStartupSnapshot(
          currentOpenSerial: 2,
          playerState: backend,
          hasAlternative: true,
        ),
        onTimeout: events.add,
        softTimeout: const Duration(seconds: 7),
        hardTimeout: const Duration(seconds: 25),
      );
      await tester.pump(const Duration(seconds: 7));
      expect(
        events,
        isEmpty,
        reason:
            'Do not switch a still-buffering live stream using stale UI state.',
      );
      await tester.pump(const Duration(seconds: 18));
      expect(events.single.phase, NativeStartupTimeoutPhase.hard);
    },
  );

  test(
    'startup snapshot never attributes old media progress to a new open',
    () {
      final guard = NativeMediaEventGuard()
        ..beginOpen(openSerial: 3, mediaUri: 'https://media.test/new.mp4');
      final old = PlayerState().copyWith(
        playlist: Playlist([Media('https://media.test/old.mp4')]),
        position: const Duration(seconds: 42),
        playing: true,
      );
      for (final ready in [false, true]) {
        if (ready) guard.finishOpen(openSerial: 3);
        final snapshot = guard.readStartupSnapshot(
          currentOpenSerial: 3,
          playerState: old,
          hasAlternative: true,
        );
        expect(snapshot.position, Duration.zero);
        expect(snapshot.buffering, isTrue);
      }
    },
  );

  testWidgets(
    'sampled first frame confirms startup after early progress was rejected',
    (tester) async {
      final media = Media('https://media.test/episode.m3u8');
      final guard = NativeMediaEventGuard()
        ..beginOpen(openSerial: 2, mediaUri: media.uri);
      expect(
        guard.acceptsValue(
          currentOpenSerial: 2,
          playerMediaUri: null,
          eventValue: const Duration(seconds: 3),
          playerStateValue: const Duration(seconds: 3),
        ),
        isFalse,
      );
      guard.finishOpen(openSerial: 2);
      final backend = PlayerState().copyWith(
        playlist: Playlist([media]),
        playing: true,
        position: const Duration(seconds: 3),
      );
      final watchdog = NativeFirstFrameWatchdog();
      addTearDown(watchdog.dispose);
      final frames = <NativePlaybackStartupSnapshot>[];
      final errors = <NativeStartupTimeoutEvent>[];
      watchdog.start(
        isCurrent: () => true,
        readSnapshot: () => guard.readStartupSnapshot(
          currentOpenSerial: 2,
          playerState: backend,
          hasAlternative: true,
        ),
        onFirstFrame: frames.add,
        onTimeout: errors.add,
      );
      await tester.pump(const Duration(seconds: 7));
      expect(frames, hasLength(1));
      expect(frames.single.position, const Duration(seconds: 3));
      expect(watchdog.isActive, isFalse);
      expect(
        watchdog.handleProgress(
          previousPosition: Duration.zero,
          currentPosition: const Duration(seconds: 4),
        ),
        isFalse,
        reason: 'A later stream event must not confirm the same frame twice.',
      );
      await tester.pump(const Duration(seconds: 30));
      expect(frames, hasLength(1));
      expect(errors, isEmpty);
    },
  );

  for (final end in ['cancel', 'dispose', 'stale', 'replace']) {
    testWidgets('sampled first frame respects $end lifecycle', (tester) async {
      final watchdog = NativeFirstFrameWatchdog();
      addTearDown(watchdog.dispose);
      var current = true;
      var oldFrames = 0;
      var newFrames = 0;
      var errors = 0;
      watchdog.start(
        isCurrent: () => current,
        readSnapshot: () => _snapshot(position: const Duration(seconds: 1)),
        onFirstFrame: (_) => oldFrames++,
        onTimeout: (_) => errors++,
      );
      switch (end) {
        case 'cancel':
          watchdog.cancel();
        case 'dispose':
          watchdog.dispose();
        case 'stale':
          current = false;
        case 'replace':
          watchdog.start(
            isCurrent: () => true,
            readSnapshot: () => _snapshot(position: const Duration(seconds: 2)),
            onFirstFrame: (_) => newFrames++,
            onTimeout: (_) => errors++,
          );
      }
      await tester.pump(const Duration(seconds: 30));
      expect(oldFrames, 0);
      expect(newFrames, end == 'replace' ? 1 : 0);
      expect(errors, 0);
      expect(watchdog.isActive, isFalse);
    });
  }

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
