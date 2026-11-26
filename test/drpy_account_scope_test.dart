import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:anime/src/accounts/account_controller.dart';
import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/data/bangumi_credential_store.dart';
import 'package:anime/src/data/tmdb_credential_store.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/rules/drpy_runtime.dart';
import 'package:anime/src/rules/rule_playback_resolver.dart';
import 'package:anime/src/sources/source_catalog_models.dart';
import 'package:anime/src/sources/source_catalog_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fake_cloud_account_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (!Platform.isWindows) return;
    DynamicLibrary.open(File.fromUri(await _resolveJsfDllUri()).path);
  });

  test(
    'CORE-003 real activation retires DRPY before source loading awaits',
    () async {
      final fixture = await _fixture();
      await _run(fixture.runtime, fixture.client, 'guest');
      await _run(fixture.runtime, fixture.client, 'guest');
      expect(fixture.runtime.storage.snapshot('scope-rule')['seen'], 2);
      final entered = Completer<void>();
      final release = Completer<void>();
      fixture.catalog.onLoad = () async {
        entered.complete();
        await release.future;
      };
      final login = fixture.controller.loginAccount(
        email: 'scope@example.test',
        password: 'fixture-password',
      );
      try {
        await entered.future.timeout(const Duration(seconds: 3));
        expect(fixture.runtime.storage.snapshot('scope-rule'), isEmpty);
      } finally {
        release.complete();
        await login;
        fixture.catalog.onLoad = null;
      }
      await _run(fixture.runtime, fixture.client, 'account');
      expect(fixture.runtime.storage.snapshot('scope-rule')['seen'], 1);
      await fixture.controller.loginAccount(
        email: 'scope-b@example.test',
        password: 'fixture-password',
      );
      expect(fixture.runtime.storage.debugSnapshot, isEmpty);
      await _run(fixture.runtime, fixture.client, 'account-b');
      expect(fixture.runtime.storage.snapshot('scope-rule')['seen'], 1);
      await fixture.controller.signOutAccount();
      expect(fixture.runtime.storage.debugSnapshot, isEmpty);
      await _run(fixture.runtime, fixture.client, 'guest-again');
      expect(fixture.runtime.storage.snapshot('scope-rule')['seen'], 1);
    },
  );

  test(
    'CORE-003 ordinary cache clear and forced probe preserve script storage',
    () async {
      final fixture = await _fixture();
      await _run(fixture.runtime, fixture.client, 'guest');
      fixture.container.read(rulePlaybackResolverProvider).clearCaches();
      await fixture.controller.updateSettings(
        const PlaybackSettings(rememberLine: false),
      );
      await fixture.controller.verifyPlaybackLine(
        const PlaybackLine(
          id: 'force-probe',
          episodeId: 1,
          providerId: 'fixture',
          providerName: 'Fixture',
          title: 'Fixture',
          quality: '',
          format: 'mp4',
          url: 'https://media.example.com/force.mp4',
        ),
        enrichMetadata: false,
        forceRefresh: true,
      );
      await _run(fixture.runtime, fixture.client, 'guest');
      expect(fixture.runtime.storage.snapshot('scope-rule')['seen'], 2);
    },
  );

  for (final retire in ['sign-out', 'dispose']) {
    test(
      'CORE-003 $retire rejects late worker results and writeback',
      () async {
        final fixture = await _fixture();
        await fixture.controller.loginAccount(
          email: 'scope@example.test',
          password: 'fixture-password',
        );
        await _run(fixture.runtime, fixture.client, 'account');
        final entered = Completer<void>();
        final release = Completer<void>();
        final blockedClient = MockClient((_) async {
          entered.complete();
          await release.future;
          return http.Response('{}', 200);
        });
        final old = _run(fixture.runtime, blockedClient, 'retired');
        addTearDown(() async {
          if (!release.isCompleted) release.complete();
          await old;
        });
        await entered.future.timeout(const Duration(seconds: 3));
        if (retire == 'sign-out') {
          await fixture.controller.signOutAccount();
          await _run(fixture.runtime, fixture.client, 'new-scope');
        } else {
          fixture.container.dispose();
        }
        release.complete();
        final result = await old;
        expect(result.succeeded, isFalse);
        expect(result.candidates, isEmpty);
        if (retire == 'sign-out') {
          expect(fixture.runtime.storage.snapshot('scope-rule'), {
            'seen': 1,
            'marker': 'new-scope',
          });
        } else {
          expect(fixture.runtime.storage.debugSnapshot, isEmpty);
        }
      },
    );
  }
}

Future<
  ({
    ProviderContainer container,
    AnimeController controller,
    DrpyRuntime runtime,
    http.Client client,
    _Catalog catalog,
  })
