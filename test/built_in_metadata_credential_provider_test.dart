import 'dart:convert';
import 'dart:io';

import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/data/bangumi_credential_store.dart';
import 'package:anime/src/data/tmdb_credential_store.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/sources/source_catalog_models.dart';
import 'package:anime/src/sources/source_catalog_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _builtInTmdbToken =
    'tmdb_built_in_provider_test_token_not_a_real_secret_1234567890';
const _storedTmdbToken =
    'tmdb_stored_provider_test_token_not_a_real_secret_0987654321';
const _builtInBangumiToken =
    'bangumi_built_in_provider_test_token_not_a_real_secret';
const _storedBangumiToken =
    'bangumi_stored_provider_test_token_not_a_real_secret';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TMDB build-time credential provider', () {
    test('sends the build-time token as a bearer credential', () async {
      final store = TmdbCredentialStore(backend: _MemoryCredentialBackend());
      final client = MockClient((request) async {
        expect(request.headers['authorization'], 'Bearer $_builtInTmdbToken');
        return _tmdbResultsResponse();
      });
      final container = _tmdbContainer(
        builtInToken: _builtInTmdbToken,
        store: store,
        client: client,
      );
      addTearDown(container.dispose);

      await container
          .read(externalServiceRepositoryProvider)
          .tmdbDetail(_tmdbProbeSubject());
    });

    test('prefers the build-time token over an older stored token', () async {
      final store = TmdbCredentialStore(backend: _MemoryCredentialBackend());
      await store.saveToken(token: _storedTmdbToken);
      final requests = <http.Request>[];
      final container = _tmdbContainer(
        builtInToken: _builtInTmdbToken,
        store: store,
        client: MockClient((request) async {
          requests.add(request);
          return _tmdbResultsResponse();
        }),
      );
      addTearDown(container.dispose);

      await container
          .read(externalServiceRepositoryProvider)
          .tmdbDetail(_tmdbProbeSubject());

      expect(
        requests.single.headers['authorization'],
        'Bearer $_builtInTmdbToken',
      );
      expect(
        requests.single.headers['authorization'],
        isNot('Bearer $_storedTmdbToken'),
      );
    });

    test(
      'does not reject a stored account token after a built-in 401',
      () async {
        final store = TmdbCredentialStore(backend: _MemoryCredentialBackend());
        await store.saveToken(token: _storedTmdbToken);
        final container = _tmdbContainer(
          builtInToken: _builtInTmdbToken,
          store: store,
          client: MockClient((_) async => http.Response('', 401)),
        );
        addTearDown(container.dispose);

        await container
            .read(externalServiceRepositoryProvider)
            .tmdbDetail(_tmdbProbeSubject());

        expect((await store.readStatus()).health, TmdbCredentialHealth.ready);
        expect(await store.readAccessToken(), _storedTmdbToken);
      },
    );

    test('falls back to secure storage without a build-time token', () async {
      final store = TmdbCredentialStore(backend: _MemoryCredentialBackend());
      await store.saveToken(token: _storedTmdbToken);
      final requests = <http.Request>[];
      final container = _tmdbContainer(
        builtInToken: null,
        store: store,
        client: MockClient((request) async {
          requests.add(request);
          return _tmdbResultsResponse();
        }),
      );
      addTearDown(container.dispose);

      await container
          .read(externalServiceRepositoryProvider)
          .tmdbDetail(_tmdbProbeSubject());

      expect(
        requests.single.headers['authorization'],
        'Bearer $_storedTmdbToken',
      );
    });
  });

  group('Bangumi build-time credential provider', () {
    test('sends the build-time token as a bearer credential', () async {
      final store = BangumiCredentialStore(backend: _MemoryCredentialBackend());
      final client = MockClient((request) async {
        expect(
          request.headers['authorization'],
          'Bearer $_builtInBangumiToken',
        );
        return _bangumiDetailResponse(request, subjectId: 101);
      });
      final container = _bangumiContainer(
        builtInToken: _builtInBangumiToken,
        store: store,
        client: client,
      );
      addTearDown(container.dispose);

      await container.read(bangumiMetadataRepositoryProvider).detail(101);
    });

    test('prefers the build-time token over an older stored token', () async {
      final store = BangumiCredentialStore(backend: _MemoryCredentialBackend());
      await store.saveToken(token: _storedBangumiToken);
      final requests = <http.Request>[];
      final container = _bangumiContainer(
        builtInToken: _builtInBangumiToken,
        store: store,
        client: MockClient((request) async {
          requests.add(request);
          return _bangumiDetailResponse(request, subjectId: 102);
        }),
      );
      addTearDown(container.dispose);

      await container.read(bangumiMetadataRepositoryProvider).detail(102);

      expect(
        requests.every(
          (request) =>
              request.headers['authorization'] ==
              'Bearer $_builtInBangumiToken',
        ),
        isTrue,
      );
      expect(
        requests.any(
          (request) =>
              request.headers['authorization'] == 'Bearer $_storedBangumiToken',
        ),
        isFalse,
      );
    });

    test(
      'does not reject a stored account token after a built-in 401',
      () async {
        final store = BangumiCredentialStore(
          backend: _MemoryCredentialBackend(),
        );
        await store.saveToken(token: _storedBangumiToken);
        final container = _bangumiContainer(
          builtInToken: _builtInBangumiToken,
          store: store,
          client: MockClient((request) async {
            if (request.headers['authorization'] != null) {
              return http.Response('', 401);
            }
            return _bangumiDetailResponse(request, subjectId: 103);
          }),
        );
        addTearDown(container.dispose);

        await container.read(bangumiMetadataRepositoryProvider).detail(103);

        expect(
          (await store.readStatus()).health,
          BangumiCredentialHealth.ready,
        );
        expect(await store.readAccessToken(), _storedBangumiToken);
      },
    );

    test('falls back to secure storage without a build-time token', () async {
      final store = BangumiCredentialStore(backend: _MemoryCredentialBackend());
      await store.saveToken(token: _storedBangumiToken);
      final requests = <http.Request>[];
      final container = _bangumiContainer(
        builtInToken: null,
        store: store,
        client: MockClient((request) async {
          requests.add(request);
          return _bangumiDetailResponse(request, subjectId: 104);
        }),
      );
      addTearDown(container.dispose);

      await container.read(bangumiMetadataRepositoryProvider).detail(104);

      expect(
        requests.every(
          (request) =>
              request.headers['authorization'] == 'Bearer $_storedBangumiToken',
        ),
        isTrue,
      );
    });
  });

  test(
    'client credentials never re-enable retired direct metadata services',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'anime-built-in-credential-policy-',
      );
      Hive.init(root.path);
      final settingsBox = await Hive.openBox<dynamic>('anime.settings.v2');
      final disabledServices = const ExternalServiceSettings().copyWith(
        mediaMetadataEnabled: false,
        tmdbEnabled: false,
        cinemetaEnabled: false,
        peerTubeEnabled: false,
        wikimediaCommonsEnabled: false,
        anilistEnabled: false,
        jikanEnabled: false,
        kitsuEnabled: false,
        bangumiEnabled: false,
        preferBangumiChinese: false,
        publicCollectionSyncEnabled: false,
      );
      await settingsBox.put('services', disabledServices.toJson());
      await settingsBox.close();

      final bangumiClient = MockClient((request) async {
        if (request.url.path == '/calendar') {
          return http.Response(
            '[]',
            200,
            headers: const {'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode({'data': const [], 'total': 0, 'limit': 20}),
          200,
          headers: const {'content-type': 'application/json'},
        );
      });
      final tmdbClient = MockClient((_) async => _tmdbResultsResponse());
      final container = ProviderContainer(
        overrides: [
          bangumiBuiltInAccessTokenProvider.overrideWithValue(
            _builtInBangumiToken,
          ),
          tmdbBuiltInAccessTokenProvider.overrideWithValue(_builtInTmdbToken),
          bangumiCredentialStoreProvider.overrideWithValue(
            BangumiCredentialStore(backend: _MemoryCredentialBackend()),
          ),
          tmdbCredentialStoreProvider.overrideWithValue(
            TmdbCredentialStore(backend: _MemoryCredentialBackend()),
          ),
          bangumiMetadataHttpClientProvider.overrideWithValue(bangumiClient),
          externalServiceHttpClientProvider.overrideWithValue(tmdbClient),
          sourceCatalogRepositoryProvider.overrideWithValue(
            const _EmptySourceCatalogRepository(),
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        bangumiClient.close();
        tmdbClient.close();
        await Hive.close();
        if (await root.exists()) await root.delete(recursive: true);
      });

      var state = await container.read(animeControllerProvider.future);
      _expectClientMetadataDisabled(state.services);

      final controller = container.read(animeControllerProvider.notifier);
      await controller.updateServices(disabledServices);
      state = container.read(animeControllerProvider).requireValue;
      _expectClientMetadataDisabled(state.services);
      final persistedGuest = ExternalServiceSettings.fromJson(
        (Hive.box<dynamic>('anime.settings.v2').get('services') as Map)
            .cast<String, dynamic>(),
      );
      _expectClientMetadataDisabled(persistedGuest);

      await controller.registerAccount(
        email: 'built-in-policy-a@example.com',
        nickname: 'Built-in policy A',
        password: 'built-in-policy-password-a',
      );
      final firstAccountId = container
          .read(animeControllerProvider)
          .requireValue
          .accountSession
          .current!
          .id;
      await controller.registerAccount(
        email: 'built-in-policy-b@example.com',
        nickname: 'Built-in policy B',
        password: 'built-in-policy-password-b',
      );
      await Hive.box<dynamic>(
        'anime.settings.v2',
      ).put('account.$firstAccountId.services', disabledServices.toJson());

      await controller.loginAccount(
        email: 'built-in-policy-a@example.com',
        password: 'built-in-policy-password-a',
      );
      state = container.read(animeControllerProvider).requireValue;
      _expectClientMetadataDisabled(state.services);
    },
  );
}

