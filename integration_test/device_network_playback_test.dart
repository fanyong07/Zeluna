import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anime/src/app/desktop_window.dart';
import 'package:anime/src/catalog/catalog_page.dart';
import 'package:anime/src/catalog/catalog_query.dart';
import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/data/bangumi_credential_store.dart';
import 'package:anime/src/data/tmdb_credential_store.dart';
import 'package:anime/src/data/zeluna_backend_catalog_repository.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/domain/subject_content_type.dart';
import 'package:anime/src/player/player_page.dart';
import 'package:anime/src/player/video/native_video_compatibility.dart';
import 'package:anime/src/shared_ui/poster_card.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../test/support/fake_cloud_account_service.dart';

// Opt-in, same production widgets/resolvers/native decoder. No account, media
// injection, VPN settings, OS input automation or normal app storage is used.
// Android must be built with -PzelunaQaApplication=true for an isolated app ID.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'device catalog scrolling and sustained production playback',
    (tester) async {
      const identity = String.fromEnvironment(
        'DEVICE_QA_IDENTITY',
        defaultValue: 'bangumi:464376',
      );
      const episodeNumber = int.fromEnvironment(
        'DEVICE_QA_EPISODE',
        defaultValue: 1,
      );
      final report = <String, Object?>{
        'platform': Platform.operatingSystem,
        'profile_mode': kProfileMode,
        'identity': identity,
        'episode': episodeNumber,
        'passed': false,
      };
      const output = String.fromEnvironment('DEVICE_QA_OUTPUT');
      Future<void> saveFrame(String name, List<int>? bytes) async {
        if (output.isEmpty || bytes == null) return;
        final directory = Directory(output);
        await directory.create(recursive: true);
        await File('${directory.path}/$name.png').writeAsBytes(bytes);
      }

      MediaKit.ensureInitialized();
      await NativeVideoCompatibility.instance.initialize();
      await initializeDesktopWindow();
      final directory = await Directory.systemTemp.createTemp(
        'zeluna-device-qa-',
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
      StreamSubscription<PlayerLog>? logs;
      var stage = 'initialization';
      try {
        final state = await container
            .read(animeControllerProvider.future)
            .timeout(const Duration(seconds: 45));
        final controller = container.read(animeControllerProvider.notifier);
        Widget app(Widget child) => UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: ThemeData.dark(),
            home: PosterNetworkScope(
              catalogBase: Uri.parse(state.services.playbackBackendEndpoint),
              child: child,
            ),
          ),
        );
        stage = 'catalog';
        final watch = Stopwatch()..start();
        final catalog = await controller.queryCatalog(
          const CatalogQuery(contentType: SubjectContentType.anime),
        );
        report['catalog_ms'] = watch.elapsedMilliseconds;
        report['catalog_count'] = catalog.subjects.length;
        expect(catalog.subjects.length, greaterThan(5));
        await tester.pumpWidget(
          app(
            SubjectListPage(title: '番剧', loader: (_) async => catalog.subjects),
          ),
        );
        await tester.pump(const Duration(seconds: 2));
        final imageDeadline = DateTime.now().add(const Duration(seconds: 20));
        var posters = 0;
        while (DateTime.now().isBefore(imageDeadline) && posters == 0) {
          await tester.pump(const Duration(milliseconds: 100));
          posters = tester
              .widgetList<RawImage>(find.byType(RawImage))
              .where((image) => (image.image?.width ?? 0) >= 100)
              .length;
        }
        report['decoded_posters'] = posters;
        expect(posters, greaterThan(0));
        stage = 'scroll';
        final timings = <FrameTiming>[];
        void collect(List<FrameTiming> values) => timings.addAll(values);
        SchedulerBinding.instance.addTimingsCallback(collect);
        try {
          final scrollable = find.byType(Scrollable).first;
          for (var i = 0; i < 8; i++) {
            await tester.timedDrag(
              scrollable,
              Offset(0, i < 4 ? -400 : 400),
              const Duration(milliseconds: 500),
            );
            await tester.pump(const Duration(milliseconds: 150));
          }
          await tester.pump(const Duration(milliseconds: 500));
        } finally {
          SchedulerBinding.instance.removeTimingsCallback(collect);
        }
        final refreshRate = tester.view.display.refreshRate;
        final budgetUs = 1000000 / (refreshRate > 0 ? refreshRate : 60);
        final builds =
            timings.map((t) => t.buildDuration.inMicroseconds).toList()..sort();
        final rasters =
            timings.map((t) => t.rasterDuration.inMicroseconds).toList()
              ..sort();
        double percentile(List<int> values, double fraction) => values.isEmpty
            ? 0
            : values[((values.length - 1) * fraction).round()] / 1000;
        report['scroll'] = {
          'sample_frames': timings.length,
          'display_hz': refreshRate,
          'frame_budget_ms': budgetUs / 1000,
          'build_p95_ms': percentile(builds, .95),
          'raster_p95_ms': percentile(rasters, .95),
          'over_budget_frames': timings
              .where(
                (t) =>
                    t.buildDuration.inMicroseconds > budgetUs ||
                    t.rasterDuration.inMicroseconds > budgetUs,
              )
              .length,
          'over_16ms_frames': timings
              .where(
                (t) =>
                    t.buildDuration.inMicroseconds > 16667 ||
                    t.rasterDuration.inMicroseconds > 16667,
              )
              .length,
        };
        if (kProfileMode) expect(timings.length, greaterThan(60));
        stage = 'search';
        final repository = ZelunaBackendCatalogRepository(
          baseUrl: state.services.playbackBackendEndpoint,
          client: container.read(zelunaBackendHttpClientProvider),
        );
        var matches = <AnimeSubject>[];
        var attempts = 0;
        while (!matches.any((subject) => subject.identityKey == identity) &&
            attempts < 2) {
          attempts++;
          matches = await repository.search('败犬女主太多了');
        }
        report['search_attempts'] = attempts;
        report['search_count'] = matches.length;
        expect(
          matches.any((subject) => subject.identityKey == identity),
          isTrue,
          reason: 'production search must return the reported title',
        );
        final subject = matches.firstWhere((s) => s.identityKey == identity);
        stage = 'detail';
        watch.reset();
        final detail = await controller.detail(subject);
        report['detail_ms'] = watch.elapsedMilliseconds;
        report['episode_count'] = detail.episodes.length;
        final episode = detail.episodes.firstWhere(
          (e) => e.number == episodeNumber,
        );
        await tester.pumpWidget(app(DetailPage(subject: subject)));
        await tester.pump(const Duration(seconds: 1));
        stage = 'playback';
        watch.reset();
        await tester.pumpWidget(
          app(
            PlayerPage(
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
        );
        final errors = <String>[];
        Player? player;
        int? firstFrame;
        var frameBytes = 0;
        var firstPosition = 0;
        final startupDeadline = DateTime.now().add(const Duration(seconds: 90));
        while (DateTime.now().isBefore(startupDeadline) && firstFrame == null) {
          await tester.pump(const Duration(milliseconds: 200));
          final videos = find.byType(Video);
          if (videos.evaluate().isEmpty) continue;
          player ??= tester.widget<Video>(videos.first).controller.player;
          logs ??= player.stream.log.listen((event) {
            if (!const {'error', 'fatal', 'warn'}.contains(event.level)) return;
            final text = event.text.replaceAll(
              RegExp(r'''https?://[^\s\]\)>"']+'''),
              '[URL]',
            );
            if (errors.length < 20 &&
                !RegExp(
                  r'(authorization|cookie|token|secret)\s*[:=]',
                  caseSensitive: false,
                ).hasMatch(text)) {
              errors.add('${event.prefix}: $text');
            }
          });
          await player.setVolume(0);
          if (player.state.position.inMilliseconds < 600 ||
              (player.state.width ?? 0) <= 0) {
            continue;
          }
          final image = await player.screenshot(format: 'image/png');
          frameBytes = image?.length ?? 0;
          if (frameBytes > 1000) {
            firstFrame = watch.elapsedMilliseconds;
            firstPosition = player.state.position.inMilliseconds;
            await saveFrame('first-frame', image);
          }
        }
        report['first_frame_ms'] = firstFrame;
        report['decoded_image_bytes'] = frameBytes;
        report['native_errors'] = errors;
        expect(
          firstFrame,
          isNotNull,
          reason: 'native video must actually decode',
        );
        var observedUri =
            player!.state.playlist.medias[player.state.playlist.index].uri;
        var observedStartPosition = firstPosition;
        var recoveries = 0;
        final replacedWindows = <Map<String, Object?>>[];
        var stalledSamples = 0;
        var maxStallMs = 0;
        var stallMs = 0;
        var previous = player.state.position.inMilliseconds;
        final observation = Stopwatch()..start();
        final recoveryBudget = Stopwatch()..start();
        while (observation.elapsed < const Duration(seconds: 35) &&
            recoveryBudget.elapsed < const Duration(seconds: 120)) {
          await tester.pump(const Duration(milliseconds: 250));
          final current = player.state.position.inMilliseconds;
          final playlist = player.state.playlist;
          final currentUri = playlist.medias.isEmpty
              ? null
              : playlist.medias[playlist.index].uri;
          if (currentUri != observedUri && currentUri != null) {
            replacedWindows.add({
              'observed_ms': observation.elapsedMilliseconds,
              'advanced_ms': previous - observedStartPosition,
              'max_stall_ms': maxStallMs,
            });
            recoveries++;
            observedUri = currentUri;
            observedStartPosition = current;
            previous = current;
            stallMs = 0;
            maxStallMs = 0;
            stalledSamples = 0;
            observation.reset();
          }
          if (current <= previous) {
            stalledSamples++;
            stallMs += 250;
            if (stallMs > maxStallMs) maxStallMs = stallMs;
          } else {
            stallMs = 0;
          }
          previous = current;
        }
        final endImage = await player.screenshot(format: 'image/png');
        await saveFrame('sustained-frame', endImage);
        final sameMedia =
            player.state.playlist.medias[player.state.playlist.index].uri ==
            observedUri;
        report.addAll({
          'observed_ms': observation.elapsedMilliseconds,
          'advanced_ms':
              player.state.position.inMilliseconds - observedStartPosition,
          'recovery_count': recoveries,
          'replaced_windows': replacedWindows,
          'total_playback_check_ms': recoveryBudget.elapsedMilliseconds,
          'same_media': sameMedia,
          'max_stall_ms': maxStallMs,
          'stalled_samples': stalledSamples,
          'end_frame_bytes': endImage?.length ?? 0,
          'width': player.state.width,
          'height': player.state.height,
        });
        expect(endImage?.length ?? 0, greaterThan(1000));
        expect(
          observation.elapsed,
          greaterThanOrEqualTo(const Duration(seconds: 35)),
        );
        expect(
          sameMedia,
          isTrue,
          reason: 'continuous observation must remain on one media',
        );
        expect(
          player.state.position.inMilliseconds - observedStartPosition,
          greaterThan(28000),
        );
        expect(maxStallMs, lessThan(5000));
        report['passed'] = true;
      } finally {
        report['last_stage'] = stage;
        binding.reportData = report;
        // ignore: avoid_print
        print('DEVICE_PLAYBACK_QA ${jsonEncode(report)}');
        await logs?.cancel();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 500));
        container.dispose();
        await Hive.close();
        if (await directory.exists()) await directory.delete(recursive: true);
        await tester.pump(const Duration(milliseconds: 500));
      }
    },
    skip: !const bool.fromEnvironment('DEVICE_PLAYBACK_QA'),
  );
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
