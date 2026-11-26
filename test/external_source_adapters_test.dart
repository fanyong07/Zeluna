import 'dart:convert';

import 'package:anime/src/sources/external_source_adapters.dart';
import 'package:anime/src/sources/source_catalog_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('M3uSourceAdapter', () {
    test('keeps different channel names that share a generic tvg-id', () {
      final channels = const M3uPlaylistParser().parse(
        source: _goodM3uSource,
        playlistUri: Uri.parse('https://feeds.example/live/list.m3u'),
        text: '''
#EXTM3U
#EXTINF:-1 tvg-id="咪咕体育" group-title="体育",咪咕足球
https://stream.example/football.m3u8
#EXTINF:-1 tvg-id="咪咕体育" group-title="体育",咪咕篮球
https://stream.example/basketball.m3u8
''',
      );

      expect(channels.map((item) => item.name), ['咪咕足球', '咪咕篮球']);
      expect(channels.map((item) => item.id).toSet(), hasLength(2));
    });

    test(
      'searches enabled playlists, isolates broken sources, and builds playback models',
      () async {
        final requests = <Uri>[];
        final client = MockClient((request) async {
          requests.add(request.url);
          if (request.url.host == 'broken.example') {
            return http.Response('gone', 404);
          }
          return _utf8Response(_m3uFixture);
        });
        final adapter = M3uSourceAdapter(client: client);
        addTearDown(adapter.close);

        final batch = await adapter.search(
          sources: const [_goodM3uSource, _brokenM3uSource, _disabledM3uSource],
          query: 'CCTV 1',
        );

        expect(
          batch.items,
          hasLength(1),
          reason: batch.failures.map((item) => item.message).join(' | '),
        );
        expect(batch.failures, hasLength(1));
        expect(batch.failures.single.sourceId, _brokenM3uSource.id);
        expect(requests.map((item) => item.host), [
          'feeds.example',
          'broken.example',
        ]);

        final channel = batch.items.single;
        expect(channel.name, 'CCTV-1 综合');
        expect(channel.group, '央视频道');
        expect(channel.tvgId, 'cctv1');
        expect(
          channel.streamUri.toString(),
          'https://feeds.example/live/streams/cctv1.m3u8',
        );
        expect(channel.logoUrl, 'https://feeds.example/logo/cctv1.png');
        expect(channel.headers['Referer'], 'https://media.example/watch');
        expect(channel.headers['User-Agent'], 'Fixture Agent');
        expect(channel.headers['Origin'], 'https://media.example');
        expect(channel.headers['X-Source'], 'catalog');
        expect(channel.headers['Authorization'], 'Bearer same-origin');
        expect(channel.headers['Cookie'], 'sid=same-origin');
        expect(channel.headers, isNot(contains('Host')));
        expect(channel.headers, isNot(contains('Bad')));

        final line = channel.toPlaybackLine();
        expect(line.available, isTrue);
        expect(line.format, 'HLS');
        expect(line.isLive, isTrue);
        expect(line.adaptive, isFalse);
        expect(line.url, channel.streamUri.toString());
        expect(channel.requiresExternalClient, isFalse);

        final subject = channel.toSubject();
        final episode = channel.toEpisode();
        final detail = channel.toDetailBundle();
        expect(subject.id, channel.subjectId);
        expect(subject.source, startsWith('m3u-channel:'));
        expect(episode.subjectId, subject.id);
        expect(detail.subject.id, subject.id);
        expect(detail.episodes.single.id, episode.id);

        final resolved = await adapter.resolveSubject(
          sources: const [_goodM3uSource],
          subject: subject,
        );
        expect(resolved?.id, channel.id);
        expect(
          await adapter.resolveSubject(
            sources: const [_disabledM3uSource],
            subject: subject,
          ),
          isNull,
        );

        final ipv6Batch = await adapter.search(
          sources: const [_goodM3uSource],
          query: '公网 IPv6',
        );
        expect(ipv6Batch.items, hasLength(1));
        expect(ipv6Batch.items.single.streamUri.host, '2606:4700:4700::1111');
      },
    );

    test(
      'reuses successful and failed caches until their TTL expires',
      () async {
        var now = DateTime(2026, 7, 18, 12);
        var goodRequests = 0;
        var brokenRequests = 0;
        final client = MockClient((request) async {
          if (request.url.host == 'broken.example') {
            brokenRequests++;
            return http.Response('gone', 404);
          }
          goodRequests++;
          return _utf8Response(_m3uFixture);
        });
        final adapter = M3uSourceAdapter(
          client: client,
          cacheTtl: const Duration(minutes: 5),
          failureTtl: const Duration(seconds: 20),
          clock: () => now,
        );
        addTearDown(adapter.close);

        await adapter.search(
          sources: const [_goodM3uSource, _brokenM3uSource],
          query: 'CCTV',
        );
        await adapter.search(
          sources: const [_goodM3uSource, _brokenM3uSource],
          query: '央视频道',
        );
        expect(goodRequests, 1);
        expect(brokenRequests, 1);

        now = now.add(const Duration(seconds: 21));
        await adapter.search(
          sources: const [_goodM3uSource, _brokenM3uSource],
          query: 'CCTV',
        );
        expect(goodRequests, 1);
        expect(brokenRequests, 2);

        now = now.add(const Duration(minutes: 5));
        await adapter.search(sources: const [_goodM3uSource], query: 'CCTV');
        expect(goodRequests, 2);
      },
    );

    test(
      'keeps channel identity stable when a playlist rotates stream URLs',
      () async {
        var now = DateTime(2026, 7, 18, 12);
        var requestCount = 0;
        final client = MockClient((request) async {
          requestCount++;
          return _utf8Response('''
#EXTM3U
#EXTINF:-1 tvg-id="cctv1" group-title="央视频道",CCTV-1 综合
https://stream.example/live/cctv1.m3u8?token=$requestCount
''');
        });
        final adapter = M3uSourceAdapter(
          client: client,
          cacheTtl: const Duration(seconds: 10),
          clock: () => now,
        );
        addTearDown(adapter.close);

        final first = (await adapter.search(
          sources: const [_goodM3uSource],
          query: 'CCTV-1',
        )).items.single;
        final persistedSubject = first.toSubject();
        now = now.add(const Duration(seconds: 11));
        final second = (await adapter.search(
          sources: const [_goodM3uSource],
          query: 'CCTV-1',
        )).items.single;

        expect(second.id, first.id);
        expect(second.subjectId, first.subjectId);
        expect(second.toSubject().source, persistedSubject.source);
        expect(second.streamUri, isNot(first.streamUri));
        final resolved = await adapter.resolveSubject(
          sources: const [_goodM3uSource],
          subject: persistedSubject,
        );
        expect(resolved?.streamUri, second.streamUri);
      },
    );

    test(
      'turns timeouts and oversized responses into isolated failures',
      () async {
        final timeoutClient = MockClient((request) async {
          await Future<void>.delayed(const Duration(milliseconds: 40));
          return _utf8Response(_m3uFixture);
        });
        final timeoutAdapter = M3uSourceAdapter(
          client: timeoutClient,
          timeout: const Duration(milliseconds: 5),
        );
        addTearDown(timeoutAdapter.close);
        final timeoutResult = await timeoutAdapter.search(
          sources: const [_goodM3uSource],
          query: 'CCTV',
        );
        expect(timeoutResult.items, isEmpty);
        expect(timeoutResult.failures.single.message, contains('超时'));

        final oversizedClient = MockClient((request) async {
          return _utf8Response(_m3uFixture);
        });
        final oversizedAdapter = M3uSourceAdapter(
          client: oversizedClient,
          maxPlaylistBytes: 12,
        );
        addTearDown(oversizedAdapter.close);
        final oversizedResult = await oversizedAdapter.search(
          sources: const [_goodM3uSource],
          query: 'CCTV',
        );
        expect(oversizedResult.items, isEmpty);
        expect(oversizedResult.failures.single.message, contains('读取上限'));
      },
    );

    test(
      'blocks private sources and private redirect targets before fetching',
      () async {
        var privateRequests = 0;
        final privateClient = MockClient((request) async {
          privateRequests++;
          return _utf8Response(_m3uFixture);
        });
        final privateAdapter = M3uSourceAdapter(client: privateClient);
        addTearDown(privateAdapter.close);
        final privateResult = await privateAdapter.search(
          sources: const [_privateM3uSource, _fileM3uSource],
          query: 'CCTV',
        );
        expect(privateResult.items, isEmpty);
        expect(privateResult.failures, hasLength(2));
        expect(privateRequests, 0);

        var redirectRequests = 0;
        final redirectClient = MockClient((request) async {
          redirectRequests++;
          return http.Response(
            '',
            302,
            headers: {'location': 'http://127.0.0.1/private.m3u'},
          );
        });
        final redirectAdapter = M3uSourceAdapter(client: redirectClient);
        addTearDown(redirectAdapter.close);
        final redirectResult = await redirectAdapter.search(
          sources: const [_goodM3uSource],
          query: 'CCTV',
        );
        expect(redirectResult.items, isEmpty);
        expect(redirectResult.failures, hasLength(1));
        expect(redirectRequests, 1);
      },
    );

    test(
      'uses the final playlist URI and strips origin-bound headers on redirects',
      () async {
        final requests = <http.Request>[];
        final client = MockClient((request) async {
          requests.add(request);
          if (request.url.host == 'feeds.example') {
            return http.Response(
              '',
              302,
              headers: {
                'location': 'https://cdn.example/catalog/live/list.m3u',
              },
            );
          }
          return _utf8Response('''
#EXTM3U
#EXTINF:-1 tvg-id="cctv1",CCTV-1 综合
#EXTHTTP:{"X-Channel":"explicit"}
streams/cctv1.m3u8
''');
        });
        final adapter = M3uSourceAdapter(client: client);
        addTearDown(adapter.close);
        const source = VideoSource(
          id: 'm3u:redirect',
          name: '重定向直播',
          kind: VideoSourceKind.liveM3u,
          importUrl: 'https://feeds.example/start.m3u',
          baseUrl: 'https://feeds.example/start.m3u',
          headers: {
            'Authorization': 'Bearer secret',
            'Cookie': 'sid=secret',
            'Origin': 'https://site.example',
            'Referer': 'https://site.example/watch',
            'X-Source': 'private',
            'User-Agent': 'Anime test',
          },
        );

        final result = await adapter.search(
          sources: const [source],
          query: 'CCTV-1',
        );

        expect(result.failures, isEmpty);
        expect(
          result.items.single.streamUri.toString(),
          'https://cdn.example/catalog/live/streams/cctv1.m3u8',
        );
        expect(requests, hasLength(2));
        expect(requests.first.headers['Authorization'], 'Bearer secret');
        expect(requests.last.headers['Authorization'], isNull);
        expect(requests.last.headers['Cookie'], isNull);
        expect(requests.last.headers['Origin'], isNull);
        expect(requests.last.headers['Referer'], isNull);
        expect(requests.last.headers['X-Source'], isNull);
        expect(requests.last.headers['User-Agent'], 'Anime test');
        final lineHeaders = result.items.single.headers;
        expect(lineHeaders['User-Agent'], 'Anime test');
        expect(lineHeaders['X-Channel'], 'explicit');
        expect(lineHeaders['Authorization'], isNull);
        expect(lineHeaders['Cookie'], isNull);
        expect(lineHeaders['Origin'], isNull);
        expect(lineHeaders['Referer'], isNull);
        expect(lineHeaders['X-Source'], isNull);
      },
    );
  });

  group('DmhySourceAdapter', () {
    test(
      'parses public search rows and models magnets as external-only lines',
      () async {
        var requests = 0;
        final client = MockClient((request) async {
          requests++;
          expect(request.url.host, 'dmhy.org');
          expect(request.url.queryParameters['keyword'], '葬送的芙莉莲');
          return _utf8Response(_dmhyFixture, contentType: 'text/html');
        });
        final adapter = DmhySourceAdapter(client: client);
        addTearDown(adapter.close);

        final first = await adapter.search(
          sources: const [_dmhySource, _disabledDmhySource],
          query: '葬送的芙莉莲',
        );
        final second = await adapter.search(
          sources: const [_dmhySource],
          query: '葬送的芙莉莲',
        );

        expect(requests, 1);
        expect(
          first.failures,
          isEmpty,
          reason: first.failures.map((item) => item.message).join(' | '),
        );
        expect(first.items, hasLength(1));
        expect(second.items, hasLength(1));
        final item = first.items.single;
        expect(item.title, '测试字幕组 葬送的芙莉莲 01');
        expect(item.category, '動畫');
        expect(item.sizeLabel, '1.2GB');
        expect(item.seeders, 12);
        expect(item.downloads, 34);
        expect(item.completions, 56);
        expect(item.publisher, 'fixture-user');
        expect(item.postedAt, DateTime(2026, 7, 18, 12, 30));
        expect(
          item.detailUri.toString(),
          'https://dmhy.org/topics/view/1.html',
        );
        expect(item.requiresExternalClient, isTrue);

        final line = item.toExternalPlaybackLine(episodeId: 99);
        expect(line.available, isFalse);
        expect(line.format, 'Magnet');
        expect(line.url, startsWith('magnet:?xt=urn:btih:'));
        expect(line.message, contains('外部客户端'));
      },
    );

    test(
      'isolates unsupported BT sources and blocks cross-host redirects',
      () async {
        var requests = 0;
        final client = MockClient((request) async {
          requests++;
          return http.Response(
            '',
            302,
            headers: {'location': 'https://evil.example/redirected'},
          );
        });
        final adapter = DmhySourceAdapter(client: client);
        addTearDown(adapter.close);

        final result = await adapter.search(
          sources: const [_dmhySource, _unsupportedTorrentSource],
          query: '测试',
        );

        expect(result.items, isEmpty);
        expect(result.failures, hasLength(2));
        expect(
          result.failures.map((item) => item.sourceId),
          contains(_unsupportedTorrentSource.id),
        );
        expect(requests, 1);
      },
    );

    test(
      'reports an unsafe DMHY endpoint without masking the real error',
      () async {
        var requests = 0;
        final adapter = DmhySourceAdapter(
          client: MockClient((request) async {
            requests++;
            return http.Response('unexpected', 500);
          }),
        );
        addTearDown(adapter.close);
        const unsafe = VideoSource(
          id: 'torrent:unsafe-dmhy',
          name: '不安全 BT',
          kind: VideoSourceKind.torrent,
          importUrl: 'https://dmhy.org/',
          baseUrl: 'https://dmhy.org/',
          endpoints: {'search': 'http://127.0.0.1/search?keyword={keyword}'},
          rawConfig: {'site': 'dmhy'},
          enabled: true,
        );

        final result = await adapter.search(
          sources: const [unsafe],
          query: '测试',
        );

        expect(result.items, isEmpty);
        expect(result.failures, hasLength(1));
        expect(result.failures.single.message, contains('地址'));
        expect(
          result.failures.single.message,
          isNot(contains('LateInitialization')),
        );
        expect(requests, 0);
      },
    );
  });

  group('SourceUriPolicy', () {
    const policy = SourceUriPolicy();

    test('allows public HTTP(S) and rejects local or unsafe forms', () {
      expect(
        policy.isAllowed(Uri.parse('https://feeds.example/live.m3u')),
        isTrue,
      );
      expect(policy.isAllowed(Uri.parse('http://8.8.8.8/live.m3u8')), isTrue);
      expect(
        policy.isAllowed(Uri.parse('http://[2606:4700:4700::1111]/live.m3u8')),
        isTrue,
      );
      for (final value in const [
        'file:///tmp/live.m3u',
        'http://localhost/live.m3u',
        'http://127.0.0.1/live.m3u',
        'http://10.0.0.1/live.m3u',
        'http://169.254.169.254/latest/meta-data',
        'http://[::]/live.m3u',
        'http://[::1]/live.m3u',
        'http://[fc00::1]/live.m3u',
        'http://[fd12:3456::1]/live.m3u',
        'http://[fe80::1]/live.m3u',
        'http://[ff02::1]/live.m3u',
        'http://[::ffff:127.0.0.1]/live.m3u',
        'http://[::ffff:8.8.8.8]/live.m3u',
        'http://[fe80::1%25eth0]/live.m3u',
        'http://2130706433/live.m3u',
        'http://0177.0.0.1/live.m3u',
        'http://0x7f.0.0.1/live.m3u',
        'https://user:pass@example.com/live.m3u',
      ]) {
        expect(policy.isAllowed(Uri.parse(value)), isFalse, reason: value);
      }
    });
  });
}

