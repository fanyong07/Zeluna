import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/rules/rule_importer.dart';
import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/rules/animeko_webview_sniffer.dart';
import 'package:anime/src/rules/rule_playback_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'cancellation aborts requests on a shared client without closing it',
    () async {
      final searchStarted = Completer<void>();
      final releaseSearch = Completer<void>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sharedClient = http.Client();
      addTearDown(() async {
        if (!releaseSearch.isCompleted) releaseSearch.complete();
        sharedClient.close();
        await server.close(force: true);
      });
      server.listen((request) async {
        if (request.uri.path == '/health') {
          request.response
            ..statusCode = 200
            ..write('ok');
          await request.response.close();
          return;
        }
        if (request.uri.path == '/vod/search.html') {
          if (!searchStarted.isCompleted) searchStarted.complete();
          await releaseSearch.future;
          try {
            request.response
              ..statusCode = 200
              ..write('<html></html>');
            await request.response.close();
          } catch (_) {
            // The client is expected to abort this individual request.
          }
          return;
        }
        request.response.statusCode = 404;
        await request.response.close();
      });

      final origin = 'http://${server.address.address}:${server.port}';
      final resolver = RulePlaybackResolver(
        client: sharedClient,
        timeout: const Duration(seconds: 5),
      );
      final rule = _kazumiRule.copyWith(
        id: 'kazumi:shared-client-cancel',
        baseUrl: '$origin/',
        searchUrl: '$origin/vod/search.html?wd=@keyword',
        requestHeaders: const {},
      );
      final cancellationToken = RulePlaybackCancellationToken();
      final resolving = resolver.resolveRule(
        rule: rule,
        subject: _animeSubject,
        episode: _episode,
        verifyPlayable: false,
        cancellationToken: cancellationToken,
      );

      await searchStarted.future.timeout(const Duration(seconds: 2));
      final stopwatch = Stopwatch()..start();
      cancellationToken.cancel();
      final lines = await resolving.timeout(const Duration(seconds: 1));
      stopwatch.stop();

      expect(lines, isEmpty);
      expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 800)));
      final health = await sharedClient.get(Uri.parse('$origin/health'));
      expect(health.statusCode, 200);
      expect(health.body, 'ok');
      releaseSearch.complete();
    },
  );

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
          return _playableHls();
        case '/test/segment-1.ts':
          return _playableSegment();
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

    expect(quickLines, hasLength(1));
    expect(quickLines.every((line) => line.available), isTrue);
    expect(playPageRequests, 1);
    expect(probeRequests, 1);

    final lines = await resolver.resolveRule(
      rule: _kazumiRule,
      subject: _animeSubject,
      episode: _episode,
    );

    expect(lines, hasLength(2));
    expect(lines.first.available, isTrue);
    expect(lines.first.url, 'https://cdn.example.com/test/01.m3u8');
    expect(lines.first.format, 'HLS');
    expect(lines.first.sizeLabel, isNull);
    expect(lines.first.isLive, isFalse);
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

  test('quick lookup rejects a dead explicit media url', () async {
    var probeRequests = 0;
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
            <script>var player={"url":"https://cdn.example.com/dead.m3u8"};</script>
          ''');
        case '/dead.m3u8':
          probeRequests++;
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
    expect(quick.single.available, isFalse);
    expect(quick.single.message, contains('404'));
    expect(probeRequests, 1);

    final verified = await resolver.resolveRule(
      rule: _kazumiRule,
      subject: _animeSubject,
      episode: _episode,
    );

    expect(verified.single.available, isFalse);
    expect(verified.single.id, quick.single.id);
    expect(probeRequests, 2);
  });

  test('quick lookup rejects a 200 HTML media response', () async {
    final client = _singleLineClient(
      mediaResponse: () => _html('<html><body>Access denied</body></html>'),
      mediaPath: '/blocked.m3u8',
    );

    final lines = await RulePlaybackResolver(client: client).resolveRule(
      rule: _kazumiRule,
      subject: _animeSubject,
      episode: _episode,
      verifyPlayable: false,
    );

    expect(lines, hasLength(1));
    expect(lines.single.available, isFalse);
    expect(lines.single.message, contains('不是媒体内容'));
  });

  test(
    'quick lookup rejects an HLS manifest without media references',
    () async {
      final client = _singleLineClient(
        mediaResponse: () => http.Response(
          '#EXTM3U\n#EXT-X-VERSION:3\n',
          200,
          headers: {'content-type': 'application/vnd.apple.mpegurl'},
        ),
        mediaPath: '/empty.m3u8',
      );

      final lines = await RulePlaybackResolver(client: client).resolveRule(
        rule: _kazumiRule,
        subject: _animeSubject,
        episode: _episode,
        verifyPlayable: false,
      );

      expect(lines, hasLength(1));
      expect(lines.single.available, isFalse);
      expect(lines.single.message, contains('没有媒体分片'));
    },
  );

  test(
    'quick lookup returns the first playback road without waiting',
    () async {
      final slowProbe = Completer<http.Response>();
      final secondSlowProbe = Completer<http.Response>();
      var fourthRoadRequests = 0;
      final client = MockClient((request) async {
        switch (request.url.path) {
          case '/vod/search.html':
            return _html('''
            <div class="item">
              <strong>测试番剧</strong>
              <a class="detail" href="/detail/race.html">详情</a>
            </div>
          ''');
          case '/detail/race.html':
            return _html('''
            <ul class="line"><li><a href="/play/slow.html">第1集</a></li></ul>
            <ul class="line"><li><a href="/play/fast.html">第1集</a></li></ul>
            <ul class="line"><li><a href="/play/slow-two.html">第1集</a></li></ul>
            <ul class="line"><li><a href="/play/not-started.html">第1集</a></li></ul>
          ''');
          case '/play/slow.html':
            return _html('''
            <script>var player={"url":"https://cdn.example.com/slow-stream?id=1"};</script>
          ''');
          case '/play/fast.html':
            return _html('''
            <script>var player={"url":"https://cdn.example.com/fast.m3u8"};</script>
          ''');
          case '/fast.m3u8':
            return _playableHls();
          case '/segment-1.ts':
            return _playableSegment();
          case '/play/slow-two.html':
            return _html('''
            <script>var player={"url":"https://cdn.example.com/slow-stream-two?id=1"};</script>
          ''');
          case '/play/not-started.html':
            fourthRoadRequests++;
            return _html('''
            <script>var player={"url":"https://cdn.example.com/fourth.m3u8"};</script>
          ''');
          case '/slow-stream':
            return slowProbe.future;
          case '/slow-stream-two':
            return secondSlowProbe.future;
        }
        return http.Response('not found', 404);
      });

      final lines = await RulePlaybackResolver(client: client)
          .resolveRule(
            rule: _kazumiRule,
            subject: _animeSubject,
            episode: _episode,
            verifyPlayable: false,
          )
          .timeout(const Duration(milliseconds: 500));

      expect(lines, hasLength(1));
      expect(lines.single.url, 'https://cdn.example.com/fast.m3u8');
      expect(fourthRoadRequests, 0);
      slowProbe.complete(http.Response('cancelled', 503));
      secondSlowProbe.complete(http.Response('cancelled', 503));
    },
  );

  test(
    'quick lookup does not let a dead road beat a playable sibling',
    () async {
      final deadProbed = Completer<void>();
      final fastPlayPage = Completer<http.Response>();
      final client = MockClient((request) async {
        switch (request.url.path) {
          case '/vod/search.html':
            return _html('''
            <div class="item">
              <strong>测试番剧</strong>
              <a class="detail" href="/detail/dead-race.html">详情</a>
            </div>
          ''');
          case '/detail/dead-race.html':
            return _html('''
            <ul class="line"><li><a href="/play/dead-first.html">第1集</a></li></ul>
            <ul class="line"><li><a href="/play/good-later.html">第1集</a></li></ul>
          ''');
          case '/play/dead-first.html':
            return _html('''
            <script>var player={"url":"https://cdn.example.com/dead.mp4"};</script>
          ''');
          case '/play/good-later.html':
            return fastPlayPage.future;
          case '/dead.mp4':
            if (!deadProbed.isCompleted) deadProbed.complete();
            return http.Response('gone', 404);
          case '/good.mp4':
            return http.Response.bytes(
              _mp4ProbeSample(),
              206,
              headers: {
                'content-type': 'video/mp4',
                'content-range': 'bytes 0-1/2',
              },
            );
        }
        return http.Response('not found', 404);
      });

      var completed = false;
      final resolving = RulePlaybackResolver(client: client)
          .resolveRule(
            rule: _kazumiRule,
            subject: _animeSubject,
            episode: _episode,
            verifyPlayable: false,
          )
          .whenComplete(() => completed = true);

      await deadProbed.future.timeout(const Duration(milliseconds: 500));
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);

      fastPlayPage.complete(
        _html('''
        <script>var player={"url":"https://cdn.example.com/good.mp4"};</script>
      '''),
      );
      final lines = await resolving.timeout(const Duration(milliseconds: 500));
      expect(lines.single.url, 'https://cdn.example.com/good.mp4');
      expect(lines.single.available, isTrue);
    },
  );

  test(
    'quick Kazumi lookup prefers HLS that succeeds inside the grace window',
    () async {
      final mp4Probed = Completer<void>();
      final hlsProbe = Completer<http.Response>();
      final client = MockClient((request) async {
        switch (request.url.path) {
          case '/vod/search.html':
            return _html('''
              <div class="item">
                <strong>测试番剧</strong>
                <a class="detail" href="/detail/prefer-hls.html">详情</a>
              </div>
            ''');
          case '/detail/prefer-hls.html':
            return _html('''
              <ul class="line"><li><a href="/play/fast-mp4.html">第1集</a></li></ul>
              <ul class="line"><li><a href="/play/preferred-hls.html">第1集</a></li></ul>
            ''');
          case '/play/fast-mp4.html':
            return _html('''
              <script>var player={"url":"https://cdn.example.com/fast.mp4"};</script>
            ''');
          case '/play/preferred-hls.html':
            return _html('''
              <script>var player={"url":"https://cdn.example.com/preferred.m3u8"};</script>
            ''');
          case '/fast.mp4':
            if (!mp4Probed.isCompleted) mp4Probed.complete();
            return http.Response.bytes(
              _mp4ProbeSample(),
              206,
              headers: {'content-type': 'video/mp4'},
            );
          case '/preferred.m3u8':
            return hlsProbe.future;
          case '/segment-1.ts':
            return _playableSegment();
        }
        return http.Response('not found', 404);
      });

      var completed = false;
      final resolving = RulePlaybackResolver(client: client)
          .resolveRule(
            rule: _kazumiRule,
            subject: _animeSubject,
            episode: _episode,
            verifyPlayable: false,
          )
          .whenComplete(() => completed = true);

      await mp4Probed.future.timeout(const Duration(milliseconds: 500));
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      hlsProbe.complete(_playableHls());

      final lines = await resolving.timeout(const Duration(milliseconds: 500));
      expect(lines.single.url, 'https://cdn.example.com/preferred.m3u8');
      expect(lines.single.format, 'HLS');
    },
  );

  test(
    'quick Kazumi lookup returns MP4 when HLS exceeds the grace window',
    () async {
      final hlsProbe = Completer<http.Response>();
      final client = MockClient((request) async {
        switch (request.url.path) {
          case '/vod/search.html':
            return _html('''
              <div class="item">
                <strong>测试番剧</strong>
                <a class="detail" href="/detail/hls-timeout.html">详情</a>
              </div>
            ''');
          case '/detail/hls-timeout.html':
            return _html('''
              <ul class="line"><li><a href="/play/fallback-mp4.html">第1集</a></li></ul>
              <ul class="line"><li><a href="/play/slow-hls.html">第1集</a></li></ul>
            ''');
          case '/play/fallback-mp4.html':
            return _html('''
              <script>var player={"url":"https://cdn.example.com/fallback.mp4"};</script>
            ''');
          case '/play/slow-hls.html':
            return _html('''
              <script>var player={"url":"https://cdn.example.com/slow.m3u8"};</script>
            ''');
          case '/fallback.mp4':
            return http.Response.bytes(
              _mp4ProbeSample(),
              206,
              headers: {'content-type': 'video/mp4'},
            );
          case '/slow.m3u8':
            return hlsProbe.future;
        }
        return http.Response('not found', 404);
      });

      final stopwatch = Stopwatch()..start();
      final lines = await RulePlaybackResolver(client: client)
          .resolveRule(
            rule: _kazumiRule,
            subject: _animeSubject,
            episode: _episode,
            verifyPlayable: false,
          )
          .timeout(const Duration(seconds: 2));
      stopwatch.stop();

      expect(lines.single.url, 'https://cdn.example.com/fallback.mp4');
      expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 1600)));
      hlsProbe.complete(http.Response('late', 503));
    },
  );

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
          return _playableHls();
        case '/segment-1.ts':
          return _playableSegment();
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
          return http.Response.bytes(
            _mp4ProbeSample(),
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

  test(
    'playable probe cancels an open stream after a bounded sample',
    () async {
      final client = _StreamingProbeClient();

      final lines = await RulePlaybackResolver(client: client).resolveRule(
        rule: _kazumiRule,
        subject: _animeSubject,
        episode: _episode,
      );

      expect(lines, hasLength(1));
      expect(lines.single.available, isTrue);
      expect(client.probeRange, 'bytes=0-2048');
      expect(client.probeStreamCancelled, isTrue);
    },
  );

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
          switch (request.url.path) {
            case '/master.m3u8':
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
            case '/1080/index.m3u8':
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
            case '/1080/segment-1.ts':
              return http.Response.bytes(
                _mpegTsSample(),
                206,
                headers: {
                  'content-type': 'video/mp2t',
                  'content-range': 'bytes 0-2048/5000000',
                },
              );
          }
          return http.Response('not found', 404);
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

  test('HLS master with a 404 child playlist is rejected', () async {
    final line = await _resolveSinglePlayableLine(
      'https://cdn.example.com/dead-master.m3u8',
      probe: (request) {
        if (request.url.path == '/dead-master.m3u8') {
          return http.Response(
            '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=1200000,RESOLUTION=854x480
dead-child.m3u8
''',
            200,
            headers: {'content-type': 'application/vnd.apple.mpegurl'},
          );
        }
        return http.Response('gone', 404);
      },
    );

    expect(line.available, isFalse);
    expect(line.message, contains('子清单'));
  });

  test('HLS media playlist with a 404 first segment is rejected', () async {
    final line = await _resolveSinglePlayableLine(
      'https://cdn.example.com/dead-segment.m3u8',
      probe: (request) {
        if (request.url.path == '/dead-segment.m3u8') {
          return _playableHls();
        }
        return http.Response('gone', 404);
      },
    );

    expect(line.available, isFalse);
    expect(line.message, contains('媒体分片'));
  });

  test(
    'HLS metadata timeout retries during required reachability check',
    () async {
      final never = Completer<http.Response>();
      var variantRequests = 0;
      addTearDown(() {
        if (!never.isCompleted) never.complete(http.Response('late', 503));
      });
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
          if (request.url.path == '/slow-variant.m3u8') {
            variantRequests++;
            return variantRequests == 1 ? never.future : _playableHls();
          }
          if (request.url.path == '/segment-1.ts') {
            return _playableSegment();
          }
          return http.Response('not found', 404);
        },
      );
      stopwatch.stop();

      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 4)));
      expect(line.available, isTrue);
      expect(line.videoWidth, 1920);
      expect(line.videoHeight, 1080);
      expect(line.bitrate, 5000000);
      expect(line.sizeBytes, isNull);
    },
  );

  test(
    'malformed HLS child URI is rejected instead of bypassing reachability',
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

      expect(line.available, isFalse);
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
              _mpegTsSample(),
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
#EXTINF:10.0,
segment-1.ts
$padding
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
          _mpegTsSample(),
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
          _mpegTsSample(),
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
          if (request.url.path == '/shared.ts') {
            return _playableSegment();
          }
          return http.Response('not found', 404);
        },
      );

      expect(line.available, isTrue);
      expect(line.sizeBytes, isNull);
      expect(line.sizeEstimated, isFalse);
      expect(line.sizeLabel, isNull);
    },
  );

  test(
    'live HLS verifies a recent segment instead of requiring ENDLIST',
    () async {
      final requestedSegments = <String>[];
      final line = await _resolveSinglePlayableLine(
        'https://cdn.example.com/live.m3u8',
        probe: (request) {
          if (request.url.path == '/live.m3u8') {
            return http.Response(
              '''
#EXTM3U
#EXT-X-TARGETDURATION:6
#EXT-X-MEDIA-SEQUENCE:100
#EXTINF:6.0,
old.ts
#EXTINF:6.0,
current.ts
''',
              200,
              headers: {'content-type': 'application/vnd.apple.mpegurl'},
            );
          }
          requestedSegments.add(request.url.path);
          if (request.url.path == '/current.ts') return _playableSegment();
          return http.Response('expired', 404);
        },
      );

      expect(line.available, isTrue);
      expect(line.isLive, isTrue);
      expect(requestedSegments, contains('/current.ts'));
      expect(requestedSegments, isNot(contains('/old.ts')));
    },
  );

  test('HLS master falls back when its highest variant is dead', () async {
    var lowerVariantRequests = 0;
    final line = await _resolveSinglePlayableLine(
      'https://cdn.example.com/fallback-master.m3u8',
      probe: (request) {
        switch (request.url.path) {
          case '/fallback-master.m3u8':
            return http.Response(
              '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
dead-1080.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720
working-720.m3u8
''',
              200,
              headers: {'content-type': 'application/vnd.apple.mpegurl'},
            );
          case '/dead-1080.m3u8':
            return http.Response('gone', 404);
          case '/working-720.m3u8':
            lowerVariantRequests++;
            return _playableHls();
          case '/segment-1.ts':
            return _playableSegment();
        }
        return http.Response('not found', 404);
      },
    );

    expect(line.available, isTrue);
    expect(lowerVariantRequests, 1);
  });

  test('media MIME and octet-stream do not make text playable', () async {
    for (final entry in <(String, String, String)>[
      (
        'https://cdn.example.com/fake.mp4',
        'video/mp4',
        '{"error":"access denied"}',
      ),
      (
        'https://cdn.example.com/blob',
        'application/octet-stream',
        'not a media file',
      ),
    ]) {
      final resolver = RulePlaybackResolver(
        client: MockClient(
          (_) async =>
              http.Response(entry.$3, 200, headers: {'content-type': entry.$2}),
        ),
      );
      final verified = await resolver.verifyPlaybackLine(
        line: _networkLine(entry.$1),
      );
      expect(verified.available, isFalse, reason: entry.$1);
    }
  });

  test('a short fake MPEG-TS response is rejected', () async {
    final line = await _resolveSinglePlayableLine(
      'https://cdn.example.com/short-ts.m3u8',
      probe: (request) {
        if (request.url.path == '/short-ts.m3u8') return _playableHls();
        return http.Response.bytes(
          const <int>[0x47, 0x40, 0x00, 0x10],
          206,
          headers: {'content-type': 'video/mp2t'},
        );
      },
    );

    expect(line.available, isFalse);
    expect(line.message, contains('媒体分片'));
  });

  test(
    'AES-128 HLS accepts an opaque segment only after key verification',
    () async {
      final line = await _resolveSinglePlayableLine(
        'https://cdn.example.com/encrypted.m3u8',
        probe: (request) {
          switch (request.url.path) {
            case '/encrypted.m3u8':
              return http.Response(
                '''
#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI="key.bin"
#EXTINF:10.0,
encrypted-segment.ts
#EXT-X-ENDLIST
''',
                200,
                headers: {'content-type': 'application/vnd.apple.mpegurl'},
              );
            case '/key.bin':
              return http.Response.bytes(
                List<int>.generate(16, (index) => index),
                206,
                headers: {'content-type': 'application/octet-stream'},
              );
            case '/encrypted-segment.ts':
              return http.Response.bytes(
                List<int>.generate(512, (index) => (index * 73) & 0xff),
                206,
                headers: {'content-type': 'application/octet-stream'},
              );
          }
          return http.Response('not found', 404);
        },
      );

      expect(line.available, isTrue);
    },
  );

  test('AES-128 HLS is rejected when its key cannot be fetched', () async {
    final line = await _resolveSinglePlayableLine(
      'https://cdn.example.com/missing-key.m3u8',
      probe: (request) {
        if (request.url.path == '/missing-key.m3u8') {
          return http.Response(
            '''
#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI="missing.bin"
#EXTINF:10.0,
encrypted-segment.ts
#EXT-X-ENDLIST
''',
            200,
            headers: {'content-type': 'application/vnd.apple.mpegurl'},
          );
        }
        if (request.url.path == '/encrypted-segment.ts') {
          fail('Encrypted segment must not be trusted before its key');
        }
        return http.Response('gone', 404);
      },
    );

    expect(line.available, isFalse);
  });

  test(
    'binary signature split across response chunks is still detected',
    () async {
      final verified =
          await RulePlaybackResolver(
            client: _SplitSignatureProbeClient(),
          ).verifyPlaybackLine(
            line: _networkLine('https://cdn.example.com/video.mp4'),
          );

      expect(verified.available, isTrue);
      expect(verified.format, 'MP4');
    },
  );

  test('Range rejection retries one bounded GET without Range', () async {
    var requests = 0;
    final resolver = RulePlaybackResolver(
      client: MockClient((request) async {
        requests++;
        if (requests == 1) {
          expect(request.headers['Range'], 'bytes=0-2048');
          return http.Response('range unsupported', 416);
        }
        expect(request.headers, isNot(contains('Range')));
        return http.Response.bytes(
          _mp4ProbeSample(),
          200,
          headers: {'content-type': 'video/mp4'},
        );
      }),
    );

    final verified = await resolver.verifyPlaybackLine(
      line: _networkLine('https://cdn.example.com/no-range.mp4'),
    );
    expect(verified.available, isTrue);
    expect(requests, 2);
  });

  test(
    'truncated HLS sample expands before checking media references',
    () async {
      final padding = List<String>.generate(
        180,
        (index) => '# padding $index',
      ).join('\n');
      final manifest =
          '''
#EXTM3U
$padding
#EXTINF:10.0,
segment-1.ts
#EXT-X-ENDLIST
''';
      final bytes = utf8.encode(manifest);
      var manifestRequests = 0;
      final line = await _resolveSinglePlayableLine(
        'https://cdn.example.com/padded-before-segment.m3u8',
        probe: (request) {
          if (request.url.path == '/padded-before-segment.m3u8') {
            manifestRequests++;
            if (request.headers['Range'] == 'bytes=0-2048') {
              return http.Response.bytes(
                bytes.take(2049).toList(growable: false),
                206,
                headers: {
                  'content-type': 'application/vnd.apple.mpegurl',
                  'content-range': 'bytes 0-2048/${bytes.length}',
                },
              );
            }
            return http.Response.bytes(
              bytes,
              206,
              headers: {
                'content-type': 'application/vnd.apple.mpegurl',
                'content-range': 'bytes 0-${bytes.length - 1}/${bytes.length}',
              },
            );
          }
          return _playableSegment();
        },
      );

      expect(line.available, isTrue);
      expect(manifestRequests, 2);
    },
  );

  test(
    'forceRefresh bypasses a cached successful probe before playback',
    () async {
      var requests = 0;
      final resolver = RulePlaybackResolver(
        client: MockClient((_) async {
          requests++;
          if (requests == 1) {
            return http.Response.bytes(
              _mp4ProbeSample(),
              206,
              headers: {'content-type': 'video/mp4'},
            );
          }
          return http.Response('expired', 404);
        }),
      );
      final candidate = _networkLine('https://cdn.example.com/expiring.mp4');

      expect(
        (await resolver.verifyPlaybackLine(line: candidate)).available,
        isTrue,
      );
      expect(
        (await resolver.verifyPlaybackLine(line: candidate)).available,
        isTrue,
      );
      expect(requests, 1);
      final refreshed = await resolver.verifyPlaybackLine(
        line: candidate,
        forceRefresh: true,
      );
      expect(refreshed.available, isFalse);
      expect(requests, 2);
    },
  );

  test('static DASH manifest exposes resolution and estimated size', () async {
    final line = await _resolveSinglePlayableLine(
      'https://cdn.example.com/video.mpd',
      probe: (request) {
        if (request.url.path != '/video.mpd') {
          expect(
            request.url.path,
            anyOf('/init-v1080.m4s', '/chunk-v1080-1.m4s'),
          );
          return http.Response.bytes(
            _mp4ProbeSample(),
            206,
            headers: {'content-type': 'video/mp4'},
          );
        }
        return http.Response(
          '''
<MPD type="static" mediaPresentationDuration="PT60S">
  <Period>
    <AdaptationSet contentType="video" mimeType="video/mp4">
      <SegmentTemplate initialization="init-\$RepresentationID\$.m4s" media="chunk-\$RepresentationID\$-\$Number\$.m4s" startNumber="1" />
      <Representation id="v720" width="1280" height="720" bandwidth="3000000" codecs="avc1.4d401f" />
      <Representation id="v1080" width="1920" height="1080" bandwidth="8000000" codecs="hev1.1.6.L120" />
    </AdaptationSet>
    <AdaptationSet contentType="audio" mimeType="audio/mp4">
      <Representation bandwidth="128000" codecs="mp4a.40.2" />
    </AdaptationSet>
  </Period>
</MPD>
''',
          200,
          headers: {'content-type': 'application/dash+xml'},
        );
      },
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

  test('DASH manifest is rejected when its media segment is dead', () async {
    final line = await _resolveSinglePlayableLine(
      'https://cdn.example.com/dead-video.mpd',
      probe: (request) {
        if (request.url.path == '/dead-video.mpd') {
          return http.Response(
            '''
<MPD type="static">
  <Period>
    <AdaptationSet contentType="video" mimeType="video/mp4">
      <SegmentTemplate initialization="init.m4s" media="chunk-\$Number\$.m4s" />
      <Representation id="video" bandwidth="1000000" />
    </AdaptationSet>
  </Period>
</MPD>
''',
            200,
            headers: {'content-type': 'application/dash+xml'},
          );
        }
        if (request.url.path == '/init.m4s') {
          return http.Response.bytes(
            _mp4ProbeSample(),
            206,
            headers: {'content-type': 'video/mp4'},
          );
        }
        return http.Response('gone', 404);
      },
    );

    expect(line.available, isFalse);
    expect(line.message, contains('媒体分片'));
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
          return http.Response.bytes(
            const [0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70],
            206,
            headers: {
              'content-type': 'video/mp4',
              'content-range': 'bytes 0-7/1024',
            },
          );
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
          return _playableHls();
        case '/anime/segment-1.ts':
          return _playableSegment();
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

  test('Animeko web selector falls back to WebView network sniffing', () async {
    final client = MockClient((request) async {
      switch (request.url.path) {
        case '/anime/02.m3u8':
          return _playableHls();
        case '/anime/segment-1.ts':
          return _playableSegment();
        case '/search':
          return _html('''
            <div class="result">
              <a title="测试番剧" href="/detail/anime.html">测试番剧</a>
            </div>
          ''');
        case '/detail/anime.html':
          return _html('''
            <div class="playlist"><a href="/play/2.html">第2集</a></div>
          ''');
        case '/play/2.html':
          return _html('<div id="player">JavaScript player</div>');
      }
      return http.Response('not found', 404);
    });
    final sniffer = _FakeAnimekoWebViewSniffer(
      observedUrl: 'https://cdn.example.com/anime/02.m3u8',
      cookieHeader: 'session=active',
    );
    final resolver = RulePlaybackResolver(
      client: client,
      animekoWebViewSniffer: sniffer,
    );

    final lines = await resolver.resolveRule(
      rule: _animekoRule,
      subject: _animeSubject,
      episode: _episode2,
    );

    expect(sniffer.calls, 1);
    expect(lines.single.available, isTrue);
    expect(lines.single.url, 'https://cdn.example.com/anime/02.m3u8');
    expect(lines.single.headers['Cookie'], 'quality=1080; session=active');
  });

  test(
    'Aikanbot API resolves the selected episode without loading its player',
    () async {
      final client = MockClient((request) async {
        switch (request.url.path) {
          case '/search':
            expect(request.url.queryParameters['q'], _animeSubject.title);
            return _html('''
            <div class="media">
              <a class="title-text" href="/play/722004">${_animeSubject.title} 2022</a>
            </div>
          ''');
          case '/play/722004':
            return _html('''
            <input id="current_id" value="722004"/>
            <input id="e_token" value="abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"/>
            <input id="mtype" value="18"/>
          ''');
          case '/api/getResN':
            expect(request.url.queryParameters['videoId'], '722004');
            expect(request.url.queryParameters['mtype'], '18');
            expect(request.url.queryParameters['token'], isNotEmpty);
            return http.Response(
              '{"state":1,"data":{"list":[{"resData":"[{\\"url\\":\\"第01集\$https://cdn.example.com/aikan/01.m3u8#第02集\$https://cdn.example.com/aikan/02.m3u8\\"}]"}]}}',
              200,
              headers: const {
                'content-type': 'application/json; charset=utf-8',
              },
            );
          case '/aikan/02.m3u8':
            return _playableHls();
          case '/aikan/segment-1.ts':
            return _playableSegment();
        }
        return http.Response('not found', 404);
      });
      final lines = await RulePlaybackResolver(client: client).resolveRule(
        rule: _aikanbotRule,
        subject: _animeSubject,
        episode: _episode2,
      );

      expect(lines, hasLength(1));
      expect(lines.single.available, isTrue);
      expect(lines.single.url, 'https://cdn.example.com/aikan/02.m3u8');
      expect(
        lines.single.headers['Referer'],
        'https://example.com/play/722004',
      );
    },
  );

  test('DBKU XBPQ rule decodes its page-provided HLS address', () async {
    final client = MockClient((request) async {
      switch (request.url.path) {
        case '/vodsearch/-------------.html':
          return _html('''
            <li class="clearfix">
              <a class="searchkey" href="/voddetail/4209.html">测试番剧</a>
            </li>
          ''');
        case '/voddetail/4209.html':
          return _html('''
            <ul class="myui-content__list"><li><a href="/vodplay/4209-1-1.html">正片</a></li></ul>
          ''');
        case '/vodplay/4209-1-1.html':
          return _html('''
            <script>
              var player_test={"encrypt":2,"url":"aHR0cHMlM0ElMkYlMkZjZG4uZXhhbXBsZS5jb20lMkZkYmt1JTJGaW5kZXgubTN1OA=="};
            </script>
          ''');
        case '/dbku/index.m3u8':
          return _playableHls();
        case '/dbku/segment-1.ts':
          return _playableSegment();
      }
      return http.Response('not found', 404);
    });

    final lines = await RulePlaybackResolver(
      client: client,
    ).resolveRule(rule: _dbkuRule, subject: _animeSubject, episode: _episode2);

    expect(lines, hasLength(1));
    expect(lines.single.available, isTrue);
    expect(lines.single.url, 'https://cdn.example.com/dbku/index.m3u8');
  });

  test('Nivod XBPQ rule probes its page-provided HLS playlist', () async {
    final client = MockClient((request) async {
      switch (request.url.path) {
        case '/s/-------------/':
          return _html('''
            <div class="module-card-item-title"><a href="/nivod/55947/"><strong>测试番剧</strong></a></div>
          ''');
        case '/nivod/55947/':
          return _html('''
            <div class="module-play-list-content"><a class="module-play-list-link" href="/niplay/55947-1-1/"><span>正片</span></a></div>
          ''');
        case '/niplay/55947-1-1/':
          return _html('''
            <script>var player_test={"encrypt":0,"url":"https://cdn.example.com/nivod/index"};</script>
          ''');
        case '/nivod/index':
          return _playableHls();
        case '/nivod/segment-1.ts':
          return _playableSegment();
      }
      return http.Response('not found', 404);
    });

    final lines = await RulePlaybackResolver(
      client: client,
    ).resolveRule(rule: _nivodRule, subject: _animeSubject, episode: _episode2);

    expect(lines, hasLength(1));
    expect(lines.single.available, isTrue);
    expect(lines.single.url, 'https://cdn.example.com/nivod/index');
  });

  test(
    'Sorani API resolves a fresh HLS playlist for the selected episode',
    () async {
      final client = MockClient((request) async {
        switch (request.url.path) {
          case '/api/video':
            expect(request.url.queryParameters['keyword'], _animeSubject.title);
            expect(request.headers['origin'], 'https://www.sorani.net');
            return _json('''
            {"data":{"records":[{"id":4550,"title":"测试番剧","alias":"Test Anime"}]}}
          ''');
          case '/api/video/4550':
            return _json('''
            {"data":{"episodes":[
              {"episodeId":10,"episodeOrder":1,"isVip":false},
              {"episodeId":20,"episodeOrder":2,"isVip":false}
            ]}}
          ''');
          case '/api/video/episode/20/play':
            expect(request.url.queryParameters['lineCode'], 'anime_jp_m3u8');
            return _json('''
            {"data":{"canPlay":true,"playUrl":"https://cdn.example.com/sorani/02.m3u8"}}
          ''');
          case '/sorani/02.m3u8':
            return _playableHls();
          case '/sorani/segment-1.ts':
            return _playableSegment();
        }
        return http.Response('not found', 404);
      });

      final lines = await RulePlaybackResolver(client: client).resolveRule(
        rule: _soraniRule,
        subject: _animeSubject,
        episode: _episode2,
      );

      expect(lines, hasLength(1));
      expect(lines.single.available, isTrue);
      expect(lines.single.url, 'https://cdn.example.com/sorani/02.m3u8');
      expect(lines.single.headers['Referer'], 'https://www.sorani.net/');
    },
  );

  test(
    'Animeko json-path-indexed search resolves the current episode',
    () async {
      final client = MockClient((request) async {
        switch (request.url.path) {
          case '/anime/02.m3u8':
            return _playableHls();
          case '/anime/segment-1.ts':
            return _playableSegment();
          case '/api/videos/search':
            expect(request.url.query, contains('q='));
            return http.Response(
              '{"data":{"videos":['
              '{"name":"测试番剧","slug":"anime"},'
              '{"name":"其他作品","slug":"other"}'
              ']}}',
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          case '/video/anime':
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
        rule: _animekoJsonRule,
        subject: _animeSubject,
        episode: _episode2,
      );

      expect(lines, hasLength(1));
      expect(lines.single.available, isTrue);
      expect(lines.single.url, 'https://cdn.example.com/anime/02.m3u8');
    },
  );
}

class _FakeAnimekoWebViewSniffer implements AnimekoWebViewSniffer {
  _FakeAnimekoWebViewSniffer({
    required this.observedUrl,
    this.cookieHeader = '',
  });

  final String observedUrl;
  final String cookieHeader;
  int calls = 0;

  @override
  bool get supported => true;

  @override
  Future<AnimekoWebViewSniffResult?> sniff(
    AnimekoWebViewSniffRequest request,
  ) async {
    calls += 1;
    return AnimekoWebViewSniffResult(
      videoUrl: request.matchVideo(observedUrl, request.pageUrl.toString()),
      cookieHeader: cookieHeader,
    );
  }
}

const _playableHlsManifest = '''
#EXTM3U
#EXT-X-TARGETDURATION:10
#EXTINF:10.0,
segment-1.ts
#EXT-X-ENDLIST
''';

http.Response _playableHls() => http.Response(
  _playableHlsManifest,
  200,
  headers: {'content-type': 'application/vnd.apple.mpegurl'},
);

http.Response _playableSegment() => http.Response.bytes(
  _mpegTsSample(),
  206,
  headers: {'content-type': 'video/mp2t'},
);

List<int> _mpegTsSample() {
  final bytes = List<int>.filled(188 * 2, 0);
  bytes[0] = 0x47;
  bytes[188] = 0x47;
  return bytes;
}

List<int> _mp4ProbeSample() {
  return <int>[
    0,
    0,
    0,
    24,
    ...ascii.encode('ftyp'),
    ...List<int>.filled(16, 0),
  ];
}

MockClient _singleLineClient({
  required String mediaPath,
  required http.Response Function() mediaResponse,
}) {
  return MockClient((request) async {
    if (request.url.path == mediaPath) return mediaResponse();
    switch (request.url.path) {
      case '/vod/search.html':
        return _html('''
          <div class="item">
            <strong>测试番剧</strong>
            <a class="detail" href="/detail/probe.html">详情</a>
          </div>
        ''');
      case '/detail/probe.html':
        return _html('''
          <ul class="line"><li><a href="/play/probe.html">第1集</a></li></ul>
        ''');
      case '/play/probe.html':
        return _html('''
          <script>var player={"url":"https://cdn.example.com$mediaPath"};</script>
        ''');
    }
    return http.Response('not found', 404);
  });
}

http.Response _html(String body) => http.Response(
  body,
  200,
  headers: {'content-type': 'text/html; charset=utf-8'},
);

http.Response _json(String body) => http.Response(
  body,
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
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

PlaybackLine _networkLine(String url) => PlaybackLine(
  id: 'probe-line',
  episodeId: 1,
  providerId: 'probe',
  providerName: 'Probe',
  title: 'Probe line',
  quality: '',
  format: '',
  url: url,
  available: true,
);

Uint8List _mp4TkhdSample({required int width, required int height}) {
  final bytes = Uint8List(104);
  final data = ByteData.sublistView(bytes);
  data.setUint32(0, 12, Endian.big);
  bytes.setRange(4, 8, ascii.encode('ftyp'));
  data.setUint32(12, 92, Endian.big);
  bytes.setRange(16, 20, ascii.encode('tkhd'));
  bytes[20] = 0;
  data.setUint32(96, width << 16, Endian.big);
  data.setUint32(100, height << 16, Endian.big);
  return bytes;
}

class _StreamingProbeClient extends http.BaseClient {
  String? probeRange;
  bool probeStreamCancelled = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;
    if (path == '/segment-1.ts') {
      final response = _playableSegment();
      return http.StreamedResponse(
        Stream.value(response.bodyBytes),
        response.statusCode,
        headers: response.headers,
      );
    }
    if (path == '/stream.m3u8') {
      probeRange ??= request.headers['Range'];
      late final StreamController<List<int>> controller;
      controller = StreamController<List<int>>(
        onListen: () => controller.add(utf8.encode(_playableHlsManifest)),
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

class _SplitSignatureProbeClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final sample = _mp4ProbeSample();
    return http.StreamedResponse(
      Stream<List<int>>.fromIterable(<List<int>>[
        sample.take(2).toList(growable: false),
        sample.skip(2).toList(growable: false),
      ]),
      206,
      headers: {'content-type': 'video/mp4'},
    );
  }
}

class _ChunkedPlaylistProbeClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path == '/chunked/segment-1.ts') {
      final response = _playableSegment();
      return http.StreamedResponse(
        Stream.value(response.bodyBytes),
        response.statusCode,
        headers: response.headers,
      );
    }
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

final _aikanbotRule = RulePlugin(
  id: 'custom:aikanbot:test',
  name: 'AikanbotTest',
  version: '1.0',
  source: RuleSourceKind.custom,
  contentType: RuleContentType.anime,
  engine: 'aikanbot-api',
  updatedAt: _date,
  qualityScore: 100,
  tags: const ['web'],
  baseUrl: 'https://example.com',
  searchUrl: 'https://example.com/search?q={keyword}',
  searchable: true,
  quickSearch: true,
  filterable: false,
);

final _dbkuRule = RulePlugin(
  id: 'custom:dbku:test',
  name: 'DBKUTest',
  version: '1.0',
  source: RuleSourceKind.custom,
  contentType: RuleContentType.movie,
  engine: 'XBPQ',
  updatedAt: _date,
  qualityScore: 88,
  tags: const ['movie'],
  baseUrl: 'https://example.com',
  searchUrl: 'https://example.com/vodsearch/-------------.html?wd={wd}',
  searchable: true,
  quickSearch: true,
  filterable: false,
  xbpq: const XbpqParserConfig(
    searchArray: '<li class="clearfix">&&</li>',
    searchTitle: '">&&</a>',
    searchLink: 'href="&&"',
    playArray: '<ul class="myui-content__list&&</ul>',
    playList: '<li&&</li>',
    playTitle: '">&&</a>',
    playLink: 'href="&&"',
  ),
);

final _nivodRule = RulePlugin(
  id: 'custom:nivod:test',
  name: 'NivodTest',
  version: '1.0',
  source: RuleSourceKind.custom,
  contentType: RuleContentType.movie,
  engine: 'XBPQ',
  updatedAt: _date,
  qualityScore: 87,
  tags: const ['movie'],
  baseUrl: 'https://example.com',
  searchUrl: 'https://example.com/s/-------------/?wd={wd}',
  searchable: true,
  quickSearch: true,
  filterable: false,
  xbpq: const XbpqParserConfig(
    searchArray: 'class="module-card-item-title">&&</div>',
    searchTitle: '<strong>&&</strong>',
    searchLink: 'href="&&"',
    playArray: '<div class="module-play-list-content&&</div>',
    playList: '<a&&</a>',
    playTitle: '><span>&&</span>',
    playLink: 'href="&&"',
  ),
);

final _soraniRule = RulePlugin(
  id: 'custom:sorani:test',
  name: 'SoraniTest',
  version: '1.0',
  source: RuleSourceKind.custom,
  contentType: RuleContentType.anime,
  engine: 'sorani-api',
  updatedAt: _date,
  qualityScore: 90,
  tags: const ['web'],
  baseUrl: 'https://example.com',
  searchUrl: 'https://www.sorani.net/',
  searchable: true,
  quickSearch: true,
  filterable: false,
  rawConfig: const {'lineCode': 'anime_jp_m3u8'},
);

final _animekoJsonRule = RulePlugin(
  id: 'custom:animeko:json',
  name: 'AnimekoJsonTest',
  version: '2',
  source: RuleSourceKind.custom,
  contentType: RuleContentType.anime,
  engine: 'animeko-web-selector',
  updatedAt: _date,
  qualityScore: 80,
  tags: ['Animeko', 'JSON'],
  baseUrl: 'https://example.com/',
  searchUrl: 'https://example.com/api/videos/search?q={keyword}',
  searchable: true,
  quickSearch: true,
  filterable: false,
  animeko: AnimekoWebSelectorConfig(
    searchUrl: 'https://example.com/api/videos/search?q={keyword}',
    rawBaseUrl: 'https://example.com/video/',
    subjectFormatId: 'json-path-indexed',
    channelFormatId: 'index-grouped',
    defaultResolution: '1080P',
    subjectJsonPathIndexed: AnimekoSubjectJsonPathIndexedConfig(
      selectNames: r'$.data.videos[*].name',
      selectLinks: r'$.data.videos[*].slug',
    ),
    channelFlattened: AnimekoChannelFlattenedConfig(
      selectEpisodeLists: '.playlist',
      selectEpisodesFromList: 'a',
      matchEpisodeSortFromName: r'第\s*(?<ep>\d+)',
    ),
    matchVideoUrl: r'url:\s*"(?<v>https?:\/\/.+\.(m3u8|mp4))"',
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
