import 'dart:convert';

import 'package:anime/src/data/zeluna_backend_playback_repository.dart';
import 'package:anime/src/domain/anime_models.dart';
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
      if (request.url.pathSegments.take(3).join('/') == 'api/v3/playback') {
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
        ]);
      }
      return http.Response('not found', 404);
    });
    addTearDown(client.close);
    final repository = ZelunaBackendPlaybackRepository(
      baseUrl: 'https://backend.example.com/',
      client: client,
    );

    final lines = await repository.linesForEpisode(subject, episode);

    expect(requestedStableId, 'bangumi:1');
    expect(lines, hasLength(2));
    expect(
      lines.map((line) => line.providerName),
      containsAll(['Zeluna · iKun', 'Zeluna · 魔都']),
    );
    expect(lines, everyElement(isA<PlaybackLine>()));
    expect(
      lines,
      everyElement(predicate<PlaybackLine>((line) => line.available)),
    );
    expect(
      lines,
      everyElement(predicate<PlaybackLine>((line) => line.publicHttpOnly)),
    );
    expect(lines.first.headers['Referer'], 'https://player.example.com/');
    expect(lines.first.message, '聚合后端缓存线路');
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