const _goodM3uSource = VideoSource(
  id: 'm3u:good',
  name: '测试直播',
  kind: VideoSourceKind.liveM3u,
  importUrl: 'https://feeds.example/live/list.m3u',
  baseUrl: 'https://feeds.example/live/list.m3u',
  headers: {
    'Authorization': 'Bearer same-origin',
    'Cookie': 'sid=same-origin',
    'X-Source': 'catalog',
    'Host': 'blocked',
    'Bad': 'line\nbreak',
  },
  enabled: true,
);

const _brokenM3uSource = VideoSource(
  id: 'm3u:broken',
  name: '失效直播',
  kind: VideoSourceKind.liveM3u,
  importUrl: 'https://broken.example/live.m3u',
  baseUrl: 'https://broken.example/live.m3u',
  enabled: true,
);

const _disabledM3uSource = VideoSource(
  id: 'm3u:disabled',
  name: '关闭直播',
  kind: VideoSourceKind.liveM3u,
  importUrl: 'https://disabled.example/live.m3u',
  baseUrl: 'https://disabled.example/live.m3u',
  enabled: false,
);

const _privateM3uSource = VideoSource(
  id: 'm3u:private',
  name: '内网直播',
  kind: VideoSourceKind.liveM3u,
  importUrl: 'http://192.168.1.2/live.m3u',
  baseUrl: 'http://192.168.1.2/live.m3u',
  enabled: true,
);

