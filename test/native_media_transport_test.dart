import 'dart:async';
import 'dart:io';

import 'package:anime/src/core/network/media_request_headers.dart';
import 'package:anime/src/core/network/network_security.dart';
import 'package:anime/src/player/video/native_media_transport_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'native playback uses the verified transport without forwarding credentials to loopback',
    () async {
      final transport = NativeMediaTransport();
      addTearDown(transport.dispose);
      final media = await transport.prepare(
        'https://media.example.test/video.m3u8?token=fixture',
        format: 'HLS',
        headers: {'Authorization': 'Bearer fixture', 'Cookie': 'fixture'},
      );
      final local = Uri.parse(media.uri);
      expect(local.host, InternetAddress.loopbackIPv4.address);
      expect(local.scheme, 'http');
      expect(media.httpHeaders ?? {}, isEmpty);
      expect(local.toString(), isNot(contains('fixture')));
      await transport.dispose();
      final client = http.Client();
      addTearDown(client.close);
      await expectLater(
        client.get(local),
        throwsA(isA<http.ClientException>()),
      );
    },
    skip: !Platform.isAndroid && !Platform.isWindows,
  );

  test(
    'public non-HLS media, opted-out HLS, Origin-gated HLS and server-cleaned HLS play directly without loopback bridge',
    () async {
      final transport = NativeMediaTransport();
      addTearDown(transport.dispose);

      final mp4 = await transport.prepare(
        'https://cdn.example.test/video.mp4',
        format: 'MP4',
        headers: {'Referer': 'https://site.example.test/'},
      );
      expect(mp4.uri, 'https://cdn.example.test/video.mp4');
      expect(mp4.httpHeaders?['Referer'], 'https://site.example.test/');

      final optedOut = await transport.prepare(
        'https://cdn.example.test/video.m3u8',
        format: 'HLS',
        cleanHlsManifest: false,
        headers: {'Referer': 'https://site.example.test/'},
      );
      expect(optedOut.uri, 'https://cdn.example.test/video.m3u8');
      expect(optedOut.httpHeaders?['Referer'], 'https://site.example.test/');

      final originGated = await transport.prepare(
        'https://cdn.example.test/video.m3u8',
        format: 'HLS',
        headers: {
          'Referer': 'https://site.example.test/',
          'Origin': 'https://site.example.test',
        },
      );
      expect(originGated.uri, 'https://cdn.example.test/video.m3u8');
      expect(originGated.httpHeaders?['Origin'], 'https://site.example.test');

      final serverCleaned = await transport.prepare(
        'https://api.example.test/api/v3/playlist/token123',
        format: 'HLS',
        headers: {'Referer': 'https://site.example.test/'},
      );
      expect(
        serverCleaned.uri,
        'https://api.example.test/api/v3/playlist/token123',
      );
    },
  );

  test(
    'public HLS without credentials uses manifest-only loopback cleaner while forwarding safe headers for direct segments',
    () async {
      final transport = NativeMediaTransport();
      addTearDown(transport.dispose);
      final media = await transport.prepare(
        'https://cdn.example.test/video.m3u8',
        format: 'HLS',
        headers: {'Referer': 'https://site.example.test/'},
      );
      final local = Uri.parse(media.uri);
      expect(local.host, InternetAddress.loopbackIPv4.address);
      expect(local.scheme, 'http');
      expect(media.httpHeaders?['Referer'], 'https://site.example.test/');
      expect(media.httpHeaders?['User-Agent'], defaultMediaUserAgent);
      expect(media.httpHeaders?.containsKey('Origin'), isFalse);
      expect(media.httpHeaders?.containsKey('Cookie'), isFalse);
      expect(media.httpHeaders?.containsKey('Authorization'), isFalse);
    },
    skip: !Platform.isAndroid && !Platform.isWindows,
  );

  test('local files and DASH keep their existing native path', () async {
    final transport = NativeMediaTransport();
    addTearDown(transport.dispose);
    for (final resource in [
      'file:///offline/video.mp4',
      'https://media.example.test/video.mpd',
    ]) {
      final media = await transport.prepare(resource, headers: {});
      expect(
        media.uri,
        resource.startsWith('file:') ? '/offline/video.mp4' : resource,
      );
    }
  });

  test(
    'transport reports HTTP failure without media URLs or headers',
    () async {
      final failures = <Map<String, Object?>>[];
      final b = await NativeMediaBridge.start(
        Uri.parse('https://media.test/secret.m3u8?token=secret'),
        headers: {'Cookie': 'secret'},
        playlist: true,
        clientFactory: () =>
            MockClient((_) async => http.Response('denied', 403)),
        onFailure: (failure) => failures.add(failure.safeFields),
      );
      addTearDown(b.dispose);
      final client = http.Client();
      addTearDown(client.close);
      final response = await client.get(b.uri);
      expect(response.statusCode, 502);
      expect(failures, [
        {
          'reason_code': 'http',
          'resource_type': 'manifest',
          'http_status': 403,
        },
      ]);
      expect(failures.toString(), isNot(contains('secret')));
    },
  );

  test(
    'private original streams keep their range request and auth on the configured origin',
    () async {
      final origin = Uri.parse('https://library.local:8443/dav/');
      final requests = <Uri>[];
      final b = await NativeMediaBridge.start(
        origin.resolve('Movie.mp4'),
        privateLibraryOrigin: origin,
        headers: {'Authorization': 'Basic fixture'},
        clientFactory: () => MockClient((request) async {
          requests.add(request.url);
          expect(request.headers['authorization'], 'Basic fixture');
          expect(request.headers['range'], 'bytes=0-31');
          expect(request.followRedirects, isFalse);
          if (requests.length == 1) {
            return http.Response(
              '',
              302,
              headers: {'location': '/dav/target.mp4'},
            );
          }
          return http.Response(
            'original media bytes',
            206,
            headers: {'content-type': 'video/mp4'},
          );
        }),
      );
      addTearDown(b.dispose);
      final client = http.Client();
      addTearDown(client.close);
      final response = await client.get(
        b.uri,
        headers: {'Range': 'bytes=0-31'},
      );
      expect(response.statusCode, 206);
      expect(response.body, 'original media bytes');
      expect(requests, [
        origin.resolve('Movie.mp4'),
        origin.resolve('target.mp4'),
      ]);
    },
  );

  test(
    'private media follows public 302 CDN redirects without leaking auth and blocks SSRF redirects',
    () async {
      final origin = Uri.parse('http://192.168.1.10:5244/dav/');
      final cdnUrl = Uri.parse('https://cdn.cloud.example/signed-video.mkv');
      final requests = <http.BaseRequest>[];
      final b = await NativeMediaBridge.start(
        origin.resolve('Movie.mkv'),
        privateLibraryOrigin: origin,
        headers: {'Authorization': 'Basic fixture'},
        clientFactory: () => MockClient((request) async {
          requests.add(request);
          if (request.url == origin.resolve('Movie.mkv')) {
            expect(request.headers['authorization'], 'Basic fixture');
            return http.Response(
              '',
              302,
              headers: {'location': cdnUrl.toString()},
            );
          }
          expect(request.url, cdnUrl);
          expect(request.headers['authorization'], isNull);
          expect(request.headers['range'], 'bytes=0-15');
          return http.Response(
            'cloud 4k bytes!!',
            206,
            headers: {'content-type': 'video/x-matroska'},
          );
        }),
      );
      addTearDown(b.dispose);
      final client = http.Client();
      addTearDown(client.close);
      final response = await client.get(
        b.uri,
        headers: {'Range': 'bytes=0-15'},
      );
      expect(response.statusCode, 206);
      expect(response.body, 'cloud 4k bytes!!');
      expect(requests.map((r) => r.url), [origin.resolve('Movie.mkv'), cdnUrl]);

      // Cross-origin redirect to a private/SSRF host must still be blocked.
      final calls = <Uri>[];
      final failures = <Map<String, Object?>>[];
      final ssrfBridge = await NativeMediaBridge.start(
        origin.resolve('Videos/42/stream?static=true'),
        privateLibraryOrigin: origin,
        headers: {'X-Emby-Token': 'fixture'},
        clientFactory: () => MockClient((request) async {
          calls.add(request.url);
          return http.Response(
            '',
            302,
            headers: {'location': 'http://169.254.169.254/latest/meta-data'},
          );
        }),
        onFailure: (failure) => failures.add(failure.safeFields),
      );
      addTearDown(ssrfBridge.dispose);
      expect((await client.get(ssrfBridge.uri)).statusCode, 502);
      expect(calls, [origin.resolve('Videos/42/stream?static=true')]);
      expect(failures.single, {
        'reason_code': 'policy',
        'resource_type': 'media',
      });
      await expectLater(
        NativeMediaBridge.start(origin.resolve('Movie.mp4')),
        throwsA(isA<NetworkSecurityException>()),
      );

      final transport = NativeMediaTransport();
      addTearDown(transport.dispose);
      final media = await transport.prepare(
        origin.resolve('Movie.mp4').toString(),
        headers: {'X-Emby-Token': 'fixture'},
        privateLibraryOrigin: origin,
      );
      expect(Uri.parse(media.uri).host, '127.0.0.1');
      expect(media.httpHeaders ?? {}, isEmpty);
      expect(media.uri, isNot(contains('192.168.1.10')));
    },
  );

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
    'completed playlist and segment reads reuse an upstream connection lease',
    () async {
      final wires = <_TrackedClient>[];
      final b = await NativeMediaBridge.start(
        root,
        playlist: true,
        clientFactory: () {
          final wire = _TrackedClient(
            (request) async => request.url.path.endsWith('.m3u8')
                ? http.Response(
                    '#EXTM3U\n#EXTINF:2,\none.ts\n#EXTINF:2,\ntwo.ts\n',
                    200,
                  )
                : http.Response.bytes(List.filled(32, 7), 200),
          );
          wires.add(wire);
          return wire;
        },
      );
      addTearDown(b.dispose);
      final playlist = await local.get(b.uri);
      for (final uri in mediaUris(playlist.body)) {
        expect((await local.get(uri)).bodyBytes, List.filled(32, 7));
      }
      expect(
        wires,
        hasLength(1),
        reason: 'do not repeat DNS/TCP/TLS for every segment',
      );
      expect(wires.single.closed, isFalse);
      await b.dispose();
      expect(wires.single.closed, isTrue);
    },
  );

  test(
    'active transfers have separate leases and errors are never pooled',
    () async {
      final wires = <_TrackedClient>[];
      final entered = Completer<void>();
      final release = Completer<void>();
      var active = 0;
      final b = await NativeMediaBridge.start(
        root,
        clientFactory: () {
          final wire = _TrackedClient((request) async {
            if (request.url.path.endsWith('.m3u8')) {
              return http.Response(
                '#EXTM3U\n#EXTINF:2,\none.ts\n#EXTINF:2,\ntwo.ts\n#EXTINF:2,\nbad.ts\n',
                200,
              );
            }
            if (request.url.path == '/bad.ts') {
              return http.Response('failed', 503);
            }
            if (++active == 2) entered.complete();
            await release.future;
            return http.Response.bytes(List.filled(32, 8), 200);
          });
          wires.add(wire);
          return wire;
        },
      );
      addTearDown(b.dispose);
      final children = mediaUris((await local.get(b.uri)).body);
      final reads = [local.get(children[0]), local.get(children[1])];
      await entered.future.timeout(const Duration(seconds: 2));
      expect(wires, hasLength(2));
      release.complete();
      expect(
        (await Future.wait(reads)).every((r) => r.statusCode == 200),
        isTrue,
      );
      expect((await local.get(children[2])).statusCode, 502);
      await Future.any(
        wires.map((w) => w.onClosed.future),
      ).timeout(const Duration(seconds: 2));
      expect(wires.where((w) => w.closed), hasLength(1));
      await b.dispose();
      expect(wires.every((w) => w.closed), isTrue);
    },
  );

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
      final waitingForNextChunk = Completer<void>();
      bytes.onCancel = () => cancelled.complete();
      bytes.onResume = () {
        if (!waitingForNextChunk.isCompleted) waitingForNextChunk.complete();
      };
      final b = await NativeMediaBridge.start(
        Uri.parse('https://media.example.test/video.mp4'),
        clientFactory: () => _StreamingClient(bytes.stream),
      );
      addTearDown(b.dispose);
      final opening = local.send(http.Request('GET', b.uri));
      bytes.add(List.filled(64, 1));
      final response = await opening;
      final reading = response.stream.listen((_) {}, onError: (Object _) {});
      // Cancel after the relay asks for more data from a silent upstream,
      // not while its first chunk is still paused in the output buffer.
      await waitingForNextChunk.future.timeout(const Duration(seconds: 2));
      await b.dispose().timeout(const Duration(seconds: 2));
      await cancelled.future.timeout(const Duration(seconds: 2));
      await reading.cancel();
      await bytes.close();
    },
  );

  test(
    'manifest-only bridge cleans HLS ads while leaving media segments, keys and init maps as direct HTTPS URLs',
    () async {
      final upstreamRequests = <String>[];
      final mediaPlaylist = StringBuffer(
        '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:6\n'
        '#EXT-X-KEY:METHOD=AES-128,URI="enc.key"\n'
        '#EXT-X-MAP:URI="init.mp4"\n',
      );
      for (var i = 0; i < 12; i++) {
        mediaPlaylist.write('#EXTINF:4.000,\nseg${i.toString().padLeft(4, '0')}.ts\n');
      }
      mediaPlaylist.write('#EXT-X-DISCONTINUITY\n');
      for (var i = 0; i < 3; i++) {
        mediaPlaylist.write('#EXTINF:5.000,\n/ad/casino_$i.ts\n');
      }
      mediaPlaylist.write('#EXT-X-DISCONTINUITY\n');
      for (var i = 12; i < 24; i++) {
        mediaPlaylist.write('#EXTINF:4.000,\nseg${i.toString().padLeft(4, '0')}.ts\n');
      }
      mediaPlaylist.write('#EXT-X-ENDLIST\n');

      final b = await NativeMediaBridge.start(
        Uri.parse('https://cdn.example.test/202611/movie/index.m3u8'),
        manifestOnly: true,
        headers: {'Referer': 'https://site.example.test/'},
        clientFactory: () => MockClient((request) async {
          upstreamRequests.add(request.url.toString());
          if (request.url.path.endsWith('/index.m3u8')) {
            return http.Response(
              '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1920x1080\n'
              '2000k/hls/mixed.m3u8\n',
              200,
            );
          }
          if (request.url.path.endsWith('/mixed.m3u8')) {
            return http.Response(mediaPlaylist.toString(), 200);
          }
          fail('manifest-only bridge must never proxy media bytes: ${request.url}');
        }),
      );
      addTearDown(b.dispose);

      // 1. Master playlist rewrites variant .m3u8 through loopback.
      final masterResp = await local.get(
        b.uri,
        headers: {'Referer': 'https://site.example.test/'},
      );
      expect(masterResp.statusCode, 200);
      final variantLine = masterResp.body
          .split('\n')
          .map((l) => l.trim())
          .firstWhere((l) => l.isNotEmpty && !l.startsWith('#'));
      final variantUri = Uri.parse(variantLine);
      expect(variantUri.host, InternetAddress.loopbackIPv4.address);
      expect(variantUri.port, b.uri.port);

      // 2. Variant playlist strips mid-roll ad island and emits direct public HTTPS URLs.
      final mediaResp = await local.get(variantUri);
      expect(mediaResp.statusCode, 200);
      final body = mediaResp.body;
      expect(body, isNot(contains('casino_0.ts')));
      expect(body, contains('https://cdn.example.test/202611/movie/2000k/hls/seg0000.ts'));
      expect(body, contains('https://cdn.example.test/202611/movie/2000k/hls/seg0023.ts'));
      expect(body, contains('URI="https://cdn.example.test/202611/movie/2000k/hls/enc.key"'));
      expect(body, contains('URI="https://cdn.example.test/202611/movie/2000k/hls/init.mp4"'));
      expect(body, isNot(contains('127.0.0.1')));
      expect(upstreamRequests, [
        'https://cdn.example.test/202611/movie/index.m3u8',
        'https://cdn.example.test/202611/movie/2000k/hls/mixed.m3u8',
      ]);
    },
  );

  test(
    'manifest-only bridge rejects private segment SSRF and non-playlist binary responses',
    () async {
      final failures = <Map<String, Object?>>[];
      final ssrfBridge = await NativeMediaBridge.start(
        Uri.parse('https://cdn.example.test/evil.m3u8'),
        manifestOnly: true,
        clientFactory: () => MockClient(
          (_) async => http.Response(
            '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:6\n'
            '#EXTINF:6.0,\nhttp://127.0.0.1:8080/internal.ts\n#EXT-X-ENDLIST\n',
            200,
          ),
        ),
        onFailure: (f) => failures.add(f.safeFields),
      );
      addTearDown(ssrfBridge.dispose);
      final ssrfResp = await local.get(ssrfBridge.uri);
      expect(ssrfResp.statusCode, 502);
      expect(failures.last['reason_code'], 'policy');

      final binaryBridge = await NativeMediaBridge.start(
        Uri.parse('https://cdn.example.test/fake.m3u8'),
        manifestOnly: true,
        clientFactory: () => MockClient(
          (_) async => http.Response('NOT_A_PLAYLIST_BINARY_PAYLOAD', 200),
        ),
        onFailure: (f) => failures.add(f.safeFields),
      );
      addTearDown(binaryBridge.dispose);
      final binaryResp = await local.get(binaryBridge.uri);
      expect(binaryResp.statusCode, 502);
      expect(failures.last['reason_code'], 'manifest');
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

class _TrackedClient extends http.BaseClient {
  _TrackedClient(Future<http.Response> Function(http.Request) handler)
    : inner = MockClient(handler);
  final http.Client inner;
  bool closed = false;
  final onClosed = Completer<void>();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (closed) throw StateError('a retired connection lease was reused');
    return inner.send(request);
  }

  @override
  void close() {
    closed = true;
    if (!onClosed.isCompleted) onClosed.complete();
    inner.close();
  }
}
