import 'dart:async';

import 'package:anime/src/player/video/web_video_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'replacing a web startup watchdog cancels the previous callback',
    () async {
      final controller = WebVideoController();
      addTearDown(controller.dispose);
      var callbacks = 0;

      controller.replaceStartupTimer(
        Timer(const Duration(milliseconds: 5), () => callbacks++),
      );
      controller.replaceStartupTimer(
        Timer(const Duration(milliseconds: 15), () => callbacks++),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(callbacks, 1);
    },
  );

  test(
    'dispose prevents startup watchdog callbacks and rejects late timers',
    () async {
      final controller = WebVideoController();
      var callbacks = 0;
      controller.replaceStartupTimer(
        Timer(const Duration(milliseconds: 10), () => callbacks++),
      );

      controller.dispose();
      controller.replaceStartupTimer(Timer(Duration.zero, () => callbacks++));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(controller.isDisposed, isTrue);
      expect(controller.startupTimer, isNull);
      expect(callbacks, 0);
    },
  );
}
