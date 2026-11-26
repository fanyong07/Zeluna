import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:anime/src/core/network/network_security.dart';
import 'package:anime/src/data/playback_source_repository.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/domain/client_media_resolver.dart';
import 'package:anime/src/domain/episode_matching.dart';
import 'package:anime/src/playback/catalog_short_clip.dart';
import 'package:anime/src/playback/playback_discovery_controller.dart';
import 'package:anime/src/rules/rule_importer.dart';
import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/rules/rule_playback_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Uint8List _mp4SampleWithMvhd({
  int version = 0,
  int timescale = 1000,
  required int duration,
}) {
  final ftyp = BytesBuilder()
    ..add([0, 0, 0, 16])
    ..add(ascii.encode('ftyp'))
    ..add(ascii.encode('isom'))
    ..add([0, 0, 0, 0]);
  final mvhdPayload = ByteData(version == 0 ? 100 : 112);
  mvhdPayload.setUint8(0, version);
  if (version == 0) {
    mvhdPayload.setUint32(12, timescale, Endian.big);
    mvhdPayload.setUint32(16, duration, Endian.big);
  } else {
    mvhdPayload.setUint32(20, timescale, Endian.big);
    mvhdPayload.setUint32(24, (duration >> 32) & 0xFFFFFFFF, Endian.big);
    mvhdPayload.setUint32(28, duration & 0xFFFFFFFF, Endian.big);
  }
  final mvhdSize = 8 + mvhdPayload.lengthInBytes;
  final mvhd = BytesBuilder()
    ..add(_uint32(mvhdSize))
    ..add(ascii.encode('mvhd'))
    ..add(mvhdPayload.buffer.asUint8List());
  final mvhdBytes = mvhd.takeBytes();
  final moov = BytesBuilder()
    ..add(_uint32(8 + mvhdBytes.length))
    ..add(ascii.encode('moov'))
    ..add(mvhdBytes);
  return (BytesBuilder()
        ..add(ftyp.takeBytes())
        ..add(moov.takeBytes()))
      .takeBytes();
}

List<int> _uint32(int value) => [
  (value >> 24) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 8) & 0xFF,
  value & 0xFF,
];

