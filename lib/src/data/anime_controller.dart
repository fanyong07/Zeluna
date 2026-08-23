import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:wakelock_plus/wakelock_plus.dart';

import '../accounts/account_controller.dart';
import '../accounts/local_account_repository.dart';
import '../catalog/catalog_controller.dart';
import '../accounts/cloud_account_repository.dart';
import '../core/identity/local_identity_migration.dart';
import '../core/network/network_http_client.dart';
import '../core/network/network_security.dart';
import '../domain/anime_models.dart';
import '../domain/subject_content_type.dart';
import '../downloads/download_controller.dart';
import '../library/library_controller.dart';
import '../playback/playback_discovery_controller.dart';
import '../recommendations/recommendations.dart';
import '../rules/drpy_runtime.dart';
import '../rules/rule_models.dart';
import '../rules/rule_playback_resolver.dart';
import '../rules/rule_plugin_repository.dart';
import '../rules/tvbox_xbpq_hydrator.dart';
import '../sources/external_source_adapters.dart';
import '../sources/source_catalog_models.dart';
import '../sources/source_catalog_repository.dart';
import '../sources/source_controller.dart';
import '../sources/source_rule_bridge.dart';
import '../settings/settings_controller.dart';
import '../sync/cloud_sync_transport.dart';
import '../sync/sync_controller.dart';
import 'bangumi_credential_store.dart';
import 'bangumi_metadata_repository.dart';
import 'chinese_metadata_repository.dart';
import 'danmaku_repository.dart';
import 'danmaku_cloud_controller.dart';
import 'external_service_repository.dart';
import 'media_download_service.dart';
import 'media_download_task.dart';
import 'playback_line_memory_store.dart';
import 'playback_prefetch_cache.dart';
import 'playback_source_repository.dart';
import 'search_history_store.dart';
import 'tmdb_credential_store.dart';
import 'zeluna_backend_catalog_repository.dart';
import 'zeluna_backend_playback_repository.dart';

export '../sources/source_controller.dart' show RuleRepositoryRefreshResult;
export '../playback/playback_discovery_controller.dart'
    show
        probePlaybackLinesProgressively,
        probeSinglePlaybackBackupSequentially,
        rankPlaybackLinesForStartup;

class _CredentialAccountContext {
  String? _accountId;
  int _revision = 0;

  ({String? accountId, int revision}) get snapshot =>
      (accountId: _accountId, revision: _revision);

  void selectAccount(String? accountId) {
    if (_accountId == accountId) return;
    _accountId = accountId;
    _revision++;
  }

  bool isCurrent(({String? accountId, int revision}) value) =>
      value.accountId == _accountId && value.revision == _revision;
}

final _bangumiCredentialAccountContextProvider =
    Provider<_CredentialAccountContext>((ref) => _CredentialAccountContext());

final _tmdbCredentialAccountContextProvider =
    Provider<_CredentialAccountContext>((ref) => _CredentialAccountContext());

final bangumiCredentialStoreProvider = Provider<BangumiCredentialStore>(
  (ref) => BangumiCredentialStore(),
);

final bangumiBuiltInAccessTokenProvider = Provider<String?>((ref) {
  return _normalizeBangumiAccessToken(
    const String.fromEnvironment('BANGUMI_ACCESS_TOKEN'),
  );
});

final bangumiMetadataHttpClientProvider = Provider<http.Client>((ref) {
  final client = createNetworkHttpClient(
    NetworkRequestPolicy.forService(NetworkServiceKind.metadataApi),
  );
  ref.onDispose(client.close);
  return client;
});

final tmdbCredentialStoreProvider = Provider<TmdbCredentialStore>(
  (ref) => TmdbCredentialStore(),
);

final tmdbBuiltInAccessTokenProvider = Provider<String?>((ref) {
  return _normalizeTmdbAccessToken(
    const String.fromEnvironment('TMDB_READ_ACCESS_TOKEN'),
  );
});

String? _normalizeTmdbAccessToken(String? value) {
  final token = value?.trim() ?? '';
  if (token.length < 32 ||
      token.length > 2048 ||
      RegExp(r'[\r\n\s]').hasMatch(token)) {
    return null;
  }
  return token;
}

String? _normalizeBangumiAccessToken(String? value) {
  final token = value?.trim() ?? '';
  if (token.length < 16 ||
      token.length > 512 ||
      RegExp(r'\s').hasMatch(token)) {
    return null;
  }
  return token;
}

final bangumiMetadataRepositoryProvider = Provider<BangumiMetadataRepository>((
  ref,
) {
  final client = ref.read(bangumiMetadataHttpClientProvider);
  final credentials = ref.read(bangumiCredentialStoreProvider);
  final accountContext = ref.read(_bangumiCredentialAccountContextProvider);
  final builtInToken = _normalizeBangumiAccessToken(
    ref.read(bangumiBuiltInAccessTokenProvider),
  );
  final repository = BangumiMetadataRepository(
    client: client,
    accessCredentialProvider: () async {
      if (builtInToken != null) {
        return BangumiAccessCredential(token: builtInToken);
      }
      final snapshot = accountContext.snapshot;
      final token = await credentials.readAccessToken(
        accountId: snapshot.accountId,
      );
      if (token == null || !accountContext.isCurrent(snapshot)) return null;
      return BangumiAccessCredential(
        token: token,
        accountId: snapshot.accountId,
      );
    },
    onAccessTokenRejected: (credential) {
      // A build-time credential is application configuration, not account
      // data. Its rejection must never mutate an account's secure storage.
      if (builtInToken != null) return Future<void>.value();
      return credentials.markRejectedToken(
        accountId: credential.accountId,
        rejectedToken: credential.token,
      );
    },
  );
  ref.onDispose(repository.close);
  return repository;
});

final playbackSourceRepositoryProvider = Provider<PlaybackSourceRepository>(
  (ref) => const EmptyPlaybackSourceRepository(),
);

final rulePlaybackResolverProvider = Provider<RulePlaybackResolver>((ref) {
  final client = createTrustedMediaProbeHttpClient();
  final rulePublicClient = createUntrustedSourceHttpClient();
  final drpyPublicClient = createDrpyPublicHttpClient();
  ref.onDispose(client.close);
  ref.onDispose(rulePublicClient.close);
  ref.onDispose(drpyPublicClient.close);
  return RulePlaybackResolver(
    client: client,
    rulePublicClient: rulePublicClient,
    drpyPublicClient: drpyPublicClient,
  );
});

final zelunaBackendHttpClientProvider = Provider<http.Client>((ref) {
  final client = createNetworkHttpClient(
    NetworkRequestPolicy.forService(NetworkServiceKind.officialPlaybackBackend),
  );
  ref.onDispose(client.close);
  return client;
});

final selfHostedBackendHttpClientProvider = Provider.family<http.Client, bool>((
  ref,
  allowInsecure,
) {
  final client = createNetworkHttpClient(
    NetworkRequestPolicy.forService(
      NetworkServiceKind.selfHostedPlaybackBackend,
      allowInsecureSelfHosted: allowInsecure,
    ),
  );
  ref.onDispose(client.close);
  return client;
});

final cloudAccountTokenStoreProvider = Provider<CloudAccountTokenStore>(
  (ref) => SecureCloudAccountTokenStore(),
);

final cloudAccountRepositoryProvider = Provider<CloudAccountRepository>((ref) {
  final repository = CloudAccountRepository(
    tokenStore: ref.read(cloudAccountTokenStoreProvider),
  );
  ref.onDispose(repository.close);
  return repository;
});

final cloudAccountServiceProvider = Provider<CloudAccountService>(
  (ref) => ref.read(cloudAccountRepositoryProvider),
);

final cloudDanmakuServiceProvider = Provider<CloudDanmakuService>(
  (ref) => ref.read(cloudAccountRepositoryProvider),
);

final externalServiceHttpClientProvider = Provider<http.Client>((ref) {
  final client = createNetworkHttpClient(
    NetworkRequestPolicy.forService(NetworkServiceKind.metadataApi),
  );
  ref.onDispose(client.close);
  return client;
});

final externalServiceRepositoryProvider = Provider<ExternalServiceRepository>((
  ref,
) {
  final client = ref.read(externalServiceHttpClientProvider);
  final credentials = ref.read(tmdbCredentialStoreProvider);
  final accountContext = ref.read(_tmdbCredentialAccountContextProvider);
  final builtInToken = _normalizeTmdbAccessToken(
    ref.read(tmdbBuiltInAccessTokenProvider),
  );
  return ExternalServiceRepository(
    client: client,
    tmdbAccessTokenProvider: () async {
      if (builtInToken != null) return builtInToken;
      final snapshot = accountContext.snapshot;
      final token = await credentials.readAccessToken(
        accountId: snapshot.accountId,
      );
      return token != null && accountContext.isCurrent(snapshot) ? token : null;
    },
    onTmdbAccessTokenRejected: (rejectedToken) {
      // A build-time credential is application configuration, not account
      // data. Its rejection must never mutate an account's secure storage.
      if (builtInToken != null) return Future<void>.value();
      final snapshot = accountContext.snapshot;
      return credentials.markRejectedToken(
        accountId: snapshot.accountId,
        rejectedToken: rejectedToken,
      );
    },
  );
});

final danmakuRepositoryProvider = Provider<DanmakuRepository>((ref) {
  final tokenStore = ref.read(cloudAccountTokenStoreProvider);
  final repository = DanmakuRepository(officialTokenProvider: tokenStore.read);
  ref.onDispose(repository.close);
  return repository;
});

final chineseMetadataRepositoryProvider = Provider<ChineseMetadataRepository>(
  (ref) => ChineseMetadataRepository(
    bangumiRepository: ref.read(bangumiMetadataRepositoryProvider),
  ),
);

final sourceCatalogRepositoryProvider = Provider<SourceCatalogRepository>(
  (ref) => const SourceCatalogRepository(),
);

final m3uSourceAdapterProvider = Provider<M3uSourceAdapter>((ref) {
  final adapter = M3uSourceAdapter();
  ref.onDispose(adapter.close);
  return adapter;
});

final torrentSourceAdapterProvider = Provider<DmhySourceAdapter>((ref) {
  final adapter = DmhySourceAdapter();
  ref.onDispose(adapter.close);
  return adapter;
});

final sourceRuleBridgeProvider = Provider<SourceRuleBridge>((ref) {
  final hydrator = TvBoxXbpqHydrator();
  ref.onDispose(hydrator.close);
  return SourceRuleBridge(xbpqHydrator: hydrator);
});

final mediaDownloadServiceProvider = Provider<MediaDownloadService>((ref) {
  final service = MediaDownloadService();
  ref.onDispose(service.dispose);
  return service;
});

final animeControllerProvider =
    AsyncNotifierProvider<AnimeController, AnimeState>(AnimeController.new);

