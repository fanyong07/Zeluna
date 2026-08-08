import 'dart:async';
import 'dart:typed_data';

import 'package:hive_ce_flutter/hive_flutter.dart';

import '../data/bangumi_credential_store.dart';
import '../data/tmdb_credential_store.dart';
import '../domain/anime_models.dart';
import 'cloud_account_repository.dart';
import 'local_account_repository.dart';

typedef AccountScopeActivator =
    Future<void> Function(AccountScopeActivation activation);
typedef AccountDownloadQuiescer = Future<void> Function();
typedef AccountOwnedDownloadsReader = List<AccountOwnedDownload> Function();
typedef AccountDownloadCanceller =
    void Function(String accountId, String taskId);
typedef AccountDownloadFileDeleter = Future<void> Function(String path);
typedef AccountContextSelector =
    void Function(String? accountId, {required bool resetCredentialState});
typedef AccountSessionPublisher = void Function(LocalAccountSession session);
typedef AccountProfilePublisher = void Function(AccountProfileUpdate update);

final class AccountOwnedDownload {
  const AccountOwnedDownload({
    required this.id,
    this.temporaryPath,
    this.localPath,
  });

  final String id;
  final String? temporaryPath;
  final String? localPath;
}

final class AccountBootstrap {
  const AccountBootstrap({required this.activeAccount, required this.session});

  final LocalAccount? activeAccount;
  final LocalAccountSession session;
}

final class AccountScopeActivation {
  const AccountScopeActivation({
    required this.account,
    required this.session,
    required this.contextVersion,
  });

  final LocalAccount? account;
  final LocalAccountSession session;
  final int contextVersion;
}

final class AccountProfileUpdate {
  const AccountProfileUpdate({
    required this.accountId,
    required this.profile,
    required this.session,
  });

  final String? accountId;
  final UserProfileSettings profile;
  final LocalAccountSession session;
}

/// Owns account identity, lifecycle recovery, serialized account operations,
/// and the account-context revision used to reject stale cross-domain work.
///
/// Other domains remain behind callbacks while [AnimeController] is migrated.
/// This keeps account switching atomic without making this controller depend on
/// the legacy aggregate application state.
final class AccountController {
  AccountController({
    required CloudAccountService cloudService,
    required LocalAccountRepository localRepository,
    required Box<dynamic> settings,
    required Box<dynamic> library,
    required BangumiCredentialStore bangumiCredentialStore,
    required TmdbCredentialStore tmdbCredentialStore,
    required AccountScopeActivator activateScope,
    required AccountDownloadQuiescer quiesceDownloads,
    required AccountOwnedDownloadsReader readOwnedDownloads,
    required AccountDownloadCanceller cancelDownload,
    required AccountDownloadFileDeleter deleteDownloadFile,
    required AccountContextSelector selectCredentialContext,
    required AccountSessionPublisher publishSession,
    required AccountProfilePublisher publishProfile,
  }) : _cloudService = cloudService,
       _localRepository = localRepository,
       _settings = settings,
       _library = library,
       _bangumiCredentialStore = bangumiCredentialStore,
       _tmdbCredentialStore = tmdbCredentialStore,
       _activateScope = activateScope,
       _quiesceDownloads = quiesceDownloads,
       _readOwnedDownloads = readOwnedDownloads,
       _cancelDownload = cancelDownload,
       _deleteDownloadFile = deleteDownloadFile,
       _selectCredentialContext = selectCredentialContext,
       _publishSession = publishSession,
       _publishProfile = publishProfile;

  static const _pendingBangumiCredentialMigrationKey =
      'credentials.pending.bangumi.v1';
  static const _pendingTmdbCredentialMigrationKey =
      'credentials.pending.tmdb.v1';
  static const _accountSettingKeys = [
    'playback',
    'profile',
    'homePreferences',
    'appearance',
    'danmaku',
    'misc',
    'services',
    'rulePlugins',
    'sourceEnabled',
    'syncState.v1',
  ];
  static const _accountLibraryKeys = [
    'favorites',
    'history',
    'following',
    'offlineTasks',
    'imageFavorites',
    'feedbacks',
  ];

  final CloudAccountService _cloudService;
  final LocalAccountRepository _localRepository;
  final Box<dynamic> _settings;
  final Box<dynamic> _library;
  final BangumiCredentialStore _bangumiCredentialStore;
  final TmdbCredentialStore _tmdbCredentialStore;
  final AccountScopeActivator _activateScope;
  final AccountDownloadQuiescer _quiesceDownloads;
  final AccountOwnedDownloadsReader _readOwnedDownloads;
  final AccountDownloadCanceller _cancelDownload;
  final AccountDownloadFileDeleter _deleteDownloadFile;
  final AccountContextSelector _selectCredentialContext;
  final AccountSessionPublisher _publishSession;
  final AccountProfilePublisher _publishProfile;

