import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui_web' as ui_web;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

import '../sources/proxy_session_headers.dart';

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
    this.rate = 1,
    this.headers = const {},
    this.controller,
    this.forceHls = false,
    this.onReady,
    this.onError,
    this.onPosition,
    this.onDuration,
    this.onPlaying,
    this.onEnded,
  });

  final String url;
  final bool playing;
  final double volume;
  final Duration position;
  final double rate;
  final Map<String, String> headers;
  final WebStreamPlayerController? controller;
  final bool forceHls;
  final VoidCallback? onReady;
  final VoidCallback? onError;
  final ValueChanged<Duration>? onPosition;
  final ValueChanged<Duration>? onDuration;
  final ValueChanged<bool>? onPlaying;
  final VoidCallback? onEnded;

  @override
  State<WebStreamPlayer> createState() => _WebStreamPlayerState();
}

class _WebStreamPlayerState extends State<WebStreamPlayer> {
  // Kept in web/vendor so the first HLS playback never waits on a third-party
  // CDN. web/index.html preloads the same version during application startup.
  static const _hlsScriptAsset = 'vendor/hls-1.5.18.min.js';
  static int _nextId = 0;
  static Completer<void>? _hlsScript;

  late final String _viewType;
  late final web.HTMLDivElement _host;
  late final web.HTMLVideoElement _video;
  late final web.HTMLButtonElement _nativePlayButton;
  JSObject? _hls;
  JSFunction? _hlsErrorHandler;
  var _loadSerial = 0;
  var _readySerial = -1;
  var _errorSerial = -1;
  var _videoErrorSerial = -1;
  Timer? _loadTimeout;
  StreamSubscription<web.Event>? _canPlaySub;
  StreamSubscription<web.Event>? _timeSub;
  StreamSubscription<web.Event>? _errorSub;
  StreamSubscription<web.Event>? _playSub;
  StreamSubscription<web.Event>? _pauseSub;
  StreamSubscription<web.Event>? _endedSub;

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
    _video.playbackRate = _safePlaybackRate(widget.rate);
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
    if (oldWidget.url != widget.url ||
        !mapEquals(oldWidget.headers, widget.headers) ||
        oldWidget.forceHls != widget.forceHls) {
      unawaited(_load(widget.url));
      return;
    }
    _video.volume = widget.volume.clamp(0, 1);
    if (oldWidget.rate != widget.rate) {
      _video.playbackRate = _safePlaybackRate(widget.rate);
    }
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
    _loadSerial++;
    _loadTimeout?.cancel();
    widget.controller?._detach(this);
    _canPlaySub?.cancel();
    _timeSub?.cancel();
    _errorSub?.cancel();
    _playSub?.cancel();
    _pauseSub?.cancel();
    _endedSub?.cancel();
    _destroyHls();
    _video.pause();
    _video.playbackRate = _safePlaybackRate(widget.rate);
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
      final serial = _loadSerial;
      if (_errorSerial == serial || _readySerial == serial) return;
      _loadTimeout?.cancel();
      _loadTimeout = null;
      _readySerial = serial;
      widget.onReady?.call();
      final duration = _video.duration;
      if (duration.isFinite && duration >= 0) {
        widget.onDuration?.call(
          Duration(milliseconds: (duration * 1000).round()),
        );
      }
      if (widget.playing) unawaited(_playIfAllowed());
    });
    _timeSub = _video.onTimeUpdate.listen((_) {
      if (_readySerial != _loadSerial) return;
      final position = _video.currentTime;
      if (position.isFinite && position >= 0) {
        widget.onPosition?.call(
          Duration(milliseconds: (position * 1000).round()),
        );
      }
    });
    _errorSub = _video.onError.listen((_) {
      final serial = _videoErrorSerial;
      if (serial >= 0) _reportLoadError(serial);
    });
    _playSub = _video.onPlay.listen((_) {
      _nativePlayButton.style.display = 'none';
      widget.onPlaying?.call(true);
    });
    _pauseSub = _video.onPause.listen((_) {
      _nativePlayButton.style.display = 'block';
      widget.onPlaying?.call(false);
    });
    _endedSub = _video.onEnded.listen((_) {
      if (_readySerial != _loadSerial || !_video.ended) return;
      widget.onEnded?.call();
    });
  }

  Future<void> _load(String url) async {
    final serial = ++_loadSerial;
    final headers = Map<String, String>.of(widget.headers);
    final forceHls = widget.forceHls;
    _readySerial = -1;
    _errorSerial = -1;
    _videoErrorSerial = -1;
    _loadTimeout?.cancel();
    _loadTimeout = Timer(
      // The page performs a seven-second soft fallback when another line is
      // available. Keep the mounted player alive long enough for a valid but
      // slow HLS source to download its first complete segment.
      const Duration(seconds: 27),
      () => _reportLoadError(serial),
    );
    _destroyHls();
    _video.pause();
    _video.removeAttribute('src');
    _video.load();

    final lower = url.toLowerCase();
    final usesProxy = _usesMediaProxy(url);
    final session = await _createProxySession(url, headers);
    if (!_isActiveLoad(serial)) return;
    if (usesProxy && headers.isNotEmpty && session == null) {
      _reportLoadError(serial);
      return;
    }
    final playbackUrl = _mediaProxyUrl(url, session);
    final isHls =
        forceHls ||
        RegExp(r'\.m3u8(?:$|[?#])').hasMatch(lower) ||
        lower.contains('type=m3u8') ||
        lower.contains('format=m3u8');
    if (isHls) {
      try {
        await _ensureHlsScript();
        if (!_isActiveLoad(serial)) return;
        if (_isHlsSupported()) {
          final hls = _newHls();
          if (!_isActiveLoad(serial)) {
            hls.callMethod('destroy'.toJS);
            return;
          }
          _hls = hls;
          _attachHlsErrorHandler(hls, serial);
          _videoErrorSerial = serial;
          hls.callMethod('loadSource'.toJS, playbackUrl.toJS);
          hls.callMethod('attachMedia'.toJS, _video);
          return;
        }
      } catch (_) {
        _destroyHls();
        // Fall back to native HLS below for Safari-like browsers.
      }
      final nativeHls = _video
          .canPlayType('application/vnd.apple.mpegurl')
          .isNotEmpty;
      if (!nativeHls) {
        _reportLoadError(serial);
        return;
      }
    }

    if (!_isActiveLoad(serial)) return;
    _videoErrorSerial = serial;
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
      ..src = _hlsScriptAsset
      ..async = true;
    script.setAttribute('data-anime-hls', 'true');
    final timeout = Timer(const Duration(seconds: 10), () {
      if (completer.isCompleted) return;
      if (identical(_hlsScript, completer)) _hlsScript = null;
      script.remove();
      completer.completeError(StateError('hls.js load timed out'));
    });
    script.onLoad.first.then((_) {
      if (!completer.isCompleted) {
        timeout.cancel();
        if (_hlsGlobalExists()) {
          completer.complete();
        } else {
          if (identical(_hlsScript, completer)) _hlsScript = null;
          script.remove();
          completer.completeError(StateError('hls.js did not initialize'));
        }
      }
    });
    script.onError.first.then((_) {
      if (!completer.isCompleted) {
        timeout.cancel();
        if (identical(_hlsScript, completer)) _hlsScript = null;
        script.remove();
        completer.completeError(StateError('hls.js failed to load'));
      }
    });
    web.document.head?.appendChild(script);
    return completer.future;
  }

  bool _hlsGlobalExists() {
    return _hlsConstructor() != null;
  }

  bool _isHlsSupported() {
    final constructor = _hlsConstructor();
    if (constructor == null) return false;
    final function = constructor.getProperty<JSAny?>('isSupported'.toJS);
    if (function == null || !function.isA<JSFunction>()) return false;
    final result = (function as JSFunction).callAsFunction(constructor);
    return result == true.toJS;
  }

  JSObject _newHls() {
    final constructor = _hlsConstructor();
    if (constructor == null) throw StateError('hls.js is unavailable');
    final options = JSObject()
      ..setProperty('enableWorker'.toJS, true.toJS)
      ..setProperty('lowLatencyMode'.toJS, true.toJS)
      // The local media proxy already streams upstream bytes. Let hls.js
      // transmux large TS fragments incrementally instead of waiting for the
      // complete response before it can append the first playable data.
      ..setProperty('progressive'.toJS, true.toJS)
      ..setProperty('capLevelToPlayerSize'.toJS, true.toJS);
    return constructor.callAsConstructor<JSObject>(options);
  }

  JSFunction? _hlsConstructor() {
    final value = web.window.getProperty<JSAny?>('Hls'.toJS);
    if (value == null || !value.isA<JSFunction>()) return null;
    return value as JSFunction;
  }

  JSAny? _hlsErrorEvent() {
    final constructor = _hlsConstructor();
    if (constructor == null) return null;
    final events = constructor.getProperty<JSAny?>('Events'.toJS);
    if (events == null || !events.isA<JSObject>()) return null;
    return (events as JSObject).getProperty<JSAny?>('ERROR'.toJS);
  }

  void _attachHlsErrorHandler(JSObject hls, int serial) {
    final callback = ((JSAny? _, JSAny? data) {
      if (!mounted ||
          serial != _loadSerial ||
          data == null ||
          !data.isA<JSObject>()) {
        return;
      }
      final fatal = (data as JSObject).getProperty<JSAny?>('fatal'.toJS);
      if (fatal == true.toJS) _reportLoadError(serial);
    }).toJS;
    _hlsErrorHandler = callback;
    final errorEvent = _hlsErrorEvent();
    if (errorEvent == null) {
      _hlsErrorHandler = null;
      throw StateError('hls.js error event is unavailable');
    }
    hls.callMethod('on'.toJS, errorEvent, callback);
  }

  Future<String?> _createProxySession(
    String url,
    Map<String, String> headers,
  ) async {
    if (headers.isEmpty || !_usesMediaProxy(url)) return null;
    try {
      final sessionHeaders = sanitizeProxySessionHeaders(headers);
      final response = await http
          .post(
            Uri.base.resolve('/media-proxy/session'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({'url': url, 'headers': sessionHeaders}),
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode < 200 || response.statusCode >= 300) return null;
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) return null;
      final token = decoded['token']?.toString().trim() ?? '';
      return token.isEmpty ? null : token;
    } catch (_) {
      return null;
    }
  }

  bool _usesMediaProxy(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !uri.hasScheme ||
        !uri.hasAuthority ||
        (uri.scheme.toLowerCase() != 'http' &&
            uri.scheme.toLowerCase() != 'https')) {
      return false;
    }
    final current = Uri.tryParse(web.window.location.href);
    return current == null ||
        uri.scheme.toLowerCase() != current.scheme.toLowerCase() ||
        uri.host.toLowerCase() != current.host.toLowerCase() ||
        uri.port != current.port;
  }

  String _mediaProxyUrl(String url, String? session) {
    if (!_usesMediaProxy(url)) return url;
    final query = <String, String>{'url': url};
    if (session != null) query['session'] = session;
    return Uri(path: '/media-proxy', queryParameters: query).toString();
  }

  bool _isActiveLoad(int serial) {
    return mounted && serial == _loadSerial && _errorSerial != serial;
  }

  void _reportLoadError(int serial) {
    if (!mounted || serial != _loadSerial || _errorSerial == serial) return;
    _errorSerial = serial;
    _loadTimeout?.cancel();
    _loadTimeout = null;
    _videoErrorSerial = -1;
    _destroyHls();
    widget.onError?.call();
  }

  void _destroyHls() {
    final hls = _hls;
    if (hls != null) {
      final errorHandler = _hlsErrorHandler;
      final errorEvent = _hlsErrorEvent();
      if (errorHandler != null && errorEvent != null) {
        try {
          hls.callMethod('off'.toJS, errorEvent, errorHandler);
        } catch (_) {
          // The player may already have torn down itself after a fatal error.
        }
      }
      try {
        hls.callMethod('destroy'.toJS);
      } catch (_) {
        // Keep disposal idempotent even if hls.js is partially initialized.
      }
      _hls = null;
    }
    _hlsErrorHandler = null;
  }
}

double _safePlaybackRate(double value) {
  if (!value.isFinite || value <= 0) return 1;
  return value.clamp(0.25, 4).toDouble();
}
