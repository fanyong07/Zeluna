import 'dart:async';

import 'package:anime/src/rules/animeko_webview_sniffer_base.dart';
import 'package:anime/src/rules/animeko_webview_sniffer_io.dart';
import 'package:anime/src/rules/rule_playback_cancellation.dart';
import 'package:anime/src/rules/rule_security.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
// Use the real Android Dart plugin with a recording native-channel boundary.
// ignore: depend_on_referenced_packages
import 'package:flutter_inappwebview_android/flutter_inappwebview_android.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _NativeSpy spy;
  late InAppWebViewPlatform? previousPlatform;
  setUp(() {
    previousPlatform = InAppWebViewPlatform.instance;
    AndroidInAppWebViewPlatform.registerWith();
    spy = _NativeSpy()..install();
  });
  tearDown(() {
    spy.uninstall();
    if (previousPlatform != null) {
      InAppWebViewPlatform.instance = previousPlatform!;
    }
  });

  test(
    'renderer gone ends task, disposes, and next instance may run',
    () async {
      final first = createAndroidAnimekoWebViewSnifferForTesting().sniff(
        _request(),
      );
      final id = await spy.nextCreated();
      expect(spy.settings.single['useOnRenderProcessGone'], isTrue);
      await spy.created(id);
      await spy.waitFor(() => spy.loads.contains(id));
      await spy.event(id, 'onRenderProcessGone', {
        'didCrash': true,
        'rendererPriorityAtExit': 0,
      });
      expect(await first, isNull);
      await spy.waitFor(() => spy.disposed.contains(id));
      expect(spy.disposed, [id]);
      expect(
        spy.scriptCalls,
        0,
        reason: 'Never run cleanup JS on a dead renderer',
      );

      final next = createAndroidAnimekoWebViewSnifferForTesting().sniff(
        _request(),
      );
      final second = await spy.nextCreated();
      await spy.created(second);
      await spy.waitFor(() => spy.loads.contains(second));
      await spy.event(second, 'onLoadStart', {'url': _video});
      expect((await next)?.videoUrl, _video);
      expect(spy.maxActive, 1);
      expect(spy.active, isEmpty);
    },
  );

  test(
    'late setup after cancellation never seeds or navigates; dispose is not held by setup',
    () async {
      final setupGate = Completer<void>();
      spy.clearGate = setupGate;
      final token = RulePlaybackCancellationToken();
      final first = createAndroidAnimekoWebViewSnifferForTesting().sniff(
        _request(token: token),
      );
      final id = await spy.nextCreated();
      await spy.created(id);
      await spy.waitFor(() => spy.clearCalls > 0);
      final waitingToken = RulePlaybackCancellationToken();
      final waiting = createAndroidAnimekoWebViewSnifferForTesting().sniff(
        _request(token: waitingToken),
      );
      waitingToken.cancel();
      expect(await waiting, isNull);
      token.cancel();
      expect(await first, isNull);
      await spy.waitFor(() => spy.disposed.contains(id));
      expect(spy.loads, isEmpty);
      expect(spy.cookieSeeds, 0);
      final next = createAndroidAnimekoWebViewSnifferForTesting().sniff(
        _request(),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        spy.settings,
        hasLength(1),
        reason: 'Pending global clear still owns the lane',
      );
      spy.clearGate = null;
      setupGate.complete();
      final second = await spy.nextCreated();
      await spy.created(second);
      await spy.waitFor(() => spy.loads.contains(second));
      await spy.event(second, 'onLoadStart', {'url': _video});
      expect((await next)?.videoUrl, _video);
      expect(spy.loads, [second]);
      expect(spy.maxActive, 1);
    },
  );

  test(
    'timeout during native run waits for run ack before dispose, with no late setup',
    () async {
      final runGate = Completer<void>();
      spy.runGate = runGate;
      final first = createAndroidAnimekoWebViewSnifferForTesting().sniff(
        _request(timeout: const Duration(milliseconds: 30)),
      );
      final id = await spy.nextCreated();
      expect(await first, isNull);
      await spy.created(id);
      expect(spy.clearCalls, 0);
      expect(spy.loads, isEmpty);
      runGate.complete();
      await spy.waitFor(() => spy.disposed.contains(id));
      await spy.waitFor(() => spy.clearCalls > 0);
    },
  );

  test('concurrent instances stay serial through stalled cleanup JS', () async {
    final scriptGate = Completer<void>();
    spy.scriptGate = scriptGate;
    final first = createAndroidAnimekoWebViewSnifferForTesting().sniff(
      _request(),
    );
    final id = await spy.nextCreated();
    await spy.created(id);
    await spy.waitFor(() => spy.loads.contains(id));
    final second = createAndroidAnimekoWebViewSnifferForTesting().sniff(
      _request(),
    );
    await spy.event(id, 'onLoadStart', {'url': _video});
    await spy.waitFor(() => spy.scriptCalls == 1);
    expect(spy.settings, hasLength(1));
    // The 500ms cleanup-JS deadline permits native dispose without waiting for
    // renderer JS forever. Global mutations are still drained before admission.
    expect((await first)?.videoUrl, _video);
    expect(spy.disposed, [id]);
    final nextId = await spy.nextCreated();
    spy.scriptGate = null;
    scriptGate.complete();
    await spy.created(nextId);
    await spy.waitFor(() => spy.loads.contains(nextId));
    await spy.event(nextId, 'onLoadStart', {'url': _video});
    expect((await second)?.videoUrl, _video);
    expect(spy.maxActive, 1);
    expect(spy.active, isEmpty);
  });

  test(
    'cleanup JS failure still disposes and denied media never becomes result',
    () async {
      spy.failScripts = true;
      final task = createAndroidAnimekoWebViewSnifferForTesting().sniff(
        _request(),
      );
      final id = await spy.nextCreated();
      await spy.created(id);
      await spy.waitFor(() => spy.loads.contains(id));
      await spy.event(id, 'onLoadStart', {
        'url': 'https://127.0.0.1/denied.m3u8',
      });
      expect(spy.disposed, isEmpty);
      await spy.event(id, 'onLoadStart', {'url': _video});
      expect((await task)?.videoUrl, _video);
      expect(spy.disposed, [id]);
    },
  );
  // Last: intentionally quarantines the process-wide production queue.
  test('native dispose failure quarantines later instances', () async {
    final task = createAndroidAnimekoWebViewSnifferForTesting().sniff(
      _request(),
    );
    final id = await spy.nextCreated();
    await spy.created(id);
    await spy.waitFor(() => spy.loads.contains(id));
    spy.failDispose = true;
    await spy.event(id, 'onLoadStart', {'url': _video});
    expect(await task, isNull);
    expect(
      await createAndroidAnimekoWebViewSnifferForTesting().sniff(_request()),
      isNull,
    );
    expect(spy.settings, hasLength(1));
  });
}

