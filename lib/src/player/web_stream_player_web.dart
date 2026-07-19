import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

bool get supportsWebStreamPlayer => true;

bool shouldUseWebStreamPlayer(String url) => url.startsWith('http');

class WebStreamPlayerController {
  _WebStreamPlayerState? _state;

  void play() => _state?._playFromUserGesture();

  void pause() => _state?._pauseFromUserGesture();

  void seek(Duration position) => _state?._seekFromUserGesture(position);

  void _attach(_WebStreamPlayerState state) => _state = state;

  void _detach(_WebStreamPlayerState state) {
    if (identical(_state, state)) _state = null;
  }
}

class WebStreamPlayer extends StatefulWidget {
  const WebStreamPlayer({
    super.key,
    required this.url,
    required this.playing,
    required this.volume,
    required this.position,
    this.controller,
    this.forceHls = false,
    this.onReady,
    this.onError,
    this.onPosition,
    this.onDuration,
    this.onPlaying,
  });

  final String url;
  final bool playing;
  final double volume;
  final Duration position;
  final WebStreamPlayerController? controller;
  final bool forceHls;
  final VoidCallback? onReady;
  final VoidCallback? onError;
  final ValueChanged<Duration>? onPosition;
  final ValueChanged<Duration>? onDuration;
  final ValueChanged<bool>? onPlaying;

  @override
  State<WebStreamPlayer> createState() => _WebStreamPlayerState();
}

class _WebStreamPlayerState extends State<WebStreamPlayer> {
  static int _nextId = 0;
  static Completer<void>? _hlsScript;

  late final String _viewType;
  late final web.HTMLDivElement _host;
  late final web.HTMLVideoElement _video;
  late final web.HTMLButtonElement _nativePlayButton;
  JSObject? _hls;
  StreamSubscription<web.Event>? _canPlaySub;
  StreamSubscription<web.Event>? _timeSub;
  StreamSubscription<web.Event>? _errorSub;
  StreamSubscription<web.Event>? _playSub;
  StreamSubscription<web.Event>? _pauseSub;

