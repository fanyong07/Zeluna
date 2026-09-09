import 'package:anime/src/player/video/native_video_compatibility.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('app.anime.anime/video-compatibility');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'affected Android runtime selects software decoding before video open',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'requiresSoftwareVideoDecode');
        expect(call.arguments, isNull);
        return true;
      });
      final compatibility = NativeVideoCompatibility();
      await compatibility.initialize();
      expect(compatibility.configuration.hwdec, 'no');
      // Keep GPU rendering; only the MediaCodec decoder is bypassed.
      expect(compatibility.configuration.enableHardwareAcceleration, isTrue);
    },
  );

  test('unaffected Android retains media-kit automatic decoding', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => false);
    final compatibility = NativeVideoCompatibility();
    await compatibility.initialize();
    expect(compatibility.configuration.hwdec, isNull);
  });

  test(
    'desktop does not query the Android channel or change decoding',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (_) async {
        calls++;
        return true;
      });
      final compatibility = NativeVideoCompatibility();
      await compatibility.initialize();
      expect(calls, 0);
      expect(compatibility.configuration.hwdec, isNull);
    },
  );

  test('missing native channel does not prevent startup', () async {
    final compatibility = NativeVideoCompatibility();
    await compatibility.initialize();
    expect(compatibility.configuration.hwdec, isNull);
  });

  test('platform failure does not prevent startup', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'unavailable'),
    );
    final compatibility = NativeVideoCompatibility();
    await compatibility.initialize();
    expect(compatibility.configuration.hwdec, isNull);
  });
}
