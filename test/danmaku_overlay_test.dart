import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/player/danmaku_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('偏移后的滚动位置与原时间轴同一帧完全一致', (tester) async {
    const comments = [
      DanmakuComment(
        id: 'one',
        provider: 'fixture',
        time: Duration(seconds: 2),
        text: '移动中',
        color: 0xffffff,
        mode: DanmakuMode.scroll,
      ),
    ];
    Future<double> left(int milliseconds, double offset) async {
      await tester.pumpWidget(
        MaterialApp(
          home: RemoteDanmakuOverlay(
            comments: comments,
            settings: DanmakuSettings(timeOffsetSeconds: offset),
            position: Duration(milliseconds: milliseconds),
          ),
        ),
      );
      return tester.getTopLeft(find.byType(DanmakuText)).dx;
    }

    final reference = await left(3200, 0);
    expect(await left(4200, 1), reference);
    expect(await left(2200, -1), reference);
    expect(await left(4200, 0), lessThan(reference));
  });
}
