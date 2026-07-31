import 'package:anime/src/player/player_page.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fullscreen player disables safe-area padding on every edge', () {
    final safeArea = buildPlayerSafeArea(
      fullscreen: true,
      child: const SizedBox.shrink(),
    );

    expect(safeArea.left, isFalse);
    expect(safeArea.top, isFalse);
    expect(safeArea.right, isFalse);
    expect(safeArea.bottom, isFalse);
  });

  test('Android landscape keeps the mobile player layout', () {
    expect(
      usesMobilePlayerLayoutForSize(
        const Size(800, 360),
        TargetPlatform.android,
      ),
      isTrue,
    );
    expect(
      usesMobilePlayerLayoutForSize(
        const Size(800, 360),
        TargetPlatform.windows,
      ),
      isFalse,
    );
    expect(
      usesMobilePlayerLayoutForSize(
        const Size(430, 900),
        TargetPlatform.windows,
      ),
      isTrue,
    );
  });

  test('portrait mobile player keeps video above a details surface', () {
    expect(
      usesPortraitPlayerPageLayoutForSize(
        const Size(430, 900),
        TargetPlatform.android,
        fullscreen: false,
      ),
      isTrue,
    );
    expect(
      usesPortraitPlayerPageLayoutForSize(
        const Size(430, 900),
        TargetPlatform.android,
        fullscreen: true,
      ),
      isFalse,
    );
    expect(
      usesPortraitPlayerPageLayoutForSize(
        const Size(900, 430),
        TargetPlatform.android,
        fullscreen: false,
      ),
      isFalse,
    );
  });

  test('player function panel uses about 30 percent in landscape', () {
    expect(playerFunctionPanelWidthForSize(const Size(1280, 720)), 384);
    expect(playerFunctionPanelWidthForSize(const Size(800, 360)), 240);
    expect(playerFunctionPanelWidthForSize(const Size(430, 900)), 430);
  });

  test('double tap zones map to rewind, play pause, and forward', () {
    expect(
      playerDoubleTapActionForPosition(120, 800),
      PlayerDoubleTapAction.rewind,
    );
    expect(
      playerDoubleTapActionForPosition(400, 800),
      PlayerDoubleTapAction.togglePlayPause,
    );
    expect(
      playerDoubleTapActionForPosition(700, 800),
      PlayerDoubleTapAction.forward,
    );
  });

  testWidgets('single tap only toggles player chrome', (tester) async {
    var taps = 0;
    var playPause = 0;
    await _pumpGestureSurface(
      tester,
      onTap: () => taps++,
      onDoubleTapCenter: () async => playPause++,
    );

    await tester.tap(find.byKey(const ValueKey('playerGestureSurface')));
    await tester.pump(const Duration(milliseconds: 350));

    expect(taps, 1);
    expect(playPause, 0);
  });

  testWidgets('long press enables 2x only while the finger is down', (
    tester,
  ) async {
    var starts = 0;
    var ends = 0;
    await _pumpGestureSurface(
      tester,
      onLongPressStart: () => starts++,
      onLongPressEnd: () => ends++,
    );

    final center = tester.getCenter(
      find.byKey(const ValueKey('playerGestureSurface')),
    );
    final gesture = await tester.startGesture(center);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    expect(starts, 1);
    expect(ends, 0);
    expect(find.text('2.0x  松开恢复'), findsOneWidget);

    await gesture.up();
    await tester.pump();
    expect(ends, 1);
  });

  testWidgets('right-side vertical drag adjusts player volume', (tester) async {
    var volume = 100.0;
    await _pumpGestureSurface(
      tester,
      onVolumeChanged: (value) => volume = value,
    );

    await tester.dragFrom(const Offset(700, 180), const Offset(0, -80));
    await tester.pump();

    expect(volume, greaterThan(100));
    expect(find.textContaining('音量'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 600));
  });

  testWidgets('horizontal drag seeks playback progress', (tester) async {
    var seekTarget = Duration.zero;
    await _pumpGestureSurface(
      tester,
      position: const Duration(minutes: 5),
      duration: const Duration(minutes: 10),
      onSeek: (value) async => seekTarget = value,
    );

    // Half the surface width → about halfway through the remaining timeline
    // when starting from 5:00 of a 10:00 video.
    await tester.dragFrom(const Offset(400, 180), const Offset(200, 0));
    await tester.pump();

    expect(seekTarget, greaterThan(const Duration(minutes: 5)));
    expect(seekTarget, lessThanOrEqualTo(const Duration(minutes: 10)));
    expect(find.textContaining('/'), findsWidgets);
    await tester.pump(const Duration(milliseconds: 600));
  });

  testWidgets('clicking or touching outside a right-side panel dismisses it', (
    tester,
  ) async {
    var dismisses = 0;
    var panelTaps = 0;
    tester.view.physicalSize = const Size(1000, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayerPanelDismissLayer(
            onDismiss: () => dismisses++,
            panel: Align(
              alignment: Alignment.centerRight,
              child: SizedBox(
                width: 500,
                height: double.infinity,
                child: Material(
                  color: Colors.black,
                  child: InkWell(
                    key: const ValueKey('testPlayerPanel'),
                    onTap: () => panelTaps++,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tapAt(const Offset(200, 300), kind: PointerDeviceKind.touch);
    await tester.pump();
    expect(dismisses, 1);
    expect(panelTaps, 0);

    await tester.tapAt(const Offset(200, 300), kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect(dismisses, 2);
    expect(panelTaps, 0);

    await tester.tapAt(const Offset(800, 300));
    await tester.pump();
    expect(dismisses, 2);
    expect(panelTaps, 1);
  });
}

Future<void> _pumpGestureSurface(
  WidgetTester tester, {
  VoidCallback? onTap,
  Future<void> Function()? onDoubleTapCenter,
  VoidCallback? onLongPressStart,
  VoidCallback? onLongPressEnd,
  ValueChanged<double>? onVolumeChanged,
  Duration position = Duration.zero,
  Duration duration = Duration.zero,
  Future<void> Function(Duration position)? onSeek,
}) async {
  tester.view.physicalSize = const Size(800, 360);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PlayerGestureSurface(
          volume: 100,
          mobileGesturesEnabled: true,
          position: position,
          duration: duration,
          onSeek: onSeek,
          onVolumeChanged: onVolumeChanged ?? (_) {},
          onTap: onTap ?? () {},
          onDoubleTapLeft: () async {},
          onDoubleTapCenter: onDoubleTapCenter ?? () async {},
          onDoubleTapRight: () async {},
          onLongPressStart: onLongPressStart ?? () {},
          onLongPressEnd: onLongPressEnd ?? () {},
          child: const ColoredBox(color: Colors.black),
        ),
      ),
    ),
  );
  await tester.pump();
}
