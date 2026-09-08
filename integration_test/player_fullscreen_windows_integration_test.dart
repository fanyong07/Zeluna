import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anime/src/app/desktop_window.dart';
import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/data/playback_source_repository.dart';
import 'package:anime/src/rules/rule_playback_cancellation.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/player/app_fullscreen.dart';
import 'package:anime/src/player/player_page.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

// Opt-in desktop integration test. The real PlayerPage, video decoder, native
// fullscreen channel and Win32 runner are NOT mocked. Only account/storage and
// online data are replaced. No user database or remote service is initialized.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  for (final online in [false, true]) {
    testWidgets(
      online
          ? 'HTTP player keeps fullscreen through episode, line and pause changes'
          : 'real player button, F and Esc restore normal and maximized windows',
      (tester) async {
        final previousFatalHitTests =
            WidgetController.hitTestWarningShouldBeFatal;
        WidgetController.hitTestWarningShouldBeFatal = true;
        addTearDown(() {
          WidgetController.hitTestWarningShouldBeFatal = previousFatalHitTests;
        });
        final playbackEvents = <Map<String, dynamic>>[];
        final previousDebugPrint = debugPrint;
        debugPrint = (message, {wrapWidth}) {
          if (message != null && message.startsWith('playback_trace ')) {
            playbackEvents.add(
              jsonDecode(message.substring('playback_trace '.length))
                  as Map<String, dynamic>,
            );
          }
          previousDebugPrint(message, wrapWidth: wrapWidth);
        };
        addTearDown(() => debugPrint = previousDebugPrint);
        MediaKit.ensureInitialized();
        await initializeDesktopWindow();
        const root = String.fromEnvironment('ZELUNA_TEST_REPOSITORY');
        final repository = root.isEmpty ? Directory.current.path : root;
        final observer = File(
          '$repository/tool/ci/windows_player_window_probe.ps1',
        );
        expect(
          observer.existsSync(),
          isTrue,
          reason: 'Win32 observer required',
        );
        final temporary = await Directory.systemTemp.createTemp(
          'zeluna-player-fullscreen-',
        );
        final probe = File('${temporary.path}/window-probe.exe');
        final compiled = await Process.run('powershell.exe', [
          '-NoProfile',
          '-NonInteractive',
          '-WindowStyle',
          'Hidden',
          '-File',
          observer.path,
          '-CompileTo',
          probe.path,
        ]);
        expect(compiled.exitCode, 0, reason: '${compiled.stderr}');
        expect(probe.existsSync(), isTrue);
        final clip = await _writeTestVideo(temporary);
        final fixture = online ? await _LoopbackVideoFixture.start(clip) : null;
        final snapshots = <Map<String, Object?>>[];
        final mediaErrors = <String>[];
        final keyboardEvents = <Map<String, Object?>>[];
        bool recordKeyboard(KeyEvent event) {
          keyboardEvents.add({
            'type': event.runtimeType.toString(),
            'key': event.logicalKey.debugName,
            'synthesized': event.synthesized,
            'lifecycle': WidgetsBinding.instance.lifecycleState?.name,
            'focus': FocusManager.instance.primaryFocus?.debugLabel,
            'focusWidget': FocusManager
                .instance
                .primaryFocus
                ?.context
                ?.widget
                .runtimeType
                .toString(),
          });
          return false;
        }

        HardwareKeyboard.instance.addHandler(recordKeyboard);
        addTearDown(
          () => HardwareKeyboard.instance.removeHandler(recordKeyboard),
        );
        final account = _IsolatedPlayerAccount(mediaBase: fixture?.baseUri);
        var passed = false;
        addTearDown(() async {
          final fullscreen = AppFullscreenController();
          await fullscreen.setEnabled(false);
          fullscreen.dispose();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(milliseconds: 300));
          const output = String.fromEnvironment('ZELUNA_TEST_OUTPUT');
          final reportDirectory = output.isEmpty
              ? temporary
              : Directory(output);
          await reportDirectory.create(recursive: true);
          final report = File(
            '${reportDirectory.path}/player-fullscreen-${DateTime.now().microsecondsSinceEpoch}.json',
          );
          await report.writeAsString(
            const JsonEncoder.withIndent('  ').convert({
              'passed': passed,
              'mediaTransport': online ? 'loopback_http' : 'local_file',
              'httpRequests': fixture?.requests ?? const [],
              'videoFirstFrames': playbackEvents
                  .where((event) => event['event'] == 'first_frame')
                  .length,
              'mediaOpenRequests': playbackEvents
                  .where((event) => event['event'] == 'line_open_requested')
                  .length,
              'recommendationFirstFrames': account.firstFrames,
              'playbackEvents': playbackEvents,
              'mediaErrors': mediaErrors,
              'keyboardEvents': keyboardEvents,
              'latestPositionMs': account.latestPosition.inMilliseconds,
              'input': 'WidgetTester button tap; targeted Win32 F/Esc messages',
              'scope': 'real PlayerPage/native decoder; isolated account data',
              'snapshots': snapshots,
            }),
          );
          debugPrint('Fullscreen integration evidence: ${report.path}');
          await fixture?.close();
          await clip.delete();
          await probe.delete();
          if (output.isNotEmpty) await temporary.delete();
        });

        await tester.pumpWidget(
          ProviderScope(
            overrides: [animeControllerProvider.overrideWith(() => account)],
            child: MaterialApp(
              home: PlayerPage(
                request: PlaySessionRequest(
                  subject: _subject,
                  episodes: online
                      ? const [_episode, _secondEpisode]
                      : const [_episode],
                  episode: _episode,
                  offlineOnly: !online,
                  initialLine: online
                      ? account.lineFor(_episode)
                      : PlaybackLine(
                          id: 'integration:local',
                          episodeId: _episode.id,
                          providerId: 'local',
                          providerName: 'Local integration fixture',
                          title: 'Generated test video',
                          quality: 'Original',
                          format: 'avi',
                          url: clip.path,
                          available: true,
                          clientVerified: true,
                        ),
                ),
              ),
            ),
          ),
        );
        await _waitFor(
          tester,
          () => find.byType(Video).evaluate().isNotEmpty,
          'native video surface',
        );
        final video = tester.widget<Video>(find.byType(Video).first);
        final errorSubscription = video.controller.player.stream.error.listen((
          error,
        ) {
          mediaErrors.add(error);
          debugPrint('Generated local fixture media error: $error');
        });
        addTearDown(errorSubscription.cancel);
        await _waitFor(
          tester,
          () => account.firstFrames > 0,
          'video first frame',
        );
        await video.controller.waitUntilFirstFrameRendered.timeout(
          const Duration(seconds: 10),
        );
        expect(find.byType(PlayerPage), findsOneWidget);

        Future<Map<String, dynamic>> observe(
          String action,
          String label,
        ) async {
          final response = File(
            '${temporary.path}/observe-${snapshots.length}.json',
          );
          final result = await Process.run(probe.path, [
            '$pid',
            action,
            response.path,
          ]);
          expect(
            response.existsSync(),
            isTrue,
            reason: '$label: observer response',
          );
          final value =
              jsonDecode(await response.readAsString()) as Map<String, dynamic>;
          await response.delete();
          expect(result.exitCode, 0, reason: '$label: ${value['error']}');
          expect(value['error'], isNull, reason: label);
          snapshots.add({
            'label': label,
            ...value,
            'focus': FocusManager.instance.primaryFocus?.debugLabel,
            'focusWidget': FocusManager
                .instance
                .primaryFocus
                ?.context
                ?.widget
                .runtimeType
                .toString(),
            'keyboardEventCount': keyboardEvents.length,
            'lifecycle': WidgetsBinding.instance.lifecycleState?.name,
          });
          await tester.pump(const Duration(milliseconds: 250));
          return value;
        }

        Future<void> expectFullscreen(String label) async {
          await _waitFor(
            tester,
            () => find.byTooltip('退出全屏').evaluate().isNotEmpty,
            '$label: player fullscreen UI',
          );
          final window = await observe('inspect', label);
          expect(window['caption'], isFalse, reason: label);
          expect(window['thickFrame'], isFalse, reason: label);
          expect(window['rect'], window['monitor'], reason: label);
        }

        Future<void> expectRestored(
          String label,
          Map<String, dynamic> before,
        ) async {
          await _waitFor(
            tester,
            () => find.byTooltip('全屏').evaluate().isNotEmpty,
            '$label: player windowed UI',
          );
          final after = await observe('inspect', label);
          for (final key in [
            'rect',
            'style',
            'extendedStyle',
            'maximized',
            'showCommand',
            'normalRect',
          ]) {
            expect(after[key], before[key], reason: '$label: $key');
          }
        }

        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        addTearDown(mouse.removePointer);
        Future<void> revealControls() async {
          // Controls intentionally reveal only at the canvas top/bottom hot zones,
          // not from arbitrary movement over the middle of the video. Drive that
          // real interaction before requiring an actually clickable button.
          final viewport = tester.getRect(find.byType(Video).first);
          await mouse.moveTo(viewport.center);
          await mouse.moveTo(Offset(viewport.center.dx, viewport.bottom - 12));
          await tester.pump();
        }

        Future<void> clickControl(String tooltip) async {
          await revealControls();
          final control = find.byTooltip(tooltip).hitTestable();
          await _waitFor(
            tester,
            () => control.evaluate().length == 1,
            '$tooltip control in bottom hot zone',
          );
          await tester.tap(control);
        }

        await observe('inspect', 'startup:before');
        for (final mode in ['normal', 'maximize']) {
          await observe(mode, '$mode:prepare');
          final before = await observe('inspect', '$mode:before');
          expect(before['caption'], isTrue);
          expect(before['maximized'], mode == 'maximize');
          await clickControl('全屏');
          await expectFullscreen('$mode:button-enter');
          await clickControl('退出全屏');
          await expectRestored('$mode:button-exit', before);
          await observe('key-f', '$mode:F-enter-dispatch');
          await expectFullscreen('$mode:F-enter');
          await observe('key-f', '$mode:F-exit-dispatch');
          await expectRestored('$mode:F-exit', before);
          await observe('key-f', '$mode:Esc-enter-dispatch');
          await expectFullscreen('$mode:Esc-enter');
          await observe('key-escape', '$mode:Esc-exit-dispatch');
          await expectRestored('$mode:Esc-exit', before);
        }
        await _waitFor(
          tester,
          () => account.latestPosition > Duration.zero,
          'real playback progress persisted to isolated account',
        );
        expect(
          account.firstFrames,
          1,
          reason: 'first-frame recommendation recorded once for this episode',
        );
        expect(
          playbackEvents.where(
            (event) => event['event'] == 'line_open_requested',
          ),
          hasLength(1),
          reason: 'fullscreen must not reopen the playback line',
        );
        expect(
          playbackEvents.where((event) => event['event'] == 'first_frame'),
          hasLength(1),
          reason: 'real playback should have one first-frame event',
        );
        if (online) {
          var expectedFrames = 1;
          Future<void> expectNewMedia(PlaybackLine line, String label) async {
            expectedFrames++;
            await _waitFor(
              tester,
              () =>
                  playbackEvents
                          .where((e) => e['event'] == 'first_frame')
                          .length ==
                      expectedFrames &&
                  video
                          .controller
                          .player
                          .state
                          .playlist
                          .medias
                          .singleOrNull
                          ?.uri ==
                      line.url &&
                  video.controller.player.state.position > Duration.zero,
              '$label: real decoder opens expected HTTP media and advances',
            );
            expect(
              playbackEvents.where((e) => e['event'] == 'line_open_requested'),
              hasLength(expectedFrames),
            );
            await expectFullscreen(label);
          }

          for (final mode in ['normal', 'maximize']) {
            await observe(mode, 'http:$mode:prepare');
            final before = await observe('inspect', 'http:$mode:before');
            await clickControl('全屏');
            await expectFullscreen('http:$mode:entered');
            await clickControl('下一集');
            await expectNewMedia(
              account.lineFor(_secondEpisode),
              'http:$mode:next-episode',
            );
            await clickControl('暂停');
            await _waitFor(
              tester,
              () => !video.controller.player.state.playing,
              'native decoder paused',
            );
            await tester.pump(const Duration(milliseconds: 300));
            final pausedAt = video.controller.player.state.position;
            await tester.pump(const Duration(milliseconds: 500));
            expect(
              (video.controller.player.state.position - pausedAt).abs(),
              lessThan(const Duration(milliseconds: 300)),
            );
            await expectFullscreen('http:$mode:paused');
            await clickControl('播放');
            await _waitFor(
              tester,
              () =>
                  video.controller.player.state.playing &&
                  video.controller.player.state.position > pausedAt,
              'native decoder resumes',
            );
            await expectFullscreen('http:$mode:resumed');
            await revealControls();
            final lineButton = find
                .widgetWithText(TextButton, 'Loopback primary')
                .hitTestable();
            await _waitFor(
              tester,
              () => lineButton.evaluate().length == 1,
              'line selector button',
            );
            await tester.tap(lineButton);
            final backupLine = find
                .descendant(
                  of: find.byType(PlaybackSourcePanel),
                  matching: find.text('Loopback backup'),
                )
                .hitTestable();
            await _waitFor(
              tester,
              () => backupLine.evaluate().length == 1,
              'backup HTTP line',
            );
            await tester.tap(backupLine);
            await expectNewMedia(
              account.lineFor(_secondEpisode, backup: true),
              'http:$mode:backup-line',
            );
            await clickControl('上一集');
            await expectNewMedia(
              account.lineFor(_episode),
              'http:$mode:previous-episode',
            );
            await observe('key-escape', 'http:$mode:Esc-exit-dispatch');
            await expectRestored('http:$mode:restored', before);
          }
          expect(
            fixture!.requests.map((r) => r['path']).toSet(),
            containsAll([
              '/episode-1-primary.avi',
              '/episode-2-primary.avi',
              '/episode-2-backup.avi',
            ]),
          );
          expect(
            fixture.requests.every(
              (r) => r['status'] == 200 || r['status'] == 206,
            ),
            isTrue,
          );
          expect(
            playbackEvents.where((e) => e['event'] == 'first_frame'),
            hasLength(7),
          );
          expect(
            playbackEvents.where((e) => e['event'] == 'line_open_requested'),
            hasLength(7),
          );
        }
        expect(find.textContaining('系统未能切换全屏'), findsNothing);
        expect(mediaErrors, isEmpty);
        final beforeLeaving = await observe('inspect', 'leave-player:before');
        await observe('key-f', 'leave-player:F-enter-dispatch');
        await expectFullscreen('leave-player:fullscreen');
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 500));
        final afterLeaving = await observe('inspect', 'leave-player:restored');
        for (final key in [
          'rect',
          'style',
          'extendedStyle',
          'maximized',
          'showCommand',
          'normalRect',
        ]) {
          expect(
            afterLeaving[key],
            beforeLeaving[key],
            reason: 'leave player: $key',
          );
        }
        expect(tester.takeException(), isNull);
        passed = true;
      },
      skip: !Platform.isWindows,
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }
}

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() ready,
  String label,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(ready(), isTrue, reason: 'Timed out: $label');
}

