import 'dart:async';

import 'package:anime/src/player/video/native_android_surface_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('app.anime.anime/native-video-surface');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late _Player engine;
  late Player player;
  late NativeAndroidSurfaceController surface;
  late List<String> order;
  late Map<String, Object?> active;
  late int count;
  late String? failMethod;
  late Completer<Map<String, Object?>>? heldProbe;
  late Completer<void>? heldPlayerWait;
  late List<Map<String, Object?>> resizeRequests;

  setUp(() {
    engine = _Player();
    player = Player(platformPlayer: engine);
    order = [];
    active = {};
    count = 0;
    failMethod = null;
    heldProbe = null;
    heldPlayerWait = null;
    resizeRequests = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      order.add(call.method);
      if (call.method == failMethod) {
        throw PlatformException(code: 'fixture_failure');
      }
      final args = Map<String, Object?>.from(call.arguments as Map);
      if (call.method == 'create') {
        active = {
          'open_serial': args['open_serial'],
          'epoch': args['epoch'],
          'frame_count': 0,
          'width': args['width'],
          'height': args['height'],
          'reason': 'awaiting_image',
        };
        return {'texture_id': ++count, 'wid': count * 100};
      }
      if (call.method == 'resize') {
        resizeRequests.add(args);
        if (args['open_serial'] != active['open_serial'] ||
            args['epoch'] != active['epoch']) {
          throw PlatformException(code: 'stale_surface');
        }
        // This mock deliberately does not turn metadata into a real consumed
        // buffer. Only an explicit frame fixture below changes frame evidence.
        return true;
      }
      if (call.method == 'probe') {
        return heldProbe?.future ?? Map<String, Object?>.from(active);
      }
      return null;
    });
    surface = NativeAndroidSurfaceController.forTesting(
      player: player,
      setProperty: (key, value) async => order.add('$key=$value'),
      waitForPlayer: () async {
        await heldPlayerWait?.future;
      },
    );
  });
  tearDown(() async {
    failMethod = null;
    await surface.dispose();
    await player.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('dimensions and a created texture are not frame evidence', () async {
    await surface.beginOpen(7);
    active['width'] = 1280;
    active['height'] = 720;
    var rendered = false;
    unawaited(surface.waitUntilFirstFrameRendered.then((_) => rendered = true));
    expect(await surface.readFrame(serial: 7), isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(rendered, isFalse);
    expect(surface.lastFrame?.frames, 0);
    active.addAll({'frame_count': 1, 'reason': 'texture_frame_consumed'});
    expect(await surface.readFrame(serial: 7), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(rendered, isTrue);
  });

  test(
    '1080p video params resize metadata without reopening the codec',
    () async {
      await surface.beginOpen(7);
      final texture = surface.id.value;
      final epoch = active['epoch'];
      order.clear();
      const params = VideoParams(w: 1920, h: 1080, dw: 1920, dh: 1080);
      engine.emitVideoParams(params);
      await Future<void>.delayed(Duration.zero);
      expect(order, ['resize']);
      expect(resizeRequests.single, containsPair('resize_buffers', false));
      expect(surface.id.value, texture);
      expect(active['epoch'], epoch);
      expect(surface.rect.value?.size, const Size(1920, 1080));
      expect(active['frame_count'], 0);
      expect(await surface.readFrame(serial: 7), isFalse);
      active.addAll({
        'frame_count': 1,
        'width': 1920,
        'height': 1080,
        'reason': 'texture_frame_consumed',
      });
      expect(await surface.readFrame(serial: 7), isTrue);
      expect(surface.lastFrame?.epoch, epoch);
    },
  );

  test(
    'metadata resize preserves actual frame evidence and its surface epoch',
    () async {
      await surface.beginOpen(1);
      active.addAll({
        'frame_count': 6,
        'width': 640,
        'height': 360,
        'reason': 'texture_frame_consumed',
      });
      expect(await surface.readFrame(serial: 1), isTrue);
      final before = surface.lastFrame;
      final texture = surface.id.value;
      order.clear();
      const params = VideoParams(w: 1920, h: 1080, dw: 1920, dh: 1080);
      engine.emitVideoParams(params);
      await Future<void>.delayed(Duration.zero);
      expect(order, ['resize']);
      expect(surface.id.value, texture);
      expect(surface.lastFrame, same(before));
      expect(await surface.readFrame(serial: 1), isTrue);
      expect(surface.lastFrame?.frames, 6);
      expect(surface.lastFrame?.width, 640);
    },
  );

  test(
    'queued old-open resize never targets the replacement surface',
    () async {
      await surface.beginOpen(1);
      heldPlayerWait = Completer<void>();
      final nextOpen = surface.beginOpen(2);
      const params = VideoParams(w: 1920, h: 1080, dw: 1920, dh: 1080);
      engine.emitVideoParams(params);
      await Future<void>.delayed(Duration.zero);
      heldPlayerWait!.complete();
      await nextOpen;
      await Future<void>.delayed(Duration.zero);
      expect(active['open_serial'], 2);
      expect(active['frame_count'], 0);
      expect(resizeRequests, isEmpty);
      expect(surface.rect.value?.size, const Size(1, 1));
      expect(surface.lastFrame, isNull);
    },
  );

  test(
    'native resize failure keeps ownership and does not claim a new image',
    () async {
      await surface.beginOpen(1);
      final texture = surface.id.value;
      final epoch = active['epoch'];
      order.clear();
      failMethod = 'resize';
      const params = VideoParams(w: 1920, h: 1080, dw: 1920, dh: 1080);
      engine.emitVideoParams(params);
      await Future<void>.delayed(Duration.zero);
      expect(order, ['resize']);
      expect(surface.id.value, texture);
      expect(active['epoch'], epoch);
      expect(active['frame_count'], 0);
      expect(surface.probeReason, 'surface_resize_failed');
      expect(surface.rect.value?.size, const Size(1, 1));
    },
  );

  test(
    'software output resizes its existing queue instead of recreating it',
    () async {
      await surface.beginOpen(1);
      await surface.useSoftwareOutput();
      final texture = surface.id.value;
      final epoch = active['epoch'];
      order.clear();
      const params = VideoParams(w: 1280, h: 720, dw: 1280, dh: 720);
      engine.emitVideoParams(params);
      await Future<void>.delayed(Duration.zero);
      expect(order, ['resize', 'android-surface-size=1280x720']);
      expect(resizeRequests.single, containsPair('resize_buffers', true));
      expect(surface.id.value, texture);
      expect(active['epoch'], epoch);
      expect(active['frame_count'], 0);
    },
  );

  test(
    'replacement open has fresh texture and rejects the old image epoch',
    () async {
      await surface.beginOpen(7);
      final old = Map<String, Object?>.from(active)
        ..addAll({
          'frame_count': 20,
          'width': 1280,
          'height': 720,
          'reason': 'texture_frame_consumed',
        });
      await surface.beginOpen(8);
      final current = Map<String, Object?>.from(active);
      expect(active['frame_count'], 0);
      expect(surface.lastFrame, isNull);
      active = old;
      expect(await surface.readFrame(serial: 8), isFalse);
      expect(await surface.readFrame(serial: 7), isFalse);
      active = current
        ..addAll({
          'frame_count': 1,
          'width': 1280,
          'height': 720,
          'reason': 'texture_frame_consumed',
        });
      expect(await surface.readFrame(serial: 8), isTrue);
    },
  );

  test(
    'in-flight image from an old texture is rejected after reopen',
    () async {
      await surface.beginOpen(1);
      final old = Map<String, Object?>.from(active)
        ..addAll({
          'frame_count': 1,
          'width': 320,
          'height': 180,
          'reason': 'texture_frame_consumed',
        });
      heldProbe = Completer<Map<String, Object?>>();
      final oldRead = surface.readFrame(serial: 1);
      await Future<void>.delayed(Duration.zero);
      await surface.beginOpen(2);
      heldProbe!.complete(old);
      expect(await oldRead, isFalse);
      expect(surface.lastFrame, isNull);
    },
  );

  test(
    'detach completes before replacing or releasing Surface resources',
    () async {
      await surface.beginOpen(1);
      order.clear();
      await surface.beginOpen(2);
      expect(order.take(4), ['vid=no', 'vo=null', 'wid=0', 'create']);
      order.clear();
      await surface.dispose();
      expect(order, ['vid=no', 'vo=null', 'wid=0', 'dispose']);
    },
  );

  test(
    'software fallback really switches output and resets consumed frames',
    () async {
      await surface.beginOpen(1);
      active.addAll({
        'frame_count': 6,
        'width': 320,
        'height': 180,
        'reason': 'texture_frame_consumed',
      });
      expect(await surface.readFrame(serial: 1), isTrue);
      order.clear();
      await surface.useSoftwareOutput();
      expect(surface.directOutput, isFalse);
      expect(surface.lastFrame, isNull);
      expect(active['frame_count'], 0);
      expect(
        order,
        containsAllInOrder([
          'vo=null',
          'create',
          'hwdec=no',
          'vo=gpu',
          'vid=auto',
        ]),
      );
    },
  );

  test(
    'background teardown and resume preserve the user pause intent',
    () async {
      await surface.beginOpen(3);
      order.clear();
      surface.didChangeAppLifecycleState(AppLifecycleState.paused);
      await Future<void>.delayed(Duration.zero);
      expect(order.last, 'dispose');
      expect(await surface.readFrame(serial: 3), isFalse);
      surface.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      expect(order, contains('create'));
      expect(
        order.any((value) => value == 'pause=no' || value == 'play'),
        isFalse,
      );
      expect(active['frame_count'], 0);
    },
  );

  test(
    'unsupported native Surface fails explicitly instead of passing startup',
    () async {
      failMethod = 'create';
      await expectLater(
        surface.beginOpen(1),
        throwsA(isA<PlatformException>()),
      );
      expect(surface.lastFrame, isNull);
      expect(surface.id.value, isNull);
    },
  );

  test('failed surface consume is not rescued by earlier positive frames', () {
    final frame = NativeSurfaceFrame.fromMap({
      'open_serial': 4,
      'epoch': 2,
      'frame_count': 12,
      'width': 1920,
      'height': 1080,
      'reason': 'texture_consume_failed',
    });
    expect(frame.reason, 'texture_consume_failed');
    expect(frame.hasImage, isFalse);
  });

  test(
    'frame reason uses a strict vocabulary and carries no native message',
    () {
      final frame = NativeSurfaceFrame.fromMap({
        'open_serial': 4,
        'epoch': 2,
        'frame_count': 0,
        'width': 1920,
        'height': 1080,
        'reason': 'https://private.test/?token=secret',
      });
      expect(frame.reason, 'awaiting_image');
      expect(frame.hasImage, isFalse);
    },
  );
}

class _Player extends PlatformPlayer {
  _Player() : super(configuration: const PlayerConfiguration());

  void emitVideoParams(VideoParams params) {
    state = state.copyWith(videoParams: params);
    videoParamsController.add(params);
  }
}
