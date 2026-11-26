import 'dart:convert';
import 'dart:io';
import 'support/generated_player_video.dart';
import 'support/isolated_player_environment.dart';

import 'package:anime/src/app/desktop_window.dart';
import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/player/app_fullscreen.dart';
import 'package:anime/src/player/player_page.dart';
import 'package:anime/src/player/danmaku_overlay.dart';
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
        final clip = await writeGeneratedPlayerTestVideo(temporary);
        final fixture = online ? await LoopbackPlayerVideo.start(clip) : null;
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
        final account = IsolatedPlayerTestAccount(mediaBase: fixture?.baseUri);
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
              'danmakuEpisodeRequests': account.danmakuRequests,
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
                  subject: online
                      ? playerTestSubject.copyWith(source: 'integration')
                      : playerTestSubject,
                  episodes: online
                      ? const [playerTestEpisode, playerTestSecondEpisode]
                      : const [playerTestEpisode],
                  episode: playerTestEpisode,
                  offlineOnly: !online,
                  initialLine: online
                      ? account.lineFor(playerTestEpisode)
                      : PlaybackLine(
                          id: 'integration:local',
                          episodeId: playerTestEpisode.id,
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
        expect(
          account.danmakuRequests,
          isEmpty,
          reason: 'disabled danmaku must not compete with video startup',
        );
        if (online) {
          account.enableDanmaku();
          await _waitFor(
            tester,
            () => account.danmakuRequests.isNotEmpty,
            'enabling danmaku during playback loads without opening a panel',
          );
          await _waitFor(
            tester,
            () => find.text('自动弹幕第1集').evaluate().isNotEmpty,
            'real PlayerPage paints timeline comments without opening a panel',
          );
          expect(account.danmakuRequests, [playerTestEpisode.id]);
        }

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
            await _waitFor(tester, () {
              final overlays = tester.widgetList<RemoteDanmakuOverlay>(
                find.byType(RemoteDanmakuOverlay),
              );
              return overlays.any(
                (overlay) =>
                    overlay.comments.isNotEmpty &&
                    overlay.comments.first.id.startsWith('${line.episodeId}:'),
              );
            }, '$label: new episode loads danmaku without opening a panel');
            await expectFullscreen(label);
          }

          for (final mode in ['normal', 'maximize']) {
            await observe(mode, 'http:$mode:prepare');
            final before = await observe('inspect', 'http:$mode:before');
            await clickControl('全屏');
            await expectFullscreen('http:$mode:entered');
            await clickControl('下一集');
            await expectNewMedia(
              account.lineFor(playerTestSecondEpisode),
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
              account.lineFor(playerTestSecondEpisode, backup: true),
              'http:$mode:backup-line',
            );
            await clickControl('上一集');
            await expectNewMedia(
              account.lineFor(playerTestEpisode),
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
