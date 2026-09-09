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

      for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
        debugDefaultTargetPlatformOverride = platform;
        for (final size in const <Size>[
          Size(568, 320),
          Size(640, 360),
          Size(800, 360),
          Size(854, 384),
          Size(1097, 617),
          Size(1280, 720),
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

          expect(
            tester.takeException(),
            isNull,
            reason: 'landscape size $size',
          );
          expect(
            find.byType(TextField),
            findsOneWidget,
            reason:
                'Landscape uses the Windows danmaku composer, not an icon-only strip',
          );
          expect(find.text('发条弹幕吧…'), findsOneWidget);
          expect(find.text('发送'), findsOneWidget);
          expect(find.text('选集'), findsOneWidget);
          expect(find.text('线路'), findsOneWidget);
          final playRect = tester.getRect(find.byTooltip('暂停'));
          final composerRect = tester.getRect(find.byType(TextField));
          final episodeRect = tester.getRect(find.byTooltip('选集'));
          expect(
            (composerRect.center.dy - playRect.center.dy).abs(),
            lessThan(2),
            reason:
                'The annotated composer stays inline, never in a second row.',
          );
          expect(composerRect.left, greaterThan(playRect.right));
          expect(composerRect.right, lessThan(episodeRect.left));
          if (size.width < 1000) {
            expect(
              tester.widget<Icon>(find.byIcon(Icons.pause_rounded)).size,
              lessThanOrEqualTo(26),
              reason: 'primary icon is less visually heavy',
            );
            expect(
              tester.widget<Icon>(find.byIcon(Icons.comment_outlined)).size,
              lessThanOrEqualTo(20),
            );
            expect(
              tester.widget<TextField>(find.byType(TextField)).style!.fontSize,
              lessThanOrEqualTo(11),
            );
            expect(
              tester.widget<Text>(find.text('选集')).style!.fontSize,
              lessThanOrEqualTo(11),
            );
            expect(
              tester.widget<Text>(find.text('线路')).style!.fontSize,
              lessThanOrEqualTo(11),
            );
            expect(
              tester.getSize(find.byTooltip('暂停')).shortestSide,
              greaterThanOrEqualTo(40),
              reason: 'smaller artwork keeps the touch target',
            );
          }

          for (final tooltip in <String>[
            '上一集',
            '暂停',
            '下一集',
            '弹幕源与显示设置',
            '选集',
            '播放速度',
            '线路',
            platform == TargetPlatform.android
                ? '音量 100%，点击调节'
                : '音量 100%，点击静音',
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
  testWidgets(
    'speed menu reports lifecycle and remains open on touch landscape',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(568, 320);
      final danmakuInput = TextEditingController();
      addTearDown(danmakuInput.dispose);
      var muteCalls = 0;
      final menuStates = <bool>[];

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
                  onControlMenuChanged: menuStates.add,
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

      await tester.tap(find.byTooltip('播放速度'));
      await tester.pumpAndSettle();

      expect(muteCalls, 0);
      expect(find.text('1.25x'), findsOneWidget);
      expect(menuStates, [true]);
      await tester.pump(const Duration(seconds: 4));
      expect(find.text('1.25x'), findsOneWidget);
      await tester.tap(find.text('1.25x'));
      await tester.pumpAndSettle();
      expect(menuStates, [true, false]);
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
