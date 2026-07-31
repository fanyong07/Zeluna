import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'animeko_webview_sniffer_base.dart';

AnimekoWebViewSniffer createAnimekoWebViewSniffer() => Platform.isWindows
    ? _WindowsAnimekoWebViewSniffer.instance
    : _NativeAnimekoWebViewSniffer();

class _WindowsAnimekoWebViewSniffer implements AnimekoWebViewSniffer {
  _WindowsAnimekoWebViewSniffer._();

  static final instance = _WindowsAnimekoWebViewSniffer._();

  Future<void> _queue = Future<void>.value();
  Future<InAppWebViewController?>? _initialization;
  HeadlessInAppWebView? _webView;
  InAppWebViewController? _controller;
  _WindowsSniffSession? _activeSession;
  Completer<void>? _blankPageLoaded;

  @override
  bool get supported => Platform.isWindows;

  @override
  Future<AnimekoWebViewSniffResult?> sniff(AnimekoWebViewSniffRequest request) {
    final operation = _queue.then((_) => _sniffSerial(request));
    _queue = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }

  Future<AnimekoWebViewSniffResult?> _sniffSerial(
    AnimekoWebViewSniffRequest request,
  ) async {
    final controller = await _ensureController();
    if (controller == null) return null;

    final session = _WindowsSniffSession(request, controller);
    _activeSession = session;
    try {
      await session.seedCookies();
      session.startTimeout();
      await controller.loadUrl(
        urlRequest: URLRequest(
          url: WebUri(request.pageUrl.toString()),
          headers: request.headers,
        ),
      );
      return await session.result.future;
    } catch (_) {
      return null;
    } finally {
      session.cancel();
      if (identical(_activeSession, session)) _activeSession = null;
      await _resetToBlank(controller);
    }
  }

  Future<InAppWebViewController?> _ensureController() {
    final controller = _controller;
    if (_webView != null && controller != null) return Future.value(controller);
    return _initialization ??= _initializeController();
  }

