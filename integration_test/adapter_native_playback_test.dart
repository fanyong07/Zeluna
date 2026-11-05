import 'dart:convert';
import 'dart:io';

import 'package:anime/src/app/desktop_window.dart';
import 'package:anime/src/core/network/network_security.dart';
import 'package:anime/src/data/zeluna_backend_playback_repository.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/player/video/native_android_surface_controller.dart';
import 'package:anime/src/player/video/native_video_compatibility.dart';
import 'package:anime/src/player/video/native_video_controller.dart';
import 'package:anime/src/rules/rule_playback_resolver.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Opt-in live adapter audit. Only the metadata handoff is localhost: the helper
/// runs real standard provider discovery and retains signed URLs in memory.
/// The app uses its normal repository, verifier, transport and native output.
/// No canned media or alternate provider may satisfy a provider's assertion.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  const base = String.fromEnvironment(
    'ZELUNA_ADAPTER_QA_BASE',
    defaultValue: 'http://127.0.0.1:18765',
  );
  const caseList = String.fromEnvironment(
    'ZELUNA_ADAPTER_QA_CASES',
    defaultValue: 'anich,kazumi,animeko',
  );
  const holdSeconds = int.fromEnvironment('ZELUNA_NATIVE_QA_HOLD_SECONDS');
  final cases = caseList.split(',').map((value) => value.trim()).toList();
  final audit = <String, Object?>{
    'platform': Platform.operatingSystem,
    'pipeline':
        'live_adapter->production_serializer->repository->client_probe->native_video',
    'catalog_freshness': 'see_separate_provider_report_not_assumed',
    'cases': <Object?>[],
  };
  binding.reportData = audit;

  setUpAll(() async {
    expect(cases.every(const {'anich', 'kazumi', 'animeko'}.contains), isTrue);
    final uri = Uri.parse(base);
    expect(uri.host, '127.0.0.1');
    expect(uri.port, 18765);
    MediaKit.ensureInitialized();
    await NativeVideoCompatibility.instance.initialize();
    await initializeDesktopWindow();
  });

  for (final provider in cases) {
    testWidgets(
      'real $provider episode media sustained native video',
      (tester) async {
        final report = <String, Object?>{
          'provider': provider,
          'stable_id': 'bangumi:400602',
          'episode': 1,
          'passed': false,
          'attempts': <Object?>[],
        };
        (audit['cases'] as List).add(report);
        final repository = ZelunaBackendPlaybackRepository(
          baseUrl: '$base/$provider',
          service: NetworkServiceKind.selfHostedPlaybackBackend,
          allowInsecureSelfHosted: true,
          requestTimeout: const Duration(seconds: 95),
        );
        addTearDown(repository.dispose);
        final resolver = RulePlaybackResolver(
          timeout: const Duration(seconds: 20),
        );
        addTearDown(resolver.resetExecutionScope);
        final requested = await repository.linesForEpisode(_subject, _episode);
        report['received_routes'] = requested.length;
        expect(
          requested,
          isNotEmpty,
          reason: '$provider produced no current episode candidates',
        );
        var completed = false;
        // Retain failed site routes in the evidence; a slow/unreachable site's
        // first two routes must not exclude another independently found site.
        for (final candidate in requested.take(6)) {
          // Identity remains the original provider/rule/route from the adapter.
          final attempt = <String, Object?>{
            'provider_id': candidate.providerId,
            'provider_name': candidate.providerName,
            'source_name': candidate.sourceName,
            'handoff_status': candidate.diagnosticStatus,
            'chapter_task': candidate.clientResolver != null,
            'header_count': candidate.headers.length,
          };
          (report['attempts'] as List).add(attempt);
          NativeVideoController? controller;
          var stage = 'client_probe';
          try {
            final verified = await resolver.verifyPlaybackLine(
              line: candidate,
              enrichMetadata: false,
              forceRefresh: true,
            );
            attempt['client_verified'] = verified.clientVerified;
            attempt['available'] = verified.available;
            attempt['probe_error'] = verified.sourceErrorCategory;
            if (!verified.available ||
                !verified.clientVerified ||
                verified.url == null) {
              continue;
            }
            attempt['media_sha256'] = sha256
                .convert(utf8.encode(verified.url!))
                .toString();
            attempt['media_host'] = Uri.parse(verified.url!).host;
            attempt['format'] = verified.format;
            attempt['media_header_count'] = verified.headers.length;
            var serial = 1;
            var firstFrames = 0;
            final timeouts = <String>[];
            final active = controller = NativeVideoController(
              readOpenSerial: () => serial,
            );
            final player = active.player;
            final surface = active.surfaceController;
            await tester.pumpWidget(
              MaterialApp(
                theme: ThemeData.dark(),
                home: Scaffold(
                  appBar: AppBar(title: Text('Native QA: $provider')),
                  body: Center(
                    child: AspectRatio(
                      aspectRatio: 16 / 9,
                      child: Video(
                        controller: surface,
                        controls: NoVideoControls,
                      ),
                    ),
                  ),
                ),
              ),
            );
            active.startFirstFrameWatchdog(
              isCurrent: () => serial == 1,
              readSnapshot: () => active.events.readStartupSnapshot(
                currentOpenSerial: serial,
                playerState: player.state,
                hasAlternative: false,
                decodedFrame: active.hasDecodedFrame,
              ),
              onTimeout: (event) => timeouts.add(event.phase.name),
              onFirstFrame: (_) => firstFrames++,
            );
            stage = 'native_open';
            final opened = await active.openRequest(
              NativePlaybackRequest(
                url: verified.url!,
                headers: verified.headers,
                format: verified.format,
                publicHttpOnly: verified.publicHttpOnly,
              ),
              serial: serial,
              isCurrent: () => serial == 1,
              canPlay: () => serial == 1,
              onDispatched: () {},
            );
            if (!opened) throw StateError('native_open_not_dispatched');
            stage = 'first_decoded_frame';
            final deadline = DateTime.now().add(const Duration(seconds: 28));
            while (!active.hasDecodedFrame &&
                DateTime.now().isBefore(deadline) &&
                timeouts.isEmpty) {
              await tester.pump(const Duration(milliseconds: 100));
            }
            attempt['first_frames'] = firstFrames;
            attempt['timeouts'] = timeouts;
            if (!active.hasDecodedFrame) {
              throw StateError('no_native_decoded_frame');
            }
            stage = 'sustained_video';
            final samples = <Map<String, Object?>>[];
            final screenshots = <String>[];
            for (var second = 0; second <= 12; second++) {
              if (surface is NativeAndroidSurfaceController) {
                if (!await surface.readFrame(serial: serial)) {
                  throw StateError('no_current_surface_image');
                }
              } else if (second % 3 == 0) {
                final bytes = await player
                    .screenshot(format: 'image/png')
                    .timeout(const Duration(seconds: 3));
                if (bytes == null || bytes.length <= 64) {
                  throw StateError('no_native_screenshot');
                }
                screenshots.add(sha256.convert(bytes).toString());
              }
              samples.add({
                'second': second,
                'position_ms': player.state.position.inMilliseconds,
                'buffering': player.state.buffering,
                ...active.frameDiagnostics,
              });
              if (second < 12) await tester.pump(const Duration(seconds: 1));
            }
            attempt['continuous_samples'] = samples;
            if ((samples.last['position_ms'] as int) -
                    (samples.first['position_ms'] as int) <
                9500) {
              throw StateError('media_clock_not_sustained');
            }
            if (surface is NativeAndroidSurfaceController) {
              for (var i = 1; i < samples.length; i++) {
                if ((samples[i]['surface_frames'] as int) <=
                    (samples[i - 1]['surface_frames'] as int)) {
                  throw StateError('video_buffer_stalled');
                }
              }
            } else {
              attempt['decoded_screenshot_sha256'] = screenshots;
              if (screenshots.toSet().length < 2) {
                throw StateError('decoded_picture_not_changing');
              }
            }
            debugPrint(
              'ADAPTER_QA_VISIBLE ${jsonEncode({'provider': provider, 'sample': samples.last})}',
            );
            if (holdSeconds > 0) {
              await tester.pump(Duration(seconds: holdSeconds));
            }
            stage = 'pause';
            await player.pause();
            await tester.pump(const Duration(milliseconds: 500));
            final paused = player.state.position;
            await tester.pump(const Duration(seconds: 1));
            if (player.state.playing ||
                (player.state.position - paused).inMilliseconds.abs() >= 300) {
              throw StateError('pause_not_stable');
            }
            attempt['pause_stable'] = true;
            attempt['passed'] = true;
            report['passed'] = completed = true;
            serial++;
            break;
          } catch (error) {
            // Neither signed media URLs nor exception text enters the report.
            attempt['failure_type'] = error.runtimeType.toString();
            attempt['failure_stage'] = stage;
            attempt['last_native'] = controller?.frameDiagnostics;
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await controller?.dispose();
          }
        }
        debugPrint('ADAPTER_NATIVE_QA ${jsonEncode(report)}');
        expect(
          completed,
          isTrue,
          reason: '$provider: no route proved sustained actual decoded video',
        );
        expect(tester.takeException(), isNull);
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );
  }
}

const _subject = AnimeSubject(
  id: 400602,
  title: '葬送的芙莉莲',
  originalTitle: '葬送のフリーレン',
  summary: '',
  coverUrl: null,
  bannerUrl: null,
  date: '2023-09-29',
  platform: 'TV',
  language: '日语',
  region: '日本',
  status: '完结',
  categories: [],
  tags: [],
  totalEpisodes: 28,
);
const _episode = AnimeEpisode(
  id: 1,
  subjectId: 400602,
  number: 1,
  title: '第1集',
  airdate: null,
  duration: '',
  description: '',
);
