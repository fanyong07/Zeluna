import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/rules/rule_importer.dart';
import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/rules/rule_playback_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('Kazumi resolver extracts current episode playable url', () async {
    var playPageRequests = 0;
    var probeRequests = 0;
    final client = MockClient((request) async {
      expect(request.headers['Cookie'], 'session=user-value');
      expect(request.headers['Authorization'], 'Bearer user-value');
      switch (request.url.path) {
        case '/test/01.m3u8':
          expect(request.headers['Range'], 'bytes=0-2048');
          probeRequests++;
          return http.Response('#EXTM3U', 200);
        case '/vod/search.html':
          return _html('''
            <div class="item">
              <strong>测试番剧</strong>
              <a class="detail" href="/detail/test.html">详情</a>
            </div>
          ''');
        case '/detail/test.html':
          return _html('''
            <ul class="line"><li><a href="/play/1.html">第1集</a></li></ul>
            <ul class="line"><li><a href="/play/1.html">备用1</a></li></ul>
          ''');
        case '/play/1.html':
          playPageRequests++;
          return _html('''
            <script>
              var player_aaaa={"flag":"play","encrypt":0,"url":"https://cdn.example.com/test/01.m3u8"};
            </script>
          ''');
      }
      return http.Response('not found', 404);
    });

    final resolver = RulePlaybackResolver(client: client);
    final quickLines = await resolver.resolveRule(
      rule: _kazumiRule,
      subject: _animeSubject,
      episode: _episode,
      verifyPlayable: false,
    );

    expect(quickLines, hasLength(2));
    expect(quickLines.every((line) => line.available), isTrue);
    expect(playPageRequests, 1);
    expect(probeRequests, 0);

    final lines = await resolver.resolveRule(
      rule: _kazumiRule,
      subject: _animeSubject,
      episode: _episode,
    );

    expect(lines, hasLength(2));
    expect(lines.first.available, isTrue);
    expect(lines.first.url, 'https://cdn.example.com/test/01.m3u8');
    expect(lines.first.format, 'HLS');
    expect(lines.first.sizeLabel, '动态流');
    expect(lines.first.isLive, isTrue);
    expect(playPageRequests, 1);
    expect(probeRequests, 1);

    final cachedLines = await resolver.resolveRule(
      rule: _kazumiRule,
      subject: _animeSubject,
      episode: _episode,
    );

    expect(cachedLines, hasLength(2));
    expect(playPageRequests, 1);
    expect(probeRequests, 1);
  });

  test('verified dead line replaces its optimistic quick result', () async {
    final client = MockClient((request) async {
      switch (request.url.path) {
        case '/vod/search.html':
          return _html('''
            <div class="item">
              <strong>测试番剧</strong>
              <a class="detail" href="/detail/dead.html">详情</a>
            </div>
          ''');
        case '/detail/dead.html':
          return _html('''
            <ul class="line"><li><a href="/play/dead.html">第1集</a></li></ul>
          ''');
        case '/play/dead.html':
          return _html('''
            <script>
              var player={"url":"https://cdn.example.com/dead.m3u8"};
            </script>
          ''');
        case '/dead.m3u8':
          return http.Response('gone', 404);
      }
      return http.Response('not found', 404);
    });
    final resolver = RulePlaybackResolver(client: client);

    final quick = await resolver.resolveRule(
      rule: _kazumiRule,
      subject: _animeSubject,
      episode: _episode,
      verifyPlayable: false,
    );
    final verified = await resolver.resolveRule(
      rule: _kazumiRule,
      subject: _animeSubject,
      episode: _episode,
    );

    expect(quick.single.available, isTrue);
    expect(verified.single.available, isFalse);
    expect(verified.single.id, quick.single.id);
  });

  test('web media proxy keeps child URI and forwards protected headers', () {
    final base = Uri.parse('http://127.0.0.1:5174/');
    final upstream = Uri.parse('https://cdn.example.com/master.m3u8');
    final proxy = ruleRequestUriForWebTest(upstream, base);
    final childProxy = base.resolve(
      '/media-proxy?url=${Uri.encodeQueryComponent('https://cdn.example.com/child.m3u8')}',
    );

    expect(proxy.path, '/media-proxy');
    expect(proxy.queryParameters['url'], upstream.toString());
    expect(ruleRequestUriForWebTest(childProxy, base), childProxy);

    final headers = ruleRequestHeadersForWebTest(childProxy, const {
      'user-agent': 'Fixture Agent',
      'Referer': 'https://source.example/watch',
      'authorization': 'Bearer secret',
      'Cookie': 'sid=secret',
      'Range': 'bytes=0-524287',
    }, base);
    expect(headers['X-Upstream-User-Agent'], 'Fixture Agent');
    expect(headers['X-Upstream-Referer'], 'https://source.example/watch');
    expect(headers['X-Upstream-Authorization'], 'Bearer secret');
    expect(headers['X-Upstream-Cookie'], 'sid=secret');
    expect(headers['Range'], 'bytes=0-524287');
    expect(headers, isNot(contains('Cookie')));
    expect(headers, isNot(contains('authorization')));
  });

  test('Kazumi probes independent playback lines concurrently', () async {
    final bothProbesStarted = Completer<void>();
    var probeRequests = 0;
    final client = MockClient((request) async {
      switch (request.url.path) {
        case '/vod/search.html':
          return _html('''
            <div class="item">
              <strong>测试番剧</strong>
              <a class="detail" href="/detail/parallel.html">详情</a>
            </div>
          ''');
        case '/detail/parallel.html':
          return _html('''
            <ul class="line"><li><a href="/play/a.html">第1集</a></li></ul>
            <ul class="line"><li><a href="/play/b.html">第1集</a></li></ul>
          ''');
        case '/play/a.html':
          return _html('''
            <script>var player={"url":"https://cdn.example.com/a.m3u8"};</script>
          ''');
        case '/play/b.html':
          return _html('''
            <script>var player={"url":"https://cdn.example.com/b.m3u8"};</script>
          ''');
        case '/a.m3u8':
        case '/b.m3u8':
          probeRequests++;
          if (probeRequests == 2) bothProbesStarted.complete();
          await bothProbesStarted.future.timeout(const Duration(seconds: 1));
          return http.Response('#EXTM3U', 200);
      }
      return http.Response('not found', 404);
    });

    final lines = await RulePlaybackResolver(
      client: client,
    ).resolveRule(rule: _kazumiRule, subject: _animeSubject, episode: _episode);

    expect(lines, hasLength(2));
    expect(lines.every((line) => line.available), isTrue);
    expect(probeRequests, 2);
  });

  test(
    'initial playable probes are limited to four concurrent requests',
    () async {
      final firstWaveStarted = Completer<void>();
      final releaseFirstWave = Completer<void>();
      var started = 0;
      var active = 0;
      var maxActive = 0;
      final client = MockClient((request) async {
        if (request.url.path == '/vod/search.html') {
          return _html('''
          <div class="item">
            <strong>测试番剧</strong>
            <a class="detail" href="/detail/limited.html">详情</a>
          </div>
        ''');
        }
        if (request.url.path == '/detail/limited.html') {
          return _html(
            List.generate(
              5,
              (index) =>
                  '<ul class="line"><li><a href="/play/$index.html">第1集</a></li></ul>',
            ).join(),
          );
        }
        if (request.url.path.startsWith('/play/')) {
          final index = request.url.pathSegments[1].split('.').first;
          return _html('''
          <script>var player={"url":"https://cdn.example.com/probe-$index.mp4"};</script>
        ''');
        }
        if (request.url.path.startsWith('/probe-')) {
          expect(request.headers['Range'], 'bytes=0-2048');
          started++;
          active++;
          if (active > maxActive) maxActive = active;
          if (started == 4) firstWaveStarted.complete();
          await releaseFirstWave.future;
          active--;
          return http.Response(
            'video',
            200,
            headers: {'content-type': 'video/mp4'},
          );
        }
        return http.Response('not found', 404);
      });

      final resolving = RulePlaybackResolver(client: client).resolveRule(
        rule: _kazumiRule,
        subject: _animeSubject,
        episode: _episode,
      );
      await firstWaveStarted.future.timeout(const Duration(seconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(started, 4);
      releaseFirstWave.complete();

      final lines = await resolving;
      expect(lines, hasLength(5));
      expect(lines.every((line) => line.available), isTrue);
      expect(started, 5);
      expect(maxActive, 4);
    },
  );

  test('playable probe reads only the first ranged response chunk', () async {
    final client = _StreamingProbeClient();

    final lines = await RulePlaybackResolver(
      client: client,
    ).resolveRule(rule: _kazumiRule, subject: _animeSubject, episode: _episode);

    expect(lines, hasLength(1));
    expect(lines.single.available, isTrue);
    expect(client.probeRange, 'bytes=0-2048');
    expect(client.probeStreamCancelled, isTrue);
  });

  test('single-file probe reads real size and MP4 resolution', () async {
    final sample = _mp4TkhdSample(width: 1920, height: 1080);
    final line = await _resolveSinglePlayableLine(
      'https://cdn.example.com/video.mp4',
      probe: (request) {
        expect(request.headers['Range'], 'bytes=0-2048');
        return http.Response.bytes(
          sample,
          206,
          headers: {
            'content-type': 'video/mp4',
            'content-range': 'bytes 0-65535/52428800',
            'content-length': '${sample.length}',
          },
        );
      },
    );

    expect(line.available, isTrue);
    expect(line.latency, isNotNull);
    expect(line.format, 'MP4');
    expect(line.sizeBytes, 50 * 1024 * 1024);
    expect(line.sizeLabel, '50.0 MB');
    expect(line.videoWidth, 1920);
    expect(line.videoHeight, 1080);
    expect(line.quality, '1080P');
  });

  test('single-file probe falls back to 200 Content-Length', () async {
    final line = await _resolveSinglePlayableLine(
      'https://cdn.example.com/video.webm',
      probe: (request) => http.Response.bytes(
        const [0x1A, 0x45, 0xDF, 0xA3],
        200,
        headers: {
          'content-type': 'video/webm',
          'content-length': '${10 * 1024 * 1024}',
        },
      ),
    );

    expect(line.available, isTrue);
    expect(line.format, 'WebM');
    expect(line.sizeBytes, 10 * 1024 * 1024);
    expect(line.sizeLabel, '10.0 MB');
  });

  test(
    'HLS master exposes highest resolution and estimated VOD size',
    () async {
      final line = await _resolveSinglePlayableLine(
        'https://cdn.example.com/master.m3u8',
        probe: (request) {
          if (request.url.path == '/master.m3u8') {
            return http.Response(
              '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=1200000,RESOLUTION=854x480,CODECS="avc1.4d401f,mp4a.40.2"
480/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=5000000,AVERAGE-BANDWIDTH=4000000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2"
/media-proxy?url=https%3A%2F%2Fcdn.example.com%2F1080%2Findex.m3u8&referer=https%3A%2F%2Fexample.com%2F
''',
              200,
              headers: {'content-type': 'application/vnd.apple.mpegurl'},
            );
          }
          expect(request.url.path, '/1080/index.m3u8');
          expect(request.headers['Range'], 'bytes=0-524287');
          return http.Response(
            '''
#EXTM3U
#EXT-X-TARGETDURATION:10
#EXTINF:10.0,
segment-1.ts
#EXTINF:10.0,
segment-2.ts
#EXT-X-ENDLIST
''',
            200,
            headers: {'content-type': 'application/vnd.apple.mpegurl'},
          );
        },
      );

      expect(line.available, isTrue);
      expect(line.format, 'HLS');
      expect(line.videoWidth, 1920);
      expect(line.videoHeight, 1080);
      expect(line.quality, '1080P');
      expect(line.adaptive, isTrue);
      expect(line.isLive, isFalse);
      expect(line.bitrate, 4000000);
      expect(line.codecs, 'avc1.640028,mp4a.40.2');
      expect(line.sizeEstimated, isTrue);
      expect(line.sizeBytes, 10000000);
      expect(line.sizeLabel, '约 9.5 MB');
    },
  );

  test('HLS metadata timeout keeps the confirmed playable line', () async {
    final never = Completer<http.Response>();
    final stopwatch = Stopwatch()..start();
    final line = await _resolveSinglePlayableLine(
      'https://cdn.example.com/slow-master.m3u8',
      probe: (request) {
        if (request.url.path == '/slow-master.m3u8') {
          return http.Response(
            '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2"
slow-variant.m3u8
''',
            200,
            headers: {'content-type': 'application/vnd.apple.mpegurl'},
          );
        }
        expect(request.url.path, '/slow-variant.m3u8');
        return never.future;
      },
    );
    stopwatch.stop();

    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 3)));
    expect(line.available, isTrue);
    expect(line.videoWidth, 1920);
    expect(line.videoHeight, 1080);
    expect(line.bitrate, 5000000);
    expect(line.sizeBytes, isNull);
  });

  test(
    'malformed optional HLS metadata keeps a confirmed playable line',
    () async {
      final line = await _resolveSinglePlayableLine(
        'https://cdn.example.com/malformed-master.m3u8',
        probe: (request) => http.Response(
          '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
http://[
''',
          200,
          headers: {'content-type': 'application/vnd.apple.mpegurl'},
        ),
      );

      expect(line.available, isTrue);
      expect(line.format, 'HLS');
    },
  );

  test('cross-origin HLS children do not inherit source credentials', () async {
    final requestedHosts = <String>[];
    final line = await _resolveSinglePlayableLine(
      'https://cdn.example.com/protected/master.m3u8',
      probe: (request) {
        requestedHosts.add(request.url.host);
        switch (request.url.host) {
          case 'cdn.example.com':
            expect(request.headers['Cookie'], 'session=user-value');
            expect(request.headers['Authorization'], 'Bearer user-value');
            expect(request.headers['Range'], 'bytes=0-2048');
            return http.Response(
              '''
#EXTM3U
#EXT-X-STREAM-INF:RESOLUTION=1920x1080
https://variants.example.net/media.m3u8
''',
              200,
              headers: {'content-type': 'application/vnd.apple.mpegurl'},
            );
          case 'variants.example.net':
            expect(request.headers, isNot(contains('Cookie')));
            expect(request.headers, isNot(contains('Authorization')));
            expect(request.headers['Range'], 'bytes=0-524287');
            return http.Response(
              '''
#EXTM3U
#EXTINF:10.0,
https://segments.example.org/segment.ts
#EXT-X-ENDLIST
''',
              200,
              headers: {'content-type': 'application/vnd.apple.mpegurl'},
            );
          case 'segments.example.org':
            expect(request.headers, isNot(contains('Cookie')));
            expect(request.headers, isNot(contains('Authorization')));
            expect(request.headers['Range'], 'bytes=0-2048');
            return http.Response.bytes(
              const [0x47, 0x40, 0x00, 0x10],
              206,
              headers: {'content-range': 'bytes 0-2048/1048576'},
            );
        }
        return http.Response('not found', 404);
      },
    );

    expect(line.available, isTrue);
    expect(
      requestedHosts,
      containsAll(<String>[
        'cdn.example.com',
        'variants.example.net',
        'segments.example.org',
      ]),
    );
  });

  test('chunked HLS manifests are read through EOF without length', () async {
    final lines = await RulePlaybackResolver(
      client: _ChunkedPlaylistProbeClient(),
    ).resolveRule(rule: _kazumiRule, subject: _animeSubject, episode: _episode);

    expect(lines, hasLength(1));
    final line = lines.single;
    expect(line.available, isTrue);
    expect(line.videoWidth, 1920);
    expect(line.videoHeight, 1080);
    expect(line.isLive, isFalse);
    expect(line.sizeEstimated, isTrue);
    expect(line.sizeBytes, 10000000);
  });

  test('HLS VOD reads an end marker beyond the first 64 KB', () async {
    final padding = List.generate(
      9000,
      (index) => '# manifest padding $index',
    ).join('\n');
    final manifest =
        '''
#EXTM3U
$padding
#EXTINF:10.0,
segment-1.ts
#EXTINF:10.0,
segment-2.ts
#EXT-X-ENDLIST
''';
    final manifestBytes = utf8.encode(manifest);
    var manifestRequests = 0;
    final line = await _resolveSinglePlayableLine(
      'https://cdn.example.com/long-media.m3u8',
      probe: (request) {
        if (request.url.path == '/long-media.m3u8') {
          manifestRequests++;
          if (request.headers['Range'] == 'bytes=0-2048') {
            return http.Response.bytes(
              manifestBytes.take(2049).toList(growable: false),
              206,
              headers: {
                'content-type': 'application/vnd.apple.mpegurl',
                'content-range': 'bytes 0-2048/${manifestBytes.length}',
              },
            );
          }
          expect(request.headers['Range'], 'bytes=0-524287');
          return http.Response.bytes(
            manifestBytes,
            206,
            headers: {
              'content-type': 'application/vnd.apple.mpegurl',
              'content-range':
                  'bytes 0-${manifestBytes.length - 1}/${manifestBytes.length}',
            },
          );
        }
        expect(request.url.path, '/segment-1.ts');
        expect(request.headers['Range'], 'bytes=0-2048');
        return http.Response.bytes(
          const [0x47, 0x40, 0x00, 0x10],
          206,
          headers: {
            'content-type': 'video/mp2t',
            'content-range': 'bytes 0-524287/5242880',
          },
        );
      },
    );

    expect(line.available, isTrue);
    expect(line.isLive, isFalse);
    expect(line.sizeEstimated, isTrue);
    expect(line.sizeBytes, 10 * 1024 * 1024);
    expect(manifestRequests, 2);
  });

  test('HLS media playlist estimates size from one segment', () async {
    final line = await _resolveSinglePlayableLine(
      'https://cdn.example.com/media.m3u8',
      probe: (request) {
        if (request.url.path == '/media.m3u8') {
          return http.Response(
            '''
#EXTM3U
#EXT-X-TARGETDURATION:10
#EXTINF:10.0,
segment-1.ts
#EXTINF:10.0,
segment-2.ts
#EXT-X-ENDLIST
''',
            200,
            headers: {'content-type': 'application/vnd.apple.mpegurl'},
          );
        }
        expect(request.url.path, '/segment-1.ts');
        return http.Response.bytes(
          const [0x47, 0x40, 0x00, 0x10],
          206,
          headers: {
            'content-type': 'video/mp2t',
            'content-range': 'bytes 0-65535/5242880',
          },
        );
      },
    );

    expect(line.available, isTrue);
    expect(line.format, 'HLS');
    expect(line.isLive, isFalse);
    expect(line.sizeEstimated, isTrue);
    expect(line.sizeBytes, 10 * 1024 * 1024);
    expect(line.sizeLabel, '约 10.0 MB');
  });

  test(
    'mixed HLS byte ranges are not reported as an exact total size',
    () async {
      final line = await _resolveSinglePlayableLine(
        'https://cdn.example.com/mixed-ranges.m3u8',
        probe: (request) {
          if (request.url.path == '/mixed-ranges.m3u8') {
            return http.Response(
              '''
#EXTM3U
#EXTINF:10.0,
#EXT-X-BYTERANGE:1024@0
shared.ts
#EXTINF:10.0,
standalone.ts
#EXT-X-ENDLIST
''',
              200,
              headers: {'content-type': 'application/vnd.apple.mpegurl'},
            );
          }
          return http.Response('metadata unavailable', 404);
        },
      );

      expect(line.available, isTrue);
      expect(line.sizeBytes, isNull);
      expect(line.sizeEstimated, isFalse);
      expect(line.sizeLabel, isNull);
    },
  );

  test('static DASH manifest exposes resolution and estimated size', () async {
    final line = await _resolveSinglePlayableLine(
      'https://cdn.example.com/video.mpd',
      probe: (request) => http.Response(
        '''
<MPD type="static" mediaPresentationDuration="PT60S">
  <Period>
    <AdaptationSet contentType="video" mimeType="video/mp4">
      <Representation width="1280" height="720" bandwidth="3000000" codecs="avc1.4d401f" />
      <Representation width="1920" height="1080" bandwidth="8000000" codecs="hev1.1.6.L120" />
    </AdaptationSet>
    <AdaptationSet contentType="audio" mimeType="audio/mp4">
      <Representation bandwidth="128000" codecs="mp4a.40.2" />
    </AdaptationSet>
  </Period>
</MPD>
''',
        200,
        headers: {'content-type': 'application/dash+xml'},
      ),
    );

    expect(line.available, isTrue);
    expect(line.format, 'DASH');
    expect(line.videoWidth, 1920);
    expect(line.videoHeight, 1080);
    expect(line.quality, '1080P');
    expect(line.adaptive, isTrue);
    expect(line.bitrate, 8128000);
    expect(line.codecs, 'hev1.1.6.L120,mp4a.40.2');
    expect(line.sizeEstimated, isTrue);
    expect(line.sizeBytes, 60960000);
    expect(line.sizeLabel, '约 58.1 MB');
  });

  test(
    'equivalent keywords are de-duplicated and unrelated hits exit early',
    () async {
      var searchRequests = 0;
      final client = MockClient((request) async {
        if (request.url.path == '/vod/search.html') {
          searchRequests++;
          return _html('''
            <div class="item">
              <strong>ZZZZ</strong>
              <a class="detail" href="/detail/unrelated.html">详情</a>
            </div>
          ''');
        }
        fail('Unrelated search result should not request ${request.url.path}');
      });

      final lines = await RulePlaybackResolver(client: client).resolveRule(
        rule: _kazumiRule,
        subject: _equivalentTitleSubject,
        episode: _episode,
      );

      expect(lines, hasLength(1));
      expect(lines.single.available, isFalse);
      expect(searchRequests, 1);
    },
  );

  test('distinct fallback keywords search concurrently on failure', () async {
    final bothSearchesStarted = Completer<void>();
    var searchRequests = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/vod/search.html') {
        searchRequests++;
        if (searchRequests == 2) bothSearchesStarted.complete();
        await bothSearchesStarted.future.timeout(const Duration(seconds: 1));
        return _html('<div class="empty"></div>');
      }
      return http.Response('not found', 404);
    });

    final lines = await RulePlaybackResolver(
      client: client,
    ).resolveRule(rule: _kazumiRule, subject: _animeSubject, episode: _episode);

    expect(lines, hasLength(1));
    expect(lines.single.available, isFalse);
    expect(searchRequests, 2);
  });

  test('XBPQ resolver extracts current episode playable url', () async {
    final client = MockClient((request) async {
      switch (request.url.path) {
        case '/movie.mp4':
          return http.Response('video', 200);
        case '/search.html':
          return _html('''
            <div class="module-item-pic">
              <a href="/movie/test.html" title="测试电影">测试电影</a>
            </div>
          ''');
        case '/movie/test.html':
          return _html('''
            <div class="scroll-content">
              <a href="/play/movie-1.html"><span>正片</span></a>
            </div>
          ''');
        case '/play/movie-1.html':
          return _html('''
            <script>
              var player_aaaa={"flag":"play","encrypt":0,"url":"https://cdn.example.com/movie.mp4"};
            </script>
          ''');
      }
      return http.Response('not found', 404);
    });

    final resolver = RulePlaybackResolver(client: client);
    final lines = await resolver.resolveRule(
      rule: _xbpqRule,
      subject: _movieSubject,
      episode: _movieEpisode,
    );

    expect(lines, hasLength(1));
    expect(lines.single.available, isTrue);
    expect(lines.single.url, 'https://cdn.example.com/movie.mp4');
    expect(lines.single.providerId, _xbpqRule.id);
  });

  test('captcha and js rules return explicit unsupported line', () async {
    final resolver = RulePlaybackResolver(
      client: MockClient((_) async => http.Response('', 200)),
    );
    final lines = await resolver.resolveRule(
      rule: _captchaRule,
      subject: _animeSubject,
      episode: _episode,
    );

    expect(lines, hasLength(1));
    expect(lines.single.available, isFalse);
    expect(lines.single.message, contains('验证码'));
  });

  test(
    'Animeko importer marks rss as unsupported and web selector playable',
    () {
      final bundle = const RuleImporter().importFromText('''
      {
        "exportedMediaSourceDataList": {
          "mediaSources": [
            {
              "factoryId": "rss",
              "version": 2,
              "arguments": {
                "name": "AnimeGarden",
                "tier": 9,
                "description": "BT 资源聚合站",
                "searchConfig": {
                  "searchUrl": "https://garden.example/feed.xml?q={keyword}"
                }
              }
            },
            {
              "factoryId": "web-selector",
              "version": 2,
              "arguments": {
                "name": "在线源",
                "tier": 2,
                "searchConfig": {
                  "searchUrl": "https://example.com/search?wd={keyword}",
                  "subjectFormatId": "a",
                  "selectorSubjectFormatA": {"selectLists": ".result a"},
                  "channelFormatId": "index-grouped",
                  "selectorChannelFormatFlattened": {
                    "selectEpisodeLists": ".playlist",
                    "selectEpisodesFromList": "a",
                    "matchEpisodeSortFromName": "(?<ep>\\\\d+)"
                  },
                  "defaultResolution": "1080P",
                  "matchVideo": {
                    "enableNestedUrl": false,
                    "matchNestedUrl": "never-match",
                    "matchVideoUrl": "url=(?<v>https?:\\\\/\\\\/.+\\\\.(m3u8|mp4))",
                    "cookies": "quality=1080",
                    "addHeadersToVideo": {"referer": ""}
                  }
                }
              }
            }
          ]
        }
      }
    ''');

      expect(bundle.rules, hasLength(2));
      final rss = bundle.rules.firstWhere(
        (rule) => rule.engine == 'animeko-rss',
      );
      final web = bundle.rules.firstWhere(
        (rule) => rule.engine == 'animeko-web-selector',
      );
      expect(rss.canResolveNatively, isFalse);
      expect(rss.unsupportedReason, contains('BT/RSS'));
      expect(rss.priority, 9);
      expect(rss.groupId, isNotEmpty);
      expect(web.canResolveNatively, isTrue);
      expect(web.animeko?.matchVideoUrl, contains('url='));
      expect(web.animeko?.cookies, 'quality=1080');
      expect(web.priority, 2);
      expect(web.groupId, isNotEmpty);
    },
  );

  test(
    'rule importer preserves credentials, scripts and repository configs',
    () {
      const importer = RuleImporter();

      final credentialBundle = importer.importFromText('''
        {
          "name": "credential-rule",
          "baseUrl": "https://example.com",
          "searchUrl": "https://example.com/search?q=@keyword",
          "chapterRoads": "//ul",
          "chapterResult": "//a",
          "cookies": "session=user-value",
          "token": "user-token",
          "headers": {
            "Authorization": "Bearer user-value"
          }
        }
      ''');
      final credentialRule = credentialBundle.rules.single;
      expect(credentialRule.requestHeaders['Cookie'], 'session=user-value');
      expect(
        credentialRule.requestHeaders['Authorization'],
        'Bearer user-value',
      );
      expect(credentialRule.rawConfig['token'], 'user-token');
      final restoredCredential = RulePlugin.fromJson(credentialRule.toJson());
      expect(restoredCredential.rawConfig['token'], 'user-token');
      expect(
        restoredCredential.requestHeaders['Authorization'],
        'Bearer user-value',
      );

      final tvBoxBundle = importer.importFromText('''
        {
          "sites": [
            {
              "key": "drpy-test",
              "name": "DRPY Test",
              "type": 3,
              "api": "csp_DRPY",
              "ext": "https://example.com/rule.js"
            }
          ],
          "spider": "https://example.com/remote.jar",
          "parses": [{"url": "https://parser.example/?url="}]
        }
      ''');
      expect(tvBoxBundle.rules, hasLength(1));
      expect(tvBoxBundle.rules.single.engine, 'csp_DRPY');
      expect(
        (tvBoxBundle.rules.single.rawConfig['site'] as Map)['ext'],
        'https://example.com/rule.js',
      );
      expect(
        tvBoxBundle.rules.single.rawConfig['spider'],
        'https://example.com/remote.jar',
      );

      final xbpqBundle = importer.importFromText('''
        {
          "sites": [
            {"type": 3, "api": "csp_XBPQ", "ext": {}}
          ],
          "parses": [{"url": "https://parser.example/?url="}]
        }
      ''');
      expect(xbpqBundle.rules.single.engine, 'XBPQ');

      final repositoryBundle = importer.importFromText('''
        {
          "urls": [
            {"name": "多仓", "url": "https://example.com/store.json"}
          ]
        }
      ''');
      expect(repositoryBundle.rules.single.engine, 'repository-link');
      expect(
        repositoryBundle.rules.single.rawConfig['url'],
        'https://example.com/store.json',
      );
    },
  );

  test('safe inline XBPQ data remains importable', () {
    final bundle = const RuleImporter().importFromText('''
      {
        "name": "安全规则",
        "sites": [
          {
            "key": "safe-xbpq",
            "name": "安全 XBPQ",
            "type": 1,
            "api": "XBPQ",
            "searchable": 1,
            "ext": {
              "主页url": "https://example.com/",
              "搜索url": "https://example.com/search?wd={wd}",
              "搜索数组": "<div&&</div>",
              "搜索标题": "title=&&",
              "搜索链接": "href=&&",
              "播放数组": "<section&&</section>",
              "播放列表": "<a&&/a>",
              "播放标题": ">&&<",
              "播放链接": "href=&&"
            }
          }
        ]
      }
    ''');

    expect(bundle.rules, hasLength(1));
    expect(bundle.rules.single.engine, 'XBPQ');
    expect(bundle.rules.single.canResolveNatively, isTrue);
  });

  test(
    'rule importer requires raw JSON instead of a GitHub repository page',
    () async {
      await expectLater(
        const RuleImporter().importFromUrl('https://github.com/example/rules'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('raw JSON'),
          ),
        ),
      );
    },
  );

  test('Animeko web selector resolver extracts current episode url', () async {
    final client = MockClient((request) async {
      switch (request.url.path) {
        case '/anime/02.m3u8':
          return http.Response('#EXTM3U', 200);
        case '/search':
          expect(request.url.query, contains('wd='));
          return _html('''
            <div class="result">
              <a title="测试番剧" href="/detail/anime.html">测试番剧</a>
            </div>
          ''');
        case '/detail/anime.html':
          return _html('''
            <div class="playlist">
              <a href="/play/1.html">第1集</a>
              <a href="/play/2.html">第2集</a>
            </div>
          ''');
        case '/play/2.html':
          return _html('''
            <script>
              window.player = {url: "https://cdn.example.com/anime/02.m3u8"};
            </script>
          ''');
      }
      return http.Response('not found', 404);
    });

    final resolver = RulePlaybackResolver(client: client);
    final lines = await resolver.resolveRule(
      rule: _animekoRule,
      subject: _animeSubject,
      episode: _episode2,
    );

    expect(lines, hasLength(1));
    expect(lines.single.available, isTrue);
    expect(lines.single.url, 'https://cdn.example.com/anime/02.m3u8');
    expect(lines.single.quality, '1080P');
    expect(lines.single.headers['Cookie'], 'quality=1080');
  });
}

http.Response _html(String body) => http.Response(
  body,
  200,
  headers: {'content-type': 'text/html; charset=utf-8'},
);

Future<PlaybackLine> _resolveSinglePlayableLine(
  String playableUrl, {
  required FutureOr<http.Response> Function(http.Request request) probe,
}) async {
  final client = MockClient((request) async {
    switch (request.url.path) {
      case '/vod/search.html':
        return _html('''
          <div class="item">
            <strong>测试番剧</strong>
            <a class="detail" href="/detail/metadata.html">详情</a>
          </div>
        ''');
      case '/detail/metadata.html':
        return _html('''
          <ul class="line"><li><a href="/play/metadata.html">第1集</a></li></ul>
        ''');
      case '/play/metadata.html':
        return _html('''
          <script>var player={"url":"$playableUrl"};</script>
        ''');
      default:
        return await probe(request);
    }
  });
  final lines = await RulePlaybackResolver(
    client: client,
  ).resolveRule(rule: _kazumiRule, subject: _animeSubject, episode: _episode);
  expect(lines, hasLength(1));
  return lines.single;
}

Uint8List _mp4TkhdSample({required int width, required int height}) {
  final bytes = Uint8List(96);
  final data = ByteData.sublistView(bytes);
  data.setUint32(0, 92, Endian.big);
  bytes.setRange(4, 8, ascii.encode('tkhd'));
  bytes[8] = 0;
  data.setUint32(84, width << 16, Endian.big);
  data.setUint32(88, height << 16, Endian.big);
  return bytes;
}

class _StreamingProbeClient extends http.BaseClient {
  String? probeRange;
  bool probeStreamCancelled = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;
    if (path == '/stream.m3u8') {
      probeRange ??= request.headers['Range'];
      late final StreamController<List<int>> controller;
      controller = StreamController<List<int>>(
        onListen: () => controller.add(utf8.encode('#EXTM3U')),
        onCancel: () {
          probeStreamCancelled = true;
          return controller.close();
        },
      );
      return http.StreamedResponse(controller.stream, 200);
    }

    final body = switch (path) {
      '/vod/search.html' =>
        '''
        <div class="item">
          <strong>测试番剧</strong>
          <a class="detail" href="/detail/stream.html">详情</a>
        </div>
      ''',
      '/detail/stream.html' =>
        '''
        <ul class="line"><li><a href="/play/stream.html">第1集</a></li></ul>
      ''',
      '/play/stream.html' =>
        '''
        <script>var player={"url":"https://cdn.example.com/stream.m3u8"};</script>
      ''',
      _ => 'not found',
    };
    final statusCode = body == 'not found' ? 404 : 200;
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      statusCode,
      headers: {'content-type': 'text/html; charset=utf-8'},
    );
  }
}

class _ChunkedPlaylistProbeClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final chunks = switch (request.url.path) {
      '/vod/search.html' => [
        '<div class="item"><strong>测试番剧</strong>',
        '<a class="detail" href="/detail/chunked.html">详情</a></div>',
      ],
      '/detail/chunked.html' => [
        '<ul class="line"><li>',
        '<a href="/play/chunked.html">第1集</a></li></ul>',
      ],
      '/play/chunked.html' => [
        '<script>var player={"url":"https://cdn.example.com/chunked/master.m3u8"',
        '};</script>',
      ],
      '/chunked/master.m3u8' => [
        '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=5000000,',
        'AVERAGE-BANDWIDTH=4000000,RESOLUTION=1920x1080\nvariant.m3u8\n',
      ],
      '/chunked/variant.m3u8' => [
        '#EXTM3U\n#EXTINF:10.0,\nsegment-1.ts\n',
        '#EXTINF:10.0,\nsegment-2.ts\n#EXT-X-ENDLIST\n',
      ],
      _ => const ['not found'],
    };
    final notFound = chunks.length == 1 && chunks.single == 'not found';
    final playlist = request.url.path.endsWith('.m3u8');
    return http.StreamedResponse(
      Stream<List<int>>.fromIterable(chunks.map(utf8.encode)),
      notFound ? 404 : 200,
      headers: {
        'content-type': playlist
            ? 'application/vnd.apple.mpegurl'
            : 'text/html; charset=utf-8',
      },
    );
  }
}

final _kazumiRule = RulePlugin(
  id: 'kazumi:test',
  name: 'KazumiTest',
  version: '1.0',
  source: RuleSourceKind.kazumi,
  contentType: RuleContentType.anime,
  engine: 'native',
  updatedAt: _date,
  qualityScore: 100,
  tags: ['native'],
  baseUrl: 'https://example.com/',
  searchUrl: 'https://example.com/vod/search.html?wd=@keyword',
  searchable: true,
  quickSearch: true,
  filterable: true,
  requestHeaders: const {
    'Cookie': 'session=user-value',
    'Authorization': 'Bearer user-value',
  },
  kazumi: KazumiParserConfig(
    searchList: "//div[@class='item']",
    searchName: '//strong',
    searchResult: "//a[@class='detail']",
    chapterRoads: "//ul[@class='line']",
    chapterResult: '//li/a',
  ),
);

final _xbpqRule = RulePlugin(
  id: 'tvbox:test',
  name: 'XbpqTest',
  version: '1.0',
  source: RuleSourceKind.tvbox,
  contentType: RuleContentType.movie,
  engine: 'XBPQ',
  updatedAt: _date,
  qualityScore: 100,
  tags: ['XBPQ'],
  baseUrl: 'https://example.com/',
  searchUrl: 'https://example.com/search.html?wd={wd}',
  searchable: true,
  quickSearch: true,
  filterable: true,
  xbpq: XbpqParserConfig(
    searchArray: '<div class="module-item-pic">&&</div>',
    searchTitle: 'title="&&"',
    searchLink: 'href="&&"',
    playArray: '<div class="scroll-content">&&</div>',
    playList: '<a&&/a>',
    playTitle: '<span>&&</span>',
    playLink: 'href="&&"',
    jumpPlayLink: 'var player_*"url":"&&"',
  ),
);

final _captchaRule = RulePlugin(
  id: 'kazumi:captcha',
  name: 'Captcha',
  version: '1.0',
  source: RuleSourceKind.kazumi,
  contentType: RuleContentType.anime,
  engine: 'native',
  updatedAt: _date,
  qualityScore: 80,
  tags: ['native'],
  baseUrl: 'https://example.com/',
  searchUrl: 'https://example.com/search?wd=@keyword',
  searchable: true,
  quickSearch: true,
  filterable: true,
  requiresCaptcha: true,
  unsupportedReason: '该规则启用了验证码验证，需要 WebView 手动处理。',
);

final _animekoRule = RulePlugin(
  id: 'custom:animeko:test',
  name: 'AnimekoTest',
  version: '2',
  source: RuleSourceKind.custom,
  contentType: RuleContentType.anime,
  engine: 'animeko-web-selector',
  updatedAt: _date,
  qualityScore: 80,
  tags: ['Animeko', 'CSS'],
  baseUrl: 'https://example.com/',
  searchUrl: 'https://example.com/search?wd={keyword}',
  searchable: true,
  quickSearch: true,
  filterable: false,
  animeko: AnimekoWebSelectorConfig(
    searchUrl: 'https://example.com/search?wd={keyword}',
    subjectFormatId: 'a',
    channelFormatId: 'index-grouped',
    defaultResolution: '1080P',
    subjectA: AnimekoSubjectAConfig(selectLists: '.result a'),
    channelFlattened: AnimekoChannelFlattenedConfig(
      selectEpisodeLists: '.playlist',
      selectEpisodesFromList: 'a',
      matchEpisodeSortFromName: r'第\s*(?<ep>\d+)',
    ),
    matchVideoUrl: r'url:\s*"(?<v>https?:\/\/.+\.(m3u8|mp4))"',
    cookies: 'quality=1080',
  ),
);

const _animeSubject = AnimeSubject(
  id: 1,
  title: '测试番剧',
  originalTitle: 'Test Anime',
  summary: 'summary',
  coverUrl: null,
  bannerUrl: null,
  date: '2026-01-01',
  platform: 'TV',
  language: '日语',
  region: '日本',
  status: '全12集',
  categories: [AnimeCategory(name: '动画')],
  tags: [AnimeTag(name: '番剧')],
  totalEpisodes: 12,
);

const _equivalentTitleSubject = AnimeSubject(
  id: 3,
  title: 'Test Anime',
  originalTitle: 'test-anime',
  summary: 'summary',
  coverUrl: null,
  bannerUrl: null,
  date: '2026-01-01',
  platform: 'TV',
  language: 'English',
  region: 'US',
  status: '12 episodes',
  categories: [AnimeCategory(name: 'Animation')],
  tags: [AnimeTag(name: 'Anime')],
  totalEpisodes: 12,
);

const _movieSubject = AnimeSubject(
  id: 2,
  title: '测试电影',
  originalTitle: 'Test Movie',
  summary: 'summary',
  coverUrl: null,
  bannerUrl: null,
  date: '2026-01-01',
  platform: 'Movie',
  language: '中文',
  region: '中国',
  status: '电影',
  categories: [AnimeCategory(name: '电影')],
  tags: [AnimeTag(name: '电影')],
  totalEpisodes: 1,
  source: 'wikidata',
);

const _episode = AnimeEpisode(
  id: 101,
  subjectId: 1,
  number: 1,
  title: '',
  airdate: '2026-01-01',
  duration: '24:00',
  description: '第一集',
);

const _episode2 = AnimeEpisode(
  id: 102,
  subjectId: 1,
  number: 2,
  title: '',
  airdate: '2026-01-08',
  duration: '24:00',
  description: '第二集',
);

const _movieEpisode = AnimeEpisode(
  id: 201,
  subjectId: 2,
  number: 1,
  title: '正片',
  airdate: '2026-01-01',
  duration: '120:00',
  description: '正片',
);

final _date = DateTime(2026, 5, 5);
