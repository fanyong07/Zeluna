import 'dart:io';

import 'package:anime/src/rules/animeko_webview_sniffer.dart';
import 'package:anime/src/rules/rule_security.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Windows headless WebView refuses loopback pages before navigation',
    (tester) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        if (request.uri.path == '/api') {
          request.response
            ..headers.contentType = ContentType.json
            ..write('{"url":"https://media.example.test/episode.m3u8"}');
        } else if (request.uri.path == '/pulse') {
          request.response
            ..headers.contentType = ContentType.json
            ..write('{"ok":true}');
        } else {
          request.response
            ..headers.contentType = ContentType.html
            ..headers.add('set-cookie', 'runtime=ready; Path=/')
            ..write('''
            <!doctype html>
            <video id="player"></video>
            <script>
              const xhr = new XMLHttpRequest();
              xhr.onreadystatechange = () => {
                if (xhr.readyState === 4) {
                  document.querySelector('#player').src = JSON.parse(xhr.responseText).url;
                }
              };
              xhr.open('GET', '/api');
              xhr.send();
              setInterval(() => fetch('/pulse?t=' + Date.now()), 25);
            </script>
          ''');
        }
        await request.response.close();
      });

      final pageUrl = Uri.parse('http://127.0.0.1:${server.port}/');
      final sniffer = createAnimekoWebViewSniffer();
      expect(sniffer.supported, isTrue);

      for (var attempt = 0; attempt < 3; attempt++) {
        final result = await sniffer.sniff(
          AnimekoWebViewSniffRequest(
            pageUrl: pageUrl,
            headers: const {'Cookie': 'configured=yes'},
            matchVideo: (value, baseUrl) {
              final match = RegExp(
                r'''https?://[^\s"']+\.(?:m3u8|mp4)''',
                caseSensitive: false,
              ).firstMatch(value);
              return match?.group(0);
            },
            matchNested: (_, _) => null,
            manifest: const RulePermissionManifest(
              id: 'integration:loopback',
              name: 'Loopback security test',
              version: '1.0',
              engine: 'animeko-web-selector',
              contentTypes: ['anime'],
              sourceRepository: 'integration-test',
              contentHash: 'test',
              signature: '',
              trustLevel: RuleTrustLevel.untrusted,
              pageDomains: ['127.0.0.1'],
              mediaDomains: ['media.example.test'],
              javascript: true,
              webViewSniffing: true,
              cookiePolicy: RuleCookiePolicy.taskScoped,
              cleartextHttp: true,
              customReferer: false,
              customOrigin: false,
              customUserAgent: false,
              minimumCoreVersion: '1.0.0',
            ),
          ),
        );

        expect(result, isNull);
        await tester.pump(const Duration(milliseconds: 100));
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