class AnimeState {
  const AnimeState({
    required this.homeFeed,
    this.settings = const PlaybackSettings(),
    this.selectedSubjects = const {},
    this.favorites = const [],
    this.history = const [],
    this.following = const [],
    this.offlineTasks = const [],
    this.imageFavorites = const [],
    this.feedbacks = const [],
    this.profile = const UserProfileSettings(),
    this.accountSession = const LocalAccountSession(),
    this.homePreferences = const HomePreferences(),
    this.appearance = const AppearanceSettings(),
    this.danmaku = const DanmakuSettings(),
    this.misc = const MiscSettings(),
    this.services = const ExternalServiceSettings(),
    this.rulePlugins = const RulePluginState(),
    this.sourceCatalog = const SourceCatalogState(),
    this.syncStatus = const SyncStatus.localOnly(),
  });

  final AnimeHomeFeed homeFeed;
  final PlaybackSettings settings;
  final Map<int, AnimeDetailBundle> selectedSubjects;
  final List<LibraryEntry> favorites;
  final List<LibraryEntry> history;
  final List<LibraryEntry> following;
  final List<MediaDownloadTask> offlineTasks;
  final List<LibraryEntry> imageFavorites;
  final List<LocalFeedback> feedbacks;
  final UserProfileSettings profile;
  final LocalAccountSession accountSession;
  final HomePreferences homePreferences;
  final AppearanceSettings appearance;
  final DanmakuSettings danmaku;
  final MiscSettings misc;
  final ExternalServiceSettings services;
  final RulePluginState rulePlugins;
  final SourceCatalogState sourceCatalog;
  final SyncStatus syncStatus;

  AnimeState copyWith({
    AnimeHomeFeed? homeFeed,
    PlaybackSettings? settings,
    Map<int, AnimeDetailBundle>? selectedSubjects,
    List<LibraryEntry>? favorites,
    List<LibraryEntry>? history,
    List<LibraryEntry>? following,
    List<MediaDownloadTask>? offlineTasks,
    List<LibraryEntry>? imageFavorites,
    List<LocalFeedback>? feedbacks,
    UserProfileSettings? profile,
    LocalAccountSession? accountSession,
    HomePreferences? homePreferences,
    AppearanceSettings? appearance,
    DanmakuSettings? danmaku,
    MiscSettings? misc,
    ExternalServiceSettings? services,
    RulePluginState? rulePlugins,
    SourceCatalogState? sourceCatalog,
    SyncStatus? syncStatus,
  }) {
    return AnimeState(
      homeFeed: homeFeed ?? this.homeFeed,
      settings: settings ?? this.settings,
      selectedSubjects: selectedSubjects ?? this.selectedSubjects,
      favorites: favorites ?? this.favorites,
      history: history ?? this.history,
      following: following ?? this.following,
      offlineTasks: offlineTasks ?? this.offlineTasks,
      imageFavorites: imageFavorites ?? this.imageFavorites,
      feedbacks: feedbacks ?? this.feedbacks,
      profile: profile ?? this.profile,
      accountSession: accountSession ?? this.accountSession,
      homePreferences: homePreferences ?? this.homePreferences,
      appearance: appearance ?? this.appearance,
      danmaku: danmaku ?? this.danmaku,
      misc: misc ?? this.misc,
      services: services ?? this.services,
      rulePlugins: rulePlugins ?? this.rulePlugins,
      sourceCatalog: sourceCatalog ?? this.sourceCatalog,
      syncStatus: syncStatus ?? this.syncStatus,
    );
  }
}

class AnimeController extends AsyncNotifier<AnimeState> {
  static const _settingsBox = 'anime.settings.v2';
  static const _libraryBox = 'anime.library.v2';
  late Box<dynamic> _settings;
  late Box<dynamic> _library;
  late PlaybackLineMemoryStore _playbackLineMemory;
  AccountController? _accountController;
  SettingsController? _settingsController;
  SourceController? _sourceController;
  DownloadController? _downloadController;
  LibraryController? _libraryController;
  CatalogController? _catalogController;
  RecommendationController? _recommendationController;
  PlaybackDiscoveryController? _playbackDiscoveryController;
  SyncController? _syncController;
  var _recommendationNonce = 0;
  String? _lastServedRecommendationFingerprint;

  AccountController get _accounts {
    final controller = _accountController;
    if (controller == null) throw const AccountException('应用状态尚未准备好');
    return controller;
  }

  SettingsController get _settingsDomain {
    final controller = _settingsController;
    if (controller == null) throw StateError('应用设置尚未准备好');
    return controller;
  }

  SourceController get _sourceDomain {
    final controller = _sourceController;
    if (controller == null) throw StateError('线路与规则尚未准备好');
    return controller;
  }

  DownloadController get _downloadDomain {
    final controller = _downloadController;
    if (controller == null) throw StateError('下载管理尚未准备好');
    return controller;
  }

  LibraryController get _libraryDomain {
    final controller = _libraryController;
    if (controller == null) throw StateError('媒体库尚未准备好');
    return controller;
  }

  CatalogController get _catalogDomain {
    final controller = _catalogController;
    if (controller == null) throw StateError('内容目录尚未准备好');
    return controller;
  }

  RecommendationController get _recommendationDomain {
    final controller = _recommendationController;
    if (controller == null) {
      throw StateError('推荐控制器尚未准备好');
    }
    return controller;
  }

  PlaybackDiscoveryController get _playbackDiscoveryDomain {
    final controller = _playbackDiscoveryController;
    if (controller == null) {
      throw StateError('播放发现尚未准备好');
    }
    return controller;
  }

  SyncController get _syncDomain {
    final controller = _syncController;
    if (controller == null) throw StateError('同步控制器尚未准备好');
    return controller;
  }

  LocalAccount? get _activeAccount => _accountController?.activeAccount;
  int get _accountContextVersion => _accountController?.contextVersion ?? 0;
  int get accountContextVersion => _accountController?.contextVersion ?? 0;

  bool isAccountContextCurrent(int version) =>
      _accountController?.isContextCurrent(version) ?? version == 0;