// A generated uncompressed AVI using only Dart byte operations. AVI is a
// supported local-file format; no download, binary fixture or encoder is needed.
Future<File> _writeTestVideo(Directory directory) async {
  const width = 64;
  const height = 36;
  const frameCount = 1800;
  const frameSize = width * height * 3;
  Uint8List words(List<int> values) {
    final data = ByteData(values.length * 4);
    for (var i = 0; i < values.length; i++) {
      data.setUint32(i * 4, values[i], Endian.little);
    }
    return data.buffer.asUint8List();
  }

  Uint8List chunk(String type, List<int> body) =>
      (BytesBuilder(copy: false)
            ..add(ascii.encode(type))
            ..add(words([body.length]))
            ..add(body)
            ..add(body.length.isOdd ? [0] : const []))
          .takeBytes();
  Uint8List list(String type, List<int> body) => chunk(
    'LIST',
    (BytesBuilder(copy: false)
          ..add(ascii.encode(type))
          ..add(body))
        .takeBytes(),
  );
  final streamHeader = ByteData(56);
  streamHeader.buffer.asUint8List().setRange(0, 8, ascii.encode('vidsDIB '));
  streamHeader.setUint32(20, 1, Endian.little);
  streamHeader.setUint32(24, 10, Endian.little);
  streamHeader.setUint32(32, frameCount, Endian.little);
  streamHeader.setUint32(36, frameSize, Endian.little);
  streamHeader.setUint32(40, 0xffffffff, Endian.little);
  streamHeader.setInt16(52, width, Endian.little);
  streamHeader.setInt16(54, height, Endian.little);
  final bitmap = ByteData(40)
    ..setUint32(0, 40, Endian.little)
    ..setInt32(4, width, Endian.little)
    ..setInt32(8, height, Endian.little)
    ..setUint16(12, 1, Endian.little)
    ..setUint16(14, 24, Endian.little)
    ..setUint32(20, frameSize, Endian.little);
  final headers = list(
    'hdrl',
    (BytesBuilder(copy: false)
          ..add(
            chunk(
              'avih',
              words([
                100000,
                frameSize * 10,
                0,
                0x10,
                frameCount,
                0,
                1,
                frameSize,
                width,
                height,
                0,
                0,
                0,
                0,
              ]),
            ),
          )
          ..add(
            list(
              'strl',
              (BytesBuilder(copy: false)
                    ..add(chunk('strh', streamHeader.buffer.asUint8List()))
                    ..add(chunk('strf', bitmap.buffer.asUint8List())))
                  .takeBytes(),
            ),
          ))
        .takeBytes(),
  );
  final frames = BytesBuilder(copy: false);
  final index = BytesBuilder(copy: false);
  var offset = 4;
  for (var frame = 0; frame < frameCount; frame++) {
    final pixels = Uint8List(frameSize)
      ..fillRange(0, frameSize, 40 + frame % 180);
    final encoded = chunk('00db', pixels);
    frames.add(encoded);
    index
      ..add(ascii.encode('00db'))
      ..add(words([0x10, offset, frameSize]));
    offset += encoded.length;
  }
  final body =
      (BytesBuilder(copy: false)
            ..add(ascii.encode('AVI '))
            ..add(headers)
            ..add(list('movi', frames.takeBytes()))
            ..add(chunk('idx1', index.takeBytes())))
          .takeBytes();
  return File(
    '${directory.path}/generated.avi',
  ).writeAsBytes(chunk('RIFF', body));
}

