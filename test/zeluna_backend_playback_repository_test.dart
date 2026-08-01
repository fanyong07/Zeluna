import 'dart:convert';

import 'package:anime/src/data/zeluna_backend_playback_repository.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/rules/rule_playback_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const subject = AnimeSubject(
    id: 1,
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
    categories: [AnimeCategory(name: '动画')],
    tags: [],
    totalEpisodes: 28,
  );
  const episode = AnimeEpisode(
    id: 101,
    subjectId: 1,
    number: 1,
    title: '第1集',
    airdate: null,
    duration: '',
    description: '',
  );

  test('聚合后端会保留同一作品的不同站点线路', () async {
    String? requestedStableId;
    final client = MockClient((request) async {
      if (request.url.pathSegments.take(3).join('/') ==
          'api/v3/quick-playback') {
        requestedStableId = request.url.pathSegments.last;
        expect(request.url.queryParameters['title'], subject.title);
        return _jsonResponse([
          {
            'url': 'https://cdn.example.com/ikun/index.m3u8',
            'title': '线路1',
            'quality': '1080P',
            'format': 'hls',
            'source': 'maccms:iKun',
            'headers': {'Referer': 'https://player.example.com/'},
            'cached': true,
            'cache_state': 'fresh',
            'source_latency_ms': 420,
          },
          {
            'url': 'https://cdn.example.com/modu/index.m3u8',
            'title': '线路2',
            'quality': '1080P',
            'format': 'hls',
            'source': 'maccms:魔都',
            'headers': const <String, String>{},
            'cached': false,
          },
          {
            'url': '',
            'title': '如意',
            'source': 'maccms:如意',
            'available': false,
            'status': 'not_found',
            'message': '当前站点没有匹配到这部作品',
          },
        ]);
      }
      return http.Response('not found', 404);
    });
    addTearDown(client.close);
    final repository = ZelunaBackendPlaybackRepository(
      baseUrl: 'https://backend.example.com/',
      client: client,
    );
    expect(repository.requestTimeout, const Duration(seconds: 18));

    final lines = await repository.linesForEpisode(subject, episode);

    expect(requestedStableId, 'bangumi:1');
    expect(lines, hasLength(3));
    expect(
      lines.map((line) => line.providerName),
      containsAll(['在线服务 · iKun', '在线服务 · 魔都']),
    );
    expect(lines, everyElement(isA<PlaybackLine>()));
    expect(lines.where((line) => line.available), hasLength(2));
    expect(
      lines,
      everyElement(predicate<PlaybackLine>((line) => !line.publicHttpOnly)),
    );
    expect(lines.first.headers['Referer'], 'https://player.example.com/');
    expect(lines.first.message, '来自在线服务（已缓存）');
    expect(lines.first.cacheState, 'fresh');
    expect(lines.first.latency, const Duration(milliseconds: 420));
    expect(lines.last.available, isFalse);
    expect(lines.last.url, isNull);
    expect(lines.last.message, '当前站点没有匹配到这部作品');
  });

  test('完整查线使用兼容接口，过期前的旧缓存会明确提示后台更新', () async {
    final client = MockClient((request) async {
      expect(request.url.pathSegments.take(3).join('/'), 'api/v3/playback');
      return _jsonResponse([
        {
          'url': 'https://cdn.example.com/stale/index.m3u8',
          'source': 'maccms:iKun',
          'available': true,
          'status': 'server_verified',
          'cached': true,
          'stale': true,
        },
      ]);
    });
    addTearDown(client.close);
    final repository = ZelunaBackendPlaybackRepository(
      baseUrl: 'https://backend.example.com',
      client: client,
    );

    final lines = await repository.linesForEpisodeMode(
      subject,
      episode,
      expandAll: true,
    );

    expect(lines.single.available, isTrue);
    expect(lines.single.message, '来自可用缓存，正在后台更新线路');
    expect(lines.single.cacheState, 'stale');
  });

  test('旧服务没有快速接口时会回退完整播放接口', () async {
    final paths = <String>[];
    final client = MockClient((request) async {
      final path = request.url.pathSegments.take(3).join('/');
      paths.add(path);
      if (path == 'api/v3/quick-playback') {
        return http.Response('not found', 404);
      }
      expect(path, 'api/v3/playback');
      return _jsonResponse([
        {
          'url': 'https://cdn.example.com/fallback/index.m3u8',
          'source': 'maccms:iKun',
          'available': true,
          'status': 'server_verified',
        },
      ]);
    });
    addTearDown(client.close);
    final repository = ZelunaBackendPlaybackRepository(
      baseUrl: 'https://backend.example.com',
      client: client,
    );

    final lines = await repository.linesForEpisode(subject, episode);

    expect(lines.single.available, isTrue);
    expect(paths, ['api/v3/quick-playback', 'api/v3/playback']);
  });

  test('后端线路不会被 Clash Fake-IP 的 drpy 防护误杀', () async {
    final backendClient = MockClient((request) async {
      return _jsonResponse([
        {
          'url': 'http://198.18.0.8/video.mp4',
          'title': 'Fake-IP CDN',
          'format': 'mp4',
          'source': 'maccms:iKun',
        },
      ]);
    });
    final mediaClient = MockClient((request) async {
      expect(request.url.host, '198.18.0.8');
      return http.Response.bytes(
        <int>[0, 0, 0, 24, ...ascii.encode('ftyp'), ...List<int>.filled(16, 0)],
        206,
        headers: const {'content-type': 'video/mp4'},
      );
    });
    addTearDown(backendClient.close);
    addTearDown(mediaClient.close);
    final repository = ZelunaBackendPlaybackRepository(
      baseUrl: 'https://backend.example.com',
      client: backendClient,
    );

    final lines = await repository.linesForEpisode(subject, episode);
    final verified = await RulePlaybackResolver(
      client: mediaClient,
    ).verifyPlaybackLine(line: lines.single, enrichMetadata: false);

    expect(lines.single.publicHttpOnly, isFalse);
    expect(verified.available, isTrue);
  });

  test('服务器受限线路会在客户端完成清单和首段验证', () async {
    final expiresAt =
        DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
        1000;
    final backendClient = MockClient((request) async {
      return _jsonResponse([
        {
          'url': 'https://1.1.1.1/index.m3u8',
          'title': '客户端候选',
          'format': 'hls',
          'source': 'crawler:dm706',
          'headers': {'Referer': 'https://source.example/watch/1'},
          'available': false,
          'status': 'client_probe_required',
          'cache_state': 'cold',
          'error_category': 'server_blocked_client_candidate',
          'source_latency_ms': 730,
          'expires_at': expiresAt,
        },
      ]);
    });
    final mediaClient = MockClient((request) async {
      expect(request.headers['Referer'], 'https://source.example/watch/1');
      if (request.url.path.endsWith('index.m3u8')) {
        return http.Response(
          '#EXTM3U\n#EXTINF:4,\nsegment.ts\n',
          200,
          headers: const {'content-type': 'application/vnd.apple.mpegurl'},
        );
      }
      expect(request.url.path, '/segment.ts');
      final transportStream = List<int>.filled(188 * 2, 0);
      transportStream[0] = 0x47;
      transportStream[188] = 0x47;
      return http.Response.bytes(
        transportStream,
        206,
        headers: const {'content-type': 'video/mp2t'},
      );
    });
    addTearDown(backendClient.close);
    addTearDown(mediaClient.close);
    final repository = ZelunaBackendPlaybackRepository(
      baseUrl: 'https://backend.example.com',
      client: backendClient,
    );

    final candidate = (await repository.linesForEpisode(
      subject,
      episode,
    )).single;
    expect(candidate.available, isFalse);
    expect(candidate.serverVerified, isFalse);
    expect(candidate.requiresClientProbe, isTrue);
    expect(candidate.publicHttpOnly, isTrue);
    expect(candidate.cacheState, 'cold');
    expect(candidate.sourceErrorCategory, 'server_blocked_client_candidate');
    expect(candidate.latency, const Duration(milliseconds: 730));
    expect(candidate.expiresAt, isNotNull);

    final verified = await RulePlaybackResolver(
      client: mediaClient,
    ).verifyPlaybackLine(line: candidate, enrichMetadata: false);

    expect(verified.available, isTrue);
    expect(verified.clientVerified, isTrue);
    expect(verified.requiresClientProbe, isFalse);
    expect(verified.serverVerified, isFalse);
    expect(verified.cacheState, 'cold');
    expect(verified.sourceErrorCategory, 'server_blocked_client_candidate');
  });

  test('不受支持的旧来源不会再触发后端或本地规则查源', () async {
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      return _jsonResponse(const []);
    });
    addTearDown(client.close);
    final repository = ZelunaBackendPlaybackRepository(
      baseUrl: 'https://backend.example.com',
      client: client,
    );

    final lines = await repository.linesForEpisode(
      const AnimeSubject(
        id: 1,
        title: '旧来源',
        originalTitle: '',
        summary: '',
        coverUrl: null,
        bannerUrl: null,
        date: '2024',
        platform: 'TV',
        language: '',
        region: '',
        status: '',
        categories: [],
        tags: [],
        totalEpisodes: 1,
        source: 'anich',
      ),
      episode,
    );

    expect(lines, isEmpty);
    expect(requests, 0);
  });

  test('后端地址与开关会持久化且拒绝带账号或参数的地址', () {
    const settings = ExternalServiceSettings(
      playbackBackendEnabled: true,
      playbackBackendEndpoint: 'https://anime.example.com',
    );
    final restored = ExternalServiceSettings.fromJson(settings.toJson());

    expect(restored.playbackBackendEnabled, isTrue);
    expect(restored.playbackBackendEndpoint, 'https://anime.example.com');
    expect(
      ZelunaBackendPlaybackRepository.normalizeBaseUrl(
        'https://user:pass@example.com',
      ),
      isNull,
    );
    expect(
      ZelunaBackendPlaybackRepository.normalizeBaseUrl(
        'https://example.com?token=secret',
      ),
      isNull,
    );
  });
}

http.Response _jsonResponse(Object value) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(value)),
    200,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}
