import 'dart:async';
import 'dart:io';

import 'package:anime/src/accounts/local_account_repository.dart';
import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/data/bangumi_credential_store.dart';
import 'package:anime/src/data/media_download_backend.dart';
import 'package:anime/src/data/media_download_result.dart';
import 'package:anime/src/data/media_download_service.dart';
import 'package:anime/src/data/media_download_task.dart';
import 'package:anime/src/data/tmdb_credential_store.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/sources/source_catalog_models.dart';
import 'package:anime/src/sources/source_catalog_repository.dart';
import 'package:anime/src/sync/cloud_sync_transport.dart';
import 'package:anime/src/sync/sync_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fake_cloud_account_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'accounts import legacy guest data once and isolate each library',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'anime-controller-accounts-',
      );
      Hive.init(root.path);
      final settings = await Hive.openBox<dynamic>('anime.settings.v2');
      final library = await Hive.openBox<dynamic>('anime.library.v2');
      await settings.put('services', _offlineServices.toJson());
      await settings.put('rulePlugins', _privateRuleState.toJson());
      await settings.put(
        'playback',
        const PlaybackSettings(speed: 1.5).toJson(),
      );
      await settings.put(
        'profile',
        const UserProfileSettings()
            .copyWith(nickname: 'fanyong', uid: '31979')
            .toJson(),
      );
      await settings.put(
        'homePreferences',
        const HomePreferences(defaultTab: AnimeHomeTab.browse).toJson(),
      );
      await settings.put(
        'appearance',
        const AppearanceSettings(
          darkMode: false,
          compactMode: true,
          reduceMotion: true,
        ).toJson(),
      );
      await settings.put(
        'danmaku',
        const DanmakuSettings(enabled: false, opacity: 0.4).toJson(),
      );
      await settings.put(
        'misc',
        const MiscSettings(
          autoCheckUpdates: false,
          wifiOnlyCache: false,
          keepScreenOn: false,
          saveCrashLog: false,
        ).toJson(),
      );
      await settings.put('sourceEnabled', const {'private-source': false});
      await library.put('favorites', [
        LibraryEntry(subject: _subject, updatedAt: DateTime(2026)).toJson(),
      ]);
      await library.put('history', [
        LibraryEntry(
          subject: _subject,
          episode: _episode,
          updatedAt: DateTime(2026),
        ).toJson(),
      ]);
      await library.put('following', [
        LibraryEntry(subject: _subject, updatedAt: DateTime(2026)).toJson(),
      ]);
      await library.put('imageFavorites', [
        LibraryEntry(
          subject: _subject,
          updatedAt: DateTime(2026),
          note: '收藏封面图',
        ).toJson(),
      ]);
      await library.put('feedbacks', [
        LocalFeedback(
          id: 'guest-feedback',
          title: '游客反馈',
          content: '仅第一账号可见',
          createdAt: DateTime(2026),
          subject: _subject,
        ).toJson(),
      ]);
      await library.put('offlineTasks', [
        MediaDownloadTask(
          id: 'guest-download',
          subject: _subject,
          episode: _episode,
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
          status: MediaDownloadTaskStatus.paused,
          url: 'https://media.example/video.mp4',
          headers: const {'Referer': 'https://media.example/'},
          message: '已暂停',
        ).toJson(),
      ]);
      await settings.close();
      await library.close();

      final container = ProviderContainer(
        overrides: [
          cloudAccountServiceProvider.overrideWithValue(
            FakeCloudAccountService(),
          ),
          bangumiCredentialStoreProvider.overrideWithValue(
            BangumiCredentialStore(backend: _MemoryCredentialBackend()),
          ),
          tmdbCredentialStoreProvider.overrideWithValue(
            TmdbCredentialStore(backend: _MemoryCredentialBackend()),
          ),
          sourceCatalogRepositoryProvider.overrideWithValue(
            const _EmptySourceCatalogRepository(),
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await Hive.close();
        if (await root.exists()) await root.delete(recursive: true);
      });

      var state = await container.read(animeControllerProvider.future);
      final controller = container.read(animeControllerProvider.notifier);
      expect(state.accountSession.isSignedIn, isFalse);
      expect(state.profile.nickname, '游客');
      expect(state.favorites.single.subject.title, _subject.title);

      await controller.registerAccount(
        email: 'first@example.com',
        nickname: '第一位用户',
        password: 'first-password',
        verificationCode: '123456',
      );
      state = container.read(animeControllerProvider).requireValue;
      expect(state.accountSession.current?.email, 'first@example.com');
      expect(state.profile.nickname, '第一位用户');
      expect(state.favorites.single.subject.title, _subject.title);
      expect(state.offlineTasks.single.id, startsWith('download:v1:'));
      expect(state.offlineTasks.single.legacyId, 'guest-download');
      expect(state.offlineTasks.single.legacyIds, contains('guest-download'));
      expect(state.settings.speed, 1.5);
      expect(state.history.single.episode?.id, _episode.id);
      expect(state.following.single.subject.id, _subject.id);
      expect(state.imageFavorites.single.note, '收藏封面图');
      expect(state.feedbacks.single.id, 'guest-feedback');
      expect(state.homePreferences.defaultTab, AnimeHomeTab.browse);
      expect(state.appearance.compactMode, isTrue);
      expect(state.appearance.reduceMotion, isTrue);
      expect(state.danmaku.enabled, isFalse);
      expect(state.danmaku.opacity, 0.4);
      expect(state.misc.keepScreenOn, isFalse);
      expect(state.services.bangumiEnabled, isFalse);
      expect(
        state.rulePlugins.customRules.map((rule) => rule.id),
        contains('private-rule'),
      );
      final firstAccountId = state.accountSession.current!.id;
      final migratedSettings = await Hive.openBox<dynamic>('anime.settings.v2');
      final migratedLibrary = await Hive.openBox<dynamic>('anime.library.v2');
      expect(migratedSettings.containsKey('playback'), isFalse);
      expect(migratedSettings.containsKey('services'), isFalse);
      expect(migratedSettings.containsKey('rulePlugins'), isFalse);
      expect(migratedSettings.containsKey('homePreferences'), isFalse);
      expect(migratedSettings.containsKey('appearance'), isFalse);
      expect(migratedSettings.containsKey('danmaku'), isFalse);
      expect(migratedSettings.containsKey('misc'), isFalse);
      expect(migratedSettings.containsKey('sourceEnabled'), isFalse);
      expect(migratedLibrary.containsKey('favorites'), isFalse);
      expect(migratedLibrary.containsKey('history'), isFalse);
      expect(migratedLibrary.containsKey('following'), isFalse);
      expect(migratedLibrary.containsKey('imageFavorites'), isFalse);
      expect(migratedLibrary.containsKey('feedbacks'), isFalse);
      expect(migratedLibrary.containsKey('offlineTasks'), isFalse);
      expect(
        migratedSettings.containsKey('account.$firstAccountId.services'),
        isTrue,
      );
      expect(
        migratedSettings.containsKey('account.$firstAccountId.sourceEnabled'),
        isTrue,
      );
      expect(
        migratedSettings.containsKey('account.$firstAccountId.rulePlugins'),
        isTrue,
      );
      expect(
        migratedLibrary.containsKey('account.$firstAccountId.offlineTasks'),
        isTrue,
      );

      await controller.registerAccount(
        email: 'second@example.com',
        nickname: '第二位用户',
        password: 'second-password',
        verificationCode: '123456',
      );
      state = container.read(animeControllerProvider).requireValue;
      expect(state.accountSession.current?.email, 'second@example.com');
      expect(state.favorites, isEmpty);
      expect(state.history, isEmpty);
      expect(state.following, isEmpty);
      expect(state.imageFavorites, isEmpty);
      expect(state.feedbacks, isEmpty);
      expect(state.offlineTasks, isEmpty);
      expect(state.settings.speed, const PlaybackSettings().speed);
      expect(state.homePreferences.defaultTab, AnimeHomeTab.recommended);
      expect(state.appearance.compactMode, isFalse);
      expect(state.danmaku.enabled, isFalse);
      expect(state.misc.keepScreenOn, isTrue);
      expect(state.services.bangumiEnabled, isFalse);
      expect(state.rulePlugins.customRules, isEmpty);
      await controller.toggleFavorite(_otherSubject);
      expect(
        container
            .read(animeControllerProvider)
            .requireValue
            .favorites
            .single
            .subject,
        _otherSubject,
      );

      await controller.loginAccount(
        email: 'first@example.com',
        password: 'first-password',
      );
      state = container.read(animeControllerProvider).requireValue;
      expect(state.profile.nickname, '第一位用户');
      expect(state.favorites.single.subject.title, _subject.title);
      expect(state.offlineTasks.single.id, startsWith('download:v1:'));
      expect(state.offlineTasks.single.legacyId, 'guest-download');
      expect(state.offlineTasks.single.legacyIds, contains('guest-download'));
      expect(state.settings.speed, 1.5);
      expect(state.history.single.episode?.id, _episode.id);
      expect(state.following.single.subject.id, _subject.id);
      expect(state.imageFavorites.single.note, '收藏封面图');
      expect(state.feedbacks.single.id, 'guest-feedback');
      expect(state.homePreferences.defaultTab, AnimeHomeTab.browse);
      expect(state.appearance.compactMode, isTrue);
      expect(state.danmaku.enabled, isFalse);
      expect(state.misc.keepScreenOn, isFalse);
      expect(state.services.bangumiEnabled, isFalse);
      expect(
        state.rulePlugins.customRules.map((rule) => rule.id),
        contains('private-rule'),
      );

      await controller.signOutAccount();
      state = container.read(animeControllerProvider).requireValue;
      expect(state.accountSession.isSignedIn, isFalse);
      expect(state.profile.nickname, '游客');
      expect(state.favorites, isEmpty);
      expect(state.history, isEmpty);
      expect(state.following, isEmpty);
      expect(state.imageFavorites, isEmpty);
      expect(state.feedbacks, isEmpty);
      expect(state.offlineTasks, isEmpty);
      expect(state.settings.speed, const PlaybackSettings().speed);
      expect(state.homePreferences.defaultTab, AnimeHomeTab.recommended);
      expect(state.appearance.compactMode, isFalse);

      await Future.wait([
        controller.loginAccount(
          email: 'first@example.com',
          password: 'first-password',
        ),
        controller.loginAccount(
          email: 'second@example.com',
          password: 'second-password',
        ),
      ]);
      state = container.read(animeControllerProvider).requireValue;
      final secondAccountId = state.accountSession.current!.id;
      expect(state.accountSession.current?.email, 'second@example.com');
      expect(
        LocalAccountRepository(
          await Hive.openBox<dynamic>(LocalAccountRepository.boxName),
        ).currentAccount()?.id,
        secondAccountId,
      );
      await migratedSettings.put('account.$secondAccountId.syncState.v1', {
        'schemaVersion': 1,
        'queue': <Object?>[],
      });
      await controller.deleteCurrentAccount(password: 'second-password');
      state = container.read(animeControllerProvider).requireValue;
      expect(state.accountSession.current, isNull);
      expect(state.accountSession.available, hasLength(1));
      expect(
        migratedLibrary.containsKey('account.$secondAccountId.favorites'),
        isFalse,
      );
      expect(
        migratedSettings.containsKey('account.$secondAccountId.syncState.v1'),
        isFalse,
      );

      await controller.loginAccount(
        email: 'first@example.com',
        password: 'first-password',
      );
      await controller.resetAccountPassword(
        email: 'FIRST@example.com ',
        verificationCode: '123456',
        newPassword: 'first-password-reset',
      );
      state = container.read(animeControllerProvider).requireValue;
      expect(state.accountSession.isSignedIn, isFalse);
      expect(state.profile.nickname, '游客');
      await expectLater(
        controller.loginAccount(
          email: 'first@example.com',
          password: 'first-password',
        ),
        throwsA(isA<AccountException>()),
      );
      await controller.loginAccount(
        email: 'first@example.com',
        password: 'first-password-reset',
      );
      expect(
        container
            .read(animeControllerProvider)
            .requireValue
            .accountSession
            .current
            ?.email,
        'first@example.com',
      );
    },
  );

  test(
    'pending first registration resumes safely on the next startup',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'anime-controller-account-recovery-',
      );
      Hive.init(root.path);
      final settings = await Hive.openBox<dynamic>('anime.settings.v2');
      final library = await Hive.openBox<dynamic>('anime.library.v2');
      final accounts = await Hive.openBox<dynamic>(
        LocalAccountRepository.boxName,
      );
      await settings.put('services', _offlineServices.toJson());
      await library.put('favorites', [
        LibraryEntry(subject: _subject, updatedAt: DateTime(2026)).toJson(),
      ]);
      final now = DateTime.now().toUtc();
      const recoveredId = 'cloud-recover-account';
      await LocalAccountRepository(accounts).beginCloudRegistration(
        account: LocalAccount(
          id: recoveredId,
          email: 'recover@example.com',
          nickname: '恢复用户',
          createdAt: now,
          lastLoginAt: now,
          cloudAuthenticated: true,
        ),
        importGuestData: true,
      );
      await LocalAccountRepository(accounts).completeRegistration(recoveredId);
      expect(LocalAccountRepository(accounts).currentAccount(), isNull);
      expect(
        LocalAccountRepository(accounts).pendingRegistration()?.account.id,
        recoveredId,
      );
      await settings.close();
      await library.close();
      await accounts.close();

      final container = ProviderContainer(
        overrides: [
          cloudAccountServiceProvider.overrideWithValue(
            FakeCloudAccountService(),
          ),
          bangumiCredentialStoreProvider.overrideWithValue(
            BangumiCredentialStore(backend: _MemoryCredentialBackend()),
          ),
          tmdbCredentialStoreProvider.overrideWithValue(
            TmdbCredentialStore(backend: _MemoryCredentialBackend()),
          ),
          sourceCatalogRepositoryProvider.overrideWithValue(
            const _EmptySourceCatalogRepository(),
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await Hive.close();
        if (await root.exists()) await root.delete(recursive: true);
      });

      final state = await container.read(animeControllerProvider.future);
      expect(state.accountSession.current?.id, recoveredId);
      expect(state.accountSession.current?.email, 'recover@example.com');
      expect(state.favorites.single.subject.title, _subject.title);
      final recoveredSettings = await Hive.openBox<dynamic>(
        'anime.settings.v2',
      );
      final recoveredLibrary = await Hive.openBox<dynamic>('anime.library.v2');
      final recoveredAccounts = await Hive.openBox<dynamic>(
        LocalAccountRepository.boxName,
      );
      expect(recoveredSettings.containsKey('services'), isFalse);
      expect(recoveredLibrary.containsKey('favorites'), isFalse);
      expect(
        LocalAccountRepository(recoveredAccounts).pendingRegistration(),
        isNull,
      );
    },
  );

  test('failed guest credential migration retries on next startup', () async {
    const token = 'controller_migration_test_token_abcdefghijklmnopqrstuvwxyz';
    final root = await Directory.systemTemp.createTemp(
      'anime-controller-credential-migration-',
    );
    Hive.init(root.path);
    final settings = await Hive.openBox<dynamic>('anime.settings.v2');
    await settings.put('services', _offlineServices.toJson());
    await settings.close();

    final backend = _FaultingCredentialBackend();
    final credentialStore = BangumiCredentialStore(backend: backend);
    await credentialStore.saveToken(token: token);
    backend.failNextWrite = true;
    final firstContainer = ProviderContainer(
      overrides: [
        cloudAccountServiceProvider.overrideWithValue(
          FakeCloudAccountService(),
        ),
        bangumiCredentialStoreProvider.overrideWithValue(credentialStore),
        tmdbCredentialStoreProvider.overrideWithValue(
          TmdbCredentialStore(backend: _MemoryCredentialBackend()),
        ),
        sourceCatalogRepositoryProvider.overrideWithValue(
          const _EmptySourceCatalogRepository(),
        ),
      ],
    );
    ProviderContainer? secondContainer;
    addTearDown(() async {
      secondContainer?.dispose();
      firstContainer.dispose();
      await Hive.close();
      if (await root.exists()) await root.delete(recursive: true);
    });

    await firstContainer.read(animeControllerProvider.future);
    final controller = firstContainer.read(animeControllerProvider.notifier);
    await controller.registerAccount(
      email: 'credential-retry@example.com',
      nickname: '凭据迁移用户',
      password: 'credential-password',
      verificationCode: '123456',
    );
    final accountId = firstContainer
        .read(animeControllerProvider)
        .requireValue
        .accountSession
        .current!
        .id;
    expect(await credentialStore.readAccessToken(), token);
    expect(await credentialStore.readAccessToken(accountId: accountId), isNull);
    final firstSettings = await Hive.openBox<dynamic>('anime.settings.v2');
    expect(firstSettings.get('credentials.pending.bangumi.v1'), accountId);

    firstContainer.dispose();
    await Hive.close();
    Hive.init(root.path);
    secondContainer = ProviderContainer(
      overrides: [
        cloudAccountServiceProvider.overrideWithValue(
          FakeCloudAccountService(),
        ),
        bangumiCredentialStoreProvider.overrideWithValue(credentialStore),
        tmdbCredentialStoreProvider.overrideWithValue(
          TmdbCredentialStore(backend: _MemoryCredentialBackend()),
        ),
        sourceCatalogRepositoryProvider.overrideWithValue(
          const _EmptySourceCatalogRepository(),
        ),
      ],
    );
    await secondContainer.read(animeControllerProvider.future);

    expect(await credentialStore.readAccessToken(), isNull);
    expect(await credentialStore.readAccessToken(accountId: accountId), token);
    final recoveredSettings = await Hive.openBox<dynamic>('anime.settings.v2');
    expect(
      recoveredSettings.containsKey('credentials.pending.bangumi.v1'),
      isFalse,
    );
  });

  test(
    'TMDB guest credential follows the first account and is cleared with it',
    () async {
      const token = 'tmdb_controller_guest_token_not_a_real_secret_1234567890';
      final root = await Directory.systemTemp.createTemp(
        'anime-controller-tmdb-credential-lifecycle-',
      );
      Hive.init(root.path);
      final settings = await Hive.openBox<dynamic>('anime.settings.v2');
      await settings.put('services', _offlineServices.toJson());
      await settings.close();

      final tmdbStore = TmdbCredentialStore(
        backend: _MemoryCredentialBackend(),
      );
      await tmdbStore.saveToken(token: token);
      final container = ProviderContainer(
        overrides: [
          cloudAccountServiceProvider.overrideWithValue(
            FakeCloudAccountService(),
          ),
          bangumiCredentialStoreProvider.overrideWithValue(
            BangumiCredentialStore(backend: _MemoryCredentialBackend()),
          ),
          tmdbCredentialStoreProvider.overrideWithValue(tmdbStore),
          sourceCatalogRepositoryProvider.overrideWithValue(
            const _EmptySourceCatalogRepository(),
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await Hive.close();
        if (await root.exists()) await root.delete(recursive: true);
      });

      await container.read(animeControllerProvider.future);
      final controller = container.read(animeControllerProvider.notifier);
      await controller.registerAccount(
        email: 'tmdb-first@example.com',
        nickname: 'TMDB User',
        password: 'tmdb-password',
        verificationCode: '123456',
      );
      final accountId = container
          .read(animeControllerProvider)
          .requireValue
          .accountSession
          .current!
          .id;

      expect(await tmdbStore.readAccessToken(), isNull);
      expect(await tmdbStore.readAccessToken(accountId: accountId), token);
      final migratedSettings = await Hive.openBox<dynamic>('anime.settings.v2');
      expect(
        migratedSettings.containsKey('credentials.pending.tmdb.v1'),
        isFalse,
      );

      await controller.deleteCurrentAccount(password: 'tmdb-password');

      expect(await tmdbStore.readAccessToken(accountId: accountId), isNull);
      expect(
        container
            .read(animeControllerProvider)
            .requireValue
            .accountSession
            .current,
        isNull,
      );
    },
  );

  test('failed TMDB guest migration retries on the next startup', () async {
    const token = 'tmdb_controller_retry_token_not_a_real_secret_1234567890';
    final root = await Directory.systemTemp.createTemp(
      'anime-controller-tmdb-credential-retry-',
    );
    Hive.init(root.path);
    final settings = await Hive.openBox<dynamic>('anime.settings.v2');
    await settings.put('services', _offlineServices.toJson());
    await settings.close();

    final backend = _FaultingCredentialBackend();
    final tmdbStore = TmdbCredentialStore(backend: backend);
    await tmdbStore.saveToken(token: token);
    backend.failNextWrite = true;
    final firstContainer = ProviderContainer(
      overrides: [
        cloudAccountServiceProvider.overrideWithValue(
          FakeCloudAccountService(),
        ),
        bangumiCredentialStoreProvider.overrideWithValue(
          BangumiCredentialStore(backend: _MemoryCredentialBackend()),
        ),
        tmdbCredentialStoreProvider.overrideWithValue(tmdbStore),
        sourceCatalogRepositoryProvider.overrideWithValue(
          const _EmptySourceCatalogRepository(),
        ),
      ],
    );
    ProviderContainer? secondContainer;
    addTearDown(() async {
      secondContainer?.dispose();
      firstContainer.dispose();
      await Hive.close();
      if (await root.exists()) await root.delete(recursive: true);
    });

    await firstContainer.read(animeControllerProvider.future);
    final controller = firstContainer.read(animeControllerProvider.notifier);
    await controller.registerAccount(
      email: 'tmdb-retry@example.com',
      nickname: 'TMDB Retry',
      password: 'tmdb-password',
      verificationCode: '123456',
    );
    final accountId = firstContainer
        .read(animeControllerProvider)
        .requireValue
        .accountSession
        .current!
        .id;
    expect(await tmdbStore.readAccessToken(), token);
    expect(await tmdbStore.readAccessToken(accountId: accountId), isNull);
    final firstSettings = await Hive.openBox<dynamic>('anime.settings.v2');
    expect(firstSettings.get('credentials.pending.tmdb.v1'), accountId);

    firstContainer.dispose();
    await Hive.close();
    Hive.init(root.path);
    secondContainer = ProviderContainer(
      overrides: [
        cloudAccountServiceProvider.overrideWithValue(
          FakeCloudAccountService(),
        ),
        bangumiCredentialStoreProvider.overrideWithValue(
          BangumiCredentialStore(backend: _MemoryCredentialBackend()),
        ),
        tmdbCredentialStoreProvider.overrideWithValue(tmdbStore),
        sourceCatalogRepositoryProvider.overrideWithValue(
          const _EmptySourceCatalogRepository(),
        ),
      ],
    );
    await secondContainer.read(animeControllerProvider.future);

    expect(await tmdbStore.readAccessToken(), isNull);
    expect(await tmdbStore.readAccessToken(accountId: accountId), token);
    final recoveredSettings = await Hive.openBox<dynamic>('anime.settings.v2');
    expect(
      recoveredSettings.containsKey('credentials.pending.tmdb.v1'),
      isFalse,
    );
  });

  test(
    'late TMDB rejection from the previous account cannot affect the new one',
    () async {
      const firstToken =
          'tmdb_controller_account_a_token_not_a_real_secret_123456';
      const secondToken =
          'tmdb_controller_account_b_token_not_a_real_secret_654321';
      final root = await Directory.systemTemp.createTemp(
        'anime-controller-tmdb-account-switch-',
      );
      Hive.init(root.path);
      final settings = await Hive.openBox<dynamic>('anime.settings.v2');
      await settings.put('services', _offlineServices.toJson());
      await settings.close();

      final oldRequestStarted = Completer<void>();
      final oldResponse = Completer<http.Response>();
      final authorizationHeaders = <String>[];
      final client = MockClient((request) async {
        final authorization =
            request.headers['authorization'] ??
            request.headers['Authorization'] ??
            '';
        authorizationHeaders.add(authorization);
        if (authorization == 'Bearer $firstToken') {
          if (!oldRequestStarted.isCompleted) oldRequestStarted.complete();
          return oldResponse.future;
        }
        return http.Response(
          '{"results":[]}',
          200,
          headers: const {'content-type': 'application/json'},
        );
      });
      final tmdbStore = TmdbCredentialStore(
        backend: _MemoryCredentialBackend(),
      );
      final container = ProviderContainer(
        overrides: [
          cloudAccountServiceProvider.overrideWithValue(
            FakeCloudAccountService(),
          ),
          bangumiCredentialStoreProvider.overrideWithValue(
            BangumiCredentialStore(backend: _MemoryCredentialBackend()),
          ),
          tmdbCredentialStoreProvider.overrideWithValue(tmdbStore),
          externalServiceHttpClientProvider.overrideWithValue(client),
          sourceCatalogRepositoryProvider.overrideWithValue(
            const _EmptySourceCatalogRepository(),
          ),
        ],
      );
      addTearDown(() async {
        if (!oldResponse.isCompleted) {
          oldResponse.complete(http.Response('', 401));
        }
        container.dispose();
        client.close();
        await Hive.close();
        if (await root.exists()) await root.delete(recursive: true);
      });

      await container.read(animeControllerProvider.future);
      final controller = container.read(animeControllerProvider.notifier);
      await controller.registerAccount(
        email: 'tmdb-account-a@example.com',
        nickname: 'TMDB Account A',
        password: 'tmdb-password-a',
        verificationCode: '123456',
      );
      final firstAccountId = container
          .read(animeControllerProvider)
          .requireValue
          .accountSession
          .current!
          .id;
      await tmdbStore.saveToken(accountId: firstAccountId, token: firstToken);

      await controller.registerAccount(
        email: 'tmdb-account-b@example.com',
        nickname: 'TMDB Account B',
        password: 'tmdb-password-b',
        verificationCode: '123456',
      );
      final secondAccountId = container
          .read(animeControllerProvider)
          .requireValue
          .accountSession
          .current!
          .id;
      await tmdbStore.saveToken(accountId: secondAccountId, token: secondToken);
      await controller.loginAccount(
        email: 'tmdb-account-a@example.com',
        password: 'tmdb-password-a',
      );

      final repository = container.read(externalServiceRepositoryProvider);
      final staleRequest = repository.tmdbDetail(_tmdbProbeSubject());
      await oldRequestStarted.future;
      await controller.loginAccount(
        email: 'tmdb-account-b@example.com',
        password: 'tmdb-password-b',
      );
      oldResponse.complete(http.Response('', 401));

      expect(await staleRequest, isNull);
      expect(
        (await tmdbStore.readStatus(accountId: firstAccountId)).health,
        TmdbCredentialHealth.ready,
      );
      expect(
        (await tmdbStore.readStatus(accountId: secondAccountId)).health,
        TmdbCredentialHealth.ready,
      );
      expect(await repository.tmdbDetail(_tmdbProbeSubject()), isNull);
      expect(authorizationHeaders.last, 'Bearer $secondToken');
    },
  );

  test('interrupted account deletion resumes on next startup', () async {
    final root = await Directory.systemTemp.createTemp(
      'anime-controller-account-delete-recovery-',
    );
    Hive.init(root.path);
    final mediaFile = File('${root.path}${Platform.pathSeparator}owned.mp4');
    await mediaFile.writeAsBytes([1, 2, 3]);
    final settings = await Hive.openBox<dynamic>('anime.settings.v2');
    final library = await Hive.openBox<dynamic>('anime.library.v2');
    await settings.put('services', _offlineServices.toJson());
    await library.put('offlineTasks', [
      MediaDownloadTask(
        id: 'owned-download',
        subject: _subject,
        episode: _episode,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        status: MediaDownloadTaskStatus.paused,
        localPath: mediaFile.path,
        message: '已暂停',
      ).toJson(),
    ]);
    await settings.close();
    await library.close();

    final failingService = MediaDownloadService(
      backend: _FileDeleteBackend(failFirstDelete: true),
    );
    final firstContainer = ProviderContainer(
      overrides: [
        cloudAccountServiceProvider.overrideWithValue(
          FakeCloudAccountService(),
        ),
        bangumiCredentialStoreProvider.overrideWithValue(
          BangumiCredentialStore(backend: _MemoryCredentialBackend()),
        ),
        tmdbCredentialStoreProvider.overrideWithValue(
          TmdbCredentialStore(backend: _MemoryCredentialBackend()),
        ),
        mediaDownloadServiceProvider.overrideWithValue(failingService),
        sourceCatalogRepositoryProvider.overrideWithValue(
          const _EmptySourceCatalogRepository(),
        ),
      ],
    );
    ProviderContainer? secondContainer;
    MediaDownloadService? recoveryService;
    addTearDown(() async {
      secondContainer?.dispose();
      recoveryService?.dispose();
      firstContainer.dispose();
      failingService.dispose();
      await Hive.close();
      if (await root.exists()) await root.delete(recursive: true);
    });

    await firstContainer.read(animeControllerProvider.future);
    final controller = firstContainer.read(animeControllerProvider.notifier);
    await controller.registerAccount(
      email: 'delete@example.com',
      nickname: '待删除用户',
      password: 'delete-password',
      verificationCode: '123456',
    );
    final accountId = firstContainer
        .read(animeControllerProvider)
        .requireValue
        .accountSession
        .current!
        .id;

    await expectLater(
      controller.deleteCurrentAccount(password: 'delete-password'),
      throwsA(isA<AccountException>()),
    );
    expect(
      firstContainer
          .read(animeControllerProvider)
          .requireValue
          .accountSession
          .hasPendingCleanup,
      isTrue,
    );
    expect(mediaFile.existsSync(), isTrue);
    final accountBox = await Hive.openBox<dynamic>(
      LocalAccountRepository.boxName,
    );
    expect(LocalAccountRepository(accountBox).pendingDeletion(), isNotNull);
    expect(accountBox.containsKey('account.$accountId'), isFalse);

    firstContainer.dispose();
    failingService.dispose();
    await Hive.close();
    Hive.init(root.path);
    final guestSettings = await Hive.openBox<dynamic>('anime.settings.v2');
    await guestSettings.put('services', _offlineServices.toJson());
    await guestSettings.close();

    recoveryService = MediaDownloadService(backend: _FileDeleteBackend());
    secondContainer = ProviderContainer(
      overrides: [
        cloudAccountServiceProvider.overrideWithValue(
          FakeCloudAccountService(),
        ),
        bangumiCredentialStoreProvider.overrideWithValue(
          BangumiCredentialStore(backend: _MemoryCredentialBackend()),
        ),
        tmdbCredentialStoreProvider.overrideWithValue(
          TmdbCredentialStore(backend: _MemoryCredentialBackend()),
        ),
        mediaDownloadServiceProvider.overrideWithValue(recoveryService),
        sourceCatalogRepositoryProvider.overrideWithValue(
          const _EmptySourceCatalogRepository(),
        ),
      ],
    );
    final recovered = await secondContainer.read(
      animeControllerProvider.future,
    );
    expect(recovered.accountSession.current, isNull);
    expect(recovered.accountSession.available, isEmpty);
    expect(recovered.accountSession.hasPendingCleanup, isFalse);
    expect(mediaFile.existsSync(), isFalse);
    final recoveredAccounts = await Hive.openBox<dynamic>(
      LocalAccountRepository.boxName,
    );
    expect(LocalAccountRepository(recoveredAccounts).pendingDeletion(), isNull);
  });

  test(
    'cloud account sync is local-first, merges pulls, and isolates logout',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'anime-controller-cloud-sync-',
      );
      Hive.init(root.path);
      final settings = await Hive.openBox<dynamic>('anime.settings.v2');
      await settings.put('services', _offlineServices.toJson());
      await settings.close();
      final cloud = _SyncCloudAccountService();
      final container = ProviderContainer(
        overrides: [
          cloudAccountServiceProvider.overrideWithValue(cloud),
          bangumiCredentialStoreProvider.overrideWithValue(
            BangumiCredentialStore(backend: _MemoryCredentialBackend()),
          ),
          tmdbCredentialStoreProvider.overrideWithValue(
            TmdbCredentialStore(backend: _MemoryCredentialBackend()),
          ),
          sourceCatalogRepositoryProvider.overrideWithValue(
            const _EmptySourceCatalogRepository(),
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await Hive.close();
        if (await root.exists()) await root.delete(recursive: true);
      });
      await container.read(animeControllerProvider.future);
      final controller = container.read(animeControllerProvider.notifier);

      await controller.registerAccount(
        email: 'sync@example.com',
        nickname: '同步用户',
        password: 'sync-password',
        verificationCode: '123456',
      );
      await _waitForSync(
        () =>
            container
                .read(animeControllerProvider)
                .requireValue
                .syncStatus
                .phase ==
            SyncPhase.synced,
      );
      cloud.pushed.clear();

      expect(await controller.toggleFavorite(_subject), isTrue);
      expect(
        container.read(animeControllerProvider).requireValue.favorites,
        hasLength(1),
        reason: 'local UI updates before the cloud acknowledgement',
      );
      await _waitForSync(
        () => cloud.pushed.any(
          (batch) =>
              batch.any((item) => item.type == CloudSyncRecordType.favorite),
        ),
      );
      await _waitForSync(
        () =>
            container
                .read(animeControllerProvider)
                .requireValue
                .syncStatus
                .phase ==
            SyncPhase.synced,
      );

      final remote = CloudSyncMutation.library(
        mutationId: 'sync:v1:remote-device:00000001',
        type: CloudSyncRecordType.following,
        entry: LibraryEntry(
          subject: _subject,
          updatedAt: DateTime.utc(2026, 8, 8),
        ),
      );
      cloud.addRemote(remote);
      final pushesBeforePull = cloud.pushed.length;
      await controller.synchronizeCloud();
      expect(
        container.read(animeControllerProvider).requireValue.following,
        hasLength(1),
      );
      expect(
        cloud.pushed,
        hasLength(pushesBeforePull),
        reason: 'pull must not echo',
      );

      await controller.signOutAccount();
      expect(
        container.read(animeControllerProvider).requireValue.syncStatus.phase,
        SyncPhase.localOnly,
      );
      final pushesBeforeGuestMutation = cloud.pushed.length;
      await controller.toggleFavorite(_subject);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(cloud.pushed, hasLength(pushesBeforeGuestMutation));
    },
  );
}