const _fileM3uSource = VideoSource(
  id: 'm3u:file',
  name: '本地文件',
  kind: VideoSourceKind.liveM3u,
  importUrl: 'file:///tmp/live.m3u',
  baseUrl: 'file:///tmp/live.m3u',
  enabled: true,
);

const _dmhySource = VideoSource(
  id: 'torrent:dmhy',
  name: '动漫花园',
  kind: VideoSourceKind.torrent,
  importUrl: 'https://dmhy.org/',
  baseUrl: 'https://dmhy.org/',
  endpoints: {'search': 'https://dmhy.org/topics/list?keyword={keyword}'},
  rawConfig: {'site': 'dmhy', 'format': 'torrent'},
  supportsSearch: true,
  executableUnsupported: true,
  enabled: true,
);

const _disabledDmhySource = VideoSource(
  id: 'torrent:dmhy-disabled',
  name: '关闭的动漫花园',
  kind: VideoSourceKind.torrent,
  importUrl: 'https://dmhy.org/',
  baseUrl: 'https://dmhy.org/',
  endpoints: {'search': 'https://dmhy.org/topics/list?keyword={keyword}'},
  rawConfig: {'site': 'dmhy'},
  enabled: false,
);

const _unsupportedTorrentSource = VideoSource(
  id: 'torrent:unsupported',
  name: '未支持 BT',
  kind: VideoSourceKind.torrent,
  importUrl: 'https://torrent.example/',
  baseUrl: 'https://torrent.example/',
  endpoints: {'search': 'https://torrent.example/search?q={keyword}'},
  rawConfig: {'site': 'other'},
  enabled: true,
);

