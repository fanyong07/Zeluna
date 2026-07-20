import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:wakelock_plus/wakelock_plus.dart';

import '../accounts/local_account_repository.dart';
import '../domain/anime_models.dart';
import '../domain/subject_content_type.dart';
import '../rules/rule_importer.dart';
import '../rules/rule_models.dart';
import '../rules/rule_playback_resolver.dart';
import '../rules/rule_plugin_repository.dart';
import '../rules/tvbox_xbpq_hydrator.dart';
import '../sources/external_source_adapters.dart';
import '../sources/source_catalog_models.dart';
import '../sources/source_catalog_repository.dart';
import '../sources/source_rule_bridge.dart';
import 'bangumi_metadata_repository.dart';
import 'chinese_metadata_repository.dart';
import 'danmaku_repository.dart';
import 'external_service_repository.dart';
import 'media_download_line_selector.dart';
import 'media_download_result.dart';
import 'media_download_service.dart';
import 'media_download_task.dart';
import 'peertube_repository.dart';
import 'playback_source_repository.dart';
import 'wikimedia_commons_repository.dart';

final bangumiMetadataRepositoryProvider = Provider<BangumiMetadataRepository>(
  (ref) => BangumiMetadataRepository(),
);

final playbackSourceRepositoryProvider = Provider<PlaybackSourceRepository>(
  (ref) => const EmptyPlaybackSourceRepository(),
);

final rulePlaybackResolverProvider = Provider<RulePlaybackResolver>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return RulePlaybackResolver(client: client);
});

final internetArchivePlaybackProvider =
    Provider<InternetArchivePlaybackSourceRepository>(
      (ref) => InternetArchivePlaybackSourceRepository(),
    );

final externalServiceRepositoryProvider = Provider<ExternalServiceRepository>(
  (ref) => ExternalServiceRepository(),
);

final danmakuRepositoryProvider = Provider<DanmakuRepository>((ref) {
  final repository = DanmakuRepository();
  ref.onDispose(repository.close);
  return repository;
});

final peerTubeRepositoryProvider = Provider<PeerTubeRepository>(
  (ref) => PeerTubeRepository(),
);