  LocalAccount? _activeAccount;
  var _contextVersion = 0;
  var _initialized = false;
  Future<void> _operationQueue = Future<void>.value();

  LocalAccount? get activeAccount => _activeAccount;
  int get contextVersion => _contextVersion;
  bool get isInitialized => _initialized;

  LocalAccountSession get session => LocalAccountSession(
    current: _activeAccount,
    available: _localRepository.listCloudAccounts(),
    hasPendingCleanup: _localRepository.pendingDeletion() != null,
  );

  static String settingsKeyFor(String? accountId, String key) =>
      accountId == null ? key : 'account.$accountId.$key';

  static String libraryKeyFor(String? accountId, String key) =>
      accountId == null ? key : 'account.$accountId.$key';

  String settingsKey(String key) => settingsKeyFor(_activeAccount?.id, key);

  String libraryKey(String key) => libraryKeyFor(_activeAccount?.id, key);

  bool isContextCurrent(int version) => version == _contextVersion;

  void ensureContext(int expectedVersion) {
    if (!isContextCurrent(expectedVersion)) {
      throw const AccountException('账号已切换，请重新打开当前内容');
    }
  }

  Future<AccountBootstrap> initialize() async {
    if (_initialized) {
      return AccountBootstrap(activeAccount: _activeAccount, session: session);
    }

    final pendingDeletion = _localRepository.pendingDeletion();
    if (pendingDeletion != null) {
      try {
        await _resumePendingDeletion(pendingDeletion);
      } catch (_) {
        // Keep the durable marker. The user can retry after startup.
      }
    }
    try {
      await _resumePendingBangumiCredentialMigration();
    } catch (_) {
      // Secure-storage failures retain the non-secret retry marker.
    }
    try {
      await _resumePendingTmdbCredentialMigration();
    } catch (_) {
      // Secure-storage failures retain the non-secret retry marker.
    }

    final pendingRegistration = _localRepository.pendingRegistration();
    LocalAccount? recoveredRegistration;
    if (pendingRegistration != null) {
      await _resumePendingRegistration(pendingRegistration);
      recoveredRegistration = pendingRegistration.account;
    }
    final cachedAccount =
        recoveredRegistration ?? _localRepository.currentCloudAccount();
    final restoredAccount = await _cloudService.restoreSession(cachedAccount);
    if (restoredAccount != null) {
      await _localRepository.rememberCloudAccount(restoredAccount);
      if (recoveredRegistration != null) {
        await _localRepository.finalizeRegistration(restoredAccount.id);
      }
    } else {
      await _localRepository.signOut();
    }
    _activeAccount = restoredAccount;
    _selectCredentialContext(_activeAccount?.id, resetCredentialState: false);
    if (recoveredRegistration != null) {
      await _localRepository.setActiveAccount(recoveredRegistration.id);
      await _localRepository.finalizeRegistration(recoveredRegistration.id);
    }
    _initialized = true;
    return AccountBootstrap(activeAccount: _activeAccount, session: session);
  }

  Future<void> register({
    required String email,
    required String nickname,
    required String password,
    required String verificationCode,
  }) => _runOperation(() async {
    _requireInitialized();
    final account = await _cloudService.register(
      email: email,
      nickname: nickname,
      password: password,
      verificationCode: verificationCode,
    );
    await _quiesceDownloads();
    await _settings.flush();
    await _library.flush();
    final shouldImportGuestData =
        _activeAccount == null && _localRepository.listCloudAccounts().isEmpty;
    await _localRepository.beginCloudRegistration(
      account: account,
      importGuestData: shouldImportGuestData,
    );
    final pending = _localRepository.pendingRegistration();
    if (pending == null) throw const AccountException('账号初始化失败，请重试');
    await _resumePendingRegistration(pending);
    await _activate(pending.account);
    await _localRepository.finalizeRegistration(pending.account.id);
  });

  Future<void> requestRegistrationCode(String email) =>
      _cloudService.requestRegistrationCode(email);

  Future<void> requestPasswordResetCode(String email) =>
      _cloudService.requestPasswordResetCode(email);

  Future<void> resetPassword({
    required String email,
    required String verificationCode,
    required String newPassword,
  }) => _runOperation(() async {
    _requireInitialized();
    final normalizedEmail = email.trim().toLowerCase();
    await _cloudService.resetPassword(
      email: normalizedEmail,
      verificationCode: verificationCode,
      newPassword: newPassword,
    );
    if (_activeAccount?.email != normalizedEmail) return;
    await _cloudService.logout();
    await _quiesceDownloads();
    await _activate(null);
  });

  Future<void> login({required String email, required String password}) =>
      _runOperation(() async {
        _requireInitialized();
        final account = await _cloudService.login(
          email: email,
          password: password,
        );
        await _localRepository.rememberCloudAccount(account);
        await _quiesceDownloads();
        await _activate(account);
      });

