import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../playback_line_display.dart';
import '../local_media.dart';
import 'native_playback_gate_stub.dart'
    if (dart.library.io) 'native_playback_gate_io.dart';
import 'native_video_compatibility.dart';
import 'native_android_surface_controller.dart';
import 'media_transport_failure.dart';
import 'native_media_transport_stub.dart'
    if (dart.library.io) 'native_media_transport_io.dart';

/// Rejects shared media-kit stream events while a media open is being
/// replaced, and after a newer open has taken ownership of the player.
final class NativeMediaEventGuard {
  int? _openSerial;
  String? _mediaUri;
  var _ready = false;

  bool get isTransitioning => _openSerial != null && !_ready;

  void beginOpen({required int openSerial, required String mediaUri}) {
    _openSerial = openSerial;
    _mediaUri = mediaUri;
    _ready = false;
  }

  void finishOpen({required int openSerial}) {
    if (_openSerial == openSerial) _ready = true;
  }

  void invalidate() {
    _openSerial = null;
    _mediaUri = null;
    _ready = false;
  }

  bool isCurrent({
    required int currentOpenSerial,
    required String? playerMediaUri,
  }) {
    return _ready &&
        _openSerial == currentOpenSerial &&
        _mediaUri != null &&
        _mediaUri == playerMediaUri;
  }

  NativePlaybackStartupSnapshot readStartupSnapshot({
    required int currentOpenSerial,
    required PlayerState playerState,
    required bool hasAlternative,
    bool decodedFrame = false,
  }) {
    final playlist = playerState.playlist;
    final index = playlist.index;
    final uri = index >= 0 && index < playlist.medias.length
        ? playlist.medias[index].uri
        : null;
    final current = isCurrent(
      currentOpenSerial: currentOpenSerial,
      playerMediaUri: uri,
    );
    // Startup stream events may precede the playlist identity and be rejected.
    // Sample the authoritative backend, not the UI values those events missed.
    // Unknown ownership is still initializing, not evidence of a dead stream;
    // the hard deadline remains active, and old media progress never leaks in.
    return NativePlaybackStartupSnapshot(
      playing: current && playerState.playing,
      position: current ? playerState.position : Duration.zero,
      buffer: current ? playerState.buffer : Duration.zero,
      buffering: !current || playerState.buffering,
      hasAlternative: hasAlternative,
      decodedFrame: current && decodedFrame,
    );
  }

  bool acceptsValue<T>({
    required int currentOpenSerial,
    required String? playerMediaUri,
    required T eventValue,
    required T playerStateValue,
  }) {
    return isCurrent(
          currentOpenSerial: currentOpenSerial,
          playerMediaUri: playerMediaUri,
        ) &&
        eventValue == playerStateValue;
  }
}

/// Owns delayed native resume seeks and rejects work from stale media opens.
final class NativeResumeSeekController {
  NativeResumeSeekController({
    required int Function() readOpenSerial,
    required Future<void> Function(Duration) seek,
    Duration initialDelay = const Duration(milliseconds: 250),
    Duration retryDelay = const Duration(seconds: 2),
    Duration seekTimeout = const Duration(seconds: 10),
    int maxAttempts = 15,
  }) : _readOpenSerial = readOpenSerial,
       _seek = seek,
       _initialDelay = initialDelay,
       _retryDelay = retryDelay,
       _seekTimeout = seekTimeout,
       _maxAttempts = maxAttempts;

  final int Function() _readOpenSerial;
  final Future<void> Function(Duration) _seek;
  final Duration _initialDelay;
  final Duration _retryDelay;
  final Duration _seekTimeout;
  final int _maxAttempts;

  Timer? _timer;
  Timer? _seekDeadlineTimer;
  bool _seekTimedOut = false;
  Duration? _target;
  int? _openSerial;
  int _attempts = 0;
  int _generation = 0;
  bool _seeking = false;
  bool _disposed = false;