class _SyncCloudAccountService extends FakeCloudAccountService
    implements CloudSyncTransport {
  final pushed = <List<CloudSyncMutation>>[];
  final _records = <CloudSyncRecord>[];
  var _revision = 0;

  @override
  Future<CloudSyncPushResult> push(List<CloudSyncMutation> mutations) async {
    pushed.add(List<CloudSyncMutation>.from(mutations));
    final acknowledged = mutations
        .map((mutation) {
          final record = _record(mutation, ++_revision);
          _records.removeWhere(
            (item) =>
                item.type == record.type && item.recordId == record.recordId,
          );
          _records.add(record);
          return record;
        })
        .toList(growable: false);
    return CloudSyncPushResult(
      acknowledged: acknowledged,
      nextRevision: acknowledged.last.serverRevision,
    );
  }

  @override
  Future<CloudSyncPullResult> pull({
    required int afterRevision,
    int limit = 200,
  }) async {
    final records = _records
        .where((item) => item.serverRevision > afterRevision)
        .take(limit)
        .toList(growable: false);
    return CloudSyncPullResult(
      records: records,
      nextRevision: records.isEmpty
          ? afterRevision
          : records.last.serverRevision,
    );
  }

  void addRemote(CloudSyncMutation mutation) {
    final record = _record(mutation, ++_revision);
    _records.removeWhere(
      (item) => item.type == record.type && item.recordId == record.recordId,
    );
    _records.add(record);
  }

  CloudSyncRecord _record(CloudSyncMutation mutation, int revision) =>
      CloudSyncRecord.fromJson({
        'type': mutation.type.wireName,
        'record_id': mutation.recordId,
        'payload': mutation.payload,
        'deleted': mutation.deleted,
        'client_mutation_id': mutation.mutationId,
        'server_revision': revision,
      });
}

