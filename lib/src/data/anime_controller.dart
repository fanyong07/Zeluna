import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:wakelock_plus/wakelock_plus.dart';

import '../accounts/local_account_repository.dart';
import '../accounts/cloud_account_repository.dart';
import '../domain/anime_models.dart';
import '../domain/subject_content_type.dart';
import '../rules/rule_importer.dart';
import '../rules/drpy_runtime.dart';
import '../rules/rule_models.dart';
import '../rules/rule_playback_resolver.dart';
import '../rules/rule_plugin_repository.dart';
import '../rules/tvbox_xbpq_hydrator.dart';
import '../sources/external_source_adapters.dart';
import '../sources/source_catalog_models.dart';
import '../sources/source_catalog_repository.dart';
import '../sources/source_rule_bridge.dart';
import 'bangumi_credential_store.dart';
import 'bangumi_metadata_repository.dart';
import 'async_single_flight.dart';
import 'chinese_metadata_repository.dart';
import 'chinese_text.dart';
import 'danmaku_repository.dart';
import 'external_service_repository.dart';
import 'media_download_line_selector.dart';
import 'media_download_result.dart';
import 'media_download_service.dart';
import 'media_download_task.dart';
import 'playback_prefetch_cache.dart';
import 'playback_source_repository.dart';
import 'tmdb_credential_store.dart';
import 'zeluna_backend_catalog_repository.dart';
import 'zeluna_backend_playback_repository.dart';

class RuleRepositoryRefreshResult {
  const RuleRepositoryRefreshResult({
    required this.repositoryCount,
    required this.refreshedCount,
    required this.failedCount,
    required this.ruleCount,
  });

  final int repositoryCount;
  final int refreshedCount;
  final int failedCount;
  final int ruleCount;

  bool get hasRemoteRepositories => repositoryCount > 0;
}

/// Runs every supplied playback probe with a small concurrency window and
/// emits each result as soon as it finishes. This keeps a large route
/// inventory responsive without creating a request burst.
Stream<PlaybackLine> probePlaybackLinesProgressively(
  List<PlaybackLine> lines, {
  int maxConcurrent = 4,
  RulePlaybackCancellationToken? cancellationToken,
  required Future<PlaybackLine> Function(PlaybackLine line) verify,
}) async* {
  if (lines.isEmpty ||
      maxConcurrent <= 0 ||
      cancellationToken?.isCancelled == true) {
    return;
  }
  var nextIndex = 0;
  final pending = <int, Future<({int index, PlaybackLine line})>>{};

  void fillWindow() {
    while (nextIndex < lines.length &&
        pending.length < maxConcurrent &&
        cancellationToken?.isCancelled != true) {
      final index = nextIndex++;
      pending[index] = verify(
        lines[index],
      ).then((line) => (index: index, line: line));
    }
  }

  fillWindow();
  while (pending.isNotEmpty && cancellationToken?.isCancelled != true) {
    final completed = await Future.any(pending.values);
    pending.remove(completed.index);
    if (cancellationToken?.isCancelled == true) return;
    yield completed.line;
    fillWindow();
  }
}

Future<List<PlaybackLine>> probeSinglePlaybackBackupSequentially(
  Iterable<PlaybackLine> candidates, {
  int maxCandidates = 3,
  RulePlaybackCancellationToken? cancellationToken,
  required Future<PlaybackLine> Function(PlaybackLine line) verify,
}) async {
  if (maxCandidates <= 0 || cancellationToken?.isCancelled == true) {
    return const <PlaybackLine>[];
  }
  final checked = <PlaybackLine>[];
  for (final candidate in candidates.take(maxCandidates)) {
    if (cancellationToken?.isCancelled == true) break;
    final verified = await verify(candidate);
    checked.add(verified);
    if (verified.available) break;
  }
  return List<PlaybackLine>.unmodifiable(checked);
}

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

final bangumiMetadataHttpClientProvider = Provider<http.Client>(
  (ref) => http.Client(),
);

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
  final client = http.Client();
  final drpyPublicClient = createDrpyPublicHttpClient();
  ref.onDispose(client.close);
  ref.onDispose(drpyPublicClient.close);
  return RulePlaybackResolver(
    client: client,
    drpyPublicClient: drpyPublicClient,
  );
});

final zelunaBackendHttpClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});

final cloudAccountServiceProvider = Provider<CloudAccountService>((ref) {
  final repository = CloudAccountRepository();
  ref.onDispose(repository.close);
  return repository;
});

final externalServiceHttpClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
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
  final repository = DanmakuRepository();
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
    );
  }
}

