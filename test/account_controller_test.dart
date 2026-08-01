import 'dart:async';
import 'dart:io';

import 'package:anime/src/accounts/account_controller.dart';
import 'package:anime/src/accounts/local_account_repository.dart';
import 'package:anime/src/data/bangumi_credential_store.dart';
import 'package:anime/src/data/tmdb_credential_store.dart';
import 'package:anime/src/domain/anime_models.dart';
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
    final controller = AccountController(
      cloudService: FakeCloudAccountService(),
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
      cancelDownload: (_) {},
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
  });
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
