import 'dart:async';

import 'package:anime/src/core/network/media_request_headers.dart';
import 'package:anime/src/core/network/network_security.dart';
import 'package:anime/src/player/video/native_media_transport_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final root = Uri.parse('https://media.example.test/start.m3u8');
  late http.Client local;
  setUp(() => local = http.Client());
  tearDown(() => local.close());

  Future<NativeMediaBridge> bridge(
    FutureOr<http.Response> Function(http.Request) handler, {
    Uri? source,
    Map<String, String> headers = const {},
    bool playlist = false,
  }) async {
    final result = await NativeMediaBridge.start(
      source ?? root,
      headers: headers,
      playlist: playlist,
      clientFactory: () => MockClient((request) async => handler(request)),
    );
    addTearDown(result.dispose);
    return result;
  }

  List<Uri> mediaUris(String text) => [
    for (final line in text.split('\n'))
      if (line.isNotEmpty && !line.startsWith('#')) Uri.parse(line),
    for (final match in RegExp(r'URI="([^"]+)"').allMatches(text))
      Uri.parse(match[1]!),
  ];

  test('probe default UA and explicit case-insensitive source UA agree', () {
    expect(
      effectiveMediaRequestHeaders({})['User-Agent'],
      defaultMediaUserAgent,
    );
    expect(effectiveMediaRequestHeaders({'user-agent': 'custom'}), {
      'user-agent': 'custom',
    });
  });

  test(
    'rewrites relative variants, AES keys, init maps, segments and subtitles',
    () async {
      final calls = <Uri>[];
      final b = await bridge((request) {
        calls.add(request.url);
        return switch (request.url.path) {
          '/start.m3u8' => http.Response(
            '#EXTM3U\n#EXT-X-MEDIA:TYPE=SUBTITLES,URI="sub/list"\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nvariant?signature=fixture\n',
            200,
          ),
          '/variant' => http.Response(
            '',
            302,
            headers: {'location': 'https://cdn.example.test/final/video.m3u8'},
          ),
          '/final/video.m3u8' => http.Response(
            '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n#EXT-X-MAP:URI="init.mp4"\n#EXTINF:2,\nsegment.ts?signature=fixture\n#EXT-X-ENDLIST\n',
            200,
          ),
          _ => http.Response.bytes(List.filled(16, 7), 200),
        };
      }, playlist: true);
      final master = await local.get(b.uri);
      expect(master.statusCode, 200);
      final children = mediaUris(master.body);
      expect(children, hasLength(2));
      expect(
        children.every((u) => u.host == '127.0.0.1' && u.port == b.uri.port),
        isTrue,
      );
      expect(master.body, isNot(contains('example.test')));
      final variant = await local.get(children.first);
      final resources = mediaUris(variant.body);
      expect(resources, hasLength(3));
      for (final uri in resources) {
        expect((await local.get(uri)).bodyBytes, List.filled(16, 7));
      }
      expect(
        calls.map((u) => u.path),
        containsAll(['/final/key.bin', '/final/init.mp4', '/final/segment.ts']),
      );
      expect(
        calls.lastWhere((u) => u.path.endsWith('segment.ts')).query,
        'signature=fixture',
      );
      final repeated = await local.get(children.first);
      expect(
        mediaUris(repeated.body),
        resources,
        reason: 'playlist refresh reuses bounded registrations',
      );
    },
  );

  test(
    'same-origin credentials retained, cross-origin and redirect bounce stripped',
    () async {
      final calls = <http.Request>[];
      final b = await bridge(
        (request) {
          calls.add(request);
          return switch (request.url.path) {
            '/start.m3u8' => http.Response(
              '#EXTM3U\n#EXTINF:2,\nsame.ts\n#EXTINF:2,\nhttps://cdn.example.test/cross.ts\n',
              200,
            ),
            '/cross.ts' => http.Response(
              '',
              302,
              headers: {'location': 'https://media.example.test/returned.ts'},
            ),
            _ => http.Response.bytes(List.filled(20, 9), 200),
          };
        },
        headers: {
          'Authorization': 'Bearer fixture',
          'Cookie': 'fixture=1',
          'X-AppId': 'fixture',
          'X-Timestamp': '1',
          'X-Signature': 'fixture',
          'X-Custom-Token': 'fixture',
          'Referer': 'https://page.example.test/',
          'User-Agent': 'fixture-agent',
        },
      );
      final response = await local.get(b.uri);
      for (final uri in mediaUris(response.body)) {
        await local.get(uri);
      }
      expect(calls.first.headers['authorization'], 'Bearer fixture');
      expect(
        calls.firstWhere((r) => r.url.path == '/same.ts').headers['cookie'],
        'fixture=1',
      );
      for (final request in calls.where(
        (r) => ['/cross.ts', '/returned.ts'].contains(r.url.path),
      )) {
        for (final header in [
          'authorization',
          'cookie',
          'x-appid',
          'x-timestamp',
          'x-signature',
          'x-custom-token',
        ]) {
          expect(request.headers.containsKey(header), isFalse);
        }
        expect(request.headers['user-agent'], 'fixture-agent');
        expect(request.headers['referer'], 'https://page.example.test/');
      }
    },
  );

  test(
    'progressive Range streams more than probe limit with correct 206 headers',
    () async {
      final payload = List.generate(700 * 1024, (i) => i % 251);
      final b = await bridge((request) {
        expect(request.headers['range'], 'bytes=1024-');
        expect(
          request.headers['cookie'],
          isNull,
          reason: 'incoming credentials are never forwarded',
        );
        return http.Response.bytes(
          payload,
          206,
          headers: {
            'content-type': 'video/mp4',
            'content-range':
                'bytes 1024-${1023 + payload.length}/${payload.length + 1024}',
            'accept-ranges': 'bytes',
            'set-cookie': 'not-forwarded=1',
          },
        );
      }, source: Uri.parse('https://media.example.test/video.mp4'));
      final r = await local.get(
        b.uri,
        headers: {'Range': 'bytes=1024-', 'Cookie': 'local=secret'},
      );
      expect(r.statusCode, 206);
      expect(r.bodyBytes, payload);
      expect(r.headers['content-range'], startsWith('bytes 1024-'));
      expect(r.headers['content-length'], '${payload.length}');
      expect(r.headers['set-cookie'], isNull);
      expect(r.headers['cache-control'], 'no-store');
    },
  );

  test(
    'missing token, arbitrary URL, query, Origin and POST cannot reach upstream',
    () async {
      var calls = 0;
      final b = await bridge((_) {
        calls++;
        return http.Response('not reached', 200);
      });
      for (final u in [
        b.uri.replace(path: '/wrong/0'),
        b.uri.replace(query: 'url=https://other.example.test'),
      ]) {
        expect((await local.get(u)).statusCode, 404);
      }
      expect(
        (await local.get(
          b.uri,
          headers: {'Origin': 'https://evil.example.test'},
        )).statusCode,
        404,
      );
      expect((await local.post(b.uri)).statusCode, 404);
      expect(calls, 0);
    },
  );

  test(
    'private source, plaintext credentials and strict synthetic IP are rejected',
    () async {
      for (final u in [
        'http://127.0.0.1/a',
        'https://192.168.0.1/a',
        'https://localhost/a',
        'https://user:pass@example.test/a',
      ]) {
        await expectLater(
          NativeMediaBridge.start(Uri.parse(u)),
          throwsA(isA<NetworkSecurityException>()),
        );
      }
      await expectLater(
        NativeMediaBridge.start(
          Uri.parse('http://media.example.test/a'),
          headers: {'Authorization': 'fixture'},
        ),
        throwsA(isA<NetworkSecurityException>()),
      );
      await expectLater(
        NativeMediaBridge.start(
          Uri.parse('https://198.18.0.1/a'),
          publicHttpOnly: true,
        ),
        throwsA(isA<NetworkSecurityException>()),
      );
    },
  );

  test(
    'private playlist children and redirected targets cannot escape policy',
    () async {
      var count = 0;
      final b = await bridge((_) {
        count++;
        return http.Response(
          '#EXTM3U\n#EXTINF:2,\nhttp://127.0.0.1/private.ts\n',
          200,
        );
      });
      expect((await local.get(b.uri)).statusCode, 502);
      expect(count, 1);
      final redirect = await bridge(
        (_) => http.Response(
          '',
          302,
          headers: {'location': 'http://169.254.169.254/metadata'},
        ),
      );
      expect((await local.get(redirect.uri)).statusCode, 502);
    },
  );

  test('playlist bodies and redirect chains are bounded', () async {
    final b = await bridge(
      (_) => http.Response(
        '#EXTM3U\n${'x' * NativeMediaBridge.maxPlaylistBytes}',
        200,
      ),
    );
    expect((await local.get(b.uri)).statusCode, 502);
    var calls = 0;
    final redirect = await bridge((_) {
      calls++;
      return http.Response('', 302, headers: {'location': '/again'});
    });
    expect((await local.get(redirect.uri)).statusCode, 502);
    expect(calls, 6);
  });

  test(
    'HEAD, suffix byte range and unsatisfiable ranges preserve semantics',
    () async {
      final b = await bridge((request) {
        if (request.method == 'HEAD') {
          return http.Response('', 200, headers: {'content-type': 'video/mp4'});
        }
        expect(request.headers['range'], 'bytes=-50');
        return http.Response('', 416);
      }, source: Uri.parse('https://media.example.test/file'));
      expect((await local.head(b.uri)).statusCode, 200);
      expect(
        (await local.get(b.uri, headers: {'Range': 'bytes=-50'})).statusCode,
        416,
      );
      expect(
        (await local.get(
          b.uri,
          headers: {'Range': 'bytes=0-3,8-9'},
        )).statusCode,
        416,
      );
    },
  );

  test(
    'disposing aborts delayed responses and revokes old capabilities',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final b = await bridge((_) async {
        started.complete();
        await release.future;
        return http.Response('late', 200);
      });
      final pending = local
          .get(b.uri)
          .then<Object>((r) => r, onError: (Object e) => e);
      await started.future;
      await b.dispose().timeout(const Duration(seconds: 2));
      release.complete();
      await pending.timeout(const Duration(seconds: 2));
      await expectLater(local.get(b.uri), throwsA(isA<http.ClientException>()));
    },
  );

  test(
    'stream cancellation closes upstream without uncaught socket errors',
    () async {
      final bytes = StreamController<List<int>>();
      final cancelled = Completer<void>();
      bytes.onCancel = () => cancelled.complete();
      final b = await NativeMediaBridge.start(
        Uri.parse('https://media.example.test/video.mp4'),
        clientFactory: () => _StreamingClient(bytes.stream),
      );
      addTearDown(b.dispose);
      final opening = local.send(http.Request('GET', b.uri));
      bytes.add(List.filled(64, 1));
      final response = await opening;
      final reading = response.stream.listen((_) {}, onError: (Object _) {});
      await b.dispose().timeout(const Duration(seconds: 2));
      await cancelled.future.timeout(const Duration(seconds: 2));
      await reading.cancel();
      await bytes.close();
    },
  );
}

class _StreamingClient extends http.BaseClient {
  _StreamingClient(this.stream);
  final Stream<List<int>> stream;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(
        stream,
        200,
        request: request,
        headers: {'content-type': 'video/mp4'},
      );
}
