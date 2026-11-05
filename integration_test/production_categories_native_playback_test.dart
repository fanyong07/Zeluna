import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anime/src/app/desktop_window.dart';
import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/data/zeluna_backend_playback_repository.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/player/player_page.dart';
import 'package:anime/src/player/video/native_android_surface_controller.dart';
import 'package:anime/src/player/video/native_video_compatibility.dart';
import 'package:anime/src/player/video/native_video_controller.dart';
import 'package:anime/src/rules/rule_playback_resolver.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'support/production_category_player_environment.dart';

/// Separate PUBLIC BACKEND regression, not proof of a local adapter/server fix.
/// Both defines are required; without them no clients, stores or players start:
///   --dart-define=PRODUCTION_CATEGORY_NATIVE_QA=true
///   --dart-define=PRODUCTION_CATEGORY_NATIVE_QA_CASES=anime,series,movie
/// Optional PRODUCTION_CATEGORY_NATIVE_QA_BASE defaults to the public production
/// endpoint. ZELUNA_NATIVE_QA_HOLD_SECONDS (0..15) lets an external runner capture
/// the actual painted page at ADAPTER_QA_VISIBLE; this test saves no screenshots.
/// Canonical subject metadata is input, not a claim of fresh catalogue search.
/// Backend order is preserved: at most six quick plus six full candidates,
/// a separate 65-second full-discovery grace, and a four-minute case budget.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('PRODUCTION_CATEGORY_NATIVE_QA');
  const caseList = String.fromEnvironment(
    'PRODUCTION_CATEGORY_NATIVE_QA_CASES',
  );
  const endpoint = String.fromEnvironment(
    'PRODUCTION_CATEGORY_NATIVE_QA_BASE',
    defaultValue: 'https://api.zeluna.top',
  );
  final selected = caseList.split(',').map((value) => value.trim()).toSet();
  final optedIn = enabled && caseList.trim().isNotEmpty;
  if (!optedIn) {
    testWidgets(
      'production categories require both explicit opt-in flags',
      (tester) async {},
      skip: true,
    );
    return;
  }
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  final audit = <String, Object?>{
    'platform': Platform.operatingSystem,
    'pipeline':
        'public_backend_quick_or_full->production_repository->RulePlaybackResolver->PlayerPage->NativeVideoController',
    'local_adapter_repair_validation': false,
    'catalog_freshness': 'canonical_metadata_inputs_not_catalog_search',
    'candidate_limit_per_case': 12,
    'quick_candidate_limit': 6,
    'full_candidate_limit': 6,
    'account_and_progress': 'isolated_in_memory',
    'page_line_lookup': 'isolated_selected_live_verified_route_only',
    'source_substitution': false,
    'hive': 'test_temporary_subtitle_store_only',
    'cases': <Object?>[],
  };
  binding.reportData = audit;
  setUpAll(() async {
    expect(
      selected.every(_samples.containsKey),
      isTrue,
      reason: 'CASES accepts only anime,series,movie',
    );
    final uri = Uri.tryParse(endpoint);
    expect(
      uri?.scheme == 'https' && uri!.userInfo.isEmpty,
      isTrue,
      reason: 'This regression requires an HTTPS public backend',
    );
    expect(
      ZelunaBackendPlaybackRepository.normalizeBaseUrl(endpoint),
      isNotNull,
    );
    audit['backend_host'] = uri!.host;
    audit['backend_sha256'] = _digest(endpoint);
    MediaKit.ensureInitialized();
    await NativeVideoCompatibility.instance.initialize();
    await initializeDesktopWindow();
  });

  for (final sample in _samples.values.where(
    (item) => selected.contains(item.key),
  )) {
    testWidgets(
      'public ${sample.key} full PlayerPage sustains real decoded video',
      (tester) async {
        final report = <String, Object?>{
          'category': sample.key,
          'platform': Platform.operatingSystem,
          'pipeline': audit['pipeline'],
          'local_adapter_repair_validation': false,
          'stable_id': sample.subject.identityKey,
          'title': sample.subject.title,
          'year': sample.subject.year,
          'episode': 1,
          'candidate_limit': 12,
          'quick_candidate_limit': 6,
          'full_candidate_limit': 6,
          'case_budget_ms': 240000,
          'passed': false,
          'lookups': <Object?>[],
          'attempts': <Object?>[],
        };
        (audit['cases'] as List).add(report);
        final clock = Stopwatch()..start();
        final caseDeadline = DateTime.now().add(const Duration(minutes: 4));
        final backend = ZelunaBackendPlaybackRepository(
          baseUrl: endpoint,
          requestTimeout: const Duration(seconds: 20),
        );
        final resolver = RulePlaybackResolver(
          timeout: const Duration(seconds: 20),
        );
        final token = RulePlaybackCancellationToken();
        final temporary = await Directory.systemTemp.createTemp(
          'zeluna-production-category-',
        );
        Hive.init('${temporary.path}/hive');
        addTearDown(() async {
          token.cancel();
          backend.dispose();
          resolver.resetExecutionScope();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(milliseconds: 500));
          await Hive.close();
          // The exact directory returned by createTemp, never an app profile.
          if (await temporary.exists()) await temporary.delete(recursive: true);
        });
        final tried = <String>{};
        var attempts = 0;
        var quickAttempts = 0;
        var fullAttempts = 0;
        var completed = false;
        try {
          // A quick empty response is final for quick mode, not proof of an
          // empty category. Full discovery can be partial while work warms up.
          DateTime? fullDiscoveryDeadline;
          for (
            var round = 0;
            !completed && attempts < 12 && fullAttempts < 6;
            round++
          ) {
            if (DateTime.now().isAfter(caseDeadline) ||
                (fullDiscoveryDeadline != null &&
                    DateTime.now().isAfter(fullDiscoveryDeadline))) {
              break;
            }
            final full = round > 0;
            if (full) {
              fullDiscoveryDeadline ??= DateTime.now().add(
                const Duration(seconds: 65),
              );
            }
            report['failure_stage'] = full
                ? 'full_discovery'
                : 'quick_discovery';
            final routes = await backend
                .linesForEpisodeMode(
                  sample.subject,
                  sample.episode,
                  expandAll: full,
                  cancellationToken: token,
                )
                .timeout(
                  _remainingBudget(caseDeadline, const Duration(seconds: 22)),
                );
            final candidates = routes
                .where(_hasCandidate)
                .toList(growable: false);
            (report['lookups'] as List).add({
              'mode': full ? 'full' : 'quick',
              'round': round,
              'inventory_count': routes.length,
              'candidate_count': candidates.length,
              'partial': routes.any((line) => line.cacheState == 'partial'),
              'elapsed_ms': clock.elapsedMilliseconds,
            });
            for (final candidate in candidates) {
              if (attempts >= 12 ||
                  (!full && quickAttempts >= 6) ||
                  (full && fullAttempts >= 6) ||
                  completed ||
                  DateTime.now().isAfter(caseDeadline)) {
                break;
              }
              if (!tried.add(candidate.id)) continue;
              attempts++;
              if (full) {
                fullAttempts++;
              } else {
                quickAttempts++;
              }
              report['failure_stage'] = 'candidate_validation';
              final attempt = <String, Object?>{
                'number': attempts,
                'discovery_mode': full ? 'full' : 'quick',
                'source_provider': _label(candidate.providerName),
                'source_name': _label(candidate.sourceName),
                'provider_sha256': _digest(candidate.providerId),
                'route_sha256': _digest(candidate.id),
                'client_resolver': candidate.clientResolver != null,
                'failure_stage': 'production_verifier',
                'passed': false,
              };
              (report['attempts'] as List).add(attempt);
              try {
                final verified = await resolver
                    .verifyPlaybackLine(
                      line: candidate,
                      enrichMetadata: false,
                      forceRefresh: true,
                      cancellationToken: token,
                    )
                    .timeout(
                      _remainingBudget(
                        caseDeadline,
                        const Duration(seconds: 23),
                      ),
                    );
                attempt['client_verified'] = verified.clientVerified;
                attempt['available'] = verified.available;
                attempt['probe_error'] = _probeErrorCode(
                  verified.sourceErrorCategory,
                );
                if (verified.id != candidate.id ||
                    verified.providerId != candidate.providerId) {
                  throw const _QaFailure('verification_identity_changed');
                }
                if (!verified.available ||
                    !verified.clientVerified ||
                    verified.url == null) {
                  throw const _QaFailure(
                    'production_verifier_no_playable_media',
                  );
                }
                attempt['media_host'] = Uri.parse(verified.url!).host;
                attempt['media_sha256'] = _digest(verified.url!);
                await _provePage(
                  tester,
                  sample,
                  verified,
                  resolver,
                  endpoint,
                  attempt,
                  caseDeadline,
                );
                attempt.remove('failure_stage');
                attempt['passed'] = completed = true;
              } on _QaFailure catch (failure) {
                attempt['failure_code'] = failure.code;
              } on TimeoutException {
                attempt['failure_code'] = 'candidate_operation_timeout';
              } catch (_) {
                // No exception text, URL, request header or raw response enters
                // the evidence, including failure paths and later candidates.
                attempt['failure_code'] = 'candidate_unexpected_failure';
              }
            }
            if (fullDiscoveryDeadline != null &&
                DateTime.now().isAfter(fullDiscoveryDeadline)) {
              break;
            }
            if (full && !completed && fullAttempts < 6) {
              await tester.pump(
                _remainingBudget(caseDeadline, const Duration(seconds: 3)),
              );
            }
          }
          report['passed'] = completed;
          if (completed) {
            report.remove('failure_stage');
          } else if (DateTime.now().isAfter(caseDeadline)) {
            report['failure_code'] = 'case_budget_exhausted';
          }
        } on _QaFailure catch (failure) {
          report['failure_code'] = failure.code;
        } catch (_) {
          report['failure_code'] = 'public_backend_case_failed';
        } finally {
          report['elapsed_ms'] = clock.elapsedMilliseconds;
          report['quick_attempts'] = quickAttempts;
          report['full_attempts'] = fullAttempts;
          debugPrint('PRODUCTION_CATEGORY_NATIVE_QA ${jsonEncode(report)}');
        }
        expect(
          completed,
          isTrue,
          reason:
              '${sample.key}: public backend route must prove actual PlayerPage decoded video',
        );
      },
      skip: !Platform.isAndroid && !Platform.isWindows,
      timeout: const Timeout(Duration(minutes: 5)),
    );
  }
}

