import 'dart:convert';
import 'dart:io';

import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/data/playback_source_repository.dart';
import 'package:anime/src/playback/playback_discovery_controller.dart';
import 'package:anime/src/player/video/native_video_compatibility.dart';
import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/rules/bundled_live_action_rules.dart';
import 'package:anime/src/rules/rule_plugin_repository.dart';
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
  const enabled = bool.fromEnvironment('LIVE_ACTION_VALIDATION');
  const selected = String.fromEnvironment('LIVE_ACTION_RULE');
  const fullDiscovery = bool.fromEnvironment('LIVE_ACTION_FULL_DISCOVERY');
  final rules = [
    const RulePluginRepository().byId('zeluna:recommended:dbku')!,
    ...optionalLiveActionRules,
  ];
  for (final rule in rules) {
    final dbku = rule.id == 'zeluna:recommended:dbku';
    for (final movie in [true, false]) {
      final subject = AnimeSubject(
        id: movie ? 9999101 : 9999102,
        title: movie ? (dbku ? '流浪地球2' : '流浪地球') : (dbku ? '庆余年 第二季' : '开端'),
        originalTitle: '',
        summary: '',
        coverUrl: null,
        bannerUrl: null,
        date: movie
            ? (dbku ? '2023-01-22' : '2019-02-05')
            : (dbku ? '2024-05-16' : '2022-01-11'),
        platform: movie ? 'Movie' : 'TV',
        language: '',
        region: '',
        status: '',
        categories: const [],
        tags: const [],
        totalEpisodes: movie ? 1 : (dbku ? 36 : 15),
        source: movie ? 'tmdb:movie' : 'tmdb:tv',
      );
      testWidgets(
        'native live action ${rule.id} ${movie ? 'movie' : 'series'}',
        (tester) async {
          MediaKit.ensureInitialized();
          await NativeVideoCompatibility.instance.initialize();
          final player = Player(
            configuration: const PlayerConfiguration(
              logLevel: MPVLogLevel.error,
            ),
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
            cacheNamespace: 'isolated-live-action-${rule.id}-${subject.id}',
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
            id: subject.id + number,
            subjectId: subject.id,
            number: number,
            title: movie ? '正片' : '第$number集',
            airdate: null,
            duration: '',
            description: '',
          );
          final evidence = <Map<String, Object?>>[];
          for (final number in (movie ? [1] : [1, 2])) {
            final episode = episodeFor(number);
            final timer = Stopwatch()..start();
            final bundle = discovery.prefetchedWarmupBundleForEpisode(
              subject,
              episode,
            );
            final lines =
                bundle?.allLines ??
                await discovery
                    .linesForEpisodeMode(
                      subject,
                      episode,
                      expandAll: fullDiscovery,
                      preferredProviderId: rule.id,
                    )
                    .timeout(const Duration(seconds: 35));
            final ready = lines
                .where((line) => line.available && line.clientVerified)
                .firstOrNull;
            final result = <String, Object?>{
              'rule': rule.id,
              'kind': movie ? 'movie' : 'series',
              'sample': subject.title,
              'episode': number,
              'platform': Platform.operatingSystem,
              'resolve_ms': timer.elapsedMilliseconds,
              'lookup_mode': bundle != null
                  ? 'warmup'
                  : (fullDiscovery ? 'full' : 'quick'),
              'warmup_hit': bundle != null,
              'verified_media': ready != null,
              'decoded_frame': false,
            };
            evidence.add(result);
            if (ready == null) {
              // Runtime type/status only: failure messages may contain signed URLs.
              result['failure'] = 'no_verified_media';
              result['statuses'] = [
                for (final line in lines) _statusCode(line.message),
              ];
              debugPrint('LIVE_ACTION_NATIVE_QA ${jsonEncode(result)}');
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
            debugPrint('LIVE_ACTION_NATIVE_QA ${jsonEncode(result)}');
            if (!movie && number == 1 && decoded) {
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
                'LIVE_ACTION_WARMUP_QA ${jsonEncode({'rule': rule.id, 'elapsed_ms': warmupTimer.elapsedMilliseconds, 'ready': discovery.prefetchedWarmupBundleForEpisode(subject, episodeFor(2)) != null})}',
              );
            }
            await player.stop();
          }
          binding.reportData = {
            'results': evidence,
            'rule_version': rule.version,
          };
          expect(
            evidence.every((row) => row['decoded_frame'] == true) &&
                (movie || evidence.last['warmup_hit'] == true),
            isTrue,
            reason:
                'movie / adjacent series episodes must decode, not just return HTTP 200',
          );
        },
        skip: !enabled || (selected.isNotEmpty && rule.id != selected),
      );
    }
  }
}

String _statusCode(String? message) {
  final text = message ?? '';
  if (text.contains('超时') || text.contains('未完成')) return 'timeout';
  if (text.contains('匹配') || text.contains('详情')) return 'no_match';
  if (text.contains('未授权')) return 'permission_denied';
  if (text.contains('分片')) return 'media_segment_unavailable';
  if (text.contains('清单')) return 'manifest_unavailable';
  return 'unavailable';
}
