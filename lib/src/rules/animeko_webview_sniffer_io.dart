import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'animeko_webview_sniffer_base.dart';
import 'rule_security.dart';

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
    if (!request.manifest.webViewSniffing) return Future.value(null);
    final operation = _queue.then((_) => _sniffSerial(request));
    _queue = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }

  Future<AnimekoWebViewSniffResult?> _sniffSerial(
    AnimekoWebViewSniffRequest request,
  ) async {
    final controller = await _ensureController(request);
    if (controller == null) return null;

    final session = _WindowsSniffSession(request, controller);
    _activeSession = session;
    try {
      if (!await session.network.allows(
        request.pageUrl.toString(),
        RuleUrlPurpose.page,
      )) {
        return null;
      }
      await clearAnimekoWebViewTaskStorage(controller);
      await session.seedCookies();
      session.startTimeout();
      await controller.loadUrl(
        urlRequest: URLRequest(
          url: WebUri(request.pageUrl.toString()),
          headers: filterRuleRequestHeaders(request.headers, request.manifest),
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

  Future<InAppWebViewController?> _ensureController(
    AnimekoWebViewSniffRequest request,
  ) {
    final controller = _controller;
    if (_webView != null && controller != null) return Future.value(controller);
    return _initialization ??= _initializeController(request);
  }

  Future<InAppWebViewController?> _initializeController(
    AnimekoWebViewSniffRequest request,
  ) async {
    final created = Completer<InAppWebViewController>();
    final webView = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri('about:blank')),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: request.manifest.javascript,
        javaScriptCanOpenWindowsAutomatically: false,
        supportMultipleWindows: false,
        allowContentAccess: false,
        allowFileAccess: false,
        allowFileAccessFromFileURLs: false,
        allowUniversalAccessFromFileURLs: false,
        geolocationEnabled: false,
        useOnDownloadStart: true,
        thirdPartyCookiesEnabled: false,
        saveFormData: false,
        incognito: true,
        cacheEnabled: false,
        clearSessionCache: true,
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
      onDownloadStartRequest: (_, _) {},
      onCreateWindow: (_, _) async => false,
      onPermissionRequest: (_, request) async => PermissionResponse(
        resources: request.resources,
        action: PermissionResponseAction.DENY,
      ),
      onUpdateVisitedHistory: (_, url, _) =>
          _activeSession?.inspect(url?.toString()),
      shouldOverrideUrlLoading: (_, action) async {
        final session = _activeSession;
        if (session == null) return NavigationActionPolicy.CANCEL;
        final url = action.request.url?.toString();
        if (!await session.network.allows(url, RuleUrlPurpose.page)) {
          return NavigationActionPolicy.CANCEL;
        }
        session.inspect(url);
        return NavigationActionPolicy.ALLOW;
      },
      shouldInterceptRequest: (_, resource) async {
        final session = _activeSession;
        if (session == null ||
            !await session.network.allowsResource(resource.url.toString())) {
          return _blockedWebResourceResponse();
        }
        session.inspect(resource.url.toString());
        return null;
      },
      shouldInterceptAjaxRequest: (_, ajax) async {
        final session = _activeSession;
        if (session == null ||
            !await session.network.allowsResource(ajax.url?.toString())) {
          ajax.action = AjaxRequestAction.ABORT;
          return ajax;
        }
        session.inspect(ajax.url?.toString());
        ajax.action = AjaxRequestAction.PROCEED;
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
        final session = _activeSession;
        if (session == null ||
            !await session.network.allowsResource(fetch.url?.toString())) {
          fetch.action = FetchRequestAction.ABORT;
          return fetch;
        }
        session.inspect(fetch.url?.toString());
        fetch.action = FetchRequestAction.PROCEED;
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
    await clearAnimekoWebViewTaskStorage(controller);
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
  _WindowsSniffSession(this.request, this.controller)
    : network = _SniffNetworkPolicy(request);

  final AnimekoWebViewSniffRequest request;
  final InAppWebViewController controller;
  final _SniffNetworkPolicy network;
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
    final cookieHeader = _headerValue(
      filterRuleRequestHeaders(request.headers, request.manifest),
      'cookie',
    );
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
    if (request.manifest.cookiePolicy != RuleCookiePolicy.taskScoped) {
      return '';
    }
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
    if (video != null &&
        video.trim().isNotEmpty &&
        network.allowsDeclared(video.trim(), RuleUrlPurpose.media)) {
      unawaited(finish(videoUrl: video.trim()));
      return;
    }
    final nested = request.matchNested(candidate, base);
    if (nested == null ||
        nested.trim().isEmpty ||
        !network.allowsDeclared(nested.trim(), RuleUrlPurpose.page)) {
      return;
    }
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
    if (!supported || !request.manifest.webViewSniffing) return null;
    final network = _SniffNetworkPolicy(request);
    if (!await network.allows(
      request.pageUrl.toString(),
      RuleUrlPurpose.page,
    )) {
      return null;
    }

    final result = Completer<AnimekoWebViewSniffResult?>();
    HeadlessInAppWebView? webView;
    Timer? timeoutTimer;
    Timer? nestedSettleTimer;
    String? nestedUrl;

    Future<String> readCookies() async {
      if (request.manifest.cookiePolicy != RuleCookiePolicy.taskScoped) {
        return '';
      }
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
      if (video != null &&
          video.trim().isNotEmpty &&
          network.allowsDeclared(video.trim(), RuleUrlPurpose.media)) {
        unawaited(finish(videoUrl: video.trim()));
        return;
      }
      final nested = request.matchNested(candidate, base);
      if (nested == null ||
          nested.trim().isEmpty ||
          !network.allowsDeclared(nested.trim(), RuleUrlPurpose.page)) {
        return;
      }
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
      final cookieHeader = _headerValue(
        filterRuleRequestHeaders(request.headers, request.manifest),
        'cookie',
      );
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
          javaScriptEnabled: request.manifest.javascript,
          javaScriptCanOpenWindowsAutomatically: false,
          supportMultipleWindows: false,
          allowContentAccess: false,
          allowFileAccess: false,
          allowFileAccessFromFileURLs: false,
          allowUniversalAccessFromFileURLs: false,
          geolocationEnabled: false,
          useOnDownloadStart: true,
          thirdPartyCookiesEnabled: false,
          saveFormData: false,
          incognito: true,
          cacheEnabled: false,
          clearSessionCache: true,
          mediaPlaybackRequiresUserGesture: false,
          useOnLoadResource: true,
          useShouldInterceptRequest: true,
          useShouldInterceptAjaxRequest: true,
          useShouldInterceptFetchRequest: true,
          userAgent: _headerValue(
            filterRuleRequestHeaders(request.headers, request.manifest),
            'user-agent',
          ),
          isInspectable: kDebugMode,
        ),
        onWebViewCreated: (controller) async {
          await clearAnimekoWebViewTaskStorage(controller);
          await seedCookies();
          if (result.isCompleted) return;
          await controller.loadUrl(
            urlRequest: URLRequest(
              url: WebUri(request.pageUrl.toString()),
              headers: filterRuleRequestHeaders(
                request.headers,
                request.manifest,
              ),
            ),
          );
        },
        onLoadStart: (_, url) => inspect(url?.toString()),
        onLoadResource: (_, resource) => inspect(resource.url.toString()),
        onDownloadStartRequest: (_, _) {},
        onCreateWindow: (_, _) async => false,
        onPermissionRequest: (_, request) async => PermissionResponse(
          resources: request.resources,
          action: PermissionResponseAction.DENY,
        ),
        onUpdateVisitedHistory: (_, url, _) => inspect(url?.toString()),
        shouldOverrideUrlLoading: (_, action) async {
          final url = action.request.url?.toString();
          if (!await network.allows(url, RuleUrlPurpose.page)) {
            return NavigationActionPolicy.CANCEL;
          }
          inspect(url);
          return NavigationActionPolicy.ALLOW;
        },
        shouldInterceptRequest: (_, resource) async {
          if (!await network.allowsResource(resource.url.toString())) {
            return _blockedWebResourceResponse();
          }
          inspect(resource.url.toString());
          return null;
        },
        shouldInterceptAjaxRequest: (_, ajax) async {
          if (!await network.allowsResource(ajax.url?.toString())) {
            ajax.action = AjaxRequestAction.ABORT;
            return ajax;
          }
          inspect(ajax.url?.toString());
          ajax.action = AjaxRequestAction.PROCEED;
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
          if (!await network.allowsResource(fetch.url?.toString())) {
            fetch.action = FetchRequestAction.ABORT;
            return fetch;
          }
          inspect(fetch.url?.toString());
          fetch.action = FetchRequestAction.PROCEED;
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
        final controller = webView?.webViewController;
        if (controller != null) {
          await clearAnimekoWebViewTaskStorage(controller);
        }
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

class _SniffNetworkPolicy {
  _SniffNetworkPolicy(this.request) : _policy = RuleUrlPolicy(request.manifest);

  final AnimekoWebViewSniffRequest request;
  final RuleUrlPolicy _policy;
  final Map<String, Future<bool>> _publicHostChecks = {};

  bool allowsDeclared(String? value, RuleUrlPurpose purpose) {
    final uri = Uri.tryParse(value?.trim() ?? '');
    return uri != null && _policy.allows(uri, purpose);
  }

  Future<bool> allows(String? value, RuleUrlPurpose purpose) async {
    final uri = Uri.tryParse(value?.trim() ?? '');
    if (uri == null || !_policy.allows(uri, purpose)) return false;
    if (uri.toString() == 'about:blank') return true;
    final host = uri.host.toLowerCase();
    return _publicHostChecks.putIfAbsent(host, () => _hostIsPublic(host));
  }

  Future<bool> allowsResource(String? value) async {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return false;
    final media = request.matchVideo(text, request.pageUrl.toString());
    final purpose = media?.trim().isNotEmpty == true
        ? RuleUrlPurpose.media
        : RuleUrlPurpose.page;
    return allows(text, purpose);
  }

  Future<bool> _hostIsPublic(String host) async {
    if (isForbiddenRuleHost(host)) return false;
    try {
      final addresses = await InternetAddress.lookup(
        host,
      ).timeout(const Duration(seconds: 2));
      return addresses.isNotEmpty &&
          addresses.every((address) => !isForbiddenRuleHost(address.address));
    } catch (_) {
      return false;
    }
  }
}

WebResourceResponse _blockedWebResourceResponse() => WebResourceResponse(
  contentType: 'text/plain',
  contentEncoding: 'utf-8',
  data: Uint8List(0),
  headers: const {'Cache-Control': 'no-store'},
  statusCode: 403,
  reasonPhrase: 'Forbidden',
);

@visibleForTesting
Future<void> clearAnimekoWebViewTaskStorage(
  InAppWebViewController controller,
) async {
  try {
    await controller.callAsyncJavaScript(
      functionBody: '''
        try { localStorage.clear(); } catch (_) {}
        try { sessionStorage.clear(); } catch (_) {}
        try {
          if (indexedDB.databases) {
            const databases = await indexedDB.databases();
            await Promise.all(databases.map((db) => db.name && new Promise(
              (resolve) => {
                const request = indexedDB.deleteDatabase(db.name);
                request.onsuccess = request.onerror = request.onblocked = resolve;
              }
            )));
          }
        } catch (_) {}
        try {
          if (navigator.serviceWorker) {
            const registrations = await navigator.serviceWorker.getRegistrations();
            await Promise.all(registrations.map((registration) => registration.unregister()));
          }
        } catch (_) {}
        return true;
      ''',
    );
  } catch (_) {}
  try {
    await WebStorageManager.instance().deleteAllData();
  } catch (_) {}
  try {
    await CookieManager.instance().deleteAllCookies();
  } catch (_) {}
  try {
    await InAppWebViewController.clearAllCache(includeDiskFiles: true);
  } catch (_) {}
}
