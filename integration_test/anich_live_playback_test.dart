import 'dart:convert';
import 'package:anime/src/data/zeluna_backend_playback_repository.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/player/video/native_video_compatibility.dart';
import 'package:anime/src/rules/rule_playback_resolver.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

// No injected media: current public API -> AniCh route -> device probe -> frame.
// Isolated player, no account/settings. Never log media addresses or headers.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('ANICH_LIVE_VALIDATION');
  testWidgets(
    'AniCh first and third episodes decode from public discovery',
    (tester) async {
      MediaKit.ensureInitialized();
      await NativeVideoCompatibility.instance.initialize();
      final player = Player(
        configuration: const PlayerConfiguration(logLevel: MPVLogLevel.error),
      );
      await player.setVolume(0);
      final video = VideoController(
        player,
        configuration: NativeVideoCompatibility.instance.configuration,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: Video(controller: video)),
        ),
      );
      final backend = ZelunaBackendPlaybackRepository(
        baseUrl: 'https://api.zeluna.top',
      );
      final resolver = RulePlaybackResolver();
      addTearDown(() async {
        backend.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
        await player.dispose();
      });
      const subject = AnimeSubject(
        id: 464376,
        title: '败犬女主太多了！',
        originalTitle: '負けヒロインが多すぎる！',
        summary: '',
        coverUrl: null,
        bannerUrl: null,
        date: '2024-07-13',
        platform: 'TV',
        language: '',
        region: '',
        status: '',
        categories: [],
        tags: [],
        totalEpisodes: 12,
        source: 'bangumi',
      );
      final tag = RegExp(r'^[a-z]{1,12}(?:-[a-z]+)?-\d+(?:-\d+)?$');
      for (final number in [1, 3]) {
        final episode = AnimeEpisode(
          id: 464376000 + number,
          subjectId: 464376,
          number: number,
          title: '第$number集',
          airdate: null,
          duration: '',
          description: '',
        );
        final timer = Stopwatch()..start();
        List<PlaybackLine> candidates = [];
        for (var i = 0; i < 8 && candidates.isEmpty; i++) {
          final lines = await backend.linesForEpisodeMode(
            subject,
            episode,
            expandAll: true,
          );
          candidates = lines
              .where((l) => tag.hasMatch(l.sourceName) && l.url != null)
              .toList();
          if (candidates.isEmpty) {
            await Future<void>.delayed(const Duration(seconds: 5));
          }
        }
        var decoded = false;
        var attempts = 0;
        var frameBytes = 0;
        String? source;
        for (final candidate in candidates.take(4)) {
          attempts++;
          final route = await resolver.verifyPlaybackLine(
            line: candidate,
            enrichMetadata: false,
          );
          if (!route.available) continue;
          await player.stop();
          try {
            await player
                .open(Media(route.url!, httpHeaders: route.headers))
                .timeout(const Duration(seconds: 12));
            final until = DateTime.now().add(const Duration(seconds: 18));
            while (DateTime.now().isBefore(until)) {
              await tester.pump(const Duration(milliseconds: 100));
              if ((player.state.width ?? 0) > 0 &&
                  (player.state.height ?? 0) > 0 &&
                  player.state.position.inMilliseconds > 1200) {
                await video.waitUntilFirstFrameRendered.timeout(
                  const Duration(seconds: 5),
                );
                final frame = await player
                    .screenshot(format: 'image/png')
                    .timeout(const Duration(seconds: 5));
                frameBytes = frame?.length ?? 0;
                decoded = frameBytes > 1024;
                source = route.sourceName;
                break;
              }
            }
          } catch (_) {
            /* Deliberately omit errors that can contain signed URLs. */
          }
          if (decoded) break;
        }
        debugPrint(
          'ANICH_NATIVE_QA ${jsonEncode({'episode': number, 'candidates': candidates.length, 'source': source, 'attempts': attempts, 'decoded_frame': decoded, 'frame_bytes': frameBytes, 'width': player.state.width, 'height': player.state.height, 'elapsed_ms': timer.elapsedMilliseconds})}',
        );
        expect(
          decoded,
          isTrue,
          reason: 'API availability is not proof of decoded frames',
        );
        await player.stop();
      }
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
