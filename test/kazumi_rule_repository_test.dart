import 'dart:convert';

import 'package:anime/src/rules/kazumi_rule_repository.dart';
import 'package:anime/src/rules/rule_importer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('bundled Kazumi catalog is immediate, current and duplicate free', () {
    final catalog = KazumiRuleRepository.bundledCatalog;

    expect(catalog.entries, hasLength(22));
    expect(catalog.remote, isFalse);
    expect(
      catalog.entries.map((entry) => entry.id).toSet(),
      hasLength(catalog.entries.length),
    );
    expect(
      catalog.entries.map((entry) => entry.name),
      containsAll(['sorani', 'aafun', 'omofun03', 'MXdm']),
    );
    expect(RuleImporter.kazumiRuleId('MXdm'), 'kazumi:mxdm');
    expect(RuleImporter.kazumiRuleId('mxdm'), 'kazumi:mxdm');
  });

  test(
    'refresh reads the lightweight index without GitHub API scanning',
    () async {
      final requests = <Uri>[];
      final repository = KazumiRuleRepository(
        client: MockClient((request) async {
          requests.add(request.url);
          return http.Response(
            jsonEncode([
              {
                'name': 'older',
                'version': '1.0',
                'useNativePlayer': true,
                'antiCrawlerEnabled': false,
                'lastUpdate': 1000,
              },
              {
                'name': 'newer',
                'version': '2.0',
                'useNativePlayer': true,
                'antiCrawlerEnabled': true,
                'lastUpdate': 2000,
              },
            ]),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
      );

      final catalog = await repository.refreshCatalog();

      expect(requests, hasLength(1));
      expect(requests.single.toString(), KazumiRuleRepository.indexUrl);
      expect(catalog.remote, isTrue);
      expect(catalog.entries.map((entry) => entry.name), ['newer', 'older']);
    },
  );

  test(
    'batch load imports current Kazumi fields and keeps partial success',
    () async {
      final repository = KazumiRuleRepository(
        maxConcurrency: 2,
        client: MockClient((request) async {
          if (request.url.path.endsWith('/working.json')) {
            return http.Response(
              jsonEncode({
                'api': '8',
                'type': 'anime',
                'name': 'working',
                'version': '1.2',
                'muliSources': true,
                'useWebview': true,
                'useNativePlayer': true,
                'usePost': true,
                'useLegacyParser': true,
                'adBlocker': true,
                'baseURL': 'https://working.example/',
                'searchURL': '',
                'searchMode': 'api',
                'chapterMode': 'api',
                'searchList': '',
                'searchName': '',
                'searchResult': '',
                'chapterRoads': '',
                'chapterResult': '',
                'referer': 'https://working.example/',
                'searchApiConfig': {
                  'request': {
                    'method': 'GET',
                    'url': 'https://api.example/search',
                  },
                  'listPath': r'$.data[*]',
                  'namePath': r'$.title',
                  'sourcePath': r'$.id',
                },
                'chapterApiConfig': {
                  'format': 'nested',
                  'roadsPath': r'$.data',
                  'episodesPath': r'$.episodes[*]',
                },
                'antiCrawlerConfig': {'enabled': true},
              }),
              200,
            );
          }
          return http.Response('not found', 404);
        }),
      );
      const working = KazumiRuleCatalogEntry(
        name: 'working',
        version: '1.2',
        lastUpdateMilliseconds: 1783987200000,
      );
      const missing = KazumiRuleCatalogEntry(
        name: 'missing',
        version: '1.0',
        lastUpdateMilliseconds: 1783987200000,
      );

      final loaded = await repository.loadRules([working, missing]);
      final rule = loaded.bundle.rules.single;

      expect(loaded.failedNames, ['missing']);
      expect(loaded.bundle.sourceUrl, KazumiRuleRepository.indexUrl);
      expect(rule.id, 'kazumi:working');
      expect(rule.baseUrl, 'https://working.example/');
      expect(rule.searchable, isTrue);
      expect(rule.requiresWebView, isTrue);
      expect(rule.groupId, KazumiRuleRepository.groupId);
      expect(rule.kazumi?.apiLevel, '8');
      expect(rule.kazumi?.multipleSources, isTrue);
      expect(rule.kazumi?.usePost, isTrue);
      expect(rule.kazumi?.useLegacyParser, isTrue);
      expect(rule.kazumi?.adBlocker, isTrue);
      expect(rule.kazumi?.searchMode, 'api');
      expect(rule.kazumi?.chapterMode, 'api');
      expect(rule.kazumi?.searchApiConfig['listPath'], r'$.data[*]');
      expect(rule.kazumi?.chapterApiConfig['format'], 'nested');
      expect(rule.kazumi?.antiCrawlerConfig['enabled'], isTrue);
      expect(rule.rawConfig['baseURL'], 'https://working.example/');
    },
  );
}
