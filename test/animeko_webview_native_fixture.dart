import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anime/src/rules/animeko_webview_sniffer.dart';
import 'package:anime/src/rules/rule_security.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';

/// Test-only fault injection around the REAL Windows platform channel.
///
/// Does not replace the platform implementation, controller, callbacks, settings,
/// or script engine. Non-faulted calls go to the native BinaryMessenger delegate.
/// Only the fixture URL becomes native NavigateToString; no server is involved.
class AnimekoWebViewNativeFixture {
  AnimekoWebViewNativeFixture._(this.profile, this.environment, this.version);

  static const _headless = 'com.pichillilorenzo/flutter_headless_inappwebview';
  static const _controller = 'com.pichillilorenzo/flutter_inappwebview_';
  static const _cookies = '${_controller}cookiemanager';
  static const _environmentPrefix =
      'com.pichillilorenzo/flutter_webview_environment_';
  static const _codec = StandardMethodCodec();
  // Numeric public host: the unchanged rule policy still runs, without DNS or
  // loopback exemptions. This URL is NEVER sent to native networking.
  static final pageUrl = Uri.parse('https://93.184.216.34/core005-fixture');

  final Directory profile;
  final WebViewEnvironment environment;
  final String version;
  final sniffer = createAnimekoWebViewSniffer();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final documents = <Map<String, Object?>>[];
  final errors = <String>[];
  final controllerIds = <String>[];
  final _controllerChannels = <String>{};
  final _headlessChannels = <String>{};
  int blankFailures = 0;
  int nativeDisposals = 0;
  int environmentDisposals = 0;
  final environmentDisposeChannels = <String>[];
  int settingsAttempts = 0;
  int injectedSettingsFailures = 0;
  int injectedReadbackFailures = 0;
  int forbiddenTaskNavigations = 0;
  int blockedGlobalClears = 0;
  int isolatedCookieCalls = 0;
  bool failBlankReset = true;
  String? fault;
  bool _faultApplied = false;
  bool _faultSettingsWritten = false;
  bool _closed = false;
  bool _disposingEnvironment = false;

  static Future<AnimekoWebViewNativeFixture> create() async {
    if (!Platform.isWindows) throw StateError('Requires real Windows WebView2');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    if (messenger.allMessagesHandler != null) {
      throw StateError('A different fixture already owns the native bridge');
    }
    final version = await WebViewEnvironment.getAvailableVersion();
    if (version == null || version.isEmpty) {
      throw StateError('WebView2 runtime is unavailable');
    }
    final profile = await Directory.systemTemp.createTemp('zeluna-core005-');
    await File(
      '${profile.path}/core005-owned-profile',
    ).writeAsString(profile.absolute.path);
    final environment = await WebViewEnvironment.create(
      settings: WebViewEnvironmentSettings(
        userDataFolder: profile.absolute.path,
      ),
    );
    final fixture = AnimekoWebViewNativeFixture._(
      profile,
      environment,
      version,
    );
    messenger.allMessagesHandler = (channel, handler, message) {
      if (!channel.startsWith('com.pichillilorenzo/flutter_')) {
        return handler != null
            ? handler(message)
            : messenger.delegate.send(channel, message);
      }
      return fixture._intercept(channel, message);
    };
    fixture.report('created');
    return fixture;
  }

  Future<AnimekoWebViewSniffResult?> sniff(bool javascript) =>
      sniffer.sniff(_request(pageUrl, javascript));

  AnimekoWebViewSniffRequest _request(Uri url, bool javascript) =>
      AnimekoWebViewSniffRequest(
        pageUrl: url,
        headers: const {},
        matchVideo: (_, _) => null,
        matchNested: (_, _) => null,
        manifest: RulePermissionManifest.untrusted(
          id: 'integration:core005',
          name: 'Isolated retained-controller fixture',
          version: '1.0',
          engine: 'animeko-web-selector',
          contentTypes: const ['anime'],
          pageDomains: [url.host],
          mediaDomains: const [],
          javascript: javascript,
          webViewSniffing: true,
        ),
        timeout: const Duration(milliseconds: 150),
      );

  Future<ByteData?> _send(String channel, MethodCall call) =>
      messenger.delegate.send(channel, _codec.encodeMethodCall(call))!;

  Future<Object?> _native(String channel, MethodCall call) async {
    final reply = await _send(channel, call);
    if (reply == null) throw MissingPluginException('${call.method}: $channel');
    return _codec.decodeEnvelope(reply);
  }