void _expectClientMetadataDisabled(ExternalServiceSettings services) {
  expect(services.mediaMetadataEnabled, isTrue);
  expect(services.tmdbEnabled, isFalse);
  expect(services.bangumiEnabled, isFalse);
  expect(services.preferBangumiChinese, isTrue);
  expect(services.playbackBackendEnabled, isTrue);
  expect(services.playbackBackendEndpoint, 'https://api.zeluna.top');
}

ProviderContainer _tmdbContainer({
  required String? builtInToken,
  required TmdbCredentialStore store,
  required http.Client client,
}) {
  return ProviderContainer(
    overrides: [
      tmdbBuiltInAccessTokenProvider.overrideWithValue(builtInToken),
      tmdbCredentialStoreProvider.overrideWithValue(store),
      externalServiceHttpClientProvider.overrideWithValue(client),
    ],
  );
}

ProviderContainer _bangumiContainer({
  required String? builtInToken,
  required BangumiCredentialStore store,
  required http.Client client,
}) {
  return ProviderContainer(
    overrides: [
      bangumiBuiltInAccessTokenProvider.overrideWithValue(builtInToken),
      bangumiCredentialStoreProvider.overrideWithValue(store),
      bangumiMetadataHttpClientProvider.overrideWithValue(client),
    ],
  );
}

