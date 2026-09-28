import 'dart:async';
import 'dart:io';

import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/data/playback_source_repository.dart';
import 'package:anime/src/rules/rule_playback_cancellation.dart';
import 'package:anime/src/player/player_page.dart';
import 'package:anime/src/player/subtitles/subtitle_store.dart';
import 'package:anime/src/player/video/native_video_controller.dart' as owned;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../integration_test/support/isolated_player_environment.dart';

// Runs the real page, stream subscriptions, event ownership, timer and open
// paths. Only the platform engine/video texture and account persistence are
// isolated. Engine commands (not reducer output) are the regression oracle.
void main() {
  testWidgets('paused page ignores late current-media error retry', (
    tester,
  ) async {
    final fixture = await _mount(tester);
    // Use the real focused player shortcut, avoiding pointer gesture ambiguity.
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(fixture.engine.state.playing, isFalse);
    expect(fixture.engine.pauseCalls, 1);
    final opens = fixture.engine.opens.length;
    final plays = fixture.engine.playCalls;

    fixture.engine.fail('deterministic current-media failure');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();

    expect(
      fixture.engine.opens.length,
      opens,
      reason: 'A late error must not dispatch open(play:true) after UI pause',
    );
    expect(fixture.engine.playCalls, plays);
    expect(fixture.engine.state.playing, isFalse);
  });

  testWidgets(
    'playing intent retries and manual resume and reload remain allowed',
    (tester) async {
      final fixture = await _mount(tester);
      fixture.engine.fail('playing-intent failure');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expect(fixture.engine.opens, hasLength(2));
      expect(fixture.engine.opens.last.play, isFalse);
      expect(
        fixture.engine.state.playing,
        isTrue,
        reason: 'A safe paused open must still actually start playing',
      );
      fixture.engine.progress(const Duration(seconds: 2));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(fixture.engine.state.playing, isFalse);
      fixture.engine.fail('paused error before manual resume');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(fixture.engine.opens, hasLength(3));
      expect(fixture.engine.state.playing, isTrue);
      fixture.engine.progress(const Duration(seconds: 3));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(fixture.engine.state.playing, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
      await tester.pump();
      expect(fixture.engine.opens, hasLength(4));
      expect(fixture.engine.state.playing, isTrue);
      fixture.engine.progress(const Duration(seconds: 4));
      await tester.pump();
      fixture.engine.fail('manual reload restores playing recovery intent');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(fixture.engine.opens, hasLength(5));
    },
  );

  testWidgets('visible Pause action cancels an already queued retry', (
    tester,
  ) async {
    final fixture = await _mount(tester);
    // Capture the actual rendered Pause command before the asynchronous failure.
    // A command the user chose as Pause must not become Resume after an error.
    final pause = _pauseCommand(tester);
    fixture.engine.fail('error racing with explicit Pause input');
    await tester.pump();
    pause();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(fixture.engine.pauseCalls, 1);
    expect(fixture.engine.opens, hasLength(1));
    expect(fixture.engine.state.playing, isFalse);
  });

  testWidgets(
    'paused intent blocks immediate automatic switch with a ready backup',
    (tester) async {
      final fixture = await _mount(
        tester,
        account: _PauseAccount(online: true, quick: [_primary, _backup]),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(fixture.engine.state.playing, isFalse);
      fixture.engine.fail('paused current media has a verified backup');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(fixture.engine.opens, hasLength(1));
      expect(fixture.engine.state.playing, isFalse);
    },
  );

  testWidgets(
    'automatic verification completed after Pause does not open backup',
    (tester) async {
      final account = _PauseAccount(
        online: true,
        quick: [_primary, _unverifiedBackup],
      );
      final fixture = await _mount(tester, account: account);
      final pause = _pauseCommand(tester);
      account.verification = Completer<PlaybackLine>();
      fixture.engine.fail('playing failure starts automatic verification');
      await tester.pump();
      expect(account.blockedVerifications, 1);
      expect(fixture.engine.opens, hasLength(1));
      pause();
      await tester.pump();
      account.verification!.complete(_backup);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(fixture.engine.opens, hasLength(1));
      expect(fixture.engine.state.playing, isFalse);
    },
  );

  testWidgets(
    'expanded result after Pause updates inventory without autoplay',
    (tester) async {
      final account = _PauseAccount(online: true);
      final fixture = await _mount(tester, account: account);
      final pause = _pauseCommand(tester);
      fixture.engine.failNextOpen = true;
      fixture.engine.fail('first failure queues retry');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expect(account.expanded.hasListener, isTrue);
      expect(fixture.engine.opens, hasLength(2));
      pause();
      await tester.pump();
      account.expanded.add(
        const PlaybackLineLookupUpdate(
          lines: [_primary, _backup],
          completedRules: 1,
          totalRules: 1,
          phase: PlaybackLineLookupPhase.complete,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(fixture.engine.opens, hasLength(2));
      expect(fixture.engine.state.playing, isFalse);
    },
  );

  testWidgets('manual line selection after Pause opens chosen line', (
    tester,
  ) async {
    final fixture = await _mount(
      tester,
      account: _PauseAccount(online: true, quick: [_primary, _backup]),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(fixture.engine.state.playing, isFalse);
    await tester.tap(find.byTooltip('Primary fixture').first);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const ValueKey('pause-backup')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(fixture.engine.opens, hasLength(2));
    expect(fixture.engine.opens.last.uri, _backup.url);
    expect(fixture.engine.state.playing, isTrue);
  });

  testWidgets('R1 manual Play takes over pending automatic verification', (
    tester,
  ) async {
    final account = _PauseAccount(
      online: true,
      quick: [_primary, _unverifiedBackup],
    );
    final fixture = await _mount(tester, account: account);
    account.verification = Completer<PlaybackLine>();
    fixture.engine.fail('automatic backup verification');
    await tester.pump();
    expect(account.blockedVerifications, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    account.verification!.complete(_backup);
    await tester.pump();
    await tester.pump();
    expect(
      fixture.engine.opens.last.uri,
      _backup.url,
      reason: 'Play must open the requested backup, not play the old media',
    );
    expect(fixture.engine.opens, hasLength(2));
    await _expectReadyPlayback(tester, fixture);
  });

  testWidgets('R1 manual Play replaces pending automatic native open', (
    tester,
  ) async {
    final fixture = await _mount(
      tester,
      account: _PauseAccount(online: true, quick: [_primary, _backup]),
    );
    final gate = fixture.engine.delayNextOpen();
    fixture.engine.fail('automatic backup open');
    await tester.pump();
    expect(fixture.engine.blockedOpens, 1);
    expect(fixture.engine.appliedOpenUris, [fixture.engine.opens.first.uri]);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(
      fixture.engine.opens,
      hasLength(3),
      reason: 'Manual Play must own a new valid open, serial and event guard',
    );
    expect(fixture.engine.opens.last.uri, _backup.url);
    await _expectReadyPlayback(tester, fixture);
  });

  testWidgets('R2 Pause prevents delayed native open from ever unpausing', (
    tester,
  ) async {
    final fixture = await _mount(
      tester,
      account: _PauseAccount(online: true, quick: [_primary, _backup]),
    );
    final pause = _pauseCommand(tester);
    final gate = fixture.engine.delayNextOpen();
    fixture.engine.fail('automatic backup open before Pause');
    await tester.pump();
    expect(fixture.engine.blockedOpens, 1);
    expect(
      fixture.engine.appliedOpenUris,
      [fixture.engine.opens.first.uri],
      reason: 'The gate is before the engine side effect, not just its return',
    );
    final playingEffects = fixture.engine.playingEffects;
    pause();
    await tester.pump();
    gate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(
      fixture.engine.playingEffects,
      playingEffects,
      reason: 'Even a transient native unpause after Pause is forbidden',
    );
    expect(fixture.engine.state.playing, isFalse);
    final position = fixture.engine.state.position;
    fixture.engine.advanceIfPlaying(const Duration(seconds: 1));
    expect(fixture.engine.state.position, position);
  });

  testWidgets('R3 paused expanded scan can recover after manual resume fails', (
    tester,
  ) async {
    final account = _PauseAccount(online: true);
    final fixture = await _mount(tester, account: account);
    final pause = _pauseCommand(tester);
    fixture.engine.failNextOpen = true;
    fixture.engine.fail('first failure queues retry');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(account.expanded.hasListener, isTrue);
    expect(fixture.engine.opens, hasLength(2));
    pause();
    await tester.pump();
    fixture.engine.failNextOpen = true;
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(fixture.engine.opens, hasLength(3));
    account.expanded.add(
      const PlaybackLineLookupUpdate(
        lines: [_primary, _backup],
        completedRules: 1,
        totalRules: 1,
        phase: PlaybackLineLookupPhase.complete,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(
      fixture.engine.opens,
      hasLength(4),
      reason: 'The current playing recovery must be allowed to consume B',
    );
    expect(fixture.engine.opens.last.uri, _backup.url);
    await _expectReadyPlayback(tester, fixture);
  });
  testWidgets('R3 paused expanded scan can recover after manual reload fails', (
    tester,
  ) async {
    final account = _PauseAccount(online: true);
    final fixture = await _mount(tester, account: account);
    final pause = _pauseCommand(tester);
    fixture.engine.failNextOpen = true;
    fixture.engine.fail('first failure queues retry');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(account.expanded.hasListener, isTrue);
    expect(fixture.engine.opens, hasLength(2));
    pause();
    await tester.pump();
    fixture.engine.failNextOpen = true;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.pump();
    expect(fixture.engine.opens, hasLength(3));
    account.expanded.add(
      const PlaybackLineLookupUpdate(
        lines: [_primary, _backup],
        completedRules: 1,
        totalRules: 1,
        phase: PlaybackLineLookupPhase.complete,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(
      fixture.engine.opens,
      hasLength(4),
      reason: 'The current playing recovery must be allowed to consume B',
    );
    expect(fixture.engine.opens.last.uri, _backup.url);
    await _expectReadyPlayback(tester, fixture);
  });

  testWidgets(
    'normal initial playback and paused seek retain valid ownership',
    (tester) async {
      final fixture = await _mount(tester);
      expect(fixture.engine.state.playing, isTrue);
      final opens = fixture.engine.opens.length;
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      final playingEffects = fixture.engine.playingEffects;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(
        fixture.engine.state.position,
        greaterThan(const Duration(seconds: 15)),
      );
      expect(fixture.engine.state.playing, isFalse);
      expect(fixture.engine.playingEffects, playingEffects);
      expect(fixture.engine.opens, hasLength(opens));
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(
        fixture.engine.opens,
        hasLength(opens),
        reason: 'A valid paused media resumes directly, without reopening',
      );
      expect(fixture.engine.state.playing, isTrue);
    },
  );

  testWidgets(
    'R3 old expanded result cannot replace a newer manual selection',
    (tester) async {
      final account = _PauseAccount(online: true);
      final fixture = await _mount(tester, account: account);
      final pause = _pauseCommand(tester);
      fixture.engine.failNextOpen = true;
      fixture.engine.fail('retry exhaustion starts a scan');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expect(account.expanded.hasListener, isTrue);
      pause();
      await tester.pump();
      account.expanded.add(
        const PlaybackLineLookupUpdate(
          lines: [_primary, _backup],
          completedRules: 1,
          totalRules: 2,
          phase: PlaybackLineLookupPhase.verification,
        ),
      );
      await tester.pump();
      expect(fixture.engine.opens, hasLength(2));
      await tester.tap(find.byTooltip('Primary fixture').first);
      await tester.pump(const Duration(milliseconds: 400));
      final gate = fixture.engine.delayNextOpen();
      await tester.tap(find.byKey(const ValueKey('pause-backup')));
      await tester.pump();
      expect(fixture.engine.blockedOpens, 1);
      final opens = fixture.engine.opens.length;
      account.expanded.add(
        PlaybackLineLookupUpdate(
          lines: [
            _primary,
            _backup,
            const PlaybackLine(
              id: 'pause-stale-result',
              episodeId: -9002,
              providerId: 'integration:stale',
              providerName: 'Stale result',
              title: 'Stale result',
              quality: 'Original',
              format: 'avi',
              available: true,
              clientVerified: true,
              url: 'http://127.0.0.1:1/stale-result.avi',
            ),
          ],
          completedRules: 2,
          totalRules: 2,
          phase: PlaybackLineLookupPhase.complete,
        ),
      );
      await tester.pump();
      expect(fixture.engine.opens, hasLength(opens));
      gate.complete();
      await tester.pump();
      expect(fixture.engine.opens.last.uri, _backup.url);
      await _expectReadyPlayback(tester, fixture);
    },
  );

  for (final interrupt in ['Pause', 'manual selection']) {
    testWidgets(
      'R2 native lock queued resume loses permission after $interrupt',
      (tester) async {
        final fixture = await _mount(
          tester,
          nativeLock: true,
          account: _PauseAccount(online: true, quick: [_primary, _backup]),
        );
        final pause = _pauseCommand(tester);
        pause();
        await tester.pump();
        expect(fixture.engine.state.playing, isFalse);
        final held = Completer<void>();
        var entered = false;
        final blocker = NativePlayer.lock.synchronized(() async {
          entered = true;
          await held.future;
        });
        await tester.pump();
        expect(entered, isTrue);
        final plays = fixture.engine.playCalls;
        final effects = fixture.engine.playingEffects;
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pump();
        expect(
          fixture.engine.playingEffects,
          effects,
          reason: 'The real media-kit lock is held before the play side effect',
        );
        if (interrupt == 'Pause') {
          pause();
        } else {
          await tester.tap(find.byTooltip('Primary fixture').first);
          await tester.pump(const Duration(milliseconds: 400));
          await tester.tap(find.byKey(const ValueKey('pause-backup')));
        }
        await tester.pump();
        held.complete();
        await blocker;
        await tester.pump();
        await tester.pump();
        if (interrupt == 'Pause') {
          expect(
            fixture.engine.playingEffects,
            effects,
            reason:
                'A queued native play must be discarded, not play then pause',
          );
          expect(fixture.engine.playCalls, plays);
          expect(fixture.engine.state.playing, isFalse);
        } else {
          expect(
            fixture.engine.playingEffects,
            effects + 1,
            reason:
                'Only the latest selected media may receive play permission',
          );
          expect(fixture.engine.playCalls, plays + 1);
          expect(fixture.engine.opens.last.uri, _backup.url);
          await _expectReadyPlayback(tester, fixture);
        }
      },
    );
  }

  testWidgets('R2 native lock queued automatic play is revoked by Pause', (
    tester,
  ) async {
    final fixture = await _mount(
      tester,
      nativeLock: true,
      account: _PauseAccount(online: true, quick: [_primary, _backup]),
    );
    final pause = _pauseCommand(tester);
    final held = Completer<void>();
    Future<void>? blocker;
    var entered = false;
    fixture.engine.afterNextOpen = () {
      blocker = NativePlayer.lock.synchronized(() async {
        entered = true;
        await held.future;
      });
    };
    final effects = fixture.engine.playingEffects;
    fixture.engine.fail('automatic backup opens paused before lock contention');
    await tester.pump();
    expect(entered, isTrue);
    expect(
      fixture.engine.appliedOpenUris.last,
      _backup.url,
      reason: 'The native open already finished; only the play is queued',
    );
    expect(fixture.engine.state.playing, isFalse);
    expect(fixture.engine.playingEffects, effects);
    pause();
    await tester.pump();
    held.complete();
    await blocker;
    await tester.pump();
    await tester.pump();
    expect(
      fixture.engine.playingEffects,
      effects,
      reason: 'Open completion must not enqueue irrevocable native play',
    );
    expect(fixture.engine.state.playing, isFalse);
    final opens = fixture.engine.opens.length;
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(fixture.engine.opens, hasLength(opens + 1));
    await _expectReadyPlayback(tester, fixture);
  });
}

const _primary = PlaybackLine(
  id: 'pause-primary',
  episodeId: -9002,
  providerId: 'integration:primary',
  providerName: 'Primary fixture',
  title: 'Primary fixture',
  quality: 'Original',
  format: 'avi',
  url: 'file:///pause-fixture-primary.avi',
  available: true,
  clientVerified: true,
);

Future<_Fixture> _mount(
  WidgetTester tester, {
  _PauseAccount? account,
  bool nativeLock = false,
}) async {
  account ??= _PauseAccount();
  final activeAccount = account;
  final temp = (await tester.runAsync(() async {
    final temp = await Directory.systemTemp.createTemp('zeluna-pause-unit-');
    Hive.init('${temp.path}/hive');
    await SubtitleStore.open(null);
    return temp;
  }))!;
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  final engine = _RecordingEngine();
  final player = Player(
    platformPlayer: nativeLock ? _NativeLockEngine(engine) : engine,
  );
  final surface = _HeadlessSurface(player);

  const wakelockChannel =
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle';
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMessageHandler(
        wakelockChannel,
        (_) async => const StandardMessageCodec().encodeMessage([null]),
      );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    // An unused single-subscription stream has no consumer to finish close.
    unawaited(activeAccount.expanded.close());
    await tester.runAsync(() async {
      await Hive.close();
      await temp.delete(recursive: true);
    });
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(wakelockChannel, null);
    expect(engine.disposeCalls, 1, reason: 'Page owns the injected engine');
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [animeControllerProvider.overrideWith(() => activeAccount)],
      child: MaterialApp(
        theme: ThemeData.dark(),
        home: PlayerPage(
          nativeVideoControllerFactory: (readSerial) =>
              owned.NativeVideoController.forTesting(
                player: player,
                surfaceController: surface,
                readOpenSerial: readSerial,
              ),
          request: PlaySessionRequest(
            subject: account.online
                ? playerTestSubject.copyWith(source: 'integration')
                : playerTestSubject,
            episodes: const [playerTestEpisode],
            episode: playerTestEpisode,
            offlineOnly: !account.online,
            initialLine: _primary,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  expect(engine.opens, hasLength(1));
  engine.progress(const Duration(seconds: 15));
  await tester.pump();
  await tester.pump();
  expect(account.firstFrames, greaterThan(0));
  return _Fixture(engine, account);
}

Future<void> _expectReadyPlayback(WidgetTester tester, _Fixture fixture) async {
  expect(fixture.engine.state.playing, isTrue);
  fixture.engine.progress(const Duration(seconds: 7));
  await tester.pump();
  expect(
    find.text('0:07 / 3:00'),
    findsWidgets,
    reason: 'Current engine progress must reach the real page event guard',
  );
  expect(
    find.byType(CircularProgressIndicator),
    findsNothing,
    reason: 'The current open must finish loading',
  );
  final opens = fixture.engine.opens.length;
  for (var second = 8; second <= 38; second++) {
    fixture.engine.progress(Duration(seconds: second));
    await tester.pump(const Duration(seconds: 1));
  }
  expect(
    fixture.engine.opens,
    hasLength(opens),
    reason: 'No abandoned watchdog may retry the successfully resumed media',
  );
}

class _Fixture {
  _Fixture(this.engine, this.account);
  final _RecordingEngine engine;
  final _PauseAccount account;
}

class _RecordingEngine extends PlatformPlayer {
  _RecordingEngine() : super(configuration: const PlayerConfiguration());
  final opens = <({String uri, bool play})>[];
  bool failNextOpen = false;
  int playCalls = 0;
  int pauseCalls = 0;
  int disposeCalls = 0;

  Future<void> _tail = Future<void>.value();
  Completer<void>? _nextOpenGate;
  final appliedOpenUris = <String>[];
  int blockedOpens = 0;
  int playingEffects = 0;
  VoidCallback? afterNextOpen;

  Completer<void> delayNextOpen() => _nextOpenGate = Completer<void>();

  Future<void> _locked(Future<void> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  @override
  Future<void> open(Playable playable, {bool play = true}) {
    final media = playable as Media;
    opens.add((uri: media.uri, play: play));
    final gate = _nextOpenGate;
    _nextOpenGate = null;
    final failOpen = failNextOpen;
    failNextOpen = false;
    return _locked(() async {
      if (gate != null) {
        blockedOpens++;
        await gate.future;
      }
      if (failOpen) {
        throw StateError('fixture engine cannot open current media');
      }
      appliedOpenUris.add(media.uri);
      state = state.copyWith(
        playlist: Playlist([media]),
        playing: play,
        position: Duration.zero,
        duration: const Duration(minutes: 3),
      );
      if (play) playingEffects++;
      playlistController.add(state.playlist);
      playingController.add(play);
      durationController.add(state.duration);
      final afterOpen = afterNextOpen;
      afterNextOpen = null;
      afterOpen?.call();
    });
  }

  void advanceIfPlaying(Duration delta) {
    if (state.playing) progress(state.position + delta);
  }

  void fail(String message) => errorController.add(message);

  void progress(Duration value) {
    state = state.copyWith(position: value);
    positionController.add(value);
  }

  @override
  Future<void> play() {
    playCalls++;
    return _locked(() async {
      playingEffects++;
      state = state.copyWith(playing: true);
      playingController.add(true);
    });
  }

  @override
  Future<void> pause() {
    pauseCalls++;
    return _locked(() async {
      state = state.copyWith(playing: false);
      playingController.add(false);
    });
  }

  @override
  Future<void> playOrPause() => state.playing ? pause() : play();
  @override
  Future<void> stop() async {
    state = state.copyWith(playing: false, position: Duration.zero);
    playingController.add(false);
  }

  @override
  Future<void> seek(Duration duration) async => progress(duration);
  @override
  Future<void> setVolume(double volume) async {
    state = state.copyWith(volume: volume);
    volumeController.add(volume);
  }

  @override
  Future<void> setRate(double rate) async {
    state = state.copyWith(rate: rate);
    rateController.add(rate);
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    await super.dispose();
  }
}

// Uses the actual media-kit static native mutex without constructing libmpv.
// Commands take that same mutex exactly as NativePlayer does; bypassing the
// mutex is only valid for play called by the gate that already owns it.
class _NativeLockEngine implements NativePlayer {
  _NativeLockEngine(this.engine);
  final _RecordingEngine engine;

  @override
  PlayerState get state => engine.state;
  @override
  PlayerStream get stream => engine.stream;
  @override
  PlayerConfiguration get configuration => engine.configuration;
  @override
  Future<void> get waitForPlayerInitialization => Future<void>.value();
  @override
  Future<void> get waitForVideoControllerInitializationIfAttached =>
      Future<void>.value();

  @override
  Future<void> open(
    Playable playable, {
    bool play = true,
    bool synchronized = true,
  }) {
    if (!synchronized) return engine.open(playable, play: play);
    return NativePlayer.lock.synchronized(
      () => engine.open(playable, play: play),
    );
  }

  @override
  Future<void> play({bool synchronized = true}) {
    if (!synchronized) return engine.play();
    return NativePlayer.lock.synchronized(() => engine.play());
  }

  @override
  Future<void> pause({bool synchronized = true}) {
    if (!synchronized) return engine.pause();
    return NativePlayer.lock.synchronized(() => engine.pause());
  }

  @override
  Future<void> stop({
    bool open = false,
    bool notify = true,
    bool synchronized = true,
  }) => engine.stop();
  @override
  Future<void> seek(Duration position, {bool synchronized = true}) =>
      engine.seek(position);
  @override
  Future<void> setRate(double rate, {bool synchronized = true}) =>
      engine.setRate(rate);
  @override
  Future<void> setVolume(double volume, {bool synchronized = true}) =>
      engine.setVolume(volume);
  @override
  Future<void> dispose({bool synchronized = true}) => engine.dispose();
  @override
  Future<String> getProperty(
    String property, {
    bool waitForInitialization = true,
  }) async => '';
  @override
  Future<void> setProperty(
    String property,
    String value, {
    bool waitForInitialization = true,
  }) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _HeadlessSurface implements VideoController {
  _HeadlessSurface(this.player);
  @override
  final Player player;
  @override
  final platform = Completer<PlatformVideoController>();
  @override
  final notifier = ValueNotifier<PlatformVideoController?>(null);
  @override
  final id = ValueNotifier<int?>(null);
  @override
  final rect = ValueNotifier<Rect?>(null);
  @override
  Future<void> setSize({int? width, int? height}) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

VoidCallback _pauseCommand(WidgetTester tester) {
  final button = find
      .descendant(
        of: find.byTooltip('暂停').first,
        matching: find.byType(IconButton),
      )
      .first;
  return tester.widget<IconButton>(button).onPressed!;
}

const _backup = PlaybackLine(
  id: 'pause-backup',
  episodeId: -9002,
  providerId: 'integration:backup',
  providerName: 'Backup fixture',
  title: 'Backup fixture',
  quality: 'Original',
  format: 'avi',
  url: 'http://127.0.0.1:1/pause-backup.avi',
  available: true,
  clientVerified: true,
);
const _unverifiedBackup = PlaybackLine(
  id: 'pause-backup',
  episodeId: -9002,
  providerId: 'integration:backup',
  providerName: 'Backup fixture',
  title: 'Backup fixture',
  quality: 'Original',
  format: 'avi',
  url: 'http://127.0.0.1:1/pause-backup.avi',
  available: true,
);

class _PauseAccount extends IsolatedPlayerTestAccount {
  _PauseAccount({this.online = false, this.quick = const [_primary]});
  final bool online;
  final List<PlaybackLine> quick;
  final expanded = StreamController<PlaybackLineLookupUpdate>();
  Completer<PlaybackLine>? verification;
  int blockedVerifications = 0;
  @override
  Future<AnimeState> build() async => (await super.build()).copyWith(
    settings: const PlaybackSettings(
      rememberLine: false,
      autoNext: false,
      autoSwitchLine: true,
    ),
  );
  @override
  Future<List<PlaybackLine>> linesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    RulePlaybackCancellationToken? cancellationToken,
  }) async => quick;
  @override
  Stream<PlaybackLineLookupUpdate> lineUpdatesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    RulePlaybackCancellationToken? cancellationToken,
  }) => expanded.stream;
  @override
  Future<List<PlaybackLine>> prepareSingleBackupForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    required PlaybackLine currentLine,
    RulePlaybackCancellationToken? cancellationToken,
  }) async => [];
  @override
  Future<PlaybackLine> verifyPlaybackLine(
    PlaybackLine line, {
    bool enrichMetadata = true,
    bool forceRefresh = false,
    RulePlaybackCancellationToken? cancellationToken,
  }) async {
    if (forceRefresh && line.id == _backup.id && verification != null) {
      blockedVerifications++;
      return verification!.future;
    }
    return line;
  }
}
