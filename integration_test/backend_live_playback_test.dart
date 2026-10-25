import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anime/src/data/zeluna_backend_playback_repository.dart';
import 'package:anime/src/data/playback_source_repository.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/playback/playback_discovery_controller.dart';
import 'package:anime/src/player/video/native_video_compatibility.dart';
import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/rules/rule_playback_resolver.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

// Opt-in only: isolated anonymous API traffic and real decoding. Never print
// or persist media URLs, headers, tokens, cookies, or application settings.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('BACKEND_LIVE_VALIDATION');
  const endpoint = String.fromEnvironment(
    'BACKEND_LIVE_ENDPOINT',
    defaultValue: 'https://api.zeluna.top',
  );
  final samples = [
    (id: 400602, title: '葬送的芙莉莲', source: 'bangumi', date: '2023-09-29'),
    (id: 535167, title: '流浪地球', source: 'tmdb:movie', date: '2019-02-05'),
    (id: 95842, title: '开端', source: 'tmdb:tv', date: '2022-01-11'),
  ];
  for (final sample in samples) {
    testWidgets(
      'live backend quick/full discovery decodes ${sample.source}',
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
        final backend = ZelunaBackendPlaybackRepository(baseUrl: endpoint);
        final resolver = RulePlaybackResolver();
        final discovery = PlaybackDiscoveryController(
          backendRepository: (_) => backend,
          ruleRepository: (_) =>
              throw StateError('rules are intentionally isolated'),
          verifyLine:
              (
                line, {
                enrichMetadata = true,
                forceRefresh = false,
                cancellationToken,
              }) => resolver.verifyPlaybackLine(
                line: line,
                enrichMetadata: enrichMetadata,
                forceRefresh: forceRefresh,
                cancellationToken: cancellationToken,
              ),
          isContextCurrent: (version) => version == 1,
          clearRuleRuntimeCaches:
              RulePlaybackSourceRepository.clearRuntimeCaches,
        );
        discovery.loadForAccount(
          accountId: 'isolated-backend-live',
          contextVersion: 1,
          services: const ExternalServiceSettings(
            playbackBackendEnabled: true,
            playbackBackendEndpoint: endpoint,
          ),
          ruleState: const RulePluginState(),
          history: const [],
        );
        final token = RulePlaybackCancellationToken();
        addTearDown(() async {
          token.cancel();
          discovery.dispose();
          backend.dispose();
          await tester.pumpWidget(const SizedBox.shrink());
          await player.dispose();
        });
        final subject = AnimeSubject(
          id: sample.id,
          title: sample.title,
          originalTitle: '',
          summary: '',
          coverUrl: null,
          bannerUrl: null,
          date: sample.date,
          platform: sample.source == 'tmdb:movie' ? 'Movie' : 'TV',
          language: '',
          region: '',
          status: '',
          categories: const [],
          tags: const [],
          totalEpisodes: sample.source == 'tmdb:movie' ? 1 : 28,
          source: sample.source,
        );
        final episode = AnimeEpisode(
          id: sample.id * 1000 + 1,
          subjectId: sample.id,
          number: 1,
          title: '第1集',
          airdate: null,
          duration: '',
          description: '',
        );
        final timer = Stopwatch()..start();
        final first = Completer<void>();
        var latest = const <PlaybackLine>[];
        var firstPlayableMs = 0;
        final finished = discovery
            .lineUpdatesForEpisode(subject, episode, cancellationToken: token)
            .forEach((update) {
              latest = update.lines;
              if (!first.isCompleted && latest.any((line) => line.available)) {
                firstPlayableMs = timer.elapsedMilliseconds;
                first.complete();
              }
            });
        await first.future.timeout(const Duration(seconds: 25));
        var decoded = false;
        var frameBytes = 0;
        var attempts = 0;
        final tried = <String>{};
        final deadline = DateTime.now().add(const Duration(seconds: 75));
        while (!decoded && DateTime.now().isBefore(deadline) && attempts < 4) {
          final candidates = latest
              .where(
                (line) =>
                    line.available &&
                    line.url != null &&
                    !tried.contains(line.id),
              )
              .toList();
          if (candidates.isEmpty) {
            await tester.pump(const Duration(milliseconds: 100));
            continue;
          }
          final route = candidates.first;
          tried.add(route.id);
          attempts++;
          try {
            await player.stop();
            await player
                .open(Media(route.url!, httpHeaders: route.headers))
                .timeout(const Duration(seconds: 12));
            final until = DateTime.now().add(const Duration(seconds: 12));
            while (DateTime.now().isBefore(until)) {
              await tester.pump(const Duration(milliseconds: 100));
              if ((player.state.width ?? 0) > 0 &&
                  (player.state.height ?? 0) > 0 &&
                  player.state.position.inMilliseconds > 700) {
                await video.waitUntilFirstFrameRendered.timeout(
                  const Duration(seconds: 5),
                );
                final frame = await player
                    .screenshot(format: 'image/png')
                    .timeout(const Duration(seconds: 5));
                frameBytes = frame?.length ?? 0;
                decoded = frameBytes > 1024;
                break;
              }
            }
          } catch (_) {
            // Runtime diagnostics can contain signed addresses; report counts only.
          }
        }
        await finished.timeout(const Duration(seconds: 25));
        debugPrint(
          'BACKEND_NATIVE_QA ${jsonEncode({'platform': Platform.operatingSystem, 'kind': sample.source, 'first_playable_ms': firstPlayableMs, 'lookup_and_decode_ms': timer.elapsedMilliseconds, 'inventory_rows': latest.length, 'playable_rows': latest.where((line) => line.available).length, 'partial_full_response': latest.any((line) => line.cacheState == 'partial'), 'attempts': attempts, 'decoded_frame': decoded, 'decoded_image_bytes': frameBytes, 'width': player.state.width, 'height': player.state.height})}',
        );
        expect(
          decoded,
          isTrue,
          reason: 'API success is not a decoded native frame',
        );
        expect(latest.length, greaterThanOrEqualTo(118));
        expect(firstPlayableMs, lessThan(18000));
      },
      skip: !enabled,
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }
}