  Future<ByteData?> _intercept(String channel, ByteData? message) async {
    if (message == null) return messenger.delegate.send(channel, message);
    final call = _codec.decodeMethodCall(message);
    if (_disposingEnvironment &&
        call.method == 'dispose' &&
        channel.startsWith(_environmentPrefix)) {
      // This Windows fork creates the native environment with env.id, but
      // binds the returned Dart env.channel to the static factory's id.
      // Correct only this fixture's disposal route. The REAL native handler
      // must acknowledge success; do not mock success or swallow exceptions.
      final ownedChannel = '$_environmentPrefix${environment.id}';
      final reply = await _send(ownedChannel, call);
      if (reply == null) {
        throw MissingPluginException(
          'Owned environment dispose: $ownedChannel',
        );
      }
      _codec.decodeEnvelope(reply);
      environmentDisposeChannels.add('$channel -> $ownedChannel');
      environmentDisposals++;
      return reply;
    }
    if (channel == _headless && call.method == 'run') {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      final params = Map<String, dynamic>.from(args['params'] as Map);
      params['webViewEnvironmentId'] = environment.id;
      args['params'] = params;
      final id = args['id'].toString();
      controllerIds.add(id);
      _controllerChannels.add('$_controller$id');
      _headlessChannels.add('${_headless}_$id');
      return _send(channel, MethodCall(call.method, args));
    }
    if (channel == _cookies) {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      args['webViewEnvironmentId'] = environment.id;
      isolatedCookieCalls++;
      return _send(channel, MethodCall(call.method, args));
    }
    // These global APIs have no environment parameter and are not implemented
    // by this Windows fork. Fail explicitly instead of risking a user store if
    // a later fork starts implementing them. Per-controller JS cleanup and all
    // environment-scoped cookie operations remain real native calls.
    if (call.method == 'clearAllCache' || call.method == 'deleteAllData') {
      blockedGlobalClears++;
      return _codec.encodeErrorEnvelope(
        code: 'CORE005_UNSCOPED_STORAGE',
        message: 'Fixture refuses profile-global clearing',
      );
    }
    if (_headlessChannels.contains(channel) && call.method == 'dispose') {
      final reply = await _send(channel, call);
      if (reply != null) _codec.decodeEnvelope(reply);
      nativeDisposals++;
      return reply;
    }
    if (!_controllerChannels.contains(channel)) {
      return messenger.delegate.send(channel, message);
    }
    if (call.method == 'setSettings') {
      settingsAttempts++;
      if (fault == 'setSettings' && !_faultApplied) {
        _faultApplied = true;
        injectedSettingsFailures++;
        return _codec.encodeErrorEnvelope(code: 'CORE005_SETTINGS_FAILURE');
      }
      final reply = await _send(channel, call);
      if (reply != null) _codec.decodeEnvelope(reply);
      if (fault != null) _faultSettingsWritten = true;
      return reply;
    }
    if (call.method == 'getSettings' &&
        _faultSettingsWritten &&
        !_faultApplied &&
        (fault == 'nullReadback' || fault == 'mismatchedReadback')) {
      final real = await _native(channel, call);
      _faultApplied = true;
      injectedReadbackFailures++;
      if (fault == 'nullReadback') return _codec.encodeSuccessEnvelope(null);
      final settings = Map<String, dynamic>.from(real! as Map);
      settings['javaScriptEnabled'] = !(settings['javaScriptEnabled'] as bool);
      return _codec.encodeSuccessEnvelope(settings);
    }
    if (call.method == 'loadUrl') {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      final request = Map<String, dynamic>.from(args['urlRequest'] as Map);
      final url = request['url'];
      if (url == 'about:blank') {
        if (failBlankReset) {
          blankFailures++;
          return _codec.encodeErrorEnvelope(
            code: 'CORE005_BLANK_RESET_FAILURE',
          );
        }
        return _send(channel, call);
      }
      if (url != pageUrl.toString()) {
        errors.add('Unexpected task navigation was blocked: $url');
        return _codec.encodeErrorEnvelope(
          code: 'CORE005_UNEXPECTED_NAVIGATION',
        );
      }
      if (fault != null) forbiddenTaskNavigations++;
      final documentId = documents.length + 1;
      final reply = await _send(
        channel,
        MethodCall('loadData', {
          'data':
              '''<!doctype html><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'">
<title>core005-$documentId</title>
<body data-fixture="$documentId" data-inline-runs="0">
<script>document.body.dataset.inlineRuns = '1';</script></body>''',
        }),
      );
      if (reply != null) _codec.decodeEnvelope(reply);
      try {
        await _captureDocument(channel, documentId);
      } catch (error) {
        errors.add('Native document observation failed: $error');
        rethrow;
      }
      return reply;
    }
    return messenger.delegate.send(channel, message);
  }

