import 'dart:convert';
import 'dart:io';

import 'package:anime/src/catalog/catalog_page.dart';
import 'package:anime/src/catalog/catalog_query.dart';
import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/data/bangumi_credential_store.dart';
import 'package:anime/src/data/tmdb_credential_store.dart';
import 'package:anime/src/data/zeluna_backend_catalog_repository.dart';
import 'package:anime/src/domain/subject_content_type.dart';
import 'package:anime/src/shared_ui/poster_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';

import '../test/support/fake_cloud_account_service.dart';

// Real backend and image bytes with the direct metadata API deliberately down.
// Does not change the device VPN, DNS, accounts or normal app persistence.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('CATALOG_NETWORK_LIVE');
  testWidgets(
    'anime catalog and decoded artwork survive blocked direct metadata',
    (tester) async {
      final dir = await Directory.systemTemp.createTemp(
        'zeluna-catalog-network-qa-',
      );
      Hive.init('${dir.path}/hive');
      final oldOverrides = HttpOverrides.current;
      HttpOverrides.global = _BlockDirectArtwork();
      addTearDown(() => HttpOverrides.global = oldOverrides);
      var directCalls = 0;
      final direct = MockClient((_) async {
        directCalls++;
        throw http.ClientException('QA: direct metadata unreachable');
      });
      final container = ProviderContainer(
        overrides: [
          cloudAccountServiceProvider.overrideWithValue(
            FakeCloudAccountService(),
          ),
          bangumiMetadataHttpClientProvider.overrideWithValue(direct),
          bangumiCredentialStoreProvider.overrideWithValue(
            BangumiCredentialStore(backend: _MemoryCredentials()),
          ),
          tmdbCredentialStoreProvider.overrideWithValue(
            TmdbCredentialStore(backend: _MemoryCredentials()),
          ),
        ],
      );
      var cleanedUp = false;
      Future<void> cleanUp() async {
        if (cleanedUp) return;
        cleanedUp = true;
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
        direct.close();
        await Hive.close();
        if (await dir.exists()) await dir.delete(recursive: true);
      }

      addTearDown(cleanUp);
      final state = await container
          .read(animeControllerProvider.future)
          .timeout(const Duration(seconds: 45));
      final controller = container.read(animeControllerProvider.notifier);
      final clock = Stopwatch()..start();
      final page = await controller.queryCatalog(
        const CatalogQuery(contentType: SubjectContentType.anime),
      );
      final catalogMs = clock.elapsedMilliseconds;
      expect(page.subjects, isNotEmpty);
      final catalog = ZelunaBackendCatalogRepository(
        baseUrl: state.services.playbackBackendEndpoint,
        client: container.read(zelunaBackendHttpClientProvider),
      );
      final matches = await catalog.search('败犬女主太多了');
      final subject = matches.firstWhere(
        (s) => s.identityKey == 'bangumi:464376',
      );
      clock.reset();
      final detail = await controller.detail(subject);
      final detailMs = clock.elapsedMilliseconds;
      expect(detail.episodes, isNotEmpty);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: PosterNetworkScope(
              catalogBase: Uri.parse(state.services.playbackBackendEndpoint),
              child: DetailPage(subject: subject),
            ),
          ),
        ),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      var decoded = false;
      while (DateTime.now().isBefore(deadline) && !decoded) {
        await tester.pump(const Duration(milliseconds: 200));
        decoded = find
            .descendant(
              of: find.byType(PosterArt),
              matching: find.byType(RawImage),
            )
            .evaluate()
            .any((element) {
              final image = (element.widget as RawImage).image;
              return image != null && image.width >= 100 && image.height >= 100;
            });
      }
      expect(
        decoded,
        isTrue,
        reason: 'actual artwork bytes must decode, not just a reachable URL',
      );
      expect(
        directCalls,
        0,
        reason: 'enabled backend must avoid the blocked metadata origin',
      );
      final report = {
        'catalog_ms': catalogMs,
        'detail_ms': detailMs,
        'poster_decoded': decoded,
        'direct_metadata_requests': directCalls,
        'episodes': detail.episodes.length,
        'physical_phone': false,
      };
      binding.reportData = report;
      // Only public timing/count evidence; never credentials or signed media URLs.
      // ignore: avoid_print
      print('CATALOG_NETWORK_QA ${jsonEncode(report)}');
      // Dispose in the same error zone that owns the in-flight socket futures.
      await cleanUp();
    },
    skip: !enabled,
  );
}

class _MemoryCredentials
    implements BangumiCredentialBackend, TmdbCredentialBackend {
  final _values = <String, String>{};
  @override
  Future<String?> read(String key) async => _values[key];
  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }
}

// Image.network must also fail if it accidentally falls back to the blocked
// origin. Backend traffic and normal certificate verification are unchanged.
class _BlockDirectArtwork extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)
        ..findProxy = (uri) {
          if (const {'api.bgm.tv', 'lain.bgm.tv'}.contains(uri.host)) {
            throw const SocketException('QA: direct artwork unreachable');
          }
          return 'DIRECT';
        };
}