  @override
  void initState() {
    super.initState();
    _viewType = 'anime-web-stream-${_nextId++}';
    widget.controller?._attach(this);
    _video = web.HTMLVideoElement()
      ..autoplay = false
      ..controls = false
      ..playsInline = true
      ..preload = 'auto';
    _video.volume = widget.volume.clamp(0, 1);
    _video
      ..removeAttribute('controls')
      ..setAttribute(
        'controlsList',
        'nodownload noplaybackrate noremoteplayback',
      )
      ..setAttribute('disablepictureinpicture', 'true')
      ..setAttribute('disableremoteplayback', 'true');
    _video.style
      ..width = '100%'
      ..height = '100%'
      ..backgroundColor = 'black'
      ..objectFit = 'contain'
      ..pointerEvents = 'none';
    _host = web.HTMLDivElement();
    _host.style
      ..position = 'relative'
      ..width = '100%'
      ..height = '100%'
      ..overflow = 'hidden'
      ..backgroundColor = 'black'
      ..pointerEvents = 'none';
    _nativePlayButton = web.HTMLButtonElement()
      ..type = 'button'
      ..textContent = '▶';
    _nativePlayButton
      ..setAttribute('aria-label', '播放视频')
      ..setAttribute('title', '播放视频')
      ..setAttribute(
        'onclick',
        'event.stopPropagation();'
            'this.previousElementSibling.play().catch(function(){});',
      );
    _nativePlayButton.style
      ..position = 'absolute'
      ..left = '50%'
      ..top = '50%'
      ..transform = 'translate(-50%, -50%)'
      ..width = '72px'
      ..height = '72px'
      ..border = '1px solid rgba(255,255,255,.7)'
      ..borderRadius = '50%'
      ..backgroundColor = 'rgba(0,0,0,.72)'
      ..color = 'white'
      ..fontSize = '30px'
      ..cursor = 'pointer'
      ..pointerEvents = 'auto'
      ..zIndex = '2';
    _host
      ..appendChild(_video)
      ..appendChild(_nativePlayButton);
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int _) {
      return _host;
    });
    _bindEvents();
    unawaited(_load(widget.url));
  }

  @override
  void didUpdateWidget(covariant WebStreamPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller?._detach(this);
      widget.controller?._attach(this);
    }
    if (oldWidget.url != widget.url) {
      unawaited(_load(widget.url));
      return;
    }
    _video.volume = widget.volume.clamp(0, 1);
    if (widget.playing != oldWidget.playing) {
      if (widget.playing) {
        unawaited(_playIfAllowed());
      } else {
        _video.pause();
      }
    }
    final desired = widget.position.inMilliseconds / 1000;
    if ((desired - _video.currentTime).abs() > 1.5) {
      _video.currentTime = desired;
    }
  }

  @override
  void dispose() {
    widget.controller?._detach(this);
    _canPlaySub?.cancel();
    _timeSub?.cancel();
    _errorSub?.cancel();
    _playSub?.cancel();
    _pauseSub?.cancel();
    _destroyHls();
    _video.pause();
    _video.removeAttribute('src');
    _video.load();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return HtmlElementView(viewType: _viewType);
  }

  void _bindEvents() {
    _canPlaySub = _video.onCanPlay.listen((_) {
      widget.onReady?.call();
      widget.onDuration?.call(
        Duration(milliseconds: (_video.duration * 1000).round()),
      );
      if (widget.playing) unawaited(_playIfAllowed());
    });
    _timeSub = _video.onTimeUpdate.listen((_) {
      widget.onPosition?.call(
        Duration(milliseconds: (_video.currentTime * 1000).round()),
      );
    });
    _errorSub = _video.onError.listen((_) {
      widget.onError?.call();
    });
    _playSub = _video.onPlay.listen((_) {
      _nativePlayButton.style.display = 'none';
      widget.onPlaying?.call(true);
    });
    _pauseSub = _video.onPause.listen((_) {
      _nativePlayButton.style.display = 'block';
      widget.onPlaying?.call(false);
    });
  }

  Future<void> _load(String url) async {
    _destroyHls();
    _video.pause();
    _video.removeAttribute('src');
    _video.load();

    final lower = url.toLowerCase();
    final playbackUrl = _mediaProxyUrl(url);
    final isHls =
        widget.forceHls || lower.contains('m3u8') || lower.contains('hls');
    if (isHls) {
      try {
        await _ensureHlsScript();
        if (_isHlsSupported()) {
          final hls = _newHls();
          _hls = hls;
          hls.callMethod('loadSource'.toJS, playbackUrl.toJS);
          hls.callMethod('attachMedia'.toJS, _video);
          return;
        }
      } catch (_) {
        // Fall back to native HLS below for Safari-like browsers.
      }
      final nativeHls = _video
          .canPlayType('application/vnd.apple.mpegurl')
          .isNotEmpty;
      if (!nativeHls) {
        widget.onError?.call();
        return;
      }
    }

    _video.src = playbackUrl;
    _video.load();
    if (widget.playing) await _playIfAllowed();
  }

  Future<void> _playIfAllowed() async {
    try {
      await _video.play().toDart;
    } catch (_) {
      // Browsers commonly reject autoplay with audio after the asynchronous
      // source lookup has consumed the original user gesture. That is not a
      // broken media URL: keep the video mounted and let the user press play.
      if (mounted) widget.onPlaying?.call(false);
    }
  }

  void _playFromUserGesture() {
    unawaited(_playIfAllowed());
  }

  void _pauseFromUserGesture() {
    _video.pause();
  }

  void _seekFromUserGesture(Duration position) {
    _video.currentTime = position.inMilliseconds / 1000;
  }

  Future<void> _ensureHlsScript() {
    final existing = _hlsScript;
    if (existing != null) return existing.future;
    final completer = Completer<void>();
    _hlsScript = completer;

    if (_hlsGlobalExists()) {
      completer.complete();
      return completer.future;
    }

    final script = web.HTMLScriptElement()
      ..src = 'https://cdn.jsdelivr.net/npm/hls.js@1.5.18/dist/hls.min.js'
      ..async = true;
    script.setAttribute('data-anime-hls', 'true');
    script.onLoad.first.then((_) {
      if (!completer.isCompleted) completer.complete();
    });
    script.onError.first.then((_) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('hls.js failed to load'));
      }
    });
    web.document.head?.appendChild(script);
    return completer.future;
  }

  bool _hlsGlobalExists() {
    final result = web.window.callMethod(
      'eval'.toJS,
      'typeof Hls !== "undefined"'.toJS,
    );
    return result == true.toJS;
  }

  bool _isHlsSupported() {
    final result = web.window.callMethod(
      'eval'.toJS,
      'typeof Hls !== "undefined" && Hls.isSupported()'.toJS,
    );
    return result == true.toJS;
  }

  JSObject _newHls() {
    return web.window.callMethod(
          'eval'.toJS,
          'new Hls({ enableWorker: true, lowLatencyMode: true })'.toJS,
        )
        as JSObject;
  }

  String _mediaProxyUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return url;
    final host = web.window.location.hostname.toLowerCase();
    final isLocalPreview =
        host == '127.0.0.1' || host == 'localhost' || host == '::1';
    if (!isLocalPreview) return url;
    if (uri.host.toLowerCase() == host &&
        uri.port.toString() == web.window.location.port) {
      return url;
    }
    return '/media-proxy?url=${Uri.encodeComponent(url)}';
  }

  void _destroyHls() {
    final hls = _hls;
    if (hls != null) {
      hls.callMethod('destroy'.toJS);
      _hls = null;
    }
  }
}
