import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import '../domain/anime_models.dart';
import 'bangumi_metadata_repository.dart';
import 'external_service_repository.dart';
import 'playback_source_repository.dart';

final bangumiMetadataRepositoryProvider = Provider<BangumiMetadataRepository>(
  (ref) => BangumiMetadataRepository(),
);

final playbackSourceRepositoryProvider = Provider<PlaybackSourceRepository>(
  (ref) => const EmptyPlaybackSourceRepository(),
);

final externalServiceRepositoryProvider = Provider<ExternalServiceRepository>(
  (ref) => ExternalServiceRepository(),
);

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
    this.homePreferences = const HomePreferences(),
    this.appearance = const AppearanceSettings(),
    this.danmaku = const DanmakuSettings(),
    this.misc = const MiscSettings(),
    this.services = const ExternalServiceSettings(),
  });

  final AnimeHomeFeed homeFeed;
  final PlaybackSettings settings;
  final Map<int, AnimeDetailBundle> selectedSubjects;
  final List<LibraryEntry> favorites;
  final List<LibraryEntry> history;
  final List<LibraryEntry> following;
  final List<LibraryEntry> offlineTasks;
  final List<LibraryEntry> imageFavorites;
  final List<LocalFeedback> feedbacks;
  final UserProfileSettings profile;
  final HomePreferences homePreferences;
  final AppearanceSettings appearance;
  final DanmakuSettings danmaku;
  final MiscSettings misc;
  final ExternalServiceSettings services;

  AnimeState copyWith({
    AnimeHomeFeed? homeFeed,
    PlaybackSettings? settings,
    Map<int, AnimeDetailBundle>? selectedSubjects,
    List<LibraryEntry>? favorites,
    List<LibraryEntry>? history,
    List<LibraryEntry>? following,
    List<LibraryEntry>? offlineTasks,
    List<LibraryEntry>? imageFavorites,
    List<LocalFeedback>? feedbacks,
    UserProfileSettings? profile,
    HomePreferences? homePreferences,
    AppearanceSettings? appearance,
    DanmakuSettings? danmaku,
    MiscSettings? misc,
    ExternalServiceSettings? services,
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
      homePreferences: homePreferences ?? this.homePreferences,
      appearance: appearance ?? this.appearance,
      danmaku: danmaku ?? this.danmaku,
      misc: misc ?? this.misc,
      services: services ?? this.services,
    );
  }
}

class AnimeController extends AsyncNotifier<AnimeState> {
  static const _settingsBox = 'anime.settings.v2';
  static const _libraryBox = 'anime.library.v2';
  late Box<dynamic> _settings;
  late Box<dynamic> _library;

  @override
  Future<AnimeState> build() async {
    _settings = await Hive.openBox<dynamic>(_settingsBox);
    _library = await Hive.openBox<dynamic>(_libraryBox);
    final settingsJson = _settings.get('playback');
    final settings = settingsJson is Map
        ? PlaybackSettings.fromJson(settingsJson.cast<String, dynamic>())
        : const PlaybackSettings();
    final profileJson = _settings.get('profile');
    final homeJson = _settings.get('homePreferences');
    final appearanceJson = _settings.get('appearance');
    final danmakuJson = _settings.get('danmaku');
    final miscJson = _settings.get('misc');
    final servicesJson = _settings.get('services');
    final feed = await ref.read(bangumiMetadataRepositoryProvider).homeFeed();
    return AnimeState(
      homeFeed: feed,
      settings: settings,
      favorites: _readEntries('favorites'),
      history: _readEntries('history'),
      following: _readEntries('following'),
      offlineTasks: _readEntries('offlineTasks'),
      imageFavorites: _readEntries('imageFavorites'),
      feedbacks: _readFeedbacks(),
      profile: profileJson is Map
          ? UserProfileSettings.fromJson(profileJson.cast<String, dynamic>())
          : const UserProfileSettings(),
      homePreferences: homeJson is Map
          ? HomePreferences.fromJson(homeJson.cast<String, dynamic>())
          : const HomePreferences(),
      appearance: appearanceJson is Map
          ? AppearanceSettings.fromJson(appearanceJson.cast<String, dynamic>())
          : const AppearanceSettings(),
      danmaku: danmakuJson is Map
          ? DanmakuSettings.fromJson(danmakuJson.cast<String, dynamic>())
          : const DanmakuSettings(),
      misc: miscJson is Map
          ? MiscSettings.fromJson(miscJson.cast<String, dynamic>())
          : const MiscSettings(),
      services: servicesJson is Map
          ? ExternalServiceSettings.fromJson(
              servicesJson.cast<String, dynamic>(),
            )
          : const ExternalServiceSettings(),
    );
  }

