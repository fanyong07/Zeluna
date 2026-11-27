import 'dart:async';

import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/player/danmaku/danmaku_controller.dart';
import 'package:anime/src/player/danmaku_overlay.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

DanmakuComment bullet(int i) => DanmakuComment(
  id: '$i',
  provider: 'fixture',
  time: const Duration(seconds: 2),
  text: '第$i条',
  color: 0xffffff,
  mode: DanmakuMode.top,
);

void main() {
  test('显示设置解码兼容旧版本，拒绝超范围偏移和负密度', () {
    final old = DanmakuSettings.fromJson({});
    expect(old.timeOffsetSeconds, 0);
    expect(old.maxOnScreen, 0);
    final read = DanmakuSettings.fromJson(
      old.copyWith(timeOffsetSeconds: -1.5, maxOnScreen: 24).toJson(),
    );
    expect(read.timeOffsetSeconds, -1.5);
    expect(read.maxOnScreen, 24);
    expect(
      DanmakuSettings.fromJson({
        'timeOffsetSeconds': 30,
        'maxOnScreen': -2,
      }).timeOffsetSeconds,
      10,
    );
    expect(DanmakuSettings.fromJson({'maxOnScreen': -2}).maxOnScreen, 0);
  });

  testWidgets('时间筛选和实际画面使用同一时间轴，密度切换立即生效', (tester) async {
    final comments = List.generate(60, bullet);
    Future<void> show(
      int seconds,
      double offset,
      int cap, {
      required int count,
    }) async {
      final settings = DanmakuSettings(
        displayArea: 1,
        timeOffsetSeconds: offset,
        maxOnScreen: cap,
      );
      final position = Duration(seconds: seconds);
      expect(
        visibleDanmakuComments(
          comments,
          position: position,
          settings: settings,
        ),
        count == 0 ? isEmpty : isNotEmpty,
      );
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(),
            child: RemoteDanmakuOverlay(
              comments: comments,
              settings: settings,
              position: position,
            ),
          ),
        ),
      );
      expect(find.byType(DanmakuText), findsNWidgets(count));
    }

    await show(0, 3, 12, count: 0);
    await show(2, 1, 12, count: 0);
    await show(3, 1, 12, count: 12);
    await show(1, -1, 12, count: 12);
    await show(1, -1, 1, count: 1);
    await show(
      1,
      -1,
      0,
      count:
          (danmakuDisplayBounds(const Size(800, 600), 1).height /
                  (DanmakuText.measure(text: '弹幕Ag').height + 3))
              .floor(),
    );
  });

  test('手动时间线覆盖待返回的自动匹配，下集不会继承', () async {
    final controller = DanmakuController();
    addTearDown(controller.dispose);
    final pending = Completer<DanmakuTimeline>();
    final loading = controller.loadEpisode(
      episodeId: 7,
      load: () => pending.future,
    );
    var updates = 0;
    controller.addListener(() => updates++);
    controller.applyManualTimeline(7, DanmakuTimeline(comments: [bullet(2)]));
    pending.complete(DanmakuTimeline(comments: [bullet(1)]));
    await loading;
    expect(updates, 1);
    expect(controller.remoteComments.single.id, '2');
    controller.changeEpisode();
    expect(controller.remoteComments, isEmpty);
    expect(controller.requestedEpisodeId, isNull);
  });
}