Future<void> _provePage(
  WidgetTester tester,
  _CategorySample sample,
  PlaybackLine verified,
  RulePlaybackResolver resolver,
  String endpoint,
  Map<String, Object?> evidence,
  DateTime caseDeadline,
) async {
  final account = ProductionCategoryPlayerAccount(
    subject: sample.subject,
    episode: sample.episode,
    line: verified,
    resolver: resolver,
    endpoint: endpoint,
  );
  final container = ProviderContainer(
    overrides: [animeControllerProvider.overrideWith(() => account)],
  );
  NativeVideoController? active;
  int Function()? readSerial;
  final trace = <Map<String, Object?>>[];
  final timeouts = <String>[];
  var nativeErrors = 0;
  final previousDebugPrint = debugPrint;
  debugPrint = (message, {wrapWidth}) {
    if (message != null && message.startsWith('playback_trace ')) {
      try {
        final event = jsonDecode(message.substring('playback_trace '.length));
        if (event is Map && event['event'] is String && trace.length < 128) {
          trace.add({
            'event': _label(event['event'] as String),
            'elapsed_ms': event['elapsed_ms'] is num
                ? event['elapsed_ms']
                : null,
            if (event['provider'] is String)
              'provider_sha256': _digest(event['provider'] as String),
          });
        }
      } catch (_) {}
      // Do not relay arbitrary provider identifiers from production traces.
      return;
    }
    previousDebugPrint(message, wrapWidth: wrapWidth);
  };
  evidence['trace'] = trace;
  evidence['timeouts'] = timeouts;
  evidence['first_frame_deadline_ms'] = 45000;
  evidence['failure_stage'] = 'isolated_state_initialization';
  try {
    await container
        .read(animeControllerProvider.future)
        .timeout(_remainingBudget(caseDeadline, const Duration(seconds: 5)));
    evidence['failure_stage'] = 'page_mount';
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: PlayerPage(
            request: PlaySessionRequest(
              subject: sample.subject,
              episodes: [sample.episode],
              episode: sample.episode,
              initialLine: verified,
            ),
            nativeVideoControllerFactory: (serial) {
              readSerial = serial;
              final controller = NativeVideoController(readOpenSerial: serial);
              active = controller;
              controller.track(
                controller.player.stream.error.listen((_) => nativeErrors++),
              );
              return controller;
            },
          ),
        ),
      ),
    );
    evidence['failure_stage'] = 'native_first_frame';
    final firstFrameBudget = _remainingBudget(
      caseDeadline,
      const Duration(seconds: 45),
    );
    final deadline = DateTime.now().add(firstFrameBudget);
    bool firstFrame() =>
        account.firstFrames > 0 &&
        active?.hasDecodedFrame == true &&
        trace.any(
          (event) =>
              event['event'] == 'first_frame' &&
              event['provider_sha256'] == _digest(verified.providerId),
        );
    var watchdogStarted = false;
    var observedTimeout = false;
    while (!firstFrame() && DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
      watchdogStarted |= active?.awaitingFirstFrame == true;
      if (watchdogStarted &&
          !observedTimeout &&
          active?.awaitingFirstFrame == false &&
          active?.hasDecodedFrame == false) {
        // This seam exposes watchdog activity, not its internal soft/hard phase.
        timeouts.add('native_watchdog_ended_without_decoded_frame');
        observedTimeout = true;
      }
    }
    evidence['first_frame_callbacks'] = account.firstFrames;
    evidence['first_frame_callback_ms'] = account.firstFrameMs;
    evidence['first_frame_trace_count'] = trace
        .where((event) => event['event'] == 'first_frame')
        .length;
    if (!firstFrame()) {
      timeouts.add('test_first_frame_deadline');
      throw const _QaFailure('page_no_actual_first_frame');
    }
    evidence['failure_stage'] = 'native_surface_validation';
    final controller = active!;
    final player = controller.player;
    if (player.platform is! NativePlayer ||
        find.byType(PlayerPage).evaluate().length != 1 ||
        find.byType(Video).evaluate().isEmpty) {
      throw const _QaFailure('not_actual_native_player_page');
    }
    final serial = readSerial!();
    final surface = controller.surfaceController;
    final samples = <Map<String, Object?>>[];
    final screenshots = <String>[];
    evidence['continuous_samples'] = samples;
    evidence['decoded_screenshot_sha256'] = screenshots;
    evidence['frame_proof'] = surface is NativeAndroidSurfaceController
        ? 'android_current_surface_consumed_buffers'
        : 'native_decoded_screenshots';
    evidence['failure_stage'] = 'sustained_decoded_frames';
    final timer = Stopwatch()..start();
    for (var second = 0; second <= 12; second++) {
      _remainingBudget(caseDeadline, const Duration(seconds: 1));
      if (readSerial!() != serial ||
          !controller.hasDecodedFrame ||
          !player.state.playing) {
        throw const _QaFailure('native_open_changed_or_stopped');
      }
      if (surface is NativeAndroidSurfaceController) {
        if (!await surface
            .readFrame(serial: serial)
            .timeout(
              _remainingBudget(caseDeadline, const Duration(seconds: 3)),
            )) {
          throw const _QaFailure('no_current_android_surface_image');
        }
      } else {
        final bytes = await player
            .screenshot(format: 'image/png')
            .timeout(
              _remainingBudget(caseDeadline, const Duration(seconds: 3)),
            );
        if (bytes == null || bytes.length <= 64) {
          throw const _QaFailure('no_decoded_screenshot');
        }
        screenshots.add(_digestBytes(bytes));
      }
      samples.add({
        'second': second,
        'elapsed_ms': timer.elapsedMilliseconds,
        'open_serial': serial,
        'position_ms': player.state.position.inMilliseconds,
        'buffering': player.state.buffering,
        ...controller.frameDiagnostics,
      });
      if (second < 12) {
        await tester.pump(
          _remainingBudget(caseDeadline, const Duration(seconds: 1)),
        );
      }
    }
    final progress =
        (samples.last['position_ms'] as int) -
        (samples.first['position_ms'] as int);
    if (timer.elapsed < const Duration(seconds: 12) || progress < 9500) {
      throw const _QaFailure('media_clock_not_sustained_12_seconds');
    }
    if (surface is NativeAndroidSurfaceController) {
      for (var i = 1; i < samples.length; i++) {
        if ((samples[i]['surface_frames'] as int) <=
            (samples[i - 1]['surface_frames'] as int)) {
          throw const _QaFailure('android_surface_buffers_stalled');
        }
      }
    } else if (screenshots.toSet().length < 2) {
      throw const _QaFailure('decoded_picture_not_changing');
    }
    evidence['failure_stage'] = 'visible_capture_hold';
    debugPrint(
      'ADAPTER_QA_VISIBLE ${jsonEncode({'provider': sample.key, 'stable_id': sample.subject.identityKey, 'source_provider': _label(verified.providerName), 'sample': samples.last})}',
    );
    const hold = int.fromEnvironment('ZELUNA_NATIVE_QA_HOLD_SECONDS');
    if (hold > 0) {
      await tester.pump(
        _remainingBudget(caseDeadline, Duration(seconds: hold.clamp(0, 15))),
      );
    }
    evidence['failure_stage'] = 'ui_pause_dispatch';
    evidence['before_pause_playing'] = player.state.playing;
    evidence['before_pause_buffering'] = player.state.buffering;
    evidence['before_pause_video_widgets'] = find
        .byType(Video)
        .evaluate()
        .length;
    if (readSerial!() != serial) {
      throw const _QaFailure('native_open_changed_before_ui_pause');
    }
    if (!player.state.playing) {
      throw const _QaFailure('native_stopped_before_ui_pause');
    }
    await _pauseThroughUi(tester);
    evidence['failure_stage'] = 'ui_pause_stability';
    await tester.pump(
      _remainingBudget(caseDeadline, const Duration(milliseconds: 500)),
    );
    final paused = player.state.position;
    await tester.pump(
      _remainingBudget(caseDeadline, const Duration(seconds: 1)),
    );
    final pauseDelta = (player.state.position - paused).inMilliseconds.abs();
    evidence['pause_position_delta_ms'] = pauseDelta;
    if (player.state.playing || pauseDelta >= 300 || readSerial!() != serial) {
      throw const _QaFailure('ui_pause_not_stable');
    }
    evidence['pause_stable'] = true;
    evidence['failure_stage'] = 'flutter_exception_check';
    if (tester.takeException() != null) {
      throw const _QaFailure('flutter_page_exception');
    }
  } finally {
    evidence['first_frame_callbacks'] = account.firstFrames;
    evidence['first_frame_callback_ms'] = account.firstFrameMs;
    evidence['first_frame_trace_count'] = trace
        .where((event) => event['event'] == 'first_frame')
        .length;
    evidence['native_error_count'] = nativeErrors;
    evidence['last_native'] = active?.frameDiagnostics;
    try {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 500));
    } finally {
      container.dispose();
      debugPrint = previousDebugPrint;
    }
    // PlayerPage alone owns/disposes its real NativeVideoController.
  }
}

