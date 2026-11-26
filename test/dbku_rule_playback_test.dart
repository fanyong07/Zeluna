import 'dart:convert';

import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/rules/rule_playback_resolver.dart';
import 'package:anime/src/rules/rule_plugin_repository.dart';
import 'package:anime/src/rules/rule_security.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final xbpqRule = _xbpqRule();
  final repository = RulePluginRepository(extraRules: [xbpqRule]);

  test(
    'XBPQ multi-genre rule participates in movies and series, not anime',
    () {
      final state = RulePluginState(
        installedIds: {xbpqRule.id},
        enabledIds: {xbpqRule.id},
      );
      for (final type in [RuleContentType.movie, RuleContentType.series]) {
        expect(
          repository.playbackRulesFor(state, type).map((r) => r.id),
          contains(xbpqRule.id),
        );
      }
      expect(
        repository.byId(xbpqRule.id)!.supportedContentTypes,
        isNot(contains(RuleContentType.anime)),
      );
    },
  );

  for (final isMovie in [false, true]) {
    test(
      'XBPQ card structure resolves ${isMovie ? 'movie' : 'series episode 2'}',
      () async {
        final subject = _subject(isMovie);
        final pages = <String>[];
        final detail = isMovie ? '4209' : '4570';
        final number = isMovie ? 1 : 2;
        final resolver = RulePlaybackResolver(
          client: MockClient((request) async {
            final uri = request.url;
            if (uri.host == 'media.xbpq-fixture.example') {
              if (uri.path.endsWith('.m3u8')) {
                return http.Response(
                  '#EXTM3U\n#EXTINF:10,\nsegment.ts\n#EXT-X-ENDLIST\n',
                  200,
                  headers: {'content-type': 'application/vnd.apple.mpegurl'},
                );
              }
              final bytes = List<int>.filled(188 * 3, 0);
              for (var i = 0; i < 3; i++) {
                bytes[i * 188] = 0x47;
              }
              return http.Response.bytes(
                bytes,
                206,
                headers: {'content-type': 'video/mp2t'},
              );
            }
            expect(uri.host, 'site.xbpq-fixture.example');
            pages.add(uri.path);
            if (uri.path.startsWith('/vodsearch/')) {
              return _html(
                '${_card('300', '庆余年')}${_card('4570', '庆余年 第二季')}${_card('4209', '流浪地球2')}',
              );
            }
            if (uri.path == '/voddetail/$detail.html') {
              return _html(
                '<ul class="myui-content__list clearfix">'
                '<li><a href="/vodplay/$detail-1-1.html">${isMovie ? '正片' : '第01集'}</a></li>'
                '${isMovie ? '' : '<li><a href="/vodplay/$detail-1-2.html">第02集</a></li>'}</ul>',
              );
            }
            if (uri.path == '/vodplay/$detail-1-$number.html') {
              final encoded = base64Encode(
                utf8.encode(
                  'https://media.xbpq-fixture.example/fixture/$number.m3u8',
                ),
              );
              return _html(
                '<script>var player_test = ${jsonEncode({'encrypt': 2, 'url': encoded})};</script>',
              );
            }
            throw StateError('Unexpected fixture page');
          }),
        );
        final lines = await resolver.resolveRule(
          rule: xbpqRule,
          subject: subject,
          episode: AnimeEpisode(
            id: number,
            subjectId: subject.id,
            number: number,
            title: isMovie ? '正片' : '第2集',
            airdate: null,
            duration: '',
            description: '',
          ),
          verifyPlayable: false,
        );
        expect(lines, hasLength(1));
        expect(lines.single.available, isTrue);
        expect(lines.single.clientVerified, isTrue);
        expect(
          lines.single.url,
          'https://media.xbpq-fixture.example/fixture/$number.m3u8',
        );
        expect(pages, contains('/vodplay/$detail-1-$number.html'));
        expect(pages, isNot(contains('/voddetail/300.html')));
      },
    );
  }
}

RulePlugin _xbpqRule() => RulePlugin(
  id: 'fixture:xbpq:live-action',
  name: '测试影视规则',
  version: '1.0',
  source: RuleSourceKind.custom,
  contentType: RuleContentType.movie,
  engine: 'XBPQ',
  updatedAt: DateTime(2026, 10, 5),
  qualityScore: 88,
  tags: const ['电影', '电视剧', '原生解析'],
  baseUrl: 'https://site.xbpq-fixture.example',
  searchUrl:
      'https://site.xbpq-fixture.example/vodsearch/-------------.html?wd={wd}',
  searchable: true,
  quickSearch: true,
  filterable: false,
  installedByDefault: true,
  priority: 3,
  xbpq: const XbpqParserConfig(
    searchArray: '<h4 class="title">&&</h4>',
    searchTitle: '">&&</a>',
    searchLink: 'href="&&"',
    playArray: '<ul class="myui-content__list&&</ul>',
    playList: '<li&&</li>',
    playTitle: '">&&</a>',
    playLink: 'href="&&"',
  ),
  permissionManifest: const RulePermissionManifest.official(
    id: 'fixture:xbpq:live-action',
    name: '测试影视规则',
    version: '1.0',
    engine: 'XBPQ',
    contentTypes: ['movie', 'series'],
    pageDomains: ['site.xbpq-fixture.example'],
    mediaDomains: ['site.xbpq-fixture.example', 'media.xbpq-fixture.example'],
    customReferer: true,
  ),
);

String _card(String id, String title) =>
    '<li class="clearfix">'
    '<div class="thumb"><a href="/voddetail/$id.html"><span class="pic-tag">8.5分</span><span>全36集</span></a></div>'
    '<div class="detail"><h4 class="title"><a href="/voddetail/$id.html">$title</a></h4></div></li>';
http.Response _html(String text) => http.Response(
  text,
  200,
  headers: {'content-type': 'text/html; charset=utf-8'},
);
AnimeSubject _subject(bool movie) => AnimeSubject(
  id: 991001,
  title: movie ? '流浪地球2' : '庆余年 第二季',
  originalTitle: '',
  summary: '',
  coverUrl: null,
  bannerUrl: null,
  date: movie ? '2023-01-22' : '2024-05-16',
  platform: movie ? 'Movie' : 'TV',
  language: '',
  region: '',
  status: '',
  categories: const [],
  tags: const [],
  totalEpisodes: movie ? 1 : 36,
  source: movie ? 'tmdb:movie' : 'tmdb:tv',
);
