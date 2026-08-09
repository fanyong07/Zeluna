import 'dart:async';
import 'dart:io';

import 'package:anime/src/accounts/account_controller.dart';
import 'package:anime/src/accounts/cloud_account_repository.dart';
import 'package:anime/src/accounts/local_account_repository.dart';
import 'package:anime/src/data/bangumi_credential_store.dart';
import 'package:anime/src/data/search_history_store.dart';
import 'package:anime/src/data/tmdb_credential_store.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/recommendations/recommendation_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import 'support/fake_cloud_account_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('serializes account changes and owns context revisions', () async {
    final root = await Directory.systemTemp.createTemp(
      'account-controller-ownership-',
    );
    Hive.init(root.path);
    final settings = await Hive.openBox<dynamic>('settings');
    final library = await Hive.openBox<dynamic>('library');
    final accounts = await Hive.openBox<dynamic>('accounts');
    addTearDown(() async {
      await Hive.close();
      if (await root.exists()) await root.delete(recursive: true);
    });

    final firstActivationStarted = Completer<void>();
    final releaseFirstActivation = Completer<void>();
    final activations = <AccountScopeActivation>[];
    final selectedContexts = <({String? accountId, bool reset})>[];
    final profileUpdates = <AccountProfileUpdate>[];
    var activationCalls = 0;
    var quiesceCalls = 0;
    final credentialBackend = _MemoryCredentialBackend();
    final cloudService = FakeCloudAccountService();
    final controller = AccountController(
      cloudService: cloudService,
      localRepository: LocalAccountRepository(accounts),
      settings: settings,
      library: library,
      bangumiCredentialStore: BangumiCredentialStore(
        backend: credentialBackend,
      ),
      tmdbCredentialStore: TmdbCredentialStore(backend: credentialBackend),
      activateScope: (activation) async {
        activationCalls++;
        if (activationCalls == 1) {
          firstActivationStarted.complete();
          await releaseFirstActivation.future;
        }
        activations.add(activation);
      },
      quiesceDownloads: () async => quiesceCalls++,
      readOwnedDownloads: () => const <AccountOwnedDownload>[],
      cancelDownload: (_, _) {},
      deleteDownloadFile: (_) async {},
      selectCredentialContext: (accountId, {required resetCredentialState}) {
        selectedContexts.add((
          accountId: accountId,
          reset: resetCredentialState,
        ));
      },
      publishSession: (_) {},
      publishProfile: profileUpdates.add,
    );

    final bootstrap = await controller.initialize();
    expect(bootstrap.activeAccount, isNull);
    expect(bootstrap.session.isSignedIn, isFalse);
    expect(selectedContexts, [(accountId: null, reset: false)]);

    final first = controller.register(
      email: 'first@example.com',
      nickname: 'First',
      password: 'first-password',
      verificationCode: '123456',
    );
    await firstActivationStarted.future;
    final second = controller.register(
      email: 'second@example.com',
      nickname: 'Second',
      password: 'second-password',
      verificationCode: '123456',
    );
    await Future<void>.delayed(Duration.zero);

    expect(activationCalls, 1);
    expect(controller.contextVersion, 1);
    expect(controller.activeAccount?.email, 'first@example.com');

    releaseFirstActivation.complete();
    await Future.wait([first, second]);

    expect(activations.map((value) => value.contextVersion), [1, 2]);
    expect(controller.contextVersion, 2);
    expect(controller.activeAccount?.email, 'second@example.com');
    expect(controller.session.available, hasLength(2));
    expect(quiesceCalls, 2);
    expect(selectedContexts.skip(1).every((value) => value.reset), isTrue);

    final secondAccountId = controller.activeAccount!.id;
    await controller.updateProfile(
      const UserProfileSettings().copyWith(nickname: 'Second Renamed'),
    );
    expect(controller.activeAccount?.nickname, 'Second Renamed');
    expect(profileUpdates.single.profile.nickname, 'Second Renamed');
    expect(
      settings.containsKey(
        AccountController.settingsKeyFor(secondAccountId, 'profile'),
      ),
      isTrue,
    );

    final signedInContext = controller.contextVersion;
    await controller.signOut();
    expect(controller.activeAccount, isNull);
    expect(controller.contextVersion, 3);
    expect(activations.last.account, isNull);
    expect(quiesceCalls, 3);
    expect(
      () => controller.ensureContext(signedInContext),
      throwsA(isA<AccountException>()),
    );

    await controller.login(
      email: 'second@example.com',
      password: 'second-password',
    );
    final deletion = await controller.requestCloudAccountDeletion(
      password: 'second-password',
    );
    expect(
      deletion.dueAt.difference(deletion.requestedAt),
      const Duration(days: 7),
    );
    expect(controller.activeAccount, isNull);
    expect(
      controller.session.available.map((account) => account.email),
      contains('second@example.com'),
    );
    await expectLater(
      controller.login(
        email: 'second@example.com',
        password: 'second-password',
      ),
      throwsA(isA<AccountDeletionPendingException>()),
    );
    await controller.cancelCloudAccountDeletionAndLogin(
      email: 'second@example.com',
      password: 'second-password',
    );
    expect(controller.activeAccount?.email, 'second@example.com');
  });

  test(
    'first registration migrates and account deletion clears recommendation data',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'account-controller-recommendation-data-',
      );
      Hive.init(root.path);
      final settings = await Hive.openBox<dynamic>('settings');
      final library = await Hive.openBox<dynamic>('library');
      final accounts = await Hive.openBox<dynamic>('accounts');
      addTearDown(() async {
        await Hive.close();
        if (await root.exists()) await root.delete(recursive: true);
      });

      const behavior = [
        {'subjectKey': 'bangumi:1', 'type': 'play'},
      ];
      const served = [
        {'subjectKey': 'bangumi:2', 'servedAt': '2026-08-09T00:00:00Z'},
      ];
      const homeCache = {'version': 1, 'items': <Object>[]};
      await library.put(recommendationBehaviorStorageKey, behavior);
      await library.put(recommendationServedStorageKey, served);
      await library.put('metadata.cache.home', homeCache);
      final searchHistory = SearchHistoryStore();
      await searchHistory.add('', '科幻');
      await searchHistory.add('', '冒险');

      final credentialBackend = _MemoryCredentialBackend();
      final controller = AccountController(
        cloudService: FakeCloudAccountService(),
        localRepository: LocalAccountRepository(accounts),
        settings: settings,
        library: library,
        bangumiCredentialStore: BangumiCredentialStore(
          backend: credentialBackend,
        ),
        tmdbCredentialStore: TmdbCredentialStore(backend: credentialBackend),
        activateScope: (_) async {},
        quiesceDownloads: () async {},
        readOwnedDownloads: () => const <AccountOwnedDownload>[],
        cancelDownload: (_, _) {},
        deleteDownloadFile: (_) async {},
        selectCredentialContext: (_, {required resetCredentialState}) {},
        publishSession: (_) {},
        publishProfile: (_) {},
        searchHistoryStore: searchHistory,
      );

      await controller.initialize();
      await controller.register(
        email: 'recommendations@example.com',
        nickname: 'Recommendations',
        password: 'recommendation-password',
        verificationCode: '123456',
      );
      final accountId = controller.activeAccount!.id;

      expect(
        library.get(
          AccountController.libraryKeyFor(
            accountId,
            recommendationBehaviorStorageKey,
          ),
        ),
        behavior,
      );
      expect(
        library.get(
          AccountController.libraryKeyFor(
            accountId,
            recommendationServedStorageKey,
          ),
        ),
        served,
      );
      expect(
        library.get(
          AccountController.libraryKeyFor(accountId, 'metadata.cache.home'),
        ),
        homeCache,
      );
      expect(library.containsKey(recommendationBehaviorStorageKey), isFalse);
      expect(library.containsKey(recommendationServedStorageKey), isFalse);
      expect(library.containsKey('metadata.cache.home'), isFalse);
      expect(await searchHistory.load(''), isEmpty);
      expect(await searchHistory.load(accountId), ['冒险', '科幻']);

      await controller.deleteCurrent(password: 'recommendation-password');

      expect(
        library.containsKey(
          AccountController.libraryKeyFor(
            accountId,
            recommendationBehaviorStorageKey,
          ),
        ),
        isFalse,
      );
      expect(
        library.containsKey(
          AccountController.libraryKeyFor(
            accountId,
            recommendationServedStorageKey,
          ),
        ),
        isFalse,
      );
      expect(
        library.containsKey(
          AccountController.libraryKeyFor(accountId, 'metadata.cache.home'),
        ),
        isFalse,
      );
      expect(await searchHistory.load(accountId), isEmpty);
    },
  );
}

class _MemoryCredentialBackend
    implements BangumiCredentialBackend, TmdbCredentialBackend {
  final _values = <String, String>{};

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
