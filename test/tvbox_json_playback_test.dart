import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/rules/rule_playback_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'TVBox JSON API resolves the requested episode into a playable line',
    () async {
      final client = MockClient((request) async {
        if (request.url.host == 'cdn.example.com') {
          return http.Response(
            'video',
            206,
            headers: {'content-type': 'video/mp2t'},
          );
        }
        expect(request.url.host, 'api.example.com');
        expect(request.url.queryParameters['wd'], '测试番剧');
        return http.Response(
          '''
{
  "code": 1,
  "list": [
    {
      "vod_id": 7,
      "vod_name": "测试番剧",
      "vod_play_from": "直连",
      "vod_play_url": "第1集\$https://cdn.example.com/ep1.m3u8#第2集\$https://cdn.example.com/ep2.m3u8"
    }
  ]
}
''',
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final resolver = RulePlaybackResolver(client: client);

      final lines = await resolver.resolveRule(
        rule: _jsonApiRule,
        subject: _subject,
        episode: _episode,
      );

      expect(lines, hasLength(1));
      expect(lines.single.available, isTrue);
      expect(lines.single.url, 'https://cdn.example.com/ep2.m3u8');
      expect(lines.single.providerName, '测试 JSON 源');
      expect(lines.single.format, 'HLS');
    },
  );
}

final _jsonApiRule = RulePlugin(
  id: 'custom:tvbox:json',
  name: '测试 JSON 源',
  version: '1.0',
  source: RuleSourceKind.tvbox,
  contentType: RuleContentType.anime,
  engine: 'tvbox-json-api',
  updatedAt: DateTime(2026, 7, 13),
  qualityScore: 80,
  tags: const ['TVBox', 'JSON API'],
  baseUrl: 'https://api.example.com/api.php/provide/vod',
  searchUrl: 'https://api.example.com/api.php/provide/vod',
  searchable: true,
  quickSearch: true,
  filterable: false,
);

const _subject = AnimeSubject(
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

const _episode = AnimeEpisode(
  id: 102,
  subjectId: 1,
  number: 2,
  title: '第二集',
  airdate: '2026-01-08',
  duration: '24:00',
  description: '第二集',
);