class AnimeController extends AsyncNotifier<AnimeState> {
  static const _settingsBox = 'anime.settings.v2';
  static const _libraryBox = 'anime.library.v2';
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
  ];
  static const _accountLibraryKeys = [
    'favorites',
    'history',
    'following',
    'offlineTasks',
    'imageFavorites',
    'feedbacks',
  ];
  static const _animeMetadataCacheKey = 'metadata.cache.anime';
  static const _seriesMetadataCacheKey = 'metadata.cache.series';
  static const _movieMetadataCacheKey = 'metadata.cache.movie';
  static const _homeFeedCacheKey = 'metadata.cache.home';
  static const _homeFeedCacheVersion = 4;
  static const _homeFeedCacheTtl = Duration(hours: 1);
  static const _metadataCacheVersion = 11;
  static const _metadataCacheLimit = 1200;
  static const _metadataCacheTtl = Duration(hours: 8);
  static const _sparseMetadataCacheTtl = Duration(minutes: 30);
  late Box<dynamic> _settings;
  late Box<dynamic> _library;
  late LocalAccountRepository _accountRepository;
  LocalAccount? _activeAccount;
  int _homeRefreshVersion = 0;
  int _sourceCatalogRefreshVersion = 0;
  int _accountContextVersion = 0;
  final _metadataRefreshes = <String, Future<List<AnimeSubject>>>{};
  final _latestMetadataRefreshes = <String, Future<List<AnimeSubject>>>{};
  final _playbackPrefetches = <String, Future<void>>{};
  final _playbackPrefetchCancellationTokens =
      <String, RulePlaybackCancellationToken>{};
  final _backendLineLookups = AsyncSingleFlight<String, List<PlaybackLine>>();
  final _backendPlaybackLineCache = PlaybackPrefetchCache();
  final _downloadRuns = <String, Future<void>>{};
  final _downloadPersistedAt = <String, DateTime>{};
  Future<void> _metadataWriteQueue = Future<void>.value();
  Future<void> _downloadWriteQueue = Future<void>.value();
  Future<void> _accountOperationQueue = Future<void>.value();
  Timer? _downloadPersistTimer;

  int get accountContextVersion => _accountContextVersion;

  bool isAccountContextCurrent(int version) =>
      version == _accountContextVersion;

  @override
  Future<AnimeState> build() async {
    final boxes = await Future.wait<Box<dynamic>>([
      Hive.openBox<dynamic>(_settingsBox),
      Hive.openBox<dynamic>(_libraryBox),
      Hive.openBox<dynamic>(LocalAccountRepository.boxName),
    ]);
    _settings = boxes[0];
    _library = boxes[1];
    _accountRepository = LocalAccountRepository(boxes[2]);
    final pendingDeletion = _accountRepository.pendingDeletion();
    if (pendingDeletion != null) {
      await _resumePendingDeletion(pendingDeletion).onError((_, _) {});
    }
    await _resumePendingBangumiCredentialMigration().onError((_, _) {});
    await _resumePendingTmdbCredentialMigration().onError((_, _) {});
    final pendingRegistration = _accountRepository.pendingRegistration();
    LocalAccount? recoveredRegistration;
    if (pendingRegistration != null) {
      await _resumePendingRegistration(pendingRegistration);
      recoveredRegistration = pendingRegistration.account;
    }
    final cachedAccount =
        recoveredRegistration ?? _accountRepository.currentCloudAccount();
    final restoredAccount = await ref
        .read(cloudAccountServiceProvider)
        .restoreSession(cachedAccount);
    if (restoredAccount != null) {
      await _accountRepository.rememberCloudAccount(restoredAccount);
      if (recoveredRegistration != null) {
        await _accountRepository.finalizeRegistration(restoredAccount.id);
      }
    } else {
      await _accountRepository.signOut();
    }
    _activeAccount = restoredAccount;
    ref
        .read(_bangumiCredentialAccountContextProvider)
        .selectAccount(_activeAccount?.id);
    ref
        .read(_tmdbCredentialAccountContextProvider)
        .selectAccount(_activeAccount?.id);
    final accountSession = LocalAccountSession(
      current: _activeAccount,
      available: _accountRepository.listCloudAccounts(),
      hasPendingCleanup: _accountRepository.pendingDeletion() != null,
    );
    final settingsJson = _settings.get(_accountSettingsKey('playback'));
    final settings = settingsJson is Map
        ? PlaybackSettings.fromJson(settingsJson.cast<String, dynamic>())
        : const PlaybackSettings();
    final profileJson = _settings.get(_accountSettingsKey('profile'));
    final homeJson = _settings.get(_accountSettingsKey('homePreferences'));
    final appearanceJson = _settings.get(_accountSettingsKey('appearance'));
    final danmakuJson = _settings.get(_accountSettingsKey('danmaku'));
    final miscJson = _settings.get(_accountSettingsKey('misc'));
    final servicesJson = _settings.get(_accountSettingsKey('services'));
    final rulePluginsJson = _settings.get(_accountSettingsKey('rulePlugins'));
    final services = _normalizeServices(
      servicesJson is Map
          ? ExternalServiceSettings.fromJson(
              servicesJson.cast<String, dynamic>(),
            )
          : const ExternalServiceSettings(),
    );
    final bangumiRepository = ref.read(bangumiMetadataRepositoryProvider);
    final cachedHomeFeed = _readHomeFeedCache(_servicesSignature(services));
    final feed = cachedHomeFeed.feed ?? bangumiRepository.fallbackHomeFeed();
    final rulePlugins = _restoreRulePlugins(rulePluginsJson);
    const sourceCatalog = SourceCatalogState();
    final misc = miscJson is Map
        ? MiscSettings.fromJson(miscJson.cast<String, dynamic>())
        : const MiscSettings();
    unawaited(
      WakelockPlus.toggle(enable: misc.keepScreenOn).onError((_, _) {}),
    );
    final offlineTasks = await _readDownloadTasks();
    final initialState = AnimeState(
      homeFeed: feed,
      settings: settings,
      favorites: _readEntries('favorites'),
      history: _readEntries('history'),
      following: _readEntries('following'),
      offlineTasks: offlineTasks,
      imageFavorites: _readEntries('imageFavorites'),
      feedbacks: _readFeedbacks(),
      profile: _profileFromJson(profileJson, _activeAccount),
      accountSession: accountSession,
      homePreferences: homeJson is Map
          ? HomePreferences.fromJson(homeJson.cast<String, dynamic>())
          : const HomePreferences(),
      appearance: appearanceJson is Map
          ? AppearanceSettings.fromJson(appearanceJson.cast<String, dynamic>())
          : const AppearanceSettings(),
      danmaku: danmakuJson is Map
          ? DanmakuSettings.fromJson(danmakuJson.cast<String, dynamic>())
          : const DanmakuSettings(),
      misc: misc,
      services: services,
      rulePlugins: rulePlugins,
      sourceCatalog: sourceCatalog,
    );
    if (recoveredRegistration != null) {
      await _accountRepository.setActiveAccount(recoveredRegistration.id);
      await _accountRepository.finalizeRegistration(recoveredRegistration.id);
    }
    if (!cachedHomeFeed.fresh) {
      unawaited(
        Future<void>.delayed(
          Duration.zero,
          () => _refreshHomeFeed(services),
        ).onError((_, _) {}),
      );
    }
    ref.onDispose(() {
      _downloadPersistTimer?.cancel();
      _cancelPlaybackPrefetches();
    });
    return initialState;
  }

  Future<List<AnimeSubject>> search(String keyword) async {
    if (keyword.trim().isEmpty) return Future.value(const []);
    final repository = _backendCatalogRepository();
    if (repository == null) return const [];
    return repository.search(keyword).onError((_, _) => const []);
  }

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

  Future<List<AnimeSubject>> categorySubjects(String name) async {
    final subjects = await discoverSubjects(waitForRefresh: true);
    return subjects
        .where((item) => item.categories.any((value) => value.name == name))
        .toList(growable: false);
  }

  Future<List<AnimeSubject>> tagSubjects(String name) async {
    final subjects = await discoverSubjects(waitForRefresh: true);
    return subjects
        .where((item) => item.tags.any((value) => value.name == name))
        .toList(growable: false);
  }

  Future<List<AnimeSubject>> discoverSubjects({
    bool waitForRefresh = false,
  }) async {
    final subjects = _homeSubjects
        .where(
          (subject) =>
              subjectMatchesContentType(subject, SubjectContentType.anime),
        )
        .toList(growable: false);
    final services = state.value?.services ?? const ExternalServiceSettings();
    return _metadataSubjects(
      key: _animeMetadataCacheKey,
      signature: _metadataSignature('anime', services),
      contentType: SubjectContentType.anime,
      fallback: subjects,
      waitForRefresh: waitForRefresh,
      load: () async {
        final repository = _backendCatalogRepository();
        return repository == null
            ? const <AnimeSubject>[]
            : repository.home(SubjectContentType.anime);
      },
    );
  }

  Future<List<AnimeSubject>> seriesSubjects({
    bool waitForRefresh = false,
  }) async {
    final services = state.value?.services ?? const ExternalServiceSettings();
    if (!services.mediaMetadataEnabled) {
      return _subjectsOfType(
        _fallbackExternalSeries,
        SubjectContentType.series,
      );
    }
    return _metadataSubjects(
      key: _seriesMetadataCacheKey,
      signature: _metadataSignature('series', services),
      contentType: SubjectContentType.series,
      fallback: _fallbackExternalSeries,
      waitForRefresh: waitForRefresh,
      load: () async {
        final repository = _backendCatalogRepository();
        return repository == null
            ? const <AnimeSubject>[]
            : repository.home(SubjectContentType.series);
      },
    );
  }

  Future<List<AnimeSubject>> movieSubjects({
    bool waitForRefresh = false,
  }) async {
    final services = state.value?.services ?? const ExternalServiceSettings();
    if (!services.mediaMetadataEnabled) {
      return _subjectsOfType(_fallbackExternalMovies, SubjectContentType.movie);
    }
    return _metadataSubjects(
      key: _movieMetadataCacheKey,
      signature: _metadataSignature('movie', services),
      contentType: SubjectContentType.movie,
      fallback: _fallbackExternalMovies,
      waitForRefresh: waitForRefresh,
      load: () async {
        final repository = _backendCatalogRepository();
        return repository == null
            ? const <AnimeSubject>[]
            : repository.home(SubjectContentType.movie);
      },
    );
  }

  Future<Map<int, List<AnimeSubject>>> weeklySchedule() async {
    final subjects = await discoverSubjects(waitForRefresh: true);
    return _groupScheduleSubjects(subjects);
  }

  Map<int, List<AnimeSubject>> _groupScheduleSubjects(
    Iterable<AnimeSubject> subjects,
  ) {
    final schedule = {for (var day = 0; day < 7; day++) day: <AnimeSubject>[]};
    for (final subject in _uniqueSubjects(subjects)) {
      final date = DateTime.tryParse(subject.date ?? '');
      final day = date == null ? subject.id.abs() % 7 : date.weekday % 7;
      schedule[day]!.add(subject);
    }
    return {
      for (final entry in schedule.entries)
        entry.key: entry.value.take(36).toList(growable: false),
    };
  }

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

  Future<AnimeDetailBundle> detail(AnimeSubject subject) async {
    final accountContextVersion = _accountContextVersion;
    final current = state.value;
    final cacheKey = _subjectCacheKey(subject);
    final cached = current?.selectedSubjects[cacheKey];
    if (cached != null) {
      _prefetchPlayback(cached.subject, cached.episodes);
      return cached;
    }
    final repository = _backendCatalogRepository();
    final detail = await _enrichSparseDetail(
      await repository?.detail(subject) ?? _fallbackDetail(subject),
    );
    _ensureAccountContext(accountContextVersion);
    final previous = state.value;
    if (previous != null && accountContextVersion == _accountContextVersion) {
      state = AsyncData(
        previous.copyWith(
          selectedSubjects: {...previous.selectedSubjects, cacheKey: detail},
        ),
      );
    }
    _prefetchPlayback(detail.subject, detail.episodes);
    return detail;
  }

  void _prefetchPlayback(AnimeSubject subject, List<AnimeEpisode> episodes) {
    if (episodes.isEmpty || !_usesBackendPlayback(subject)) return;
    final historyEpisode = state.value?.history
        .where((item) => sameSubjectIdentity(item.subject, subject))
        .map((item) => item.episode)
        .whereType<AnimeEpisode>()
        .firstOrNull;
    final episode =
        historyEpisode != null &&
            episodes.any((item) => item.id == historyEpisode.id)
        ? historyEpisode
        : episodes.first;
    final key =
        '${subject.source}|${subject.id}|'
        '${subject.title}|${episode.id}|${episode.number}';
    if (_playbackPrefetches.containsKey(key)) return;

    final cancellationToken = RulePlaybackCancellationToken();
    late final Future<void> prefetch;
    prefetch =
        linesForEpisode(
          subject,
          episode,
          cancellationToken: cancellationToken,
        ).then<void>((_) {}, onError: (_, _) {}).whenComplete(() {
          if (identical(_playbackPrefetches[key], prefetch)) {
            _playbackPrefetches.remove(key);
            _playbackPrefetchCancellationTokens.remove(key);
          }
        });
    _playbackPrefetches[key] = prefetch;
    _playbackPrefetchCancellationTokens[key] = cancellationToken;
  }

  void _cancelPlaybackPrefetches() {
    for (final token in _playbackPrefetchCancellationTokens.values) {
      token.cancel();
    }
    _playbackPrefetchCancellationTokens.clear();
    _playbackPrefetches.clear();
    _backendPlaybackLineCache.clear();
  }

  Future<List<PlaybackLine>> linesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    RulePlaybackCancellationToken? cancellationToken,
  }) {
    return linesForEpisodeMode(
      subject,
      episode,
      cancellationToken: cancellationToken,
    );
  }

  Future<PlaybackLine> verifyPlaybackLine(
    PlaybackLine line, {
    bool enrichMetadata = true,
    bool forceRefresh = false,
    RulePlaybackCancellationToken? cancellationToken,
  }) {
    return ref
        .read(rulePlaybackResolverProvider)
        .verifyPlaybackLine(
          line: line,
          enrichMetadata: enrichMetadata,
          forceRefresh: forceRefresh,
          cancellationToken: cancellationToken,
        );
  }

  Future<List<PlaybackLine>> linesForEpisodeMode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    bool expandAll = false,
    RulePlaybackCancellationToken? cancellationToken,
  }) async {
    if (cancellationToken?.isCancelled ?? false) return const [];
    final accountContextVersion = _accountContextVersion;
    var backendLines = const <PlaybackLine>[];
    var probedBackendLines = const <PlaybackLine>[];
    var ruleLines = const <PlaybackLine>[];

    bool isCurrentRequest() =>
        accountContextVersion == _accountContextVersion &&
        !(cancellationToken?.isCancelled ?? false);

    bool hasPlayableLine(Iterable<PlaybackLine> lines) => lines.any(
      (line) => line.available && (line.url?.trim().isNotEmpty ?? false),
    );

    Future<({String kind, List<PlaybackLine> lines})> tagged(
      String kind,
      Future<List<PlaybackLine>> future,
    ) async => (kind: kind, lines: await future);

    // A warm Zeluna cache normally responds in well under a second. Give it a
    // short uncontested head start, then race it against custom rules. This is
    // a real hedge: a fast empty backend result starts fallback immediately,
    // while a slow backend can no longer hold a ready rule line for six seconds.
    final backendEvent = tagged(
      'backend',
      _backendLinesForEpisode(
        subject,
        episode,
        cancellationToken: cancellationToken,
      ).timeout(
        const Duration(seconds: 6),
        onTimeout: () => const <PlaybackLine>[],
      ),
    );
    final firstEvent = await Future.any([
      backendEvent,
      Future<({String kind, List<PlaybackLine> lines})>.delayed(
        const Duration(milliseconds: 900),
        () => (kind: 'hedge', lines: const <PlaybackLine>[]),
      ),
    ]);
    if (!isCurrentRequest()) return const <PlaybackLine>[];

    final pending =
        <String, Future<({String kind, List<PlaybackLine> lines})>>{};

    void startRules() {
      pending.putIfAbsent(
        'rules',
        () => tagged(
          'rules',
          _ruleLinesForEpisode(
            subject,
            episode,
            expandAll: expandAll,
            cancellationToken: cancellationToken,
          ),
        ),
      );
    }

    void startBackendCandidateProbe() {
      if (backendLines.isEmpty || pending.containsKey('probe')) return;
      pending['probe'] = tagged(
        'probe',
        _probeBackendClientCandidates(
          backendLines,
          cancellationToken: cancellationToken,
        ).onError((_, _) => const <PlaybackLine>[]),
      );
    }

    if (firstEvent.kind == 'backend') {
      backendLines = firstEvent.lines;
      if (hasPlayableLine(backendLines)) {
        return _mergePlaybackLines(backendLines);
      }
      startBackendCandidateProbe();
      startRules();
    } else {
      pending['backend'] = backendEvent;
      startRules();
    }

    while (pending.isNotEmpty) {
      final event = await Future.any(pending.values);
      pending.remove(event.kind);
      if (!isCurrentRequest()) return const <PlaybackLine>[];
      switch (event.kind) {
        case 'backend':
          backendLines = event.lines;
          startBackendCandidateProbe();
        case 'probe':
          probedBackendLines = event.lines;
          if (hasPlayableLine(probedBackendLines)) {
            _cacheBackendPlaybackLines(
              subject,
              episode,
              _mergePlaybackLines(<PlaybackLine>[
                ...backendLines,
                ...probedBackendLines,
              ]),
              expandAll: expandAll,
            );
          }
        case 'rules':
          ruleLines = event.lines;
      }
      final merged = _mergePlaybackLines(<PlaybackLine>[
        ...backendLines,
        ...probedBackendLines,
        ...ruleLines,
      ]);
      if (hasPlayableLine(merged)) return merged;
    }

    return isCurrentRequest()
        ? _mergePlaybackLines(<PlaybackLine>[
            ...backendLines,
            ...probedBackendLines,
            ...ruleLines,
          ])
        : const <PlaybackLine>[];
  }

  String? _backendPlaybackLookupKey(
    ExternalServiceSettings services,
    AnimeSubject subject,
    AnimeEpisode episode, {
    bool expandAll = false,
  }) {
    final endpoint = ZelunaBackendPlaybackRepository.normalizeBaseUrl(
      services.playbackBackendEndpoint,
    );
    if (!services.playbackBackendEnabled ||
        !_usesBackendPlayback(subject) ||
        endpoint == null) {
      return null;
    }
    return <Object>[
      _accountContextVersion,
      endpoint,
      subject.source,
      subject.id,
      episode.id,
      episode.number,
      expandAll,
    ].join('|');
  }

  void _cacheBackendPlaybackLines(
    AnimeSubject subject,
    AnimeEpisode episode,
    Iterable<PlaybackLine> lines, {
    bool expandAll = false,
  }) {
    final services = state.value?.services ?? const ExternalServiceSettings();
    final lookupKey = _backendPlaybackLookupKey(
      services,
      subject,
      episode,
      expandAll: expandAll,
    );
    if (lookupKey == null) return;
    _backendPlaybackLineCache.write(lookupKey, lines);
  }

  Future<List<PlaybackLine>> _backendLinesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    bool expandAll = false,
    RulePlaybackCancellationToken? cancellationToken,
  }) {
    if (cancellationToken?.isCancelled == true) {
      return Future.value(const <PlaybackLine>[]);
    }
    final services = state.value?.services ?? const ExternalServiceSettings();
    final lookupKey = _backendPlaybackLookupKey(
      services,
      subject,
      episode,
      expandAll: expandAll,
    );
    if (lookupKey == null) {
      return Future.value(const <PlaybackLine>[]);
    }
    final accountContextVersion = _accountContextVersion;
    final cached = _backendPlaybackLineCache.read(lookupKey);
    if (cached != null) return Future.value(cached);
    final pending = _backendLineLookups.run(lookupKey, () {
      final repository = ZelunaBackendPlaybackRepository(
        baseUrl: services.playbackBackendEndpoint,
        client: ref.read(zelunaBackendHttpClientProvider),
        requestTimeout: const Duration(seconds: 18),
      );
      // Caller cancellation must not cancel the shared request for another
      // listener. Each caller applies its own cancellation check below.
      return repository
          .linesForEpisodeMode(subject, episode, expandAll: expandAll)
          .timeout(
            const Duration(seconds: 20),
            onTimeout: () => const <PlaybackLine>[],
          )
          .onError((_, _) => const <PlaybackLine>[]);
    });
    return pending.then((lines) {
      if (accountContextVersion != _accountContextVersion ||
          cancellationToken?.isCancelled == true) {
        return const <PlaybackLine>[];
      }
      _backendPlaybackLineCache.write(lookupKey, lines);
      return lines;
    });
  }

  PlaybackLine? prefetchedLineForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode,
  ) {
    final services = state.value?.services ?? const ExternalServiceSettings();
    final lookupKey = _backendPlaybackLookupKey(services, subject, episode);
    if (lookupKey == null) return null;
    final lines = _backendPlaybackLineCache.read(lookupKey);
    if (lines == null) return null;
    for (final line in lines) {
      if (line.available &&
          (line.serverVerified || line.clientVerified) &&
          (line.url?.trim().isNotEmpty ?? false)) {
        return line;
      }
    }
    return null;
  }

  // 客户端 web-selector 规则线路：独立于后端路径，不受 _usesBackendPlayback
  // 的 bangumi/tmdb 门禁限制。仅当用户导入过订阅(customRules 非空)时才发起，
  // 保证默认行为仍是纯后端。空规则时仓库内部直接返回空。
  Future<List<PlaybackLine>> _ruleLinesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    bool expandAll = false,
    RulePlaybackCancellationToken? cancellationToken,
  }) {
    final ruleState = state.value?.rulePlugins;
    if (ruleState == null) {
      return Future.value(const <PlaybackLine>[]);
    }
    final repository = RulePlaybackSourceRepository(
      repository: _ruleRepositoryFor(ruleState),
      ruleState: ruleState,
      resolver: ref.read(rulePlaybackResolverProvider),
    );
    return repository
        .linesForEpisodeMode(
          subject,
          episode,
          expandAll: expandAll,
          cancellationToken: cancellationToken,
        )
        .timeout(
          const Duration(seconds: 12),
          onTimeout: () => const <PlaybackLine>[],
        )
        .onError((_, _) => const <PlaybackLine>[]);
  }

  List<PlaybackLine> _mergePlaybackLines(List<PlaybackLine> lines) {
    final merged = <PlaybackLine>[];
    final indexes = <String, int>{};
    for (final line in lines) {
      final url = line.url ?? '';
      final key = url.isNotEmpty ? url : '${line.providerId}:${line.id}';
      final previousIndex = indexes[key];
      if (previousIndex == null) {
        indexes[key] = merged.length;
        merged.add(line);
      } else if (!merged[previousIndex].available && line.available) {
        merged[previousIndex] = line;
      }
    }
    return merged;
  }

  Future<List<PlaybackLine>> _probeBackendClientCandidates(
    List<PlaybackLine> lines, {
    RulePlaybackCancellationToken? cancellationToken,
  }) async {
    final now = DateTime.now();
    final candidates = lines
        .where(
          (line) =>
              line.requiresClientProbe &&
              (line.url?.trim().isNotEmpty ?? false) &&
              (line.expiresAt == null ||
                  line.expiresAt!.isAfter(
                    now.add(const Duration(seconds: 15)),
                  )),
        )
        .take(4)
        .toList(growable: false);
    if (candidates.isEmpty || cancellationToken?.isCancelled == true) {
      return const <PlaybackLine>[];
    }
    final checked = <PlaybackLine>[];
    await for (final line in probePlaybackLinesProgressively(
      candidates,
      maxConcurrent: 4,
      cancellationToken: cancellationToken,
      verify: (line) => verifyPlaybackLine(
        line,
        enrichMetadata: false,
        cancellationToken: cancellationToken,
      ),
    )) {
      checked.add(line);
      // Candidate-only inventories should open on the first proven route;
      // the remaining inventory is checked by lineUpdatesForEpisode after the
      // first frame instead of waiting for the slowest probe in this batch.
      if (line.available) return <PlaybackLine>[line];
    }
    return checked;
  }

  Future<List<PlaybackLine>> prepareSingleBackupForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    required PlaybackLine currentLine,
    RulePlaybackCancellationToken? cancellationToken,
  }) async {
    final accountContextVersion = _accountContextVersion;
    final backendLines = await _backendLinesForEpisode(
      subject,
      episode,
      expandAll: true,
      cancellationToken: cancellationToken,
    );
    if (accountContextVersion != _accountContextVersion ||
        cancellationToken?.isCancelled == true) {
      return const <PlaybackLine>[];
    }

    var checked = _mergePlaybackLines(backendLines);
    final currentUrl = currentLine.url?.trim() ?? '';
    bool isCurrent(PlaybackLine line) {
      final url = line.url?.trim() ?? '';
      return line.id == currentLine.id ||
          (currentUrl.isNotEmpty && url == currentUrl);
    }

    if (checked.any((line) => line.available && !isCurrent(line))) {
      return checked;
    }

    final candidates = _backendLinesNeedingBackgroundProbe(
      checked,
    ).where((line) => line.requiresClientProbe && !isCurrent(line));
    final probed = await probeSinglePlaybackBackupSequentially(
      candidates,
      cancellationToken: cancellationToken,
      verify: (candidate) => verifyPlaybackLine(
        candidate,
        enrichMetadata: false,
        cancellationToken: cancellationToken,
      ),
    );
    for (final verified in probed) {
      checked = _replacePlaybackLine(checked, verified);
    }
    return checked;
  }

  List<PlaybackLine> _backendLinesNeedingBackgroundProbe(
    List<PlaybackLine> lines,
  ) {
    final refreshThreshold = DateTime.now().add(const Duration(seconds: 15));
    return lines
        .where(
          (line) =>
              (line.url?.trim().isNotEmpty ?? false) &&
              (line.requiresClientProbe ||
                  (line.serverVerified &&
                      !line.clientVerified &&
                      line.latency == null)) &&
              (line.expiresAt == null ||
                  line.expiresAt!.isAfter(refreshThreshold)),
        )
        .toList(growable: false);
  }

  List<PlaybackLine> _replacePlaybackLine(
    List<PlaybackLine> lines,
    PlaybackLine replacement,
  ) {
    var replaced = false;
    final result = <PlaybackLine>[];
    for (final line in lines) {
      if (line.id == replacement.id) {
        if (!replaced) result.add(replacement);
        replaced = true;
      } else {
        result.add(line);
      }
    }
    if (!replaced) result.add(replacement);
    return result;
  }

  ZelunaBackendCatalogRepository? _backendCatalogRepository() {
    final services = state.value?.services ?? const ExternalServiceSettings();
    if (!services.playbackBackendEnabled ||
        ZelunaBackendPlaybackRepository.normalizeBaseUrl(
              services.playbackBackendEndpoint,
            ) ==
            null) {
      return null;
    }
    return ZelunaBackendCatalogRepository(
      baseUrl: services.playbackBackendEndpoint,
      client: ref.read(zelunaBackendHttpClientProvider),
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

  bool _usesBackendPlayback(AnimeSubject subject) {
    final source = subject.source.toLowerCase();
    return source == 'bangumi' || source.startsWith('tmdb:');
  }

  Stream<PlaybackLineLookupUpdate> lineUpdatesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    RulePlaybackCancellationToken? cancellationToken,
  }) async* {
    final accountContextVersion = _accountContextVersion;
    final token = cancellationToken ?? RulePlaybackCancellationToken();
    final backendLines = await _backendLinesForEpisode(
      subject,
      episode,
      cancellationToken: token,
    );
    if (accountContextVersion != _accountContextVersion || token.isCancelled) {
      return;
    }
    var baseLines = _mergePlaybackLines(backendLines);
    yield PlaybackLineLookupUpdate(
      lines: baseLines,
      completedRules: 0,
      totalRules: 1,
      phase: PlaybackLineLookupPhase.discovery,
    );
    final expandedBackendLines = await _backendLinesForEpisode(
      subject,
      episode,
      expandAll: true,
      cancellationToken: token,
    );
    if (accountContextVersion != _accountContextVersion || token.isCancelled) {
      return;
    }
    baseLines = _mergePlaybackLines(<PlaybackLine>[
      ...baseLines,
      ...expandedBackendLines,
    ]);
    final backendProbeCandidates = _backendLinesNeedingBackgroundProbe(
      baseLines,
    );
    final backendProbeTotal = backendProbeCandidates.isEmpty
        ? 1
        : backendProbeCandidates.length;
    yield PlaybackLineLookupUpdate(
      lines: baseLines,
      completedRules: 0,
      totalRules: backendProbeTotal,
      phase: PlaybackLineLookupPhase.discovery,
    );
    var clientCheckedBaseLines = baseLines;
    var completedBackendProbes = 0;
    await for (final probedLine in probePlaybackLinesProgressively(
      backendProbeCandidates,
      maxConcurrent: 4,
      cancellationToken: token,
      verify: (line) => verifyPlaybackLine(
        line,
        enrichMetadata: false,
        cancellationToken: token,
      ),
    )) {
      if (accountContextVersion != _accountContextVersion ||
          token.isCancelled) {
        return;
      }
      clientCheckedBaseLines = _replacePlaybackLine(
        clientCheckedBaseLines,
        probedLine,
      );
      completedBackendProbes++;
      yield PlaybackLineLookupUpdate(
        lines: clientCheckedBaseLines,
        completedRules: completedBackendProbes,
        totalRules: backendProbeTotal,
        phase: PlaybackLineLookupPhase.discovery,
      );
    }
    final ruleState = state.value?.rulePlugins;
    final hasRules = ruleState != null && ruleState.customRules.isNotEmpty;
    if (!hasRules) {
      yield PlaybackLineLookupUpdate(
        lines: clientCheckedBaseLines,
        completedRules: backendProbeTotal,
        totalRules: backendProbeTotal,
        phase: PlaybackLineLookupPhase.complete,
      );
      return;
    }
    // 后端线路先返回，再叠加用户规则仓库的渐进发现/验证流。
    yield PlaybackLineLookupUpdate(
      lines: clientCheckedBaseLines,
      completedRules: backendProbeTotal,
      totalRules: backendProbeTotal,
      phase: PlaybackLineLookupPhase.discovery,
    );
    final repository = RulePlaybackSourceRepository(
      repository: _ruleRepositoryFor(ruleState),
      ruleState: ruleState,
      resolver: ref.read(rulePlaybackResolverProvider),
    );
    await for (final update in repository.lineUpdatesForEpisode(
      subject,
      episode,
      cancellationToken: token,
    )) {
      if (accountContextVersion != _accountContextVersion ||
          token.isCancelled) {
        return;
      }
      yield PlaybackLineLookupUpdate(
        lines: _mergePlaybackLines(<PlaybackLine>[
          ...clientCheckedBaseLines,
          ...update.lines,
        ]),
        completedRules: update.completedRules + backendProbeTotal,
        totalRules: update.totalRules + backendProbeTotal,
        phase: update.phase,
        timedOut: update.timedOut,
        resolvedProviderId: update.resolvedProviderId,
      );
    }
  }

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

  Future<List<DanmakuMatch>> danmakuForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode,
  ) async {
    final timeline = await danmakuTimelineForEpisode(subject, episode);
    return timeline.sources;
  }

  Future<void> registerAccount({
    required String email,
    required String nickname,
    required String password,
    String verificationCode = '000000',
  }) => _runAccountOperation(() async {
    final current = state.value;
    if (current == null) throw const AccountException('应用状态尚未准备好');
    final account = await ref
        .read(cloudAccountServiceProvider)
        .register(
          email: email,
          nickname: nickname,
          password: password,
          verificationCode: verificationCode,
        );
    await _quiesceDownloadsForAccountChange();
    await _settings.flush();
    await _library.flush();
    final shouldImportGuestData =
        _activeAccount == null && current.accountSession.available.isEmpty;
    await _accountRepository.beginCloudRegistration(
      account: account,
      importGuestData: shouldImportGuestData,
    );
    final pending = _accountRepository.pendingRegistration();
    if (pending == null) throw const AccountException('账号初始化失败，请重试');
    await _resumePendingRegistration(pending);
    await _activateAccount(pending.account);
    await _accountRepository.finalizeRegistration(pending.account.id);
  });

  Future<void> requestRegistrationCode(String email) =>
      ref.read(cloudAccountServiceProvider).requestRegistrationCode(email);

  Future<void> requestPasswordResetCode(String email) =>
      ref.read(cloudAccountServiceProvider).requestPasswordResetCode(email);

  Future<void> resetAccountPassword({
    required String email,
    required String verificationCode,
    required String newPassword,
  }) => _runAccountOperation(() async {
    final normalizedEmail = email.trim().toLowerCase();
    await ref
        .read(cloudAccountServiceProvider)
        .resetPassword(
          email: normalizedEmail,
          verificationCode: verificationCode,
          newPassword: newPassword,
        );
    if (_activeAccount?.email != normalizedEmail) return;
    await ref.read(cloudAccountServiceProvider).logout();
    await _quiesceDownloadsForAccountChange();
    await _activateAccount(null);
  });

  Future<void> loginAccount({
    required String email,
    required String password,
  }) => _runAccountOperation(() async {
    final account = await ref
        .read(cloudAccountServiceProvider)
        .login(email: email, password: password);
    await _accountRepository.rememberCloudAccount(account);
    await _quiesceDownloadsForAccountChange();
    await _activateAccount(account);
  });

  Future<void> signOutAccount() => _runAccountOperation(() async {
    await ref.read(cloudAccountServiceProvider).logout();
    await _quiesceDownloadsForAccountChange();
    await _activateAccount(null);
  });

  Future<void> changeAccountPassword({
    required String currentPassword,
    required String newPassword,
  }) => _runAccountOperation(() async {
    final account = _activeAccount;
    if (account == null) throw const AccountException('请先登录账号');
    await ref
        .read(cloudAccountServiceProvider)
        .changePassword(
          currentPassword: currentPassword,
          newPassword: newPassword,
        );
  });

  Future<void> deleteCurrentAccount({required String password}) =>
      _runAccountOperation(() async {
        final account = _activeAccount;
        final current = state.value;
        if (account == null || current == null) {
          throw const AccountException('请先登录账号');
        }
        await ref.read(cloudAccountServiceProvider).verifyPassword(password);
        await ref.read(cloudAccountServiceProvider).logout();
        await _quiesceDownloadsForAccountChange();
        final latest = state.value;
        final ownedDownloads = List<MediaDownloadTask>.from(
          latest?.offlineTasks ?? const [],
        );
        final pendingDeletion = await _accountRepository.beginDeletion(
          accountId: account.id,
          taskIds: ownedDownloads.map((task) => task.id),
          paths: ownedDownloads.expand(
            (task) => <String?>[task.temporaryPath, task.localPath],
          ),
        );
        await _activateAccount(null);
        try {
          await _resumePendingDeletion(pendingDeletion);
        } finally {
          final guest = state.value;
          if (guest != null && _activeAccount == null) {
            state = AsyncData(
              guest.copyWith(
                accountSession: LocalAccountSession(
                  available: _accountRepository.listCloudAccounts(),
                  hasPendingCleanup:
                      _accountRepository.pendingDeletion() != null,
                ),
              ),
            );
          }
        }
      });

  Future<void> retryPendingAccountCleanup() => _runAccountOperation(() async {
    final pending = _accountRepository.pendingDeletion();
    if (pending != null) await _resumePendingDeletion(pending);
    final current = state.value;
    if (current == null) return;
    state = AsyncData(
      current.copyWith(
        accountSession: LocalAccountSession(
          current: _activeAccount,
          available: _accountRepository.listCloudAccounts(),
          hasPendingCleanup: _accountRepository.pendingDeletion() != null,
        ),
      ),
    );
  });

  Future<void> updateSettings(PlaybackSettings settings) async {
    final accountId = _activeAccount?.id;
    final current = state.value;
    if (current != null) {
      state = AsyncData(current.copyWith(settings: settings));
    }
    await _settings.put(
      _accountSettingsKeyFor(accountId, 'playback'),
      settings.toJson(),
    );
  }

  Future<void> updateProfile(UserProfileSettings profile) =>
      _runAccountOperation(() async {
        final current = state.value;
        if (current == null) return;
        var normalized = profile;
        var session = current.accountSession;
        final account = _activeAccount;
        if (account != null) {
          final cloudUpdated = await ref
              .read(cloudAccountServiceProvider)
              .updateNickname(profile.nickname);
          final updated = await _accountRepository.rememberCloudAccount(
            cloudUpdated,
          );
          if (_activeAccount?.id != account.id) return;
          _activeAccount = updated;
          normalized = profile.copyWith(
            nickname: updated.nickname,
            uid: updated.shortId,
          );
          session = LocalAccountSession(
            current: updated,
            available: _accountRepository.listCloudAccounts(),
            hasPendingCleanup: _accountRepository.pendingDeletion() != null,
          );
        }
        final latest = state.value;
        if (latest == null) return;
        state = AsyncData(
          latest.copyWith(profile: normalized, accountSession: session),
        );
        await _settings.put(
          _accountSettingsKeyFor(account?.id, 'profile'),
          normalized.toJson(),
        );
      });

  Future<void> updateHomePreferences(HomePreferences preferences) async {
    final accountId = _activeAccount?.id;
    final current = state.value;
    if (current != null) {
      state = AsyncData(current.copyWith(homePreferences: preferences));
    }
    await _settings.put(
      _accountSettingsKeyFor(accountId, 'homePreferences'),
      preferences.toJson(),
    );
  }

  Future<void> updateAppearance(AppearanceSettings settings) async {
    final accountId = _activeAccount?.id;
    final current = state.value;
    if (current != null) {
      state = AsyncData(current.copyWith(appearance: settings));
    }
    await _settings.put(
      _accountSettingsKeyFor(accountId, 'appearance'),
      settings.toJson(),
    );
  }

  Future<void> updateDanmaku(DanmakuSettings settings) async {
    final accountId = _activeAccount?.id;
    final current = state.value;
    if (current != null) state = AsyncData(current.copyWith(danmaku: settings));
    await _settings.put(
      _accountSettingsKeyFor(accountId, 'danmaku'),
      settings.toJson(),
    );
  }

  Future<void> updateMisc(MiscSettings settings) async {
    final accountId = _activeAccount?.id;
    final accountContextVersion = _accountContextVersion;
    final current = state.value;
    if (current != null) state = AsyncData(current.copyWith(misc: settings));
    await _settings.put(
      _accountSettingsKeyFor(accountId, 'misc'),
      settings.toJson(),
    );
    if (accountContextVersion == _accountContextVersion) {
      await WakelockPlus.toggle(
        enable: settings.keepScreenOn,
      ).onError((_, _) {});
    }
  }

  Future<void> updateServices(ExternalServiceSettings settings) async {
    final accountId = _activeAccount?.id;
    final accountContextVersion = _accountContextVersion;
    final normalized = _normalizeServices(settings);
    final current = state.value;
    final changed =
        current != null &&
        _servicesSignature(current.services) != _servicesSignature(normalized);
    if (current != null) {
      state = AsyncData(current.copyWith(services: normalized));
    }
    await _settings.put(
      _accountSettingsKeyFor(accountId, 'services'),
      normalized.toJson(),
    );
    if (changed) {
      _backendLineLookups.clear();
      _backendPlaybackLineCache.clear();
      await Future.wait([
        _library.delete(_homeFeedCacheKey),
        _library.delete(_animeMetadataCacheKey),
        _library.delete(_seriesMetadataCacheKey),
        _library.delete(_movieMetadataCacheKey),
      ]);
      if (accountContextVersion == _accountContextVersion) {
        unawaited(_refreshHomeFeed(normalized).onError((_, _) {}));
      }
    }
  }

  ExternalServiceSettings _normalizeServices(ExternalServiceSettings settings) {
    final backendConfigured =
        ZelunaBackendPlaybackRepository.normalizeBaseUrl(
          settings.playbackBackendEndpoint,
        ) !=
        null;
    return settings.copyWith(
      watchHubEnabled: false,
      mediaMetadataEnabled: true,
      tmdbEnabled: false,
      cinemetaEnabled: false,
      peerTubeEnabled: false,
      wikimediaCommonsEnabled: false,
      anilistEnabled: false,
      jikanEnabled: false,
      kitsuEnabled: false,
      bangumiEnabled: false,
      publicCollectionSyncEnabled: false,
      preferBangumiChinese: true,
      playbackBackendEnabled: backendConfigured,
    );
  }

  void handleBangumiCredentialChanged() {
    _cancelPlaybackPrefetches();
    ref.read(bangumiMetadataRepositoryProvider).resetAccessTokenState();
    ref.read(chineseMetadataRepositoryProvider).clearMemoryCache();
    final current = state.value;
    if (current != null && current.selectedSubjects.isNotEmpty) {
      state = AsyncData(current.copyWith(selectedSubjects: const {}));
    }
  }

  Future<void> handleTmdbCredentialChanged() async {
    ref.read(externalServiceRepositoryProvider).resetTmdbAccessTokenState();
    _homeRefreshVersion++;
    _latestMetadataRefreshes.remove(_seriesMetadataCacheKey);
    _latestMetadataRefreshes.remove(_movieMetadataCacheKey);
    final current = state.value;
    if (current != null && current.selectedSubjects.isNotEmpty) {
      state = AsyncData(current.copyWith(selectedSubjects: const {}));
    }
    await Future.wait([
      _library.delete(_homeFeedCacheKey),
      _library.delete(_seriesMetadataCacheKey),
      _library.delete(_movieMetadataCacheKey),
    ]);
    final services = state.value?.services;
    if (services != null && services.mediaMetadataEnabled) {
      unawaited(_refreshHomeFeed(services).onError((_, _) {}));
    }
  }

  Future<void> invalidateMetadataCache(String kind) {
    final key = switch (kind) {
      'series' => _seriesMetadataCacheKey,
      'movie' => _movieMetadataCacheKey,
      _ => _animeMetadataCacheKey,
    };
    return _library.delete(key);
  }

  Future<void> installRulePlugin(String id) async {
    final current = state.value;
    if (current == null) return;
    final rule = _ruleRepositoryFor(current.rulePlugins).byId(id);
    final installed = {...current.rulePlugins.installedIds, id};
    final enabled = {...current.rulePlugins.enabledIds};
    if (rule?.canResolveNatively ?? false) enabled.add(id);
    await _updateRulePlugins(
      current.rulePlugins.copyWith(
        installedIds: installed,
        enabledIds: enabled,
      ),
    );
  }

  Future<void> uninstallRulePlugin(String id) async {
    final current = state.value;
    if (current == null) return;
    final installed = {...current.rulePlugins.installedIds}..remove(id);
    final enabled = {...current.rulePlugins.enabledIds}..remove(id);
    await _updateRulePlugins(
      current.rulePlugins.copyWith(
        installedIds: installed,
        enabledIds: enabled,
      ),
    );
  }

  Future<void> toggleRulePlugin(String id, bool enabled) async {
    final current = state.value;
    if (current == null || !current.rulePlugins.installedIds.contains(id)) {
      return;
    }
    final enabledIds = {...current.rulePlugins.enabledIds};
    if (enabled) {
      enabledIds.add(id);
    } else {
      enabledIds.remove(id);
    }
    await _updateRulePlugins(
      current.rulePlugins.copyWith(enabledIds: enabledIds),
    );
  }

  Future<void> setInstalledRulePluginsEnabled(
    Iterable<String> ids,
    bool enabled,
  ) async {
    final current = state.value;
    if (current == null) return;
    final targets = ids.toSet().intersection(current.rulePlugins.installedIds);
    if (targets.isEmpty) return;
    final enabledIds = {...current.rulePlugins.enabledIds};
    if (enabled) {
      enabledIds.addAll(targets);
    } else {
      enabledIds.removeAll(targets);
    }
    await _updateRulePlugins(
      current.rulePlugins.copyWith(enabledIds: enabledIds),
    );
  }

  Future<RuleRepositoryRefreshResult> refreshRuleRepositories() async {
    final current = state.value;
    if (current == null) {
      return const RuleRepositoryRefreshResult(
        repositoryCount: 0,
        refreshedCount: 0,
        failedCount: 0,
        ruleCount: 0,
      );
    }

    // Built-in verified rules ship with the app. Refreshing still installs any
    // newly added recommendations without changing the user's existing
    // enable/disable choices.
    await _updateRulePlugins(_installNewRecommendedRules(current.rulePlugins));

    final urls = current.rulePlugins.repositories
        .map((record) => record.url.trim())
        .where((url) => url.isNotEmpty)
        .toSet()
        .toList(growable: false);
    var refreshedCount = 0;
    var failedCount = 0;
    var ruleCount = 0;
    for (final url in urls) {
      try {
        final result = await importRuleRepositoryUrl(url);
        refreshedCount++;
        ruleCount += result.installedCount;
      } catch (_) {
        failedCount++;
      }
    }
    return RuleRepositoryRefreshResult(
      repositoryCount: urls.length,
      refreshedCount: refreshedCount,
      failedCount: failedCount,
      ruleCount: ruleCount,
    );
  }

  Future<void> setAllInstalledRulePluginsEnabled(bool enabled) async {
    final accountId = _activeAccount?.id;
    final current = state.value;
    if (current == null) return;
    final bridge = ref.read(sourceRuleBridgeProvider);
    final rulePlugins = _normalizeRulePlugins(
      current.rulePlugins.copyWith(
        enabledIds: enabled
            ? {...current.rulePlugins.installedIds}
            : <String>{},
      ),
    );
    final toggledCatalog = current.sourceCatalog.copyWith(
      sources: [
        for (final source in current.sourceCatalog.sources)
          current.sourceCatalog.playbackRuleCountFor(source.id) > 0 ||
                  bridge.mayContributePlaybackRules(source)
              ? source.copyWith(enabled: enabled)
              : source,
      ],
      loadError: current.sourceCatalog.loadError,
    );
    final refreshVersion = ++_sourceCatalogRefreshVersion;
    final sourceBridge = bridge.build(toggledCatalog);
    final sourceCatalog = sourceBridge.attachTo(toggledCatalog);
    state = AsyncData(
      current.copyWith(rulePlugins: rulePlugins, sourceCatalog: sourceCatalog),
    );
    await Future.wait([
      _settings.put(
        _accountSettingsKeyFor(accountId, 'rulePlugins'),
        rulePlugins.toJson(),
      ),
      _settings.put(
        _accountSettingsKeyFor(accountId, 'sourceEnabled'),
        sourceCatalog.enabledById,
      ),
    ]);
    await _hydrateAndApplySourceCatalog(toggledCatalog, refreshVersion);
  }

  Future<void> resetRulePlugins() async {
    final current = state.value;
    final customRules =
        current?.rulePlugins.customRules ?? const <RulePlugin>[];
    final repositories =
        current?.rulePlugins.repositories ?? const <RuleRepositoryRecord>[];
    final defaults = RulePluginRepository(
      extraRules: customRules,
    ).defaultState();
    await _updateRulePlugins(
      defaults.copyWith(customRules: customRules, repositories: repositories),
    );
  }

  Future<RuleImportResult> importRuleRepositoryUrl(String url) async {
    final ownerAccountId = _activeAccount?.id;
    final bundle = await const RuleImporter().importFromUrl(url);
    if (_activeAccount?.id != ownerAccountId) {
      throw const AccountException('账号已切换，请在当前账号下重新导入');
    }
    return _importRuleBundle(bundle, ownerAccountId: ownerAccountId);
  }

  Future<RuleImportResult> importRuleRepositoryText(String text) async {
    final ownerAccountId = _activeAccount?.id;
    final bundle = const RuleImporter().importFromText(text);
    return _importRuleBundle(bundle, ownerAccountId: ownerAccountId);
  }

  Future<RuleImportResult> importSelectedRulePlugins({
    required String repositoryName,
    required List<RulePlugin> rules,
    String sourceUrl = '',
  }) {
    final ownerAccountId = _activeAccount?.id;
    return _importRuleBundle(
      RuleImportBundle(
        name: repositoryName,
        rules: List<RulePlugin>.unmodifiable(rules),
        sourceUrl: sourceUrl,
      ),
      ownerAccountId: ownerAccountId,
    );
  }

  Future<void> toggleVideoSource(String id, bool enabled) async {
    await setVideoSourcesEnabled({id}, enabled);
  }

  Future<void> setVideoSourcesEnabled(
    Iterable<String> ids,
    bool enabled,
  ) async {
    final accountId = _activeAccount?.id;
    final current = state.value;
    if (current == null) return;
    final sourceIds = ids.toSet();
    if (sourceIds.isEmpty ||
        !current.sourceCatalog.sources.any(
          (source) => sourceIds.contains(source.id),
        )) {
      return;
    }
    final toggledCatalog = current.sourceCatalog.copyWith(
      sources: [
        for (final source in current.sourceCatalog.sources)
          sourceIds.contains(source.id)
              ? source.copyWith(enabled: enabled)
              : source,
      ],
      loadError: current.sourceCatalog.loadError,
    );
    final refreshVersion = ++_sourceCatalogRefreshVersion;
    final sourceBridge = ref
        .read(sourceRuleBridgeProvider)
        .build(toggledCatalog);
    final sourceCatalog = sourceBridge.attachTo(toggledCatalog);
    state = AsyncData(current.copyWith(sourceCatalog: sourceCatalog));
    await _settings.put(
      _accountSettingsKeyFor(accountId, 'sourceEnabled'),
      sourceCatalog.enabledById,
    );
    await _hydrateAndApplySourceCatalog(toggledCatalog, refreshVersion);
  }

  Future<void> _hydrateAndApplySourceCatalog(
    SourceCatalogState catalog,
    int refreshVersion,
  ) async {
    if (refreshVersion != _sourceCatalogRefreshVersion) return;
    final hydrated = await ref
        .read(sourceRuleBridgeProvider)
        .buildHydrated(catalog);
    if (refreshVersion != _sourceCatalogRefreshVersion) return;
    final current = state.value;
    if (current == null) return;
    state = AsyncData(
      current.copyWith(sourceCatalog: hydrated.attachTo(current.sourceCatalog)),
    );
  }

  Future<void> _updateRulePlugins(RulePluginState rulePlugins) async {
    final accountId = _activeAccount?.id;
    final normalized = _normalizeRulePlugins(rulePlugins);
    final current = state.value;
    if (current != null) {
      state = AsyncData(current.copyWith(rulePlugins: normalized));
    }
    await _settings.put(
      _accountSettingsKeyFor(accountId, 'rulePlugins'),
      normalized.toJson(),
    );
  }

  RulePluginState _normalizeRulePlugins(RulePluginState rulePlugins) {
    final repository = _ruleRepositoryFor(rulePlugins);
    return repository.normalizeState(rulePlugins);
  }

  RulePluginState _restoreRulePlugins(Object? value) {
    if (value is! Map) return const RulePluginRepository().defaultState();
    try {
      return _installNewRecommendedRules(
        _normalizeRulePlugins(
          RulePluginState.fromJson(value.cast<String, dynamic>()),
        ),
      );
    } catch (_) {
      return const RulePluginRepository().defaultState();
    }
  }

  RulePluginState _installNewRecommendedRules(RulePluginState state) {
    final repository = _ruleRepositoryFor(state);
    final defaults = repository.defaultState();
    final missing = defaults.installedIds.difference(state.installedIds);
    if (missing.isEmpty) return state;
    return repository.normalizeState(
      state.copyWith(
        installedIds: {...state.installedIds, ...missing},
        enabledIds: {
          ...state.enabledIds,
          ...defaults.enabledIds.intersection(missing),
        },
      ),
    );
  }

  Future<RuleImportResult> _importRuleBundle(
    RuleImportBundle bundle, {
    required String? ownerAccountId,
  }) async {
    if (_activeAccount?.id != ownerAccountId) {
      throw const AccountException('账号已切换，请在当前账号下重新导入');
    }
    if (bundle.rules.isEmpty) {
      return RuleImportResult(
        repositoryName: bundle.name,
        ruleCount: 0,
        installedCount: 0,
      );
    }
    final current = state.value;
    if (current == null) {
      return RuleImportResult(
        repositoryName: bundle.name,
        ruleCount: bundle.rules.length,
        installedCount: 0,
      );
    }
    final existing = {
      for (final rule in current.rulePlugins.customRules) rule.id: rule,
    };
    for (final rule in bundle.rules) {
      existing[rule.id] = rule;
    }
    final mergedCustomRules = existing.values.toList(growable: false);
    final mergedRepository = RulePluginRepository(
      extraRules: mergedCustomRules,
    );
    final effectiveRuleIds = <String>{};
    for (final rule in bundle.rules) {
      final effectiveRule = mergedRepository.byId(rule.id);
      if (effectiveRule != null) effectiveRuleIds.add(effectiveRule.id);
    }
    final installed = {
      ...current.rulePlugins.installedIds,
      ...effectiveRuleIds,
    };
    final enabled = {...current.rulePlugins.enabledIds};
    final repositoryRecord = RuleRepositoryRecord(
      id: bundle.sourceUrl.trim().isEmpty
          ? 'clipboard:${DateTime.now().microsecondsSinceEpoch}'
          : 'url:${_stableRuleRepositoryId(bundle.sourceUrl)}',
      name: bundle.name,
      url: bundle.sourceUrl,
      importedAt: DateTime.now(),
      ruleCount: effectiveRuleIds.length,
    );
    final repositories = [
      repositoryRecord,
      ...current.rulePlugins.repositories.where(
        (record) =>
            record.id != repositoryRecord.id &&
            (bundle.sourceUrl.trim().isEmpty ||
                record.url.trim() != bundle.sourceUrl.trim()),
      ),
    ];
    if (_activeAccount?.id != ownerAccountId) {
      throw const AccountException('账号已切换，请在当前账号下重新导入');
    }
    await _updateRulePlugins(
      current.rulePlugins.copyWith(
        installedIds: installed,
        enabledIds: enabled,
        customRules: mergedCustomRules,
        repositories: repositories,
      ),
    );
    return RuleImportResult(
      repositoryName: bundle.name,
      ruleCount: bundle.rules.length,
      installedCount: effectiveRuleIds.length,
    );
  }

  RulePluginRepository _ruleRepositoryFor(RulePluginState state) {
    return RulePluginRepository(extraRules: state.customRules);
  }

  Future<bool> toggleFavorite(AnimeSubject subject) async {
    final current = state.value;
    if (current == null) return false;
    final next = _toggleSubject(current.favorites, subject);
    state = AsyncData(current.copyWith(favorites: next));
    await _writeEntries('favorites', next);
    return next.any((item) => sameSubjectIdentity(item.subject, subject));
  }

  Future<bool> toggleFollowing(AnimeSubject subject) async {
    final current = state.value;
    if (current == null) return false;
    final next = _toggleSubject(current.following, subject);
    state = AsyncData(current.copyWith(following: next));
    await _writeEntries('following', next);
    return next.any((item) => sameSubjectIdentity(item.subject, subject));
  }

  Future<bool> addHistory(
    AnimeSubject subject,
    AnimeEpisode? episode, {
    int? expectedAccountContextVersion,
  }) async {
    final accountContextVersion =
        expectedAccountContextVersion ?? _accountContextVersion;
    if (!isAccountContextCurrent(accountContextVersion)) return false;
    final current = state.value;
    if (current == null) return false;
    final next = [
      LibraryEntry(
        subject: subject,
        episode: episode,
        updatedAt: DateTime.now(),
        note: episode == null ? '打开详情' : '播放到 ${episode.displayTitle}',
      ),
      ...current.history.where(
        (item) => !sameSubjectIdentity(item.subject, subject),
      ),
    ].take(80).toList();
    state = AsyncData(current.copyWith(history: next));
    await _writeEntries('history', next);
    await ref
        .read(externalServiceRepositoryProvider)
        .syncLocalHistory(subject, episode, current.services);
    return isAccountContextCurrent(accountContextVersion);
  }

  /// Persists the in-episode playback position onto the matching history
  /// entry. Near-complete positions (>=98% or within the final 15s) reset to
  /// zero so "continue watching" never resumes into credits.
  Future<void> updatePlaybackProgress(
    AnimeSubject subject,
    AnimeEpisode episode, {
    required Duration position,
    required Duration duration,
    int? expectedAccountContextVersion,
  }) async {
    final accountContextVersion =
        expectedAccountContextVersion ?? _accountContextVersion;
    if (!isAccountContextCurrent(accountContextVersion)) return;
    final current = state.value;
    if (current == null) return;
    var positionSeconds = position.inSeconds;
    final durationSeconds = duration.inSeconds;
    if (positionSeconds < 5) return;
    if (durationSeconds > 0 &&
        (positionSeconds >= durationSeconds - 15 ||
            positionSeconds / durationSeconds >= 0.98)) {
      positionSeconds = 0;
    }
    var changed = false;
    final next = current.history
        .map((item) {
          if (!sameSubjectIdentity(item.subject, subject) ||
              item.episode?.id != episode.id) {
            return item;
          }
          changed = true;
          return item.copyWith(
            positionSeconds: positionSeconds,
            durationSeconds: durationSeconds,
            updatedAt: DateTime.now(),
          );
        })
        .toList(growable: false);
    if (!changed) return;
    state = AsyncData(current.copyWith(history: next));
    await _writeEntries('history', next);
  }

  Future<String> queueOffline(
    AnimeSubject subject,
    AnimeEpisode? episode,
  ) async {
    final current = state.value;
    if (current == null) return '应用状态尚未准备好';
    if (episode == null) return '当前条目没有可下载的集数';
    if (!supportsOfflineDownloads) {
      return '网页版暂不支持离线下载，请使用桌面或移动客户端';
    }
    final existing = current.offlineTasks
        .where(
          (item) =>
              sameSubjectIdentity(item.subject, subject) &&
              item.episode.id == episode.id,
        )
        .firstOrNull;
    if (existing != null) {
      if (existing.isActive) return '该集已经在下载队列中';
      if (existing.isPlayable &&
          await ref
              .read(mediaDownloadServiceProvider)
              .fileExists(existing.localPath)) {
        return '该集已经下载完成';
      }
      await resumeDownload(existing.id);
      return '已重新开始下载';
    }
    final now = DateTime.now();
    final task = MediaDownloadTask(
      id: now.microsecondsSinceEpoch.toString(),
      subject: subject,
      episode: episode,
      createdAt: now,
      updatedAt: now,
      status: MediaDownloadTaskStatus.resolving,
      message: '正在查找可下载线路',
    );
    final next = [task, ...current.offlineTasks];
    state = AsyncData(current.copyWith(offlineTasks: next));
    await _persistDownloadTasksNow();
    unawaited(_launchDownload(task.id));
    return '已加入下载队列';
  }

  bool get supportsOfflineDownloads =>
      ref.read(mediaDownloadServiceProvider).supportsDownloads;

  Future<void> pauseDownload(String taskId) async {
    final task = _downloadTask(taskId);
    if (task == null || !task.isActive) return;
    ref.read(mediaDownloadServiceProvider).pause(taskId);
    _replaceDownloadTask(
      task.copyWith(
        status: MediaDownloadTaskStatus.paused,
        updatedAt: DateTime.now(),
        message: '下载已暂停',
      ),
    );
    await _persistDownloadTasksNow();
  }

  Future<void> resumeDownload(String taskId) async {
    if (!supportsOfflineDownloads) return;
    var task = _downloadTask(taskId);
    if (task == null || task.isActive) return;
    final finishingRun = _downloadRuns[taskId];
    if (finishingRun != null) {
      await finishingRun;
      task = _downloadTask(taskId);
      if (task == null || task.isActive) return;
    }
    final service = ref.read(mediaDownloadServiceProvider);
    if (task.isPlayable && await service.fileExists(task.localPath)) return;
    if (task.status == MediaDownloadTaskStatus.cancelled ||
        (task.status == MediaDownloadTaskStatus.completed &&
            !await service.fileExists(task.localPath))) {
      await service.deleteFiles([task.temporaryPath, task.localPath]);
      task = task.copyWith(
        downloadedBytes: 0,
        totalBytes: 0,
        completedUnits: 0,
        totalUnits: 0,
        temporaryPath: null,
        localPath: null,
        etag: null,
        lastModified: null,
        url: null,
        lineId: null,
        providerName: null,
        format: null,
        headers: const {},
      );
    }
    task = task.copyWith(
      status: MediaDownloadTaskStatus.queued,
      updatedAt: DateTime.now(),
      message: task.downloadedBytes > 0 ? '等待继续下载' : '等待下载',
    );
    _replaceDownloadTask(task);
    await _persistDownloadTasksNow();
    unawaited(_launchDownload(taskId, preferStoredLine: task.url != null));
  }

  Future<void> cancelDownload(String taskId) async {
    final task = _downloadTask(taskId);
    if (task == null || task.status == MediaDownloadTaskStatus.completed) {
      return;
    }
    final service = ref.read(mediaDownloadServiceProvider);
    final stoppedActiveDownload = service.cancel(taskId);
    if (!stoppedActiveDownload) {
      await service.deleteFiles([task.temporaryPath]);
    }
    _replaceDownloadTask(
      task.copyWith(
        status: MediaDownloadTaskStatus.cancelled,
        updatedAt: DateTime.now(),
        downloadedBytes: 0,
        totalBytes: 0,
        completedUnits: 0,
        totalUnits: 0,
        temporaryPath: null,
        localPath: null,
        etag: null,
        lastModified: null,
        message: '下载已取消',
      ),
    );
    await _persistDownloadTasksNow();
  }

  Future<void> removeDownload(String taskId) async {
    var task = _downloadTask(taskId);
    if (task == null) return;
    final service = ref.read(mediaDownloadServiceProvider);
    final paths = <String?>[task.temporaryPath, task.localPath];
    if (task.status != MediaDownloadTaskStatus.completed) {
      await cancelDownload(taskId);
      task = _downloadTask(taskId) ?? task;
      paths.addAll([task.temporaryPath, task.localPath]);
    }
    final run = _downloadRuns[taskId];
    final current = state.value;
    if (current == null) return;
    state = AsyncData(
      current.copyWith(
        offlineTasks: current.offlineTasks
            .where((item) => item.id != taskId)
            .toList(growable: false),
      ),
    );
    await _persistDownloadTasksNow();
    Future<void> cleanup() async {
      if (run != null) await run;
      await service.deleteFiles(paths);
    }

    if (run == null) {
      await cleanup();
    } else {
      unawaited(cleanup().onError((_, _) {}));
    }
  }

  Future<void> _launchDownload(String taskId, {bool preferStoredLine = false}) {
    final active = _downloadRuns[taskId];
    if (active != null) return active;
    final run = () async {
      try {
        await _performDownload(taskId, preferStoredLine: preferStoredLine);
      } catch (_) {
        final task = _downloadTask(taskId);
        if (task != null &&
            task.status != MediaDownloadTaskStatus.cancelled &&
            task.status != MediaDownloadTaskStatus.paused) {
          _replaceDownloadTask(
            task.copyWith(
              status: MediaDownloadTaskStatus.failed,
              updatedAt: DateTime.now(),
              message: '下载失败，可稍后重试',
            ),
          );
          await _persistDownloadTasksNow();
        }
      } finally {
        _downloadRuns.remove(taskId);
      }
    }();
    _downloadRuns[taskId] = run;
    return run;
  }

  Future<void> _performDownload(
    String taskId, {
    required bool preferStoredLine,
  }) async {
    var task = _downloadTask(taskId);
    if (task == null ||
        task.status == MediaDownloadTaskStatus.paused ||
        task.status == MediaDownloadTaskStatus.cancelled) {
      return;
    }

    MediaDownloadResult? lastResult;
    if (preferStoredLine && task.url?.trim().isNotEmpty == true) {
      final storedLine = PlaybackLine(
        id: task.lineId ?? 'download:${task.id}',
        episodeId: task.episode.id,
        providerId: task.lineId ?? 'download',
        providerName: task.providerName ?? '已保存线路',
        title: task.providerName ?? '已保存线路',
        quality: '离线下载',
        format: task.format ?? 'MP4',
        url: task.url,
        headers: task.headers,
        available: true,
      );
      lastResult = await _downloadLine(taskId, storedLine);
      if (lastResult.success || lastResult.paused || lastResult.cancelled) {
        return;
      }
    }

    task = _downloadTask(taskId);
    if (task == null ||
        task.status == MediaDownloadTaskStatus.paused ||
        task.status == MediaDownloadTaskStatus.cancelled) {
      return;
    }
    _replaceDownloadTask(
      task.copyWith(
        status: MediaDownloadTaskStatus.resolving,
        updatedAt: DateTime.now(),
        message: lastResult == null ? '正在查找可下载线路' : '当前线路失败，正在换线',
      ),
    );
    await _persistDownloadTasksNow();

    List<PlaybackLine> lines;
    try {
      lines = await linesForEpisodeMode(
        task.subject,
        task.episode,
        expandAll: true,
      );
    } catch (_) {
      final latest = _downloadTask(taskId);
      if (latest == null ||
          latest.status == MediaDownloadTaskStatus.paused ||
          latest.status == MediaDownloadTaskStatus.cancelled) {
        return;
      }
      _replaceDownloadTask(
        latest.copyWith(
          status: MediaDownloadTaskStatus.failed,
          updatedAt: DateTime.now(),
          message: '查找下载线路失败，请稍后重试',
        ),
      );
      await _persistDownloadTasksNow();
      return;
    }

    final candidates = [
      ...singleFileDownloadCandidates(lines),
      ...hlsDownloadCandidates(lines),
    ].where((line) => line.url != task!.url).toList(growable: false);
    if (candidates.isEmpty) {
      final latest = _downloadTask(taskId);
      if (latest == null ||
          latest.status == MediaDownloadTaskStatus.paused ||
          latest.status == MediaDownloadTaskStatus.cancelled) {
        return;
      }
      final onlySegmented = lines.any(
        (line) => line.available && isSegmentedDownloadLine(line),
      );
      _replaceDownloadTask(
        latest.copyWith(
          status: MediaDownloadTaskStatus.failed,
          updatedAt: DateTime.now(),
          message: onlySegmented
              ? '当前只找到 DASH 或不受支持的分片线路'
              : (lastResult?.message ?? '没有找到可直接下载的单文件线路'),
        ),
      );
      await _persistDownloadTasksNow();
      return;
    }

    for (var index = 0; index < candidates.length; index++) {
      final latest = _downloadTask(taskId);
      if (latest == null ||
          latest.status == MediaDownloadTaskStatus.paused ||
          latest.status == MediaDownloadTaskStatus.cancelled) {
        return;
      }
      if (lastResult != null ||
          (latest.url != null && latest.url != candidates[index].url)) {
        await _discardPartialDownload(latest);
      }
      lastResult = await _downloadLine(taskId, candidates[index]);
      if (lastResult.success || lastResult.paused || lastResult.cancelled) {
        return;
      }
      if (index + 1 < candidates.length) {
        final failed = _downloadTask(taskId);
        if (failed != null) {
          _replaceDownloadTask(
            failed.copyWith(
              status: MediaDownloadTaskStatus.resolving,
              updatedAt: DateTime.now(),
              message: '${failed.providerName ?? '当前线路'}失败，正在尝试下一条',
            ),
          );
          await _persistDownloadTasksNow();
        }
      }
    }

    final failed = _downloadTask(taskId);
    if (failed != null &&
        failed.status != MediaDownloadTaskStatus.paused &&
        failed.status != MediaDownloadTaskStatus.cancelled) {
      _replaceDownloadTask(
        failed.copyWith(
          status: MediaDownloadTaskStatus.failed,
          updatedAt: DateTime.now(),
          message: lastResult?.message ?? '所有单文件线路都下载失败',
        ),
      );
      await _persistDownloadTasksNow();
    }
  }

  Future<MediaDownloadResult> _downloadLine(
    String taskId,
    PlaybackLine line,
  ) async {
    var task = _downloadTask(taskId)!;
    task = task.copyWith(
      status: MediaDownloadTaskStatus.downloading,
      updatedAt: DateTime.now(),
      lineId: line.id,
      providerName: line.providerName,
      format: line.format,
      url: line.url,
      headers: line.headers,
      message: '正在通过 ${line.providerName} 下载',
    );
    _replaceDownloadTask(task);
    await _persistDownloadTasksNow();

    final service = ref.read(mediaDownloadServiceProvider);
    final producedPaths = <String?>{task.temporaryPath, task.localPath};
    final result = await service.download(
      taskId: taskId,
      url: line.url!,
      title: '${task.subject.title}_EP${task.episode.number}',
      headers: line.headers,
      format: line.format,
      temporaryPath: task.temporaryPath,
      targetPath: task.localPath,
      etag: task.etag,
      lastModified: task.lastModified,
      onProgress: (progress) {
        producedPaths
          ..add(progress.temporaryPath)
          ..add(progress.targetPath);
        _updateDownloadProgress(taskId, progress);
      },
    );
    final latest = _downloadTask(taskId);
    if (latest == null || latest.status == MediaDownloadTaskStatus.cancelled) {
      await service.deleteFiles({
        ...producedPaths,
        result.temporaryPath,
        result.path,
      });
      return result;
    }
    if (latest.status == MediaDownloadTaskStatus.paused) return result;
    final nextStatus = switch (result.outcome) {
      MediaDownloadOutcome.completed => MediaDownloadTaskStatus.completed,
      MediaDownloadOutcome.paused => MediaDownloadTaskStatus.paused,
      MediaDownloadOutcome.cancelled => MediaDownloadTaskStatus.cancelled,
      MediaDownloadOutcome.failed ||
      MediaDownloadOutcome.unsupported => MediaDownloadTaskStatus.failed,
    };
    _replaceDownloadTask(
      latest.copyWith(
        status: nextStatus,
        updatedAt: DateTime.now(),
        downloadedBytes: result.cancelled ? 0 : result.bytes,
        totalBytes: result.cancelled ? 0 : result.totalBytes,
        completedUnits: result.cancelled ? 0 : result.completedUnits,
        totalUnits: result.cancelled ? 0 : result.totalUnits,
        temporaryPath: result.cancelled ? null : result.temporaryPath,
        localPath: result.success ? result.path : latest.localPath,
        etag: result.cancelled ? null : result.etag,
        lastModified: result.cancelled ? null : result.lastModified,
        message: result.message,
      ),
    );
    await _persistDownloadTasksNow();
    return result;
  }

  void _updateDownloadProgress(String taskId, MediaDownloadProgress progress) {
    final task = _downloadTask(taskId);
    if (task == null || task.status != MediaDownloadTaskStatus.downloading) {
      return;
    }
    _replaceDownloadTask(
      task.copyWith(
        updatedAt: DateTime.now(),
        downloadedBytes: progress.downloadedBytes,
        totalBytes: progress.totalBytes,
        completedUnits: progress.completedUnits,
        totalUnits: progress.totalUnits,
        temporaryPath: progress.temporaryPath,
        localPath: progress.targetPath.trim().isEmpty
            ? task.localPath
            : progress.targetPath,
        etag: progress.etag,
        lastModified: progress.lastModified,
      ),
    );
    _scheduleDownloadPersist(taskId);
  }

  Future<void> _discardPartialDownload(MediaDownloadTask task) async {
    await ref.read(mediaDownloadServiceProvider).deleteFiles([
      task.temporaryPath,
      task.localPath,
    ]);
    final latest = _downloadTask(task.id);
    if (latest == null) return;
    _replaceDownloadTask(
      latest.copyWith(
        downloadedBytes: 0,
        totalBytes: 0,
        completedUnits: 0,
        totalUnits: 0,
        temporaryPath: null,
        localPath: null,
        etag: null,
        lastModified: null,
      ),
    );
    await _persistDownloadTasksNow();
  }

  Future<void> addImageFavorite(AnimeSubject subject) async {
    final current = state.value;
    if (current == null) return;
    final next = [
      LibraryEntry(subject: subject, updatedAt: DateTime.now(), note: '收藏封面图'),
      ...current.imageFavorites.where(
        (item) => !sameSubjectIdentity(item.subject, subject),
      ),
    ].take(80).toList();
    state = AsyncData(current.copyWith(imageFavorites: next));
    await _writeEntries('imageFavorites', next);
  }

  Future<void> clearLibrary(String key) async {
    final current = state.value;
    if (current == null) return;
    switch (key) {
      case 'history':
        state = AsyncData(current.copyWith(history: const []));
        break;
      case 'offlineTasks':
        state = AsyncData(current.copyWith(offlineTasks: const []));
        break;
      case 'imageFavorites':
        state = AsyncData(current.copyWith(imageFavorites: const []));
        break;
      case 'feedbacks':
        state = AsyncData(current.copyWith(feedbacks: const []));
        break;
      default:
        return;
    }
    await _library.put(_accountLibraryKey(key), const []);
  }

  Future<void> submitFeedback({
    required String title,
    required String content,
    AnimeSubject? subject,
  }) async {
    final accountId = _activeAccount?.id;
    final current = state.value;
    if (current == null) return;
    final now = DateTime.now();
    final feedback = LocalFeedback(
      id: now.microsecondsSinceEpoch.toString(),
      title: title.trim().isEmpty ? '未命名反馈' : title.trim(),
      content: content.trim(),
      createdAt: now,
      subject: subject,
    );
    final next = [feedback, ...current.feedbacks].take(80).toList();
    state = AsyncData(current.copyWith(feedbacks: next));
    await _library.put(
      _accountLibraryKeyFor(accountId, 'feedbacks'),
      next.map((item) => item.toJson()).toList(),
    );
  }

  _HomeFeedCacheSnapshot _readHomeFeedCache(String signature) {
    final value = _library.get(_homeFeedCacheKey);
    if (value is! Map) return const _HomeFeedCacheSnapshot();
    final version = value['version'];
    if (version != _homeFeedCacheVersion ||
        value['signature']?.toString() != signature) {
      return const _HomeFeedCacheSnapshot();
    }
    final feedJson = value['feed'];
    if (feedJson is! Map) return const _HomeFeedCacheSnapshot();
    try {
      final feed = AnimeHomeFeed.fromJson(feedJson.cast<String, dynamic>());
      final fetchedAt = DateTime.tryParse(value['fetchedAt']?.toString() ?? '');
      final age = fetchedAt == null
          ? null
          : DateTime.now().toUtc().difference(fetchedAt.toUtc());
      final fresh = age != null && !age.isNegative && age <= _homeFeedCacheTtl;
      return _HomeFeedCacheSnapshot(feed: feed, fresh: fresh);
    } catch (_) {
      return const _HomeFeedCacheSnapshot();
    }
  }

  Future<void> _refreshHomeFeed(ExternalServiceSettings services) async {
    final refreshVersion = ++_homeRefreshVersion;
    final repository = _backendCatalogRepository();
    if (repository == null) return;
    final groups =
        await Future.wait([
          repository.home(SubjectContentType.anime),
          repository.home(SubjectContentType.series),
          repository.home(SubjectContentType.movie),
        ]).onError(
          (_, _) => const [
            <AnimeSubject>[],
            <AnimeSubject>[],
            <AnimeSubject>[],
          ],
        );
    final anime = _uniqueSubjects(groups[0]);
    if (anime.isEmpty || refreshVersion != _homeRefreshVersion) return;
    final categories = <String, AnimeCategory>{};
    for (final subject in anime) {
      for (final category in subject.categories) {
        categories.putIfAbsent(category.name, () => category);
      }
    }
    final feed = AnimeHomeFeed(
      hero: anime.first,
      recent: anime.take(24).toList(growable: false),
      recommended: anime.skip(8).take(24).toList(growable: false),
      index: anime,
      categories: categories.values.toList(growable: false),
      tags: const [],
      seriesHighlights: _uniqueSubjects(groups[1]),
      movieHighlights: _uniqueSubjects(groups[2]),
    );
    if (refreshVersion != _homeRefreshVersion) return;
    await _library.put(_homeFeedCacheKey, {
      'version': _homeFeedCacheVersion,
      'signature': _servicesSignature(services),
      'fetchedAt': DateTime.now().toUtc().toIso8601String(),
      'feed': feed.toJson(),
    });
    final current = state.value;
    if (current != null) {
      state = AsyncData(current.copyWith(homeFeed: feed));
    }
  }

  Future<void> _activateAccount(LocalAccount? account) async {
    final accountId = account?.id;
    final settingsJson = _settings.get(
      _accountSettingsKeyFor(accountId, 'playback'),
    );
    final profileJson = _settings.get(
      _accountSettingsKeyFor(accountId, 'profile'),
    );
    final homeJson = _settings.get(
      _accountSettingsKeyFor(accountId, 'homePreferences'),
    );
    final appearanceJson = _settings.get(
      _accountSettingsKeyFor(accountId, 'appearance'),
    );
    final danmakuJson = _settings.get(
      _accountSettingsKeyFor(accountId, 'danmaku'),
    );
    final miscJson = _settings.get(_accountSettingsKeyFor(accountId, 'misc'));
    final servicesJson = _settings.get(
      _accountSettingsKeyFor(accountId, 'services'),
    );
    final rulePluginsJson = _settings.get(
      _accountSettingsKeyFor(accountId, 'rulePlugins'),
    );
    final misc = miscJson is Map
        ? MiscSettings.fromJson(miscJson.cast<String, dynamic>())
        : const MiscSettings();
    final services = _normalizeServices(
      servicesJson is Map
          ? ExternalServiceSettings.fromJson(
              servicesJson.cast<String, dynamic>(),
            )
          : const ExternalServiceSettings(),
    );
    final rulePlugins = _restoreRulePlugins(rulePluginsJson);
    const sourceCatalog = SourceCatalogState();
    final offlineTasks = await _readDownloadTasksFor(accountId);
    final current = state.value;
    if (current == null) return;
    await _accountRepository.setActiveAccount(accountId);
    _activeAccount = account;
    ref.read(_bangumiCredentialAccountContextProvider).selectAccount(accountId);
    ref.read(_tmdbCredentialAccountContextProvider).selectAccount(accountId);
    ref.read(bangumiMetadataRepositoryProvider).resetAccessTokenState();
    ref.read(externalServiceRepositoryProvider).resetTmdbAccessTokenState();
    _accountContextVersion++;
    RulePlaybackSourceRepository.clearRuntimeCaches();
    ref.read(rulePlaybackResolverProvider).clearCaches();
    ref.read(m3uSourceAdapterProvider).clearCache();
    ref.read(torrentSourceAdapterProvider).clearCache();
    ref.read(sourceRuleBridgeProvider).xbpqHydrator?.clearCache();
    _backendLineLookups.clear();
    _homeRefreshVersion++;
    _sourceCatalogRefreshVersion++;
    _cancelPlaybackPrefetches();
    final session = LocalAccountSession(
      current: account,
      available: _accountRepository.listCloudAccounts(),
      hasPendingCleanup: _accountRepository.pendingDeletion() != null,
    );
    state = AsyncData(
      current.copyWith(
        selectedSubjects: const {},
        settings: settingsJson is Map
            ? PlaybackSettings.fromJson(settingsJson.cast<String, dynamic>())
            : const PlaybackSettings(),
        favorites: _readEntriesFor(accountId, 'favorites'),
        history: _readEntriesFor(accountId, 'history'),
        following: _readEntriesFor(accountId, 'following'),
        offlineTasks: offlineTasks,
        imageFavorites: _readEntriesFor(accountId, 'imageFavorites'),
        feedbacks: _readFeedbacksFor(accountId),
        profile: _profileFromJson(profileJson, account),
        accountSession: session,
        homePreferences: homeJson is Map
            ? HomePreferences.fromJson(homeJson.cast<String, dynamic>())
            : const HomePreferences(),
        appearance: appearanceJson is Map
            ? AppearanceSettings.fromJson(
                appearanceJson.cast<String, dynamic>(),
              )
            : const AppearanceSettings(),
        danmaku: danmakuJson is Map
            ? DanmakuSettings.fromJson(danmakuJson.cast<String, dynamic>())
            : const DanmakuSettings(),
        misc: misc,
        services: services,
        rulePlugins: rulePlugins,
        sourceCatalog: sourceCatalog,
      ),
    );
    await WakelockPlus.toggle(enable: misc.keepScreenOn).onError((_, _) {});
    unawaited(_refreshHomeFeed(services).onError((_, _) {}));
  }

  Future<void> _resumePendingRegistration(
    PendingLocalAccountRegistration pending,
  ) async {
    final accountId = pending.account.id;
    if (pending.importGuestData) {
      await _settings.put(_pendingBangumiCredentialMigrationKey, accountId);
      try {
        await ref
            .read(bangumiCredentialStoreProvider)
            .migrateGuestToAccount(accountId);
        await _settings.delete(_pendingBangumiCredentialMigrationKey);
      } catch (_) {
        // Registration remains usable. A non-secret pending marker retries
        // the secure-store migration on the next startup.
      }
      await _settings.put(_pendingTmdbCredentialMigrationKey, accountId);
      try {
        await ref
            .read(tmdbCredentialStoreProvider)
            .migrateGuestToAccount(accountId);
        await _settings.delete(_pendingTmdbCredentialMigrationKey);
      } catch (_) {
        // Keep registration usable and retry the non-secret marker later.
      }
      for (final key in _accountSettingKeys) {
        if (key == 'profile') continue;
        final value = _settings.get(key);
        final target = _accountSettingsKeyFor(accountId, key);
        if (value != null && !_settings.containsKey(target)) {
          await _settings.put(target, value);
        }
      }
      for (final key in _accountLibraryKeys) {
        final value = _library.get(key);
        final target = _accountLibraryKeyFor(accountId, key);
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
    await _accountRepository.completeRegistration(accountId);
  }

  Future<void> _resumePendingBangumiCredentialMigration() async {
    final accountId = _settings
        .get(_pendingBangumiCredentialMigrationKey)
        ?.toString()
        .trim();
    if (accountId == null || accountId.isEmpty) return;
    if (_accountRepository.pendingDeletion()?.accountId == accountId) return;
    final pendingRegistration = _accountRepository.pendingRegistration();
    final accountExists = _accountRepository.listCloudAccounts().any(
      (account) => account.id == accountId,
    );
    if (!accountExists && pendingRegistration?.account.id != accountId) {
      await _settings.delete(_pendingBangumiCredentialMigrationKey);
      return;
    }
    await ref
        .read(bangumiCredentialStoreProvider)
        .migrateGuestToAccount(accountId);
    await _settings.delete(_pendingBangumiCredentialMigrationKey);
  }

  Future<void> _resumePendingTmdbCredentialMigration() async {
    final accountId = _settings
        .get(_pendingTmdbCredentialMigrationKey)
        ?.toString()
        .trim();
    if (accountId == null || accountId.isEmpty) return;
    if (_accountRepository.pendingDeletion()?.accountId == accountId) return;
    final pendingRegistration = _accountRepository.pendingRegistration();
    final accountExists = _accountRepository.listCloudAccounts().any(
      (account) => account.id == accountId,
    );
    if (!accountExists && pendingRegistration?.account.id != accountId) {
      await _settings.delete(_pendingTmdbCredentialMigrationKey);
      return;
    }
    await ref
        .read(tmdbCredentialStoreProvider)
        .migrateGuestToAccount(accountId);
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

    final downloadService = ref.read(mediaDownloadServiceProvider);
    for (final taskId in pending.taskIds) {
      downloadService.cancel(taskId);
    }
    await attempt(
      () => _accountRepository.deleteAccountRecord(pending.accountId),
    );
    for (final path in pending.paths) {
      await attempt(() => downloadService.deleteFiles([path]));
    }
    for (final key in _accountSettingKeys) {
      await attempt(
        () => _settings.delete(_accountSettingsKeyFor(pending.accountId, key)),
      );
    }
    for (final key in _accountLibraryKeys) {
      await attempt(
        () => _library.delete(_accountLibraryKeyFor(pending.accountId, key)),
      );
    }
    await attempt(
      () => ref
          .read(bangumiCredentialStoreProvider)
          .clearAccount(pending.accountId),
    );
    await attempt(
      () =>
          ref.read(tmdbCredentialStoreProvider).clearAccount(pending.accountId),
    );
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
      await _accountRepository.completeDeletion(pending.accountId);
      return;
    }
    throw const AccountException('账号已退出，但部分本机文件仍在清理；下次启动会自动继续');
  }

  Future<T> _runAccountOperation<T>(Future<T> Function() action) {
    final operation = _accountOperationQueue.then((_) => action());
    _accountOperationQueue = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  Future<void> _quiesceDownloadsForAccountChange() async {
    final activeIds = state.value?.offlineTasks
        .where((task) => task.isActive)
        .map((task) => task.id)
        .toList(growable: false);
    if (activeIds != null) {
      for (final taskId in activeIds) {
        await pauseDownload(taskId);
      }
    }
    await _persistDownloadTasksNow();
    final runs = List<Future<void>>.from(_downloadRuns.values);
    if (runs.isNotEmpty) {
      await Future.wait(
        runs,
      ).timeout(const Duration(seconds: 3), onTimeout: () => const <void>[]);
    }
  }

  UserProfileSettings _profileFromJson(Object? value, LocalAccount? account) {
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

  void _ensureAccountContext(int expectedVersion) {
    if (expectedVersion != _accountContextVersion) {
      throw const AccountException('账号已切换，请重新打开当前内容');
    }
  }

  String _accountSettingsKey(String key) =>
      _accountSettingsKeyFor(_activeAccount?.id, key);

  String _accountLibraryKey(String key) =>
      _accountLibraryKeyFor(_activeAccount?.id, key);

  static String _accountSettingsKeyFor(String? accountId, String key) =>
      accountId == null ? key : 'account.$accountId.$key';

  static String _accountLibraryKeyFor(String? accountId, String key) =>
      accountId == null ? key : 'account.$accountId.$key';

  List<LibraryEntry> _toggleSubject(
    List<LibraryEntry> entries,
    AnimeSubject subject,
  ) {
    final exists = entries.any(
      (item) => sameSubjectIdentity(item.subject, subject),
    );
    if (exists) {
      return entries
          .where((item) => !sameSubjectIdentity(item.subject, subject))
          .toList();
    }
    return [
      LibraryEntry(subject: subject, updatedAt: DateTime.now()),
      ...entries,
    ];
  }

  List<LibraryEntry> _readEntries(String key) {
    return _readEntriesFor(_activeAccount?.id, key);
  }

  List<LibraryEntry> _readEntriesFor(String? accountId, String key) {
    final value = _library.get(_accountLibraryKeyFor(accountId, key));
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map((item) => LibraryEntry.fromJson(item.cast<String, dynamic>()))
        .where((item) => item.subject.title.trim().isNotEmpty)
        .toList();
  }

  Future<List<MediaDownloadTask>> _readDownloadTasks() async {
    return _readDownloadTasksFor(_activeAccount?.id);
  }

  Future<List<MediaDownloadTask>> _readDownloadTasksFor(
    String? accountId,
  ) async {
    final storageKey = _accountLibraryKeyFor(accountId, 'offlineTasks');
    final value = _library.get(storageKey);
    if (value is! List) return const [];
    final tasks = <MediaDownloadTask>[];
    var migrated = false;
    for (final raw in value.whereType<Map>()) {
      final json = raw.cast<String, dynamic>();
      MediaDownloadTask task;
      if (json.containsKey('status') && json.containsKey('id')) {
        task = MediaDownloadTask.fromJson(json);
        final rawHeaders = json['headers'];
        final storedHeaders = rawHeaders is Map
            ? {
                for (final entry in rawHeaders.entries)
                  entry.key.toString(): entry.value.toString(),
              }
            : const <String, String>{};
        final storedUrl = json['url']?.toString().trim() ?? '';
        final storedMessage = json['message']?.toString() ?? '';
        if (json['version'] != 2 ||
            !_sameStringMap(storedHeaders, task.headers) ||
            storedUrl != (task.url ?? '') ||
            storedMessage != task.message) {
          migrated = true;
        }
      } else {
        task = MediaDownloadTask.fromLegacy(LibraryEntry.fromJson(json));
        migrated = true;
      }
      if (task.id.trim().isEmpty ||
          task.subject.title.trim().isEmpty ||
          task.episode.id == 0) {
        migrated = true;
        continue;
      }
      if (task.isActive) {
        task = task.copyWith(
          status: MediaDownloadTaskStatus.paused,
          updatedAt: DateTime.now(),
          message: '上次下载已中断，可以继续下载',
        );
        migrated = true;
      }
      if (task.status == MediaDownloadTaskStatus.completed &&
          !await ref
              .read(mediaDownloadServiceProvider)
              .fileExists(task.localPath)) {
        task = task.copyWith(
          status: MediaDownloadTaskStatus.failed,
          updatedAt: DateTime.now(),
          localPath: null,
          message: '本地文件已不存在，请重新下载',
        );
        migrated = true;
      }
      if (task.downloadedBytes > 0 &&
          task.status != MediaDownloadTaskStatus.completed &&
          !await ref
              .read(mediaDownloadServiceProvider)
              .fileExists(task.temporaryPath)) {
        task = task.copyWith(
          downloadedBytes: 0,
          totalBytes: 0,
          completedUnits: 0,
          totalUnits: 0,
          temporaryPath: null,
          etag: null,
          lastModified: null,
          message: task.status == MediaDownloadTaskStatus.paused
              ? '临时文件已不存在，将重新下载'
              : task.message,
        );
        migrated = true;
      }
      tasks.add(task);
    }
    if (migrated) {
      await _library.put(
        storageKey,
        tasks.map((item) => item.toJson()).toList(),
      );
    }
    return tasks;
  }

  MediaDownloadTask? _downloadTask(String taskId) {
    return state.value?.offlineTasks
        .where((item) => item.id == taskId)
        .firstOrNull;
  }

  void _replaceDownloadTask(MediaDownloadTask task) {
    final current = state.value;
    if (current == null) return;
    final next = current.offlineTasks
        .map((item) => item.id == task.id ? task : item)
        .toList(growable: false);
    state = AsyncData(current.copyWith(offlineTasks: next));
  }

  void _scheduleDownloadPersist(String taskId) {
    final now = DateTime.now();
    final last = _downloadPersistedAt[taskId];
    if (last == null || now.difference(last) >= const Duration(seconds: 1)) {
      _downloadPersistedAt[taskId] = now;
      unawaited(_persistDownloadTasks());
      return;
    }
    if (_downloadPersistTimer?.isActive ?? false) return;
    _downloadPersistTimer = Timer(const Duration(seconds: 1), () {
      _downloadPersistTimer = null;
      unawaited(_persistDownloadTasks());
    });
  }

  Future<void> _persistDownloadTasksNow() {
    _downloadPersistTimer?.cancel();
    _downloadPersistTimer = null;
    return _persistDownloadTasks();
  }

  Future<void> _persistDownloadTasks() {
    final storageKey = _accountLibraryKeyFor(
      _activeAccount?.id,
      'offlineTasks',
    );
    final snapshot = state.value?.offlineTasks
        .map((item) => item.toJson())
        .toList(growable: false);
    if (snapshot == null) return Future<void>.value();
    final operation = _downloadWriteQueue.then(
      (_) => _library.put(storageKey, snapshot),
    );
    _downloadWriteQueue = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  _SubjectCacheSnapshot _readSubjectCache(String key, String signature) {
    final value = _library.get(key);
    if (value is List) return const _SubjectCacheSnapshot();
    if (value is! Map) return const _SubjectCacheSnapshot();
    if (value['version'] != _metadataCacheVersion ||
        value['signature']?.toString() != signature) {
      return const _SubjectCacheSnapshot();
    }
    final rawSubjects = value['subjects'];
    final subjects = rawSubjects is List
        ? rawSubjects
              .whereType<Map>()
              .map(
                (item) => AnimeSubject.fromJson(item.cast<String, dynamic>()),
              )
              .where((item) => item.title.trim().isNotEmpty)
              .toList()
        : const <AnimeSubject>[];
    final fetchedAt = DateTime.tryParse(value['fetchedAt']?.toString() ?? '');
    final refreshCount = switch (value['refreshCount']) {
      final num count => count.toInt(),
      _ => subjects.length,
    };
    final cacheTtl = _isSparseMetadataResult(key, refreshCount)
        ? _sparseMetadataCacheTtl
        : _metadataCacheTtl;
    final fresh =
        value['version'] == _metadataCacheVersion &&
        value['signature']?.toString() == signature &&
        fetchedAt != null &&
        DateTime.now().difference(fetchedAt) <= cacheTtl;
    return _SubjectCacheSnapshot(subjects: subjects, fresh: fresh);
  }

  Future<List<AnimeSubject>> _metadataSubjects({
    required String key,
    required String signature,
    required SubjectContentType contentType,
    required List<AnimeSubject> fallback,
    required bool waitForRefresh,
    required Future<List<AnimeSubject>> Function() load,
  }) async {
    final cached = _readSubjectCache(key, signature);
    final cachedSubjects = _subjectsOfType(cached.subjects, contentType);
    final fallbackSubjects = _subjectsOfType(fallback, contentType);
    final initialSubjects = _uniqueSubjects([
      ...cachedSubjects,
      ...fallbackSubjects,
    ]);
    if (cached.fresh) {
      return initialSubjects;
    }
    final refresh = _refreshSubjectCache(
      key,
      signature,
      load,
    ).onError((_, _) => const <AnimeSubject>[]);
    if (!waitForRefresh) {
      unawaited(refresh);
      return initialSubjects;
    }
    final refreshed = _subjectsOfType(await refresh, contentType);
    if (refreshed.isNotEmpty) {
      return _uniqueSubjects([
        ...refreshed,
        ...cachedSubjects,
        ...fallbackSubjects,
      ]);
    }
    return initialSubjects;
  }

  List<AnimeSubject> _subjectsOfType(
    Iterable<AnimeSubject> subjects,
    SubjectContentType contentType,
  ) {
    return _uniqueSubjects(
      subjects.where(
        (subject) => subjectMatchesContentType(subject, contentType),
      ),
    );
  }

  Future<List<AnimeSubject>> _refreshSubjectCache(
    String key,
    String signature,
    Future<List<AnimeSubject>> Function() load,
  ) {
    final operationKey = '$key\u0000$signature';
    final active = _metadataRefreshes[operationKey];
    if (active != null && identical(_latestMetadataRefreshes[key], active)) {
      return active;
    }
    late final Future<List<AnimeSubject>> task;
    task = () async {
      final refreshed = _uniqueSubjects(await load());
      if (refreshed.isEmpty) return const <AnimeSubject>[];
      final subjects = _uniqueSubjects([
        ...refreshed,
        ..._compatibleCachedSubjects(key, signature),
      ]);
      if (!identical(_latestMetadataRefreshes[key], task)) {
        return const <AnimeSubject>[];
      }
      final payload = {
        'version': _metadataCacheVersion,
        'signature': signature,
        'fetchedAt': DateTime.now().toUtc().toIso8601String(),
        'refreshCount': refreshed.length,
        'subjects': subjects
            .take(_metadataCacheLimit)
            .map((item) => item.toJson())
            .toList(growable: false),
      };
      final write = _metadataWriteQueue.then((_) async {
        if (!identical(_latestMetadataRefreshes[key], task)) return;
        await _library.put(key, payload);
      });
      _metadataWriteQueue = write.then<void>((_) {}, onError: (_, _) {});
      await write;
      return identical(_latestMetadataRefreshes[key], task)
          ? subjects
          : const <AnimeSubject>[];
    }();
    _metadataRefreshes[operationKey] = task;
    _latestMetadataRefreshes[key] = task;
    return task.whenComplete(() {
      if (identical(_metadataRefreshes[operationKey], task)) {
        _metadataRefreshes.remove(operationKey);
      }
      if (identical(_latestMetadataRefreshes[key], task)) {
        _latestMetadataRefreshes.remove(key);
      }
    });
  }

  List<AnimeSubject> _compatibleCachedSubjects(String key, String signature) {
    final value = _library.get(key);
    if (value is! Map ||
        value['version'] != _metadataCacheVersion ||
        value['signature']?.toString() != signature) {
      return const [];
    }
    final rawSubjects = value['subjects'];
    if (rawSubjects is! List) return const [];
    return rawSubjects
        .whereType<Map>()
        .map((item) => AnimeSubject.fromJson(item.cast<String, dynamic>()))
        .where((item) => item.title.trim().isNotEmpty)
        .toList(growable: false);
  }

  bool _isSparseMetadataResult(String key, int count) {
    final expected = switch (key) {
      _animeMetadataCacheKey => 120,
      _seriesMetadataCacheKey => 250,
      _movieMetadataCacheKey => 250,
      _ => 1,
    };
    return count < expected;
  }

  String _metadataSignature(String kind, ExternalServiceSettings services) {
    return '$kind:${_servicesSignature(services)}';
  }

  String _servicesSignature(ExternalServiceSettings services) {
    return [
      services.mediaMetadataEnabled,
      services.tmdbEnabled,
      services.cinemetaEnabled,
      services.anilistEnabled,
      services.jikanEnabled,
      services.kitsuEnabled,
      services.bangumiEnabled,
      services.publicCollectionSyncEnabled,
      services.peerTubeEnabled,
      services.wikimediaCommonsEnabled,
      services.preferBangumiChinese,
    ].join(':');
  }

  List<AnimeSubject> _uniqueSubjects(
    Iterable<AnimeSubject> subjects, {
    bool? preferChinese,
  }) {
    final shouldPreferChinese =
        preferChinese ?? state.value?.services.preferBangumiChinese ?? true;
    final keyToIndex = <String, int>{};
    final unique = <AnimeSubject>[];
    for (final subject in subjects) {
      if (subject.title.trim().isEmpty) continue;
      final keys = _subjectIdentityKeys(subject);
      int? existingIndex;
      for (final key in keys) {
        final index = keyToIndex[key];
        if (index != null) {
          existingIndex = index;
          break;
        }
      }
      if (existingIndex == null) {
        final index = unique.length;
        unique.add(subject);
        for (final key in keys) {
          keyToIndex[key] = index;
        }
        continue;
      }
      final merged = _mergeSubjects(
        unique[existingIndex],
        subject,
        preferChinese: shouldPreferChinese,
      );
      unique[existingIndex] = merged;
      for (final key in _subjectIdentityKeys(merged)) {
        keyToIndex[key] = existingIndex;
      }
    }
    return unique;
  }

  Set<String> _subjectIdentityKeys(AnimeSubject subject) {
    final kind = subjectContentTypeOf(subject).name;
    final year = subject.year == '未知' ? '' : subject.year;
    final titles = <String>{subject.title, subject.originalTitle}
        .map(
          (item) => item.toLowerCase().replaceAll(
            RegExp(r'[^\p{L}\p{N}]', unicode: true),
            '',
          ),
        )
        .where((item) => item.isNotEmpty);
    final keys = titles.map((title) => '$kind:$year:$title').toSet();
    if (keys.isEmpty) keys.add('$kind:$year:${subject.id}');
    return keys;
  }

  AnimeSubject _mergeSubjects(
    AnimeSubject first,
    AnimeSubject second, {
    required bool preferChinese,
  }) {
    final firstDirect = _isDirectPlayable(first);
    final secondDirect = _isDirectPlayable(second);
    final firstBangumi = _isBangumiSubject(first);
    final secondBangumi = _isBangumiSubject(second);
    final primary = firstDirect != secondDirect
        ? (firstDirect ? first : second)
        : _subjectQuality(second) > _subjectQuality(first)
        ? second
        : first;
    final secondary = identical(primary, first) ? second : first;
    final bangumiMetadata =
        preferChinese &&
            !firstDirect &&
            !secondDirect &&
            firstBangumi != secondBangumi &&
            subjectMatchesContentType(first, SubjectContentType.anime) &&
            subjectMatchesContentType(second, SubjectContentType.anime)
        ? (firstBangumi ? first : second)
        : null;
    final displayPrimary = bangumiMetadata ?? primary;
    final displaySecondary = identical(displayPrimary, first) ? second : first;
    final title = !preferChinese
        ? primary.title
        : isLikelyChineseTitle(displayPrimary.title)
        ? displayPrimary.title
        : isLikelyChineseTitle(displaySecondary.title)
        ? displaySecondary.title
        : displayPrimary.title;
    final keepBangumiLabels = bangumiMetadata != null;
    final categories = !preferChinese
        ? primary.categories
        : keepBangumiLabels
        ? displayPrimary.categories
        : <String, AnimeCategory>{
            for (final item in primary.categories) item.name: item,
            for (final item in secondary.categories) item.name: item,
          }.values.take(8).toList(growable: false);
    final tags = !preferChinese
        ? primary.tags
        : keepBangumiLabels
        ? displayPrimary.tags
        : <String, AnimeTag>{
            for (final item in primary.tags) item.name: item,
            for (final item in secondary.tags) item.name: item,
          }.values.take(20).toList(growable: false);
    return AnimeSubject(
      id: primary.id,
      title: title,
      originalTitle: primary.originalTitle.trim().isNotEmpty
          ? primary.originalTitle
          : secondary.originalTitle,
      summary: !preferChinese
          ? primary.summary
          : keepBangumiLabels
          ? _preferredBangumiSummary(
              displayPrimary.summary,
              displaySecondary.summary,
            )
          : _preferredLocalizedText(primary.summary, secondary.summary),
      coverUrl:
          _isDirectPlayable(primary) &&
              secondary.source.startsWith('cinemeta:') &&
              secondary.coverUrl != null
          ? secondary.coverUrl
          : primary.coverUrl ?? secondary.coverUrl,
      bannerUrl: primary.bannerUrl ?? secondary.bannerUrl,
      date: primary.date ?? secondary.date,
      platform: primary.platform,
      language: primary.language.trim().isNotEmpty
          ? primary.language
          : secondary.language,
      region: primary.region.trim().isNotEmpty
          ? primary.region
          : secondary.region,
      status: primary.status.trim().isNotEmpty
          ? primary.status
          : secondary.status,
      categories: categories,
      tags: tags,
      totalEpisodes: primary.totalEpisodes > secondary.totalEpisodes
          ? primary.totalEpisodes
          : secondary.totalEpisodes,
      ratingScore: primary.ratingScore ?? secondary.ratingScore,
      ratingRank: primary.ratingRank ?? secondary.ratingRank,
      ratingTotal: primary.ratingTotal ?? secondary.ratingTotal,
      source: primary.source,
    );
  }

  int _subjectQuality(AnimeSubject subject) {
    var score = 0;
    if ((subject.bannerUrl ?? '').isNotEmpty) score += 16;
    if ((subject.coverUrl ?? '').isNotEmpty) score += 8;
    if (isLikelyChineseTitle(subject.title)) score += 4;
    if (!isMetadataPlaceholder(subject.summary) &&
        subject.summary.length >= 80) {
      score += 3;
    }
    if (subject.ratingScore != null) score += 3;
    if (subject.totalEpisodes > 0) score += 2;
    return score;
  }

  bool _isDirectPlayable(AnimeSubject subject) {
    return subject.source.startsWith('archive:') ||
        subject.source.startsWith('peertube:') ||
        subject.source.startsWith('commons:');
  }

  bool _isBangumiSubject(AnimeSubject subject) {
    final source = subject.source.trim().toLowerCase();
    return source == 'bangumi' || source.startsWith('bangumi:');
  }

  String _preferredLocalizedText(String first, String second) {
    final firstPlaceholder = isMetadataPlaceholder(first);
    final secondPlaceholder = isMetadataPlaceholder(second);
    if (firstPlaceholder != secondPlaceholder) {
      return firstPlaceholder ? second : first;
    }
    final firstChinese = isLikelyChineseText(first);
    final secondChinese = isLikelyChineseText(second);
    if (firstChinese != secondChinese) return firstChinese ? first : second;
    return first.length >= second.length ? first : second;
  }

  String _preferredBangumiSummary(String bangumi, String fallback) {
    if (isLikelyChineseText(bangumi)) return bangumi;
    if (isLikelyChineseText(fallback)) return fallback;
    return isMetadataPlaceholder(bangumi) ? bangumi : '暂无中文简介。';
  }

  List<AnimeSubject> get _homeSubjects {
    final feed = state.value?.homeFeed;
    if (feed == null) return const [];
    return _uniqueSubjects([
      feed.hero,
      ...feed.index,
      ...feed.recommended,
      ...feed.recent,
    ]);
  }

  int _subjectCacheKey(AnimeSubject subject) {
    return Object.hash(subject.source, subject.platform, subject.id);
  }

  Future<void> _writeEntries(String key, List<LibraryEntry> entries) {
    final accountId = _activeAccount?.id;
    return _library.put(
      _accountLibraryKeyFor(accountId, key),
      entries.map((item) => item.toJson()).toList(),
    );
  }

  List<LocalFeedback> _readFeedbacks() {
    return _readFeedbacksFor(_activeAccount?.id);
  }

  List<LocalFeedback> _readFeedbacksFor(String? accountId) {
    final value = _library.get(_accountLibraryKeyFor(accountId, 'feedbacks'));
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map((item) => LocalFeedback.fromJson(item.cast<String, dynamic>()))
        .where((item) => item.title.trim().isNotEmpty)
        .toList();
  }
}

bool _sameStringMap(Map<String, String> left, Map<String, String> right) {
  if (left.length != right.length) return false;
  for (final entry in left.entries) {
    if (right[entry.key] != entry.value) return false;
  }
  return true;
}

String _stableRuleRepositoryId(String value) {
  var hash = 0x811c9dc5;
  for (final codeUnit in value.trim().codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

class _HomeFeedCacheSnapshot {
  const _HomeFeedCacheSnapshot({this.feed, this.fresh = false});

  final AnimeHomeFeed? feed;
  final bool fresh;
}

class _SubjectCacheSnapshot {
  const _SubjectCacheSnapshot({this.subjects = const [], this.fresh = false});

  final List<AnimeSubject> subjects;
  final bool fresh;
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