Future<void> _waitForSync(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for cloud sync.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

class _MemoryCredentialBackend
    implements BangumiCredentialBackend, TmdbCredentialBackend {
  final values = <String, String>{};

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

class _FaultingCredentialBackend extends _MemoryCredentialBackend {
  bool failNextWrite = false;

  @override
  Future<void> write(String key, String value) async {
    if (failNextWrite) {
      failNextWrite = false;
      throw StateError('simulated secure write failure');
    }
    await super.write(key, value);
  }
}

class _EmptySourceCatalogRepository extends SourceCatalogRepository {
  const _EmptySourceCatalogRepository();

  @override
  Future<SourceCatalogState> loadCatalog({
    Map<String, bool> enabledOverrides = const {},
  }) async => const SourceCatalogState();
}

class _FileDeleteBackend implements MediaDownloadBackend {
  _FileDeleteBackend({this.failFirstDelete = false});

  final bool failFirstDelete;
  var _deleteAttempts = 0;

  @override
  Future<MediaDownloadResult> download({
    required MediaDownloadRequest request,
    required MediaDownloadControl control,
    required void Function(MediaDownloadProgress progress) onProgress,
  }) => throw UnsupportedError('Downloads are not used by this test');

  @override
  Future<void> deleteFile(String path) async {
    _deleteAttempts++;
    if (failFirstDelete && _deleteAttempts == 1) {
      throw const FileSystemException('simulated delete interruption');
    }
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  @override
  Future<bool> fileExists(String path) => File(path).exists();
}

const _offlineServices = ExternalServiceSettings(
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
);

const _subject = AnimeSubject(
  id: 101,
  title: '游客收藏',
  originalTitle: 'Guest Favorite',
  summary: '用于验证首次账号迁移',
  coverUrl: null,
  bannerUrl: null,
  date: '2026-01-01',
  platform: '测试',
  language: '中文',
  region: '中国',
  status: '完结',
  categories: [],
  tags: [],
  totalEpisodes: 1,
  source: 'test',
);

const _otherSubject = AnimeSubject(
  id: 202,
  title: '第二账号收藏',
  originalTitle: 'Second Account Favorite',
  summary: '用于验证账号数据隔离',
  coverUrl: null,
  bannerUrl: null,
  date: '2026-01-01',
  platform: '测试',
  language: '中文',
  region: '中国',
  status: '完结',
  categories: [],
  tags: [],
  totalEpisodes: 1,
  source: 'test',
);

const _episode = AnimeEpisode(
  id: 101,
  subjectId: 101,
  number: 1,
  title: '第一集',
  airdate: '2026-01-01',
  duration: '24:00',
  description: '',
);

final _privateRuleState = RulePluginState(
  installedIds: const {'private-rule'},
  enabledIds: const {'private-rule'},
  customRules: [
    RulePlugin(
      id: 'private-rule',
      name: '私密源',
      version: '1.0',
      source: RuleSourceKind.custom,
      contentType: RuleContentType.anime,
      engine: 'native',
      updatedAt: DateTime(2026),
      qualityScore: 60,
      tags: const ['私密'],
      baseUrl: 'https://private.example',
      searchUrl: 'https://private.example/search?q=@keyword',
      searchable: true,
      quickSearch: true,
      filterable: false,
      requiresPrivateAuth: true,
      rawConfig: const {'Cookie': 'session=private'},
    ),
  ],
);

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