  Future<void> _captureDocument(String channel, int documentId) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      final raw = await _native(
        channel,
        const MethodCall('evaluateJavascript', {
          'source': '''JSON.stringify({
            fixture: document.body && document.body.dataset.fixture,
            inlineRuns: document.body && document.body.dataset.inlineRuns,
            ready: document.readyState
          })''',
        }),
      );
      // WebView2 ExecuteScript serializes the JS return value once; the script
      // deliberately returns JSON text, giving a second layer to decode.
      var value = raw;
      for (var layer = 0; layer < 2 && value is String; layer++) {
        value = jsonDecode(value);
      }
      if (value is Map &&
          value['fixture'] == '$documentId' &&
          value['ready'] == 'complete') {
        final settings = await _native(
          channel,
          const MethodCall('getSettings', {}),
        );
        if (settings is! Map) throw StateError('Native settings unavailable');
        documents.add({
          'controller': channel,
          'fixture': documentId,
          'inlineRuns': value['inlineRuns'],
          'javascript': settings['javaScriptEnabled'],
        });
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    throw TimeoutException('Native inline document did not finish loading');
  }

  Future<void> seedOwnedCookie() async {
    final manager = CookieManager.instance(webViewEnvironment: environment);
    final set = await manager.setCookie(
      url: WebUri(pageUrl.toString()),
      name: 'core005_owned',
      value: 'fixture-only',
    );
    if (!set) throw StateError('Could not seed isolated native cookie');
    final cookies = await manager.getCookies(url: WebUri(pageUrl.toString()));
    if (!cookies.any((cookie) => cookie.name == 'core005_owned')) {
      throw StateError('Isolated native cookie was not observable');
    }
  }

  Future<bool> get ownedCookiesCleared async => (await CookieManager.instance(
    webViewEnvironment: environment,
  ).getCookies(url: WebUri(pageUrl.toString()))).isEmpty;

  void report(String stage) {
    debugPrint(
      'WEBVIEW_CORE005 ${jsonEncode({'stage': stage, 'runtime': version, 'profile': profile.absolute.path, 'controllers': controllerIds, 'documents': documents, 'blankFailures': blankFailures, 'nativeDisposals': nativeDisposals, 'environmentId': environment.id, 'environmentDisposals': environmentDisposals, 'environmentDisposeChannels': environmentDisposeChannels, 'settingsAttempts': settingsAttempts, 'injectedSettingsFailures': injectedSettingsFailures, 'injectedReadbackFailures': injectedReadbackFailures, 'forbiddenTaskNavigations': forbiddenTaskNavigations, 'isolatedCookieCalls': isolatedCookieCalls, 'blockedGlobalClears': blockedGlobalClears, 'errors': errors})}',
    );
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    failBlankReset = false;
    fault = null;
    var safelyDisposed = false;
    try {
      if (controllerIds.isNotEmpty) {
        // Existing network policy rejects this before task navigation. Finally
        // runs the real blank navigation/callback/drain/disposal path, with no
        // forced destruction of a live retained controller.
        await sniffer
            .sniff(_request(Uri.parse('http://127.0.0.1/'), false))
            .timeout(const Duration(seconds: 15));
        if (nativeDisposals != controllerIds.length) {
          throw StateError('Real blank callback/disposal was not confirmed');
        }
      }
      _disposingEnvironment = true;
      try {
        await environment.dispose();
        if (environmentDisposals != 1) {
          throw StateError(
            'Owned native environment disposal was not confirmed',
          );
        }
      } finally {
        _disposingEnvironment = false;
      }
      safelyDisposed = true;
    } finally {
      messenger.allMessagesHandler = null;
      report(
        safelyDisposed ? 'native-cleanup-confirmed' : 'retained-for-safety',
      );
    }
    // WebView2 may hold profile files briefly after its last COM release.
    // Delete only this fixture's verified temp directory, never a shared store.
    final temp = await Directory.systemTemp.resolveSymbolicLinks();
    final target = profile.absolute.path;
    final marker = File('$target/core005-owned-profile');
    final isDirectory =
        await FileSystemEntity.type(target, followLinks: false) ==
        FileSystemEntityType.directory;
    final resolved = await profile.resolveSymbolicLinks();
    if (!isDirectory ||
        !resolved.toLowerCase().startsWith(
          '${temp.toLowerCase()}${Platform.pathSeparator}zeluna-core005-',
        ) ||
        !await marker.exists() ||
        await marker.readAsString() != target) {
      throw StateError('Refusing to delete an unverified fixture directory');
    }
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        await profile.delete(recursive: true);
        debugPrint('WEBVIEW_CORE005 owned-profile-removed: $target');
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
    debugPrint('WEBVIEW_CORE005 owned-profile-still-locked: $target');
  }
}
