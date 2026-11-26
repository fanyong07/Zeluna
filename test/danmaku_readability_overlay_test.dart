import 'dart:collection';
import 'dart:ui' as ui;

import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/player/danmaku_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

DanmakuComment bullet(
  String id, {
  String? text,
  DanmakuMode mode = DanmakuMode.scroll,
  int at = 0,
}) => DanmakuComment(
  id: id,
  provider: 'readability-test',
  time: Duration(milliseconds: at),
  mode: mode,
  color: 0xffffff,
  text: text ?? '弹幕$id',
);

Future<void> showOverlay(
  WidgetTester tester,
  List<DanmakuComment> comments, {
  int at = 1000,
  double area = 1,
  double scale = 1,
  double fontSize = 18,
  double speed = 1,
  List<String> blockKeywords = const [],
  Rect? exclusion,
  EdgeInsets reservedInsets = EdgeInsets.zero,
  Size size = const Size(640, 360),
}) => tester.pumpWidget(
  MaterialApp(
    home: Center(
      child: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: SizedBox.fromSize(
          size: size,
          child: RemoteDanmakuOverlay(
            comments: comments,
            position: Duration(milliseconds: at),
            settings: DanmakuSettings(
              displayArea: area,
              fontSize: fontSize,
              speed: speed,
              blockKeywords: blockKeywords,
            ),
            excludedArea: exclusion,
            reservedInsets: reservedInsets,
          ),
        ),
      ),
    ),
  ),
);

List<Rect> visibleRects(WidgetTester tester) {
  final overlay = find.byType(RemoteDanmakuOverlay);
  final viewport = tester.getRect(overlay);
  return find
      .descendant(of: overlay, matching: find.byType(Text))
      .evaluate()
      .map((element) => tester.getRect(find.byWidget(element.widget)))
      .where((rect) => rect.overlaps(viewport))
      .map((rect) => rect.intersect(viewport))
      .toList();
}

void expectSeparated(List<Rect> rects) {
  for (var i = 0; i < rects.length; i++) {
    for (var j = i + 1; j < rects.length; j++) {
      expect(
        rects[i].overlaps(rects[j]),
        isFalse,
        reason: 'Comments $i and $j must not obscure one another',
      );
    }
  }
}

class CountingTimeline extends ListBase<DanmakuComment> {
  CountingTimeline(this.items);
  final List<DanmakuComment> items;
  int reads = 0;
  @override
  int get length => items.length;
  @override
  set length(int value) => throw UnsupportedError('read only');
  @override
  DanmakuComment operator [](int index) {
    reads++;
    return items[index];
  }

  @override
  void operator []=(int index, DanmakuComment value) =>
      throw UnsupportedError('read only');
}