  Future<List<AnimeSubject>> search(String keyword) {
    if (keyword.trim().isEmpty) return Future.value(const []);
    final query = keyword.trim();
    final services = state.value?.services ?? const ExternalServiceSettings();
    final external = ref.read(externalServiceRepositoryProvider);
    return Future.wait([
      if (services.bangumiEnabled)
        ref
            .read(bangumiMetadataRepositoryProvider)
            .searchSubjects(keyword: query, limit: 48)
            .onError((_, _) => const <AnimeSubject>[]),
      if (services.anilistEnabled)
        external
            .anilistSearch(query, perPage: 24)
            .onError((_, _) => const <AnimeSubject>[]),
      if (services.mediaMetadataEnabled)
        external.mediaSearch(query).onError((_, _) => const <AnimeSubject>[]),
    ]).then((groups) => _uniqueSubjects(groups.expand((items) => items)));
  }

  Future<List<AnimeSubject>> categorySubjects(String name) {
    return ref.read(bangumiMetadataRepositoryProvider).subjectsByCategory(name);
  }

  Future<List<AnimeSubject>> tagSubjects(String name) {
    return ref.read(bangumiMetadataRepositoryProvider).subjectsByTag(name);
  }

  Future<List<AnimeSubject>> discoverSubjects() async {
    return _homeSubjects;
  }

  Future<List<AnimeSubject>> seriesSubjects() async {
    final subjects = await ref
        .read(externalServiceRepositoryProvider)
        .seriesMetadataFeed()
        .onError((_, _) => const <AnimeSubject>[]);
    return subjects.isEmpty ? _fallbackExternalSeries : subjects;
  }

  Future<List<AnimeSubject>> movieSubjects() async {
    final subjects = await ref
        .read(externalServiceRepositoryProvider)
        .movieMetadataFeed()
        .onError((_, _) => const <AnimeSubject>[]);
    return subjects.isEmpty ? _fallbackExternalMovies : subjects;
  }

  Future<Map<int, List<AnimeSubject>>> weeklySchedule() {
    final services = state.value?.services ?? const ExternalServiceSettings();
    return Future.wait([
      if (services.bangumiEnabled)
        ref
            .read(bangumiMetadataRepositoryProvider)
            .weeklySchedule()
            .onError((_, _) => <int, List<AnimeSubject>>{}),
      if (services.anilistEnabled)
        ref
            .read(externalServiceRepositoryProvider)
            .anilistTrending(perPage: 48)
            .onError((_, _) => const <AnimeSubject>[]),
    ]).then((results) {
      final baseResult = results.whereType<Map<int, List<AnimeSubject>>>();
      final base = baseResult.isEmpty
          ? <int, List<AnimeSubject>>{}
          : baseResult.first;
      final anilist = results
          .whereType<List<AnimeSubject>>()
          .expand((items) => items)
          .toList();
      final merged = {
        for (var i = 0; i < 7; i++) i: [...?base[i]],
      };
      for (final subject in anilist) {
        final date = DateTime.tryParse(subject.date ?? '');
        final weekday = date == null ? subject.id % 7 : date.weekday % 7;
        merged[weekday]!.add(subject);
      }
      return {
        for (final entry in merged.entries)
          entry.key: _uniqueSubjects(entry.value).take(36).toList(),
      };
    });
  }

