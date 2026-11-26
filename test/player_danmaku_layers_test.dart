import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/player/danmaku/danmaku_controller.dart';
import 'package:anime/src/player/danmaku_overlay.dart';
import 'package:anime/src/player/player_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const remote = [
  DanmakuComment(
    id: 'r',
    provider: 'fixture',
    time: Duration.zero,
    mode: DanmakuMode.top,
    color: 0xffffff,
    text: '远程弹幕',
  ),
];
const local = [LocalDanmakuEntry(id: 1, text: '本地发送')];

Future<void> showLayers(
  WidgetTester tester, {
  EdgeInsets insets = EdgeInsets.zero,
  List<LocalDanmakuEntry> entries = local,
  double height = 360,
}) => tester.pumpWidget(
  MaterialApp(
    home: Center(
      child: SizedBox(
        width: 640,
        height: height,
        child: PlayerDanmakuLayers(
          remoteComments: remote,
          localComments: entries,
          settings: const DanmakuSettings(displayArea: .25),
          position: const Duration(seconds: 1),
          reservedInsets: insets,
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets(
    'local animation releases reserved lanes before controller records expire',
    (tester) async {
      await showLayers(tester);
      expect(
        tester
            .widget<RemoteDanmakuOverlay>(find.byType(RemoteDanmakuOverlay))
            .reservedInsets
            .bottom,
        greaterThan(0),
      );
      expect(find.text('本地发送'), findsOneWidget);
      await tester.pump(const Duration(seconds: 8));
      await tester.pump();
      expect(
        tester
            .widget<RemoteDanmakuOverlay>(find.byType(RemoteDanmakuOverlay))
            .reservedInsets
            .bottom,
        0,
      );
      expect(find.text('本地发送'), findsNothing);
      expect(find.text('远程弹幕'), findsOneWidget);
      // The controller's 24-second record remains, but may not be replayed.
      await showLayers(tester, insets: const EdgeInsets.only(top: 100));
      await showLayers(tester);
      expect(find.text('本地发送'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'hidden local lanes still finish and never replay after chrome closes',
    (tester) async {
      await showLayers(tester);
      await tester.pump(const Duration(seconds: 2));
      await showLayers(tester, insets: const EdgeInsets.only(top: 100));
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();
      await showLayers(tester);
      expect(find.text('本地发送'), findsNothing);
      expect(find.text('远程弹幕'), findsOneWidget);
      expect(
        tester
            .widget<RemoteDanmakuOverlay>(find.byType(RemoteDanmakuOverlay))
            .reservedInsets,
        EdgeInsets.zero,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('one available lane displays the newest local send', (
    tester,
  ) async {
    await showLayers(
      tester,
      height: 240,
      entries: const [
        LocalDanmakuEntry(id: 1, text: '旧发送'),
        LocalDanmakuEntry(id: 2, text: '最新发送'),
      ],
    );
    await tester.pump(const Duration(seconds: 2));
    final origin = tester.getTopLeft(find.byType(PlayerDanmakuLayers));
    final newest = tester.getRect(find.text('最新发送'));
    final bounds = danmakuDisplayBounds(
      const Size(640, 240),
      .25,
    ).shift(origin);
    expect(newest.overlaps(bounds), isTrue);
    expect(newest.bottom, lessThanOrEqualTo(bounds.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'displaced local send never reappears when a later send finishes',
    (tester) async {
      const a = LocalDanmakuEntry(id: 1, text: 'A');
      const b = LocalDanmakuEntry(id: 2, text: 'B');
      const c = LocalDanmakuEntry(id: 3, text: 'C');
      await showLayers(tester, entries: [a]);
      await tester.pump(const Duration(seconds: 1));
      await showLayers(tester, entries: [a, b]);
      await tester.pump(const Duration(seconds: 1));
      await showLayers(tester, entries: [a, b, c]);
      expect(find.text('A'), findsNothing);
      await tester.pump(const Duration(milliseconds: 6300));
      await tester.pump();
      expect(find.text('A'), findsNothing);
      expect(find.text('B'), findsNothing);
      expect(find.text('C'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
