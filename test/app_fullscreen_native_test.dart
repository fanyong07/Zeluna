import 'dart:io';

import 'package:anime/src/player/app_fullscreen_native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('app.anime.anime/window');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'setFullscreen':
              return call.arguments as bool;
            case 'isFullscreen':
              return true;
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group(
    'AppFullscreenController on Windows',
    () {
      test('sets fullscreen through the native window channel', () async {
        final controller = AppFullscreenController();

        expect(await controller.setEnabled(true), isTrue);
        expect(calls, hasLength(1));
        expect(calls.single.method, 'setFullscreen');
        expect(calls.single.arguments, isTrue);
      });

      test('exits fullscreen through the same native channel', () async {
        final controller = AppFullscreenController();
        expect(await controller.setEnabled(false), isFalse);
        expect(calls.single.method, 'setFullscreen');
        expect(calls.single.arguments, isFalse);
      });

      test(
        'returns native refusal instead of echoing the requested state',
        () async {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, (call) async => false);
          expect(await AppFullscreenController().setEnabled(true), isFalse);
        },
      );

      test(
        'preserves native errors so the player can report failure',
        () async {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, (call) async {
                throw PlatformException(code: 'window_unavailable');
              });
          await expectLater(
            AppFullscreenController().setEnabled(true),
            throwsA(isA<PlatformException>()),
          );
        },
      );

      test(
        'returns the real fullscreen state from the native channel',
        () async {
          final controller = AppFullscreenController();

          expect(await controller.isEnabled(), isTrue);
          expect(calls, hasLength(1));
          expect(calls.single.method, 'isFullscreen');
          expect(calls.single.arguments, isNull);
        },
      );
    },
    skip: Platform.isWindows ? false : 'Windows-only native channel',
  );
}
