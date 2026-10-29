import 'dart:async';
import 'package:anime/src/rules/rule_media_resolver.dart';
import 'package:anime/src/rules/animeko_webview_sniffer_base.dart';
import 'package:anime/src/rules/rule_playback_cancellation.dart';
import 'package:anime/src/rules/rule_security.dart';
import 'package:flutter_test/flutter_test.dart';

const manifest = RulePermissionManifest.official(
  id: 'test',
  name: 'test',
  version: '1',
  engine: 'native',
  contentTypes: ['anime'],
  pageDomains: ['page.test', 'embed.test'],
  mediaDomains: ['media.test'],
  customReferer: true,
  cookiePolicy: RuleCookiePolicy.taskScoped,
);

void main() {
  RuleMediaResolver resolver(
    Future<String> Function(Uri, Map<String, String>) read,
    _Sniffer sniffer,
  ) => RuleMediaResolver(
    readPage: read,
    sniffer: sniffer,
    extract: (text, base) =>
        text.startsWith('MEDIA:') ? text.substring(6) : null,
    headersFor: (page) => {'Referer': page.toString(), 'Cookie': 'page-secret'},
  );

  test(
    'forbidden frames never generate requests and frame loops terminate',
    () async {
      final calls = <Uri>[];
      final sniffer = _Sniffer();
      final result =
          await resolver((uri, headers) async {
            calls.add(uri);
            expect(
              headers.keys.map((k) => k.toLowerCase()),
              isNot(contains('cookie')),
            );
            return '<iframe src="https://page.test/start"></iframe>';
          }, sniffer).resolve(
            page: Uri.parse('https://page.test/start'),
            body:
                '<iframe src="http://127.0.0.1/private"></iframe><iframe src="https://unknown.test/private"></iframe><iframe src="https://embed.test/player"></iframe>',
            manifest: manifest,
          );
      expect(result, isNull);
      expect(calls.map((u) => u.host), ['embed.test']);
      expect(sniffer.calls, 0);
    },
  );
  test(
    'a late page response after cancellation cannot deliver media',
    () async {
      final response = Completer<String>();
      final token = RulePlaybackCancellationToken();
      final result = resolver((_, _) => response.future, _Sniffer()).resolve(
        page: Uri.parse('https://page.test/start'),
        body: '<iframe src="/embed"></iframe>',
        manifest: manifest,
        cancellationToken: token,
      );
      await Future<void>.delayed(Duration.zero);
      token.cancel();
      response.complete('MEDIA:https://media.test/ep1.m3u8');
      expect(await result, isNull);
    },
  );
  test('unapproved script discovery is not executed', () async {
    final sniffer = _Sniffer();
    final result = await resolver((_, _) async => '', sniffer).resolve(
      page: Uri.parse('https://page.test/start'),
      body: '<script>player()</script>',
      manifest: manifest,
    );
    expect(result, isNull);
    expect(sniffer.calls, 0);
  });
  test('sniffed media outside granted domains is rejected', () async {
    final sniffer = _Sniffer();
    final result = await resolver((_, _) async => '', sniffer).resolve(
      page: Uri.parse('https://page.test/start'),
      body: '<script>player()</script>',
      manifest: manifest.copyWith(javascript: true, webViewSniffing: true),
    );
    expect(result, isNull);
    expect(sniffer.calls, 1);
  });
}

class _Sniffer implements AnimekoWebViewSniffer {
  int calls = 0;
  @override
  bool get supported => true;
  @override
  Future<AnimekoWebViewSniffResult?> sniff(
    AnimekoWebViewSniffRequest request,
  ) async {
    calls++;
    return const AnimekoWebViewSniffResult(
      videoUrl: 'https://unknown.test/ep1.m3u8',
      cookieHeader: 'secret',
    );
  }
}
