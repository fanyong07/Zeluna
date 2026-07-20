import 'dart:async';
import 'dart:io';

import 'package:anime/src/accounts/local_account_repository.dart';
import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/data/media_download_backend.dart';
import 'package:anime/src/data/media_download_result.dart';
import 'package:anime/src/data/media_download_service.dart';
import 'package:anime/src/data/media_download_task.dart';
import 'package:anime/src/data/peertube_repository.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/sources/source_catalog_models.dart';
import 'package:anime/src/sources/source_catalog_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

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
      );
      state = container.read(animeControllerProvider).requireValue;
      expect(state.accountSession.current?.email, 'first@example.com');
      expect(state.profile.nickname, '第一位用户');
      expect(state.favorites.single.subject.title, _subject.title);
      expect(state.offlineTasks.single.id, 'guest-download');
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
        state.rulePlugins.customRules.single.rawConfig['Cookie'],
        'session=private',
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
        migratedLibrary.containsKey('account.$firstAccountId.offlineTasks'),
        isTrue,
      );

      await controller.registerAccount(
        email: 'second@example.com',
        nickname: '第二位用户',
        password: 'second-password',
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
      expect(state.danmaku.enabled, isTrue);
      expect(state.misc.keepScreenOn, isTrue);
      expect(state.services.bangumiEnabled, isTrue);
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
      expect(state.offlineTasks.single.id, 'guest-download');
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
        state.rulePlugins.customRules.single.rawConfig['Cookie'],
        'session=private',
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
      await controller.deleteCurrentAccount(password: 'second-password');
      state = container.read(animeControllerProvider).requireValue;
      expect(state.accountSession.current, isNull);
      expect(state.accountSession.available, hasLength(1));
      expect(
        migratedLibrary.containsKey('account.$secondAccountId.favorites'),
        isFalse,
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
      final pending = await LocalAccountRepository(accounts).beginRegistration(
        email: 'recover@example.com',
        nickname: '恢复用户',
        password: 'recover-password',
        importGuestData: true,
      );
      await LocalAccountRepository(accounts).completeRegistration(pending.id);
      expect(LocalAccountRepository(accounts).currentAccount(), isNull);
      expect(
        LocalAccountRepository(accounts).pendingRegistration()?.account.id,
        pending.id,
      );
      await settings.close();
      await library.close();
      await accounts.close();

      final container = ProviderContainer(
        overrides: [
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
      expect(state.accountSession.current?.id, pending.id);
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

  test('wrong account password does not interrupt active downloads', () async {
    final root = await Directory.systemTemp.createTemp(
      'anime-controller-account-auth-side-effects-',
    );
    Hive.init(root.path);
    final settings = await Hive.openBox<dynamic>('anime.settings.v2');
    await settings.put('services', _downloadServices.toJson());
    await settings.close();

    final backend = _BlockingDownloadBackend();
    final service = MediaDownloadService(backend: backend);
    final container = ProviderContainer(
      overrides: [
        mediaDownloadServiceProvider.overrideWithValue(service),
        peerTubeRepositoryProvider.overrideWithValue(
          _SingleLinePeerTubeRepository(),
        ),
        sourceCatalogRepositoryProvider.overrideWithValue(
          const _EmptySourceCatalogRepository(),
        ),
      ],
    );
    addTearDown(() async {
      if (!backend.release.isCompleted) backend.release.complete();
      await backend.finished.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () {},
      );
      container.dispose();
      service.dispose();
      await Hive.close();
      if (await root.exists()) await root.delete(recursive: true);
    });

    await container.read(animeControllerProvider.future);
    final controller = container.read(animeControllerProvider.notifier);
    await controller.registerAccount(
      email: 'downloader@example.com',
      nickname: '下载用户',
      password: 'download-password',
    );
    await controller.registerAccount(
      email: 'other@example.com',
      nickname: '其他用户',
      password: 'other-password',
    );
    await controller.loginAccount(
      email: 'downloader@example.com',
      password: 'download-password',
    );

    await controller.queueOffline(_downloadSubject, _downloadEpisode);
    await backend.started.future;
    var state = container.read(animeControllerProvider).requireValue;
    final taskId = state.offlineTasks.single.id;
    expect(
      state.offlineTasks.single.status,
      MediaDownloadTaskStatus.downloading,
    );
    expect(service.isActive(taskId), isTrue);

    await expectLater(
      controller.loginAccount(
        email: 'other@example.com',
        password: 'wrong-password',
      ),
      throwsA(isA<AccountException>()),
    );
    state = container.read(animeControllerProvider).requireValue;
    expect(state.accountSession.current?.email, 'downloader@example.com');
    expect(
      state.offlineTasks.single.status,
      MediaDownloadTaskStatus.downloading,
    );
    expect(service.isActive(taskId), isTrue);

    await expectLater(
      controller.deleteCurrentAccount(password: 'wrong-password'),
      throwsA(isA<AccountException>()),
    );
    state = container.read(animeControllerProvider).requireValue;
    expect(state.accountSession.current?.email, 'downloader@example.com');
    expect(
      state.offlineTasks.single.status,
      MediaDownloadTaskStatus.downloading,
    );
    expect(service.isActive(taskId), isTrue);

    await controller.pauseDownload(taskId);
  });

  test('playback results from the previous account are discarded', () async {
    final root = await Directory.systemTemp.createTemp(
      'anime-controller-account-stale-playback-',
    );
    Hive.init(root.path);
    final settings = await Hive.openBox<dynamic>('anime.settings.v2');
    await settings.put('services', _downloadServices.toJson());
    await settings.close();

    final repository = _BlockingLinePeerTubeRepository();
    final container = ProviderContainer(
      overrides: [
        peerTubeRepositoryProvider.overrideWithValue(repository),
        sourceCatalogRepositoryProvider.overrideWithValue(
          const _EmptySourceCatalogRepository(),
        ),
      ],
    );
    addTearDown(() async {
      if (!repository.lines.isCompleted) {
        repository.lines.complete(const <PlaybackLine>[]);
      }
      container.dispose();
      await Hive.close();
      if (await root.exists()) await root.delete(recursive: true);
    });

    await container.read(animeControllerProvider.future);
    final controller = container.read(animeControllerProvider.notifier);
    await controller.registerAccount(
      email: 'playback-a@example.com',
      nickname: '线路用户甲',
      password: 'playback-password-a',
    );
    await controller.registerAccount(
      email: 'playback-b@example.com',
      nickname: '线路用户乙',
      password: 'playback-password-b',
    );
    await controller.loginAccount(
      email: 'playback-a@example.com',
      password: 'playback-password-a',
    );

    final accountAContext = controller.accountContextVersion;
    final staleResult = controller.linesForEpisode(
      _downloadSubject,
      _downloadEpisode,
    );
    await repository.requested.future;
    await controller.loginAccount(
      email: 'playback-b@example.com',
      password: 'playback-password-b',
    );
    repository.lines.complete(const [
      PlaybackLine(
        id: 'private-line',
        episodeId: 303,
        providerId: 'private',
        providerName: 'Private source',
        title: 'Private line',
        quality: '1080p',
        format: 'MP4',
        url: 'https://private.example/video.mp4',
        headers: {'Cookie': 'session=account-a'},
        available: true,
      ),
    ]);

    expect(await staleResult, isEmpty);
    expect(
      await controller.addHistory(
        _downloadSubject,
        _downloadEpisode,
        expectedAccountContextVersion: accountAContext,
      ),
      isFalse,
    );
    expect(
      container.read(animeControllerProvider).requireValue.history,
      isEmpty,
    );
    expect(
      container
          .read(animeControllerProvider)
          .requireValue
          .accountSession
          .current
          ?.email,
      'playback-b@example.com',
    );
  });

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
}

class _EmptySourceCatalogRepository extends SourceCatalogRepository {
  const _EmptySourceCatalogRepository();

  @override
  Future<SourceCatalogState> loadCatalog({
    Map<String, bool> enabledOverrides = const {},
  }) async => const SourceCatalogState();
}

class _SingleLinePeerTubeRepository extends PeerTubeRepository {
  @override
  Future<List<AnimeSubject>> trending({int page = 1, int limit = 24}) async =>
      const [];

  @override
  Future<List<PlaybackLine>> linesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode,
  ) async => const [
    PlaybackLine(
      id: 'account-test-line',
      episodeId: 303,
      providerId: 'account-test',
      providerName: 'Account test',
      title: 'MP4',
      quality: '720p',
      format: 'MP4',
      url: 'https://cdn.example/account-test.mp4',
      available: true,
    ),
  ];
}

class _BlockingLinePeerTubeRepository extends PeerTubeRepository {
  final requested = Completer<void>();
  final lines = Completer<List<PlaybackLine>>();

  @override
  Future<List<AnimeSubject>> trending({int page = 1, int limit = 24}) async =>
      const [];

  @override
  Future<List<PlaybackLine>> linesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode,
  ) {
    if (!requested.isCompleted) requested.complete();
    return lines.future;
  }
}