  Timer? get timer => _timer;
  Duration? get target => _target;
  int get attempts => _attempts;
  bool get isPending => _target != null;
  // An exhausted target is kept for the next line, but must not prevent the
  // stalled player from recovering forever after all retries have stopped.
  bool get blocksStallRecovery =>
      isPending && !_seekTimedOut && (_attempts < _maxAttempts || _seeking);
  bool get isSeeking => _seeking;
  bool get isDisposed => _disposed;

  Duration recoveryPosition(Duration current) {
    final target = _target;
    final position = target != null && target > current ? target : current;
    return playbackRecoveryPosition(position);
  }

  void arm({required int openSerial, required Duration position}) {
    if (_disposed) return;
    cancel();
    _target = position;
    _openSerial = openSerial;
    _schedule(_initialDelay);
  }

  void nudge({bool mediaReady = false}) {
    if (_disposed || _seekTimedOut || _openSerial != _readOpenSerial()) return;
    if (mediaReady) {
      _timer?.cancel();
      _timer = null;
      if (_attempts >= _maxAttempts) _attempts = 0;
    }
    _schedule(Duration.zero);
  }

  void handleProgress(Duration value) {
    final target = _target;
    if (_disposed || target == null || _openSerial != _readOpenSerial()) {
      return;
    }
    if (value >= target - const Duration(seconds: 2)) {
      cancel();
      return;
    }
    if (value > Duration.zero) nudge();
  }

  void cancel() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _seekDeadlineTimer?.cancel();
    _seekDeadlineTimer = null;
    _seekTimedOut = false;
    _target = null;
    _openSerial = null;
    _attempts = 0;
    _seeking = false;
  }

  void _schedule(Duration delay) {
    if (_disposed ||
        _target == null ||
        _seekTimedOut ||
        _seeking ||
        _attempts >= _maxAttempts ||
        _timer != null) {
      return;
    }
    _timer = Timer(delay, () {
      _timer = null;
      if (!_disposed) unawaited(_apply());
    });
  }

  Future<void> _apply() async {
    final generation = _generation;
    final position = _target;
    final serial = _openSerial;
    if (_disposed ||
        position == null ||
        serial == null ||
        serial != _readOpenSerial() ||
        _seeking ||
        _attempts >= _maxAttempts) {
      return;
    }
    _seeking = true;
    _attempts++;
    _seekDeadlineTimer = Timer(_seekTimeout, () {
      _seekDeadlineTimer = null;
      if (_disposed || generation != _generation) return;
      // Native commands can hang without completing or throwing. Stop waiting
      // and release recovery, but do not enqueue more seeks on the same open.
      // The native future is not cancellable; invalidate its late completion.
      _generation++;
      _seekTimedOut = true;
      _seeking = false;
    });
    try {
      await _seek(position);
    } catch (_) {
      // Some demuxers reject seeking until duration or the first frame exists.
    } finally {
      if (generation == _generation) {
        _seekDeadlineTimer?.cancel();
        _seekDeadlineTimer = null;
        _seeking = false;
      }
    }
    if (!_disposed &&
        generation == _generation &&
        serial == _readOpenSerial() &&
        _target != null) {
      _schedule(_retryDelay);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    cancel();
  }
}

enum NativeStartupTimeoutPhase { soft, hard }

final class NativePlaybackStartupSnapshot {
  const NativePlaybackStartupSnapshot({
    required this.playing,
    required this.position,
    required this.buffer,
    required this.buffering,
    required this.hasAlternative,
    this.decodedFrame = false,
  });

  final bool decodedFrame;
  final bool playing;
  final Duration position;
  final Duration buffer;
  final bool buffering;
  final bool hasAlternative;
}

final class NativeStartupTimeoutEvent {
  const NativeStartupTimeoutEvent({
    required this.phase,
    required this.hasAlternative,
  });

  final NativeStartupTimeoutPhase phase;
  final bool hasAlternative;
}

/// Owns native first-frame timeout polling independently from page state.
final class NativeFirstFrameWatchdog {
  Timer? _timer;
  Timer? _hardDeadline;
  var _generation = 0;
  var _disposed = false;

  bool get isActive => _timer != null || _hardDeadline != null;
  bool get isDisposed => _disposed;

