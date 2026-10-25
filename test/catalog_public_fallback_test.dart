import 'dart:convert';

import 'package:anime/src/catalog/catalog_query.dart';
import 'package:anime/src/data/bangumi_metadata_repository.dart';
import 'package:anime/src/data/zeluna_backend_catalog_repository.dart';
import 'package:anime/src/domain/subject_content_type.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'failed direct metadata is relayed with a bounded retry cooldown',
    () async {
      var now = DateTime.utc(2026, 10, 6);
      final client = MockClient((_) async => http.Response('{}', 200));
      final repository = BangumiMetadataRepository(
        client: client,
        clock: () => now,
      );
      addTearDown(repository.close);
      var directCalls = 0;
      var relayCalls = 0;
      Future<int> direct() async {
        directCalls++;
        throw http.ClientException('network unavailable');
      }

      Future<int> relay() async => ++relayCalls;
      expect(await repository.withPublicCatalogFallback(direct, relay), 1);
      expect(await repository.withPublicCatalogFallback(direct, relay), 2);
      expect(directCalls, 1);
      now = now.add(const Duration(minutes: 3));
      expect(await repository.withPublicCatalogFallback(direct, relay), 3);
      expect(directCalls, 2);
      // Returning direct access after cooldown clears the failed-route hint.
      now = now.add(const Duration(minutes: 3));
      expect(
        await repository.withPublicCatalogFallback(() async => 99, relay),
        99,
      );
      expect(
        await repository.withPublicCatalogFallback(() async => 100, relay),
        100,
      );
      expect(relayCalls, 3);
    },
  );

  test(
    'disabled or failing relay is never reported as an empty catalogue',
    () async {
      final repository = BangumiMetadataRepository();
      addTearDown(repository.close);
      Future<int> fail() async => throw StateError('unavailable');
      await expectLater(
        repository.withPublicCatalogFallback(fail, null),
        throwsStateError,
      );
      await expectLater(
        repository.withPublicCatalogFallback(fail, fail),
        throwsStateError,
      );
    },
  );

  test('provider rate limits are not bypassed by the public relay', () async {
    final repository = BangumiMetadataRepository();
    addTearDown(repository.close);
    var relayed = false;
    await expectLater(
      repository.withPublicCatalogFallback<int>(
        () async => throw BangumiRateLimitException(
          retryAt: DateTime.now(),
          uri: Uri.parse('https://api.bgm.tv/calendar'),
        ),
        () async {
          relayed = true;
          return 1;
        },
      ),
      throwsA(isA<BangumiRateLimitException>()),
    );
    expect(relayed, isFalse);
  });

  test(
    'calendar and browse relay preserve parsing and never send account auth',
    () async {
      final paths = <String>[];
      final client = MockClient((request) async {
        paths.add(request.url.path);
        expect(request.headers.containsKey('Authorization'), isFalse);
        expect(request.headers.containsKey('authorization'), isFalse);
        expect(request.headers.containsKey('cookie'), isFalse);
        final subject = {
          'id': 987654,
          'type': 2,
          'name': 'Test',
          'name_cn': '公开番剧',
          'date': '2026-01-01',
          'air_date': '2026-01-01',
          'platform': 'TV',
          'tags': [
            {'name': '国产'},
          ],
          'images': <String, dynamic>{},
        };
        if (request.url.path.endsWith('/calendar')) {
          return http.Response(
            jsonEncode([
              {
                'weekday': {'id': 1},
                'items': [subject],
              },
            ]),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        expect(request.url.queryParameters['year'], '2026');
        expect(request.url.queryParameters['offset'], '100');
        return http.Response(
          jsonEncode({
            'data': [subject],
            'total': 101,
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      addTearDown(client.close);
      final backend = ZelunaBackendCatalogRepository(
        baseUrl: 'https://catalog.example/prefix',
        client: client,
      );
      final calendar = await backend.weeklySchedule();
      expect(calendar[1]!.single.title, '公开番剧');
      final page = await backend.queryAnimeCatalog(
        const CatalogQuery(
          contentType: SubjectContentType.anime,
          sort: CatalogSortMode.latest,
          year: 2026,
        ),
        cursor: 'date:2026:100',
      );
      expect(page.subjects.single.title, '公开番剧');
      expect(paths, [
        '/prefix/api/v3/catalog/bangumi/calendar',
        '/prefix/api/v3/catalog/bangumi/v0/subjects',
      ]);
    },
  );
}