void main() {
  test('temporal candidates are not reduced a second time by display area', () {
    final comments = List.generate(80, (i) => bullet('$i'));
    for (final area in [1.0, .5, .25]) {
      expect(
        visibleDanmakuComments(
          comments,
          position: const Duration(seconds: 1),
          settings: DanmakuSettings(displayArea: area),
        ),
        hasLength(80),
      );
      expect(
        visibleDanmakuComments(
          comments,
          position: const Duration(seconds: 1),
          settings: DanmakuSettings(displayArea: area),
          limit: 10,
        ),
        hasLength(10),
      );
    }
    for (final limit in [0, -1]) {
      expect(
        visibleDanmakuComments(
          comments,
          position: Duration.zero,
          settings: const DanmakuSettings(),
          limit: limit,
        ),
        isEmpty,
      );
    }
  });

  testWidgets('usable height rather than fixed 8 4 2 caps determines lanes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final comments = List.generate(
      100,
      (i) => bullet('$i', text: '好看', mode: DanmakuMode.top),
    );
    final counts = <int>[];
    for (final area in [1.0, .5, .25]) {
      const size = Size(1280, 720);
      final bounds = danmakuDisplayBounds(size, area);
      final laneHeight = DanmakuText.measure(text: '弹幕Ag').height + 3;
      final expectedLanes = (bounds.height / laneHeight).floor();
      await showOverlay(tester, comments, size: size, area: area);
      final rects = visibleRects(tester);
      expect(rects.length, expectedLanes);
      expectSeparated(rects);
      counts.add(rects.length);
    }
    expect(counts[0], greaterThan(counts[1]));
    expect(counts[1], greaterThan(counts[2]));
  });

  testWidgets('scrolling traffic exceeds old caps without overlapping', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final comments = List.generate(
      400,
      (i) => bullet('$i', text: '好看', at: i * 20),
    );
    final counts = <int>[];
    for (final (area, oldCap) in [(1.0, 24), (.5, 12), (.25, 6)]) {
      await showOverlay(
        tester,
        comments,
        size: const Size(1280, 720),
        area: area,
        at: 6500,
      );
      final rects = visibleRects(tester);
      expect(rects.length, greaterThan(oldCap));
      expectSeparated(rects);
      counts.add(rects.length);
    }
    expect(counts[0], greaterThan(counts[1]));
    expect(counts[1], greaterThan(counts[2]));
  });

  testWidgets('width and measured glyph size determine safe throughput', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    Future<int> count(double width, String text, double fontSize) async {
      final comments = List.generate(
        400,
        (i) => bullet('$i', text: text, at: i * 20),
      );
      await showOverlay(
        tester,
        comments,
        size: Size(width, 720),
        area: .5,
        at: 6500,
        fontSize: fontSize,
      );
      final rects = visibleRects(tester);
      expectSeparated(rects);
      return rects.length;
    }

    final wideShort = await count(1280, '好看', 18);
    expect(wideShort, greaterThan(await count(640, '好看', 18)));
    expect(wideShort, greaterThan(await count(1280, '这是一条比较长的弹幕内容', 18)));
    expect(wideShort, greaterThan(await count(1280, '好看', 28)));
  });

  testWidgets('simultaneous comments use measured, non-overlapping lanes', (
    tester,
  ) async {
    final comments = List.generate(
      40,
      (i) => bullet('$i', text: '${'宽' * (i % 6 + 1)}-$i'),
    );
    await showOverlay(tester, comments, at: 2200);
    final rects = visibleRects(tester);
    expect(rects.length, greaterThan(1));
    expect(rects.length, lessThan(comments.length));
    expectSeparated(rects);
  });

  testWidgets(
    'scroll tail exits rather than being cut off by estimated width',
    (tester) async {
      final comment = bullet('wide', text: '宽' * 20);
      // Existing duration contract: 7 s + 80 ms per character.
      await showOverlay(tester, [comment], at: 8599);
      final origin = tester.getTopLeft(find.byType(RemoteDanmakuOverlay));
      final rect = tester.getRect(find.text(comment.text));
      expect(rect.right, lessThan(origin.dx + 3));
    },
  );

  testWidgets('glyphs have no blurred duplicate shadows', (tester) async {
    await showOverlay(tester, [bullet('outline')]);
    final text = tester.widget<Text>(find.text('弹幕outline'));
    expect(text.style?.shadows ?? const <Shadow>[], isEmpty);
    expect(text.style?.color, const Color(0xffffffff));
  });

  testWidgets(
    'admitted comments keep their lane and linear motion as others enter',
    (tester) async {
      final comments = [bullet('first'), bullet('next', at: 1200)];
      await showOverlay(tester, comments, at: 1000);
      final a = tester.getTopLeft(find.text('弹幕first'));
      await showOverlay(tester, comments, at: 1500);
      final b = tester.getTopLeft(find.text('弹幕first'));
      await showOverlay(tester, comments, at: 2000);
      final c = tester.getTopLeft(find.text('弹幕first'));
      expect(a.dy, b.dy);
      expect(b.dy, c.dy);
      expect(a.dx - b.dx, closeTo(b.dx - c.dx, .01));
      expect(a.dx, greaterThan(b.dx));
      expectSeparated(visibleRects(tester));
    },
  );

  testWidgets(
    'mixed top, bottom, reverse and fast following comments never collide',
    (tester) async {
      final comments = [
        bullet('long', text: '宽' * 36),
        bullet('reverse', mode: DanmakuMode.reverse),
        bullet('top', mode: DanmakuMode.top),
        bullet('bottom', mode: DanmakuMode.bottom),
        for (var i = 0; i < 30; i++)
          bullet(
            'follower$i',
            at: 300 + i * 180,
            text: i.isEven ? 'W' * 28 : '窄$i',
          ),
      ];
      for (var at = 1000; at < 12000; at += 250) {
        await showOverlay(tester, comments, at: at, area: .5);
        expectSeparated(visibleRects(tester));
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('text scaling and subtitle exclusions constrain every mode', (
    tester,
  ) async {
    final comments = [
      for (var i = 0; i < 20; i++)
        bullet(
          'mode$i',
          mode: DanmakuMode.values[i % DanmakuMode.values.length],
        ),
    ];
    const exclusion = Rect.fromLTWH(0, 220, 640, 110);
    await showOverlay(
      tester,
      comments,
      at: 1500,
      scale: 1.8,
      fontSize: 28,
      exclusion: exclusion,
    );
    final origin = tester.getTopLeft(find.byType(RemoteDanmakuOverlay));
    final bounds = danmakuDisplayBounds(
      const Size(640, 360),
      1,
      excludedArea: exclusion,
    ).shift(origin);
    final rects = visibleRects(tester);
    expect(rects, isNotEmpty);
    for (final rect in rects) {
      expect(rect.top, greaterThanOrEqualTo(bounds.top));
      expect(rect.bottom, lessThanOrEqualTo(bounds.bottom));
      expect(rect.overlaps(exclusion.shift(origin)), isFalse);
    }
    expectSeparated(rects);
    expect(tester.takeException(), isNull);
  });

  testWidgets('area reductions admit fewer actual rendered comments', (
    tester,
  ) async {
    final comments = List.generate(
      40,
      (i) => bullet('$i', mode: DanmakuMode.top),
    );
    final counts = <int>[];
    for (final area in [1.0, .5, .25]) {
      await showOverlay(tester, comments, area: area);
      final rects = visibleRects(tester);
      final bounds = danmakuDisplayBounds(const Size(640, 360), area);
      final laneHeight = DanmakuText.measure(text: '弹幕Ag').height + 3;
      expect(rects.length, (bounds.height / laneHeight).floor());
      expectSeparated(rects);
      counts.add(rects.length);
    }
    expect(counts[0], greaterThan(counts[1]));
    expect(counts[1], greaterThan(counts[2]));
  });

  testWidgets('no lane is forced into an empty subtitle-safe area', (
    tester,
  ) async {
    await showOverlay(tester, [
      bullet('hidden'),
    ], exclusion: const Rect.fromLTWH(0, 0, 640, 360));
    expect(find.text('弹幕hidden'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'header, footer and subtitle reservations compose without overlap',
    (tester) async {
      const insets = EdgeInsets.fromLTRB(16, 75, 16, 90);
      const subtitle = Rect.fromLTWH(0, 200, 640, 65);
      final comments = List.generate(
        12,
        (i) => bullet(
          'reserved$i',
          mode: i.isEven ? DanmakuMode.top : DanmakuMode.bottom,
        ),
      );
      await showOverlay(
        tester,
        comments,
        reservedInsets: insets,
        exclusion: subtitle,
      );
      final origin = tester.getTopLeft(find.byType(RemoteDanmakuOverlay));
      for (final rect in visibleRects(tester)) {
        expect(rect.top, greaterThanOrEqualTo(origin.dy + 75));
        expect(rect.bottom, lessThanOrEqualTo(origin.dy + 194));
        expect(rect.left, greaterThanOrEqualTo(origin.dx + 16));
        expect(rect.right, lessThanOrEqualTo(origin.dx + 624));
      }
      expect(visibleRects(tester), isNotEmpty);
      expectSeparated(visibleRects(tester));
      expect(tester.takeException(), isNull);
    },
  );

  test('footer reservation does not take space from upper quarter twice', () {
    final bounds = danmakuDisplayBounds(
      const Size(640, 360),
      .25,
      reservedInsets: const EdgeInsets.only(bottom: 90),
    );
    expect(bounds.bottom, 90);
  });

  testWidgets('reusable outlined text matches measured scaled dimensions', (
    tester,
  ) async {
    const text = 'Wii 宽字 👋';
    const scaler = TextScaler.linear(1.5);
    final size = DanmakuText.measure(
      text: text,
      fontSize: 24,
      textScaler: scaler,
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: MediaQuery(
            data: MediaQueryData(textScaler: scaler),
            child: DanmakuText(text: text, fontSize: 24, opacity: .4),
          ),
        ),
      ),
    );
    final rendered = tester.getSize(find.byType(DanmakuText));
    expect(rendered.width, closeTo(size.width, .01));
    expect(rendered.height, closeTo(size.height, .01));
    expect(find.text(text), findsOneWidget);
    final style = tester.widget<Text>(find.text(text)).style!;
    expect(style.fontFamily, 'NotoSansSC');
    expect(style.fontWeight, FontWeight.w600);
    expect(tester.widget<Text>(find.text(text)).style?.shadows, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reverse travels right and fixed comments stay anchored', (
    tester,
  ) async {
    final comments = [
      bullet('reverse', mode: DanmakuMode.reverse),
      bullet('top', mode: DanmakuMode.top),
      bullet('bottom', mode: DanmakuMode.bottom),
      bullet('advanced', mode: DanmakuMode.advanced),
    ];
    await showOverlay(tester, comments, at: 1000);
    final reverse = tester.getTopLeft(find.text('弹幕reverse'));
    final top = tester.getTopLeft(find.text('弹幕top'));
    final bottom = tester.getTopLeft(find.text('弹幕bottom'));
    final advanced = tester.getTopLeft(find.text('弹幕advanced'));
    await showOverlay(tester, comments, at: 2000);
    expect(
      tester.getTopLeft(find.text('弹幕reverse')).dx,
      greaterThan(reverse.dx),
    );
    expect(tester.getTopLeft(find.text('弹幕top')), top);
    expect(tester.getTopLeft(find.text('弹幕bottom')), bottom);
    expect(tester.getTopLeft(find.text('弹幕advanced')), advanced);
    expect(top.dy, lessThan(bottom.dy));
    expectSeparated(visibleRects(tester));
  });

  testWidgets('seek-back deterministically rebuilds the same early lanes', (
    tester,
  ) async {
    final comments = List.generate(30, (i) => bullet('seek$i', at: i * 100));
    await showOverlay(tester, comments, at: 2000);
    final before = visibleRects(tester);
    await showOverlay(tester, comments, at: 20000);
    await showOverlay(tester, comments, at: 2000);
    expect(visibleRects(tester), before);
    expect(tester.takeException(), isNull);
  });
  testWidgets('long timeline seeks are windowed and frames do not rescan', (
    tester,
  ) async {
    final timeline = CountingTimeline(
      List.generate(100000, (i) => bullet('long$i', at: i * 1000)),
    );
    await showOverlay(tester, timeline, at: 60000100);
    expect(timeline.reads, lessThan(200));
    expect(visibleRects(tester), isNotEmpty);
    timeline.reads = 0;
    await showOverlay(tester, timeline, at: 60000116);
    expect(timeline.reads, lessThan(5));
    expectSeparated(visibleRects(tester));
  });

  testWidgets(
    'dense bursts bound candidate work and never repopulate on the next frame',
    (tester) async {
      final timeline = CountingTimeline(
        List.generate(10000, (i) => bullet('burst$i', mode: DanmakuMode.top)),
      );
      await showOverlay(tester, timeline, at: 1000);
      expect(timeline.reads, lessThan(200));
      final first = visibleRects(tester);
      expect(first, isNotEmpty);
      final bounds = danmakuDisplayBounds(const Size(640, 360), 1);
      final laneHeight = DanmakuText.measure(text: '弹幕Ag').height + 3;
      expect(first.length, (bounds.height / laneHeight).floor());
      expectSeparated(first);
      timeline.reads = 0;
      await showOverlay(tester, timeline, at: 1016);
      expect(timeline.reads, lessThan(5));
      expect(visibleRects(tester), first);
      await showOverlay(tester, timeline, at: 4100);
      expect(visibleRects(tester), isEmpty);
    },
  );

  testWidgets('sustained dense seeks stay bounded without sparse quotas', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1920, 1080));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final timeline = CountingTimeline(
      List.generate(
        100000,
        (i) => bullet('$i', text: '这是一条用于检查高密度播放的长弹幕内容', at: i),
      ),
    );
    await showOverlay(
      tester,
      timeline,
      size: const Size(1920, 1080),
      at: 60000,
      speed: .5,
    );
    final rects = visibleRects(tester);
    expect(rects.length, greaterThan(24));
    expect(find.byType(DanmakuText).evaluate().length, lessThanOrEqualTo(256));
    expect(timeline.reads, lessThan(30000));
    expectSeparated(rects);
    timeline.reads = 0;
    await showOverlay(
      tester,
      timeline,
      size: const Size(1920, 1080),
      at: 60016,
      speed: .5,
    );
    expect(timeline.reads, lessThan(100));
    expectSeparated(visibleRects(tester));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'dark source glyphs retain a crisp light outline after color changes',
    (tester) async {
      const key = ValueKey('dark-danmaku');
      Future<void> paint(Color color) => tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: RepaintBoundary(
              key: key,
              child: ColoredBox(
                color: Colors.black,
                child: DanmakuText(text: '弹幕Ag', color: color, opacity: 1),
              ),
            ),
          ),
        ),
      );
      await paint(Colors.white);
      await paint(Colors.black);
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(key),
      );
      final hasLightOutline = await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        try {
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          for (var i = 0; i < bytes.lengthInBytes; i += 4) {
            if (bytes.getUint8(i) > 200 &&
                bytes.getUint8(i + 1) > 200 &&
                bytes.getUint8(i + 2) > 200) {
              return true;
            }
          }
          return false;
        } finally {
          image.dispose();
        }
      });
      expect(
        hasLightOutline,
        isTrue,
        reason: 'Black glyphs need a visible light outline on a black frame',
      );
      expect(tester.widget<Text>(find.text('弹幕Ag')).style?.shadows, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('all-blocked bursts still obey the candidate read budget', (
    tester,
  ) async {
    final timeline = CountingTimeline(
      List.generate(10000, (i) => bullet('blocked$i', text: '屏蔽内容$i')),
    );
    await showOverlay(tester, timeline, blockKeywords: ['屏蔽']);
    expect(timeline.reads, lessThan(200));
    expect(visibleRects(tester), isEmpty);
    timeline.reads = 0;
    await showOverlay(tester, timeline, at: 1016, blockKeywords: ['屏蔽']);
    expect(timeline.reads, lessThan(5));
  });

  testWidgets(
    'bounded burst sampling reaches valid comments after a blocked prefix',
    (tester) async {
      final timeline = CountingTimeline([
        ...List.generate(9999, (i) => bullet('blocked$i', text: '屏蔽内容$i')),
        bullet('allowed', text: '保留这条', mode: DanmakuMode.top),
      ]);
      await showOverlay(tester, timeline, blockKeywords: ['屏蔽']);
      expect(timeline.reads, lessThan(200));
      expect(find.text('保留这条'), findsOneWidget);
      final before = tester.getRect(find.text('保留这条'));
      timeline.reads = 0;
      await showOverlay(tester, timeline, at: 1016, blockKeywords: ['屏蔽']);
      expect(timeline.reads, lessThan(5));
      expect(tester.getRect(find.text('保留这条')), before);
    },
  );

  testWidgets(
    'midtimeline seek preserves earlier admission and rejection decisions',
    (tester) async {
      final timeline = CountingTimeline(
        List.generate(
          20,
          (i) => bullet(
            'at${i * 3}',
            text: 'at${i * 3}',
            at: i * 3000,
            mode: DanmakuMode.top,
          ),
        ),
      );
      // One lane, four-second fixed comments arriving every three seconds:
      // 0/6/12/18/24/30 are admitted; 3/9/15/21/27 must stay rejected.
      Future<void> frame(int at) => showOverlay(
        tester,
        timeline,
        at: at,
        size: const Size(640, 64),
        fontSize: 28,
      );
      for (var at = 0; at <= 27000; at += 1000) {
        await frame(at);
      }
      await frame(27500);
      expect(find.text('at24'), findsOneWidget);
      expect(find.text('at27'), findsNothing);
      final before = tester.getRect(find.text('at24'));
      await frame(30000);
      expect(find.text('at30'), findsOneWidget);
      timeline.reads = 0;
      await frame(27500);
      expect(find.text('at24'), findsOneWidget);
      expect(find.text('at27'), findsNothing);
      expect(tester.getRect(find.text('at24')), before);
      expect(
        timeline.reads,
        lessThan(10),
        reason: 'Restore a checkpoint, not the episode',
      );
      // Also restore an intermediate time that was not itself rendered before.
      await frame(27250);
      expect(find.text('at24'), findsOneWidget);
      expect(find.text('at27'), findsNothing);
      await frame(28500);
      expect(visibleRects(tester), isEmpty);
      await frame(30000);
      expect(find.text('at30'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