  void start({
    required bool Function() isCurrent,
    required NativePlaybackStartupSnapshot Function() readSnapshot,
    required void Function(NativeStartupTimeoutEvent event) onTimeout,
    void Function(NativePlaybackStartupSnapshot snapshot)? onFirstFrame,
    Duration softTimeout = const Duration(seconds: 7),
    Duration hardTimeout = const Duration(seconds: 25),
    Duration pollInterval = const Duration(seconds: 1),
  }) {
    cancel();
    if (_disposed) return;
    assert(softTimeout > Duration.zero);
    assert(hardTimeout >= softTimeout);
    assert(pollInterval > Duration.zero);
    final generation = _generation;

    void check({required bool hardTimedOut}) {
      if (_disposed || generation != _generation) return;
      if (!isCurrent()) {
        cancel();
        return;
      }
      final snapshot = readSnapshot();
      if (nativePlaybackHasFirstFrame(
        playing: snapshot.playing,
        position: snapshot.position,
        decodedVideo: snapshot.decodedFrame,
      )) {
        // Early stream events can be rejected before media ownership is
        // known. A sampled first frame must complete the same UI lifecycle.
        cancel();
        onFirstFrame?.call(snapshot);
        return;
      }
      if (!hardTimedOut &&
          !nativePlaybackShouldSwitchAtSoftTimeout(
            position: snapshot.position,
            buffer: snapshot.buffer,
            buffering: snapshot.buffering,
            hasAlternative: snapshot.hasAlternative,
          )) {
        _timer = Timer(pollInterval, () => check(hardTimedOut: false));
        return;
      }
      cancel();
      onTimeout(
        NativeStartupTimeoutEvent(
          phase: hardTimedOut
              ? NativeStartupTimeoutPhase.hard
              : NativeStartupTimeoutPhase.soft,
          hasAlternative: snapshot.hasAlternative,
        ),
      );
    }

    // A busy UI isolate can delay polls. A deadline scheduled once at startup
    // must remain due even when relative poll callbacks are running late.
    _hardDeadline = Timer(hardTimeout, () => check(hardTimedOut: true));
    _timer = Timer(softTimeout, () => check(hardTimedOut: false));
  }

  bool handleProgress({
    required Duration previousPosition,
    required Duration currentPosition,
    bool decodedFrame = false,
  }) {
    if (!decodedFrame ||
        _disposed ||
        !isActive ||
        !nativePlaybackReachedFirstFrame(
          previousPosition: previousPosition,
          currentPosition: currentPosition,
          decodedVideo: decodedFrame,
        )) {
      return false;
    }
    cancel();
    return true;
  }

  void cancel() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _hardDeadline?.cancel();
    _hardDeadline = null;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    cancel();
  }
}

/// A native decoded-image probe is video evidence; timestamps and dimensions
/// alone can describe audio-only progress or an undecodable video track.
/// Pixels stay in the native worker; only a boolean returns to the UI isolate.
final class NativeDecodedFrameMonitor {
  Timer? _timer;
  int _generation = 0;
  bool _disposed = false;
  bool _reading = false;

  void start({
    required bool Function() isCurrent,
    required bool Function() canRead,
    required Future<bool> Function() readFrame,
    required void Function() onFrame,
    void Function(String reason)? onProbe,
    Duration interval = const Duration(milliseconds: 400),
    Duration readTimeout = const Duration(seconds: 2),
  }) {
    cancel();
    if (_disposed) return;
    final generation = _generation;
    _timer = Timer.periodic(interval, (_) async {
      if (_disposed || generation != _generation || !isCurrent()) {
        if (generation == _generation) cancel();
        return;
      }
      if (_reading || !canRead()) return;
      _reading = true;
      try {
        // Bound observation without extending the independent startup deadline.
        // This does not cancel native work or release the shared native mutex.
        final decoded = await readFrame().timeout(readTimeout);
        if (!_disposed && generation == _generation && isCurrent()) {
          onProbe?.call(decoded ? 'frame_available' : 'no_image');
          if (decoded) {
            cancel();
            onFrame();
          }
        }
      } on TimeoutException {
        if (!_disposed && generation == _generation && isCurrent()) {
          // timeout does not cancel the native command/worker. Repeating it
          // would queue more work behind media-kit's shared lock (and disposal).
          // Retire this generation only; its independent startup watchdog still
          // owns the hard deadline. Retire before callbacks can start a new open.
          cancel();
          onProbe?.call('probe_timeout');
        }
      } catch (_) {
        if (!_disposed && generation == _generation && isCurrent()) {
          onProbe?.call('probe_failed');
        }
      } finally {
        // A stale completion must not unlock a newer in-flight probe.
        if (generation == _generation) _reading = false;
      }
    });
  }

