import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/player/player_pip_controller.dart';
import 'package:anime/src/player/sleep_timer_controller.dart';
import 'package:anime/src/settings/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
    now = const Duration(seconds: 32);
    await tap('以当前进度设为片头');
    await tap('以剩余时长设为片尾');
    expect(
      settings.effectiveSkipFor(subject.identityKey),
      const SkipTiming(introSeconds: 32, outroSeconds: 148),
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
