import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anime/src/rules/animeko_webview_sniffer.dart';
import 'package:anime/src/rules/rule_playback_cancellation.dart';
import 'package:anime/src/rules/rule_security.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Opt-in only: a separate .qa Android application on an owned test device.
/// Uses real native headless WebViews, renderer death, cookies, and disposal.
/// No HTTP server, DNS lookup, downloaded content, or production profile is used.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets(
    'Android renderer crash is contained and a new sniff succeeds',
    (tester) async {
      expect(
        Platform.isAndroid,
        isTrue,
        reason: 'Android-only native regression',
      );
      final package = await PackageInfo.fromPlatform();
      expect(
        package.packageName.endsWith('.qa'),
        isTrue,
        reason:
            'Never run the crash fixture or global cleanup in a user profile',
      );
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      final fixture = _NativeAndroidFixture()..install();
      final firstToken = RulePlaybackCancellationToken();
      final nextToken = RulePlaybackCancellationToken();
      final report = <String, Object?>{
        'package': package.packageName,
        'passed': false,
        'fixture': 'about_blank_native_html_no_network',
        // A successful plugin dispose reply is not proof of WebView.destroy().
        'native_destroy_verified': false,
      };
      binding.reportData = report;
      addTearDown(() async {
        firstToken.cancel();
        nextToken.cancel();
        await fixture.close();
        report.addAll(fixture.snapshot());
        debugPrint('ANDROID_WEBVIEW_STABILITY ${jsonEncode(report)}');
      });

      final first = createAnimekoWebViewSniffer().sniff(_request(firstToken));
      final crashedId = await fixture.waitForCreated(0);
      await fixture.waitForDocument(crashedId);
      expect(fixture.settings.single['useOnRenderProcessGone'], isTrue);

      final cookies = CookieManager.instance();
      final cookieUrl = WebUri('https://example.com/');
      expect(
        await cookies.setCookie(
          url: cookieUrl,
          name: 'zeluna_qa_owned',
          value: 'one',
        ),
        isTrue,
      );
      expect(
        (await cookies.getCookies(
          url: cookieUrl,
        )).any((cookie) => cookie.name == 'zeluna_qa_owned'),
        isTrue,
        reason: 'Native cookie creation must be observable before cleanup',
      );

      // This direct test-only native command targets exactly the captured WebView.
      // It is deliberately not a rule URL and does not loosen RuleUrlPolicy.
      await fixture.native(
        fixture.controllerChannel(crashedId),
        MethodCall('loadUrl', {
          'urlRequest': URLRequest(url: WebUri('chrome://crash')).toMap(),
        }),
      );
      await fixture.waitFor(
        () => fixture.rendererGone.containsKey(crashedId),
        'real Android onRenderProcessGone',
      );
      expect(await first.timeout(const Duration(seconds: 10)), isNull);
      await fixture.waitFor(
        () => fixture.disposed.contains(crashedId),
        'native disposal acknowledgement after renderer crash',
      );
      expect(fixture.rendererGone[crashedId]?['didCrash'], isTrue);

      // A distinct production sniffer must pass the shared queue and execute a
      // real native DOM scan after the previous renderer has died.
      fixture.includeMedia = true;
      final next = createAnimekoWebViewSniffer().sniff(_request(nextToken));
      final nextId = await fixture.waitForCreated(1);
      expect(nextId, isNot(crashedId));
      final recovered = await next.timeout(const Duration(seconds: 20));
      expect(recovered?.videoUrl, _mediaUrl);
      expect(recovered?.nestedUrl, isNull);
      expect(fixture.disposed, containsAll([crashedId, nextId]));
      expect(fixture.maxActive, 1);
      expect(
        (await cookies.getCookies(
          url: cookieUrl,
        )).where((cookie) => cookie.name == 'zeluna_qa_owned'),
        isEmpty,
      );
      expect(fixture.unexpectedNavigations, isEmpty);
      expect(fixture.rendererGone, hasLength(1));
      report.addAll({
        ...fixture.snapshot(),
        'host_survived_renderer_crash': true,
        'subsequent_native_sniff_succeeded': true,
        'native_cookie_cleanup_confirmed': true,
        'passed': true,
      });
      debugPrint('ANDROID_WEBVIEW_STABILITY ${jsonEncode(report)}');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

const _mediaUrl = 'https://media.example.test/owned-fixture.m3u8';
AnimekoWebViewSniffRequest _request(RulePlaybackCancellationToken token) =>
    AnimekoWebViewSniffRequest(
      pageUrl: Uri.parse('about:blank'),
      headers: const {},
      cancellationToken: token,
      timeout: const Duration(seconds: 45),
      manifest: const RulePermissionManifest.untrusted(
        id: 'integration:android-webview-stability',
        name: 'Owned native renderer regression',
        version: '1',
        engine: 'animeko-web-selector',
        contentTypes: ['anime'],
        pageDomains: [],
        mediaDomains: ['media.example.test'],
        javascript: true,
        webViewSniffing: true,
      ),
      matchVideo: (value, _) => value.contains(_mediaUrl) ? _mediaUrl : null,
      matchNested: (_, _) => null,
    );

/// Forwards every invocation to the real BinaryMessenger. The owned about:blank
/// document receives fixture DOM through real native evaluateJavascript before
/// its genuine onLoadStop reaches the production scanner. No event is forged.
class _NativeAndroidFixture {
  static const _headless = 'com.pichillilorenzo/flutter_headless_inappwebview';
  static const _controller = 'com.pichillilorenzo/flutter_inappwebview_';
  static const _codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final ids = <String>[];
  final runAcknowledged = <String>{};
  final createdCallbacks = <String>{};
  final documentDispatched = <String>{};
  final loadStopped = <String>{};
  final fixtureInjected = <String>{};
  final diagnosticEvents = <Map<String, Object?>>[];
  final lastDocuments = <String, Object?>{};
  int initializationMissingReplies = 0;
  final disposed = <String>[];
  final active = <String>{};
  final settings = <Map<String, dynamic>>[];
  final rendererGone = <String, Map<String, dynamic>>{};
  final unexpectedNavigations = <String>[];
  final _controllerChannels = <String>{};
  bool includeMedia = false;
  bool _installed = false;
  int maxActive = 0;

  String controllerChannel(String id) => '$_controller$id';

  void install() {
    if (messenger.allMessagesHandler != null) {
      throw StateError(
        'Another fixture already owns outgoing platform messages',
      );
    }
    _installed = true;
    messenger.allMessagesHandler = (channel, handler, message) {
      if (!channel.startsWith('com.pichillilorenzo/flutter_')) {
        return handler != null
            ? handler(message)
            : messenger.delegate.send(channel, message);
      }
      return _outgoing(channel, message);
    };
  }

  Future<ByteData?> _outgoing(String channel, ByteData? message) async {
    if (message == null) return messenger.delegate.send(channel, message);
    final call = _codec.decodeMethodCall(message);
    if (channel == _headless && call.method == 'run') {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      final id = args['id'].toString();
      final params = Map<String, dynamic>.from(args['params'] as Map);
      settings.add(Map<String, dynamic>.from(params['initialSettings'] as Map));
      ids.add(id);
      active.add(id);
      if (active.length > maxActive) maxActive = active.length;
      final controller = controllerChannel(id);
      _controllerChannels.add(controller);
      // The Android Dart plugin installed its original handler before run.
      // Replace only the engine delegate, leaving TestDefaultBinaryMessenger's
      // stored production handler intact for forwarding genuine native events.
      final headlessChannel = '${_headless}_$id';
      messenger.delegate.setMessageHandler(headlessChannel, (data) async {
        if (data != null &&
            _codec.decodeMethodCall(data).method == 'onWebViewCreated') {
          createdCallbacks.add(id);
        }
        return messenger.handlePlatformMessage(headlessChannel, data, null);
      });
      messenger.delegate.setMessageHandler(controller, (data) async {
        if (data != null) {
          final event = _codec.decodeMethodCall(data);
          if (event.method == 'onLoadStart' ||
              event.method == 'onLoadStop' ||
              event.method == 'onReceivedError' ||
              event.method == 'shouldInterceptRequest') {
            if (diagnosticEvents.length < 24) {
              diagnosticEvents.add({
                'id': id,
                'event': event.method,
                'args': event.arguments,
              });
            }
          }
          if (event.method == 'onLoadStop' && documentDispatched.contains(id)) {
            if (fixtureInjected.add(id)) {
              await _injectFixtureDocument(id);
            }
            loadStopped.add(id);
          }
          if (event.method == 'onRenderProcessGone') {
            rendererGone[id] = Map<String, dynamic>.from(
              event.arguments as Map,
            );
            debugPrint(
              'ANDROID_WEBVIEW_RENDERER_GONE ${jsonEncode(rendererGone[id])}',
            );
          }
        }
        return messenger.handlePlatformMessage(controller, data, null);
      });
    }
    if (_controllerChannels.contains(channel) && call.method == 'loadUrl') {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      final request = Map<String, dynamic>.from(args['urlRequest'] as Map);
      if (request['url'] != 'about:blank') {
        unexpectedNavigations.add(request['url'].toString());
        throw StateError('Unexpected production task navigation');
      }
      documentDispatched.add(channel.substring(_controller.length));
      // Keep the real about:blank navigation. loadDataWithBaseURL can introduce
      // a data: main request, which the unchanged production URL policy blocks.
      // Fixture DOM is installed only after the real native onLoadStop arrives.
    }
    final reply = await messenger.delegate.send(channel, message);
    if (channel == _headless && call.method == 'run') {
      if (reply == null) throw StateError('Missing real native run reply');
      _codec.decodeEnvelope(reply);
      runAcknowledged.add(call.arguments['id'].toString());
    }
    if (channel.startsWith('${_headless}_') && call.method == 'dispose') {
      if (reply == null) throw StateError('Missing real native disposal reply');
      _codec.decodeEnvelope(reply);
      final id = channel.substring(_headless.length + 1);
      active.remove(id);
      disposed.add(id);
    }
    return reply;
  }

  Future<void> _injectFixtureDocument(String id) async {
    // Only a detached source element is used; it has no media owner and cannot
    // fetch. The native DOM scanner still sees it. No inline scripts are needed.
    final source =
        '''(() => {
      const root = document.documentElement;
      const head = document.head || root.insertBefore(document.createElement('head'), root.firstChild);
      const body = document.body || root.appendChild(document.createElement('body'));
      const csp = document.createElement('meta');
      csp.httpEquiv = 'Content-Security-Policy';
      csp.content = "default-src 'none'; script-src 'none'";
      head.appendChild(csp);
      document.title = 'Zeluna owned native fixture';
      body.setAttribute('data-zeluna-qa', 'ready');
      ${includeMedia ? "const media = document.createElement('source'); media.src = '$_mediaUrl'; body.appendChild(media);" : ''}
      return {url: location.href, marker: body.getAttribute('data-zeluna-qa'),
        title: document.title, readyState: document.readyState};
    })()''';
    final value = await native(
      controllerChannel(id),
      MethodCall('evaluateJavascript', {
        'source': source,
        'contentWorld': null,
      }),
    );
    lastDocuments[id] = value;
    debugPrint(
      'ANDROID_WEBVIEW_FIXTURE_INJECT ${jsonEncode({'id': id, 'value': value})}',
    );
  }

  Future<ByteData?> _send(String channel, MethodCall call) async =>
      messenger.delegate.send(channel, _codec.encodeMethodCall(call));

  Future<Object?> native(String channel, MethodCall call) async {
    final reply = await _send(channel, call);
    if (reply == null) throw MissingPluginException('${call.method}: $channel');
    return _codec.decodeEnvelope(reply);
  }

  Future<void> waitFor(bool Function() ready, String label) async {
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (!ready() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    if (!ready()) throw TimeoutException(label);
  }

  Future<String> waitForCreated(int index) async {
    await waitFor(
      () =>
          ids.length > index &&
          runAcknowledged.contains(ids[index]) &&
          createdCallbacks.contains(ids[index]),
      'native run acknowledgement and onWebViewCreated $index',
    );
    return ids[index];
  }

  Future<void> waitForDocument(String id) async {
    await waitFor(
      () => loadStopped.contains(id),
      'real onLoadStop after production about:blank navigation',
    );
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(deadline)) {
      if (disposed.contains(id) || rendererGone.containsKey(id)) {
        throw StateError('WebView ended before initial document was ready');
      }
      Object? value;
      try {
        value = await native(
          controllerChannel(id),
          const MethodCall('evaluateJavascript', {
            'source':
                '({url: location.href, title: document.title, '
                'marker: document.body && document.body.getAttribute("data-zeluna-qa"), '
                'html: document.documentElement && document.documentElement.outerHTML.slice(0, 700)})',
            'contentWorld': null,
          }),
        );
      } on MissingPluginException {
        // Only initialization polling may retry an absent channel response.
        // Crash commands, cookie operations and native teardown remain strict.
        initializationMissingReplies++;
        await Future<void>.delayed(const Duration(milliseconds: 25));
        continue;
      }
      // Native evaluateJavascript returns JSON text; decode the same envelope
      // that the public Android Dart controller decodes before returning it.
      if (value is String) {
        try {
          value = jsonDecode(value);
        } catch (_) {}
      }
      lastDocuments[id] = value;
      if (value is Map && value['marker'] == 'ready') return;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    final currentSettings = await native(
      controllerChannel(id),
      const MethodCall('getSettings'),
    );
    debugPrint(
      'ANDROID_WEBVIEW_DOCUMENT_TIMEOUT ${jsonEncode({'id': id, 'document': lastDocuments[id], 'settings': currentSettings, 'events': diagnosticEvents})}',
    );
    throw TimeoutException('Real native fixture document was not loaded');
  }

  Map<String, Object?> snapshot() => {
    'native_create_dispatched': ids.length,
    'native_run_acknowledged': runAcknowledged.length,
    'native_created_callbacks': createdCallbacks.length,
    'native_fixture_load_stopped': loadStopped.length,
    'fixture_dom_injected': fixtureInjected.length,
    'last_documents': lastDocuments,
    'initialization_events': diagnosticEvents,
    'initialization_missing_replies': initializationMissingReplies,
    'native_dispose_acknowledged': disposed.length,
    'renderer_gone_events': rendererGone.values.toList(),
    'max_active_native_handles': maxActive,
    'remaining_active_handles': active.length,
    'unexpected_task_navigations': unexpectedNavigations.length,
  };

  Future<void> close() async {
    if (!_installed) return;
    // Give production cancellation/dispose its own native acknowledgement;
    // never synthesize success or manually destroy a competing task's WebView.
    try {
      await waitFor(() => active.isEmpty, 'production native teardown');
    } finally {
      messenger.allMessagesHandler = null;
      _installed = false;
    }
  }
}