http.Response _tmdbResultsResponse() {
  return http.Response(
    jsonEncode({'page': 1, 'results': const []}),
    200,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

http.Response _bangumiDetailResponse(
  http.Request request, {
  required int subjectId,
}) {
  if (request.url.path == '/v0/subjects/$subjectId') {
    return http.Response(
      jsonEncode({
        'id': subjectId,
        'name': 'Provider test subject',
        'name_cn': 'Provider test subject',
        'summary': '',
        'date': '2026-07-23',
        'platform': 'TV',
        'total_episodes': 0,
        'meta_tags': const ['动画'],
        'tags': const [],
        'rating': const {},
      }),
      200,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );
  }
  if (request.url.path == '/v0/episodes') {
    return http.Response(
      jsonEncode({'data': const [], 'total': 0, 'limit': 100}),
      200,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );
  }
  return http.Response(
    '[]',
    200,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

AnimeSubject _tmdbProbeSubject() => const AnimeSubject(
  id: 603,
  title: '凭证探针',
  originalTitle: '',
  summary: '',
  coverUrl: null,
  bannerUrl: null,
  date: '2026-01-01',
  platform: '电影',
  language: '',
  region: '',
  status: '',
  categories: [],
  tags: [],
  totalEpisodes: 1,
  source: 'tmdb:movie',
);

class _MemoryCredentialBackend
    implements BangumiCredentialBackend, TmdbCredentialBackend {
  final Map<String, String> _values = {};

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }
}

class _EmptySourceCatalogRepository extends SourceCatalogRepository {
  const _EmptySourceCatalogRepository();

  @override
  Future<SourceCatalogState> loadCatalog({
    Map<String, bool> enabledOverrides = const {},
  }) async => const SourceCatalogState();
}