  void cancel() {
    _generation++;
    _reading = false;
    _timer?.cancel();
    _timer = null;
  }

  void dispose() {
    _disposed = true;
    cancel();
  }
}

/// Immutable input to one native open. A media URL never travels without its
/// request headers and trust requirements.
final class NativePlaybackRequest {
  NativePlaybackRequest({
    required this.url,
    required Map<String, String> headers,
    required this.format,
    required this.publicHttpOnly,
    this.resumePosition = Duration.zero,
  }) : headers = Map.unmodifiable(headers);
  final String url;
  final Map<String, String> headers;
  final String format;
  final bool publicHttpOnly;
  final Duration resumePosition;
}

/// Optional wire-preparation seam for tests with a recording native engine.
typedef NativeMediaPreparer =
    Future<Media> Function(
      String resource, {
      required Map<String, String> headers,
      String format,
      bool publicHttpOnly,
      void Function(MediaTransportFailure)? onFailure,
    });

/// Owns the native media-kit objects and every subscription/timer tied to
/// their lifetime. UI code may subscribe through [track], but it never disposes
/// individual native resources itself.
final class NativeVideoController {
  NativeVideoController({int Function()? readOpenSerial}) : player = Player() {
    surfaceController = NativeVideoCompatibility.instance.usesDirectSurface
        ? NativeAndroidSurfaceController(player: player)
        : VideoController(
            player,
            configuration: NativeVideoCompatibility.instance.configuration,
          );
    resumeSeek = NativeResumeSeekController(
      readOpenSerial: readOpenSerial ?? () => 0,
      seek: player.seek,
    );
  }

  /// Keeps real subscription/watchdog ownership while replacing only the engine
  /// and video surface in page tests. Disposal owns [player], as in production.
  @visibleForTesting
  NativeVideoController.forTesting({
    required this.player,
    required this.surfaceController,
    required int Function() readOpenSerial,
    Future<bool> Function()? readDecodedFrame,
    NativeMediaPreparer? prepareMedia,
  }) : _readDecodedFrame = readDecodedFrame,
       _prepareMediaForTesting = prepareMedia {
    assert(identical(surfaceController.player, player));
    resumeSeek = NativeResumeSeekController(
      readOpenSerial: readOpenSerial,
      seek: player.seek,
    );
  }

  final Player player;
  void Function(MediaTransportFailure)? onTransportFailure;
  final NativeMediaEventGuard events = NativeMediaEventGuard();
  bool _softwareDecodeTried = false;
  Future<bool> Function()? _readDecodedFrame;
  final NativeDecodedFrameMonitor _decodedFrames = NativeDecodedFrameMonitor();
  bool _decodedFrame = false;
  bool get hasDecodedFrame => _decodedFrame;
  final NativeMediaTransport _mediaTransport = NativeMediaTransport();
  NativeMediaPreparer? _prepareMediaForTesting;
  int _activeSerial = -1;
  String _probeReason = 'not_sampled';
  int _probeCount = 0;
  String? _lastProbeSignature;