const _subject = AnimeSubject(
  id: -9001,
  title: 'Fullscreen integration fixture',
  originalTitle: '',
  summary: '',
  coverUrl: null,
  bannerUrl: null,
  date: null,
  platform: 'local',
  language: '',
  region: '',
  status: '',
  categories: [],
  tags: [],
  totalEpisodes: 2,
  source: 'direct',
);
const _episode = AnimeEpisode(
  id: -9002,
  subjectId: -9001,
  number: 1,
  title: 'Local video',
  airdate: null,
  duration: '180',
  description: '',
);

const _secondEpisode = AnimeEpisode(
  id: -9003,
  subjectId: -9001,
  number: 2,
  title: 'Second generated video',
  airdate: null,
  duration: '180',
  description: '',
);

class _IsolatedPlayerAccount extends AnimeController {
  _IsolatedPlayerAccount({this.mediaBase});
  final Uri? mediaBase;

  PlaybackLine lineFor(AnimeEpisode episode, {bool backup = false}) {
    final provider = backup ? 'backup' : 'primary';
    return PlaybackLine(
      id: 'integration:${episode.id}:$provider',
      episodeId: episode.id,
      providerId: 'integration:$provider',
      providerName: 'Loopback $provider',
      title: 'Generated episode ${episode.number}',
      quality: 'Original',
      format: 'avi',
      url: mediaBase!
          .resolve('/episode-${episode.number}-$provider.avi')
          .toString(),
      available: true,
      clientVerified: true,
    );
  }