  Future<InAppWebViewController?> _initializeController() async {
    final created = Completer<InAppWebViewController>();
    final webView = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri('about:blank')),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        mediaPlaybackRequiresUserGesture: false,
        useOnLoadResource: true,
        useShouldInterceptRequest: true,
        useShouldInterceptAjaxRequest: true,
        useShouldInterceptFetchRequest: true,
        isInspectable: kDebugMode,
      ),
      onWebViewCreated: (controller) {
        _controller = controller;
        if (!created.isCompleted) created.complete(controller);
      },
      onLoadStart: (_, url) => _activeSession?.inspect(url?.toString()),
      onLoadResource: (_, resource) =>
          _activeSession?.inspect(resource.url.toString()),
      onDownloadStartRequest: (_, download) =>
          _activeSession?.inspect(download.url.toString()),
      onUpdateVisitedHistory: (_, url, _) =>
          _activeSession?.inspect(url?.toString()),
      shouldOverrideUrlLoading: (_, action) async {
        _activeSession?.inspect(action.request.url?.toString());
        return NavigationActionPolicy.ALLOW;
      },
      shouldInterceptRequest: (_, resource) async {
        _activeSession?.inspect(resource.url.toString());
        return null;
      },
      shouldInterceptAjaxRequest: (_, ajax) async {
        _activeSession?.inspect(ajax.url?.toString());
        return ajax;
      },
      onAjaxReadyStateChange: (_, ajax) async {
        final session = _activeSession;
        if (session != null) {
          final responseUrl =
              ajax.responseURL?.toString() ?? ajax.url?.toString();
          session.inspect(responseUrl);
          session.inspectDynamic(ajax.responseText, baseUrl: responseUrl);
          session.inspectDynamic(ajax.response, baseUrl: responseUrl);
        }
        return AjaxRequestAction.PROCEED;
      },
      shouldInterceptFetchRequest: (_, fetch) async {
        _activeSession?.inspect(fetch.url?.toString());
        return fetch;
      },
      onLoadStop: (controller, url) async {
        if (url?.toString() == 'about:blank') {
          final blankPageLoaded = _blankPageLoaded;
          if (blankPageLoaded != null && !blankPageLoaded.isCompleted) {
            blankPageLoaded.complete();
          }
          return;
        }
        final session = _activeSession;
        if (session == null) return;
        session.inspect(url?.toString());
        try {
          final resources = await controller.evaluateJavascript(
            source: '''
              JSON.stringify([
                ...Array.from(document.querySelectorAll('video,source,iframe'))
                  .flatMap((node) => [node.src, node.currentSrc, node.getAttribute('src')]),
                ...performance.getEntriesByType('resource').map((entry) => entry.name)
              ].filter(Boolean));
            ''',
          );
          if (identical(session, _activeSession)) {
            session.inspectDynamic(resources, baseUrl: url?.toString());
          }
        } catch (_) {}
      },
    );
    _webView = webView;
    try {
      await webView.run();
      return await created.future.timeout(const Duration(seconds: 10));
    } catch (_) {
      _webView = null;
      _controller = null;
      _initialization = null;
      return null;
    }
  }

  Future<void> _resetToBlank(InAppWebViewController controller) async {
    final loaded = Completer<void>();
    _blankPageLoaded = loaded;
    var blankLoaded = false;
    try {
      try {
        await controller.stopLoading();
      } catch (_) {}
      await controller.loadUrl(
        urlRequest: URLRequest(url: WebUri('about:blank')),
      );
      await loaded.future.timeout(const Duration(seconds: 2));
      blankLoaded = true;
    } catch (_) {
      // Keep the controller alive when blank navigation cannot be confirmed;
      // destroying it with pending WebView2 callbacks can crash the process.
    } finally {
      if (identical(_blankPageLoaded, loaded)) _blankPageLoaded = null;
    }
    if (!blankLoaded) return;

    await Future<void>.delayed(const Duration(milliseconds: 500));
    final webView = _webView;
    if (webView == null || !identical(_controller, controller)) return;
    try {
      await webView.dispose();
    } catch (_) {
      return;
    }
    _webView = null;
    _controller = null;
    _initialization = null;
    // The vendored plugin performs the native erase on the next Win32 message.
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

class _WindowsSniffSession {
  _WindowsSniffSession(this.request, this.controller);

  final AnimekoWebViewSniffRequest request;
  final InAppWebViewController controller;
  final result = Completer<AnimekoWebViewSniffResult?>();
  Timer? timeoutTimer;
  Timer? nestedSettleTimer;
  String? nestedUrl;

  void startTimeout() {
    timeoutTimer = Timer(
      request.timeout,
      () => unawaited(finish(nested: nestedUrl)),
    );
  }

  Future<void> seedCookies() async {
    final cookieHeader = _headerValue(request.headers, 'cookie');
    if (cookieHeader.isEmpty) return;
    for (final pair in cookieHeader.split(';')) {
      final separator = pair.indexOf('=');
      if (separator <= 0) continue;
      final name = pair.substring(0, separator).trim();
      final value = pair.substring(separator + 1).trim();
      if (name.isEmpty) continue;
      await CookieManager.instance().setCookie(
        url: WebUri(request.pageUrl.toString()),
        name: name,
        value: value,
        webViewController: controller,
      );
    }
  }

  Future<String> readCookies() async {
    try {
      final cookies = await CookieManager.instance().getCookies(
        url: WebUri(request.pageUrl.toString()),
        webViewController: controller,
      );
      return cookies
          .map((cookie) => '${cookie.name}=${cookie.value}')
          .join('; ');
    } catch (_) {
      return '';
    }
  }

  Future<void> finish({String? videoUrl, String? nested}) async {
    if (result.isCompleted) return;
    nestedSettleTimer?.cancel();
    final cookieHeader = await readCookies();
    if (result.isCompleted) return;
    result.complete(
      AnimekoWebViewSniffResult(
        videoUrl: videoUrl,
        nestedUrl: nested,
        cookieHeader: cookieHeader,
      ),
    );
  }

  void inspect(String? value, {String? baseUrl}) {
    final candidate = value?.trim() ?? '';
    if (candidate.isEmpty || result.isCompleted) return;
    final base = baseUrl?.trim().isNotEmpty == true
        ? baseUrl!.trim()
        : request.pageUrl.toString();
    final video = request.matchVideo(candidate, base);
    if (video != null && video.trim().isNotEmpty) {
      unawaited(finish(videoUrl: video.trim()));
      return;
    }
    final nested = request.matchNested(candidate, base);
    if (nested == null || nested.trim().isEmpty) return;
    nestedUrl = nested.trim();
    nestedSettleTimer?.cancel();
    nestedSettleTimer = Timer(
      const Duration(seconds: 2),
      () => unawaited(finish(nested: nestedUrl)),
    );
  }

  void inspectDynamic(Object? value, {String? baseUrl}) {
    if (value == null) return;
    if (value is String) {
      inspect(value, baseUrl: baseUrl);
      return;
    }
    try {
      inspect(jsonEncode(value), baseUrl: baseUrl);
    } catch (_) {}
  }

  void cancel() {
    timeoutTimer?.cancel();
    nestedSettleTimer?.cancel();
  }
}

class _NativeAnimekoWebViewSniffer implements AnimekoWebViewSniffer {
  @override
  bool get supported => Platform.isAndroid;

  @override
  Future<AnimekoWebViewSniffResult?> sniff(
    AnimekoWebViewSniffRequest request,
  ) async {
    if (!supported) return null;

    final result = Completer<AnimekoWebViewSniffResult?>();
    HeadlessInAppWebView? webView;
    Timer? timeoutTimer;
    Timer? nestedSettleTimer;
    String? nestedUrl;

    Future<String> readCookies() async {
      try {
        final cookies = await CookieManager.instance().getCookies(
          url: WebUri(request.pageUrl.toString()),
          webViewController: webView?.webViewController,
        );
        return cookies
            .map((cookie) => '${cookie.name}=${cookie.value}')
            .join('; ');
      } catch (_) {
        return '';
      }
    }

    Future<void> finish({String? videoUrl, String? nested}) async {
      if (result.isCompleted) return;
      nestedSettleTimer?.cancel();
      final cookieHeader = await readCookies();
      if (!result.isCompleted) {
        result.complete(
          AnimekoWebViewSniffResult(
            videoUrl: videoUrl,
            nestedUrl: nested,
            cookieHeader: cookieHeader,
          ),
        );
      }
    }

    void inspect(String? value, {String? baseUrl}) {
      final candidate = value?.trim() ?? '';
      if (candidate.isEmpty || result.isCompleted) return;
      final base = baseUrl?.trim().isNotEmpty == true
          ? baseUrl!.trim()
          : request.pageUrl.toString();
      final video = request.matchVideo(candidate, base);
      if (video != null && video.trim().isNotEmpty) {
        unawaited(finish(videoUrl: video.trim()));
        return;
      }
      final nested = request.matchNested(candidate, base);
      if (nested == null || nested.trim().isEmpty) return;
      nestedUrl = nested.trim();
      nestedSettleTimer?.cancel();
      nestedSettleTimer = Timer(
        const Duration(seconds: 2),
        () => unawaited(finish(nested: nestedUrl)),
      );
    }

    void inspectDynamic(Object? value, {String? baseUrl}) {
      if (value == null) return;
      if (value is String) {
        inspect(value, baseUrl: baseUrl);
        return;
      }
      try {
        inspect(jsonEncode(value), baseUrl: baseUrl);
      } catch (_) {}
    }

    Future<void> seedCookies() async {
      final cookieHeader = _headerValue(request.headers, 'cookie');
      if (cookieHeader.isEmpty) return;
      for (final pair in cookieHeader.split(';')) {
        final separator = pair.indexOf('=');
        if (separator <= 0) continue;
        final name = pair.substring(0, separator).trim();
        final value = pair.substring(separator + 1).trim();
        if (name.isEmpty) continue;
        await CookieManager.instance().setCookie(
          url: WebUri(request.pageUrl.toString()),
          name: name,
          value: value,
          webViewController: webView?.webViewController,
        );
      }
    }

    try {
      webView = HeadlessInAppWebView(
        initialUrlRequest: URLRequest(url: WebUri('about:blank')),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          mediaPlaybackRequiresUserGesture: false,
          useOnLoadResource: true,
          useShouldInterceptRequest: true,
          useShouldInterceptAjaxRequest: true,
          useShouldInterceptFetchRequest: true,
          userAgent: _headerValue(request.headers, 'user-agent'),
          isInspectable: kDebugMode,
        ),
        onWebViewCreated: (controller) async {
          await seedCookies();
          if (result.isCompleted) return;
          await controller.loadUrl(
            urlRequest: URLRequest(
              url: WebUri(request.pageUrl.toString()),
              headers: request.headers,
            ),
          );
        },
        onLoadStart: (_, url) => inspect(url?.toString()),
        onLoadResource: (_, resource) => inspect(resource.url.toString()),
        onDownloadStartRequest: (_, download) =>
            inspect(download.url.toString()),
        onUpdateVisitedHistory: (_, url, _) => inspect(url?.toString()),
        shouldOverrideUrlLoading: (_, action) async {
          inspect(action.request.url?.toString());
          return NavigationActionPolicy.ALLOW;
        },
        shouldInterceptRequest: (_, resource) async {
          inspect(resource.url.toString());
          return null;
        },
        shouldInterceptAjaxRequest: (_, ajax) async {
          inspect(ajax.url?.toString());
          return ajax;
        },
        onAjaxReadyStateChange: (_, ajax) async {
          final responseUrl =
              ajax.responseURL?.toString() ?? ajax.url?.toString();
          inspect(responseUrl);
          inspectDynamic(ajax.responseText, baseUrl: responseUrl);
          inspectDynamic(ajax.response, baseUrl: responseUrl);
          return AjaxRequestAction.PROCEED;
        },
        shouldInterceptFetchRequest: (_, fetch) async {
          inspect(fetch.url?.toString());
          return fetch;
        },
        onLoadStop: (controller, url) async {
          inspect(url?.toString());
          try {
            final resources = await controller.evaluateJavascript(
              source: '''
              JSON.stringify([
                ...Array.from(document.querySelectorAll('video,source,iframe'))
                  .flatMap((node) => [node.src, node.currentSrc, node.getAttribute('src')]),
                ...performance.getEntriesByType('resource').map((entry) => entry.name)
              ].filter(Boolean));
            ''',
            );
            inspectDynamic(resources, baseUrl: url?.toString());
          } catch (_) {}
        },
      );
      timeoutTimer = Timer(
        request.timeout,
        () => unawaited(finish(nested: nestedUrl)),
      );
      await webView.run();
      return await result.future;
    } catch (_) {
      return null;
    } finally {
      timeoutTimer?.cancel();
      nestedSettleTimer?.cancel();
      try {
        await webView?.dispose();
      } catch (_) {}
    }
  }
}

String _headerValue(Map<String, String> headers, String name) {
  final normalized = name.toLowerCase();
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == normalized) return entry.value.trim();
  }
  return '';
}