Future<void> _pauseThroughUi(WidgetTester tester) async {
  if (find.byType(Video).evaluate().isEmpty) {
    throw const _QaFailure('video_surface_lost_before_ui_pause');
  }
  final video = find.byType(Video).first;
  if (Platform.isWindows) {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    try {
      final rect = tester.getRect(video);
      await mouse.addPointer(location: rect.center);
      await mouse.moveTo(Offset(rect.center.dx, rect.bottom - 12));
      await tester.pump(const Duration(milliseconds: 100));
    } finally {
      await mouse.removePointer();
    }
  } else if (find.byTooltip('暂停').hitTestable().evaluate().isEmpty) {
    await tester.tapAt(tester.getCenter(video));
    await tester.pump(const Duration(milliseconds: 100));
  }
  final button = find.byTooltip('暂停').hitTestable();
  if (button.evaluate().isEmpty) {
    throw const _QaFailure('pause_control_not_hit_testable');
  }
  await tester.tap(button.first);
}

Duration _remainingBudget(DateTime deadline, Duration maximum) {
  final remaining = deadline.difference(DateTime.now());
  if (remaining < maximum) {
    throw const _QaFailure('case_budget_exhausted');
  }
  // Never shorten the 12-second samples or the 500ms + 1s pause check merely
  // to squeeze a late candidate into the deadline.
  return maximum;
}