  @override
  Future<List<PlaybackLine>> linesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    RulePlaybackCancellationToken? cancellationToken,
  }) async => [lineFor(episode), lineFor(episode, backup: true)];

  @override
  Stream<PlaybackLineLookupUpdate> lineUpdatesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    RulePlaybackCancellationToken? cancellationToken,
  }) async* {
    yield PlaybackLineLookupUpdate(
      lines: await linesForEpisode(
        subject,
        episode,
        cancellationToken: cancellationToken,
      ),
      completedRules: 1,
      totalRules: 1,
      phase: PlaybackLineLookupPhase.complete,
    );
  }

  @override
  Future<PlaybackLine> verifyPlaybackLine(
    PlaybackLine line, {
    bool enrichMetadata = true,
    bool forceRefresh = false,
    RulePlaybackCancellationToken? cancellationToken,
  }) async => line;

  @override
  Future<List<PlaybackLine>> prepareSingleBackupForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    required PlaybackLine currentLine,
    RulePlaybackCancellationToken? cancellationToken,
  }) async => [lineFor(episode, backup: true)];

  var firstFrames = 0;
  Duration latestPosition = Duration.zero;

  @override
  Future<AnimeState> build() async => const AnimeState(
    homeFeed: AnimeHomeFeed(
      hero: _subject,
      recent: [],
      recommended: [],
      index: [],
      categories: [],
      tags: [],
    ),
    settings: PlaybackSettings(
      rememberLine: false,
      autoNext: false,
      autoSwitchLine: false,
    ),
    danmaku: DanmakuSettings(enabled: false),
  );

  @override
  String? rememberedPlaybackProvider(AnimeSubject subject) => null;

  @override
  Future<DanmakuTimeline> danmakuTimelineForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    bool forceRefresh = false,
  }) async => const DanmakuTimeline();

  @override
  Future<void> recordRecommendationFirstFrame(
    AnimeSubject subject,
    AnimeEpisode episode, {
    int? expectedAccountContextVersion,
  }) async {
    firstFrames++;
  }

  @override
  Future<void> recordRecommendationEffectiveWatch(
    AnimeSubject subject,
    AnimeEpisode episode, {
    int? expectedAccountContextVersion,
  }) async {}

  @override
  Future<void> recordRecommendationCompleted(
    AnimeSubject subject,
    AnimeEpisode episode, {
    int? expectedAccountContextVersion,
  }) async {}

  @override
  Future<void> updatePlaybackProgress(
    AnimeSubject subject,
    AnimeEpisode episode, {
    required Duration position,
    required Duration duration,
    int? expectedAccountContextVersion,
  }) async {
    latestPosition = position;
  }
}