  @override
  Future<AnimeState> build() async {
    final boxes = await Future.wait<Box<dynamic>>([
      Hive.openBox<dynamic>(_settingsBox),
      Hive.openBox<dynamic>(_libraryBox),
      Hive.openBox<dynamic>(LocalAccountRepository.boxName),
    ]);
    _settings = boxes[0];
    _library = boxes[1];
    _playbackLineMemory = PlaybackLineMemoryStore(_settings);
    _recommendationController = RecommendationController(
      store: _HiveRecommendationEventStore(_library),
    );
    await LocalIdentityMigration(settings: _settings, library: _library).run();
    final cloudService = ref.read(cloudAccountServiceProvider);
    final CloudSyncTransport? cloudTransport =
        cloudService is CloudSyncTransport
        ? cloudService as CloudSyncTransport
        : null;
    _accountController = AccountController(
      cloudService: cloudService,
      localRepository: LocalAccountRepository(boxes[2]),
      settings: _settings,
      library: _library,
      bangumiCredentialStore: ref.read(bangumiCredentialStoreProvider),
      tmdbCredentialStore: ref.read(tmdbCredentialStoreProvider),
      activateScope: _applyAccountScope,
      quiesceDownloads: _quiesceDownloadsForAccountChange,
      readOwnedDownloads: _readAccountOwnedDownloads,
      cancelDownload: (accountId, taskId) {
        final controller = _downloadController;
        if (controller == null) {
          ref.read(mediaDownloadServiceProvider).cancel(taskId);
          return;
        }
        controller.cancelOwnedDownload(accountId, taskId);
      },
      deleteDownloadFile: (path) =>
          ref.read(mediaDownloadServiceProvider).deleteFiles([path]),
      selectCredentialContext: _selectCredentialAccountContext,
      publishSession: _publishAccountSession,
      publishProfile: _publishAccountProfile,
      searchHistoryStore: ref.read(searchHistoryStoreProvider),
    );
    final accountBootstrap = await _accounts.initialize();
    final activeAccount = accountBootstrap.activeAccount;
    final accountSession = accountBootstrap.session;
    await _recommendationDomain.loadForAccount(
      accountId: activeAccount?.id,
      contextVersion: _accounts.contextVersion,
    );
    _settingsController = SettingsController(
      storage: HiveSettingsStorage(_settings),
      publishSnapshot: _publishSettingsSnapshot,
      applyKeepScreenOn: (enabled) async {
        await WakelockPlus.toggle(enable: enabled).onError((_, _) {});
      },
      onExternalServicesChanged: _handleExternalServicesChanged,
      syncPlayback: (accountId, contextVersion, settings) =>
          _syncController?.enqueuePlaybackSettings(
            accountId: accountId,
            contextVersion: contextVersion,
            settings: settings,
          ) ??
          Future<bool>.value(false),
      syncAppearance: (accountId, contextVersion, settings) =>
          _syncController?.enqueueAppearance(
            accountId: accountId,
            contextVersion: contextVersion,
            settings: settings,
          ) ??
          Future<bool>.value(false),
    );
    final settingsSnapshot = _settingsDomain.loadForAccount(
      accountId: activeAccount?.id,
      contextVersion: _accounts.contextVersion,
    );
    _playbackLineMemory.loadForAccount(
      accountId: activeAccount?.id,
      contextVersion: _accounts.contextVersion,
    );
    if (!settingsSnapshot.playback.rememberLine) {
      await _playbackLineMemory.clearForCurrentAccount(
        expectedContextVersion: _accounts.contextVersion,
      );
    }
    final services = settingsSnapshot.services;
    final profileJson = _settings.get(_accountSettingsKey('profile'));
    _sourceController = SourceController(
      storage: HiveSourceStorage(_settings),
      catalogRepository: ref.read(sourceCatalogRepositoryProvider),
      sourceRuleBridge: ref.read(sourceRuleBridgeProvider),
      publishSnapshot: _publishSourceSnapshot,
    );
    final sourceSnapshot = await _sourceDomain.loadForAccount(
      accountId: activeAccount?.id,
      contextVersion: _accounts.contextVersion,
    );
    _downloadController = DownloadController(
      storage: HiveDownloadStorage(_library),
      service: ref.read(mediaDownloadServiceProvider),
      resolveLines: (subject, episode) =>
          linesForEpisodeMode(subject, episode, expandAll: true),
      publishSnapshot: _publishDownloadSnapshot,
    );
    final downloadSnapshot = await _downloadDomain.loadForAccount(
      accountId: activeAccount?.id,
      contextVersion: _accounts.contextVersion,
    );
    _libraryController = LibraryController(
      storage: HiveLibraryStorage(_library),
      publishSnapshot: _publishLibrarySnapshot,
      syncHistory: (context, subject, episode) async {
        await _syncDomain.syncHistory(
          accountId: context.accountId,
          contextVersion: context.contextVersion,
          subject: subject,
          episode: episode,
        );
      },
      writeCloudMutation: (context, type, entry, {required deleted}) =>
          _syncDomain.enqueueLibrary(
            accountId: context.accountId,
            contextVersion: context.contextVersion,
            type: type,
            entry: entry,
            deleted: deleted,
          ),
      writePlaybackMutation: (context, entry) =>
          _syncDomain.enqueuePlaybackPosition(
            accountId: context.accountId,
            contextVersion: context.contextVersion,
            entry: entry,
          ),
    );
    final librarySnapshot = await _libraryDomain.loadForAccount(
      accountId: activeAccount?.id,
      contextVersion: _accounts.contextVersion,
    );
    final syncRepository = ref.read(externalServiceRepositoryProvider);
    _syncController = SyncController(
      uploadHistory: syncRepository.syncLocalHistory,
      isContextCurrent: _accounts.isContextCurrent,
      cloudTransport: cloudTransport,
      storage: HiveSyncStorage(_settings),
      readLocalSnapshot: _readSyncLocalSnapshot,
      applyRecord: _applyCloudSyncRecord,
      publishStatus: _publishSyncStatus,
    );
    final playbackResolver = ref.read(rulePlaybackResolverProvider);
    _playbackDiscoveryController = PlaybackDiscoveryController(
      backendRepository: _backendPlaybackRepositoryFor,
      ruleRepository: _rulePlaybackRepositoryFor,
      verifyLine:
          (
            line, {
            enrichMetadata = true,
            forceRefresh = false,
            cancellationToken,
          }) => playbackResolver.verifyPlaybackLine(
            line: line,
            enrichMetadata: enrichMetadata,
            forceRefresh: forceRefresh,
            cancellationToken: cancellationToken,
          ),
      isContextCurrent: _accounts.isContextCurrent,
      clearRuleRuntimeCaches: () {
        RulePlaybackSourceRepository.clearRuntimeCaches();
        playbackResolver.clearCaches();
      },
    );
    _playbackDiscoveryDomain.loadForAccount(
      accountId: activeAccount?.id,
      contextVersion: _accounts.contextVersion,
      services: services,
      ruleState: sourceSnapshot.rulePlugins,
      history: librarySnapshot.history,
    );
    final bangumiRepository = ref.read(bangumiMetadataRepositoryProvider);
    _catalogController = CatalogController(
      storage: HiveCatalogStorage(_library),
      publishSnapshot: _publishCatalogSnapshot,
      search: (query, settings) async {
        final repository = _backendCatalogRepositoryFor(settings);
        return repository == null ? const [] : repository.search(query);
      },
      loadHome: (type, settings) async {
        final repository = _backendCatalogRepositoryFor(settings);
        return repository == null ? const [] : repository.home(type);
      },
      loadCandidates: (type, settings) async {
        final repository = _backendCatalogRepositoryFor(settings);
        return repository == null
            ? const <CatalogCandidate>[]
            : repository.homeCandidates(type);
      },
      loadDetail: (subject, settings) async {
        final repository = _backendCatalogRepositoryFor(settings);
        return await repository?.detail(subject) ?? _fallbackDetail(subject);
      },
      enrichDetail: (bundle, _) => _enrichSparseDetail(bundle),
      prefetchPlayback: (subject, episodes) {
        if (_settingsDomain.snapshot.playback.rememberLine) {
          _playbackDiscoveryDomain.prefetchPlayback(subject, episodes);
        }
      },
      fallbackSeries: _fallbackExternalSeries,
      fallbackMovies: _fallbackExternalMovies,
    );
    final catalogLoad = await _catalogDomain.loadForAccount(
      accountId: activeAccount?.id,
      contextVersion: _accounts.contextVersion,
      services: services,
      fallbackHomeFeed: bangumiRepository.fallbackHomeFeed(),
    );
    final feed = _composeRecommendedHomeFeed(
      catalogLoad.snapshot,
      librarySnapshot: librarySnapshot,
      preferences: settingsSnapshot.homePreferences,
    );
    unawaited(_settingsDomain.applyRuntimeEffects().onError((_, _) {}));
    final initialContextVersion = _accounts.contextVersion;
    final initialState = AnimeState(
      homeFeed: feed,
      settings: settingsSnapshot.playback,
      favorites: librarySnapshot.favorites,
      history: librarySnapshot.history,
      following: librarySnapshot.following,
      offlineTasks: downloadSnapshot.tasks,
      imageFavorites: librarySnapshot.imageFavorites,
      feedbacks: librarySnapshot.feedbacks,
      profile: AccountController.profileFromJson(profileJson, activeAccount),
      accountSession: accountSession,
      homePreferences: settingsSnapshot.homePreferences,
      appearance: settingsSnapshot.appearance,
      danmaku: settingsSnapshot.danmaku,
      misc: settingsSnapshot.misc,
      services: services,
      rulePlugins: sourceSnapshot.rulePlugins,
      sourceCatalog: sourceSnapshot.sourceCatalog,
      syncStatus: activeAccount != null && cloudTransport != null
          ? const SyncStatus(phase: SyncPhase.checking)
          : const SyncStatus.localOnly(),
    );
    var syncBootstrapCancelled = false;
    unawaited(
      Future<void>.delayed(Duration.zero, () {
        if (syncBootstrapCancelled ||
            !_accounts.isContextCurrent(initialContextVersion)) {
          return;
        }
        _syncDomain.loadForAccount(
          accountId: activeAccount?.id,
          contextVersion: initialContextVersion,
          services: services,
        );
      }),
    );
    if (!catalogLoad.homeFresh) {
      unawaited(
        Future<void>.delayed(
          Duration.zero,
          _catalogDomain.refreshHome,
        ).onError((_, _) {}),
      );
    }
    unawaited(
      Future<void>.delayed(
        Duration.zero,
        _recordCurrentHomeRecommendationsServed,
      ).onError((_, _) {}),
    );
    ref.onDispose(() {
      syncBootstrapCancelled = true;
      _downloadController?.dispose();
      _libraryController?.dispose();
      _catalogController?.dispose();
      _recommendationController?.dispose();
      _playbackDiscoveryController?.dispose();
      _syncController?.dispose();
    });
    return initialState;
  }

  Future<List<AnimeSubject>> search(String keyword) =>
      _catalogDomain.search(keyword);

  Future<SourceAdapterBatch<TorrentResource>> searchTorrentResources(
    String keyword,
  ) {
    final query = keyword.trim();
    if (query.isEmpty) {
      return Future.value(const SourceAdapterBatch<TorrentResource>());
    }
    final sourceCatalog =
        state.value?.sourceCatalog ?? const SourceCatalogState();
    return ref
        .read(torrentSourceAdapterProvider)
        .search(sources: sourceCatalog.sources, query: query, limit: 36);
  }

  Future<List<AnimeSubject>> categorySubjects(String name) =>
      _catalogDomain.categorySubjects(name);

  Future<List<AnimeSubject>> tagSubjects(String name) =>
      _catalogDomain.tagSubjects(name);

  Future<List<AnimeSubject>> discoverSubjects({
    bool waitForRefresh = false,
    CatalogSortMode sort = CatalogSortMode.recommended,
  }) => _catalogSubjects(
    SubjectContentType.anime,
    sort: sort,
    waitForRefresh: waitForRefresh,
  );

  Future<List<AnimeSubject>> seriesSubjects({
    bool waitForRefresh = false,
    CatalogSortMode sort = CatalogSortMode.recommended,
  }) => _catalogSubjects(
    SubjectContentType.series,
    sort: sort,
    waitForRefresh: waitForRefresh,
  );

  Future<List<AnimeSubject>> movieSubjects({
    bool waitForRefresh = false,
    CatalogSortMode sort = CatalogSortMode.recommended,
  }) => _catalogSubjects(
    SubjectContentType.movie,
    sort: sort,
    waitForRefresh: waitForRefresh,
  );

  Future<Map<int, List<AnimeSubject>>> weeklySchedule() =>
      _catalogDomain.weeklySchedule();

  /// The unified backend only ships subject + episodes today. Characters,
  /// staff, recommendations and tags come straight from the public metadata
  /// services; failures leave the base bundle untouched.
  Future<AnimeDetailBundle> _enrichSparseDetail(
    AnimeDetailBundle bundle,
  ) async {
    if (bundle.characters.isNotEmpty ||
        bundle.staff.isNotEmpty ||
        bundle.recommendations.isNotEmpty) {
      return bundle;
    }
    final subject = bundle.subject;
    try {
      AnimeDetailBundle? rich;
      if (subject.source == 'bangumi' && subject.id > 0) {
        rich = await ref
            .read(bangumiMetadataRepositoryProvider)
            .detail(subject.id, fallbackSubject: subject)
            .timeout(const Duration(seconds: 14));
      } else if (subject.source.startsWith('tmdb')) {
        rich = await ref
            .read(externalServiceRepositoryProvider)
            .tmdbDetail(subject)
            .timeout(const Duration(seconds: 14));
      }
      if (rich == null) return bundle;
      final baseSummary = subject.summary.trim();
      final richSummary = rich.subject.summary.trim();
      return AnimeDetailBundle(
        subject: subject.copyWith(
          summary:
              (baseSummary.isEmpty || baseSummary.startsWith('暂无')) &&
                  richSummary.isNotEmpty
              ? richSummary
              : subject.summary,
          categories: subject.categories.isEmpty
              ? rich.subject.categories
              : subject.categories,
          tags: subject.tags.isEmpty ? rich.subject.tags : subject.tags,
        ),
        episodes: bundle.episodes.isNotEmpty ? bundle.episodes : rich.episodes,
        characters: rich.characters,
        staff: rich.staff,
        recommendations: rich.recommendations,
        watchLinks: bundle.watchLinks.isNotEmpty
            ? bundle.watchLinks
            : rich.watchLinks,
      );
    } on Exception {
      return bundle;
    }
  }

  Future<AnimeDetailBundle> detail(AnimeSubject subject) =>
      _catalogDomain.detail(subject);

