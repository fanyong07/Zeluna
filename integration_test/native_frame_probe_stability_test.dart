import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';

import 'support/generated_player_video.dart';

/// Opt-in native FFI regression in a separate QA application. No production
/// account, provider, screenshot storage or user profile is involved. Null VO
/// isolates decoded-frame memory/ownership from emulator GPU driver behavior;
/// this does not claim rendered output or physical ARM hardware acceptance.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets(
    'native raw frame probe and screenshot survive repeated opens',
    (tester) async {
      MediaKit.ensureInitialized();
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      final directory = await Directory.systemTemp.createTemp(
        'zeluna-frame-qa-',
      );
      final file = await writeGeneratedPlayerTestVideo(directory);
      final player = Player(
        configuration: const PlayerConfiguration(vo: 'null'),
      );
      final native = player.platform as NativePlayer;
      final report = <String, Object?>{
        'platform': Platform.operatingSystem,
        'vo': 'null',
        'fixture': 'generated_local_raw_64x36_avi',
        'rendered_output_validation': false,
        'passed': false,
      };
      binding.reportData = report;
      var disposed = false;
      addTearDown(() async {
        if (!disposed) await player.dispose();
        await directory.delete(recursive: true);
      });
      await native.setProperty('vid', 'auto');
      var probes = 0;
      var screenshots = 0;
      for (var round = 0; round < 12; round++) {
        await player.open(Media(file.path));
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        var decoded = false;
        while (!decoded && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 100));
          decoded = await native.hasDecodedVideoFrame().timeout(
            const Duration(seconds: 3),
          );
        }
        expect(decoded, isTrue, reason: 'decoded buffer on open $round');
        for (var attempt = 0; attempt < 5; attempt++) {
          expect(await native.hasDecodedVideoFrame(), isTrue);
          probes++;
        }
        // Public user screenshots still work through the corrected argv helper.
        final jpeg = await player.screenshot();
        expect(jpeg, isNotNull);
        expect(jpeg!.take(2).toList(), [0xff, 0xd8]);
        screenshots++;
        await player.pause();
        expect(await native.hasDecodedVideoFrame(), isTrue);
        // Exercise the shared native mutex against a concurrently requested stop.
        await Future.wait<Object?>([
          native.hasDecodedVideoFrame(),
          player.stop(),
        ]);
      }
      await Future.wait<Object?>([
        native.hasDecodedVideoFrame(),
        player.dispose(),
      ]).timeout(const Duration(seconds: 15));
      disposed = true;
      report.addAll({
        'opens': 12,
        'successful_repeated_probes': probes,
        'valid_jpeg_screenshots': screenshots,
        'pause_stop_dispose_races_completed': true,
        'passed': true,
      });
      expect(tester.takeException(), isNull);
      debugPrint('NATIVE_FRAME_STABILITY ${jsonEncode(report)}');
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
