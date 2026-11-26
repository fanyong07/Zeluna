import 'dart:convert';

import 'package:anime/src/rules/rule_importer.dart';
import 'package:anime/src/rules/rule_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'Kazumi subscribes to the full sibling rules, not index placeholders',
    () async {
      final requests = <Uri>[];
      final client = MockClient((request) async {
        requests.add(request.url);
        return _json(
          request.url.pathSegments.last == 'index.json'
              ? [_kazumiEntry('Fixture 站'), _kazumiEntry('Second')]
              : _kazumiRule(request.url.pathSegments.last.split('.').first),
        );
      });
      addTearDown(client.close);
      const url = 'https://rules.example/branch/index.json?view=fixture';
      final bundle = await RuleImporter(client: client).importFromUrl(url);
      expect(bundle.sourceUrl, url);
      expect(bundle.rules.map((rule) => rule.name), ['Fixture 站', 'Second']);
      expect(bundle.rules.every((rule) => rule.canResolveNatively), isTrue);
      expect(
        bundle.rules.every((rule) => rule.source == RuleSourceKind.kazumi),
        isTrue,
      );
      expect(requests, hasLength(3));
      expect(
        requests.skip(1).map((uri) => uri.pathSegments),
        unorderedEquals([
          ['branch', 'Fixture 站.json'],
          ['branch', 'Second.json'],
        ]),
      );
      expect(
        requests
            .skip(1)
            .every(
              (uri) => uri.origin == requests.first.origin && !uri.hasQuery,
            ),
        isTrue,
      );
      expect(
        () => const RuleImporter().importFromText(
          jsonEncode([_kazumiEntry('Fixture')]),
        ),
        throwsFormatException,
      );
    },
  );

  test('Kazumi rejects path-bearing names before fetching any child', () async {
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      return _json([_kazumiEntry('Fixture'), _kazumiEntry('../elsewhere')]);
    });
    addTearDown(client.close);
    await expectLater(
      RuleImporter(
        client: client,
      ).importFromUrl('https://rules.example/sub/index.json'),
      throwsFormatException,
    );
    expect(requests, 1);
  });

  test(
    'a Kazumi child failure fails the refresh instead of returning a partial snapshot',
    () async {
      final client = MockClient((request) async {
        return switch (request.url.pathSegments.last) {
          'index.json' => _json([
            _kazumiEntry('Available'),
            _kazumiEntry('Missing'),
          ]),
          'Available.json' => _json(_kazumiRule('Available')),
          _ => http.Response('', 503),
        };
      });
      addTearDown(client.close);
      await expectLater(
        RuleImporter(
          client: client,
        ).importFromUrl('https://rules.example/sub/index.json'),
        throwsFormatException,
      );
    },
  );

  test(
    'Kazumi skips individual missing 404 files and follows safe public redirects',
    () async {
      final client = MockClient((request) async {
        if (request.url.host == 'mirror.example') {
          return http.Response(
            '',
            302,
            headers: {'location': 'https://rules.example/sub/index.json'},
          );
        }
        return switch (request.url.pathSegments.last) {
          'index.json' => _json([
            _kazumiEntry('Available'),
            _kazumiEntry('DeletedRule'),
          ]),
          'Available.json' => _json(_kazumiRule('Available')),
          _ => http.Response('', 404),
        };
      });
      addTearDown(client.close);
      final bundle = await RuleImporter(
        client: client,
      ).importFromUrl('https://mirror.example/kazumi');
      expect(bundle.sourceUrl, 'https://mirror.example/kazumi');
      expect(bundle.rules.map((rule) => rule.name), ['Available']);
    },
  );

  test(
    'Animeko and TVBox imports retain subscription URL and declared content types',
    () async {
      final client = MockClient((request) async {
        return _json(
          request.url.path.endsWith('animeko.json') ? _animeko : _tvBox,
        );
      });
      addTearDown(client.close);
      final importer = RuleImporter(client: client);
      const animekoUrl = 'https://rules.example/animeko.json';
      const tvBoxUrl = 'https://rules.example/tvbox.json';
      final animeko = await importer.importFromUrl(animekoUrl);
      expect(animeko.sourceUrl, animekoUrl);
      expect(animeko.rules.single.engine, 'animeko-web-selector');
      expect(animeko.rules.single.canResolveNatively, isTrue);
      final tvBox = await importer.importFromUrl(tvBoxUrl);
      expect(tvBox.sourceUrl, tvBoxUrl);
      expect(
        tvBox.rules.map((rule) => rule.contentType),
        unorderedEquals(RuleContentType.values),
      );
      expect(tvBox.rules.every((rule) => rule.canResolveNatively), isTrue);
    },
  );

  test(
    'MoonTV / LunaTV api_site and LibreTV sources catalogs import as native 3-type rules',
    () async {
      final client = MockClient((request) async {
        if (request.url.path.endsWith('jin18.json')) {
          return _json({
            'cache_time': 7200,
            'api_site': {
              'ikunzy.com': {
                'api': 'https://ikunzyapi.com/api.php/provide/vod',
                'name': 'iKun资源',
              },
              'dyttzyapi.com': {
                'api': 'http://caiji.dyttzyapi.com/api.php/provide/vod',
                'name': '电影天堂',
              },
            },
          });
        }
        return _json({
          'name': 'LibreTV 精选源',
          'sources': [
            {'name': '极速资源', 'url': 'https://jszyapi.com/api.php/provide/vod'},
          ],
        });
      });
      addTearDown(client.close);
      final importer = RuleImporter(client: client);

      const lunaUrl =
          'https://raw.githubusercontent.com/hafrey1/LunaTV-config/main/jin18.json';
      final luna = await importer.importFromUrl(lunaUrl);
      expect(luna.name, 'hafrey1/LunaTV-config');
      expect(luna.sourceUrl, lunaUrl);
      // iKun资源 -> 3 content types (anime/series/movie), 电影天堂 -> movie.
      expect(luna.rules, hasLength(4));
      expect(
        luna.rules.every(
          (rule) => rule.engine == 'tvbox-json-api' && rule.canResolveNatively,
        ),
        isTrue,
      );
      expect(
        luna.rules.map((rule) => rule.contentType).toSet(),
        unorderedEquals(RuleContentType.values),
      );

      final libre = await importer.importFromUrl(
        'https://rules.example/libretv.json',
      );
      expect(libre.name, 'LibreTV 精选源');
      expect(libre.rules, hasLength(3));
      expect(libre.rules.every((r) => r.engine == 'tvbox-json-api'), isTrue);
    },
  );
}