  Future<void> signOut() => _runOperation(() async {
    _requireInitialized();
    await _cloudService.logout();
    await _quiesceDownloads();
    await _activate(null);
  });

  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) => _runOperation(() async {
    _requireInitialized();
    if (_activeAccount == null) throw const AccountException('请先登录账号');
    await _cloudService.changePassword(
      currentPassword: currentPassword,
      newPassword: newPassword,
    );
  });

  Future<void> updateProfile(
    UserProfileSettings profile,
  ) => _runOperation(() async {
    _requireInitialized();
    var normalized = profile;
    final account = _activeAccount;
    if (account != null) {
      final cloudUpdated = await _cloudService.updateNickname(profile.nickname);
      final updated = await _localRepository.rememberCloudAccount(cloudUpdated);
      if (_activeAccount?.id != account.id) return;
      _activeAccount = updated;
      normalized = profile.copyWith(
        nickname: updated.nickname,
        uid: updated.shortId,
      );
    }
    _publishProfile(
      AccountProfileUpdate(
        accountId: account?.id,
        profile: normalized,
        session: session,
      ),
    );
    await _settings.put(
      settingsKeyFor(account?.id, 'profile'),
      normalized.toJson(),
    );
  });

  Future<void> deleteCurrent({required String password}) =>
      _runOperation(() async {
        _requireInitialized();
        final account = _activeAccount;
        if (account == null) throw const AccountException('请先登录账号');
        await _cloudService.verifyPassword(password);
        await _cloudService.logout();
        await _quiesceDownloads();
        final ownedDownloads = _readOwnedDownloads();
        final pendingDeletion = await _localRepository.beginDeletion(
          accountId: account.id,
          taskIds: ownedDownloads.map((task) => task.id),
          paths: ownedDownloads.expand(
            (task) => <String?>[task.temporaryPath, task.localPath],
          ),
        );
        await _activate(null);
        try {
          await _resumePendingDeletion(pendingDeletion);
        } finally {
          _publishSession(session);
        }
      });

  Future<Uint8List> exportAccountData() {
    _requireInitialized();
    if (_activeAccount == null) {
      throw const AccountException('请先登录账号');
    }
    return _cloudService.exportAccountData();
  }

  Future<AccountDeletionSchedule> requestCloudAccountDeletion({
    required String password,
  }) => _runOperation(() async {
    _requireInitialized();
    if (_activeAccount == null) throw const AccountException('请先登录账号');
    await _quiesceDownloads();
    final schedule = await _cloudService.requestAccountDeletion(password);
    await _activate(null);
    return schedule;
  });

  Future<void> cancelCloudAccountDeletionAndLogin({
    required String email,
    required String password,
  }) => _runOperation(() async {
    _requireInitialized();
    await _cloudService.cancelAccountDeletion(email: email, password: password);
    final account = await _cloudService.login(email: email, password: password);
    await _localRepository.rememberCloudAccount(account);
    await _quiesceDownloads();
    await _activate(account);
  });

  Future<void> retryPendingCleanup() => _runOperation(() async {
    _requireInitialized();
    final pending = _localRepository.pendingDeletion();
    if (pending != null) await _resumePendingDeletion(pending);
    _publishSession(session);
  });

  static UserProfileSettings profileFromJson(
    Object? value,
    LocalAccount? account,
  ) {
    var profile = value is Map
        ? UserProfileSettings.fromJson(value.cast<String, dynamic>())
        : const UserProfileSettings();
    if (account != null) {
      return profile.copyWith(
        nickname: account.nickname,
        uid: account.shortId,
        density: profile.density < 0 ? 0 : profile.density,
        coins: profile.coins < 0 ? 0 : profile.coins,
      );
    }
    final isLegacyPlaceholder =
        profile.nickname.trim().toLowerCase() == 'fanyong' &&
        profile.uid == '31979';
    if (isLegacyPlaceholder || profile.nickname.trim().isEmpty) {
      profile = const UserProfileSettings();
    }
    return profile;
  }

  Future<void> _activate(LocalAccount? account) async {
    final accountId = account?.id;
    await _localRepository.setActiveAccount(accountId);
    _activeAccount = account;
    _selectCredentialContext(accountId, resetCredentialState: true);
    _contextVersion++;
    await _activateScope(
      AccountScopeActivation(
        account: account,
        session: session,
        contextVersion: _contextVersion,
      ),
    );
  }

  Future<void> _resumePendingRegistration(
    PendingLocalAccountRegistration pending,
  ) async {
    final accountId = pending.account.id;
    if (pending.importGuestData) {
      await _settings.put(_pendingBangumiCredentialMigrationKey, accountId);
      try {
        await _bangumiCredentialStore.migrateGuestToAccount(accountId);
        await _settings.delete(_pendingBangumiCredentialMigrationKey);
      } catch (_) {
        // Registration remains usable; startup retries the durable marker.
      }
      await _settings.put(_pendingTmdbCredentialMigrationKey, accountId);
      try {
        await _tmdbCredentialStore.migrateGuestToAccount(accountId);
        await _settings.delete(_pendingTmdbCredentialMigrationKey);
      } catch (_) {
        // Registration remains usable; startup retries the durable marker.
      }
      for (final key in _accountSettingKeys) {
        if (key == 'profile') continue;
        final value = _settings.get(key);
        final target = settingsKeyFor(accountId, key);
        if (value != null && !_settings.containsKey(target)) {
          await _settings.put(target, value);
        }
      }
      for (final key in _accountLibraryKeys) {
        final value = _library.get(key);
        final target = libraryKeyFor(accountId, key);
        if (value != null && !_library.containsKey(target)) {
          await _library.put(target, value);
        }
      }
      for (final key in _accountSettingKeys) {
        await _settings.delete(key);
      }
      for (final key in _accountLibraryKeys) {
        await _library.delete(key);
      }
    }
    await _localRepository.completeRegistration(accountId);
  }

  Future<void> _resumePendingBangumiCredentialMigration() async {
    final accountId = _settings
        .get(_pendingBangumiCredentialMigrationKey)
        ?.toString()
        .trim();
    if (accountId == null || accountId.isEmpty) return;
    if (_localRepository.pendingDeletion()?.accountId == accountId) return;
    final pendingRegistration = _localRepository.pendingRegistration();
    final accountExists = _localRepository.listCloudAccounts().any(
      (account) => account.id == accountId,
    );
    if (!accountExists && pendingRegistration?.account.id != accountId) {
      await _settings.delete(_pendingBangumiCredentialMigrationKey);
      return;
    }
    await _bangumiCredentialStore.migrateGuestToAccount(accountId);
    await _settings.delete(_pendingBangumiCredentialMigrationKey);
  }

  Future<void> _resumePendingTmdbCredentialMigration() async {
    final accountId = _settings
        .get(_pendingTmdbCredentialMigrationKey)
        ?.toString()
        .trim();
    if (accountId == null || accountId.isEmpty) return;
    if (_localRepository.pendingDeletion()?.accountId == accountId) return;
    final pendingRegistration = _localRepository.pendingRegistration();
    final accountExists = _localRepository.listCloudAccounts().any(
      (account) => account.id == accountId,
    );
    if (!accountExists && pendingRegistration?.account.id != accountId) {
      await _settings.delete(_pendingTmdbCredentialMigrationKey);
      return;
    }
    await _tmdbCredentialStore.migrateGuestToAccount(accountId);
    await _settings.delete(_pendingTmdbCredentialMigrationKey);
  }

  Future<void> _resumePendingDeletion(
    PendingLocalAccountDeletion pending,
  ) async {
    Object? firstError;

    Future<void> attempt(Future<void> Function() action) async {
      try {
        await action();
      } catch (error) {
        firstError ??= error;
      }
    }

    for (final taskId in pending.taskIds) {
      _cancelDownload(pending.accountId, taskId);
    }
    await attempt(
      () => _localRepository.deleteAccountRecord(pending.accountId),
    );
    for (final path in pending.paths) {
      await attempt(() => _deleteDownloadFile(path));
    }
    for (final key in _accountSettingKeys) {
      await attempt(
        () => _settings.delete(settingsKeyFor(pending.accountId, key)),
      );
    }
    for (final key in _accountLibraryKeys) {
      await attempt(
        () => _library.delete(libraryKeyFor(pending.accountId, key)),
      );
    }
    await attempt(
      () => _bangumiCredentialStore.clearAccount(pending.accountId),
    );
    await attempt(() => _tmdbCredentialStore.clearAccount(pending.accountId));
    if (_settings.get(_pendingBangumiCredentialMigrationKey)?.toString() ==
        pending.accountId) {
      await attempt(
        () => _settings.delete(_pendingBangumiCredentialMigrationKey),
      );
    }
    if (_settings.get(_pendingTmdbCredentialMigrationKey)?.toString() ==
        pending.accountId) {
      await attempt(() => _settings.delete(_pendingTmdbCredentialMigrationKey));
    }
    if (firstError == null) {
      await _localRepository.completeDeletion(pending.accountId);
      return;
    }
    throw const AccountException('账号已退出，但部分本机文件仍在清理；下次启动会自动继续');
  }

  Future<T> _runOperation<T>(Future<T> Function() action) {
    final operation = _operationQueue.then((_) => action());
    _operationQueue = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  void _requireInitialized() {
    if (!_initialized) throw const AccountException('应用状态尚未准备好');
  }
}
