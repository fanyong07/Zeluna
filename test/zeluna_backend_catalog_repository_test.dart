import 'dart:convert';

import 'package:anime/src/data/zeluna_backend_catalog_repository.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/domain/subject_content_type.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('后端目录把稳定 ID 映射为客户端作品身份', () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/api/v3/catalog/home/tv');
      expect(request.url.queryParameters['limit'], '240');
      return _jsonResponse([
        {
          'stable_id': 'tmdb:tv:42',
          'title': '测试剧集',
          'original_title': 'Test Series',
          'summary': '简介',
          'cover_url': 'https://img.example/poster.jpg',
          'banner_url': 'https://img.example/backdrop.jpg',
          'date': '2026-01-01',
          'language': 'zh',
          'region': 'CN',
          'status': 'Returning Series',
          'genres': ['剧情'],
          'total_episodes': 12,
          'rating': 8.5,
          'rating_count': 100,
        },
      ]);
    });
    addTearDown(client.close);
    final repository = ZelunaBackendCatalogRepository(
      baseUrl: 'https://backend.example',
      client: client,
    );

    final subjects = await repository.home(SubjectContentType.series);

    expect(subjects, hasLength(1));
    expect(subjects.single.id, 42);
    expect(subjects.single.source, 'tmdb:series:42');
    expect(stableSubjectId(subjects.single), 'tmdb:tv:42');
    expect(subjects.single.categories.single.name, '剧情');
  });
  test('客户端不会缓存后台返回的轻量目录记录', () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/api/v3/catalog/subject/bangumi:590786');
      return _jsonResponse({
        'stable_id': 'bangumi:590786',
        'title': '测试动画',
        'summary': '',
        'genres': const [],
        'total_episodes': 0,
      });
    });
    addTearDown(client.close);
    final repository = ZelunaBackendCatalogRepository(
      baseUrl: 'https://backend.example',
      client: client,
    );

    expect(await repository.detail(_bangumiSubject()), isNull);
  });

  test('完整后台详情会补齐简介分类和占位集数', () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/api/v3/catalog/subject/bangumi:590786');
      return _jsonResponse({
        'stable_id': 'bangumi:590786',
        'title': '测试动画',
        'summary': '完整中文简介',
        'region': '日本',
        'genres': const ['冒险', '奇幻'],
        'total_episodes': 12,
        'episodes': const [],
        'detail_complete': true,
      });
    });
    addTearDown(client.close);
    final repository = ZelunaBackendCatalogRepository(
      baseUrl: 'https://backend.example',
      client: client,
    );

    final detail = await repository.detail(_bangumiSubject());

    expect(detail, isNotNull);
    expect(detail!.subject.summary, '完整中文简介');
    expect(detail.subject.categories.map((item) => item.name), ['冒险', '奇幻']);
    expect(detail.episodes, hasLength(12));
  });
}

AnimeSubject _bangumiSubject() => const AnimeSubject(
  id: 590786,
  title: '测试动画',
  originalTitle: 'Test Anime',
  summary: '',
  coverUrl: null,
  bannerUrl: null,
  date: null,
  platform: 'TV',
  language: 'ja',
  region: '日本',
  status: '',
  categories: [],
  tags: [],
  totalEpisodes: 0,
);

http.Response _jsonResponse(Object value) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(value)),
    200,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}
