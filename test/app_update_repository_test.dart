import 'dart:async';
import 'dart:convert';

import 'package:anime/src/updates/app_update_models.dart';
import 'package:anime/src/updates/app_update_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'app_update_models_test.dart' show feed;

void main() {
  test(
    'production v2 manifest uses exact names, hashes, ABIs, derived URLs',
    () async {
      final visited = <Uri>[];
      final manifest = productionManifest();
      final client = TrackingClient((request) async {
        visited.add(request.url);
        expect(request.followRedirects, isFalse);
        expect(
          request.headers.keys.any((k) => k.toLowerCase() == 'authorization'),
          isFalse,
        );
        if (request.url.host == 'api.github.com') {
          return jsonResponse(githubRelease(manifest));
        }
        return jsonResponse(manifest);
      });
      final value = await ReleaseAppUpdateRepository(
        clientFactory: () => client,
      ).check(UpdateCancellation());
      expect(value!.version, '1.3.1');
      expect(value.buildNumber, 87);
      expect(value.abis, ['arm64-v8a', 'armeabi-v7a', 'x86_64']);
      expect(
        value.apkUri.toString(),
        'https://github.com/fanyong07/Zeluna/releases/download/v1.3.1/Zeluna-v1.3.1-Android.apk',
      );
      expect(
        visited.last.toString(),
        'https://github.com/fanyong07/Zeluna/releases/download/v1.3.1/Zeluna-v1.3.1-manifest.json',
      );
      expect(client.closed, isTrue);
    },
  );

  test('GitHub 404, draft and prerelease mean no available update', () async {
    for (final kind in ['404', 'draft', 'prerelease']) {
      var count = 0;
      final client = TrackingClient((_) async {
        count++;
        final release = githubRelease(productionManifest());
        if (kind == '404') return http.Response('', 404);
        release[kind] = true;
        return jsonResponse(release);
      });
      expect(
        await ReleaseAppUpdateRepository(
          clientFactory: () => client,
        ).check(UpdateCancellation()),
        isNull,
      );
      expect(count, 1);
      expect(client.closed, isTrue);
    }
  });

  test(
    'tag, manifest schema/version/hash/bytes and duplicate assets are strict',
    () async {
      final edits = <void Function(Map<String, dynamic>, Map<String, dynamic>)>[
        (r, m) => r['tag_name'] = '1.3.1',
        (r, m) => r['tag_name'] = 'v1.3.1-beta',
        (r, m) => r['tag_name'] = 'v01.3.1',
        (r, m) => m['schema'] = 'zeluna-release-manifest-v1',
        (r, m) => m['version'] = '1.3.2+88',
        (r, m) => m['version'] = '1.3.1+0',
        (r, m) => m['version'] = '1.3.1+2147483648',
        (r, m) => m['artifacts'][0]['bytes'] = 133140678,
        (r, m) => m['artifacts'][0]['bytes'] = '133140679',
        (r, m) => m['artifacts'][0]['sha256'] = 'bad',
        (r, m) => m['artifacts'][0]['native_abis'] = [],
        (r, m) => m['artifacts'][0]['name'] = 'other.apk',
        (r, m) => (r['assets'] as List).add((r['assets'] as List).last),
      ];
      for (final edit in edits) {
        final manifest = productionManifest();
        final release = githubRelease(manifest);
        edit(release, manifest);
        release['assets'][0]['size'] = utf8.encode(jsonEncode(manifest)).length;
        final client = TrackingClient(
          (request) async => jsonResponse(
            request.url.host == 'api.github.com' ? release : manifest,
          ),
        );
        await expectLater(
          ReleaseAppUpdateRepository(
            clientFactory: () => client,
          ).check(UpdateCancellation()),
          throwsA(
            isA<UpdateFailure>().having(
              (e) => e.code,
              'code',
              'invalid_manifest',
            ),
          ),
        );
        expect(client.closed, isTrue);
      }
    },
  );

  test(
    'public HTTPS redirects are followed and every hop keeps policy',
    () async {
      for (final destination in [
        'https://cdn.example/feed.json',
        'http://cdn.example/feed.json',
        'https://127.0.0.1/feed.json',
        'https://198.18.0.1/feed.json',
        'https://name:secret@cdn.example/feed.json',
      ]) {
        final visited = <Uri>[];
        final client = TrackingClient((request) async {
          visited.add(request.url);
          expect(request.followRedirects, isFalse);
          if (visited.length == 1) {
            return http.Response('', 302, headers: {'location': destination});
          }
          return jsonResponse(feed());
        });
        final pending = ReleaseAppUpdateRepository(
          clientFactory: () => client,
          manifestUrl: 'https://feed.example/update.json',
        ).check(UpdateCancellation());
        if (destination == 'https://cdn.example/feed.json') {
          expect((await pending)!.version, '1.10.0');
          expect(visited, hasLength(2));
        } else {
          await expectLater(pending, throwsA(isA<UpdateFailure>()));
          expect(visited, hasLength(1));
        }
        expect(client.closed, isTrue);
      }
    },
  );

  test(
    'JSON is bounded and malformed response errors use fixed Chinese',
    () async {
      for (final body in ['{broken', '[]', 'x' * (appUpdateMaxJsonBytes + 1)]) {
        final client = TrackingClient((_) async => http.Response(body, 200));
        await expectLater(
          ReleaseAppUpdateRepository(
            clientFactory: () => client,
            manifestUrl: 'https://feed.example/update.json',
          ).check(UpdateCancellation()),
          throwsA(isA<UpdateFailure>()),
        );
        expect(client.closed, isTrue);
      }
    },
  );

  test(
    'late headers: cancellation promptly completes and closes client',
    () async {
      final pendingHeaders = Completer<http.StreamedResponse>();
      final requested = Completer<void>();
      final client = StreamClient((_) {
        requested.complete();
        return pendingHeaders.future;
      });
      final token = UpdateCancellation();
      final pending = ReleaseAppUpdateRepository(
        clientFactory: () => client,
      ).check(token);
      final assertion = expectLater(pending, throwsA(isA<UpdateCancelled>()));
      await requested.future;
      token.cancel();
      await assertion;
      expect(client.closed, isTrue);
      pendingHeaders.complete(
        http.StreamedResponse(Stream.value(utf8.encode('{}')), 200),
      );
    },
  );

  test(
    'silent body: total timeout aborts stream and returns fixed timeout',
    () async {
      var streamCancelled = false;
      final stream = StreamController<List<int>>(
        onCancel: () {
          streamCancelled = true;
        },
      );
      final client = StreamClient(
        (_) async => http.StreamedResponse(stream.stream, 200),
      );
      await expectLater(
        ReleaseAppUpdateRepository(
          clientFactory: () => client,
          checkTimeout: const Duration(milliseconds: 30),
        ).check(UpdateCancellation()),
        throwsA(
          isA<UpdateFailure>().having((e) => e.code, 'code', 'check_timeout'),
        ),
      );
      expect(client.closed, isTrue);
      expect(streamCancelled, isTrue);
      await stream.close();
    },
  );

  test(
    '403/429 fallback follows fixed latest HEAD and exact manifest only',
    () async {
      for (final status in [403, 429]) {
        final visited = <String>[];
        final client = TrackingClient((request) async {
          visited.add('${request.method} ${request.url}');
          expect(request.followRedirects, isFalse);
          if (request.url.host == 'api.github.com') {
            return http.Response('', status);
          }
          if (request.url.path.endsWith('/latest')) {
            expect(request.method, 'HEAD');
            return http.Response(
              '',
              302,
              headers: {
                'location':
                    'https://github.com/fanyong07/Zeluna/releases/tag/v1.3.1',
              },
            );
          }
          if (request.url.path.contains('/tag/')) {
            expect(request.method, 'HEAD');
            return http.Response('', 200);
          }
          return jsonResponse(productionManifest());
        });
        final value = await ReleaseAppUpdateRepository(
          clientFactory: () => client,
        ).check(UpdateCancellation());
        expect(value!.version, '1.3.1');
        expect(value.buildNumber, 87);
        expect(value.bytes, 133140679);
        expect(value.notes, '更新内容请参阅发布说明');
        expect(visited, hasLength(4));
        expect(client.closed, isTrue);
      }
    },
  );

  test(
    'fallback rejects cross-host/repository, HTTP, malformed tag before next hop',
    () async {
      for (final location in [
        'https://evil.example/fanyong07/Zeluna/releases/tag/v1.3.1',
        'http://github.com/fanyong07/Zeluna/releases/tag/v1.3.1',
        'https://github.com/other/Zeluna/releases/tag/v1.3.1',
        'https://github.com/fanyong07/Zeluna/releases/tag/v1.3.1-rc1',
        'https://github.com/fanyong07/Zeluna/releases/tag/v1.3.1?redirect=1',
        'https://127.0.0.1/fanyong07/Zeluna/releases/tag/v1.3.1',
      ]) {
        var requests = 0;
        final client = TrackingClient((request) async {
          requests++;
          if (requests == 1) return http.Response('', 403);
          return http.Response('', 302, headers: {'location': location});
        });
        await expectLater(
          ReleaseAppUpdateRepository(
            clientFactory: () => client,
          ).check(UpdateCancellation()),
          throwsA(isA<UpdateFailure>()),
        );
        expect(requests, 2);
        expect(client.closed, isTrue);
      }
    },
  );

  test(
    'custom feeds and overridden API endpoints never take GitHub fallback',
    () async {
      for (final custom in [false, true]) {
        var requests = 0;
        final client = TrackingClient((_) async {
          requests++;
          return http.Response('', 403);
        });
        await expectLater(
          ReleaseAppUpdateRepository(
            clientFactory: () => client,
            manifestUrl: custom ? 'https://feed.example/update.json' : '',
            endpoint: Uri.parse('https://api.example/latest'),
          ).check(UpdateCancellation()),
          throwsA(isA<UpdateFailure>()),
        );
        expect(requests, 1);
      }
    },
  );

  test(
    'fallback silent HEAD obeys shared check budget and closes client',
    () async {
      var requests = 0;
      final late = Completer<http.StreamedResponse>();
      final client = StreamClient((_) async {
        if (++requests == 1) {
          return http.StreamedResponse(const Stream.empty(), 429);
        }
        return late.future;
      });
      await expectLater(
        ReleaseAppUpdateRepository(
          clientFactory: () => client,
          checkTimeout: const Duration(milliseconds: 30),
        ).check(UpdateCancellation()),
        throwsA(
          isA<UpdateFailure>().having((e) => e.code, 'code', 'check_timeout'),
        ),
      );
      expect(client.closed, isTrue);
      late.complete(http.StreamedResponse(const Stream.empty(), 200));
    },
  );

  test('each check gets a fresh client and notes are bounded', () async {
    final clients = <TrackingClient>[];
    final manifest = productionManifest();
    final release = githubRelease(manifest)..['body'] = 'x' * 21000;
    final repo = ReleaseAppUpdateRepository(
      clientFactory: () {
        final client = TrackingClient(
          (r) async =>
              jsonResponse(r.url.host == 'api.github.com' ? release : manifest),
        );
        clients.add(client);
        return client;
      },
    );
    expect((await repo.check(UpdateCancellation()))!.notes.length, 20000);
    await repo.check(UpdateCancellation());
    expect(clients, hasLength(2));
    expect(clients.every((c) => c.closed), isTrue);
  });
}