  /// Only fixed reason codes, codec allowlist and dimensions. No URI, headers,
  /// track title, raw exception or pixel data enters this local diagnostic.
  Map<String, Object?> get frameDiagnostics {
    final state = player.state;
    final codec = state.track.video.codec?.toLowerCase();
    const codecs = {'h264', 'hevc', 'vp8', 'vp9', 'av1', 'mpeg4', 'mpeg2video'};
    final surface = surfaceController;
    final image = surface is NativeAndroidSurfaceController
        ? surface.lastFrame
        : null;
    return {
      'video_output': surface is NativeAndroidSurfaceController
          ? (surface.directOutput ? 'mediacodec_embed' : 'gpu_software')
          : 'gpu',
      'video_codec': codec == null
          ? 'unknown'
          : (codecs.contains(codec) ? codec : 'other'),
      'video_width': state.videoParams.w ?? 0,
      'video_height': state.videoParams.h ?? 0,
      'surface_width': image?.width ?? 0,
      'surface_height': image?.height ?? 0,
      'surface_frames': image?.frames ?? 0,
      'frame_probe': _probeReason,
      'frame_probe_count': _probeCount,
      'decoded_video': _decodedFrame,
    };
  }

  void _recordFrameProbe(String reason) {
    _probeReason = reason;
    _probeCount++;
    final fields = frameDiagnostics;
    final signature =
        '${fields['video_codec']}:${fields['video_width']}:'
        '${fields['video_height']}:$reason';
    if (signature == _lastProbeSignature) return;
    _lastProbeSignature = signature;
    debugPrint('native_frame_probe ${jsonEncode(fields)}');
  }

  Future<bool> _probeFrame() async {
    final serial = _activeSerial;
    final surface = surfaceController;
    if (surface is NativeAndroidSurfaceController) {
      final found = await surface.readFrame(serial: serial);
      if (_disposed || serial != _activeSerial) return false;
      _recordFrameProbe(surface.probeReason);
      return found;
    }
    final native = player.platform;
    if (native is! NativePlayer) return false;
    // Validate a real decoded screenshot node in its worker, returning only a
    // boolean. No JPEG encoding or full-frame pixel copy into the UI isolate.
    final found = await native.hasDecodedVideoFrame();
    if (_disposed || serial != _activeSerial) return false;
    _recordFrameProbe(found ? 'decoded_image' : 'no_image');
    return found;
  }

  Future<Media> prepareMedia(
    String resource, {
    required Map<String, String> headers,
    String format = '',
    bool publicHttpOnly = false,
    void Function(MediaTransportFailure)? onFailure,
  }) => (_prepareMediaForTesting ?? _mediaTransport.prepare)(
    resource,
    headers: headers,
    format: format,
    publicHttpOnly: publicHttpOnly,
    onFailure: onFailure,
  );

  /// The page requests an open; transport, ownership, play permission and
  /// resume seek form one operation here rather than independent UI futures.
  Future<bool> openRequest(
    NativePlaybackRequest request, {
    required int serial,
    required bool Function() isCurrent,
    required bool Function() canPlay,
    required void Function() onDispatched,
  }) async {
    if (_disposed || !isCurrent()) return false;
    final resource = nativeMediaPlaybackResource(
      request.url,
      windows: !kIsWeb && defaultTargetPlatform == TargetPlatform.windows,
    );
    final media = await prepareMedia(
      resource,
      headers: request.headers,
      format: request.format,
      publicHttpOnly: request.publicHttpOnly,
      onFailure: (failure) {
        if (!_disposed && isCurrent()) onTransportFailure?.call(failure);
      },
    );
    if (_disposed || !isCurrent()) return false;
    events.beginOpen(openSerial: serial, mediaUri: media.uri);
    _activeSerial = serial;
    _probeCount = 0;
    _probeReason = 'awaiting_image';
    _lastProbeSignature = null;
    final surface = surfaceController;
    if (surface is NativeAndroidSurfaceController) {
      // A previous media may still be draining. Stop it before allocating the
      // new texture, so its last image cannot confirm the replacement open.
      await player.stop();
      if (_disposed || !isCurrent()) return false;
      await surface.beginOpen(serial);
      if (_disposed || !isCurrent()) return false;
    }
    onDispatched();
    await player.open(media, play: false);
    if (_disposed || !isCurrent() || !canPlay()) return false;
    await playNativeIfCurrent(
      player,
      isCurrent: () => !_disposed && isCurrent() && canPlay(),
    );
    if (_disposed || !isCurrent() || !canPlay()) return false;
    events.finishOpen(openSerial: serial);
    if (request.resumePosition > Duration.zero) {
      resumeSeek.arm(openSerial: serial, position: request.resumePosition);
    }
    return true;
  }

