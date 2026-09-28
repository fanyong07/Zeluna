import 'dart:convert';
import 'dart:io';

import 'package:anime/src/app/desktop_window.dart';
import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/player/app_fullscreen.dart';
import 'package:anime/src/player/player_page.dart';
import 'package:anime/src/player/video/native_video_compatibility.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'support/generated_player_video.dart';
import 'support/isolated_player_environment.dart';

// Opt-in device test: actual PlayerPage, native decoder, HTTP Range transport
// and fullscreen channel. Catalogue/account state and media are isolated, not
// external-provider or production-account evidence.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native playback controls and rapid episode transitions', (
    tester,
  ) async {
    MediaKit.ensureInitialized();
    await NativeVideoCompatibility.instance.initialize();
    await initializeDesktopWindow();
    final directory = await Directory.systemTemp.createTemp(
      'zeluna-native-qa-',
    );
    Hive.init('${directory.path}/hive');
    final fixture = await LoopbackPlayerVideo.start(
      await writeGeneratedPlayerTestVideo(directory),
    );
    final account = IsolatedPlayerTestAccount(mediaBase: fixture.baseUri);
    final evidence = <String, Object?>{
      'platform': Platform.operatingSystem,
      'transport': 'generated_loopback_http_range',
      'storage': 'isolated_temporary_hive',
      'catalogue': 'fixture_only',
    };
    binding.reportData = evidence;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 500));
      await fixture.close();
      await Hive.close();
      // Created by this test only; never the application's profile directory.
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [animeControllerProvider.overrideWith(() => account)],
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: PlayerPage(
            request: PlaySessionRequest(
              subject: playerTestSubject,
              episodes: const [playerTestEpisode, playerTestSecondEpisode],
              episode: playerTestEpisode,
              initialLine: account.lineFor(playerTestEpisode),
            ),
          ),
        ),
      ),
    );
    Future<void> until(bool Function() ready, String label) async {
      final end = DateTime.now().add(const Duration(seconds: 25));
      while (!ready() && DateTime.now().isBefore(end)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(ready(), isTrue, reason: label);
    }

    await until(() => account.firstFrames > 0, 'decoded first frame');
    final video = tester.widget<Video>(find.byType(Video).first);
    await video.controller.waitUntilFirstFrameRendered.timeout(
      const Duration(seconds: 15),
    );
    final player = video.controller.player;
    await until(
      () => player.state.position > const Duration(milliseconds: 600),
      'media time advances',
    );
    evidence['decoded_first_frame'] = true;
    Future<void> tapControl(String tooltip) async {
      if (find.byTooltip(tooltip).hitTestable().evaluate().isEmpty) {
        await tester.tapAt(tester.getCenter(find.byType(Video).first));
        await tester.pump(const Duration(milliseconds: 300));
      }
      await until(
        () => find.byTooltip(tooltip).hitTestable().evaluate().isNotEmpty,
        '$tooltip control visible',
      );
      await tester.tap(find.byTooltip(tooltip).hitTestable().first);
      await tester.pump(const Duration(milliseconds: 400));
    }

    await tapControl('暂停');
    await until(() => !player.state.playing, 'real pause button');
    final pausedPosition = player.state.position;
    await tester.pump(const Duration(milliseconds: 900));
    expect(
      (player.state.position - pausedPosition).inMilliseconds.abs(),
      lessThan(300),
    );
    evidence['pause_stable'] = true;
    await player.seek(const Duration(seconds: 15));
    await until(
      () => player.state.position >= const Duration(seconds: 14),
      'native seek while paused',
    );
    await player.setRate(1.5);
    await tapControl('播放');
    await until(() => player.state.playing, 'manual resume');
    evidence['seek_resume_rate'] = true;

    await tapControl('全屏');
    await until(
      () => find.byTooltip('退出全屏').evaluate().isNotEmpty,
      'fullscreen UI state',
    );
    if (Platform.isWindows) {
      expect(await AppFullscreenController().isEnabled(), isTrue);
    }
    await tapControl('退出全屏');
    await until(
      () => find.byTooltip('全屏').evaluate().isNotEmpty,
      'exited fullscreen UI state',
    );
    if (Platform.isWindows) {
      final fullscreen = AppFullscreenController();
      for (
        var attempt = 0;
        attempt < 30 && await fullscreen.isEnabled();
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(await fullscreen.isEnabled(), isFalse);
    }
    evidence['fullscreen_roundtrip'] = true;

    for (var round = 0; round < 3; round++) {
      await tapControl('下一集');
      await until(
        () => player.state.playlist.medias.any(
          (media) => media.uri.contains('episode-2-'),
        ),
        'episode 2 selected, round $round',
      );
      await tapControl('上一集');
      await until(
        () => player.state.playlist.medias.any(
          (media) => media.uri.contains('episode-1-'),
        ),
        'episode 1 restored, round $round',
      );
    }
    await until(
      () => player.state.playing && player.state.position.inMilliseconds > 300,
      'final episode still plays after rapid switching',
    );
    evidence['episode_switches'] = 6;
    evidence['first_frames_recorded'] = account.firstFrames;
    evidence['http_requests'] = fixture.requests.length;
    evidence['final_playing'] = player.state.playing;
    expect(fixture.requests, isNotEmpty);
    expect(tester.takeException(), isNull);
    debugPrint('NATIVE_PLAYBACK_VALIDATION ${jsonEncode(evidence)}');
  });
}
