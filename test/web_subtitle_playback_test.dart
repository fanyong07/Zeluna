@TestOn('browser')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:anime/src/player/subtitles/subtitle_document.dart';
import 'package:anime/src/player/subtitles/subtitle_overlay.dart';
import 'package:anime/src/player/subtitles/subtitle_store.dart';
import 'package:anime/src/player/subtitles/supplemental_subtitle_controller.dart';
import 'package:anime/src/player/web_stream_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;

import 'fixtures/subtitle_video_fixture.dart';

void main() {
  testWidgets(
    'real browser video drives supplements without changing Chinese track',
    (tester) async {
      final captions = SupplementalSubtitleController(SubtitleStore());
      captions.bind(
        subject: 'test:1',
        episode: 'test:1:1',
        line: 'web',
        originalLanguage: 'en',
      );
      await captions.selectDocument(
        parseSubtitle(
          Uint8List.fromList(
            utf8.encode(
              '1\n00:00:00,000 --> 00:00:05,000\nOriginal first\n\n'
              '2\n00:00:05,000 --> 00:00:12,000\nOriginal second',
            ),
          ),
          'fixture.en.srt',
          'en',
        ),
        expectedGeneration: captions.generation,
      );
      final playback = WebStreamPlayerController();
      final position = ValueNotifier(Duration.zero);
      var ready = false;
      var failed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned.fill(
                  child: WebStreamPlayer(
                    url: subtitleVideoDataUri,
                    controller: playback,
                    playing: true,
                    volume: 0,
                    position: Duration.zero,
                    rate: 1.5,
                    onReady: () => ready = true,
                    onError: () => failed = true,
                    onPosition: (value) => position.value = value,
                  ),
                ),
                Positioned.fill(
                  child: ValueListenableBuilder<Duration>(
                    valueListenable: position,
                    builder: (context, value, _) => SupplementalSubtitleOverlay(
                      controller: captions,
                      position: value,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        position.dispose();
        captions.dispose();
      });
      Future<void> until(bool Function() condition, String reason) async {
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (!condition() && !failed && DateTime.now().isBefore(deadline)) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          await tester.pump();
        }
        expect(failed, isFalse, reason: 'browser decode failure');
        expect(condition(), isTrue, reason: reason);
      }

      await until(
        () => ready && position.value > Duration.zero,
        'browser decodes and advances video time',
      );
      final video = web.document.querySelector('video') as web.HTMLVideoElement;
      final primary = video.addTextTrack('subtitles', '简中', 'zh');
      primary.addCue(web.VTTCue(0, 12, '片源原有中文字幕'));
      primary.mode = 'showing';
      await until(
        () => find.text('Original first').evaluate().isNotEmpty,
        'first original cue',
      );
      playback.seek(const Duration(seconds: 7));
      await until(
        () => find.text('Original second').evaluate().isNotEmpty,
        'seek follows media position',
      );
      playback.pause();
      await until(() => video.paused, 'pause');
      final pausedAt = video.currentTime;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 400)),
      );
      await tester.pump();
      expect(video.currentTime, closeTo(pausedAt, .05));
      expect(find.text('Original second'), findsOneWidget);
      expect(video.playbackRate, 1.5);
      expect(primary.mode, 'showing');
      expect(primary.cues?.length, 1);
      await captions.setBilingual(true);
      await tester.pump();
      expect(find.text('Original second'), findsNothing);
      expect(primary.mode, 'showing');
      await captions.setBilingual(false);
      await captions.adjustDelay(3000);
      await tester.pump();
      expect(find.text('Original first'), findsOneWidget);
      expect(primary.mode, 'showing');
      expect(tester.takeException(), isNull);
    },
  );
}