void main() {
  group('P0 mobile stability bounds in PlaybackDiscoveryController', () {
    ClientMediaResolverDescriptor resolverDescriptor(int index) =>
        ClientMediaResolverDescriptor.fromJson({
          'kind': 'kazumi_page_v1',
          'page_url': 'https://chapter-$index.example/play/1.html',
          'referer': 'https://chapter-$index.example/detail/1.html',
          'rule_id': 'rule-$index',
          'rule_name': 'Rule $index',
          'user_agent': '',
          'page_hosts': ['chapter-$index.example'],
          'media_hosts': ['cdn-$index.example'],
        })!;

    PlaybackLine webViewLine(int index) => PlaybackLine(
      id: 'wv:$index',
      episodeId: _episode.id,
      providerId: 'crawler.kazumi',
      providerName: 'Rule $index',
      title: '本集章节 $index',
      quality: '',
      format: 'auto',
      clientResolver: resolverDescriptor(index),
      requiresClientProbe: true,
      diagnosticStatus: PlaybackDiscoveryStatus.clientResolverRequired,
    );

    PlaybackLine httpProbeLine(int index) => PlaybackLine(
      id: 'http:$index',
      episodeId: _episode.id,
      providerId: 'aggregate.maccms',
      providerName: 'Site $index',
      title: '线路 $index',
      quality: '1080P',
      format: 'hls',
      url: 'https://probe-$index.example/index.m3u8',
      requiresClientProbe: true,
      diagnosticStatus: PlaybackDiscoveryStatus.clientProbeRequired,
    );

    PlaybackLine readyLine(int index) => PlaybackLine(
      id: 'ready:$index',
      episodeId: _episode.id,
      providerId: 'aggregate.maccms',
      providerName: 'Ready $index',
      title: '已验证 $index',
      quality: '1080P',
      format: 'hls',
      url: 'https://ready-$index.example/index.m3u8',
      available: true,
      serverVerified: true,
      diagnosticStatus: PlaybackDiscoveryStatus.serverVerified,
    );

    test(
      'caps backend client_probe_required HTTP probes at 12 and client_resolver_required WebView resolves at 3',
      () async {
        final backendLines = <PlaybackLine>[
          for (var i = 0; i < 18; i++) httpProbeLine(i),
          for (var i = 0; i < 15; i++) webViewLine(i),
        ];
        var httpProbeCalls = 0;
        var webViewResolveCalls = 0;
        final controller = PlaybackDiscoveryController(
          backendRepository: (_) => _StaticBackendRepository(backendLines),
          ruleRepository: (_) => _EmptyRuleRepository(),
          verifyLine:
              (
                line, {
                enrichMetadata = true,
                forceRefresh = false,
                cancellationToken,
              }) async {
                if (line.clientResolver != null) {
                  webViewResolveCalls++;
                } else {
                  httpProbeCalls++;
                }
                return PlaybackLine(
                  id: line.id,
                  episodeId: line.episodeId,
                  providerId: line.providerId,
                  providerName: line.providerName,
                  title: line.title,
                  quality: line.quality,
                  format: line.format,
                  url: line.url,
                  available: false,
                );
              },
          isContextCurrent: (_) => true,
          clearRuleRuntimeCaches: () {},
        );
        addTearDown(controller.dispose);
        controller.loadForAccount(
          accountId: 'account-a',
          contextVersion: 1,
          services: const ExternalServiceSettings(
            playbackBackendEnabled: true,
            playbackBackendEndpoint: 'https://api.example.com',
          ),
          ruleState: RulePluginState(customRules: const []),
          history: const [],
        );

        await controller.lineUpdatesForEpisode(_subject, _episode).toList();
        expect(httpProbeCalls, 12);
        expect(webViewResolveCalls, 3);
      },
    );

    test(
      'skips all backend client_resolver_required WebView resolves when 6+ playable routes already exist',
      () async {
        final backendLines = <PlaybackLine>[
          for (var i = 0; i < 6; i++) readyLine(i),
          for (var i = 0; i < 10; i++) webViewLine(i),
        ];
        var webViewResolveCalls = 0;
        final controller = PlaybackDiscoveryController(
          backendRepository: (_) => _StaticBackendRepository(backendLines),
          ruleRepository: (_) => _EmptyRuleRepository(),
          verifyLine:
              (
                line, {
                enrichMetadata = true,
                forceRefresh = false,
                cancellationToken,
              }) async {
                if (line.clientResolver != null) webViewResolveCalls++;
                return line;
              },
          isContextCurrent: (_) => true,
          clearRuleRuntimeCaches: () {},
        );
        addTearDown(controller.dispose);
        controller.loadForAccount(
          accountId: 'account-a',
          contextVersion: 1,
          services: const ExternalServiceSettings(
            playbackBackendEnabled: true,
            playbackBackendEndpoint: 'https://api.example.com',
          ),
          ruleState: RulePluginState(customRules: const []),
          history: const [],
        );

        await controller.lineUpdatesForEpisode(_subject, _episode).toList();
        expect(webViewResolveCalls, 0);
      },
    );
  });

  group('T2 episode matching: season conflicts and OVA/special isolation', () {
    test(
      'rejects conflicting season labels like S01E02 or 第1季 when targeting season 2',
      () {
        const season2Episode = AnimeEpisode(
          id: 202,
          subjectId: 100,
          number: 27,
          seasonNumber: 2,
          seasonEpisodeNumber: 2,
          title: '憧憬',
          airdate: '2026-10-10',
          duration: '24:00',
          description: '',
        );

        expect(
          matchingEpisodes<String>(
            const ['S01E02', '第1季 第2集', 'Season 1 EP02'],
            season2Episode,
            (item) => item,
          ),
          isEmpty,
        );

        expect(
          matchingEpisodes<String>(
            const ['S01E02', 'S02E02'],
            season2Episode,
            (item) => item,
          ),
          ['S02E02'],
        );

        expect(
          matchingEpisodes<String>(
            const ['第1季 第2集', '第二季 第2集'],
            season2Episode,
            (item) => item,
          ),
          ['第二季 第2集'],
        );
      },
    );

    test(
      'isolates OVA/OAD/特别篇/Special from normal episodes while keeping OVA targets matchable',
      () {
        const normalEp = AnimeEpisode(
          id: 2,
          subjectId: 100,
          number: 2,
          title: '第2集 约定',
          airdate: '2026-10-10',
          duration: '24:00',
          description: '',
        );
        expect(
          matchingEpisodes<String>(
            const ['OVA 第2集', 'OAD 02', '特别篇 第2集', 'Special 2', '番外 02'],
            normalEp,
            (item) => item,
          ),
          isEmpty,
        );

        const ovaTarget = AnimeEpisode(
          id: 901,
          subjectId: 100,
          number: 1,
          title: 'OVA 1',
          airdate: '2026-12-01',
          duration: '24:00',
          description: '',
        );
        expect(
          matchingEpisodes<String>(
            const ['OVA 1', '预告'],
            ovaTarget,
            (item) => item,
          ),
          ['OVA 1'],
        );
      },
    );
  });

  group('T5 Kazumi API movie chapter matching', () {
    test(
      'forwards movie flag to Kazumi API chapter selection (delimited movie chapter)',
      () async {
        final imported = const RuleImporter().importFromText(
          jsonEncode({
            'api': '9',
            'type': 'anime',
            'name': 'Kazumi API Movie',
            'version': '1.0',
            'baseURL': 'https://movie-api.example',
            'searchURL': 'https://movie-api.example/search?wd=@keyword',
            'searchMode': 'api',
            'chapterMode': 'api',
            'searchApiConfig': {
              'request': {
                'method': 'GET',
                'url': 'https://movie-api.example/api/search',
                'query': {'wd': '@keyword'},
              },
              'listPath': r'$.list[*]',
              'namePath': r'$.name',
              'sourcePath': r'$.id',
            },
            'chapterApiConfig': {
              'request': {
                'method': 'GET',
                'url': 'https://movie-api.example/api/detail',
                'query': {'id': '@source'},
              },
              'format': 'delimited',
              'roadSeparator': r'$$$',
              'episodeSeparator': '#',
              'fieldSeparator': r'$',
              'roadNamesPath': r'$.vod_play_from',
              'roadEpisodesPath': r'$.vod_play_url',
            },
          }),
        );
        expect(imported.rules, hasLength(1));
        final delimitedRule = imported.rules.single;

        final mp4Long = _mp4SampleWithMvhd(timescale: 1000, duration: 5400000);
        final client = MockClient((request) async {
          switch (request.url.path) {
            case '/api/search':
              return http.Response.bytes(
                utf8.encode(
                  jsonEncode({
                    'list': [
                      {'id': '77', 'name': '测试剧场版'},
                    ],
                  }),
                ),
                200,
                headers: {'content-type': 'application/json'},
              );
            case '/api/detail':
              return http.Response.bytes(
                utf8.encode(
                  jsonEncode({
                    'vod_play_from': '高清专线',
                    'vod_play_url': r'正片$https://movie-api.example/movie.mp4',
                  }),
                ),
                200,
                headers: {'content-type': 'application/json'},
              );
            case '/movie.mp4':
              return http.Response.bytes(
                mp4Long,
                206,
                headers: {
                  'content-type': 'video/mp4',
                  'content-range':
                      'bytes 0-${mp4Long.length - 1}/${400 * 1024 * 1024}',
                },
              );
          }
          return http.Response('not found', 404);
        });

        final lines = await RulePlaybackResolver(client: client).resolveRule(
          rule: delimitedRule,
          subject: _movieSubject,
          episode: _movieEpisode,
        );
        expect(lines.where((line) => line.available), hasLength(1));
        expect(lines.first.url, 'https://movie-api.example/movie.mp4');
      },
    );
  });

  group('T3 MP4 mvhd duration extraction and short-clip filtering', () {
    test(
      'catalogShortClip consistently rejects measured <60s small clips on both catalog and local rules',
      () {
        expect(
          catalogShortClip(
            Uri.parse('https://cdn.example/ad.mp4'),
            format: 'MP4',
            bytes: 614400,
            seconds: 6.0,
            catalog: false,
          ),
          isTrue,
        );
        expect(
          catalogShortClip(
            Uri.parse('https://cdn.example/ad.mp4'),
            format: 'MP4',
            bytes: 614400,
            seconds: 6.0,
            catalog: true,
          ),
          isTrue,
        );
        expect(
          catalogShortClip(
            Uri.parse('https://cdn.example/compact.mp4'),
            format: 'MP4',
            bytes: 2 * 1024 * 1024,
            seconds: 120.0,
            catalog: true,
          ),
          isFalse,
        );
        expect(
          catalogShortClip(
            Uri.parse('https://cdn.example/local-unknown.mp4'),
            format: 'MP4',
            bytes: 1024,
            seconds: null,
            catalog: false,
          ),
          isFalse,
        );
      },
    );

    test(
      'RulePlaybackResolver extracts MP4 mvhd duration and keeps 120s small MP4 while rejecting 6s MP4',
      () async {
        final validSmallMp4 = _mp4SampleWithMvhd(
          timescale: 1000,
          duration: 120000,
        );
        final shortAdMp4 = _mp4SampleWithMvhd(timescale: 1000, duration: 6000);
        final client = MockClient((request) async {
          if (request.url.path == '/valid-small.mp4') {
            return http.Response.bytes(
              validSmallMp4,
              206,
              headers: {
                'content-type': 'video/mp4',
                'content-range':
                    'bytes 0-${validSmallMp4.length - 1}/${2 * 1024 * 1024}',
              },
            );
          }
          if (request.url.path == '/short-ad.mp4') {
            return http.Response.bytes(
              shortAdMp4,
              206,
              headers: {
                'content-type': 'video/mp4',
                'content-range': 'bytes 0-${shortAdMp4.length - 1}/614400',
              },
            );
          }
          return http.Response('not found', 404);
        });

        final resolver = RulePlaybackResolver(client: client);
        final validVerified = await resolver.verifyPlaybackLine(
          line: const PlaybackLine(
            id: 'valid-small',
            episodeId: 1,
            providerId: 'aggregate.maccms',
            providerName: 'Test',
            title: '第1集',
            quality: '',
            format: 'MP4',
            url: 'https://cdn.example/valid-small.mp4',
            requiresClientProbe: true,
          ),
        );
        expect(validVerified.available, isTrue);

        final shortVerified = await resolver.verifyPlaybackLine(
          line: const PlaybackLine(
            id: 'short-ad',
            episodeId: 1,
            providerId: 'rule:local',
            providerName: 'Local Rule',
            title: '第1集',
            quality: '',
            format: 'MP4',
            url: 'https://cdn.example/short-ad.mp4',
            requiresClientProbe: true,
          ),
        );
        expect(shortVerified.available, isFalse);
        expect(shortVerified.message, contains('短片'));
      },
    );
  });

  group('T6 bounded media probe tolerates HTTP 200 large Content-Length', () {
    test(
      'enforceContentLengthHeader=false streams bounded sample while default rejects upfront',
      () async {
        final sampleChunk = Uint8List.fromList(List<int>.filled(4096, 0x41));
        http.Client buildInner() => MockClient.streaming((request, _) async {
          final stream = Stream<List<int>>.fromIterable(
            List<List<int>>.filled(20, sampleChunk),
          );
          return http.StreamedResponse(
            stream,
            200,
            contentLength: 10 * 1024 * 1024,
            headers: {'content-type': 'video/mp4'},
          );
        });

        final strictClient = PolicyHttpClient(
          inner: buildInner(),
          policy: const NetworkRequestPolicy(
            service: NetworkServiceKind.mediaResource,
            httpsOnly: true,
            allowPrivateNetwork: false,
            requestTimeout: Duration(seconds: 5),
            maxResponseBytes: 64 * 1024,
            enforceContentLengthHeader: true,
          ),
        );
        addTearDown(strictClient.close);
        await expectLater(
          () => strictClient.send(
            http.Request('GET', Uri.parse('https://cdn.example/large.mp4')),
          ),
          throwsA(isA<NetworkSecurityException>()),
        );

        final boundedProbeClient = PolicyHttpClient(
          inner: buildInner(),
          policy: const NetworkRequestPolicy(
            service: NetworkServiceKind.mediaResource,
            httpsOnly: true,
            allowPrivateNetwork: false,
            requestTimeout: Duration(seconds: 5),
            maxResponseBytes: 64 * 1024,
            enforceContentLengthHeader: false,
          ),
        );
        addTearDown(boundedProbeClient.close);
        final response = await boundedProbeClient.send(
          http.Request('GET', Uri.parse('https://cdn.example/large.mp4')),
        );
        expect(response.statusCode, 200);
        expect(response.contentLength, 10 * 1024 * 1024);

        final collected = <int>[];
        await for (final chunk in response.stream) {
          collected.addAll(chunk);
          if (collected.length >= 16 * 1024) break;
        }
        expect(collected.length, greaterThanOrEqualTo(16 * 1024));
      },
    );
  });
}

