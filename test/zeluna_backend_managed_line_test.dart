import 'dart:convert';

import 'package:anime/src/data/zeluna_backend_playback_repository.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const subject = AnimeSubject(
    id: 400602,
    title: '测试作品',
    originalTitle: 'Test Subject',
    summary: '',
    coverUrl: null,
    bannerUrl: null,
    date: '2026',
    platform: 'TV',
    language: '日语',
    region: '日本',
    status: '完结',
    categories: [AnimeCategory(name: '动画')],
    tags: [],
    totalEpisodes: 1,
  );
  const episode = AnimeEpisode(
    id: 1,
    subjectId: 400602,
    number: 1,
    title: '第1集',
    airdate: null,
    duration: '',
    description: '',
  );

  test('优先采用服务端稳定 line_id 与 provider 字段', () async {
    final client = MockClient((_) async {
      return http.Response.bytes(
        utf8.encode(
          jsonEncode([
            {
              'line_id': 'mpl_stable_server_id',
              'url': 'https://cdn.example/video.m3u8?signature=first',
              'title': '主线路',
              'format': 'hls',
              'source': 'managed:main:mpl_stable_server_id',
              'provider_id': 'managed.urls',
              'provider_name': 'Zeluna 管理线路',
              'origin_kind': 'managed',
              'available': true,
              'status': 'server_verified',
            },
          ]),
        ),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    });
    addTearDown(client.close);
    final repository = ZelunaBackendPlaybackRepository(
      baseUrl: 'https://backend.example',
      client: client,
    );

    final line = (await repository.linesForEpisode(subject, episode)).single;

    expect(line.id, 'mpl_stable_server_id');
    expect(line.providerId, 'managed.urls');
    expect(line.providerName, 'Zeluna 管理线路');
  });

  test('旧响应缺少新字段时仍使用原有稳定身份算法', () async {
    final client = MockClient((_) async {
      return http.Response.bytes(
        utf8.encode(
          jsonEncode([
            {
              'url': 'https://cdn.example/video.m3u8',
              'source': 'maccms:iKun',
              'available': true,
              'status': 'server_verified',
            },
          ]),
        ),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    });
    addTearDown(client.close);
    final repository = ZelunaBackendPlaybackRepository(
      baseUrl: 'https://backend.example',
      client: client,
    );

    final line = (await repository.linesForEpisode(subject, episode)).single;

    expect(line.id, startsWith('line:v'));
    expect(line.providerId, 'zeluna:site:iKun');
    expect(line.providerName, '在线服务 · iKun');
  });
}
