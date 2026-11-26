import 'dart:convert';
import 'dart:io';

import 'package:anime/src/data/zeluna_backend_playback_repository.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/domain/client_media_resolver.dart';
import 'package:anime/src/player/playback_line_display.dart';
import 'package:anime/src/playback/playback_discovery_controller.dart';
import 'package:anime/src/rules/animeko_webview_sniffer.dart';
import 'package:anime/src/rules/drpy_runtime.dart';
import 'package:anime/src/rules/rule_playback_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _subject = AnimeSubject(
  id: 400602,
  title: '葬送的芙莉莲',
  originalTitle: 'Sousou no Frieren',
  summary: '',
  coverUrl: null,
  bannerUrl: null,
  date: '2023',
  platform: 'TV',
  language: '日语',
  region: '日本',
  status: '完结',
  categories: [],
  tags: [],
  totalEpisodes: 28,
);
const _episode = AnimeEpisode(
  id: 1,
  subjectId: 400602,
  number: 1,
  title: '第1集',
  airdate: null,
  duration: '',
  description: '',
);

Map<String, Object> _descriptor() => {
  'kind': 'kazumi_page_v1',
  'page_url': 'https://chapter.example/play/1.html',
  'referer': 'https://chapter.example/detail/1.html',
  'rule_id': 'new-independent-rule',
  'rule_name': '独立规则',
  'user_agent': 'Rule-UA/1',
  'page_hosts': ['chapter.example', 'player.example'],
  'media_hosts': ['cdn.example'],
};

PlaybackLine _task() => PlaybackLine(
  id: 'client-resolver:one',
  episodeId: 1,
  providerId: 'crawler.kazumi',
  providerName: '独立规则',
  title: '线路一',
  quality: '',
  format: 'auto',
  clientResolver: ClientMediaResolverDescriptor.fromJson(_descriptor()),
  requiresClientProbe: true,
  publicHttpOnly: true,
  queryLocation: 'hybrid',
  diagnosticStatus: PlaybackDiscoveryStatus.clientResolverRequired,
  queried: true,
  episodeFound: true,
);

DrpyRuntime _publicRuntime() =>
    DrpyRuntime(addressLookup: (_) async => [InternetAddress('93.184.216.34')]);

http.Response _media(http.Request request) {
  expect(request.url.host, 'cdn.example');
  expect(
    request.headers.keys.map((k) => k.toLowerCase()),
    isNot(contains('authorization')),
  );
  final bytes = <int>[
    0,
    0,
    0,
    24,
    ...ascii.encode('ftyp'),
    ...List.filled(16, 0),
  ];
  return http.Response.bytes(
    bytes,
    206,
    headers: {'content-type': 'video/mp4'},
  );
}