const _subject = AnimeSubject(
  id: 400602,
  title: '青之箱 第二季',
  originalTitle: 'アオのハコ 第2期',
  summary: '',
  coverUrl: null,
  bannerUrl: null,
  date: '2026-10-01',
  platform: 'TV',
  language: 'ja',
  region: 'JP',
  status: 'airing',
  categories: [],
  tags: [],
  totalEpisodes: 25,
  source: 'bangumi',
);

const _episode = AnimeEpisode(
  id: 400602027,
  subjectId: 400602,
  number: 27,
  seasonNumber: 2,
  seasonEpisodeNumber: 2,
  title: '憧憬',
  airdate: '2026-10-10',
  duration: '24:00',
  description: '',
);

const _movieSubject = AnimeSubject(
  id: 500001,
  title: '测试剧场版',
  originalTitle: 'Test Movie',
  summary: '',
  coverUrl: null,
  bannerUrl: null,
  date: '2026-05-01',
  platform: '剧场版',
  language: 'ja',
  region: 'JP',
  status: 'finished',
  categories: [],
  tags: [],
  totalEpisodes: 1,
  source: 'tmdb',
  stableKey: 'tmdb:movie:500001',
);

const _movieEpisode = AnimeEpisode(
  id: 500001001,
  subjectId: 500001,
  number: 1,
  title: '正片',
  airdate: '2026-05-01',
  duration: '110:00',
  description: '',
);

class _StaticBackendRepository extends PlaybackSourceRepository {
  _StaticBackendRepository(this.lines);

  final List<PlaybackLine> lines;

  @override
  Future<List<PlaybackLine>> linesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    RulePlaybackCancellationToken? cancellationToken,
  }) async => lines;

  @override
  Future<List<PlaybackLine>> linesForEpisodeMode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    bool expandAll = false,
    RulePlaybackCancellationToken? cancellationToken,
  }) async => lines;

  @override
  Stream<PlaybackLineLookupUpdate> lineUpdatesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    RulePlaybackCancellationToken? cancellationToken,
  }) => const Stream.empty();
}

class _EmptyRuleRepository extends PlaybackSourceRepository {
  @override
  Future<List<PlaybackLine>> linesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    RulePlaybackCancellationToken? cancellationToken,
  }) async => const [];

  @override
  Future<List<PlaybackLine>> linesForEpisodeMode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    bool expandAll = false,
    RulePlaybackCancellationToken? cancellationToken,
  }) async => const [];

  @override
  Stream<PlaybackLineLookupUpdate> lineUpdatesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    RulePlaybackCancellationToken? cancellationToken,
  }) => const Stream.empty();
}