final wikimediaCommonsRepositoryProvider = Provider<WikimediaCommonsRepository>(
  (ref) => WikimediaCommonsRepository(),
);

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
  static const _homeFeedCacheVersion = 2;
  static const _legacyHomeFeedCacheVersion = 1;
  static const _homeFeedCacheTtl = Duration(hours: 1);
  static const _metadataCacheVersion = 9;
  static const _metadataCacheLimit = 1200;
  static const _metadataCacheTtl = Duration(hours: 8);
  static const _sparseMetadataCacheTtl = Duration(minutes: 30);
  static const _sourceCatalogHydrationDelay = Duration(seconds: 1);
  late Box<dynamic> _settings;
  late Box<dynamic> _library;
  late LocalAccountRepository _accountRepository;
  LocalAccount? _activeAccount;
  List<RulePlugin> _sourceCatalogRules = const [];
  int _homeRefreshVersion = 0;
  int _sourceCatalogRefreshVersion = 0;
  int _accountContextVersion = 0;
  final _metadataRefreshes = <String, Future<List<AnimeSubject>>>{};
  final _playbackPrefetches = <String, Future<void>>{};
  final _downloadRuns = <String, Future<void>>{};
  final _downloadPersistedAt = <String, DateTime>{};
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
    final pendingRegistration = _accountRepository.pendingRegistration();
    LocalAccount? recoveredRegistration;
    if (pendingRegistration != null) {
      await _resumePendingRegistration(pendingRegistration);
      recoveredRegistration = pendingRegistration.account;
    }
    _activeAccount =
        recoveredRegistration ?? _accountRepository.currentAccount();
    final accountSession = LocalAccountSession(
      current: _activeAccount,
      available: _accountRepository.listAccounts(),
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
    final sourceEnabledJson = _settings.get(
      _accountSettingsKey('sourceEnabled'),
    );
    final services = servicesJson is Map
        ? ExternalServiceSettings.fromJson(servicesJson.cast<String, dynamic>())
        : const ExternalServiceSettings();
    final bangumiRepository = ref.read(bangumiMetadataRepositoryProvider);
    final cachedHomeFeed = _readHomeFeedCache();
    final feed = cachedHomeFeed.feed ?? bangumiRepository.fallbackHomeFeed();
    final defaultRulePlugins = const RulePluginRepository().defaultState();
    final rulePlugins = rulePluginsJson is Map
        ? _mergeDefaultNativeRules(
            _normalizeRulePlugins(
              RulePluginState.fromJson(rulePluginsJson.cast<String, dynamic>()),
            ),
            defaultRulePlugins,
          )
        : defaultRulePlugins;
    if (rulePluginsJson is Map) {
      await _settings.put(
        _accountSettingsKey('rulePlugins'),
        rulePlugins.toJson(),
      );
    }
    final loadedSourceCatalog = await _loadSourceCatalog(
      _enabledOverridesFromJson(sourceEnabledJson),
    );
    final sourceBridge = ref
        .read(sourceRuleBridgeProvider)
        .build(loadedSourceCatalog);
    _sourceCatalogRules = sourceBridge.rules;
    final sourceCatalog = sourceBridge.attachTo(loadedSourceCatalog);
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
    _scheduleSourceCatalogHydration(loadedSourceCatalog);
    ref.onDispose(() {
      _downloadPersistTimer?.cancel();
    });
    return initialState;
  }

  Future<List<AnimeSubject>> search(String keyword) async {
    if (keyword.trim().isEmpty) return Future.value(const []);
    final query = keyword.trim();
    final services = state.value?.services ?? const ExternalServiceSettings();
    final sourceCatalog =
        state.value?.sourceCatalog ?? const SourceCatalogState();
    final external = ref.read(externalServiceRepositoryProvider);
    final liveSearch = ref
        .read(m3uSourceAdapterProvider)
        .search(sources: sourceCatalog.sources, query: query, limit: 60)
        .onError((_, _) => const SourceAdapterBatch<M3uChannel>());
    final groups = await Future.wait([
      if (services.bangumiEnabled)
        ref
            .read(bangumiMetadataRepositoryProvider)
            .searchSubjects(keyword: query, limit: 48)
            .onError((_, _) => const <AnimeSubject>[]),
      if (services.anilistEnabled)
        external
            .anilistSearch(query, perPage: 24)
            .onError((_, _) => const <AnimeSubject>[]),
      if (services.jikanEnabled)
        external
            .jikanSearch(query, limit: 24)
            .onError((_, _) => const <AnimeSubject>[]),
      if (services.kitsuEnabled)
        external
            .kitsuSearch(query, limit: 20)
            .onError((_, _) => const <AnimeSubject>[]),
      if (services.mediaMetadataEnabled && services.cinemetaEnabled)
        external
            .cinemetaSearch(query)
            .onError((_, _) => const <AnimeSubject>[]),
      if (services.mediaMetadataEnabled)
        external.tvMazeSearch(query).onError((_, _) => const <AnimeSubject>[]),
      if (services.mediaMetadataEnabled)
        external
            .wikidataMovieSearch(query)
            .onError((_, _) => const <AnimeSubject>[]),
      if (services.publicCollectionSyncEnabled)
        external
            .internetArchiveSearch(query, limit: 24)
            .onError((_, _) => const <AnimeSubject>[]),
      if (services.peerTubeEnabled)
        ref
            .read(peerTubeRepositoryProvider)
            .search(query, limit: 24)
            .onError((_, _) => const <AnimeSubject>[]),
      if (services.wikimediaCommonsEnabled)
        ref
            .read(wikimediaCommonsRepositoryProvider)
            .search(query, limit: 24)
            .onError((_, _) => const <AnimeSubject>[]),
    ]);
    final merged = _uniqueSubjects(groups.expand((items) => items));
    final enriched = await _enrichSubjects(
      merged,
      services,
      animeLookupLimit: 24,
    );
    final liveChannels = (await liveSearch).items;
    return List<AnimeSubject>.unmodifiable([
      ...enriched,
      ...liveChannels.map((channel) => channel.toSubject()),
    ]);
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

  Future<List<AnimeSubject>> categorySubjects(String name) {
    return ref.read(bangumiMetadataRepositoryProvider).subjectsByCategory(name);
  }

  Future<List<AnimeSubject>> tagSubjects(String name) {
    return ref.read(bangumiMetadataRepositoryProvider).subjectsByTag(name);
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
        final external = ref.read(externalServiceRepositoryProvider);
        final groups = await Future.wait([
          if (services.bangumiEnabled)
            ref
                .read(bangumiMetadataRepositoryProvider)
                .discoverySubjects()
                .onError((_, _) => const <AnimeSubject>[]),
          if (services.anilistEnabled)
            external
                .anilistTrendingFeed(pages: 3, perPage: 50)
                .onError((_, _) => const <AnimeSubject>[]),
          if (services.jikanEnabled)
            external
                .jikanDiscoveryFeed(pages: 2)
                .onError((_, _) => const <AnimeSubject>[]),
          if (services.kitsuEnabled)
            external
                .kitsuTrendingFeed(pages: 4)
                .onError((_, _) => const <AnimeSubject>[]),
        ]);
        final merged =
            _uniqueSubjects([
                  ..._interleaveSubjectGroups(groups, limitPerRound: 12),
                  ...groups.expand((items) => items),
                  ...subjects,
                ])
                .where(
                  (subject) => subjectMatchesContentType(
                    subject,
                    SubjectContentType.anime,
                  ),
                )
                .toList(growable: false);
        merged.sort((a, b) => _homeRank(b).compareTo(_homeRank(a)));
        return _enrichSubjects(merged, services, animeLookupLimit: 36);
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
        final subjects = await ref
            .read(externalServiceRepositoryProvider)
            .seriesMetadataFeed(
              includeCinemeta: services.cinemetaEnabled,
              cinemetaPages: 6,
              tvMazePages: 3,
            );
        return _enrichSubjects(
          _subjectsOfType(subjects, SubjectContentType.series),
          services,
          animeLookupLimit: 0,
        );
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
        final groups = await Future.wait([
          ref
              .read(externalServiceRepositoryProvider)
              .movieMetadataFeed(
                includeCinemeta:
                    services.mediaMetadataEnabled && services.cinemetaEnabled,
                includeArchive: false,
                cinemetaPages: 6,
              ),
        ]);
        final subjects =
            _uniqueSubjects([
                  ..._interleaveSubjectGroups(groups, limitPerRound: 10),
                  ...groups.expand((items) => items),
                ])
                .where(
                  (subject) => subjectMatchesContentType(
                    subject,
                    SubjectContentType.movie,
                  ),
                )
                .toList(growable: false);
        return _enrichSubjects(subjects, services, animeLookupLimit: 0);
      },
    );
  }

  Future<Map<int, List<AnimeSubject>>> weeklySchedule() {
    final services = state.value?.services ?? const ExternalServiceSettings();
    return _weeklyScheduleWithBudget(services);
  }

  Future<Map<int, List<AnimeSubject>>> _weeklyScheduleWithBudget(
    ExternalServiceSettings services,
  ) async {
    const sourceBudget = Duration(seconds: 5);
    final bangumi = ref.read(bangumiMetadataRepositoryProvider);
    final primary = services.bangumiEnabled
        ? await bangumi
              .weeklySchedule()
              .timeout(
                sourceBudget,
                onTimeout: () => <int, List<AnimeSubject>>{},
              )
              .onError((_, _) => <int, List<AnimeSubject>>{})
        : <int, List<AnimeSubject>>{};
    final schedule = {
      for (var day = 0; day < 7; day++)
        day: _uniqueSubjects(
          (primary[day] ?? const <AnimeSubject>[]).where(
            (subject) =>
                subjectMatchesContentType(subject, SubjectContentType.anime),
          ),
        ).take(36).toList(growable: false),
    };
    if (schedule.values.any((items) => items.isNotEmpty)) return schedule;

    final homeFallback = _scheduleChineseAnime(_homeSubjects);
    if (homeFallback.isNotEmpty) {
      return _groupScheduleSubjects(homeFallback);
    }
    final feed = bangumi.fallbackHomeFeed();
    return _groupScheduleSubjects(
      _scheduleChineseAnime([
        feed.hero,
        ...feed.index,
        ...feed.recommended,
        ...feed.recent,
      ]),
    );
  }

  List<AnimeSubject> _scheduleChineseAnime(Iterable<AnimeSubject> subjects) {
    return _uniqueSubjects(
      subjects.where(
        (subject) =>
            subjectMatchesContentType(subject, SubjectContentType.anime) &&
            _containsChinese(subject.title) &&
            _containsChinese(subject.summary),
      ),
    );
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

  Future<AnimeDetailBundle> detail(AnimeSubject subject) async {
    final accountContextVersion = _accountContextVersion;
    final current = state.value;
    final cacheKey = _subjectCacheKey(subject);
    final cached = current?.selectedSubjects[cacheKey];
    if (cached != null) {
      _prefetchDetailPlayback(cached);
      return cached;
    }
    if (subject.source.startsWith('m3u-channel:')) {
      final channel = await ref
          .read(m3uSourceAdapterProvider)
          .resolveSubject(
            sources:
                state.value?.sourceCatalog.sources ?? const <VideoSource>[],
            subject: subject,
          );
      final detail =
          channel?.toDetailBundle() ??
          AnimeDetailBundle(
            subject: subject,
            episodes: const [],
            characters: const [],
            staff: const [],
            recommendations: const [],
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
      return detail;
    }
    final services = state.value?.services ?? const ExternalServiceSettings();
    final rawDetail = subject.source == 'bangumi'
        ? await ref.read(bangumiMetadataRepositoryProvider).detail(subject.id)
        : await ref
              .read(externalServiceRepositoryProvider)
              .externalDetail(subject);
    final detailSubjects = await _enrichSubjects(
      [
        rawDetail.subject,
        ...rawDetail.recommendations.map((item) => item.subject),
      ],
      services,
      animeLookupLimit: 12,
    );
    final detail = AnimeDetailBundle(
      subject: detailSubjects.first,
      episodes: rawDetail.episodes,
      characters: rawDetail.characters,
      staff: rawDetail.staff,
      recommendations: [
        for (var i = 0; i < rawDetail.recommendations.length; i++)
          AnimeRecommendation(
            subject: detailSubjects[i + 1],
            relation: rawDetail.recommendations[i].relation,
          ),
      ],
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
    _prefetchDetailPlayback(detail);
    return detail;
  }

  void _prefetchDetailPlayback(AnimeDetailBundle detail) {
    if (detail.episodes.isEmpty || !_usesRulePlayback(detail.subject)) return;
    final historyEpisode = state.value?.history
        .where((item) => sameSubjectIdentity(item.subject, detail.subject))
        .map((item) => item.episode)
        .whereType<AnimeEpisode>()
        .firstOrNull;
    final episode =
        historyEpisode != null &&
            detail.episodes.any((item) => item.id == historyEpisode.id)
        ? historyEpisode
        : detail.episodes.first;
    final key =
        '${detail.subject.source}|${detail.subject.id}|'
        '${detail.subject.title}|${episode.id}|${episode.number}';
    if (_playbackPrefetches.containsKey(key)) return;

    late final Future<void> prefetch;
    prefetch = linesForEpisode(detail.subject, episode)
        .then<void>((_) {}, onError: (_, _) {})
        .whenComplete(() {
          if (identical(_playbackPrefetches[key], prefetch)) {
            _playbackPrefetches.remove(key);
          }
        });
    _playbackPrefetches[key] = prefetch;
  }

  bool _usesRulePlayback(AnimeSubject subject) {
    final source = subject.source.toLowerCase();
    return source != 'direct' &&
        !source.startsWith('m3u-channel:') &&
        !source.startsWith('peertube:') &&
        !source.startsWith('archive:') &&
        !source.startsWith('commons:');
  }

  Future<List<PlaybackLine>> linesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode,
  ) {
    return linesForEpisodeMode(subject, episode);
  }

  Future<List<PlaybackLine>> linesForEpisodeMode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    bool expandAll = false,
  }) async {
    final accountContextVersion = _accountContextVersion;
    final accountId = _activeAccount?.id;
    late final List<PlaybackLine> lines;
    if (subject.source.startsWith('m3u-channel:')) {
      lines = await _m3uLinesForEpisode(subject, episode);
    } else if (subject.source.startsWith('peertube:')) {
      final services = state.value?.services ?? const ExternalServiceSettings();
      if (!services.peerTubeEnabled) {
        return const <PlaybackLine>[];
      }
      lines = await ref
          .read(peerTubeRepositoryProvider)
          .linesForEpisode(subject, episode);
    } else if (subject.source.startsWith('archive:')) {
      final services = state.value?.services ?? const ExternalServiceSettings();
      if (!services.publicCollectionSyncEnabled) {
        return const <PlaybackLine>[];
      }
      lines = await ref
          .read(internetArchivePlaybackProvider)
          .linesForEpisode(subject, episode);
    } else if (subject.source.startsWith('commons:')) {
      final services = state.value?.services ?? const ExternalServiceSettings();
      if (!services.wikimediaCommonsEnabled) {
        return const <PlaybackLine>[];
      }
      lines = await ref
          .read(wikimediaCommonsRepositoryProvider)
          .linesForEpisode(subject, episode);
    } else {
      final ruleState =
          state.value?.rulePlugins ??
          const RulePluginRepository().defaultState();
      final catalogRuleIds = _sourceCatalogRules.map((rule) => rule.id).toSet();
      final effectiveRuleState = ruleState.copyWith(
        installedIds: {...ruleState.installedIds, ...catalogRuleIds},
        enabledIds: {...ruleState.enabledIds, ...catalogRuleIds},
      );
      lines = await RulePlaybackSourceRepository(
        repository: RulePluginRepository(
          extraRules: [..._sourceCatalogRules, ...ruleState.customRules],
        ),
        ruleState: effectiveRuleState,
        resolver: ref.read(rulePlaybackResolverProvider),
        cacheNamespace: '${accountId ?? 'guest'}:$accountContextVersion',
      ).linesForEpisodeMode(subject, episode, expandAll: expandAll);
    }
    return accountContextVersion == _accountContextVersion
        ? lines
        : const <PlaybackLine>[];
  }

  Future<List<PlaybackLine>> _m3uLinesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode,
  ) async {
    final channel = await ref
        .read(m3uSourceAdapterProvider)
        .resolveSubject(
          sources: state.value?.sourceCatalog.sources ?? const <VideoSource>[],
          subject: subject,
        );
    if (channel == null) return const <PlaybackLine>[];
    return <PlaybackLine>[channel.toPlaybackLine(episodeId: episode.id)];
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
  }) => _runAccountOperation(() async {
    final current = state.value;
    if (current == null) throw const AccountException('应用状态尚未准备好');
    _accountRepository.validateNewAccount(
      email: email,
      nickname: nickname,
      password: password,
    );
    await _quiesceDownloadsForAccountChange();
    await _settings.flush();
    await _library.flush();
    final shouldImportGuestData =
        _activeAccount == null && current.accountSession.available.isEmpty;
    await _accountRepository.beginRegistration(
      email: email,
      nickname: nickname,
      password: password,
      importGuestData: shouldImportGuestData,
    );
    final pending = _accountRepository.pendingRegistration();
    if (pending == null) throw const AccountException('账号初始化失败，请重试');
    await _resumePendingRegistration(pending);
    await _activateAccount(pending.account);
    await _accountRepository.finalizeRegistration(pending.account.id);
  });

  Future<void> loginAccount({
    required String email,
    required String password,
  }) => _runAccountOperation(() async {
    final account = await _accountRepository.login(
      email: email,
      password: password,
    );
    await _quiesceDownloadsForAccountChange();
    await _activateAccount(account);
  });

  Future<void> signOutAccount() => _runAccountOperation(() async {
    await _quiesceDownloadsForAccountChange();
    await _activateAccount(null);
  });

  Future<void> changeAccountPassword({
    required String currentPassword,
    required String newPassword,
  }) => _runAccountOperation(() async {
    final account = _activeAccount;
    if (account == null) throw const AccountException('请先登录账号');
    await _accountRepository.changePassword(
      accountId: account.id,
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
        await _accountRepository.verifyAccountPassword(
          accountId: account.id,
          password: password,
        );
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
                  available: _accountRepository.listAccounts(),
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
          available: _accountRepository.listAccounts(),
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
          final updated = await _accountRepository.updateNickname(
            account.id,
            profile.nickname,
          );
          if (_activeAccount?.id != account.id) return;
          _activeAccount = updated;
          normalized = profile.copyWith(
            nickname: updated.nickname,
            uid: updated.shortId,
          );
          session = LocalAccountSession(
            current: updated,
            available: _accountRepository.listAccounts(),
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
    final normalized = settings.watchHubEnabled
        ? settings.copyWith(watchHubEnabled: false)
        : settings;
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
    _sourceCatalogRules = sourceBridge.rules;
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
    _sourceCatalogRules = sourceBridge.rules;
    final sourceCatalog = sourceBridge.attachTo(toggledCatalog);
    state = AsyncData(current.copyWith(sourceCatalog: sourceCatalog));
    await _settings.put(
      _accountSettingsKeyFor(accountId, 'sourceEnabled'),
      sourceCatalog.enabledById,
    );
    await _hydrateAndApplySourceCatalog(toggledCatalog, refreshVersion);
  }

  void _scheduleSourceCatalogHydration(SourceCatalogState catalog) {
    final refreshVersion = ++_sourceCatalogRefreshVersion;
    unawaited(
      Future<void>.delayed(
        _sourceCatalogHydrationDelay,
        () => _hydrateAndApplySourceCatalog(catalog, refreshVersion),
      ).onError((_, _) {}),
    );
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
    _sourceCatalogRules = hydrated.rules;
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

  RulePluginState _mergeDefaultNativeRules(
    RulePluginState stored,
    RulePluginState defaults,
  ) {
    final installedIds = {...stored.installedIds, ...defaults.installedIds};
    final enabledIds = {...stored.enabledIds, ...defaults.enabledIds};
    return _normalizeRulePlugins(
      stored.copyWith(installedIds: installedIds, enabledIds: enabledIds),
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

  Future<SourceCatalogState> _loadSourceCatalog(
    Map<String, bool> enabledOverrides,
  ) async {
    try {
      return await ref
          .read(sourceCatalogRepositoryProvider)
          .loadCatalog(enabledOverrides: enabledOverrides);
    } catch (error) {
      return SourceCatalogState.failed(error);
    }
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

  _HomeFeedCacheSnapshot _readHomeFeedCache() {
    final value = _library.get(_homeFeedCacheKey);
    if (value is! Map) return const _HomeFeedCacheSnapshot();
    final version = value['version'];
    if (version != _homeFeedCacheVersion &&
        version != _legacyHomeFeedCacheVersion) {
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
      final fresh =
          version == _homeFeedCacheVersion &&
          age != null &&
          !age.isNegative &&
          age <= _homeFeedCacheTtl;
      return _HomeFeedCacheSnapshot(feed: feed, fresh: fresh);
    } catch (_) {
      return const _HomeFeedCacheSnapshot();
    }
  }

  Future<void> _refreshHomeFeed(ExternalServiceSettings services) async {
    final refreshVersion = ++_homeRefreshVersion;
    final bangumiRepository = ref.read(bangumiMetadataRepositoryProvider);
    final fallback = bangumiRepository.fallbackHomeFeed();
    final groups = await Future.wait<Object>([
      if (services.bangumiEnabled)
        bangumiRepository
            .homeFeed()
            .timeout(const Duration(seconds: 12), onTimeout: () => fallback)
            .onError((_, _) => fallback)
      else
        Future.value(fallback),
      _loadHomeHighlights(services).onError((_, _) => const _HomeHighlights()),
    ]);
    final feed = _composeHomeFeed(
      groups[0] as AnimeHomeFeed,
      groups[1] as _HomeHighlights,
    );
    if (refreshVersion != _homeRefreshVersion) return;
    await _library.put(_homeFeedCacheKey, {
      'version': _homeFeedCacheVersion,
      'fetchedAt': DateTime.now().toUtc().toIso8601String(),
      'feed': feed.toJson(),
    });
    final current = state.value;
    if (current != null) {
      state = AsyncData(current.copyWith(homeFeed: feed));
    }
  }

  Future<_HomeHighlights> _loadHomeHighlights(
    ExternalServiceSettings services,
  ) async {
    final external = ref.read(externalServiceRepositoryProvider);
    final animeFuture =
        Future.wait([
          if (services.anilistEnabled)
            external
                .anilistTrending(perPage: 36)
                .onError((_, _) => const <AnimeSubject>[]),
          if (services.jikanEnabled)
            external
                .jikanTop(limit: 25)
                .onError((_, _) => const <AnimeSubject>[]),
          if (services.kitsuEnabled)
            external
                .kitsuTrending(limit: 20)
                .onError((_, _) => const <AnimeSubject>[]),
        ]).then(
          (groups) => _uniqueSubjects([
            ..._interleaveSubjectGroups(groups, limitPerRound: 8),
            ...groups.expand((items) => items),
          ]),
        );
    final seriesFuture =
        services.mediaMetadataEnabled && services.cinemetaEnabled
        ? external
              .cinemetaFeed(type: 'series', pages: 1)
              .onError((_, _) => const <AnimeSubject>[])
        : Future.value(const <AnimeSubject>[]);
    final movieFuture =
        Future.wait([
          if (services.mediaMetadataEnabled)
            external
                .movieMetadataFeed(
                  includeCinemeta: services.cinemetaEnabled,
                  includeArchive: false,
                  cinemetaPages: 1,
                )
                .onError((_, _) => const <AnimeSubject>[]),
        ]).then(
          (groups) => _uniqueSubjects([
            ..._interleaveSubjectGroups(groups, limitPerRound: 6),
            ...groups.expand((items) => items),
          ]),
        );
    final groups = await Future.wait([animeFuture, seriesFuture, movieFuture])
        .timeout(
          const Duration(seconds: 12),
          onTimeout: () => const <List<AnimeSubject>>[[], [], []],
        );
    final enriched = await Future.wait([
      _enrichSubjects(groups[0], services, animeLookupLimit: 12),
      _enrichSubjects(groups[1], services, animeLookupLimit: 0),
      _enrichSubjects(groups[2], services, animeLookupLimit: 0),
    ]).timeout(const Duration(seconds: 8), onTimeout: () => groups);
    return _HomeHighlights(
      anime: enriched[0],
      series: enriched[1],
      movies: enriched[2],
    );
  }

  Future<List<AnimeSubject>> _enrichSubjects(
    Iterable<AnimeSubject> subjects,
    ExternalServiceSettings services, {
    required int animeLookupLimit,
  }) async {
    final items = subjects.toList(growable: false);
    if (items.isEmpty) return const [];
    var enriched = items;
    try {
      enriched = await ref
          .read(chineseMetadataRepositoryProvider)
          .enrichSubjects(
            items,
            useBangumiForAnime: services.preferBangumiChinese,
            animeLookupLimit: animeLookupLimit,
          )
          .timeout(const Duration(seconds: 24), onTimeout: () => items);
    } catch (_) {
      enriched = items;
    }
    return enriched.map(_localizeSubjectLabels).toList(growable: false);
  }

  AnimeSubject _localizeSubjectLabels(AnimeSubject subject) {
    final platform = _localizedLabel(subject.platform, const {
      'movie': '电影',
      'series': '剧集',
      'scripted': '剧集',
      'show': '剧集',
      'reality': '真人秀',
      'peertube': '开放视频',
      'live': '直播',
    });
    final language = _localizedLabel(subject.language, const {
      'english': '英语',
      'japanese': '日语',
      'korean': '韩语',
      'chinese': '中文',
      'mandarin': '国语',
      'cantonese': '粤语',
      'french': '法语',
      'german': '德语',
      'spanish': '西班牙语',
      'italian': '意大利语',
      'russian': '俄语',
    });
    final region = _localizedLabel(subject.region, const {
      'united states': '美国',
      'united kingdom': '英国',
      'south korea': '韩国',
      'korea, republic of': '韩国',
      'japan': '日本',
      'china': '中国',
      'hong kong': '中国香港',
      'taiwan': '中国台湾',
      'canada': '加拿大',
      'france': '法国',
      'germany': '德国',
      'italy': '意大利',
      'spain': '西班牙',
      'australia': '澳大利亚',
    });
    final status = _localizedLabel(subject.status, const {
      'running': '连载中',
      'ended': '已完结',
      'in development': '制作中',
      'to be determined': '待定',
    });
    final categories = subject.categories
        .map(
          (item) => AnimeCategory(
            name: _localizedLabel(item.name, const {
              'drama': '剧情',
              'action': '动作',
              'adventure': '冒险',
              'fantasy': '奇幻',
              'crime': '犯罪',
              'thriller': '惊悚',
              'horror': '恐怖',
              'science fiction': '科幻',
              'science-fiction': '科幻',
              'sci-fi': '科幻',
              'comedy': '喜剧',
              'romance': '爱情',
              'mystery': '悬疑',
              'animation': '动画',
              'documentary': '纪录片',
              'family': '家庭',
              'history': '历史',
              'war': '战争',
              'western': '西部',
              'music': '音乐',
              'supernatural': '超自然',
              'reality': '真人秀',
              'talk show': '脱口秀',
            }),
            count: item.count,
            imageUrl: item.imageUrl,
          ),
        )
        .toList(growable: false);
    if (platform == subject.platform &&
        language == subject.language &&
        region == subject.region &&
        status == subject.status &&
        _sameCategoryLabels(categories, subject.categories)) {
      return subject;
    }
    return AnimeSubject(
      id: subject.id,
      title: subject.title,
      originalTitle: subject.originalTitle,
      summary: subject.summary,
      coverUrl: subject.coverUrl,
      bannerUrl: subject.bannerUrl,
      date: subject.date,
      platform: platform,
      language: language,
      region: region,
      status: status,
      categories: categories,
      tags: subject.tags,
      totalEpisodes: subject.totalEpisodes,
      ratingScore: subject.ratingScore,
      ratingRank: subject.ratingRank,
      ratingTotal: subject.ratingTotal,
      source: subject.source,
    );
  }

  String _localizedLabel(String value, Map<String, String> labels) {
    final text = value.trim();
    if (text.isEmpty) return text;
    return labels[text.toLowerCase()] ?? text;
  }

  bool _sameCategoryLabels(
    List<AnimeCategory> first,
    List<AnimeCategory> second,
  ) {
    if (first.length != second.length) return false;
    for (var i = 0; i < first.length; i++) {
      if (first[i].name != second[i].name) return false;
    }
    return true;
  }

  AnimeHomeFeed _composeHomeFeed(
    AnimeHomeFeed base,
    _HomeHighlights highlights,
  ) {
    final animeHighlights = _subjectsOfType(
      highlights.anime,
      SubjectContentType.anime,
    );
    final animeBaseRecommended = _subjectsOfType(
      base.recommended,
      SubjectContentType.anime,
    );
    final animeBaseRecent = _subjectsOfType(
      base.recent,
      SubjectContentType.anime,
    );
    final animeBaseIndex = _subjectsOfType(
      base.index,
      SubjectContentType.anime,
    );
    final all = _uniqueSubjects([
      ..._interleaveSubjectGroups([
        animeHighlights,
        animeBaseRecommended,
        animeBaseRecent,
      ], limitPerRound: 4),
      ...animeBaseIndex,
    ]);
    final rankedAll = [...all]
      ..sort((a, b) => _homeRank(b).compareTo(_homeRank(a)));
    final heroCandidates =
        rankedAll.where((item) => (item.bannerUrl ?? '').isNotEmpty).toList()
          ..sort((a, b) => _homeRank(b).compareTo(_homeRank(a)));
    final hero = heroCandidates.firstOrNull ?? base.hero;
    final recentCandidates =
        _uniqueSubjects([...animeBaseRecent, ...animeHighlights])..sort((a, b) {
          final rankOrder = _homeRank(b).compareTo(_homeRank(a));
          if (rankOrder != 0) return rankOrder;
          return (b.date ?? '').compareTo(a.date ?? '');
        });
    final recent = <AnimeSubject>[];
    for (final subject in recentCandidates) {
      if (_sameSubject(subject, hero)) continue;
      recent.add(subject);
      if (recent.length >= 28) break;
    }
    final recommended = <AnimeSubject>[];
    for (final subject in rankedAll) {
      if (_sameSubject(subject, hero) ||
          recent.any((item) => _sameSubject(item, subject))) {
        continue;
      }
      recommended.add(subject);
      if (recommended.length >= 36) break;
    }
    return AnimeHomeFeed(
      hero: hero,
      recent: recent.isEmpty ? animeBaseRecent : recent,
      recommended: recommended.isEmpty ? animeBaseRecommended : recommended,
      index: all.take(360).toList(growable: false),
      categories: base.categories,
      tags: base.tags,
      seriesHighlights: _subjectsOfType(
        highlights.series,
        SubjectContentType.series,
      ).take(12).toList(growable: false),
      movieHighlights: _subjectsOfType(
        highlights.movies,
        SubjectContentType.movie,
      ).take(12).toList(growable: false),
    );
  }

  int _homeRank(AnimeSubject subject) {
    var score = ((subject.ratingScore ?? 0) * 10).round();
    if ((subject.bannerUrl ?? '').isNotEmpty) score += 30;
    if ((subject.coverUrl ?? '').isNotEmpty) score += 12;
    if (_containsChinese(subject.title)) score += 20;
    if (_containsChinese(subject.summary)) score += 6;
    if (_isDirectPlayable(subject)) score += 4;
    final date = DateTime.tryParse(subject.date ?? '');
    if (date != null) {
      final age = DateTime.now().difference(date).inDays;
      if (age >= 0 && age <= 180) {
        score += 24;
      } else if (age >= 0 && age <= 730) {
        score += 10;
      }
    }
    return score;
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
    final sourceEnabledJson = _settings.get(
      _accountSettingsKeyFor(accountId, 'sourceEnabled'),
    );
    final misc = miscJson is Map
        ? MiscSettings.fromJson(miscJson.cast<String, dynamic>())
        : const MiscSettings();
    final services = servicesJson is Map
        ? ExternalServiceSettings.fromJson(servicesJson.cast<String, dynamic>())
        : const ExternalServiceSettings();
    final defaultRulePlugins = const RulePluginRepository().defaultState();
    final rulePlugins = rulePluginsJson is Map
        ? _mergeDefaultNativeRules(
            _normalizeRulePlugins(
              RulePluginState.fromJson(rulePluginsJson.cast<String, dynamic>()),
            ),
            defaultRulePlugins,
          )
        : defaultRulePlugins;
    final loadedSourceCatalog = await _loadSourceCatalog(
      _enabledOverridesFromJson(sourceEnabledJson),
    );
    final sourceBridge = ref
        .read(sourceRuleBridgeProvider)
        .build(loadedSourceCatalog);
    final sourceCatalog = sourceBridge.attachTo(loadedSourceCatalog);
    final offlineTasks = await _readDownloadTasksFor(accountId);
    final current = state.value;
    if (current == null) return;
    await _accountRepository.setActiveAccount(accountId);
    _activeAccount = account;
    _accountContextVersion++;
    RulePlaybackSourceRepository.clearRuntimeCaches();
    ref.read(rulePlaybackResolverProvider).clearCaches();
    ref.read(m3uSourceAdapterProvider).clearCache();
    ref.read(torrentSourceAdapterProvider).clearCache();
    ref.read(sourceRuleBridgeProvider).xbpqHydrator?.clearCache();
    _homeRefreshVersion++;
    _sourceCatalogRefreshVersion++;
    _playbackPrefetches.clear();
    _sourceCatalogRules = sourceBridge.rules;
    final session = LocalAccountSession(
      current: account,
      available: _accountRepository.listAccounts(),
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
    _scheduleSourceCatalogHydration(loadedSourceCatalog);
  }

  Future<void> _resumePendingRegistration(
    PendingLocalAccountRegistration pending,
  ) async {
    final accountId = pending.account.id;
    if (pending.importGuestData) {
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
    if (value is List) {
      final legacy = value
          .whereType<Map>()
          .map((item) => AnimeSubject.fromJson(item.cast<String, dynamic>()))
          .where((item) => item.title.trim().isNotEmpty)
          .toList();
      return _SubjectCacheSnapshot(subjects: legacy, fresh: false);
    }
    if (value is! Map) return const _SubjectCacheSnapshot();
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
    final active = _metadataRefreshes[key];
    if (active != null) return active;
    late final Future<List<AnimeSubject>> task;
    task = () async {
      final refreshed = _uniqueSubjects(await load());
      if (refreshed.isEmpty) return const <AnimeSubject>[];
      final subjects = _uniqueSubjects([
        ...refreshed,
        ..._compatibleCachedSubjects(key, signature),
      ]);
      await _library.put(key, {
        'version': _metadataCacheVersion,
        'signature': signature,
        'fetchedAt': DateTime.now().toUtc().toIso8601String(),
        'refreshCount': refreshed.length,
        'subjects': subjects
            .take(_metadataCacheLimit)
            .map((item) => item.toJson())
            .toList(growable: false),
      });
      return subjects;
    }();
    _metadataRefreshes[key] = task;
    return task.whenComplete(() {
      if (identical(_metadataRefreshes[key], task)) {
        _metadataRefreshes.remove(key);
      }
    });
  }

  List<AnimeSubject> _compatibleCachedSubjects(String key, String signature) {
    final value = _library.get(key);
    if (value is! Map || value['signature']?.toString() != signature) {
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

  List<AnimeSubject> _interleaveSubjectGroups(
    List<List<AnimeSubject>> groups, {
    int limitPerRound = 8,
  }) {
    final result = <AnimeSubject>[];
    final offsets = List<int>.filled(groups.length, 0);
    var added = true;
    while (added) {
      added = false;
      for (var groupIndex = 0; groupIndex < groups.length; groupIndex++) {
        final group = groups[groupIndex];
        final start = offsets[groupIndex];
        if (start >= group.length) continue;
        final end = (start + limitPerRound).clamp(0, group.length);
        result.addAll(group.sublist(start, end));
        offsets[groupIndex] = end;
        added = true;
      }
    }
    return result;
  }

  List<AnimeSubject> _uniqueSubjects(Iterable<AnimeSubject> subjects) {
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
      final merged = _mergeSubjects(unique[existingIndex], subject);
      unique[existingIndex] = merged;
      for (final key in _subjectIdentityKeys(merged)) {
        keyToIndex[key] = existingIndex;
      }
    }
    return unique;
  }

  bool _sameSubject(AnimeSubject a, AnimeSubject b) {
    final bKeys = _subjectIdentityKeys(b);
    return _subjectIdentityKeys(a).any(bKeys.contains);
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

  AnimeSubject _mergeSubjects(AnimeSubject first, AnimeSubject second) {
    final firstDirect = _isDirectPlayable(first);
    final secondDirect = _isDirectPlayable(second);
    final primary = firstDirect != secondDirect
        ? (firstDirect ? first : second)
        : _subjectQuality(second) > _subjectQuality(first)
        ? second
        : first;
    final secondary = identical(primary, first) ? second : first;
    final title = _containsChinese(primary.title)
        ? primary.title
        : _containsChinese(secondary.title)
        ? secondary.title
        : primary.title;
    final categories = <String, AnimeCategory>{
      for (final item in primary.categories) item.name: item,
      for (final item in secondary.categories) item.name: item,
    }.values.take(8).toList(growable: false);
    final tags = <String, AnimeTag>{
      for (final item in primary.tags) item.name: item,
      for (final item in secondary.tags) item.name: item,
    }.values.take(20).toList(growable: false);
    return AnimeSubject(
      id: primary.id,
      title: title,
      originalTitle: primary.originalTitle.trim().isNotEmpty
          ? primary.originalTitle
          : secondary.originalTitle,
      summary: _preferredLocalizedText(primary.summary, secondary.summary),
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
    if (_containsChinese(subject.title)) score += 4;
    if (subject.summary.length >= 80) score += 3;
    if (subject.ratingScore != null) score += 3;
    if (subject.totalEpisodes > 0) score += 2;
    return score;
  }

  bool _isDirectPlayable(AnimeSubject subject) {
    return subject.source.startsWith('archive:') ||
        subject.source.startsWith('peertube:') ||
        subject.source.startsWith('commons:');
  }

  bool _containsChinese(String value) {
    return RegExp(r'[\u3400-\u9fff]').hasMatch(value);
  }

  String _preferredLocalizedText(String first, String second) {
    final firstChinese = _containsChinese(first);
    final secondChinese = _containsChinese(second);
    if (firstChinese != secondChinese) return firstChinese ? first : second;
    return first.length >= second.length ? first : second;
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

  Map<String, bool> _enabledOverridesFromJson(Object? value) {
    if (value is! Map) return const {};
    return {
      for (final entry in value.entries)
        entry.key.toString(): entry.value is bool
            ? entry.value as bool
            : entry.value.toString().toLowerCase() == 'true',
    };
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

class _HomeHighlights {
  const _HomeHighlights({
    this.anime = const [],
    this.series = const [],
    this.movies = const [],
  });

  final List<AnimeSubject> anime;
  final List<AnimeSubject> series;
  final List<AnimeSubject> movies;
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