// Exposes only the generated clip on loopback, never a directory or user data.
// Range requests and media decoding are real; catalogue discovery is isolated.
class _LoopbackVideoFixture {
  _LoopbackVideoFixture(this.server);
  final HttpServer server;
  final requests = <Map<String, Object?>>[];
  Uri get baseUri => Uri.parse('http://127.0.0.1:${server.port}');

  static Future<_LoopbackVideoFixture> start(File clip) async {
    final fixture = _LoopbackVideoFixture(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    final size = await clip.length();
    fixture.server.listen((request) async {
      final response = request.response;
      try {
        if (!RegExp(
              r'^/episode-[12]-(primary|backup)\.avi$',
            ).hasMatch(request.uri.path) ||
            !['GET', 'HEAD'].contains(request.method)) {
          response.statusCode = HttpStatus.notFound;
          await response.close();
          return;
        }
        var start = 0;
        var end = size - 1;
        final range = request.headers.value(HttpHeaders.rangeHeader);
        if (range != null) {
          final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
          if (match == null) {
            throw const FormatException('Unsupported fixture range');
          }
          start = int.parse(match[1]!);
          if (match[2]!.isNotEmpty) end = int.parse(match[2]!);
          if (end >= size) end = size - 1;
          if (start > end || start >= size) {
            throw const FormatException('Invalid fixture range');
          }
          response.statusCode = HttpStatus.partialContent;
          response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-$end/$size',
          );
        }
        response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        response.headers.contentType = ContentType('video', 'x-msvideo');
        response.contentLength = end - start + 1;
        fixture.requests.add({
          'path': request.uri.path,
          'range': range,
          'status': response.statusCode,
        });
        if (request.method == 'GET') {
          await response.addStream(clip.openRead(start, end + 1));
        }
        await response.close();
      } on FormatException {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$size');
        await response.close();
      } on HttpException {
        // Switching media cancels an in-flight response, as a normal player does.
      } on SocketException {
        // Decoder stop/dispose can close the connection before the clip finishes.
      }
    });
    return fixture;
  }

  Future<void> close() => server.close(force: true);
}
