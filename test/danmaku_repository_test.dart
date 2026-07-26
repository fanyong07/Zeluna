import 'dart:convert';
import 'dart:io';

import 'package:anime/src/data/danmaku_repository.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/player/danmaku_overlay.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('Bilibili XML parses real time, mode, color and decoded text', () {
    final comments = parseBilibiliDanmakuXml('''
<i>
  <d p="1.25,1,25,16711680,0,0,user,9001">滚动 &amp; 文本</d>
  <d p="2.5,5,25,65280,0,0,user,9002">顶部弹幕</d>
  <d p="3,4,25,255,0,0,user,9003">底部弹幕</d>
</i>
''');

    expect(comments, hasLength(3));
    expect(comments[0].time, const Duration(milliseconds: 1250));
    expect(comments[0].mode, DanmakuMode.scroll);
    expect(comments[0].color, 0xFF0000);
    expect(comments[0].text, '滚动 & 文本');
    expect(comments[1].mode, DanmakuMode.top);
    expect(comments[1].color, 0x00FF00);
    expect(comments[2].mode, DanmakuMode.bottom);
    expect(comments[2].color, 0x0000FF);
  });

  test('Bilibili WBI matching loads episode XML and caches the timeline', () async {
    var requests = 0;
    final paths = <String>[];
    final repository = DanmakuRepository(
      client: MockClient((request) async {
        requests++;
        paths.add(request.url.path);
        if (request.url.path == '/x/web-interface/nav') {
          return _jsonResponse({
            'code': -101,
            'data': {
              'wbi_img': {
                'img_url':
                    'https://i0.hdslb.com/bfs/wbi/abcdefghijklmnopqrstuvwxyz123456.png',
                'sub_url':
                    'https://i0.hdslb.com/bfs/wbi/654321zyxwvutsrqponmlkjihgfedcba.png',
              },
            },
          });
        }
        if (request.url.path == '/x/web-interface/wbi/search/type') {
          expect(request.url.queryParameters['search_type'], 'media_bangumi');
          expect(request.url.queryParameters['wts'], isNotEmpty);
          expect(
            request.url.queryParameters['w_rid'],
            matches(RegExp(r'^[0-9a-f]{32}$')),
          );
          return _jsonResponse({
            'code': 0,
            'data': {
              'result': [
                {
                  'season_id': 42,
                  'title': '<em>葬送的芙莉莲</em>',
                  'org_title': '葬送のフリーレン',
                },
              ],
            },
          });
        }
        if (request.url.path == '/pgc/view/web/season') {
          expect(request.url.queryParameters['season_id'], '42');
          return _jsonResponse({
            'code': 0,
            'result': {
              'title': '葬送的芙莉莲',
              'episodes': [
                {'title': '1', 'long_title': '冒险的结束', 'cid': 777},
              ],
            },
          });
        }
        if (request.url.path == '/x/v1/dm/list.so') {
          expect(request.url.queryParameters['oid'], '777');
          final compressed = ZLibCodec(raw: true).encode(
            utf8.encode('<i><d p="9.5,1,25,16777215,0,0,u,1">真实弹幕</d></i>'),
          );
          return http.Response.bytes(
            compressed,
            200,
            headers: const {
              'content-type': 'text/xml; charset=utf-8',
              'content-encoding': 'deflate',
            },
          );
        }
        return http.Response('not found', 404);
      }),
    );

    final first = await repository.timelineForEpisode(
      _subject,
      _episode,
      const ExternalServiceSettings(dandanplayDanmakuEnabled: false),
    );
    final afterFirstLoad = requests;
    final second = await repository.timelineForEpisode(
      _subject,
      _episode,
      const ExternalServiceSettings(dandanplayDanmakuEnabled: false),
    );

    expect(paths, contains('/x/web-interface/wbi/search/type'));
    expect(
      first.sources.single.available,
      isTrue,
      reason: '${first.sources.single.message}; paths=$paths',
    );
    expect(first.sources.single.episodeId, '777');
    expect(first.comments.single.provider, 'Bilibili');
    expect(first.comments.single.text, '真实弹幕');
    expect(second.comments.single.text, '真实弹幕');
    expect(requests, afterFirstLoad);
  });

  test('Bilibili 412 clearly falls back to dandanplay comments', () async {
    final paths = <String>[];
    final repository = DanmakuRepository(
      client: MockClient((request) async {
        paths.add(request.url.path);
        if (request.url.path == '/x/web-interface/nav') {
          return _jsonResponse({
            'code': -101,
            'data': {
              'wbi_img': {
                'img_url':
                    'https://i0.hdslb.com/bfs/wbi/abcdefghijklmnopqrstuvwxyz123456.png',
                'sub_url':
                    'https://i0.hdslb.com/bfs/wbi/654321zyxwvutsrqponmlkjihgfedcba.png',
              },
            },
          });
        }
        if (request.url.path == '/x/web-interface/wbi/search/type') {
          return http.Response('<div class="error-container">412</div>', 412);
        }
        if (request.url.path == '/api/v2/search/episodes') {
          expect(_header(request, 'X-AppId'), 'app');
          expect(_header(request, 'X-Signature'), isNotEmpty);
          return _jsonResponse({
            'animes': [
              {
                'animeTitle': '葬送的芙莉莲',
                'episodes': [
                  {'episodeId': 12345, 'episodeTitle': '第1话 冒险的结束'},
                ],
              },
            ],
          });
        }
        if (request.url.path == '/api/v2/comment/12345') {
          return _jsonResponse({
            'comments': [
              {'cid': 88, 'p': '12.5,5,16776960,user', 'm': '备用真实弹幕'},
            ],
          });
        }
        return http.Response('not found', 404);
      }),
    );

    final timeline = await repository.timelineForEpisode(
      _subject,
      _episode,
      const ExternalServiceSettings(
        dandanplayAppId: 'app',
        dandanplayAppSecret: 'secret',
      ),
    );

    expect(paths, contains('/x/web-interface/wbi/search/type'));
    expect(timeline.sources, hasLength(2));
    expect(timeline.sources.first.message, contains('风控'));
    expect(timeline.sources.last.available, isTrue);
    expect(timeline.comments.single.provider, '弹弹play');
    expect(timeline.comments.single.mode, DanmakuMode.top);
    expect(timeline.comments.single.color, 0xFFFF00);
    expect(timeline.comments.single.text, '备用真实弹幕');
  });

  test(
    'unrelated Bilibili result is rejected instead of attaching wrong comments',
    () async {
      var seasonRequested = false;
      final repository = DanmakuRepository(
        client: MockClient((request) async {
          if (request.url.path == '/x/web-interface/nav') {
            return _jsonResponse({
              'code': -101,
              'data': {
                'wbi_img': {
                  'img_url':
                      'https://i0.hdslb.com/bfs/wbi/abcdefghijklmnopqrstuvwxyz123456.png',
                  'sub_url':
                      'https://i0.hdslb.com/bfs/wbi/654321zyxwvutsrqponmlkjihgfedcba.png',
                },
              },
            });
          }
          if (request.url.path == '/x/web-interface/wbi/search/type') {
            return _jsonResponse({
              'code': 0,
              'data': {
                'result': [
                  {'season_id': 99, 'title': '完全无关的电视剧', 'org_title': ''},
                ],
              },
            });
          }
          if (request.url.path == '/pgc/view/web/season') {
            seasonRequested = true;
          }
          return http.Response('not found', 404);
        }),
      );

      final timeline = await repository.timelineForEpisode(
        _subject,
        _episode,
        const ExternalServiceSettings(dandanplayDanmakuEnabled: false),
      );

      expect(seasonRequested, isFalse);
      expect(timeline.comments, isEmpty);
      expect(timeline.sources.single.available, isFalse);
    },
  );

  test(
    'timeline window follows progress and respects mode and keyword filters',
    () {
      const comments = [
        DanmakuComment(
          id: '1',
          provider: 'Bilibili',
          time: Duration(seconds: 1),
          mode: DanmakuMode.scroll,
          color: 0xFFFFFF,
          text: '保留',
        ),
        DanmakuComment(
          id: '2',
          provider: 'Bilibili',
          time: Duration(milliseconds: 1200),
          mode: DanmakuMode.top,
          color: 0xFFFFFF,
          text: '顶部',
        ),
        DanmakuComment(
          id: '3',
          provider: 'Bilibili',
          time: Duration(milliseconds: 1400),
          mode: DanmakuMode.bottom,
          color: 0xFFFFFF,
          text: '剧透内容',
        ),
        DanmakuComment(
          id: '4',
          provider: 'Bilibili',
          time: Duration(seconds: 3),
          mode: DanmakuMode.scroll,
          color: 0xFFFFFF,
          text: '未来弹幕',
        ),
      ];

      final visible = visibleDanmakuComments(
        comments,
        position: const Duration(seconds: 2),
        settings: const DanmakuSettings(
          enabled: true,
          blockTop: true,
          blockKeywords: ['剧透'],
        ),
      );

      expect(visible.map((item) => item.text), ['保留']);
    },
  );
}

http.Response _jsonResponse(Object value) {
  return http.Response(
    jsonEncode(value),
    200,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

String? _header(http.Request request, String name) {
  final target = name.toLowerCase();
  for (final entry in request.headers.entries) {
    if (entry.key.toLowerCase() == target) return entry.value;
  }
  return null;
}

const _subject = AnimeSubject(
  id: 1,
  title: '葬送的芙莉莲',
  originalTitle: 'Frieren',
  summary: 'summary',
  coverUrl: null,
  bannerUrl: null,
  date: '2023-09-29',
  platform: 'TV',
  language: '日语',
  region: '日本',
  status: '全28集',
  categories: [AnimeCategory(name: '动画')],
  tags: [AnimeTag(name: 'TV')],
  totalEpisodes: 28,
);

const _episode = AnimeEpisode(
  id: 101,
  subjectId: 1,
  number: 1,
  title: '',
  airdate: '2023-09-29',
  duration: '24:00',
  description: '第一集',
);