  Future<AnimeDetailBundle> detail(AnimeSubject subject) async {
    final current = state.value;
    final cacheKey = _subjectCacheKey(subject);
    final cached = current?.selectedSubjects[cacheKey];
    if (cached != null) return cached;
    final detail = subject.source == 'bangumi'
        ? await ref.read(bangumiMetadataRepositoryProvider).detail(subject.id)
        : await ref
              .read(externalServiceRepositoryProvider)
              .externalDetail(subject);
    final previous = state.value;
    if (previous != null) {
      state = AsyncData(
        previous.copyWith(
          selectedSubjects: {...previous.selectedSubjects, cacheKey: detail},
        ),
      );
    }
    return detail;
  }

  Future<List<PlaybackLine>> linesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode,
  ) {
    return ref
        .read(playbackSourceRepositoryProvider)
        .linesForEpisode(subject, episode);
  }

  Future<List<SubtitleCandidate>> subtitlesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode,
  ) {
    final services = state.value?.services ?? const ExternalServiceSettings();
    return ref
        .read(externalServiceRepositoryProvider)
        .searchSubtitles(subject, episode, services);
  }

  Future<List<DanmakuMatch>> danmakuForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode,
  ) {
    final services = state.value?.services ?? const ExternalServiceSettings();
    return ref
        .read(externalServiceRepositoryProvider)
        .matchDanmaku(subject, episode, services);
  }

  Future<void> updateSettings(PlaybackSettings settings) async {
    final current = state.value;
    if (current != null) {
      state = AsyncData(current.copyWith(settings: settings));
    }
    await _settings.put('playback', settings.toJson());
  }

  Future<void> updateProfile(UserProfileSettings profile) async {
    final current = state.value;
    if (current != null) state = AsyncData(current.copyWith(profile: profile));
    await _settings.put('profile', profile.toJson());
  }

  Future<void> updateHomePreferences(HomePreferences preferences) async {
    final current = state.value;
    if (current != null) {
      state = AsyncData(current.copyWith(homePreferences: preferences));
    }
    await _settings.put('homePreferences', preferences.toJson());
  }

  Future<void> updateAppearance(AppearanceSettings settings) async {
    final current = state.value;
    if (current != null) {
      state = AsyncData(current.copyWith(appearance: settings));
    }
    await _settings.put('appearance', settings.toJson());
  }

  Future<void> updateDanmaku(DanmakuSettings settings) async {
    final current = state.value;
    if (current != null) state = AsyncData(current.copyWith(danmaku: settings));
    await _settings.put('danmaku', settings.toJson());
  }

  Future<void> updateMisc(MiscSettings settings) async {
    final current = state.value;
    if (current != null) state = AsyncData(current.copyWith(misc: settings));
    await _settings.put('misc', settings.toJson());
  }

  Future<void> updateServices(ExternalServiceSettings settings) async {
    final current = state.value;
    if (current != null) {
      state = AsyncData(current.copyWith(services: settings));
    }
    await _settings.put('services', settings.toJson());
  }

  Future<bool> toggleFavorite(AnimeSubject subject) async {
    final current = state.value;
    if (current == null) return false;
    final next = _toggleSubject(current.favorites, subject);
    state = AsyncData(current.copyWith(favorites: next));
    await _writeEntries('favorites', next);
    return next.any((item) => item.subject.id == subject.id);
  }

  Future<bool> toggleFollowing(AnimeSubject subject) async {
    final current = state.value;
    if (current == null) return false;
    final next = _toggleSubject(current.following, subject);
    state = AsyncData(current.copyWith(following: next));
    await _writeEntries('following', next);
    return next.any((item) => item.subject.id == subject.id);
  }

  Future<void> addHistory(AnimeSubject subject, AnimeEpisode? episode) async {
    final current = state.value;
    if (current == null) return;
    final next = [
      LibraryEntry(
        subject: subject,
        episode: episode,
        updatedAt: DateTime.now(),
        note: episode == null ? '打开详情' : '播放到 ${episode.displayTitle}',
      ),
      ...current.history.where((item) => item.subject.id != subject.id),
    ].take(80).toList();
    state = AsyncData(current.copyWith(history: next));
    await _writeEntries('history', next);
    await ref
        .read(externalServiceRepositoryProvider)
        .syncLocalHistory(subject, episode, current.services);
  }

  Future<void> queueOffline(AnimeSubject subject, AnimeEpisode? episode) async {
    final current = state.value;
    if (current == null) return;
    final keyEpisodeId = episode?.id;
    final next = [
      LibraryEntry(
        subject: subject,
        episode: episode,
        updatedAt: DateTime.now(),
        note: '待接入视频源后开始缓存',
      ),
      ...current.offlineTasks.where(
        (item) =>
            item.subject.id != subject.id || item.episode?.id != keyEpisodeId,
      ),
    ].take(80).toList();
    state = AsyncData(current.copyWith(offlineTasks: next));
    await _writeEntries('offlineTasks', next);
  }

  Future<void> addImageFavorite(AnimeSubject subject) async {
    final current = state.value;
    if (current == null) return;
    final next = [
      LibraryEntry(subject: subject, updatedAt: DateTime.now(), note: '收藏封面图'),
      ...current.imageFavorites.where((item) => item.subject.id != subject.id),
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
    await _library.put(key, const []);
  }

  Future<void> submitFeedback({
    required String title,
    required String content,
    AnimeSubject? subject,
  }) async {
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
    await _library.put('feedbacks', next.map((item) => item.toJson()).toList());
  }

  List<LibraryEntry> _toggleSubject(
    List<LibraryEntry> entries,
    AnimeSubject subject,
  ) {
    final exists = entries.any((item) => item.subject.id == subject.id);
    if (exists) {
      return entries.where((item) => item.subject.id != subject.id).toList();
    }
    return [
      LibraryEntry(subject: subject, updatedAt: DateTime.now()),
      ...entries,
    ];
  }

  List<LibraryEntry> _readEntries(String key) {
    final value = _library.get(key);
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map((item) => LibraryEntry.fromJson(item.cast<String, dynamic>()))
        .where((item) => item.subject.title.trim().isNotEmpty)
        .toList();
  }

  List<AnimeSubject> _uniqueSubjects(Iterable<AnimeSubject> subjects) {
    final seen = <String>{};
    final unique = <AnimeSubject>[];
    for (final subject in subjects) {
      final key = '${subject.platform}:${subject.id}:${subject.title}';
      if (subject.title.trim().isEmpty || !seen.add(key)) continue;
      unique.add(subject);
    }
    return unique;
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
    return _library.put(key, entries.map((item) => item.toJson()).toList());
  }

  List<LocalFeedback> _readFeedbacks() {
    final value = _library.get('feedbacks');
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map((item) => LocalFeedback.fromJson(item.cast<String, dynamic>()))
        .where((item) => item.title.trim().isNotEmpty)
        .toList();
  }
}