// The model exposes sourceErrorCategory, not raw probe errors. Backend values
// may be arbitrary text: only resolver-owned fixed codes are released here.
String _probeErrorCode(String value) {
  if (value.isEmpty) return 'none';
  const fixed = {
    'timeout',
    'invalid_media',
    'tls',
    'policy',
    'connection',
    'probe_failed',
    'media_unreachable',
  };
  return fixed.contains(value) ||
          RegExp(r'^http_[1-5][0-9]{2}$').hasMatch(value)
      ? value
      : 'other';
}

bool _hasCandidate(PlaybackLine line) {
  if (line.clientResolver != null) return true;
  final uri = Uri.tryParse(line.url ?? '');
  return uri != null &&
      uri.host.isNotEmpty &&
      const {'http', 'https'}.contains(uri.scheme);
}

String _digest(String value) => _digestBytes(utf8.encode(value));
String _digestBytes(List<int> value) => sha256.convert(value).toString();
String _label(String value) {
  final text = value.trim();
  if (text.isEmpty) return 'unspecified';
  if (text.length > 100 ||
      text.contains('://') ||
      RegExp(
        r'[?&=\r\n]|authorization|cookie|token|secret|bearer',
        caseSensitive: false,
      ).hasMatch(text)) {
    return 'redacted';
  }
  return text;
}