class _BlockingDownloadBackend implements MediaDownloadBackend {
  final started = Completer<void>();
  final release = Completer<void>();
  final finished = Completer<void>();

  @override
  Future<MediaDownloadResult> download({
    required MediaDownloadRequest request,
    required MediaDownloadControl control,
    required void Function(MediaDownloadProgress progress) onProgress,
  }) async {
    if (!started.isCompleted) started.complete();
    try {
      await Future.any([release.future, control.whenStopped]);
      return MediaDownloadResult(
        outcome: control.reason == MediaDownloadStopReason.pause
            ? MediaDownloadOutcome.paused
            : MediaDownloadOutcome.cancelled,
        message: '测试下载已停止',
      );
    } finally {
      if (!finished.isCompleted) finished.complete();
    }
  }

  @override
  Future<void> deleteFile(String path) async {}

  @override
  Future<bool> fileExists(String path) async => false;
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

const _downloadServices = ExternalServiceSettings(
  mediaMetadataEnabled: false,
  cinemetaEnabled: false,
  peerTubeEnabled: true,
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

const _downloadSubject = AnimeSubject(
  id: 303,
  title: '下载中的动画',
  originalTitle: 'Downloading Anime',
  summary: '用于验证错误密码不会暂停下载',
  coverUrl: null,
  bannerUrl: null,
  date: '2026-01-01',
  platform: '测试',
  language: '中文',
  region: '中国',
  status: '连载',
  categories: [],
  tags: [],
  totalEpisodes: 1,
  source: 'peertube:test',
);

const _downloadEpisode = AnimeEpisode(
  id: 303,
  subjectId: 303,
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
