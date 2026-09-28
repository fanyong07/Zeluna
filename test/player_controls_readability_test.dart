import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/app/app_theme.dart';
import 'package:anime/src/player/player_page.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> mountControls(
  WidgetTester tester,
  Size size, {
  double textScale = 1,
  EdgeInsets padding = EdgeInsets.zero,
  ValueChanged<bool>? onDanmaku,
  VoidCallback? onFullscreen,
}) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.android;
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  final input = TextEditingController();
  addTearDown(input.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: AnimeTheme.dark(),
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          padding: padding,
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(
          body: Stack(
            children: [
              PlayerBottomBar(
                line: null,
                settings: const PlaybackSettings(),
                services: const ExternalServiceSettings(),
                danmaku: const DanmakuSettings(),
                position: const Duration(minutes: 2, seconds: 28),
                duration: const Duration(minutes: 23, seconds: 15),
                buffer: const Duration(minutes: 4),
                volume: 100,
                playing: true,
                buffering: false,
                loadingLine: false,
                fullscreen: size.width > size.height,
                muted: false,
                onPlayPause: () async {},
                onPreviousEpisode: () async {},
                onNextEpisode: () async {},
                onSeek: (_) async {},
                onMute: () async {},
                onVolumeChanged: (_) {},
                onSpeedSelected: (_) {},
                onFullscreen: () async {
                  onFullscreen?.call();
                },
                onDanmakuPanel: () {},
                onDanmakuEnabledChanged: onDanmaku ?? (_) {},
                danmakuInput: input,
                onSendDanmaku: (_) {},
                onEpisodePanel: () {},
                onLinePanel: () {},
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'portrait has only a danmaku toggle and fullscreen at the outer right',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var fullscreenCalls = 0;
      bool? danmakuEnabled;
      await mountControls(
        tester,
        const Size(390, 844),
        padding: const EdgeInsets.only(right: 16),
        onFullscreen: () => fullscreenCalls++,
        onDanmaku: (value) => danmakuEnabled = value,
      );
      expect(find.byTooltip('弹幕设置'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      final fullscreen = tester.getRect(find.byTooltip('全屏'));
      final toggle = tester.getRect(
        find.byKey(const ValueKey('playerDanmakuQuickToggle')),
      );
      expect(fullscreen.left, greaterThanOrEqualTo(toggle.right + 8));
      expect(fullscreen.right, closeTo(390 - 16 - 10, .1));
      expect(fullscreen.height, greaterThanOrEqualTo(40));
      await tester.tap(find.byTooltip('全屏'));
      await tester.tap(find.byTooltip('关闭弹幕'));
      expect(fullscreenCalls, 1);
      expect(danmakuEnabled, isFalse);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'wide landscape keeps smaller artwork and visible space between groups',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await mountControls(tester, const Size(1194, 672));
      expect(
        tester.widget<Icon>(find.byIcon(Icons.pause_rounded)).size,
        lessThanOrEqualTo(26),
      );
      expect(
        tester.widget<Icon>(find.byIcon(Icons.comment_outlined)).size,
        lessThanOrEqualTo(18),
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).style!.fontSize,
        lessThanOrEqualTo(12),
      );
      expect(
        tester.widget<Text>(find.text('线路')).style!.fontSize,
        lessThanOrEqualTo(12),
      );
      final send = tester.getRect(find.widgetWithText(TextButton, '发送'));
      expect(send.width, greaterThanOrEqualTo(40));
      expect(send.height, greaterThanOrEqualTo(40));
      expect(
        tester.getSize(find.byType(TextField)).height,
        greaterThanOrEqualTo(40),
      );
      final inputWidget = tester.widget<TextField>(find.byType(TextField));
      expect(
        inputWidget.decoration!.hintStyle!.fontSize,
        inputWidget.style!.fontSize,
      );
      final next = tester.getRect(find.byTooltip('下一集'));
      final settings = tester.getRect(find.byTooltip('弹幕设置'));
      final episode = tester.getRect(find.byTooltip('选集'));
      final speed = tester.getRect(find.byTooltip('播放速度'));
      final route = tester.getRect(find.byTooltip('线路'));
      expect(settings.left - next.right, greaterThanOrEqualTo(20));
      expect(speed.left - episode.right, greaterThanOrEqualTo(8));
      expect(route.left - speed.right, greaterThanOrEqualTo(8));
      expect(
        tester.getSize(find.byTooltip('暂停')).shortestSide,
        greaterThanOrEqualTo(40),
      );
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'landscape keeps controls and inline composer at small widths and increased text scale',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final width in [568.0, 640.0, 800.0, 854.0, 1097.0, 1280.0]) {
        for (final scale in [1.0, 1.3]) {
          await mountControls(tester, Size(width, 320), textScale: scale);
          expect(
            tester.takeException(),
            isNull,
            reason: 'width=$width scale=$scale',
          );
          expect(find.byType(TextField), findsOneWidget);
          expect(find.byTooltip('弹幕设置'), findsOneWidget);
          final play = tester.getRect(find.byTooltip('暂停'));
          final input = tester.getRect(find.byType(TextField));
          final full = tester.getRect(find.byTooltip('退出全屏'));
          expect((play.center.dy - input.center.dy).abs(), lessThan(2));
          expect(
            input.width,
            greaterThan(24),
            reason: 'composer must remain usable width=$width scale=$scale',
          );
          expect(full.right, closeTo(width - 10, .1));
        }
      }
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