  Future<List<PlaybackLine>> linesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    RulePlaybackCancellationToken? cancellationToken,
  }) => _playbackDiscoveryDomain.linesForEpisode(
    subject,
    episode,
    cancellationToken: cancellationToken,
  );

  Future<PlaybackLine> verifyPlaybackLine(
    PlaybackLine line, {
    bool enrichMetadata = true,
    bool forceRefresh = false,
    RulePlaybackCancellationToken? cancellationToken,
  }) => _playbackDiscoveryDomain.verifyPlaybackLine(
    line,
    enrichMetadata: enrichMetadata,
    forceRefresh: forceRefresh,
    cancellationToken: cancellationToken,
  );

  Future<List<PlaybackLine>> linesForEpisodeMode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    bool expandAll = false,
    RulePlaybackCancellationToken? cancellationToken,
  }) => _playbackDiscoveryDomain.linesForEpisodeMode(
    subject,
    episode,
    expandAll: expandAll,
    cancellationToken: cancellationToken,
  );

  PlaybackLine? prefetchedLineForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    String? preferredProviderId,
    Duration minValidity = const Duration(seconds: 60),
  }) {
    final rememberLine = state.value?.settings.rememberLine ?? true;
    if (!rememberLine) return null;
    final preferred =
        preferredProviderId ??
        (rememberLine
            ? _playbackLineMemory.preferredProviderFor(subject)
            : null);
    return _playbackDiscoveryDomain.prefetchedLineForEpisode(
      subject,
      episode,
      preferredProviderId: preferred,
      minValidity: minValidity,
    );
  }

  NextEpisodeWarmupBundle? prefetchedWarmupBundleForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    Duration minValidity = const Duration(seconds: 60),
  }) {
    if (!(state.value?.settings.rememberLine ?? true)) return null;
    return _playbackDiscoveryDomain.prefetchedWarmupBundleForEpisode(
      subject,
      episode,
      minValidity: minValidity,
    );
  }

  String? rememberedPlaybackProvider(AnimeSubject subject) {
    if (!(state.value?.settings.rememberLine ?? true)) return null;
    return _playbackLineMemory.preferredProviderFor(subject);
  }

  Future<void> rememberPlaybackProvider({
    required AnimeSubject subject,
    required PlaybackLine line,
    required int expectedAccountContextVersion,
  }) {
    if (!(state.value?.settings.rememberLine ?? true)) {
      return Future<void>.value();
    }
    return _playbackLineMemory.rememberSuccessfulProvider(
      subject: subject,
      line: line,
      expectedContextVersion: expectedAccountContextVersion,
    );
  }

  Future<void> prefetchPlaybackForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    String? preferredProviderId,
    bool forceRefresh = false,
    RulePlaybackCancellationToken? cancellationToken,
  }) {
    if (!(state.value?.settings.rememberLine ?? true)) {
      return Future<void>.value();
    }
    return _playbackDiscoveryDomain.prefetchPlaybackForEpisode(
      subject,
      episode,
      preferredProviderId: preferredProviderId,
      forceRefresh: forceRefresh,
      cancellationToken: cancellationToken,
    );
  }

  Future<List<PlaybackLine>> prepareSingleBackupForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    required PlaybackLine currentLine,
    RulePlaybackCancellationToken? cancellationToken,
  }) => _playbackDiscoveryDomain.prepareSingleBackupForEpisode(
    subject,
    episode,
    currentLine: currentLine,
    cancellationToken: cancellationToken,
  );
  ZelunaBackendCatalogRepository? _backendCatalogRepositoryFor(
    ExternalServiceSettings services,
  ) {
    if (!services.playbackBackendEnabled ||
        ZelunaBackendPlaybackRepository.normalizeBaseUrl(
              services.playbackBackendEndpoint,
              service: _playbackBackendService(services),
              allowInsecureSelfHosted: services.allowInsecurePlaybackBackend,
            ) ==
            null) {
      return null;
    }
    return ZelunaBackendCatalogRepository(
      baseUrl: services.playbackBackendEndpoint,
      client: _playbackBackendClient(services),
      service: _playbackBackendService(services),
      allowInsecureSelfHosted: services.allowInsecurePlaybackBackend,
    );
  }

  PlaybackSourceRepository? _backendPlaybackRepositoryFor(
    ExternalServiceSettings services,
  ) {
    if (!services.playbackBackendEnabled ||
        ZelunaBackendPlaybackRepository.normalizeBaseUrl(
              services.playbackBackendEndpoint,
              service: _playbackBackendService(services),
              allowInsecureSelfHosted: services.allowInsecurePlaybackBackend,
            ) ==
            null) {
      return null;
    }
    return ZelunaBackendPlaybackRepository(
      baseUrl: services.playbackBackendEndpoint,
      client: _playbackBackendClient(services),
      service: _playbackBackendService(services),
      allowInsecureSelfHosted: services.allowInsecurePlaybackBackend,
      requestTimeout: const Duration(seconds: 18),
    );
  }

  AnimeDetailBundle _fallbackDetail(AnimeSubject subject) {
    final episodes = [
      for (var number = 1; number <= subject.totalEpisodes; number++)
        AnimeEpisode(
          id: subject.id * 1000 + number,
          subjectId: subject.id,
          number: number,
          title: '',
          airdate: null,
          duration: '',
          description: '',
        ),
    ];
    return AnimeDetailBundle(
      subject: subject,
      episodes: episodes,
      characters: const [],
      staff: const [],
      recommendations: const [],
    );
  }

  Stream<PlaybackLineLookupUpdate> lineUpdatesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    RulePlaybackCancellationToken? cancellationToken,
  }) => _playbackDiscoveryDomain.lineUpdatesForEpisode(
    subject,
    episode,
    cancellationToken: cancellationToken,
  );
  Future<List<SubtitleCandidate>> subtitlesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode,
  ) async {
    final accountContextVersion = _accountContextVersion;
    final services = state.value?.services ?? const ExternalServiceSettings();
    final candidates = await ref
        .read(externalServiceRepositoryProvider)
        .searchSubtitles(subject, episode, services);
    return accountContextVersion == _accountContextVersion
        ? candidates
        : const <SubtitleCandidate>[];
  }

  Future<DanmakuTimeline> danmakuTimelineForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode,
  ) async {
    final accountContextVersion = _accountContextVersion;
    final services = state.value?.services ?? const ExternalServiceSettings();
    final timeline = await ref
        .read(danmakuRepositoryProvider)
        .timelineForEpisode(subject, episode, services);
    return accountContextVersion == _accountContextVersion
        ? timeline
        : const DanmakuTimeline();
  }

  DanmakuCloudController get _danmakuCloud => DanmakuCloudController(
    service: ref.read(cloudDanmakuServiceProvider),
    repository: ref.read(danmakuRepositoryProvider),
    activeAccount: () => _activeAccount,
    contextVersion: () => _accountContextVersion,
    ensureContext: _accounts.ensureContext,
  );
  Future<DanmakuComment> publishDanmaku({
    required AnimeSubject subject,
    required AnimeEpisode episode,
    required Duration position,
    required String text,
  }) => _danmakuCloud.publish(
    subject: subject,
    episode: episode,
    position: position,
    text: text,
  );

  Future<void> deleteDanmaku(DanmakuComment comment) =>
      _danmakuCloud.delete(comment);

  Future<void> registerAccount({
    required String email,
    required String nickname,
    required String password,
    required String verificationCode,
  }) => _accounts.register(
    email: email,
    nickname: nickname,
    password: password,
    verificationCode: verificationCode,
  );

  Future<void> requestRegistrationCode(String email) =>
      _accounts.requestRegistrationCode(email);

  Future<void> requestPasswordResetCode(String email) =>
      _accounts.requestPasswordResetCode(email);

  Future<void> resetAccountPassword({
    required String email,
    required String verificationCode,
    required String newPassword,
  }) => _accounts.resetPassword(
    email: email,
    verificationCode: verificationCode,
    newPassword: newPassword,
  );

  Future<void> loginAccount({
    required String email,
    required String password,
  }) => _accounts.login(email: email, password: password);

  Future<void> signOutAccount() => _accounts.signOut();

  Future<void> changeAccountPassword({
    required String currentPassword,
    required String newPassword,
  }) => _accounts.changePassword(
    currentPassword: currentPassword,
    newPassword: newPassword,
  );

  Future<void> deleteCurrentAccount({required String password}) =>
      _accounts.deleteCurrent(password: password);

  Future<Uint8List> exportCurrentAccountData() => _accounts.exportAccountData();

  Future<AccountDeletionSchedule> requestCloudAccountDeletion({
    required String password,
  }) => _accounts.requestCloudAccountDeletion(password: password);

  Future<void> cancelCloudAccountDeletionAndLogin({
    required String email,
    required String password,
  }) => _accounts.cancelCloudAccountDeletionAndLogin(
    email: email,
    password: password,
  );

  Future<void> retryPendingAccountCleanup() => _accounts.retryPendingCleanup();

  Future<void> updateSettings(PlaybackSettings settings) async {
    await _settingsDomain.updatePlayback(settings);
    if (!settings.rememberLine) {
      await _playbackLineMemory.clearForCurrentAccount(
        expectedContextVersion: _accountContextVersion,
      );
      _playbackDiscoveryController?.clearCaches();
    }
  }

  Future<void> updateProfile(UserProfileSettings profile) =>
      _accounts.updateProfile(profile);

  Future<void> updateHomePreferences(HomePreferences preferences) =>
      _settingsDomain.updateHomePreferences(preferences);

  Future<void> resetRecommendationPreferences() async {
    final contextVersion = _accountContextVersion;
    await _recommendationDomain.clearForCurrentAccount(
      expectedContextVersion: contextVersion,
    );
    if (!isAccountContextCurrent(contextVersion)) return;
    _recommendationNonce = 0;
    _lastServedRecommendationFingerprint = null;
    _rebuildRecommendedHome(recordServed: true);
  }

  Future<void> markRecommendationNotInterested(AnimeSubject subject) async {
    if (!_personalizedRecommendationsEnabled) return;
    final contextVersion = _accountContextVersion;
    await _recordRecommendationEvent(
      RecommendationEventType.notInterested,
      subject,
      id: 'recommendation:not-interested:${canonicalWorkKey(subject)}',
      expectedContextVersion: contextVersion,
    );
    if (!isAccountContextCurrent(contextVersion)) return;
    _rebuildRecommendedHome(recordServed: true);
  }

  void rotateRecommendations() {
    _recommendationNonce++;
    _lastServedRecommendationFingerprint = null;
    _rebuildRecommendedHome(recordServed: true);
  }

  Future<void> recordRecommendationFirstFrame(
    AnimeSubject subject,
    AnimeEpisode episode, {
    int? expectedAccountContextVersion,
  }) async {
    final expected = expectedAccountContextVersion ?? _accountContextVersion;
    if (!isAccountContextCurrent(expected)) return;
    try {
      await _libraryDomain.addHistory(
        subject,
        episode,
        expectedContextVersion: expected,
      );
    } on AccountException {
      return;
    }
    await _recordPlaybackRecommendation(
      RecommendationEventType.firstFrame,
      subject,
      episode,
      expectedContextVersion: expected,
    );
  }

  Future<void> recordRecommendationEffectiveWatch(
    AnimeSubject subject,
    AnimeEpisode episode, {
    int? expectedAccountContextVersion,
  }) => _recordPlaybackRecommendation(
    RecommendationEventType.effectiveWatch,
    subject,
    episode,
    expectedContextVersion:
        expectedAccountContextVersion ?? _accountContextVersion,
  );

  Future<void> recordRecommendationCompleted(
    AnimeSubject subject,
    AnimeEpisode episode, {
    int? expectedAccountContextVersion,
  }) => _recordPlaybackRecommendation(
    RecommendationEventType.completed,
    subject,
    episode,
    expectedContextVersion:
        expectedAccountContextVersion ?? _accountContextVersion,
  );

  Future<void> updateAppearance(AppearanceSettings settings) =>
      _settingsDomain.updateAppearance(settings);

  Future<void> updateDanmaku(DanmakuSettings settings) =>
      _settingsDomain.updateDanmaku(settings);

  Future<void> updateMisc(MiscSettings settings) =>
      _settingsDomain.updateMisc(settings);

  Future<void> updateServices(ExternalServiceSettings settings) =>
      _settingsDomain.updateServices(settings);

  NetworkServiceKind _playbackBackendService(
    ExternalServiceSettings settings,
  ) => SettingsController.playbackBackendService(settings);

  http.Client _playbackBackendClient(ExternalServiceSettings settings) {
    if (!settings.playbackBackendSelfHosted) {
      return ref.read(zelunaBackendHttpClientProvider);
    }
    return ref.read(
      selfHostedBackendHttpClientProvider(
        settings.allowInsecurePlaybackBackend,
      ),
    );
  }

  void handleBangumiCredentialChanged() {
    _playbackDiscoveryController?.clearCaches();
    ref.read(bangumiMetadataRepositoryProvider).resetAccessTokenState();
    ref.read(chineseMetadataRepositoryProvider).clearMemoryCache();
    _catalogController?.clearDetailCache();
  }

  Future<void> handleTmdbCredentialChanged() async {
    ref.read(externalServiceRepositoryProvider).resetTmdbAccessTokenState();
    await _catalogDomain.invalidateTmdbCredential();
  }

  Future<void> invalidateMetadataCache(String kind) =>
      _catalogDomain.invalidateMetadataCache(kind);

  Future<void> installRulePlugin(String id) =>
      _sourceDomain.installRulePlugin(id);

  Future<void> uninstallRulePlugin(String id) =>
      _sourceDomain.uninstallRulePlugin(id);

  Future<void> toggleRulePlugin(String id, bool enabled) =>
      _sourceDomain.toggleRulePlugin(id, enabled);

  Future<void> approveRulePluginPermissionsAndEnable(String id) =>
      _sourceDomain.approveRulePluginPermissionsAndEnable(id);

  Future<void> setInstalledRulePluginsEnabled(
    Iterable<String> ids,
    bool enabled,
  ) => _sourceDomain.setInstalledRulePluginsEnabled(ids, enabled);

  Future<RuleRepositoryRefreshResult> refreshRuleRepositories() =>
      _sourceDomain.refreshRuleRepositories();

  Future<void> setAllInstalledRulePluginsEnabled(bool enabled) =>
      _sourceDomain.setAllInstalledRulePluginsEnabled(enabled);

  Future<void> resetRulePlugins() => _sourceDomain.resetRulePlugins();

  Future<RuleImportResult> importRuleRepositoryUrl(String url) =>
      _sourceDomain.importRuleRepositoryUrl(url);

  Future<RuleImportResult> importRuleRepositoryText(String text) =>
      _sourceDomain.importRuleRepositoryText(text);

  Future<RuleImportResult> importSelectedRulePlugins({
    required String repositoryName,
    required List<RulePlugin> rules,
    String sourceUrl = '',
  }) => _sourceDomain.importSelectedRulePlugins(
    repositoryName: repositoryName,
    rules: rules,
    sourceUrl: sourceUrl,
  );

  Future<void> toggleVideoSource(String id, bool enabled) =>
      _sourceDomain.toggleVideoSource(id, enabled);

  Future<void> setVideoSourcesEnabled(Iterable<String> ids, bool enabled) =>
      _sourceDomain.setVideoSourcesEnabled(ids, enabled);

  RulePluginRepository _ruleRepositoryFor(RulePluginState value) =>
      _sourceController?.repositoryFor(value) ??
      RulePluginRepository(extraRules: value.customRules);

  PlaybackSourceRepository _rulePlaybackRepositoryFor(RulePluginState value) =>
      RulePlaybackSourceRepository(
        repository: _ruleRepositoryFor(value),
        ruleState: value,
        resolver: ref.read(rulePlaybackResolverProvider),
      );

  Future<bool> toggleFavorite(AnimeSubject subject) =>
      _libraryDomain.toggleFavorite(subject);

  Future<bool> toggleFollowing(AnimeSubject subject) =>
      _libraryDomain.toggleFollowing(subject);

  Future<void> synchronizeCloud() => _syncDomain.synchronize();

  Future<bool> addHistory(
    AnimeSubject subject,
    AnimeEpisode? episode, {
    int? expectedAccountContextVersion,
  }) => _libraryDomain.addHistory(
    subject,
    episode,
    expectedContextVersion: expectedAccountContextVersion,
  );

  /// Persists the in-episode playback position onto the matching history
  /// entry. Near-complete positions (>=98% or within the final 15s) reset to
  /// zero so "continue watching" never resumes into credits.
  Future<void> updatePlaybackProgress(
    AnimeSubject subject,
    AnimeEpisode episode, {
    required Duration position,
    required Duration duration,
    int? expectedAccountContextVersion,
  }) => _libraryDomain.updatePlaybackProgress(
    subject,
    episode,
    position: position,
    duration: duration,
    expectedContextVersion: expectedAccountContextVersion,
  );

  Future<String> queueOffline(AnimeSubject subject, AnimeEpisode? episode) =>
      _downloadDomain.queueOffline(subject, episode);

  bool get supportsOfflineDownloads =>
      _downloadController?.supportsDownloads ??
      ref.read(mediaDownloadServiceProvider).supportsDownloads;

  Future<void> pauseDownload(String taskId) =>
      _downloadDomain.pauseDownload(taskId);

  Future<void> resumeDownload(String taskId) =>
      _downloadDomain.resumeDownload(taskId);

  Future<void> cancelDownload(String taskId) =>
      _downloadDomain.cancelDownload(taskId);

  Future<void> removeDownload(String taskId) =>
      _downloadDomain.removeDownload(taskId);

  Future<DownloadStorageSnapshot> downloadStorageSnapshot() =>
      _downloadDomain.storageSnapshot();

  bool get isDownloadDomainReady => _downloadController != null;

  Future<void> deleteConfirmedDownloadStorageEntries(Iterable<String> paths) =>
      _downloadDomain.deleteConfirmedStorageEntries(paths);

  Future<void> addImageFavorite(AnimeSubject subject) =>
      _libraryDomain.addImageFavorite(subject);

  Future<void> clearLibrary(String key) => key == 'offlineTasks'
      ? _downloadDomain.clearDownloads()
      : _libraryDomain.clear(key);

  Future<void> submitFeedback({
    required String title,
    required String content,
    AnimeSubject? subject,
  }) => _libraryDomain.submitFeedback(
    title: title,
    content: content,
    subject: subject,
  );

  Future<void> _applyAccountScope(AccountScopeActivation activation) async {
    final account = activation.account;
    final accountId = account?.id;
    final settingsSnapshot = _settingsDomain.loadForAccount(
      accountId: accountId,
      contextVersion: activation.contextVersion,
    );
    _playbackLineMemory.loadForAccount(
      accountId: accountId,
      contextVersion: activation.contextVersion,
    );
    if (!settingsSnapshot.playback.rememberLine) {
      await _playbackLineMemory.clearForCurrentAccount(
        expectedContextVersion: activation.contextVersion,
      );
    }
    final profileJson = _settings.get(
      _accountSettingsKeyFor(accountId, 'profile'),
    );
    final sourceSnapshot = await _sourceDomain.loadForAccount(
      accountId: accountId,
      contextVersion: activation.contextVersion,
    );
    final downloadSnapshot = await _downloadDomain.loadForAccount(
      accountId: accountId,
      contextVersion: activation.contextVersion,
    );
    final librarySnapshot = await _libraryDomain.loadForAccount(
      accountId: accountId,
      contextVersion: activation.contextVersion,
    );
    await _recommendationDomain.loadForAccount(
      accountId: accountId,
      contextVersion: activation.contextVersion,
    );
    _recommendationNonce = 0;
    _lastServedRecommendationFingerprint = null;
    _playbackDiscoveryDomain.loadForAccount(
      accountId: accountId,
      contextVersion: activation.contextVersion,
      services: settingsSnapshot.services,
      ruleState: sourceSnapshot.rulePlugins,
      history: librarySnapshot.history,
    );
    final catalogLoad = await _catalogDomain.loadForAccount(
      accountId: accountId,
      contextVersion: activation.contextVersion,
      services: settingsSnapshot.services,
      fallbackHomeFeed: ref
          .read(bangumiMetadataRepositoryProvider)
          .fallbackHomeFeed(),
    );
    final recommendedHome = _composeRecommendedHomeFeed(
      catalogLoad.snapshot,
      librarySnapshot: librarySnapshot,
      preferences: settingsSnapshot.homePreferences,
    );
    final current = state.value;
    if (current == null ||
        !_accounts.isContextCurrent(activation.contextVersion)) {
      return;
    }
    ref.read(m3uSourceAdapterProvider).clearCache();
    ref.read(torrentSourceAdapterProvider).clearCache();
    ref.read(danmakuRepositoryProvider).invalidate();
    ref.read(sourceRuleBridgeProvider).xbpqHydrator?.clearCache();
    state = AsyncData(
      current.copyWith(
        homeFeed: recommendedHome,
        selectedSubjects: catalogLoad.snapshot.selectedSubjects,
        settings: settingsSnapshot.playback,
        favorites: librarySnapshot.favorites,
        history: librarySnapshot.history,
        following: librarySnapshot.following,
        offlineTasks: downloadSnapshot.tasks,
        imageFavorites: librarySnapshot.imageFavorites,
        feedbacks: librarySnapshot.feedbacks,
        profile: AccountController.profileFromJson(profileJson, account),
        accountSession: activation.session,
        homePreferences: settingsSnapshot.homePreferences,
        appearance: settingsSnapshot.appearance,
        danmaku: settingsSnapshot.danmaku,
        misc: settingsSnapshot.misc,
        services: settingsSnapshot.services,
        rulePlugins: sourceSnapshot.rulePlugins,
        sourceCatalog: sourceSnapshot.sourceCatalog,
        syncStatus: account == null
            ? const SyncStatus.localOnly()
            : const SyncStatus(phase: SyncPhase.checking),
      ),
    );
    _syncDomain.loadForAccount(
      accountId: accountId,
      contextVersion: activation.contextVersion,
      services: settingsSnapshot.services,
    );
    await _settingsDomain.applyRuntimeEffects().onError((_, _) {});
    if (!catalogLoad.homeFresh) {
      unawaited(_catalogDomain.refreshHome().onError((_, _) {}));
    }
    unawaited(_recordCurrentHomeRecommendationsServed().onError((_, _) {}));
  }

  void _selectCredentialAccountContext(
    String? accountId, {
    required bool resetCredentialState,
  }) {
    ref.read(_bangumiCredentialAccountContextProvider).selectAccount(accountId);
    ref.read(_tmdbCredentialAccountContextProvider).selectAccount(accountId);
    if (!resetCredentialState) return;
    ref.read(bangumiMetadataRepositoryProvider).resetAccessTokenState();
    ref.read(externalServiceRepositoryProvider).resetTmdbAccessTokenState();
  }

  List<AccountOwnedDownload> _readAccountOwnedDownloads() =>
      _downloadController?.ownedDownloads() ?? const [];

  void _publishAccountSession(LocalAccountSession session) {
    final current = state.value;
    if (current == null) return;
    state = AsyncData(current.copyWith(accountSession: session));
  }

  void _publishAccountProfile(AccountProfileUpdate update) {
    final current = state.value;
    if (current == null) return;
    state = AsyncData(
      current.copyWith(profile: update.profile, accountSession: update.session),
    );
  }

  void _publishSettingsSnapshot(SettingsSnapshot snapshot) {
    final current = state.value;
    if (current == null) return;
    final recommendationModeChanged =
        current.homePreferences.personalizedRecommendations !=
        snapshot.homePreferences.personalizedRecommendations;
    state = AsyncData(
      current.copyWith(
        settings: snapshot.playback,
        homePreferences: snapshot.homePreferences,
        appearance: snapshot.appearance,
        danmaku: snapshot.danmaku,
        misc: snapshot.misc,
        services: snapshot.services,
      ),
    );
    if (recommendationModeChanged) {
      _recommendationNonce = 0;
      _lastServedRecommendationFingerprint = null;
      _rebuildRecommendedHome(recordServed: true);
    }
  }

  SyncLocalSnapshot _readSyncLocalSnapshot() => SyncLocalSnapshot(
    favorites: _libraryDomain.snapshot.favorites,
    following: _libraryDomain.snapshot.following,
    history: _libraryDomain.snapshot.history,
    appearance: _settingsDomain.snapshot.appearance,
    playback: _settingsDomain.snapshot.playback,
  );

  Future<void> _applyCloudSyncRecord(CloudSyncRecord record) async {
    switch (record.type) {
      case CloudSyncRecordType.favorite ||
          CloudSyncRecordType.following ||
          CloudSyncRecordType.history ||
          CloudSyncRecordType.playbackPosition:
        await _libraryDomain.applyRemoteRecord(record);
      case CloudSyncRecordType.appearanceSettings:
        await _settingsDomain.applyRemoteAppearance(
          AppearanceSettings.fromJson(record.payload),
        );
      case CloudSyncRecordType.playbackSettings:
        final next = PlaybackSettings.fromJson(record.payload);
        await _settingsDomain.applyRemotePlayback(next);
        if (!next.rememberLine) {
          await _playbackLineMemory.clearForCurrentAccount(
            expectedContextVersion: _accountContextVersion,
          );
          _playbackDiscoveryController?.clearCaches();
        }
    }
  }

  void _publishSyncStatus(SyncStatus status) {
    final current = state.value;
    if (current == null) return;
    state = AsyncData(current.copyWith(syncStatus: status));
  }

  void _publishSourceSnapshot(SourceSnapshot snapshot) {
    final current = state.value;
    if (current == null) return;
    _playbackDiscoveryController?.applyRuleState(
      snapshot.rulePlugins,
      contextVersion: _accountContextVersion,
    );
    state = AsyncData(
      current.copyWith(
        rulePlugins: snapshot.rulePlugins,
        sourceCatalog: snapshot.sourceCatalog,
      ),
    );
  }

  void _publishDownloadSnapshot(DownloadSnapshot snapshot) {
    final current = state.value;
    if (current == null) return;
    state = AsyncData(current.copyWith(offlineTasks: snapshot.tasks));
  }

  void _publishLibrarySnapshot(LibrarySnapshot snapshot) {
    final current = state.value;
    if (current == null) return;
    _playbackDiscoveryController?.updateHistory(
      snapshot.history,
      contextVersion: _accountContextVersion,
    );
    state = AsyncData(
      current.copyWith(
        favorites: snapshot.favorites,
        history: snapshot.history,
        following: snapshot.following,
        imageFavorites: snapshot.imageFavorites,
        feedbacks: snapshot.feedbacks,
      ),
    );
    _rebuildRecommendedHome(recordServed: false);
  }

  void _publishCatalogSnapshot(CatalogSnapshot snapshot) {
    final current = state.value;
    if (current == null) return;
    final feed = _composeRecommendedHomeFeed(
      snapshot,
      librarySnapshot: _libraryDomain.snapshot,
      preferences: current.homePreferences,
    );
    state = AsyncData(
      current.copyWith(
        homeFeed: feed,
        selectedSubjects: snapshot.selectedSubjects,
      ),
    );
    unawaited(_recordCurrentHomeRecommendationsServed().onError((_, _) {}));
  }

  bool get _personalizedRecommendationsEnabled =>
      state.value?.homePreferences.personalizedRecommendations ??
      _settingsController
          ?.snapshot
          .homePreferences
          .personalizedRecommendations ??
      true;

  Future<void> _recordPlaybackRecommendation(
    RecommendationEventType type,
    AnimeSubject subject,
    AnimeEpisode episode, {
    required int expectedContextVersion,
  }) async {
    if (!isAccountContextCurrent(expectedContextVersion) ||
        !_personalizedRecommendationsEnabled) {
      return;
    }
    final workKey = canonicalWorkKey(subject);
    await _recordRecommendationEvent(
      type,
      subject,
      id: 'recommendation:playback:${type.name}:$workKey:${episode.id}',
      sessionId: 'episode:${episode.id}',
      expectedContextVersion: expectedContextVersion,
    );
    if (!isAccountContextCurrent(expectedContextVersion)) return;
    _rebuildRecommendedHome(recordServed: false);
  }

  Future<void> _recordRecommendationEvent(
    RecommendationEventType type,
    AnimeSubject subject, {
    required int expectedContextVersion,
    String? id,
    String? sessionId,
  }) async {
    if (!isAccountContextCurrent(expectedContextVersion) ||
        !_personalizedRecommendationsEnabled) {
      return;
    }
    try {
      await _recommendationDomain.record(
        RecommendationEvent.forSubject(
          id: id,
          type: type,
          subject: subject,
          occurredAt: DateTime.now(),
          sessionId: sessionId,
        ),
        expectedContextVersion: expectedContextVersion,
      );
    } on StateError {
      // Account switches deliberately invalidate stale recommendation writes.
    }
  }

  RecommendationSnapshot _effectiveRecommendationSnapshot(
    LibrarySnapshot librarySnapshot,
  ) {
    final stored = _recommendationDomain.snapshot;
    final storedPlaybackWorks = stored.behaviors
        .where(
          (event) =>
              event.type == RecommendationEventType.firstFrame ||
              event.type == RecommendationEventType.effectiveWatch ||
              event.type == RecommendationEventType.completed,
        )
        .map((event) => event.workKey)
        .toSet();
    final libraryEvents = <RecommendationEvent>[];
    void addLibraryEvent(
      RecommendationEventType type,
      LibraryEntry entry,
      String source,
    ) {
      final workKey = canonicalWorkKey(entry.subject);
      libraryEvents.add(
        RecommendationEvent.forSubject(
          id: 'recommendation:library:$source:$workKey',
          type: type,
          subject: entry.subject,
          occurredAt: entry.updatedAt,
          sessionId: source,
        ),
      );
    }

    for (final entry in librarySnapshot.following) {
      addLibraryEvent(RecommendationEventType.following, entry, 'following');
    }
    for (final entry in librarySnapshot.favorites) {
      addLibraryEvent(RecommendationEventType.favorite, entry, 'favorite');
    }
    for (final entry in librarySnapshot.history) {
      if (storedPlaybackWorks.contains(canonicalWorkKey(entry.subject))) {
        continue;
      }
      addLibraryEvent(RecommendationEventType.firstFrame, entry, 'history');
    }
    final now = DateTime.now();
    final behaviors = <RecommendationEvent>[
      ...stored.behaviors,
      ...libraryEvents,
    ];
    return RecommendationSnapshot(
      accountId: stored.accountId,
      contextVersion: stored.contextVersion,
      behaviors: behaviors,
      served: stored.served,
      profile: RecommendationProfile.fromEvents(
        behaviors: behaviors,
        served: stored.served,
        now: now,
      ),
      generatedAt: now,
    );
  }

  AnimeHomeFeed _composeRecommendedHomeFeed(
    CatalogSnapshot catalogSnapshot, {
    required LibrarySnapshot librarySnapshot,
    required HomePreferences preferences,
  }) {
    final candidates = _catalogCandidates(catalogSnapshot);
    if (candidates.isEmpty) return catalogSnapshot.homeFeed;
    final now = DateTime.now();
    RecommendationSnapshot? recommendationSnapshot;
    late final List<CatalogCandidate> ordered;
    if (preferences.personalizedRecommendations) {
      recommendationSnapshot = _effectiveRecommendationSnapshot(
        librarySnapshot,
      );
      final result = rankCatalog(
        candidates: candidates,
        snapshot: recommendationSnapshot,
        now: now,
        nonce: _recommendationNonce,
      );
      ordered = _interleaveRankedCandidates(result);
    } else {
      ordered = _pureChartHomepageCandidates(candidates, now: now);
    }
    if (ordered.isEmpty) return catalogSnapshot.homeFeed;
    final recommended = ordered
        .take(recommendationDefaultTotalSlots)
        .map((item) => item.subject)
        .toList(growable: false);
    final withBanner = ordered.where(
      (item) => (item.subject.bannerUrl ?? '').trim().isNotEmpty,
    );
    final notRecentlyServed = recommendationSnapshot == null
        ? withBanner
        : withBanner.where(
            (item) => !recommendationSnapshot!.profile.lastServedAt.containsKey(
              item.workKey,
            ),
          );
    final hero = notRecentlyServed.isNotEmpty
        ? notRecentlyServed.first.subject
        : withBanner.isNotEmpty
        ? withBanner.first.subject
        : recommended.first;
    final base = catalogSnapshot.homeFeed;
    return AnimeHomeFeed(
      hero: hero,
      recent: base.recent,
      recommended: recommended,
      index: base.index,
      categories: base.categories,
      tags: base.tags,
      seriesHighlights: base.seriesHighlights,
      movieHighlights: base.movieHighlights,
    );
  }

  List<CatalogCandidate> _catalogCandidates(CatalogSnapshot snapshot) {
    final candidates = <CatalogCandidate>[
      for (final values in snapshot.homeCandidates.values) ...values,
    ];
    if (candidates.isNotEmpty) {
      return _deduplicateRecommendationCandidates(candidates);
    }
    final feed = snapshot.homeFeed;
    return _deduplicateRecommendationCandidates(
      <AnimeSubject>[
        feed.hero,
        ...feed.recommended,
        ...feed.index,
        ...feed.seriesHighlights,
        ...feed.movieHighlights,
      ].map((subject) => CatalogCandidate(subject: subject)),
    );
  }

  List<CatalogCandidate> _deduplicateRecommendationCandidates(
    Iterable<CatalogCandidate> candidates,
  ) {
    final byKey = <String, CatalogCandidate>{};
    for (final candidate in candidates) {
      if (candidate.subject.title.trim().isEmpty) continue;
      final current = byKey[candidate.workKey];
      byKey[candidate.workKey] = current == null
          ? candidate
          : current.merge(candidate);
    }
    return byKey.values.toList(growable: false);
  }

  List<CatalogCandidate> _interleaveRankedCandidates(
    RecommendationRankingResult result,
  ) {
    final queues = <SubjectContentType, List<CatalogCandidate>>{
      for (final type in SubjectContentType.values)
        type: result.byType[type]!
            .map((item) => item.candidate)
            .toList(growable: true),
    };
    return interleaveRecommendationCandidates(queues, seed: result.seed);
  }

  List<CatalogCandidate> _pureChartHomepageCandidates(
    Iterable<CatalogCandidate> candidates, {
    required DateTime now,
  }) {
    final seed = recommendationStableSeed(
      accountId: _recommendationDomain.accountId,
      date: now,
      nonce: _recommendationNonce,
    );
    final baseSeed = recommendationStableSeed(
      accountId: _recommendationDomain.accountId,
      date: now,
    );
    final queues = <SubjectContentType, List<CatalogCandidate>>{};
    for (final type in SubjectContentType.values) {
      final values =
          candidates
              .where((item) => item.contentType == type)
              .toList(growable: true)
            ..sort(_comparePopularCandidates);
      final chartWindow = values
          .take(recommendationColdStartQuotaPerType * 3)
          .toList(growable: false);
      queues[type] = _rotatingChartSelection(
        chartWindow,
        seed: '$baseSeed|${type.name}',
      );
    }
    return interleaveRecommendationCandidates(queues, seed: 'pure:$seed');
  }

  List<CatalogCandidate> _rotatingChartSelection(
    List<CatalogCandidate> candidates, {
    required String seed,
  }) {
    if (candidates.length <= recommendationColdStartQuotaPerType) {
      return candidates.toList(growable: true);
    }
    final baseOffset = seed.codeUnits.fold<int>(
      0,
      (value, unit) => (value * 31 + unit) & 0x7fffffff,
    );
    final offset = (baseOffset + _recommendationNonce * 2) % candidates.length;
    return <CatalogCandidate>[
      ...candidates.skip(offset),
      ...candidates.take(offset),
    ].take(recommendationColdStartQuotaPerType).toList(growable: true);
  }

  Future<List<AnimeSubject>> _catalogSubjects(
    SubjectContentType type, {
    required CatalogSortMode sort,
    required bool waitForRefresh,
  }) async {
    final candidates = await _catalogDomain.candidatesForType(
      type,
      waitForRefresh: waitForRefresh,
    );
    final unique = _deduplicateRecommendationCandidates(candidates);
    if (sort == CatalogSortMode.recommended &&
        _personalizedRecommendationsEnabled) {
      final profile = _effectiveRecommendationSnapshot(_libraryDomain.snapshot);
      final ranked = rankCatalogForType(
        type: type,
        candidates: unique,
        snapshot: profile,
        now: DateTime.now(),
        nonce: _recommendationNonce,
        excludeKnownWorks: false,
      );
      final rankedKeys = ranked.map((item) => item.candidate.workKey).toSet();
      final blocked =
          unique
              .where((item) => !rankedKeys.contains(item.workKey))
              .toList(growable: false)
            ..sort(_comparePopularCandidates);
      return <AnimeSubject>[
        ...ranked.map((item) => item.candidate.subject),
        ...blocked.map((item) => item.subject),
      ];
    }
    final sorted = unique.toList(growable: false)
      ..sort(switch (sort) {
        CatalogSortMode.topRated => _compareTopRatedCandidates,
        CatalogSortMode.latest => _compareLatestCandidates,
        CatalogSortMode.recommended ||
        CatalogSortMode.popular => _comparePopularCandidates,
      });
    return sorted.map((item) => item.subject).toList(growable: false);
  }

  int _comparePopularCandidates(
    CatalogCandidate first,
    CatalogCandidate second,
  ) {
    final byScore = _catalogPopularityScore(
      second,
    ).compareTo(_catalogPopularityScore(first));
    return byScore != 0 ? byScore : first.workKey.compareTo(second.workKey);
  }

  int _compareTopRatedCandidates(
    CatalogCandidate first,
    CatalogCandidate second,
  ) {
    final byRating = (second.subject.ratingScore ?? -1).compareTo(
      first.subject.ratingScore ?? -1,
    );
    if (byRating != 0) return byRating;
    final byVotes = (second.subject.ratingTotal ?? 0).compareTo(
      first.subject.ratingTotal ?? 0,
    );
    return byVotes != 0 ? byVotes : first.workKey.compareTo(second.workKey);
  }

  int _compareLatestCandidates(
    CatalogCandidate first,
    CatalogCandidate second,
  ) {
    final firstDate = _catalogDate(first.subject);
    final secondDate = _catalogDate(second.subject);
    if (firstDate != null || secondDate != null) {
      if (firstDate == null) return 1;
      if (secondDate == null) return -1;
      final byDate = secondDate.compareTo(firstDate);
      if (byDate != 0) return byDate;
    }
    return _comparePopularCandidates(first, second);
  }

  DateTime? _catalogDate(AnimeSubject subject) {
    final raw = subject.date?.trim() ?? '';
    final parsed = DateTime.tryParse(raw);
    if (parsed != null) return parsed;
    final year = int.tryParse(subject.year);
    return year == null ? null : DateTime.utc(year);
  }

  double _catalogPopularityScore(CatalogCandidate candidate) {
    final chart = candidate.evidence.chartScore;
    if (chart > 0) return chart;
    final rating = ((candidate.subject.ratingScore ?? 0) / 10).clamp(0.0, 1.0);
    final votes = candidate.subject.ratingTotal ?? 0;
    final voteConfidence = votes <= 0 ? 0.0 : votes / (votes + 500);
    return (rating * 0.8 + voteConfidence * 0.2).clamp(0.0, 1.0);
  }

  void _rebuildRecommendedHome({required bool recordServed}) {
    final current = state.value;
    final catalog = _catalogController;
    final library = _libraryController;
    if (current == null || catalog == null || library == null) return;
    final feed = _composeRecommendedHomeFeed(
      catalog.snapshot,
      librarySnapshot: library.snapshot,
      preferences: current.homePreferences,
    );
    state = AsyncData(current.copyWith(homeFeed: feed));
    if (recordServed) {
      unawaited(_recordCurrentHomeRecommendationsServed().onError((_, _) {}));
    }
  }

  Future<void> _recordCurrentHomeRecommendationsServed() async {
    if (!_personalizedRecommendationsEnabled) return;
    final current = state.value;
    final catalog = _catalogController;
    final recommendation = _recommendationController;
    if (current == null || catalog == null || recommendation == null) return;
    final candidates = <String, CatalogCandidate>{
      for (final item in _catalogCandidates(catalog.snapshot))
        item.workKey: item,
    };
    final visible = <CatalogCandidate>[];
    final seen = <String>{};
    for (final subject in <AnimeSubject>[
      current.homeFeed.hero,
      ...current.homeFeed.recommended,
    ]) {
      final key = canonicalWorkKey(subject);
      if (!seen.add(key)) continue;
      visible.add(candidates[key] ?? CatalogCandidate(subject: subject));
    }
    if (visible.isEmpty) return;
    final now = DateTime.now();
    final fingerprint =
        '${recommendation.accountId ?? 'guest'}|'
        '${now.year}-${now.month}-${now.day}|$_recommendationNonce|'
        '${visible.map((item) => item.workKey).join(',')}';
    if (_lastServedRecommendationFingerprint == fingerprint) return;
    try {
      final recorded = await recommendation.recordServed(
        visible.map(
          (candidate) => RecommendationServedEvent.forCandidate(
            candidate: candidate,
            servedAt: now,
            surface: 'home',
          ),
        ),
        expectedContextVersion: _accountContextVersion,
      );
      if (recorded) _lastServedRecommendationFingerprint = fingerprint;
    } on StateError {
      // Ignore a display record invalidated by an account switch.
    }
  }

  Future<void> _handleExternalServicesChanged(
    ExternalServicesChange change,
  ) async {
    _syncDomain.applyServices(
      change.current,
      contextVersion: change.contextVersion,
    );
    if (change.playbackBackendChanged) {
      _playbackDiscoveryDomain.applyServices(
        change.current,
        contextVersion: change.contextVersion,
      );
    }
    if (!change.metadataChanged && !change.playbackBackendChanged) return;
    await _catalogDomain.applyServices(
      change.current,
      contextVersion: change.contextVersion,
    );
  }

  Future<void> _quiesceDownloadsForAccountChange() async {
    await _settingsController?.settleWrites();
    await _sourceController?.settleWrites();
    await _libraryController?.settleWrites();
    await _syncController?.settle();
    await _catalogController?.settleWrites();
    await _recommendationController?.settleWrites();
    await _playbackLineMemory.settleWrites();
    await _downloadController?.quiesce();
  }

  String _accountSettingsKey(String key) =>
      _accountSettingsKeyFor(_activeAccount?.id, key);

  static String _accountSettingsKeyFor(String? accountId, String key) =>
      AccountController.settingsKeyFor(accountId, key);
}

