import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

bool get supportsWebStreamPlayer => true;

bool shouldUseWebStreamPlayer(String url) => url.startsWith('http');

class WebStreamPlayer extends StatefulWidget {
  const WebStreamPlayer({
    super.key,
    required this.url,
    this.forceHls = false,
    this.onReady,
    this.onError,
    this.onPosition,
  });

  final String url;
  final bool forceHls;
  final VoidCallback? onReady;
  final VoidCallback? onError;
  final ValueChanged<Duration>? onPosition;

  @override
  State<WebStreamPlayer> createState() => _WebStreamPlayerState();
}

class _WebStreamPlayerState extends State<WebStreamPlayer> {
  static int _nextId = 0;
  static Completer<void>? _hlsScript;

  late final String _viewType;
  late final web.HTMLVideoElement _video;
  JSObject? _hls;
  StreamSubscription<web.Event>? _canPlaySub;
  StreamSubscription<web.Event>? _timeSub;
  StreamSubscription<web.Event>? _errorSub;

  @override
  void initState() {
    super.initState();
    _viewType = 'anime-web-stream-${_nextId++}';
    _video = web.HTMLVideoElement()
      ..autoplay = true
      ..controls = false
      ..playsInline = true
      ..preload = 'auto';
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
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int _) {
      return _video;
    });
    _bindEvents();
    unawaited(_load(widget.url));
  }

  @override
  void didUpdateWidget(covariant WebStreamPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      unawaited(_load(widget.url));
    }
  }

  @override
  void dispose() {
    _canPlaySub?.cancel();
    _timeSub?.cancel();
    _errorSub?.cancel();
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
      unawaited(_video.play().toDart);
    });
    _timeSub = _video.onTimeUpdate.listen((_) {
      widget.onPosition?.call(
        Duration(milliseconds: (_video.currentTime * 1000).round()),
      );
    });
    _errorSub = _video.onError.listen((_) {
      widget.onError?.call();
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
    try {
      await _video.play().toDart;
    } catch (_) {
      widget.onError?.call();
    }
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
