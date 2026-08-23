import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/player/player_page.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'Android landscape matches the desktop primary controls without overflow',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.devicePixelRatio = 1;
      final danmakuInput = TextEditingController();
      addTearDown(danmakuInput.dispose);

      for (final size in const <Size>[
        Size(568, 320),
        Size(640, 360),
        Size(800, 360),
        Size(854, 384),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: Scaffold(
              body: Stack(
                children: [
                  PlayerBottomBar(
                    line: null,
                    settings: const PlaybackSettings(),
                    services: const ExternalServiceSettings(),
                    danmaku: const DanmakuSettings(),
                    position: const Duration(minutes: 3, seconds: 12),
                    duration: const Duration(minutes: 24),
                    buffer: const Duration(minutes: 5),
                    volume: 100,
                    playing: true,
                    buffering: false,
                    loadingLine: false,
                    fullscreen: true,
                    muted: false,
                    onPlayPause: () async {},
                    onPreviousEpisode: () async {},
                    onNextEpisode: () async {},
                    onSeek: (_) async {},
                    onMute: () async {},
                    onVolumeChanged: (_) {},
                    onSpeedSelected: (_) {},
                    onFullscreen: () async {},
                    onDanmakuPanel: () {},
                    danmakuInput: danmakuInput,
                    onSendDanmaku: (_) {},
                    onEpisodePanel: () {},
                    onLinePanel: () {},
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pump();

        expect(tester.takeException(), isNull, reason: 'landscape size $size');
        for (final tooltip in <String>[
          '上一集',
          '暂停',
          '下一集',
          '弹幕源与显示设置',
          '选集',
          '播放速度',
          '线路',
          '音量 100%，点击调节',
          '退出全屏',
        ]) {
          expect(
            find.byTooltip(tooltip),
            findsOneWidget,
            reason: '$tooltip at $size',
          );
        }
        expect(
          find.byIcon(Icons.subtitles_outlined),
          findsNothing,
          reason: 'external subtitle source is not a primary player control',
        );
        for (final tooltip in <String>['弹幕源与显示设置', '选集']) {
          final tapTarget = tester.getSize(find.byTooltip(tooltip));
          expect(
            tapTarget.shortestSide,
            greaterThanOrEqualTo(40),
            reason: '$tooltip keeps a comfortable landscape tap target',
          );
        }
      }
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('portrait mobile does not expose the external subtitle source', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    final danmakuInput = TextEditingController();
    addTearDown(danmakuInput.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: Stack(
            children: [
              PlayerBottomBar(
                line: null,
                settings: const PlaybackSettings(),
                services: const ExternalServiceSettings(),
                danmaku: const DanmakuSettings(),
                position: const Duration(minutes: 3, seconds: 12),
                duration: const Duration(minutes: 24),
                buffer: const Duration(minutes: 5),
                volume: 100,
                playing: true,
                buffering: false,
                loadingLine: false,
                fullscreen: false,
                muted: false,
                onPlayPause: () async {},
                onPreviousEpisode: () async {},
                onNextEpisode: () async {},
                onSeek: (_) async {},
                onMute: () async {},
                onVolumeChanged: (_) {},
                onSpeedSelected: (_) {},
                onFullscreen: () async {},
                onDanmakuPanel: () {},
                danmakuInput: danmakuInput,
                onSendDanmaku: (_) {},
                onEpisodePanel: () {},
                onLinePanel: () {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.subtitles_outlined), findsNothing);
    expect(find.byTooltip('暂停'), findsOneWidget);
    expect(find.byTooltip('全屏'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('landscape mobile opens touch volume controls before muting', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(568, 320);
    final danmakuInput = TextEditingController();
    addTearDown(danmakuInput.dispose);
    var muteCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: Stack(
            children: [
              PlayerBottomBar(
                line: null,
                settings: const PlaybackSettings(),
                services: const ExternalServiceSettings(),
                danmaku: const DanmakuSettings(),
                position: const Duration(minutes: 3, seconds: 12),
                duration: const Duration(minutes: 24),
                buffer: const Duration(minutes: 5),
                volume: 100,
                playing: true,
                buffering: false,
                loadingLine: false,
                fullscreen: true,
                muted: false,
                onPlayPause: () async {},
                onPreviousEpisode: () async {},
                onNextEpisode: () async {},
                onSeek: (_) async {},
                onMute: () async => muteCalls++,
                onVolumeChanged: (_) {},
                onSpeedSelected: (_) {},
                onFullscreen: () async {},
                onDanmakuPanel: () {},
                danmakuInput: danmakuInput,
                onSendDanmaku: (_) {},
                onEpisodePanel: () {},
                onLinePanel: () {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('音量 100%，点击调节'));
    await tester.pumpAndSettle();

    expect(muteCalls, 0);
    expect(find.byType(Slider), findsOneWidget);
    expect(find.byTooltip('静音'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
}