  /// Only decoded-video failure warrants changing the decoder. A missing URL,
  /// DNS failure or inaccessible CDN is not fixed by software decoding.
  Future<bool> trySoftwareDecoding({required int serial}) async {
    final playlist = player.state.playlist;
    final index = playlist.index;
    final uri = index >= 0 && index < playlist.medias.length
        ? playlist.medias[index].uri
        : null;
    if (!events.isCurrent(currentOpenSerial: serial, playerMediaUri: uri)) {
      return false;
    }
    if (_disposed ||
        _softwareDecodeTried ||
        _decodedFrame ||
        player.state.position <= Duration.zero ||
        player.platform is! NativePlayer) {
      return false;
    }
    _softwareDecodeTried = true;
    try {
      final surface = surfaceController;
      if (surface is NativeAndroidSurfaceController) {
        // Preserve a real software fallback instead of repeatedly reopening
        // a direct MediaCodec-only output with an incompatible decoder.
        await surface.useSoftwareOutput();
      } else {
        final native = player.platform as dynamic;
        await native.setProperty('hwdec', 'no');
      }
      return !_disposed;
    } catch (_) {
      return false;
    }
  }

  late final VideoController surfaceController;
  late final NativeResumeSeekController resumeSeek;
  final NativeFirstFrameWatchdog _firstFrameWatchdog =
      NativeFirstFrameWatchdog();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  bool _disposed = false;

  bool get isDisposed => _disposed;
  bool get awaitingFirstFrame => _firstFrameWatchdog.isActive;

  void track(StreamSubscription<dynamic> subscription) {
    if (_disposed) {
      unawaited(subscription.cancel());
      return;
    }
    _subscriptions.add(subscription);
  }

  void startFirstFrameWatchdog({
    required bool Function() isCurrent,
    required NativePlaybackStartupSnapshot Function() readSnapshot,
    required void Function(NativeStartupTimeoutEvent event) onTimeout,
    required void Function(NativePlaybackStartupSnapshot snapshot) onFirstFrame,
  }) {
    if (_disposed) return;
    _decodedFrame = false;
    _decodedFrames.start(
      isCurrent: isCurrent,
      canRead: () =>
          _activeSerial >= 0 && readSnapshot().position > Duration.zero,
      readFrame: _readDecodedFrame ?? _probeFrame,
      onProbe: (reason) {
        if (reason == 'probe_failed' || reason == 'probe_timeout') {
          _recordFrameProbe(reason);
        }
      },
      onFrame: () {
        _decodedFrame = true;
        _firstFrameWatchdog.cancel();
        onFirstFrame(readSnapshot());
      },
    );
    _firstFrameWatchdog.start(
      isCurrent: isCurrent,
      readSnapshot: readSnapshot,
      onTimeout: (event) {
        _decodedFrames.cancel();
        onTimeout(event);
      },
      onFirstFrame: onFirstFrame,
    );
  }

  bool handlePlaybackProgress({
    required Duration previousPosition,
    required Duration currentPosition,
  }) {
    return _firstFrameWatchdog.handleProgress(
      previousPosition: previousPosition,
      currentPosition: currentPosition,
      decodedFrame: _decodedFrame,
    );
  }

  void cancelFirstFrameWatchdog() {
    _decodedFrames.cancel();
    _firstFrameWatchdog.cancel();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _firstFrameWatchdog.dispose();
    _decodedFrames.dispose();
    resumeSeek.dispose();
    final subscriptions = List.of(_subscriptions);
    _subscriptions.clear();
    await Future.wait(subscriptions.map((item) => item.cancel()));
    await _mediaTransport.dispose();
    final surface = surfaceController;
    if (surface is NativeAndroidSurfaceController) await surface.dispose();
    await player.dispose();
  }
}
