import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/rules/rule_importer.dart';
import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/rules/rule_playback_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('Kazumi resolver extracts current episode playable url', () async {
    final client = MockClient((request) async {
      switch (request.url.path) {
        case '/test/01.m3u8':
          return http.Response('#EXTM3U', 200);
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
            <ul class="line"><li><a href="/play/1b.html">备用1</a></li></ul>
          ''');
        case '/play/1.html':
        case '/play/1b.html':
          return _html('''
            <script>
              var player_aaaa={"flag":"play","encrypt":0,"url":"https://cdn.example.com/test/01.m3u8"};
            </script>
          ''');
      }
      return http.Response('not found', 404);
    });

    final resolver = RulePlaybackResolver(client: client);
    final lines = await resolver.resolveRule(
      rule: _kazumiRule,
      subject: _animeSubject,
      episode: _episode,
    );

    expect(lines, isNotEmpty);
    expect(lines.first.available, isTrue);
    expect(lines.first.url, 'https://cdn.example.com/test/01.m3u8');
    expect(lines.first.format, 'HLS');
  });

  test('XBPQ resolver extracts current episode playable url', () async {
    final client = MockClient((request) async {
      switch (request.url.path) {
        case '/movie.mp4':
          return http.Response('video', 200);
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
      expect(web.priority, 2);
      expect(web.groupId, isNotEmpty);
    },
  );

  test('Animeko web selector resolver extracts current episode url', () async {
    final client = MockClient((request) async {
      switch (request.url.path) {
        case '/anime/02.m3u8':
          return http.Response('#EXTM3U', 200);
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
}

http.Response _html(String body) => http.Response(
  body,
  200,
  headers: {'content-type': 'text/html; charset=utf-8'},
);

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
