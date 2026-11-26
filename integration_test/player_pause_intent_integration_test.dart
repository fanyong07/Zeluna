import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anime/src/app/desktop_window.dart';
import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/player/player_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'support/generated_player_video.dart';
import 'support/isolated_player_environment.dart';

// Cross-platform Windows/Android fixture. Default PlayerPage/native media-kit
// construction, real generated AVI decoding and UI input. No user stores,
// credentials, external upstream or OS-specific UI automation.
// Error-stream injection below is an explicit deterministic fault STIMULUS,
// not evidence that a real network/provider fault occurred.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native page preserves pause through late error and allows manual recovery',
    (tester) async {
      // Recommendation accounting is once-per-episode, not once-per-open.
      // Observe the production per-open trace alongside the real engine state.
      final originalDebugPrint = debugPrint;
      var decodedOpens = 0;
      var dispatchedOpens = 0;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null && message.startsWith('playback_trace ')) {
          final event = jsonDecode(message.substring('playback_trace '.length));
          if (event['event'] == 'first_frame') decodedOpens++;
          if (event['event'] == 'player_open_dispatched') dispatchedOpens++;
        }
        originalDebugPrint(message, wrapWidth: wrapWidth);
      };
      addTearDown(() => debugPrint = originalDebugPrint);
      MediaKit.ensureInitialized();
      await initializeDesktopWindow();
      final temp = await Directory.systemTemp.createTemp(
        'zeluna-pause-native-',
      );
      Hive.init('${temp.path}/hive');
      final clip = await writeGeneratedPlayerTestVideo(temp);
      final account = IsolatedPlayerTestAccount();
      final playingEvents = <bool>[];
      StreamSubscription<bool>? playingSubscription;
      addTearDown(() async {
        await playingSubscription?.cancel();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 500));
        await Hive.close();
        await temp.delete(recursive: true);
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [animeControllerProvider.overrideWith(() => account)],
          child: MaterialApp(
            theme: ThemeData.dark(),
            home: PlayerPage(
              request: PlaySessionRequest(
                subject: playerTestSubject,
                episodes: const [playerTestEpisode],
                episode: playerTestEpisode,
                offlineOnly: true,
                initialLine: PlaybackLine(
                  id: 'pause-native-fixture',
                  episodeId: playerTestEpisode.id,
                  providerId: 'integration:local',
                  providerName: 'Local pause fixture',
                  title: 'Generated pause fixture',
                  quality: 'Original',
                  format: 'avi',
                  url: clip.path,
                  available: true,
                  clientVerified: true,
                ),
              ),
            ),
          ),
        ),
      );
      await _until(
        tester,
        () =>
            find.byType(Video).evaluate().isNotEmpty && account.firstFrames > 0,
        'real native decoder produced a first frame',
      );
      final player = tester
          .widget<Video>(find.byType(Video).first)
          .controller
          .player;
      expect(player.platform, isA<NativePlayer>());
      playingSubscription = player.stream.playing.listen(playingEvents.add);
      await _until(
        tester,
        () => player.state.position > const Duration(seconds: 1),
        'real native position advances',
      );
      await _toggleThroughUi(tester, '暂停');
      await _until(
        tester,
        () => !player.state.playing,
        'UI pauses real engine',
      );
      await tester.pump(const Duration(milliseconds: 250));
      final pausedPosition = player.state.position;
      final framesBeforeError = decodedOpens;
      final opensBeforeError = dispatchedOpens;
      playingEvents.clear();

      // Deterministic fault injection only; all playback effects remain native.
      // ignore: invalid_use_of_protected_member
      player.platform!.errorController.add(
        'pause-fixture: deterministic late current-media error',
      );
      await tester.pump(const Duration(milliseconds: 150));
      // Longer than the 500ms retry and the normal opening-ignore interval.
      await tester.pump(const Duration(milliseconds: 1500));
      expect(
        player.state.playing,
        isFalse,
        reason: 'Late error cannot resume paused engine',
      );
      expect(
        playingEvents.where((value) => value),
        isEmpty,
        reason: 'No transient restart hidden by final paused state',
      );
      expect(
        decodedOpens,
        framesBeforeError,
        reason: 'No automatic reopen/decoded-first-frame while paused',
      );
      expect(
        (player.state.position - pausedPosition).inMilliseconds.abs(),
        lessThan(350),
      );
      debugPrint(
        'PAUSE_NATIVE ${jsonEncode({'platform': Platform.operatingSystem, 'engine': 'real media_kit NativePlayer', 'stimulus': 'injected current-media error stream', 'paused_after_error': true, 'transient_play_events': playingEvents.where((value) => value).length, 'position_delta_ms': (player.state.position - pausedPosition).inMilliseconds})}',
      );

      expect(
        dispatchedOpens,
        opensBeforeError,
        reason: 'No hidden automatic open while paused',
      );

      // Manual resume after failure must be an allowed new playback intent.
      await _toggleThroughUi(tester, '播放');
      await _until(
        tester,
        () =>
            player.state.playing &&
            decodedOpens > framesBeforeError &&
            player.state.position > const Duration(seconds: 1),
        'manual play reopens real media and decodes another first frame',
      );
      final resumeFrames = decodedOpens;
      final resumeOpens = dispatchedOpens;
      await tester.pump(const Duration(milliseconds: 900));
      // Positive control: same failure while user intent is playing DOES retry.
      // Deterministic fault injection only; all playback effects remain native.
      // ignore: invalid_use_of_protected_member
      player.platform!.errorController.add(
        'pause-fixture: deterministic playing-intent error',
      );
      await _until(
        tester,
        () =>
            decodedOpens > resumeFrames &&
            dispatchedOpens > resumeOpens &&
            player.state.playing &&
            player.state.position > const Duration(seconds: 1),
        'playing-intent automatic retry still opens and decodes',
      );
      debugPrint(
        'PAUSE_NATIVE ${jsonEncode({'platform': Platform.operatingSystem, 'manual_resume_decoded': true, 'playing_intent_retry_decoded': true, 'decoded_opens': decodedOpens, 'dispatched_opens': dispatchedOpens})}',
      );
    },
  );
}

Future<void> _until(
  WidgetTester tester,
  bool Function() predicate,
  String reason,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 25));
  while (!predicate() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(predicate(), isTrue, reason: reason);
}

Future<void> _toggleThroughUi(WidgetTester tester, String tooltip) async {
  if (Platform.isWindows) {
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
  } else {
    await tester.tap(find.byTooltip(tooltip).first);
  }
  await tester.pump(const Duration(milliseconds: 400));
}