class _QaFailure implements Exception {
  const _QaFailure(this.code);
  final String code;
}

class _CategorySample {
  const _CategorySample(this.key, this.subject);
  final String key;
  final AnimeSubject subject;
  AnimeEpisode get episode => AnimeEpisode(
    id: subject.id * 1000 + 1,
    subjectId: subject.id,
    number: 1,
    title: key == 'movie' ? '正片' : '第1集',
    airdate: null,
    duration: '',
    description: '',
    seasonNumber: key == 'movie' ? null : 1,
    seasonEpisodeNumber: key == 'movie' ? null : 1,
  );
}

const _samples = {
  'anime': _CategorySample(
    'anime',
    AnimeSubject(
      id: 400602,
      stableKey: 'bangumi:400602',
      source: 'bangumi',
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
    ),
  ),
  'series': _CategorySample(
    'series',
    AnimeSubject(
      id: 155441,
      stableKey: 'tmdb:tv:155441',
      source: 'tmdb:tv',
      title: '开端',
      originalTitle: '开端',
      summary: '',
      coverUrl: null,
      bannerUrl: null,
      date: '2022-01-11',
      platform: 'TV',
      language: '普通话',
      region: '中国大陆',
      status: '完结',
      categories: [],
      tags: [],
      totalEpisodes: 15,
    ),
  ),
  'movie': _CategorySample(
    'movie',
    AnimeSubject(
      id: 535167,
      stableKey: 'tmdb:movie:535167',
      source: 'tmdb:movie',
      title: '流浪地球',
      originalTitle: '流浪地球',
      summary: '',
      coverUrl: null,
      bannerUrl: null,
      date: '2019-02-05',
      platform: 'Movie',
      language: '普通话',
      region: '中国大陆',
      status: '已上映',
      categories: [],
      tags: [],
      totalEpisodes: 1,
    ),
  ),
};