http.Response _json(Object body) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

Map<String, Object> _kazumiEntry(String name) => {
  'name': name,
  'version': '1.0',
  'lastUpdate': 1784000000,
  'useNativePlayer': true,
};

Map<String, Object> _kazumiRule(String name) => {
  'name': name,
  'type': 'anime',
  'baseURL': 'https://media.example',
  'searchURL': 'https://media.example/search?q=@keyword',
  'searchList': '//li',
  'searchName': './a/text()',
  'searchResult': './a/@href',
  'chapterRoads': '//ul',
  'chapterResult': './li/a/@href',
};

const _animeko = {
  'exportedMediaSourceDataList': {
    'mediaSources': [
      {
        'factoryId': 'web-selector',
        'version': 2,
        'arguments': {
          'name': 'Anime fixture',
          'searchConfig': {
            'searchUrl': 'https://media.example/search?q={keyword}',
            'subjectFormatId': 'a',
            'selectorSubjectFormatA': {'selectLists': '.result a'},
            'channelFormatId': 'index-grouped',
            'selectorChannelFormatFlattened': {
              'selectEpisodeLists': '.playlist',
              'selectEpisodesFromList': 'a',
            },
          },
        },
      },
    ],
  },
};

const _tvBox = {
  'name': 'TVBox fixture',
  'sites': [
    {
      'key': 'three-types',
      'name': '三栖测试源',
      'type': 1,
      'api': 'https://api.example/site/vod',
    },
  ],
};
