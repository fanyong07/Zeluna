import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/rules/rule_playback_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'TVBox XML API resolves the requested episode into a playable line',
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
<rss version="5.1">
  <list page="1" pagecount="1" pagesize="20" recordcount="1">
    <video>
      <id>7</id>
      <name><![CDATA[测试番剧]]></name>
      <dl>
        <dd flag="直连"><![CDATA[第1集\$https://cdn.example.com/ep1.m3u8#第2集\$https://cdn.example.com/ep2.m3u8]]></dd>
      </dl>
    </video>
  </list>
</rss>
''',
          200,
          headers: {'content-type': 'text/xml; charset=utf-8'},
        );
      });
      final resolver = RulePlaybackResolver(client: client);

      final lines = await resolver.resolveRule(
        rule: _xmlApiRule,
        subject: _subject,
        episode: _episode,
      );

      expect(lines, hasLength(1));
      expect(lines.single.available, isTrue);
      expect(lines.single.url, 'https://cdn.example.com/ep2.m3u8');
      expect(lines.single.providerName, '测试 XML 源');
      expect(lines.single.format, 'HLS');
    },
  );

  test('TVBox detail lookup falls back from detail to videolist', () async {
    var failedDetailRequests = 0;
    var successfulDetailRequests = 0;
    final client = MockClient((request) async {
      if (request.url.host == 'cdn.example.com') {
        return http.Response(
          'video',
          206,
          headers: {'content-type': 'video/mp2t'},
        );
      }
      final hasVodId = request.url.queryParameters['ids'] == '7';
      if (!hasVodId) {
        return http.Response(
          '''
<rss><list><video><id>7</id><name><![CDATA[测试番剧]]></name></video></list></rss>
''',
          200,
          headers: {'content-type': 'text/xml; charset=utf-8'},
        );
      }
      if (request.url.queryParameters['ac'] == 'detail') {
        failedDetailRequests++;
        return http.Response('unsupported', 500);
      }
      successfulDetailRequests++;
      return http.Response(
        '''
<rss>
  <list>
    <video>
      <id>7</id>
      <name><![CDATA[测试番剧]]></name>
      <dl>
        <dd flag="直连"><![CDATA[第1集\$https://cdn.example.com/ep1.m3u8#第2集\$https://cdn.example.com/ep2.m3u8]]></dd>
      </dl>
    </video>
  </list>
</rss>
''',
        200,
        headers: {'content-type': 'text/xml; charset=utf-8'},
      );
    });
    final resolver = RulePlaybackResolver(client: client);

    final lines = await resolver.resolveRule(
      rule: _xmlApiRule,
      subject: _subject,
      episode: _episode,
    );

    expect(failedDetailRequests, 1);
    expect(successfulDetailRequests, 1);
    expect(lines, hasLength(1));
    expect(lines.single.available, isTrue);
    expect(lines.single.url, 'https://cdn.example.com/ep2.m3u8');
  });
}

final _xmlApiRule = RulePlugin(
  id: 'custom:tvbox:xml',
  name: '测试 XML 源',
  version: '1.0',
  source: RuleSourceKind.tvbox,
  contentType: RuleContentType.anime,
  engine: 'tvbox-xml-api',
  updatedAt: DateTime(2026, 7, 18),
  qualityScore: 80,
  tags: const ['TVBox', 'XML API'],
  baseUrl: 'https://api.example.com/api.php/provide/vod/at/xml/',
  searchUrl: 'https://api.example.com/api.php/provide/vod/at/xml/',
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
