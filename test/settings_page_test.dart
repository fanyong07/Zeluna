import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/settings/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('快捷键只在按键说明展开后显示', (tester) async {
    await _setViewport(tester, const Size(420, 900));
    await tester.pumpWidget(
      _SettingsHarness(
        compact: true,
        line: const PlaybackLine(
          id: 'line-1',
          episodeId: 1,
          providerId: 'private-provider',
          providerName: '后台数据源名称',
          title: '后台线路名称',
          quality: '1080P',
          format: 'HLS',
          url: 'https://private.example/video.m3u8',
          available: true,
        ),
      ),
    );

    expect(find.text('Space'), findsNothing);
    expect(find.text('K'), findsNothing);
    expect(find.text('F'), findsNothing);
    expect(find.text('M'), findsNothing);
    expect(find.text('后台数据源名称'), findsNothing);
    expect(find.text('后台线路名称'), findsNothing);
    expect(find.text('private.example'), findsNothing);

    final shortcutDisclosure = find.byKey(
      const ValueKey('settings_disclosure_按键说明'),
    );
    await tester.ensureVisible(shortcutDisclosure);
    await tester.pumpAndSettle();
    await tester.tap(shortcutDisclosure);
    await tester.pumpAndSettle();

    expect(find.text('Space'), findsOneWidget);
    expect(find.text('K'), findsOneWidget);
    expect(find.text('F'), findsOneWidget);
    expect(find.text('M'), findsOneWidget);
    expect(find.text('←'), findsOneWidget);
    expect(find.text('→'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('播放设置开关和选择器会写回 PlaybackSettings', (tester) async {
    final changes = <PlaybackSettings>[];
    await _setViewport(tester, const Size(430, 900));
    await tester.pumpWidget(
      _SettingsHarness(compact: true, onChanged: changes.add),
    );

    final superResolution = find.byKey(const ValueKey('setting_switch_超分辨率'));
    await tester.ensureVisible(superResolution);
    await tester.tap(superResolution);
    await tester.pumpAndSettle();
    expect(changes.last.superResolution, isTrue);
    expect(find.text('画质档位'), findsOneWidget);
    expect(find.text('超分模式'), findsOneWidget);

    final tier = find.byKey(const ValueKey('setting_choice_画质档位'));
    await tester.ensureVisible(tier);
    await tester.tap(tier);
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    await tester.tap(find.text('均衡').last);
    await tester.pumpAndSettle();
    expect(changes.last.superResolutionTier, 'balance');

    final mode = find.byKey(const ValueKey('setting_choice_超分模式'));
    await tester.ensureVisible(mode);
    await tester.tap(mode);
    await tester.pumpAndSettle();
    await tester.tap(find.text('模式C+A').last);
    await tester.pumpAndSettle();
    expect(changes.last.superResolutionMode, 'ca');

    final autoFullscreen = find.byKey(const ValueKey('setting_switch_自动全屏'));
    await tester.ensureVisible(autoFullscreen);
    await tester.tap(autoFullscreen);
    await tester.pumpAndSettle();
    expect(changes.last.autoFullscreen, isTrue);

    final rememberLine = find.byKey(const ValueKey('setting_switch_线路记忆'));
    await tester.ensureVisible(rememberLine);
    await tester.tap(rememberLine);
    await tester.pumpAndSettle();
    expect(changes.last.rememberLine, isFalse);

    final forward = find.byKey(const ValueKey('setting_choice_快进时间'));
    await tester.ensureVisible(forward);
    await tester.tap(forward);
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    await tester.tap(find.text('30 秒').last);
    await tester.pumpAndSettle();
    expect(changes.last.forwardSeconds, 30);
    expect(tester.takeException(), isNull);
  });

  testWidgets('音量滑块和键盘控制会写回 PlaybackSettings', (tester) async {
    final changes = <PlaybackSettings>[];
    await _setViewport(tester, const Size(430, 900));
    await tester.pumpWidget(
      _SettingsHarness(
        initialSettings: const PlaybackSettings(volumeBoost: 0.1),
        onChanged: changes.add,
      ),
    );

    await tester.tap(find.byKey(const ValueKey('settings_disclosure_按键说明')));
    await tester.pumpAndSettle();
    final keyboard = find.byKey(const ValueKey('setting_switch_启用键盘控制'));
    await tester.tap(keyboard);
    await tester.pumpAndSettle();
    expect(changes.last.keyboardShortcutsEnabled, isFalse);
    await tester.tap(keyboard);
    await tester.pumpAndSettle();
    expect(changes.last.keyboardShortcutsEnabled, isTrue);

    final mute = find.byKey(const ValueKey('shortcut_switch_静音'));
    await tester.ensureVisible(mute);
    await tester.tap(mute);
    await tester.pumpAndSettle();
    expect(changes.last.shortcutMute, isFalse);

    final slider = find.byKey(const ValueKey('volume_boost_slider'));
    await tester.ensureVisible(slider);
    await tester.drag(slider, const Offset(120, 0));
    await tester.pumpAndSettle();
    expect(changes.last.volumeBoost, greaterThan(0.1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('高级超分可以选择并保存着色器组合', (tester) async {
    final changes = <PlaybackSettings>[];
    await _setViewport(tester, const Size(430, 900));
    await tester.pumpWidget(
      _SettingsHarness(
        initialSettings: const PlaybackSettings(
          superResolution: true,
          superResolutionTier: 'custom',
        ),
        onChanged: changes.add,
      ),
    );

    final picker = find.byKey(const ValueKey('setting_choice_高级着色器'));
    await tester.ensureVisible(picker);
    await tester.tap(picker);
    await tester.pumpAndSettle();
    expect(find.text('完成 (0)'), findsOneWidget);

    await tester.tap(find.text('Clamp Highlights'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成 (1)'));
    await tester.pumpAndSettle();

    expect(changes, isNotEmpty);
    expect(changes.last.superResolutionTier, 'custom');
    expect(changes.last.superResolutionCustomShaders, [
      'Anime4K_Clamp_Highlights.glsl',
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('播放器超分状态只显示在右侧播放设置面板', (tester) async {
    await _setViewport(tester, const Size(430, 900));
    await tester.pumpWidget(
      const _SettingsHarness(
        compact: true,
        initialSettings: PlaybackSettings(superResolution: true),
        superResolutionStatus: Text(
          '画质修复中 · 片源 1920×1080 · 显示区域 1080×608 · '
          '画质修复 · 模式A · 质量',
        ),
      ),
    );

    expect(find.textContaining('画质修复中'), findsOneWidget);
    expect(find.textContaining('片源 1920×1080'), findsOneWidget);
    expect(find.textContaining('显示区域 1080×608'), findsOneWidget);
    expect(find.textContaining('模式A · 质量'), findsOneWidget);
  });

  testWidgets('移动端和桌面端布局均无溢出', (tester) async {
    await _setViewport(tester, const Size(360, 640));
    await tester.pumpWidget(const _SettingsHarness(compact: true));
    expect(tester.takeException(), isNull);

    await _setViewport(tester, const Size(1200, 900));
    await tester.pumpWidget(const _SettingsHarness());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey('playback_settings_back')),
      findsOneWidget,
    );
    expect(find.text('默认倍速'), findsNothing);
    expect(find.text('长按倍速'), findsNothing);
    expect(find.text('边缘双击'), findsNothing);
    expect(find.text('线路记忆'), findsOneWidget);
    expect(find.text('兼容模式'), findsNothing);
  });
}

Future<void> _setViewport(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
}

class _SettingsHarness extends StatefulWidget {
  const _SettingsHarness({
    this.initialSettings = const PlaybackSettings(),
    this.compact = false,
    this.line,
    this.onChanged,
    this.superResolutionStatus,
  });

  final PlaybackSettings initialSettings;
  final bool compact;
  final PlaybackLine? line;
  final ValueChanged<PlaybackSettings>? onChanged;
  final Widget? superResolutionStatus;

  @override
  State<_SettingsHarness> createState() => _SettingsHarnessState();
}

class _SettingsHarnessState extends State<_SettingsHarness> {
  late PlaybackSettings settings = widget.initialSettings;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: PlaybackSettingsView(
        compact: widget.compact,
        settings: settings,
        line: widget.line,
        superResolutionStatus: widget.superResolutionStatus,
        onBack: () {},
        onChanged: (value) {
          setState(() => settings = value);
          widget.onChanged?.call(value);
        },
      ),
    );
  }
}