>
_fixture() async {
  final root = await Directory.systemTemp.createTemp('drpy-account-scope-');
  Hive.init(root.path);
  final settings = await Hive.openBox<dynamic>('anime.settings.v2');
  const offline = ExternalServiceSettings(
    mediaMetadataEnabled: false,
    tmdbEnabled: false,
    cinemetaEnabled: false,
    peerTubeEnabled: false,
    wikimediaCommonsEnabled: false,
    anilistEnabled: false,
    jikanEnabled: false,
    kitsuEnabled: false,
    bangumiEnabled: false,
    publicCollectionSyncEnabled: false,
    bilibiliSubtitleEnabled: false,
    dandanplayDanmakuEnabled: false,
    bilibiliDanmakuEnabled: false,
    playbackBackendEnabled: false,
  );
  final accounts = FakeCloudAccountService();
  final account = await accounts.register(
    email: 'scope@example.test',
    nickname: 'Scope',
    password: 'fixture-password',
    verificationCode: '000000',
  );
  final secondAccount = await accounts.register(
    email: 'scope-b@example.test',
    nickname: 'Scope B',
    password: 'fixture-password',
    verificationCode: '000000',
  );
  await accounts.logout();
  await settings.put('services', offline.toJson());
  await settings.put(
    AccountController.settingsKeyFor(account.id, 'services'),
    offline.toJson(),
  );
  await settings.put(
    AccountController.settingsKeyFor(secondAccount.id, 'services'),
    offline.toJson(),
  );
  await settings.close();
  final client = MockClient((_) async => http.Response('{}', 200));
  final runtime = DrpyRuntime(
    addressLookup: (_) async => [InternetAddress('93.184.216.34')],
  );
  final resolver = RulePlaybackResolver(
    client: client,
    rulePublicClient: client,
    drpyPublicClient: client,
    drpyRuntime: runtime,
  );
  final catalog = _Catalog();
  final container = ProviderContainer(
    overrides: [
      cloudAccountServiceProvider.overrideWithValue(accounts),
      bangumiCredentialStoreProvider.overrideWithValue(
        BangumiCredentialStore(backend: _MemoryCredentials()),
      ),
      tmdbCredentialStoreProvider.overrideWithValue(
        TmdbCredentialStore(backend: _MemoryCredentials()),
      ),
      sourceCatalogRepositoryProvider.overrideWithValue(catalog),
      rulePlaybackResolverProvider.overrideWithValue(resolver),
      zelunaBackendHttpClientProvider.overrideWithValue(client),
      bangumiMetadataHttpClientProvider.overrideWithValue(client),
      externalServiceHttpClientProvider.overrideWithValue(client),
    ],
  );
  addTearDown(() async {
    container.dispose();
    await Hive.close();
    client.close();
    if (await root.exists()) {
      final resolved = await root.resolveSymbolicLinks();
      final temp = await Directory.systemTemp.resolveSymbolicLinks();
      if (!resolved.startsWith(
        '$temp${Platform.pathSeparator}drpy-account-scope-',
      )) {
        throw StateError('Refusing to delete a non-fixture directory.');
      }
      await Directory(resolved).delete(recursive: true);
    }
  });
  await container.read(animeControllerProvider.future);
  return (
    container: container,
    controller: container.read(animeControllerProvider.notifier),
    runtime: runtime,
    client: client,
    catalog: catalog,
  );
}

Future<DrpyRuntimeResult> _run(
  DrpyRuntime runtime,
  http.Client client,
  String marker,
) => runtime.resolve(
  DrpyRuntimeRequest(
    ruleId: 'scope-rule',
    keyword: marker,
    episodeNumber: 1,
    episodeTitle: '',
    ruleSource: _scopeRule,
  ),
  client: client,
);

class _Catalog extends SourceCatalogRepository {
  Future<void> Function()? onLoad;

  @override
  Future<SourceCatalogState> loadCatalog({
    Map<String, bool> enabledOverrides = const {},
  }) async {
    await onLoad?.call();
    return const SourceCatalogState();
  }
}

class _MemoryCredentials
    implements BangumiCredentialBackend, TmdbCredentialBackend {
  final values = <String, String>{};
  @override
  Future<void> delete(String key) async => values.remove(key);
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

const _scopeRule = r'''
var rule = {
  host: 'https://example.com',
  ['\u641c\u7d22']: $js.toString(() => {
    request('https://example.com/search');
    setItem('seen', Number(getItem('seen', 0)) + 1);
    setItem('marker', KEY);
    VODS = [{vod_id: '/detail', vod_name: KEY}];
  }),
  ['\u4e8c\u7ea7']: $js.toString(() => {
    VOD = {vod_name: KEY, vod_play_from: 'direct',
      vod_play_url: 'episode 1$https://media.example.com/1.mp4'};
  })
};
''';

Future<Uri> _resolveJsfDllUri() async {
  try {
    final packageUri = await Isolate.resolvePackageUri(
      Uri.parse('package:jsf/jsf.dart'),
    );
    if (packageUri != null) return packageUri.resolve('../windows/jsf.dll');
  } on UnsupportedError {
    // The Flutter test runner does not expose package URI resolution on every
    // host, so fall back to the same package configuration it compiled with.
  }
  final configFile = File('.dart_tool/package_config.json').absolute;
  final config = jsonDecode(await configFile.readAsString()) as Map;
  final packages = config['packages'] as List? ?? const [];
  final jsf = packages.whereType<Map>().firstWhere(
    (entry) => entry['name'] == 'jsf',
    orElse: () => throw StateError('Unable to locate jsf in package_config.'),
  );
  final rootUri = configFile.uri.resolve(jsf['rootUri'].toString());
  final directoryUri = rootUri.path.endsWith('/')
      ? rootUri
      : rootUri.replace(path: '${rootUri.path}/');
  return directoryUri.resolve('windows/jsf.dll');
}
