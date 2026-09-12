import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/player/danmaku_overlay.dart';
import 'package:anime/src/shared_ui/danmaku_display_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

DanmakuComment comment(String id, DanmakuMode mode, {String text = '弹幕'}) =>
    DanmakuComment(
      id: id,
      provider: '弹弹play',
      time: Duration.zero,
      mode: mode,
      color: 0xFFFFFF,
      text: text,
    );

void main() {
  test('new preferences round trip and legacy values remain compatible', () {
    final old = DanmakuSettings.fromJson({'opacity': .6, 'fontSize': 16});
    expect(old.displayArea, .75);
    expect(old.speed, 1);
    expect(old.blockBottom, isFalse);
    final next = old.copyWith(displayArea: .25, speed: 1.5, blockBottom: true);
    final restored = DanmakuSettings.fromJson(next.toJson());
    expect(restored.displayArea, .25);
    expect(restored.speed, 1.5);
    expect(restored.blockBottom, isTrue);
    expect(restored.opacity, .6);
    final invalid = DanmakuSettings.fromJson({
      'displayArea': 8,
      'speed': 0,
      'fontSize': 500,
      'opacity': -1,
    });
    expect(invalid.displayArea, 1);
    expect(invalid.speed, .5);
    expect(invalid.fontSize, 28);
    expect(invalid.opacity, .2);
  });

  test('speed changes both the visibility window and motion duration', () {
    final comments = [comment('long', DanmakuMode.scroll, text: '很长的弹幕' * 9)];
    expect(
      visibleDanmakuComments(
        comments,
        position: const Duration(seconds: 15),
        settings: const DanmakuSettings(speed: .5),
      ),
      hasLength(1),
    );
    expect(
      visibleDanmakuComments(
        comments,
        position: const Duration(seconds: 8),
        settings: const DanmakuSettings(speed: 2),
      ),
      isEmpty,
    );
  });

  test('top, bottom and scrolling filters are independent', () {
    final comments = [
      comment('s', DanmakuMode.scroll),
      comment('r', DanmakuMode.reverse),
      comment('t', DanmakuMode.top),
      comment('b', DanmakuMode.bottom),
      comment('a', DanmakuMode.advanced),
    ];
    expect(
      visibleDanmakuComments(
        comments,
        position: Duration.zero,
        settings: const DanmakuSettings(blockBottom: true),
      ).map((e) => e.id),
      ['s', 'r', 't', 'a'],
    );
    expect(
      visibleDanmakuComments(
        comments,
        position: Duration.zero,
        settings: const DanmakuSettings(blockTop: true, blockScroll: true),
      ).map((e) => e.id),
      ['b'],
    );
  });

  testWidgets(
    'quick switch toggles without opening settings and reports its state',
    (tester) async {
      var enabled = true;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) => Scaffold(
              body: DanmakuQuickSwitch(
                enabled: enabled,
                onChanged: (value) => setState(() => enabled = value),
              ),
            ),
          ),
        ),
      );
      expect(find.byTooltip('关闭弹幕'), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const ValueKey('playerDanmakuQuickToggle'))),
        const Size(40, 40),
      );
      await tester.tap(find.byTooltip('关闭弹幕'));
      await tester.pumpAndSettle();
      expect(enabled, isFalse);
      expect(find.byTooltip('开启弹幕'), findsOneWidget);
      await tester.tap(find.byTooltip('开启弹幕'));
      await tester.pumpAndSettle();
      expect(enabled, isTrue);
    },
  );

  testWidgets('speed changes actual scrolling position, not only filtering', (
    tester,
  ) async {
    final bullet = comment('moving', DanmakuMode.scroll, text: 'speed');
    Future<double> x(double speed) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 640,
            height: 360,
            child: RemoteDanmakuOverlay(
              comments: [bullet],
              position: const Duration(seconds: 2),
              settings: DanmakuSettings(speed: speed),
            ),
          ),
        ),
      );
      return tester.getTopLeft(find.text('speed')).dx;
    }

    final slow = await x(.5);
    final normal = await x(1);
    final fast = await x(2);
    expect(slow, greaterThan(normal));
    expect(normal, greaterThan(fast));
  });

  testWidgets(
    'reset preserves enablement and keywords and restores display fields',
    (tester) async {
      var settings = const DanmakuSettings(
        enabled: false,
        opacity: .3,
        fontSize: 28,
        displayArea: .25,
        speed: 2,
        blockTop: true,
        blockBottom: true,
        blockScroll: true,
        blockKeywords: ['保留的屏蔽词'],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) => Scaffold(
              body: SingleChildScrollView(
                child: DanmakuDisplayControls(
                  settings: settings,
                  onChanged: (value) async {
                    setState(() => settings = value);
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('danmakuResetDisplay')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('danmakuResetDisplay')));
      await tester.pumpAndSettle();
      expect(
        settings.toJson(),
        const DanmakuSettings(
          enabled: false,
          blockKeywords: ['保留的屏蔽词'],
        ).toJson(),
      );
    },
  );

  testWidgets(
    'failed persistence shows feedback and small drawer remains usable',
    (tester) async {
      tester.view.physicalSize = const Size(220, 360);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: DanmakuDisplayControls(
                settings: const DanmakuSettings(),
                theater: true,
                onChanged: (_) async => throw StateError('save failed'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('半屏'));
      await tester.pumpAndSettle();
      expect(find.text('弹幕设置未保存，请重试'), findsOneWidget);
      await tester.ensureVisible(find.text('底部'));
      await tester.pumpAndSettle();
      final scroll = tester.getRect(find.text('滚动'));
      final top = tester.getRect(find.text('顶部'));
      final bottom = tester.getRect(find.text('底部'));
      expect(scroll.center.dy, top.center.dy);
      expect(top.center.dy, bottom.center.dy);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('display area bounds all modes and opacity includes shadows', (
    tester,
  ) async {
    final comments = [
      comment('s', DanmakuMode.scroll),
      comment('t', DanmakuMode.top),
      comment('b', DanmakuMode.bottom),
    ];
    for (final area in [.25, .5, .75, 1.0]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 640,
              height: 360,
              child: RemoteDanmakuOverlay(
                comments: comments,
                position: const Duration(seconds: 1),
                settings: DanmakuSettings(displayArea: area, opacity: .4),
              ),
            ),
          ),
        ),
      );
      final origin = tester.getTopLeft(find.byType(RemoteDanmakuOverlay));
      for (final text in find.text('弹幕').evaluate()) {
        final rect = tester.getRect(find.byWidget(text.widget));
        expect(rect.top, greaterThanOrEqualTo(origin.dy));
        expect(rect.bottom, lessThanOrEqualTo(origin.dy + 360 * area + 1));
      }
      expect(
        tester
            .widgetList<Opacity>(find.byType(Opacity))
            .where((e) => e.opacity == .4),
        hasLength(3),
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('compact settings are editable and contain no provider list', (
    tester,
  ) async {
    var settings = const DanmakuSettings();
    tester.view.physicalSize = const Size(320, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: SingleChildScrollView(
              child: DanmakuDisplayControls(
                settings: settings,
                onChanged: (value) async {
                  setState(() => settings = value);
                },
                theater: true,
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('弹幕来源'), findsNothing);
    expect(find.text('透明度'), findsOneWidget);
    expect(find.text('显示区域'), findsOneWidget);
    await tester.tap(find.text('1/4屏'));
    await tester.pump();
    expect(settings.displayArea, .25);
    await tester.ensureVisible(find.byKey(const ValueKey('danmakuFontSize')));
    await tester.pumpAndSettle();
    tester
        .widget<Slider>(find.byKey(const ValueKey('danmakuFontSize')))
        .onChanged!(14);
    await tester.pump();
    expect(settings.fontSize, 14);
    await tester.ensureVisible(find.text('底部'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('底部'));
    await tester.pump();
    expect(settings.blockBottom, isTrue);
    expect(tester.takeException(), isNull);
  });
}