final class _HiveRecommendationEventStore implements RecommendationEventStore {
  const _HiveRecommendationEventStore(this._box);

  final Box<dynamic> _box;

  @override
  Object? read(String storageKey) => _box.get(storageKey);

  @override
  Future<void> write(String storageKey, Object value) =>
      _box.put(storageKey, value);

  @override
  Future<void> delete(String storageKey) => _box.delete(storageKey);
}

const _fallbackExternalSeries = [
  AnimeSubject(
    id: 82,
    title: '权力的游戏',
    originalTitle: 'Game of Thrones',
    summary: '九大家族争夺维斯特洛大陆控制权的史诗剧集。',
    coverUrl:
        'https://static.tvmaze.com/uploads/images/original_untouched/190/476117.jpg',
    bannerUrl: 'https://images.metahub.space/background/medium/tt0944947/img',
    date: '2011-04-17',
    platform: 'Scripted',
    language: '英语',
    region: '美国',
    status: '已完结',
    categories: [
      AnimeCategory(name: '剧情'),
      AnimeCategory(name: '冒险'),
      AnimeCategory(name: '奇幻'),
    ],
    tags: [AnimeTag(name: 'TVMaze')],
    totalEpisodes: 73,
    source: 'tvmaze',
  ),
  AnimeSubject(
    id: 169,
    title: '绝命毒师',
    originalTitle: 'Breaking Bad',
    summary: '一位化学教师在绝境中走向犯罪世界。',
    coverUrl:
        'https://static.tvmaze.com/uploads/images/original_untouched/0/2400.jpg',
    bannerUrl: 'https://images.metahub.space/background/medium/tt0903747/img',
    date: '2008-01-20',
    platform: 'Scripted',
    language: '英语',
    region: '美国',
    status: '已完结',
    categories: [
      AnimeCategory(name: '剧情'),
      AnimeCategory(name: '犯罪'),
      AnimeCategory(name: '惊悚'),
    ],
    tags: [AnimeTag(name: 'TVMaze')],
    totalEpisodes: 62,
    source: 'tvmaze',
  ),
  AnimeSubject(
    id: 527,
    title: '行尸走肉',
    originalTitle: 'The Walking Dead',
    summary: '幸存者在末日世界中寻找栖身之处，也面对人与人之间更复杂的冲突。',
    coverUrl:
        'https://static.tvmaze.com/uploads/images/original_untouched/67/168817.jpg',
    bannerUrl: 'https://images.metahub.space/background/medium/tt1520211/img',
    date: '2010-10-31',
    platform: 'Scripted',
    language: '英语',
    region: '美国',
    status: '已完结',
    categories: [
      AnimeCategory(name: '剧情'),
      AnimeCategory(name: '动作'),
      AnimeCategory(name: '恐怖'),
    ],
    tags: [AnimeTag(name: 'TVMaze')],
    totalEpisodes: 177,
    source: 'tvmaze',
  ),
  AnimeSubject(
    id: 57841,
    title: '黑暗荣耀',
    originalTitle: '더 글로리',
    summary: '一名女性围绕校园暴力展开漫长复仇。',
    coverUrl: 'https://images.metahub.space/poster/medium/tt21344706/img',
    bannerUrl: 'https://images.metahub.space/background/medium/tt21344706/img',
    date: '2022-12-30',
    platform: 'Scripted',
    language: '韩语',
    region: '韩国',
    status: '已完结',
    categories: [
      AnimeCategory(name: '剧情'),
      AnimeCategory(name: '惊悚'),
    ],
    tags: [AnimeTag(name: 'TVMaze')],
    totalEpisodes: 16,
    source: 'tvmaze',
  ),
  AnimeSubject(
    id: 41007,
    title: '后翼弃兵',
    originalTitle: 'The Queen\'s Gambit',
    summary: '天才棋手在成长、胜负和自我控制之间寻找平衡。',
    coverUrl: 'https://images.metahub.space/poster/medium/tt10048342/img',
    bannerUrl: 'https://images.metahub.space/background/medium/tt10048342/img',
    date: '2020-10-23',
    platform: 'Scripted',
    language: '英语',
    region: '美国',
    status: '已完结',
    categories: [AnimeCategory(name: '剧情')],
    tags: [AnimeTag(name: 'TVMaze')],
    totalEpisodes: 7,
    source: 'tvmaze',
  ),
  AnimeSubject(
    id: 2993,
    title: '怪奇物语',
    originalTitle: 'Stranger Things',
    summary: '小镇少年与超自然事件、秘密实验和异世界威胁相遇。',
    coverUrl: 'https://images.metahub.space/poster/medium/tt4574334/img',
    bannerUrl: 'https://images.metahub.space/background/medium/tt4574334/img',
    date: '2016-07-15',
    platform: 'Scripted',
    language: '英语',
    region: '美国',
    status: '连载中',
    categories: [
      AnimeCategory(name: '剧情'),
      AnimeCategory(name: '科幻'),
      AnimeCategory(name: '恐怖'),
    ],
    tags: [AnimeTag(name: 'TVMaze')],
    totalEpisodes: 34,
    source: 'tvmaze',
  ),
  AnimeSubject(
    id: 335,
    title: '神探夏洛克',
    originalTitle: 'Sherlock',
    summary: '福尔摩斯与华生在现代伦敦破解高智商案件。',
    coverUrl: 'https://images.metahub.space/poster/medium/tt1475582/img',
    bannerUrl: 'https://images.metahub.space/background/medium/tt1475582/img',
    date: '2010-07-25',
    platform: 'Scripted',
    language: '英语',
    region: '英国',
    status: '已完结',
    categories: [
      AnimeCategory(name: '剧情'),
      AnimeCategory(name: '犯罪'),
      AnimeCategory(name: '悬疑'),
    ],
    tags: [AnimeTag(name: 'TVMaze')],
    totalEpisodes: 13,
    source: 'tvmaze',
  ),
];

