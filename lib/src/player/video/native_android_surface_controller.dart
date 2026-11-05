import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// A new timestamped decoder buffer consumed by Flutter's SurfaceTexture raster
/// output. Dimensions, clocks and media-kit's Android first-frame future are
/// deliberately not accepted as substitutes for this evidence.
final class NativeSurfaceFrame {
  const NativeSurfaceFrame({
    required this.openSerial,
    required this.epoch,
    required this.frames,
    required this.width,
    required this.height,
    this.reason = 'awaiting_image',
  });

  final int openSerial;
  final int epoch;
  final int frames;
  final int width;
  final int height;
  final String reason;

  bool belongsTo({required int serial, required int surfaceEpoch}) =>
      openSerial == serial && epoch == surfaceEpoch;
  bool get hasImage =>
      frames > 0 &&
      width > 1 &&
      height > 1 &&
      reason == 'texture_frame_consumed';

  factory NativeSurfaceFrame.fromMap(Map<Object?, Object?> data) =>
      NativeSurfaceFrame(
        openSerial: (data['open_serial'] as num?)?.toInt() ?? -1,
        epoch: (data['epoch'] as num?)?.toInt() ?? -1,
        frames: (data['frame_count'] as num?)?.toInt() ?? 0,
        width: (data['width'] as num?)?.toInt() ?? 0,
        height: (data['height'] as num?)?.toInt() ?? 0,
        // Native code returns only these fixed reason codes, never exceptions.
        reason: switch (data['reason']) {
          'texture_frame_consumed' => 'texture_frame_consumed',
          'texture_consume_failed' => 'texture_consume_failed',
          'suspended' => 'suspended',
          _ => 'awaiting_image',
        },
      );
}

