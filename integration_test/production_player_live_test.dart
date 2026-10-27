import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anime/src/app/desktop_window.dart';
import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/data/bangumi_credential_store.dart';
import 'package:anime/src/data/tmdb_credential_store.dart';
import 'package:anime/src/data/zeluna_backend_catalog_repository.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/player/player_page.dart';
import 'package:anime/src/player/video/native_video_compatibility.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../test/support/fake_cloud_account_service.dart';

// Opt-in production pipeline test: real catalogue -> AnimeController ->
// PlayerPage -> native decoder. Only account credentials and local persistence
// are isolated. No media URL, token, header or account data is logged.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('PRODUCTION_PLAYER_LIVE');
  final reports = <String, Object?>{};
  // Native/frame callbacks can retain the first test's error zone. Keep both
  // app lifecycles in one test zone so shared HttpClient connection futures do
  // not cross error-zone boundaries. Do not suppress errors or delay teardown.
  testWidgets('production PlayerPage decodes both reported title identities', (
    tester,
  ) async {
    for (final identity in ['bangumi:464376', 'tmdb:tv:241535']) {
      MediaKit.ensureInitialized();
      await NativeVideoCompatibility.instance.initialize();
      await initializeDesktopWindow();
      final directory = await Directory.systemTemp.createTemp(
        'zeluna-production-player-qa-',
      );
      Hive.init('${directory.path}/hive');
      final settings = await Hive.openBox<dynamic>('anime.settings.v2');
      await settings.put(
        'playback',
        const PlaybackSettings(volumeBoost: -1, autoNext: false).toJson(),
      );
      await settings.close();
      final container = ProviderContainer(
        overrides: [
          cloudAccountServiceProvider.overrideWithValue(
            FakeCloudAccountService(),
          ),
          bangumiCredentialStoreProvider.overrideWithValue(
            BangumiCredentialStore(backend: _MemoryCredentials()),
          ),
          tmdbCredentialStoreProvider.overrideWithValue(
            TmdbCredentialStore(backend: _MemoryCredentials()),
          ),
        ],
      );
      var cleanedUp = false;
      Future<void> cleanUp() async {
        if (cleanedUp) return;
        cleanedUp = true;
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 500));
        container.dispose();
        await Hive.close();
        // This directory was created by this test, not the user's profile.
        if (await directory.exists()) await directory.delete(recursive: true);
      }

      addTearDown(cleanUp);
      final state = await container
          .read(animeControllerProvider.future)
          .timeout(const Duration(seconds: 45));
      final controller = container.read(animeControllerProvider.notifier);
      final catalog = ZelunaBackendCatalogRepository(
        baseUrl: state.services.playbackBackendEndpoint,
        client: container.read(zelunaBackendHttpClientProvider),
      );
      final matches = await catalog.search('败犬女主太多了');
      final subject = matches.firstWhere((s) => s.identityKey == identity);
      final detail = await controller.detail(subject);
      final episode = detail.episodes.firstWhere((e) => e.number == 1);
      final stopwatch = Stopwatch()..start();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: ThemeData.dark(),
            home: PlayerPage(
              request: PlaySessionRequest(
                subject: detail.subject,
                episodes: detail.episodes,
                episode: episode,
                initialLine: controller.prefetchedLineForEpisode(
                  detail.subject,
                  episode,
                ),
              ),
            ),
          ),
        ),
      );
      StreamSubscription<PlayerLog>? nativeLogs;
      final nativeErrors = <String>[];
      addTearDown(() async => nativeLogs?.cancel());
      var decoded = false;
      int? firstDecodedFrameMs;
      var frameBytes = 0;
      var positionMs = 0;
      final deadline = DateTime.now().add(const Duration(seconds: 90));
      while (DateTime.now().isBefore(deadline) && !decoded) {
        await tester.pump(const Duration(milliseconds: 200));
        final videos = find.byType(Video);
        if (videos.evaluate().isEmpty) continue;
        final player = tester.widget<Video>(videos.first).controller.player;
        nativeLogs ??= player.stream.log.listen((event) {
          if (!const {'error', 'fatal', 'warn'}.contains(event.level)) return;
          var message = event.text.replaceAll(
            RegExp(r'''https?://[^\s\]\)>"']+'''),
            '[URL]',
          );
          if (RegExp(
            r'(authorization|cookie|token|secret)\s*[:=]',
            caseSensitive: false,
          ).hasMatch(message)) {
            return;
          }
          if (nativeErrors.length < 20) {
            nativeErrors.add('${event.prefix}: $message');
          }
        });
        await player.setVolume(0);
        positionMs = player.state.position.inMilliseconds;
        if (positionMs < 600 || (player.state.width ?? 0) <= 0) continue;
        final image = await player.screenshot(format: 'image/png');
        frameBytes = image?.length ?? 0;
        decoded = frameBytes > 1000;
        if (decoded) firstDecodedFrameMs = stopwatch.elapsedMilliseconds;
        if (decoded &&
            image != null &&
            const bool.fromEnvironment('PRODUCTION_PLAYER_SAVE_FRAMES')) {
          await File(
            '${Directory.systemTemp.path}/qa-frame-${identity.replaceAll(':', '-')}.png',
          ).writeAsBytes(image);
        }
      }
      final firstFramePosition = positionMs;
      var sustainedPlayback = false;
      if (decoded) {
        final player = tester
            .widget<Video>(find.byType(Video).first)
            .controller
            .player;
        final progressDeadline = DateTime.now().add(
          const Duration(seconds: 20),
        );
        while (DateTime.now().isBefore(progressDeadline)) {
          await tester.pump(const Duration(milliseconds: 200));
          positionMs = player.state.position.inMilliseconds;
          if (positionMs >= firstFramePosition + 5000) {
            sustainedPlayback = true;
            break;
          }
        }
      }
      final report = <String, Object?>{
        'platform': Platform.operatingSystem,
        'requested_identity': identity,
        'detail_identity': detail.subject.identityKey,
        'episode': episode.number,
        'backend_enabled': state.services.playbackBackendEnabled,
        'default_enabled_rules': state.rulePlugins.enabledIds.length,
        'lookup_and_decode_ms': stopwatch.elapsedMilliseconds,
        'first_decoded_frame_ms': firstDecodedFrameMs,
        'decoded_frame': decoded,
        'sustained_playback': sustainedPlayback,
        'first_frame_position_ms': firstFramePosition,
        'decoded_image_bytes': frameBytes,
        'position_ms': positionMs,
        'native_errors': nativeErrors,
      };
      if (!decoded) {
        report['visible_failure_messages'] = tester
            .widgetList<Text>(find.byType(Text))
            .map((text) => text.data ?? '')
            .where((text) => RegExp('线路|来源|超时|不可用|播放|查找').hasMatch(text))
            .where((text) => !text.contains('://'))
            .take(18)
            .toList();
      }
      reports[identity] = report;
      binding.reportData = reports;
      // ignore: avoid_print
      print('PRODUCTION_PLAYER_QA ${jsonEncode(report)}');
      await cleanUp();
      expect(
        decoded && sustainedPlayback,
        isTrue,
        reason: 'the real PlayerPage must decode the reported title',
      );
    }
  }, skip: !enabled);
}

class _MemoryCredentials
    implements BangumiCredentialBackend, TmdbCredentialBackend {
  final _values = <String, String>{};
  @override
  Future<String?> read(String key) async => _values[key];
  @override
  Future<void> write(String key, String value) async => _values[key] = value;
  @override
  Future<void> delete(String key) async => _values.remove(key);
}
