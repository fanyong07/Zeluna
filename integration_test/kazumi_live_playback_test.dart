import 'dart:convert';
import 'dart:io';

import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/data/playback_source_repository.dart';
import 'package:anime/src/playback/playback_discovery_controller.dart';
import 'package:anime/src/player/video/native_video_compatibility.dart';
import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/rules/rule_plugin_repository.dart';
import 'package:anime/src/rules/bundled_kazumi_rules.dart';
import 'package:anime/src/rules/rule_playback_resolver.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

// Explicit opt-in: public source traffic and native decoder, isolated from
// all application accounts/settings. Never persist signed URLs or headers.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('KAZUMI_LIVE_VALIDATION');
  const selected = String.fromEnvironment('KAZUMI_VALIDATION_RULE');
  const subject = AnimeSubject(
    id: 9999001,
    title: '葬送的芙莉莲',
    originalTitle: '',
    summary: '',
    coverUrl: null,
    bannerUrl: null,
    date: '2023-09-29',
    platform: 'TV',
    language: '',
    region: '',
    status: '',
    categories: [],
    tags: [],
    totalEpisodes: 28,
    source: 'bangumi',
  );
  for (final rule in bundledKazumiRules) {
    testWidgets(
      'native Kazumi ${rule.id} adjacent episodes',
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
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await player.dispose();
        });
        final resolver = RulePlaybackResolver();
        final ruleState = RulePluginState(
          installedIds: {rule.id},
          enabledIds: {rule.id},
        );
        final sources = RulePlaybackSourceRepository(
          repository: const RulePluginRepository(),
          ruleState: ruleState,
          resolver: resolver,
          cacheNamespace: 'isolated-live-${rule.id}',
        );
        final discovery = PlaybackDiscoveryController(
          backendRepository: (_) => null,
          ruleRepository: (_) => sources,
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
          accountId: 'isolated-live',
          contextVersion: 1,
          services: const ExternalServiceSettings(
            playbackBackendEnabled: false,
          ),
          ruleState: ruleState,
          history: [],
        );
        addTearDown(discovery.dispose);
        AnimeEpisode episodeFor(int number) => AnimeEpisode(
          id: 9999001 + number,
          subjectId: subject.id,
          number: number,
          title: '第$number集',
          airdate: null,
          duration: '',
          description: '',
        );
        final evidence = <Map<String, Object?>>[];
        for (final number in [1, 2]) {
          final episode = episodeFor(number);
          final timer = Stopwatch()..start();
          final bundle = discovery.prefetchedWarmupBundleForEpisode(
            subject,
            episode,
          );
          final lines =
              bundle?.allLines ??
              await discovery
                  .linesForEpisode(
                    subject,
                    episode,
                    preferredProviderId: rule.id,
                  )
                  .timeout(const Duration(seconds: 35));
          final ready = lines
              .where((line) => line.available && line.clientVerified)
              .firstOrNull;
          final result = <String, Object?>{
            'rule': rule.id,
            'episode': number,
            'platform': Platform.operatingSystem,
            'resolve_ms': timer.elapsedMilliseconds,
            'warmup_hit': bundle != null,
            'verified_media': ready != null,
            'decoded_frame': false,
          };
          evidence.add(result);
          if (ready == null) {
            // Runtime type/status only: failure messages may contain signed URLs.
            result['failure'] = 'no_verified_media';
            debugPrint('KAZUMI_NATIVE_QA ${jsonEncode(result)}');
            continue;
          }
          final previous = player.state.position;
          final opened = Stopwatch()..start();
          await player.open(Media(ready.url!, httpHeaders: ready.headers));
          var decoded = false;
          final end = DateTime.now().add(const Duration(seconds: 25));
          while (DateTime.now().isBefore(end)) {
            await tester.pump(const Duration(milliseconds: 100));
            if ((player.state.width ?? 0) > 0 &&
                (player.state.height ?? 0) > 0 &&
                player.state.position > const Duration(milliseconds: 600) &&
                player.state.position != previous) {
              decoded = true;
              break;
            }
          }
          if (decoded && number == 1) {
            await video.waitUntilFirstFrameRendered.timeout(
              const Duration(seconds: 8),
            );
          }
          if (decoded) {
            final frame = await player
                .screenshot(format: 'image/png')
                .timeout(const Duration(seconds: 5));
            decoded = frame != null && frame.length > 1024;
            result['decoded_image_bytes'] = frame?.length;
          }
          result.addAll({
            'media_host': Uri.parse(ready.url!).host,
            'decoded_frame': decoded,
            'open_ms': opened.elapsedMilliseconds,
            'width': player.state.width,
            'height': player.state.height,
            'position_ms': player.state.position.inMilliseconds,
          });
          debugPrint('KAZUMI_NATIVE_QA ${jsonEncode(result)}');
          if (number == 1 && decoded) {
            final warmupTimer = Stopwatch()..start();
            await discovery
                .prefetchPlaybackForEpisode(
                  subject,
                  episodeFor(2),
                  preferredProviderId: rule.id,
                )
                .timeout(const Duration(seconds: 35));
            result['next_warmup_ms'] = warmupTimer.elapsedMilliseconds;
            debugPrint(
              'KAZUMI_WARMUP_QA ${jsonEncode({'rule': rule.id, 'elapsed_ms': warmupTimer.elapsedMilliseconds, 'ready': discovery.prefetchedWarmupBundleForEpisode(subject, episodeFor(2)) != null})}',
            );
          }
          await player.stop();
        }
        binding.reportData = {
          'results': evidence,
          'revision': bundledKazumiRevision,
        };
        expect(
          evidence.every((row) => row['decoded_frame'] == true) &&
              evidence.last['warmup_hit'] == true,
          isTrue,
          reason:
              'both adjacent episodes must decode, not just return HTTP 200',
        );
      },
      skip: !enabled || (selected.isNotEmpty && rule.id != selected),
    );
  }
}