const _video = 'https://93.184.216.34/video.m3u8';
AnimekoWebViewSniffRequest _request({
  RulePlaybackCancellationToken? token,
  Duration timeout = const Duration(seconds: 3),
}) => AnimekoWebViewSniffRequest(
  pageUrl: Uri.parse('https://93.184.216.34/page'),
  headers: const {'Cookie': 'task=one'},
  matchVideo: (value, _) => value.endsWith('.m3u8') ? value : null,
  matchNested: (_, _) => null,
  manifest: const RulePermissionManifest.untrusted(
    id: 'test:webview',
    name: 'fixture',
    version: '1',
    engine: 'animeko-web-selector',
    contentTypes: ['anime'],
    pageDomains: ['93.184.216.34'],
    mediaDomains: ['93.184.216.34'],
    javascript: true,
    webViewSniffing: true,
    cookiePolicy: RuleCookiePolicy.taskScoped,
  ),
  timeout: timeout,
  cancellationToken: token,
);

class _NativeSpy {
  static const _headless = 'com.pichillilorenzo/flutter_headless_inappwebview';
  static const _controller = 'com.pichillilorenzo/flutter_inappwebview_';
  static const _codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final _newIds = <String>[];
  final settings = <Map<dynamic, dynamic>>[];
  final active = <String>{};
  final disposed = <String>[];
  final loads = <String>[];
  int maxActive = 0, clearCalls = 0, cookieSeeds = 0, scriptCalls = 0;
  Completer<void>? clearGate, runGate, scriptGate;
  bool failScripts = false, failDispose = false;

  void install() {
    messenger.allMessagesHandler = (channel, handler, message) async {
      if (!channel.startsWith('com.pichillilorenzo/flutter_')) {
        return handler?.call(message);
      }
      final call = _codec.decodeMethodCall(message!);
      Object? result;
      if (channel == _headless && call.method == 'run') {
        final id = call.arguments['id'].toString();
        _newIds.add(id);
        active.add(id);
        if (active.length > maxActive) maxActive = active.length;
        settings.add(
          Map.from(call.arguments['params']['initialSettings'] as Map),
        );
        await runGate?.future;
      } else if (channel.startsWith('${_headless}_') &&
          call.method == 'dispose') {
        final id = channel.substring(_headless.length + 1);
        if (failDispose) {
          return _codec.encodeErrorEnvelope(code: 'fixture_dispose_failure');
        }
        active.remove(id);
        disposed.add(id);
      } else if (call.method == 'deleteAllData') {
        clearCalls++;
        await clearGate?.future;
      } else if (call.method == 'loadUrl') {
        loads.add(channel.substring(_controller.length));
      } else if (call.method == 'setCookie') {
        cookieSeeds++;
        result = true;
      } else if (call.method == 'getCookies') {
        result = <Object>[];
      } else if (call.method == 'deleteAllCookies') {
        result = true;
      } else if (call.method == 'callAsyncJavaScript') {
        scriptCalls++;
        await scriptGate?.future;
        if (failScripts) {
          return _codec.encodeErrorEnvelope(code: 'fixture_js_failure');
        }
        result = '{"value":true,"error":null}';
      }
      return _codec.encodeSuccessEnvelope(result);
    };
  }

  Future<void> waitFor(bool Function() predicate) async {
    for (var i = 0; i < 1000 && !predicate(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(predicate(), isTrue, reason: 'native channel event did not arrive');
  }

  Future<String> nextCreated() async {
    await waitFor(() => _newIds.isNotEmpty);
    return _newIds.removeAt(0);
  }

  Future<void> created(String id) =>
      _send('${_headless}_$id', 'onWebViewCreated', null);
  Future<void> event(String id, String method, Object? args) =>
      _send('$_controller$id', method, args);
  Future<void> _send(String channel, String method, Object? args) async {
    final done = Completer<void>();
    messenger.handlePlatformMessage(
      channel,
      _codec.encodeMethodCall(MethodCall(method, args)),
      (_) => done.complete(),
    );
    await done.future;
  }

  void uninstall() => messenger.allMessagesHandler = null;
}
