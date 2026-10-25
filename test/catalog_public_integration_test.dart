// Opt-in, read-only verification against public metadata. Never uses account tokens.
import 'package:anime/src/catalog/catalog_query.dart';
import 'package:anime/src/core/network/network_http_client.dart';
import 'package:anime/src/core/network/network_security.dart';
import 'package:anime/src/data/zeluna_backend_catalog_repository.dart';
import 'package:anime/src/data/bangumi_metadata_repository.dart';
import 'package:anime/src/domain/subject_content_type.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'public current calendar and 2026 discovery return real catalogue data',
    () async {
      final repository = BangumiMetadataRepository();
      addTearDown(repository.close);
      final backendClient = createNetworkHttpClient(
        NetworkRequestPolicy.forService(
          NetworkServiceKind.officialPlaybackBackend,
        ),
      );
      addTearDown(backendClient.close);
      final backend = ZelunaBackendCatalogRepository(
        baseUrl: 'https://api.zeluna.top',
        client: backendClient,
      );
      var publicRelayRequests = 0;
      Future<CatalogPageResult> query(CatalogQuery value) => repository
          .withPublicCatalogFallback(() => repository.queryCatalog(value), () {
            publicRelayRequests++;
            return backend.queryAnimeCatalog(value);
          });
      final calendar = await repository.withPublicCatalogFallback(
        () => repository.weeklySchedule(strict: true),
        () {
          publicRelayRequests++;
          return backend.weeklySchedule();
        },
      );
      final calendarCount = calendar.values.fold<int>(
        0,
        (n, entries) => n + entries.length,
      );
      expect(calendar.keys, containsAll([0, 1, 2, 3, 4, 5, 6]));
      expect(calendarCount, greaterThan(0));
      final latest = await query(
        const CatalogQuery(
          contentType: SubjectContentType.anime,
          sort: CatalogSortMode.latest,
          year: 2026,
        ),
      );
      expect(latest.subjects, isNotEmpty);
      expect(latest.subjects.every((s) => s.year == '2026'), isTrue);
      final scienceFiction = await query(
        const CatalogQuery(
          contentType: SubjectContentType.anime,
          genre: '科幻',
          year: 2026,
        ),
      );
      expect(scienceFiction.subjects, isNotEmpty);
      final chinese = await query(
        const CatalogQuery(
          contentType: SubjectContentType.anime,
          year: 2026,
          language: '国语',
        ),
      );
      expect(chinese.subjects, isNotEmpty);
      expect(chinese.subjects.every((s) => s.language == '国语'), isTrue);
      final earlier = await query(
        const CatalogQuery(
          contentType: SubjectContentType.anime,
          year: 2024,
          genre: '科幻',
        ),
      );
      expect(earlier.subjects, isNotEmpty);
      expect(earlier.subjects.every((s) => s.year == '2024'), isTrue);
      // Counts and dates only; no authentication or user data in diagnostics.
      // ignore: avoid_print
      print(
        'PUBLIC_CATALOG calendar=$calendarCount latest2026=${latest.subjects.length} '
        'newest=${latest.subjects.first.date} scienceFiction2026=${scienceFiction.subjects.length} '
        'hasMore=${latest.hasMore} chinese2026=${chinese.subjects.length} scienceFiction2024=${earlier.subjects.length} '
        'publicRelayRequests=$publicRelayRequests',
      );
    },
    skip: !const bool.fromEnvironment('RUN_PUBLIC_CATALOG_PROBE'),
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