const _fallbackExternalSeries = [
  AnimeSubject(
    id: 82,
    title: 'Game of Thrones',
    originalTitle: 'Game of Thrones',
    summary: '九大家族争夺维斯特洛大陆控制权的史诗剧集。',
    coverUrl:
        'https://static.tvmaze.com/uploads/images/original_untouched/190/476117.jpg',
    bannerUrl:
        'https://static.tvmaze.com/uploads/images/original_untouched/190/476117.jpg',
    date: '2011-04-17',
    platform: 'Scripted',
    language: 'English',
    region: 'United States',
    status: 'Ended',
    categories: [
      AnimeCategory(name: 'Drama'),
      AnimeCategory(name: 'Adventure'),
      AnimeCategory(name: 'Fantasy'),
    ],
    tags: [AnimeTag(name: 'TVMaze')],
    totalEpisodes: 73,
    source: 'tvmaze',
  ),
  AnimeSubject(
    id: 169,
    title: 'Breaking Bad',
    originalTitle: 'Breaking Bad',
    summary: '一位化学教师在绝境中走向犯罪世界。',
    coverUrl:
        'https://static.tvmaze.com/uploads/images/original_untouched/0/2400.jpg',
    bannerUrl:
        'https://static.tvmaze.com/uploads/images/original_untouched/0/2400.jpg',
    date: '2008-01-20',
    platform: 'Scripted',
    language: 'English',
    region: 'United States',
    status: 'Ended',
    categories: [
      AnimeCategory(name: 'Drama'),
      AnimeCategory(name: 'Crime'),
      AnimeCategory(name: 'Thriller'),
    ],
    tags: [AnimeTag(name: 'TVMaze')],
    totalEpisodes: 62,
    source: 'tvmaze',
  ),
  AnimeSubject(
    id: 527,
    title: 'The Walking Dead',
    originalTitle: 'The Walking Dead',
    summary: '幸存者在末日世界中寻找栖身之处，也面对人与人之间更复杂的冲突。',
    coverUrl:
        'https://static.tvmaze.com/uploads/images/original_untouched/67/168817.jpg',
    bannerUrl:
        'https://static.tvmaze.com/uploads/images/original_untouched/67/168817.jpg',
    date: '2010-10-31',
    platform: 'Scripted',
    language: 'English',
    region: 'United States',
    status: 'Ended',
    categories: [
      AnimeCategory(name: 'Drama'),
      AnimeCategory(name: 'Action'),
      AnimeCategory(name: 'Horror'),
    ],
    tags: [AnimeTag(name: 'TVMaze')],
    totalEpisodes: 177,
    source: 'tvmaze',
  ),
];

