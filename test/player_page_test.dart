import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/player/player_pip_controller.dart';
import 'package:anime/src/player/player_page.dart';
import 'package:flutter/gestures.dart';
import 'package:anime/src/player/skip/skip_segment.dart';
import 'package:anime/src/player/sleep_timer_controller.dart';
import 'package:anime/src/settings/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'seek track paints both outlined boundaries and labels a hovered endpoint',
    (tester) async {
      final input = TextEditingController();
      addTearDown(input.dispose);
      const op = SkipSegment(
        type: SkipSegmentType.op,
        start: Duration(seconds: 30),
        end: Duration(seconds: 60),
        source: SkipSegmentSource.chapter,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                PlayerBottomBar(
                  line: null,
                  settings: const PlaybackSettings(),
                  services: const ExternalServiceSettings(),
                  danmaku: const DanmakuSettings(),
                  position: const Duration(seconds: 45),
                  duration: const Duration(seconds: 120),
                  buffer: Duration.zero,
                  volume: 100,
                  playing: true,
                  buffering: false,
                  loadingLine: false,
                  fullscreen: false,
                  muted: false,
                  skipSegments: const [op],
                  onPlayPause: () async {},
                  onPreviousEpisode: null,
                  onNextEpisode: null,
                  onSeek: (_) async {},
                  onMute: () async {},
                  onVolumeChanged: (_) {},
                  onSpeedSelected: (_) {},
                  onFullscreen: () async {},
                  onDanmakuPanel: () {},
                  danmakuInput: input,
                  onSendDanmaku: (_) {},
                  onEpisodePanel: () {},
                  onLinePanel: () {},
                ),
              ],
            ),
          ),
        ),
      );
      final track = find.byKey(const ValueKey('playerSeekTrack'));
      final bounds = tester.getRect(track);
      final start = Offset(bounds.width / 4, bounds.height / 2),
          end = Offset(bounds.width / 2, bounds.height / 2);
      expect(
        track,
        paints
          ..line()
          ..circle(x: start.dx, y: start.dy, color: Colors.black87)
          ..circle(x: start.dx, y: start.dy, color: Colors.white)
          ..circle(x: end.dx, y: end.dy, color: Colors.black87)
          ..circle(x: end.dx, y: end.dy, color: Colors.white),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(bounds.topLeft + end);
      await tester.pump();
      expect(find.text('01:00 · 片头'), findsOneWidget);
      expect(find.text('+85s'), findsNothing);
      await mouse.removePointer();
    },
  );
  testWidgets('番剧覆盖可从零开始编辑，快捷标记读取点击时的进度', (tester) async {
    await tester.binding.setSurfaceSize(const Size(850, 2800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final subject = AnimeSubject.fromJson({'id': 5, 'title': '测试作品'});
    var settings = const PlaybackSettings();
    var now = const Duration(seconds: 12);
    final timer = SleepTimerController(onTriggered: () {});
    addTearDown(timer.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => PlaybackSettingsView(
            settings: settings,
            onChanged: (next) => setState(() => settings = next),
            onBack: () {},
            subject: subject,
            detectedSkipSegments: const [
              SkipSegment(
                type: SkipSegmentType.op,
                start: Duration(seconds: 153),
                end: Duration(seconds: 243),
                source: SkipSegmentSource.aniskip,
              ),
            ],
            compact: true,
            currentPosition: now,
            readPosition: () => now,
            totalDuration: const Duration(seconds: 180),
            sleepTimer: timer,
          ),
        ),
      ),
    );
    Future<void> tap(String text) async {
      final target = find.text(text);
      await tester.ensureVisible(target);
      await tester.pumpAndSettle();
      await tester.tap(target);
      await tester.pump();
    }

    await tap('当前番剧单独设置');
    expect(find.text('片头 02:33 - 04:03 · AniSkip'), findsOneWidget);
    await tap('自动跳过识别到的片头');
    await tap('自动跳过识别到的片尾');
    expect(settings.autoSkipOp && settings.autoSkipEd, isTrue);
    for (final (label, time) in [
      ('片头起点', 32),
      ('片头终点', 80),
      ('片尾起点', 145),
      ('片尾终点', 166),
    ]) {
      now = Duration(seconds: time);
      final button = find.byTooltip('以当前进度设为$label');
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pump();
    }
    expect(
      settings.effectiveSkipFor(subject.identityKey),
      const SkipTiming(
        introStartSeconds: 32,
        introSeconds: 80,
        outroStartSeconds: 145,
        outroEndSeconds: 166,
      ),
    );
    expect(settings.skipIntroSeconds, 0);
    await tap('当前番剧单独设置');
    expect(settings.subjectSkipTimings, isEmpty);
    await tap('30分钟');
    expect(timer.badgeLabel, '30:00');
    await tap('播完本集');
    expect(timer.mode, SleepTimerMode.endOfEpisode);
  });

  testWidgets(
    'Windows 小窗向原生查询实际状态，离开时仅恢复活跃小窗',
    (tester) async {
      const channel = MethodChannel('app.anime.anime/window');
      final messenger = tester.binding.defaultBinaryMessenger;
      var native = false;
      final changes = <bool>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'setMiniWindow') native = call.arguments as bool;
        return native;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final pip = PlayerPipController(onChanged: changes.add);
      expect(await pip.initialize(), isTrue);
      expect(await pip.toggle(active: false), isTrue);
      expect(changes, [true]);
      await pip.exitIfActive();
      expect(native, isFalse);
      pip.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'Android 模式由系统回调而非点击结果决定',
    (tester) async {
      const channel = MethodChannel('app.anime.anime/pip');
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async => true);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final changes = <bool>[];
      final pip = PlayerPipController(onChanged: changes.add);
      expect(await pip.initialize(), isTrue);
      expect(await pip.toggle(active: false), isTrue);
      expect(changes, isEmpty);
      for (final active in [true, false]) {
        final ByteData data = channel.codec.encodeMethodCall(
          MethodCall('onPipChanged', active),
        );
        await messenger.handlePlatformMessage(channel.name, data, (_) {});
      }
      expect(changes, [true, false]);
      pip.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
