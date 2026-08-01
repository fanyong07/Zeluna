import 'dart:async';

import 'package:anime/src/player/gestures/player_gesture_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('gesture controller replaces and disposes chrome timers', () async {
    final controller = PlayerGestureController();
    var callbacks = 0;
    controller.replaceControlsHideTimer(
      Timer(const Duration(milliseconds: 5), () => callbacks++),
    );
    controller.replaceControlsHideTimer(
      Timer(const Duration(milliseconds: 15), () => callbacks++),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(callbacks, 1);

    controller.replaceControlsHideTimer(
      Timer(const Duration(milliseconds: 5), () => callbacks++),
    );
    controller.dispose();
    controller.replaceControlsHideTimer(
      Timer(Duration.zero, () => callbacks++),
    );
    await Future<void>.delayed(const Duration(milliseconds: 15));

    expect(controller.isDisposed, isTrue);
    expect(controller.controlsHideTimer, isNull);
    expect(callbacks, 1);
  });
}