void main() {
  test(
    'trusted inventory retains an explicit chapter task without a fake media URL',
    () async {
      final repository = ZelunaBackendPlaybackRepository(
        baseUrl: 'https://backend.example',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode([
              {
                'url': '',
                'source': 'crawler:kazumi:independent:one',
                'catalog_source': 'kazumi',
                'provider_id': 'crawler.kazumi',
                'provider_name': '独立规则',
                'available': false,
                'status': 'client_resolver_required',
                'route_status': 'client_resolver_required',
                'diagnostic_status': 'matched_no_episode',
                'client_resolver': _descriptor(),
                'episode_found': true,
                'query_location': 'hybrid',
              },
            ]),
            200,
            headers: {'content-type': 'application/json'},
          ),
        ),
      );
      final lines = await repository.linesForEpisode(_subject, _episode);
      final line = lines.single;
      expect(line.url, isNull);
      expect(line.available, isFalse);
      expect(line.serverVerified, isFalse);
      expect(line.requiresClientProbe, isTrue);
      expect(line.clientResolver?.pageUrl.path, '/play/1.html');
      expect(
        line.diagnosticStatus,
        PlaybackDiscoveryStatus.clientResolverRequired,
      );
      expect(line.id, startsWith('client-resolver:'));
      expect(line.queryLocation, 'hybrid');
      expect(playbackLineProviderLabel(line), '独立规则');
      expect(playbackLineFailureLabel(line), '本机解析中');
    },
  );

  for (final mutation in <Map<String, Object>>[
    {'page_url': 'file:///etc/passwd'},
    {'page_url': 'http://127.0.0.1/player.html'},
    {'page_url': 'https://user:pass@chapter.example/play/1.html'},
    {
      'page_hosts': ['*'],
    },
    {
      'media_hosts': ['*'],
    },
    {'media_hosts': <String>[]},
    {'referer': 'https://other.example/'},
    {'user_agent': 'ok\r\nAuthorization: secret'},
  ]) {
    test('descriptor rejects malformed or unbounded task $mutation', () {
      final descriptor = {..._descriptor(), ...mutation};
      expect(ClientMediaResolverDescriptor.fromJson(descriptor), isNull);
    });
  }

  test(
    'current chapter player resolves then probes media with the player referer',
    () async {
      final calls = <String>[];
      final client = MockClient((request) async {
        calls.add(request.url.toString());
        if (request.url.host == 'chapter.example') {
          return http.Response(
            '''<script>var player_aaaa={"encrypt":0,"url":"https://cdn.example/current.mp4","url_next":"https://cdn.example/next.mp4","metadata":{"nested":true}};</script>''',
            200,
          );
        }
        expect(request.url.path, '/current.mp4');
        expect(
          request.headers['referer'],
          'https://chapter.example/play/1.html',
        );
        expect(request.headers['user-agent'], 'Rule-UA/1');
        return _media(request);
      });
      final resolver = RulePlaybackResolver(
        client: client,
        drpyRuntime: _publicRuntime(),
      );
      final result = await resolver.verifyPlaybackLine(
        line: _task(),
        enrichMetadata: false,
      );
      expect(result.id, _task().id);
      expect(result.url, 'https://cdn.example/current.mp4');
      expect(result.clientResolver, isNull);
      expect(result.clientVerified, isTrue);
      expect(result.available, isTrue);
      expect(result.serverVerified, isFalse);
      expect(calls.any((url) => url.contains('next.mp4')), isFalse);
    },
  );

  test(
    'nested iframe keeps correct referer and is verified before available',
    () async {
      final client = MockClient((request) async {
        if (request.url.host == 'chapter.example') {
          return http.Response(
            '<iframe src="https://player.example/embed/1"></iframe>',
            200,
          );
        }
        if (request.url.host == 'player.example') {
          return http.Response(
            '<video src="https://cdn.example/episode.mp4"></video>',
            200,
          );
        }
        expect(request.headers['referer'], 'https://player.example/embed/1');
        return _media(request);
      });
      final result = await RulePlaybackResolver(
        client: client,
        drpyRuntime: _publicRuntime(),
      ).verifyPlaybackLine(line: _task(), enrichMetadata: false);
      expect(result.clientVerified, isTrue);
      expect(result.headers['Referer'], 'https://player.example/embed/1');
    },
  );

  test(
    'chapter media redirect stays within the explicit media host grant',
    () async {
      var forbiddenRequests = 0;
      final client = MockClient((request) async {
        if (request.url.host == 'chapter.example') {
          return http.Response(
            '<video src="https://cdn.example/episode.mp4"></video>',
            200,
          );
        }
        if (request.url.host == 'cdn.example') {
          return http.Response(
            '',
            302,
            headers: {'location': 'https://other-public.example/episode.mp4'},
          );
        }
        forbiddenRequests++;
        return _media(request);
      });
      final result = await RulePlaybackResolver(
        client: client,
        drpyRuntime: _publicRuntime(),
      ).verifyPlaybackLine(line: _task(), enrichMetadata: false);
      expect(result.available, isFalse);
      expect(result.clientVerified, isFalse);
      expect(forbiddenRequests, 0);
    },
  );

  test(
    'chapter HLS child segment cannot escape the explicit host grant',
    () async {
      var forbiddenRequests = 0;
      final client = MockClient((request) async {
        if (request.url.host == 'chapter.example') {
          return http.Response(
            '<video src="https://cdn.example/episode.m3u8"></video>',
            200,
          );
        }
        if (request.url.host == 'cdn.example') {
          return http.Response(
            '#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:10,\nhttps://other-public.example/segment.ts\n#EXT-X-ENDLIST\n',
            200,
            headers: {'content-type': 'application/vnd.apple.mpegurl'},
          );
        }
        forbiddenRequests++;
        return http.Response.bytes(List.filled(1024, 0x47), 206);
      });
      final result = await RulePlaybackResolver(
        client: client,
        drpyRuntime: _publicRuntime(),
      ).verifyPlaybackLine(line: _task(), enrichMetadata: false);
      expect(result.available, isFalse);
      expect(result.clientVerified, isFalse);
      expect(forbiddenRequests, 0);
    },
  );

  test(
    'unresolved current player never falls through to next episode or ad URL',
    () async {
      var mediaCalls = 0;
      final client = MockClient((request) async {
        if (request.url.host != 'chapter.example') mediaCalls++;
        return http.Response(
          '''<script>var player_aaaa={"url":"opaque","url_next":"https://cdn.example/next.mp4"}; var ad="https://cdn.example/ad.mp4";</script>''',
          200,
        );
      });
      final result = await RulePlaybackResolver(
        client: client,
        drpyRuntime: _publicRuntime(),
        animekoWebViewSniffer: _Sniffer(null),
      ).verifyPlaybackLine(line: _task(), enrichMetadata: false);
      expect(result.available, isFalse);
      expect(result.url, isNull);
      expect(result.diagnosticStatus, PlaybackDiscoveryStatus.routeUnavailable);
      expect(mediaCalls, 0);
    },
  );

  test(
    'JavaScript chapter uses explicit bounded browser task, then validates media',
    () async {
      final sniffer = _Sniffer('https://cdn.example/javascript.mp4');
      final client = MockClient((request) async {
        if (request.url.host == 'chapter.example') {
          return http.Response('<script src="/player.js"></script>', 200);
        }
        return _media(request);
      });
      final result = await RulePlaybackResolver(
        client: client,
        drpyRuntime: _publicRuntime(),
        animekoWebViewSniffer: sniffer,
      ).verifyPlaybackLine(line: _task(), enrichMetadata: false);
      expect(result.clientVerified, isTrue);
      expect(sniffer.calls, 1);
      expect(sniffer.last!.manifest.mediaDomains, ['cdn.example']);
      expect(sniffer.last!.manifest.cookiePolicy.name, 'none');
    },
  );

  test(
    'descriptor task and resolved request retain a stable replacement id',
    () {
      final pending = _task();
      final resolved = PlaybackLine(
        id: pending.id,
        episodeId: 1,
        providerId: pending.providerId,
        providerName: pending.providerName,
        title: 'resolved',
        quality: '',
        format: 'MP4',
        url: 'https://cdn.example/episode.mp4',
        available: true,
        clientVerified: true,
      );
      final merged = replacePlaybackLine([pending], resolved);
      expect(merged, [same(resolved)]);
    },
  );

  test('route status is not upgraded by the provider summary', () async {
    final repository = ZelunaBackendPlaybackRepository(
      baseUrl: 'https://backend.example',
      client: MockClient(
        (_) async => http.Response(
          jsonEncode([
            {
              'url': 'https://cdn.example/candidate.mp4',
              'source': 'crawler:animeko:other-rule:line',
              'provider_id': 'crawler.animeko',
              'provider_name': 'other-rule',
              'available': false,
              'status': 'client_probe_required',
              'diagnostic_status': 'server_verified',
            },
            {
              'url': '',
              'available': false,
              'source': 'crawler:kazumi',
              'diagnostic_status': 'unsupported_content_type',
              'status': 'unavailable',
            },
          ]),
          200,
        ),
      ),
    );
    final lines = await repository.linesForEpisode(_subject, _episode);
    expect(
      lines.first.diagnosticStatus,
      PlaybackDiscoveryStatus.clientProbeRequired,
    );
    expect(playbackLineProviderLabel(lines.first), 'other-rule');
    expect(
      lines.last.diagnosticStatus,
      PlaybackDiscoveryStatus.unsupportedContentType,
    );
    expect(playbackLineFailureLabel(lines.last), '不支持此内容类型');
  });
}

final class _Sniffer implements AnimekoWebViewSniffer {
  _Sniffer(this.url);
  final String? url;
  var calls = 0;
  AnimekoWebViewSniffRequest? last;
  @override
  bool get supported => true;
  @override
  Future<AnimekoWebViewSniffResult?> sniff(
    AnimekoWebViewSniffRequest request,
  ) async {
    calls++;
    last = request;
    return url == null ? null : AnimekoWebViewSniffResult(videoUrl: url);
  }
}