const _fallbackExternalMovies = [
  AnimeSubject(
    id: 25188,
    title: 'The Lord of the Rings: The Fellowship of the Ring',
    originalTitle: 'The Lord of the Rings: The Fellowship of the Ring',
    summary: '一枚戒指引发跨越中土世界的远征。',
    coverUrl: null,
    bannerUrl: null,
    date: '2001-12-10',
    platform: 'Movie',
    language: '',
    region: 'Wikidata',
    status: '电影',
    categories: [
      AnimeCategory(name: '电影'),
      AnimeCategory(name: 'Fantasy'),
    ],
    tags: [
      AnimeTag(name: 'Wikidata'),
      AnimeTag(name: 'IMDb'),
    ],
    totalEpisodes: 1,
    source: 'wikidata',
  ),
  AnimeSubject(
    id: 2875,
    title: 'Inception',
    originalTitle: 'Inception',
    summary: '一名盗梦者接受在他人潜意识中植入想法的任务。',
    coverUrl: null,
    bannerUrl: null,
    date: '2010-07-08',
    platform: 'Movie',
    language: '',
    region: 'Wikidata',
    status: '电影',
    categories: [
      AnimeCategory(name: '电影'),
      AnimeCategory(name: 'Science fiction'),
    ],
    tags: [
      AnimeTag(name: 'Wikidata'),
      AnimeTag(name: 'IMDb'),
    ],
    totalEpisodes: 1,
    source: 'wikidata',
  ),
  AnimeSubject(
    id: 103474,
    title: 'Interstellar',
    originalTitle: 'Interstellar',
    summary: '人类为寻找新的栖息星球，穿越虫洞展开星际航行。',
    coverUrl: null,
    bannerUrl: null,
    date: '2014-10-26',
    platform: 'Movie',
    language: 'English',
    region: 'United States',
    status: '电影',
    categories: [
      AnimeCategory(name: '电影'),
      AnimeCategory(name: 'Science fiction'),
      AnimeCategory(name: 'Adventure'),
    ],
    tags: [
      AnimeTag(name: 'Wikidata'),
      AnimeTag(name: 'IMDb'),
    ],
    totalEpisodes: 1,
    source: 'wikidata',
  ),
];