const _fallbackExternalMovies = [
  AnimeSubject(
    id: 25188,
    title: '指环王：护戒使者',
    originalTitle: 'The Lord of the Rings: The Fellowship of the Ring',
    summary: '一枚戒指引发跨越中土世界的远征。',
    coverUrl: 'https://images.metahub.space/poster/medium/tt0120737/img',
    bannerUrl: 'https://images.metahub.space/background/medium/tt0120737/img',
    date: '2001-12-10',
    platform: 'Movie',
    language: '',
    region: 'Wikidata',
    status: '电影',
    categories: [
      AnimeCategory(name: '电影'),
      AnimeCategory(name: '奇幻'),
    ],
    tags: [
      AnimeTag(name: 'Wikidata'),
      AnimeTag(name: 'IMDb'),
    ],
    totalEpisodes: 1,
    source: 'cinemeta:movie:tt0120737',
  ),
  AnimeSubject(
    id: 2875,
    title: '盗梦空间',
    originalTitle: 'Inception',
    summary: '一名盗梦者接受在他人潜意识中植入想法的任务。',
    coverUrl: 'https://images.metahub.space/poster/medium/tt1375666/img',
    bannerUrl: 'https://images.metahub.space/background/medium/tt1375666/img',
    date: '2010-07-08',
    platform: 'Movie',
    language: '',
    region: 'Wikidata',
    status: '电影',
    categories: [
      AnimeCategory(name: '电影'),
      AnimeCategory(name: '科幻'),
    ],
    tags: [
      AnimeTag(name: 'Wikidata'),
      AnimeTag(name: 'IMDb'),
    ],
    totalEpisodes: 1,
    source: 'cinemeta:movie:tt1375666',
  ),
  AnimeSubject(
    id: 103474,
    title: '星际穿越',
    originalTitle: 'Interstellar',
    summary: '人类为寻找新的栖息星球，穿越虫洞展开星际航行。',
    coverUrl: 'https://images.metahub.space/poster/medium/tt0816692/img',
    bannerUrl: 'https://images.metahub.space/background/medium/tt0816692/img',
    date: '2014-10-26',
    platform: 'Movie',
    language: '英语',
    region: '美国',
    status: '电影',
    categories: [
      AnimeCategory(name: '电影'),
      AnimeCategory(name: '科幻'),
      AnimeCategory(name: '冒险'),
    ],
    tags: [
      AnimeTag(name: 'Wikidata'),
      AnimeTag(name: 'IMDb'),
    ],
    totalEpisodes: 1,
    source: 'cinemeta:movie:tt0816692',
  ),
  AnimeSubject(
    id: 83495,
    title: '黑客帝国',
    originalTitle: 'The Matrix',
    summary: '程序员发现现实背后的真相，并卷入人类与机器的战争。',
    coverUrl: 'https://images.metahub.space/poster/medium/tt0133093/img',
    bannerUrl: 'https://images.metahub.space/background/medium/tt0133093/img',
    date: '1999-03-31',
    platform: 'Movie',
    language: '英语',
    region: '美国',
    status: '电影',
    categories: [
      AnimeCategory(name: '电影'),
      AnimeCategory(name: '科幻'),
      AnimeCategory(name: '动作'),
    ],
    tags: [
      AnimeTag(name: 'Wikidata'),
      AnimeTag(name: 'IMDb'),
    ],
    totalEpisodes: 1,
    source: 'cinemeta:movie:tt0133093',
  ),
  AnimeSubject(
    id: 163872,
    title: '蝙蝠侠：黑暗骑士',
    originalTitle: 'The Dark Knight',
    summary: '蝙蝠侠面对小丑制造的混乱和道德困境。',
    coverUrl: 'https://images.metahub.space/poster/medium/tt0468569/img',
    bannerUrl: 'https://images.metahub.space/background/medium/tt0468569/img',
    date: '2008-07-14',
    platform: 'Movie',
    language: '英语',
    region: '美国',
    status: '电影',
    categories: [
      AnimeCategory(name: '电影'),
      AnimeCategory(name: '动作'),
      AnimeCategory(name: '犯罪'),
    ],
    tags: [
      AnimeTag(name: 'Wikidata'),
      AnimeTag(name: 'IMDb'),
    ],
    totalEpisodes: 1,
    source: 'cinemeta:movie:tt0468569',
  ),
  AnimeSubject(
    id: 47703,
    title: '教父',
    originalTitle: 'The Godfather',
    summary: '科里昂家族权力交接中的犯罪史诗。',
    coverUrl: 'https://images.metahub.space/poster/medium/tt0068646/img',
    bannerUrl: 'https://images.metahub.space/background/medium/tt0068646/img',
    date: '1972-03-14',
    platform: 'Movie',
    language: '英语',
    region: '美国',
    status: '电影',
    categories: [
      AnimeCategory(name: '电影'),
      AnimeCategory(name: '犯罪'),
      AnimeCategory(name: '剧情'),
    ],
    tags: [
      AnimeTag(name: 'Wikidata'),
      AnimeTag(name: 'IMDb'),
    ],
    totalEpisodes: 1,
    source: 'cinemeta:movie:tt0068646',
  ),
  AnimeSubject(
    id: 181795,
    title: '千与千寻',
    originalTitle: '千と千尋の神隠し',
    summary: '少女误入神灵世界，为救父母开始独自面对陌生规则。',
    coverUrl: 'https://images.metahub.space/poster/medium/tt0245429/img',
    bannerUrl: 'https://images.metahub.space/background/medium/tt0245429/img',
    date: '2001-07-20',
    platform: 'Movie',
    language: '日语',
    region: '日本',
    status: '电影',
    categories: [
      AnimeCategory(name: '电影'),
      AnimeCategory(name: '奇幻'),
      AnimeCategory(name: '冒险'),
    ],
    tags: [
      AnimeTag(name: 'Wikidata'),
      AnimeTag(name: 'Animation'),
    ],
    totalEpisodes: 1,
    source: 'cinemeta:movie:tt0245429',
  ),
  AnimeSubject(
    id: 287158,
    title: '你的名字。',
    originalTitle: '君の名は。',
    summary: '两个少年少女在梦中交换身体，并追寻彼此的命运交点。',
    coverUrl: 'https://images.metahub.space/poster/medium/tt5311514/img',
    bannerUrl: 'https://images.metahub.space/background/medium/tt5311514/img',
    date: '2016-08-26',
    platform: 'Movie',
    language: '日语',
    region: '日本',
    status: '电影',
    categories: [
      AnimeCategory(name: '电影'),
      AnimeCategory(name: '奇幻'),
      AnimeCategory(name: '剧情'),
    ],
    tags: [
      AnimeTag(name: 'Wikidata'),
      AnimeTag(name: 'Animation'),
    ],
    totalEpisodes: 1,
    source: 'cinemeta:movie:tt5311514',
  ),
  AnimeSubject(
    id: 1055672,
    title: '沙丘',
    originalTitle: 'Dune',
    summary: '少年继承沙漠星球的命运，在权力、生态和预言中成长。',
    coverUrl: 'https://images.metahub.space/poster/medium/tt1160419/img',
    bannerUrl: 'https://images.metahub.space/background/medium/tt1160419/img',
    date: '2021-09-03',
    platform: 'Movie',
    language: '英语',
    region: '美国',
    status: '电影',
    categories: [
      AnimeCategory(name: '电影'),
      AnimeCategory(name: '科幻'),
      AnimeCategory(name: '冒险'),
    ],
    tags: [
      AnimeTag(name: 'Wikidata'),
      AnimeTag(name: 'IMDb'),
    ],
    totalEpisodes: 1,
    source: 'cinemeta:movie:tt1160419',
  ),
];
