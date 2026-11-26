import 'dart:convert';
import 'dart:io';

import 'package:anime/src/player/video/native_android_surface_controller.dart';
import 'package:anime/src/player/video/native_video_compatibility.dart';
import 'package:anime/src/player/video/native_video_controller.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Opt-in, Android-only local H264 A/B test. The host generates and serves the
/// fixture; it is downloaded to isolated temp storage before normal openRequest.
/// Neither production private-network policy nor a provider URL is substituted.
/// Run twice with ZELUNA_ANDROID_VIDEO_OUTPUT=gpu / auto; failures stay failures.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // External Android textures request engine frames themselves. Exercise them
  // under normal live frame scheduling, not the default fadePointers test
  // policy's explicit-pump-only rendering. All real buffer-count checks remain.
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  const endpoint = String.fromEnvironment(
    'ZELUNA_NATIVE_QA_FIXTURE',
    defaultValue: 'http://127.0.0.1:18764/native-h264.mp4',
  );
  const requestedOutput = String.fromEnvironment(
    'ZELUNA_ANDROID_VIDEO_OUTPUT',
    defaultValue: 'auto',
  );
  const holdSeconds = int.fromEnvironment('ZELUNA_NATIVE_QA_HOLD_SECONDS');

  testWidgets(
    'local H264 actual output, pause and fresh open generations',
    (tester) async {
      expect(Platform.isAndroid, isTrue, reason: 'Android surface test target');
      MediaKit.ensureInitialized();
      await NativeVideoCompatibility.instance.initialize();
      final evidence = <String, Object?>{
        'fixture': endpoint.endsWith('/native-h264-1080.mp4')
            ? 'generated_local_h264_high_1920x1080_mp4'
            : 'generated_local_h264_baseline_640x360_mp4',
        'requested_output': requestedOutput,
        'environment': await NativeVideoCompatibility.instance
            .diagnosticEnvironment(),
        'passed': false,
      };
      binding.reportData = evidence;
      final directory = await Directory.systemTemp.createTemp(
        'zeluna-surface-qa-',
      );
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);
      final file = File('${directory.path}/fixture.mp4');
      final uri = Uri.parse(endpoint);
      expect(
        uri.host == '127.0.0.1' || uri.host == '10.0.2.2',
        isTrue,
        reason: 'the fixture endpoint is local to the QA host only',
      );
      final response = await (await client.getUrl(uri)).close();
      expect(response.statusCode, HttpStatus.ok);
      await response.pipe(file.openWrite());
      client.close(force: true);
      expect(await file.length(), greaterThan(1024));
      evidence['fixture_bytes'] = await file.length();
      evidence['fixture_sha256'] = (await sha256.bind(file.openRead()).first)
          .toString();
      var serial = 0;
      var firstFrames = 0;
      final timeouts = <String>[];
      final controller = NativeVideoController(readOpenSerial: () => serial);
      final player = controller.player;
      final surface = controller.surfaceController;
      evidence['actual_output'] = surface is NativeAndroidSurfaceController
          ? 'mediacodec_embed_surface_texture'
          : 'gpu';
      if (requestedOutput == 'gpu') {
        expect(surface, isNot(isA<NativeAndroidSurfaceController>()));
      } else {
        // An emulator predicate miss is evidence, not a silent GPU pass.
        expect(
          surface,
          isA<NativeAndroidSurfaceController>(),
          reason:
              'API35+ x86_64 with explicit emulator markers should select direct output',
        );
      }
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await controller.dispose();
        client.close(force: true);
        // Only this test's own fresh temp directory, never the app profile.
        await directory.delete(recursive: true);
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 640,
                height: 360,
                child: Video(controller: surface, controls: NoVideoControls),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      Future<void> spinUntil(
        bool Function() ready,
        String label, {
        Duration deadline = const Duration(seconds: 28),
      }) async {
        final end = DateTime.now().add(deadline);
        while (!ready() && DateTime.now().isBefore(end)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(
          ready(),
          isTrue,
          reason: '$label; ${controller.frameDiagnostics}',
        );
      }

      NativePlaybackStartupSnapshot snapshot() =>
          controller.events.readStartupSnapshot(
            currentOpenSerial: serial,
            playerState: player.state,
            hasAlternative: false,
            decodedFrame: controller.hasDecodedFrame,
          );

      Future<void> open({required bool play}) async {
        final ownSerial = ++serial;
        controller.startFirstFrameWatchdog(
          isCurrent: () => ownSerial == serial,
          readSnapshot: snapshot,
          onTimeout: (event) {
            timeouts.add(event.phase.name);
            debugPrint(
              'ANDROID_SURFACE_QA_TIMEOUT ${jsonEncode(controller.frameDiagnostics)}',
            );
          },
          onFirstFrame: (_) => firstFrames++,
        );
        final opened = await controller.openRequest(
          NativePlaybackRequest(
            url: file.uri.toString(),
            headers: const {},
            format: 'mp4',
            publicHttpOnly: false,
          ),
          serial: ownSerial,
          isCurrent: () => ownSerial == serial,
          canPlay: () => play && ownSerial == serial,
          onDispatched: () {},
        );
        expect(opened, play);
      }

      try {
        await open(play: true);
        await spinUntil(
          () => controller.hasDecodedFrame,
          'actual video image, not audio clock',
        );
        expect(firstFrames, 1);
        expect(timeouts, isEmpty);
        final samples = <Map<String, Object?>>[];
        for (var second = 0; second <= 10; second++) {
          if (surface is NativeAndroidSurfaceController) {
            expect(await surface.readFrame(serial: serial), isTrue);
          }
          samples.add({
            'second': second,
            'position_ms': player.state.position.inMilliseconds,
            ...controller.frameDiagnostics,
          });
          if (second < 10) await tester.pump(const Duration(seconds: 1));
        }
        evidence['continuous_samples'] = samples;
        expect(
          (samples.last['position_ms'] as int) -
              (samples.first['position_ms'] as int),
          greaterThan(8500),
          reason: 'clock must remain advancing for ten seconds',
        );
        if (surface is NativeAndroidSurfaceController) {
          for (var i = 1; i < samples.length; i++) {
            expect(
              samples[i]['surface_frames'] as int,
              greaterThan(samples[i - 1]['surface_frames'] as int),
              reason:
                  'distinct raster-consumed video buffers must keep arriving',
            );
          }
        }
        debugPrint('ANDROID_SURFACE_QA_VISIBLE ${jsonEncode(samples.last)}');
        if (holdSeconds > 0) await tester.pump(Duration(seconds: holdSeconds));

        await player.pause();
        await tester.pump(const Duration(milliseconds: 300));
        final paused = player.state.position;
        await tester.pump(const Duration(seconds: 1));
        expect(player.state.playing, isFalse);
        expect(
          (player.state.position - paused).inMilliseconds.abs(),
          lessThan(300),
        );
        evidence['pause_stable'] = true;

        final oldSerial = serial;
        final oldEpoch = surface is NativeAndroidSurfaceController
            ? surface.lastFrame?.epoch
            : null;
        controller.cancelFirstFrameWatchdog();
        await open(play: false);
        expect(
          controller.hasDecodedFrame,
          isFalse,
          reason: 'a paused replacement cannot inherit the old decoded flag',
        );
        expect(player.state.playing, isFalse);
        if (surface is NativeAndroidSurfaceController) {
          expect(await surface.readFrame(serial: oldSerial), isFalse);
          final fresh = surface.lastFrame;
          expect(fresh?.epoch == oldEpoch && fresh != null, isFalse);
        }
        controller.cancelFirstFrameWatchdog();
        await open(play: true);
        await spinUntil(
          () => controller.hasDecodedFrame,
          'replacement media own image',
        );
        expect(firstFrames, 2);
        if (surface is NativeAndroidSurfaceController) {
          expect(surface.lastFrame?.openSerial, serial);
          expect(surface.lastFrame?.epoch, isNot(oldEpoch));
        }
        evidence['fresh_open_generations'] = true;
        evidence['final'] = controller.frameDiagnostics;
        evidence['passed'] = true;
        expect(timeouts, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        evidence['first_frame_count'] = firstFrames;
        evidence['timeouts'] = timeouts;
        evidence['last_probe'] = controller.frameDiagnostics;
        debugPrint('ANDROID_SURFACE_QA ${jsonEncode(evidence)}');
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