Map<String, dynamic> productionManifest() => {
  'schema': 'zeluna-release-manifest-v2',
  'version': '1.3.1+87',
  'git_sha': '769ee519ada04cf62971a07794119c8be300fe52',
  'artifacts': [
    {
      'name': 'Zeluna-v1.3.1-Android.apk',
      'bytes': 133140679,
      'sha256':
          'ba6701b8fcb46a4e99d8ccd442c1e0a12408efc8a44cbe8dfa28eb6591efe4eb',
      'native_abis': ['arm64-v8a', 'armeabi-v7a', 'x86_64'],
    },
  ],
};

Map<String, dynamic> githubRelease(Map<String, dynamic> manifest) => {
  'tag_name': 'v1.3.1',
  'draft': false,
  'prerelease': false,
  'body': '发行说明',
  'assets': [
    {
      'name': 'Zeluna-v1.3.1-manifest.json',
      'size': utf8.encode(jsonEncode(manifest)).length,
      'browser_download_url': 'https://127.0.0.1/ignored',
    },
    {
      'name': 'Zeluna-v1.3.1-Android.apk',
      'size': 133140679,
      'browser_download_url': 'https://127.0.0.1/ignored',
    },
  ],
};

http.Response jsonResponse(Object value) => http.Response(
  jsonEncode(value),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

class TrackingClient extends MockClient {
  TrackingClient(super.handler);
  bool closed = false;
  @override
  void close() {
    closed = true;
    super.close();
  }
}

class StreamClient extends http.BaseClient {
  StreamClient(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
  @override
  void close() {
    closed = true;
  }
}
