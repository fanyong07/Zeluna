import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anime/src/app/desktop_window.dart';
import 'package:anime/src/player/app_fullscreen.dart';
import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/player/player_page.dart';
import 'package:anime/src/player/subtitles/subtitle_document.dart';
import 'package:anime/src/player/subtitles/subtitle_overlay.dart';
import 'package:anime/src/player/subtitles/subtitle_panel.dart';
import 'package:anime/src/player/subtitles/subtitle_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'support/generated_player_video.dart';
import 'support/isolated_player_environment.dart';

// Real native playback; all media/account data belongs to this test directory.
// Does not initialize the user's Hive directory or access remote providers.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native Chinese track survives supplementary captions, seek, pause and panel changes',
    (tester) async {
      MediaKit.ensureInitialized();
      await initializeDesktopWindow();
      final temporary = await Directory.systemTemp.createTemp(
        'zeluna-subtitle-integration-',
      );
      Hive.init('${temporary.path}/hive');
      final clip = await writeGeneratedPlayerTestVideo(temporary);
      final store = await SubtitleStore.open(null);
      final doc = parseSubtitle(
        Uint8List.fromList(
          utf8.encode(
            '1\n00:00:00,000 --> 00:00:20,000\nOriginal first line\n\n2\n00:00:20,000 --> 00:01:00,000\nOriginal second line',
          ),
        ),
        'fixture.en.srt',
        'en',
      );
      await store.bindDocument(
        playerTestEpisode.identityKey(
          subjectKey: playerTestSubject.identityKey,
        ),
        doc,
      );
      await store.setPreferences(playerTestSubject.identityKey, {
        'enabled': true,
        'language': 'en',
      });
      final account = IsolatedPlayerTestAccount();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 500));
        await Hive.close();
        await temporary.delete(recursive: true);
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
                  id: 'subtitle-native-fixture',
                  episodeId: playerTestEpisode.id,
                  providerId: 'test-local',
                  providerName: 'Local test',
                  title: 'Generated fixture',
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
      Future<void> until(bool Function() predicate, String reason) async {
        final deadline = DateTime.now().add(const Duration(seconds: 25));
        while (!predicate() && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 150));
        }
        expect(predicate(), isTrue, reason: reason);
      }

      await until(
        () =>
            find.byType(Video).evaluate().isNotEmpty && account.firstFrames > 0,
        'native decoded first frame',
      );
      final player = tester
          .widget<Video>(find.byType(Video).first)
          .controller
          .player;
      await until(
        () => find.text('Original first line').evaluate().isNotEmpty,
        'supplement loaded from isolated local cache',
      );
      final subtitles = tester
          .widget<SupplementalSubtitleOverlay>(
            find.byType(SupplementalSubtitleOverlay).first,
          )
          .controller;
      await player.setSubtitleTrack(
        SubtitleTrack.data(
          '1\n00:00:00,000 --> 00:02:59,000\n片源原有中文字幕',
          title: 'Existing Chinese',
          language: 'zh',
        ),
      );
      await until(
        () => player.state.subtitle.any((text) => text.contains('片源原有中文字幕')),
        'native Chinese track is active',
      );
      final originalTrack = player.state.track.subtitle;
      await subtitles.adjustDelay(500);
      expect(player.state.track.subtitle, originalTrack);
      await player.seek(const Duration(seconds: 25));
      await until(
        () => find.text('Original second line').evaluate().isNotEmpty,
        'seek changes supplementary cue',
      );
      await player.pause();
      await tester.pump(const Duration(milliseconds: 400));
      final before = player.state.position;
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        (player.state.position - before).inMilliseconds.abs(),
        lessThan(300),
      );
      expect(find.text('Original second line'), findsOneWidget);
      await subtitles.setBilingual(true);
      await tester.pump();
      expect(find.text('Original second line'), findsNothing);
      expect(player.state.track.subtitle, originalTrack);
      await subtitles.setBilingual(false);
      await player.setRate(1.5);
      await player.play();
      await player.seek(const Duration(seconds: 2));
      await until(
        () => find.text('Original first line').evaluate().isNotEmpty,
        'rewind at a different rate uses media time',
      );
      expect(player.state.track.subtitle, originalTrack);
      // Reveal controls via the existing tap gesture, then use the actual new entry.
      await tester.tap(find.byType(Video).first);
      await tester.pump(const Duration(milliseconds: 250));
      await player.pause();
      await tester.tap(find.byTooltip('全屏'));
      await until(
        () => find.byTooltip('退出全屏').evaluate().isNotEmpty,
        'fullscreen entered',
      );
      expect(await AppFullscreenController().isEnabled(), isTrue);
      expect(find.text('Original first line'), findsOneWidget);
      expect(player.state.track.subtitle, originalTrack);
      await tester.tap(find.byTooltip('退出全屏'));
      await until(
        () => find.byTooltip('全屏').evaluate().isNotEmpty,
        'fullscreen exited',
      );
      expect(await AppFullscreenController().isEnabled(), isFalse);
      await tester.pump(const Duration(milliseconds: 500));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      final viewport = tester.getRect(find.byType(Video).first);
      await mouse.moveTo(viewport.center);
      await mouse.moveTo(Offset(viewport.center.dx, viewport.top + 12));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byTooltip('字幕').hitTestable());
      await until(
        () => find.byType(SupplementalSubtitlePanel).evaluate().isNotEmpty,
        'subtitle panel opens after restoring window',
      );
      expect(find.byType(SupplementalSubtitlePanel), findsOneWidget);
      expect(tester.takeException(), isNull);
      debugPrint(
        'SUBTITLE_NATIVE_QA: first_frame=true preserved_primary=true seek=true pause=true rate=true fullscreen=true panel=true',
      );
    },
  );
}