const _m3uFixture = '''
\uFEFF#EXTM3U
#EXTINF:-1 tvg-id="cctv1" tvg-name="央视一套" tvg-logo="/logo/cctv1.png" group-title="央视频道",CCTV-1 综合
#EXTVLCOPT:http-referrer=https://media.example/watch
#EXTVLCOPT:http-user-agent=Fixture Agent
streams/cctv1.m3u8|Origin=https%3A%2F%2Fmedia.example
#EXTINF:-1 group-title="IPv6",公网 IPv6
http://[2606:4700:4700::1111]/live.m3u8
#EXTINF:-1 group-title="内网",内网频道
http://127.0.0.1/private.m3u8
#EXTINF:-1 group-title="危险",本地文件
file:///tmp/video.mp4
#EXTINF:-1 group-title="重复",重复频道
streams/cctv1.m3u8
''';

const _hash = '0123456789abcdef0123456789abcdef01234567';

const _dmhyFixture =
    '''
<!doctype html>
<html><body>
<table id="topic_list"><tbody>
  <tr>
    <td>2026/07/18 12:30</td>
    <td><a>動畫</a></td>
    <td class="title"><a href="/topics/view/1.html">测试字幕组 <span>葬送的芙莉莲</span> 01</a></td>
    <td><a class="arrow-magnet" href="magnet:?xt=urn:btih:$_hash&amp;dn=fixture">磁力</a></td>
    <td>1.2GB</td><td>12</td><td>34</td><td>56</td><td>fixture-user</td>
  </tr>
  <tr>
    <td>2026/07/18 12:31</td><td>動畫</td>
    <td class="title"><a href="/topics/view/duplicate.html">重复资源</a></td>
    <td><a href="magnet:?xt=urn:btih:$_hash">磁力</a></td>
    <td>1.2GB</td><td>-</td><td>-</td><td>-</td><td>duplicate</td>
  </tr>
  <tr>
    <td>2026/07/18 12:32</td><td>動畫</td>
    <td class="title"><a href="/topics/view/invalid.html">无效磁力</a></td>
    <td><a href="magnet:?xt=urn:btih:short">磁力</a></td>
    <td>10MB</td><td>-</td><td>-</td><td>-</td><td>invalid</td>
  </tr>
</tbody></table>
</body></html>
''';

http.Response _utf8Response(
  String body, {
  int statusCode = 200,
  String contentType = 'text/plain',
}) {
  return http.Response.bytes(
    utf8.encode(body),
    statusCode,
    headers: {'content-type': '$contentType; charset=utf-8'},
  );
}