/// App-owned Android output for the narrowly detected emulator EGL problem.
/// MediaCodec renders into a Flutter-owned SurfaceTexture. Its raster callback
/// confirms distinct consumed buffers in the same Texture widget used by
/// media_kit_video. No mpv/EGL context is involved on the direct path; Flutter's
/// own texture composition remains intact. Physical/default output is unchanged.
final class NativeAndroidSurfaceController
    with WidgetsBindingObserver
    implements VideoController {
  // The public NativePlayer.setProperty wraps a synchronous mpv FFI call, even
  // though it returns Future<void>. command uses mpv_command_async with the
  // player's default async configuration, so codec reconfiguration never blocks
  // Dart's timers or frame scheduling. Await replies to preserve detach order.
  NativeAndroidSurfaceController({required this.player})
    : _setProperty = ((key, value) => (player.platform as NativePlayer).command(
        ['set', key, value],
        waitForInitialization: false,
      )),
      _waitForPlayer = (() =>
          (player.platform as NativePlayer).waitForPlayerInitialization) {
    _attach();
  }

  @visibleForTesting
  NativeAndroidSurfaceController.forTesting({
    required this.player,
    required Future<void> Function(String, String) setProperty,
    required Future<void> Function() waitForPlayer,
  }) : _setProperty = setProperty,
       _waitForPlayer = waitForPlayer {
    _attach();
  }

  static const _channel = MethodChannel('app.anime.anime/native-video-surface');
  final Future<void> Function(String, String) _setProperty;
  final Future<void> Function() _waitForPlayer;
  @override
  final Player player;
  @override
  final platform = Completer<PlatformVideoController>();
  @override
  final notifier = ValueNotifier<PlatformVideoController?>(null);
  @override
  final id = ValueNotifier<int?>(null);
  @override
  final rect = ValueNotifier<Rect?>(null);
  late final _ImageSurfacePlatform _view;
  StreamSubscription<VideoParams>? _params;
  Future<void> _tail = Future<void>.value();
  var _disposed = false;
  var _suspended = false;
  var _openSerial = -1;
  var _epoch = 0;
  var _width = 1;
  var _height = 1;
  var _direct = true;
  var _surfaceAttached = false;
  var _failure = 'awaiting_image';
  NativeSurfaceFrame? _lastFrame;

  bool get directOutput => _direct;
  String get probeReason => _failure;
  NativeSurfaceFrame? get lastFrame => _lastFrame;

  void _attach() {
    // Complete immediately: there is no native surface until beginOpen, and
    // initializing a video controller while waiting for itself deadlocks mpv.
    player.platform?.isVideoControllerAttached = true;
    _view = _ImageSurfacePlatform(player);
    platform.complete(_view);
    notifier.value = _view;
    final ready = player.platform?.videoControllerCompleter;
    if (ready != null && !ready.isCompleted) ready.complete();
    _params = player.stream.videoParams.listen((params) {
      final serial = _openSerial;
      if (serial < 0 || params != player.state.videoParams) return;
      final rotated = params.rotate == 90 || params.rotate == 270;
      final width = (rotated ? params.dh : params.dw) ?? 0;
      final height = (rotated ? params.dw : params.dh) ?? 0;
      if (width <= 0 || height <= 0) return;
      unawaited(
        _resizeSurface(serial: serial, width: width, height: height).catchError(
          (Object _) {
            _failure = 'surface_resize_failed';
          },
        ),
      );
    });
    WidgetsBinding.instance.addObserver(this);
  }

  Future<void> _resizeSurface({
    required int serial,
    required int width,
    required int height,
  }) => _serialize(() async {
    if (_disposed || _suspended || serial != _openSerial || !_surfaceAttached) {
      return;
    }
    if (_width == width && _height == height) return;
    // MediaCodec sets the producer buffer size itself. A video-params event
    // must not tear down the active codec/Surface or synchronously block Dart
    // inside mpv. Update only layout/diagnostic metadata on the direct path.
    final resized = await _channel.invokeMethod<bool>('resize', {
      'owner': identityHashCode(this),
      'open_serial': serial,
      'epoch': _epoch,
      'width': width,
      'height': height,
      'resize_buffers': !_direct,
    });
    if (resized != true) throw PlatformException(code: 'surface_resize_failed');
    if (_disposed || _suspended || serial != _openSerial) return;
    _width = width;
    _height = height;
    _view.rect.value = rect.value = Rect.fromLTWH(
      0,
      0,
      width.toDouble(),
      height.toDouble(),
    );
    if (!_direct) {
      // Software/GPU output owns its viewport. Resize the existing buffer queue
      // in place, without changing vo/wid/vid or its ownership epoch.
      await _setProperty('android-surface-size', '${width}x$height');
    }
  });

  Future<void> _serialize(Future<void> Function() action) {
    final result = _tail.then((_) => action());
    // Keep the queue usable after an explicitly reported native failure.
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> beginOpen(int serial) => _serialize(() async {
    if (_disposed) return;
    await _waitForPlayer();
    _openSerial = serial;
    _width = 1;
    _height = 1;
    _lastFrame = null;
    _failure = 'awaiting_image';
    if (!_suspended) await _replaceSurface();
  });

  Future<void> useSoftwareOutput() => _serialize(() async {
    if (_disposed) return;
    _direct = false;
    _lastFrame = null;
    if (!_suspended) await _replaceSurface();
  });

  Future<void> _detach() async {
    if (!_surfaceAttached) return;
    // Finish detaching mpv before deleting the Surface global reference or
    // releasing its Flutter-owned SurfaceTexture and BufferQueue.
    await _setProperty('vid', 'no');
    await _setProperty('vo', 'null');
    await _setProperty('wid', '0');
    _surfaceAttached = false;
  }

  Future<void> _replaceSurface() async {
    await _detach();
    final epoch = ++_epoch;
    _lastFrame = null;
    final raw = await _channel.invokeMapMethod<Object?, Object?>('create', {
      'owner': identityHashCode(this),
      'open_serial': _openSerial,
      'epoch': epoch,
      'width': _width,
      'height': _height,
    });
    final texture = raw?['texture_id'];
    final wid = raw?['wid'];
    if (texture is! int || wid is! int || wid == 0) {
      _failure = 'surface_create_failed';
      throw PlatformException(code: 'surface_create_failed');
    }
    _view.id.value = id.value = texture;
    _view.rect.value = rect.value = Rect.fromLTWH(
      0,
      0,
      _width.toDouble(),
      _height.toDouble(),
    );
    try {
      await _setProperty('hwdec', _direct ? 'mediacodec' : 'no');
      await _setProperty('opengl-es', 'yes');
      await _setProperty('gpu-context', 'android');
      await _setProperty('force-window', 'yes');
      await _setProperty('android-surface-size', '${_width}x$_height');
      await _setProperty('wid', '$wid');
      _surfaceAttached = true;
      await _setProperty('vo', _direct ? 'mediacodec_embed' : 'gpu');
      await _setProperty('vid', 'auto');
    } catch (_) {
      _failure = 'surface_attach_failed';
      rethrow;
    }
  }

  Future<bool> readFrame({required int serial}) async {
    if (_disposed || _suspended || serial != _openSerial) return false;
    // A resize/open may be queued. Do not attribute an image from its previous
    // texture to a replacement surface, even if the asynchronous call finishes.
    final epoch = _epoch;
    final raw = await _channel.invokeMapMethod<Object?, Object?>('probe', {
      'owner': identityHashCode(this),
      'open_serial': serial,
      'epoch': epoch,
    });
    if (_disposed || serial != _openSerial || epoch != _epoch || raw == null) {
      return false;
    }
    final frame = NativeSurfaceFrame.fromMap(raw);
    if (!frame.belongsTo(serial: serial, surfaceEpoch: epoch)) return false;
    _lastFrame = frame;
    _failure = frame.reason;
    if (!frame.hasImage) return false;
    _view.confirmImage();
    return true;
  }

  @override
  Future<void> get waitUntilFirstFrameRendered =>
      _view.waitUntilFirstFrameRendered;

  @override
  Future<void> setSize({int? width, int? height}) async {
    // Output dimensions come from the decoder, not the screen's layout.
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      _suspended = true;
      unawaited(
        _serialize(() async {
          if (_disposed) return;
          await _detach();
          await _channel.invokeMethod<void>('dispose', {
            'owner': identityHashCode(this),
          });
          _lastFrame = null;
        }).catchError((Object _) {
          _failure = 'surface_suspend_failed';
        }),
      );
    } else if (state == AppLifecycleState.resumed) {
      _suspended = false;
      unawaited(
        _serialize(() async {
          if (_disposed || _openSerial < 0) return;
          await _replaceSurface();
          // Restoring output never changes user play/pause intent.
        }).catchError((Object _) {
          _failure = 'surface_resume_failed';
        }),
      );
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    await _params?.cancel();
    await _waitForPlayer();
    await _serialize(() async {
      await _detach();
      await _channel.invokeMethod<void>('dispose', {
        'owner': identityHashCode(this),
      });
      _view.dispose();
      id.dispose();
      rect.dispose();
      notifier.dispose();
    });
  }
}

final class _ImageSurfacePlatform extends PlatformVideoController {
  _ImageSurfacePlatform(Player player)
    : super(
        player,
        const VideoControllerConfiguration(
          vo: 'mediacodec_embed',
          hwdec: 'mediacodec',
        ),
      );

  void confirmImage() {
    if (!waitUntilFirstFrameRenderedCompleter.isCompleted) {
      waitUntilFirstFrameRenderedCompleter.complete();
    }
  }

  @override
  Future<void> setSize({int? width, int? height}) async {}
}
