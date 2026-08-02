import 'dart:async';

import 'package:hive_ce_flutter/hive_flutter.dart';

import '../accounts/local_account_repository.dart';
import '../data/chinese_text.dart';
import '../domain/anime_models.dart';
import '../domain/subject_content_type.dart';
import '../settings/settings_controller.dart';

abstract interface class CatalogStorage {
  Object? get(String key);

  Future<void> put(String key, Object? value);

  Future<void> delete(String key);
}

final class HiveCatalogStorage implements CatalogStorage {
  const HiveCatalogStorage(this._box);

  final Box<dynamic> _box;

  @override
  Object? get(String key) => _box.get(key);

  @override
  Future<void> put(String key, Object? value) => _box.put(key, value);

  @override
  Future<void> delete(String key) => _box.delete(key);
}

typedef CatalogSnapshotPublisher = void Function(CatalogSnapshot snapshot);
typedef CatalogSearchLoader =
    Future<List<AnimeSubject>> Function(
      String query,
      ExternalServiceSettings services,
    );
typedef CatalogHomeLoader =
    Future<List<AnimeSubject>> Function(
      SubjectContentType type,
      ExternalServiceSettings services,
    );
typedef CatalogDetailLoader =
    Future<AnimeDetailBundle> Function(
      AnimeSubject subject,
      ExternalServiceSettings services,
    );
typedef CatalogDetailEnricher =
    Future<AnimeDetailBundle> Function(
      AnimeDetailBundle bundle,
      ExternalServiceSettings services,
    );
typedef CatalogPlaybackPrefetcher =
    void Function(AnimeSubject subject, List<AnimeEpisode> episodes);

final class CatalogSnapshot {
  const CatalogSnapshot({
    required this.homeFeed,
    this.selectedSubjects = const {},
  });

  final AnimeHomeFeed homeFeed;
  final Map<int, AnimeDetailBundle> selectedSubjects;

  CatalogSnapshot copyWith({
    AnimeHomeFeed? homeFeed,
    Map<int, AnimeDetailBundle>? selectedSubjects,
  }) => CatalogSnapshot(
    homeFeed: homeFeed ?? this.homeFeed,
    selectedSubjects: selectedSubjects ?? this.selectedSubjects,
  );
}

final class CatalogLoadResult {
  const CatalogLoadResult({required this.snapshot, required this.homeFresh});

  final CatalogSnapshot snapshot;
  final bool homeFresh;
}

/// Owns catalog search, home/detail state, metadata caches, enrichment
/// orchestration, and account/settings guards.
final class CatalogController {
  CatalogController({
    required CatalogStorage storage,
    required CatalogSnapshotPublisher publishSnapshot,
    required CatalogSearchLoader search,
    required CatalogHomeLoader loadHome,
    required CatalogDetailLoader loadDetail,
    required CatalogDetailEnricher enrichDetail,
    required CatalogPlaybackPrefetcher prefetchPlayback,
    required List<AnimeSubject> fallbackSeries,
    required List<AnimeSubject> fallbackMovies,
    DateTime Function()? now,
  }) : _storage = storage,
       _publishSnapshot = publishSnapshot,
       _search = search,
       _loadHome = loadHome,
       _loadDetail = loadDetail,
       _enrichDetail = enrichDetail,
       _prefetchPlayback = prefetchPlayback,
       _fallbackSeries = List.unmodifiable(fallbackSeries),
       _fallbackMovies = List.unmodifiable(fallbackMovies),
       _now = now ?? DateTime.now;

  static const animeMetadataCacheKey = 'metadata.cache.anime';
  static const seriesMetadataCacheKey = 'metadata.cache.series';
  static const movieMetadataCacheKey = 'metadata.cache.movie';
  static const homeFeedCacheKey = 'metadata.cache.home';
  static const _homeFeedCacheVersion = 4;
  static const _homeFeedCacheTtl = Duration(hours: 1);
  static const _metadataCacheVersion = 11;
  static const _metadataCacheLimit = 1200;
  static const _metadataCacheTtl = Duration(hours: 8);
  static const _sparseMetadataCacheTtl = Duration(minutes: 30);

  final CatalogStorage _storage;
  final CatalogSnapshotPublisher _publishSnapshot;
  final CatalogSearchLoader _search;
  final CatalogHomeLoader _loadHome;
  final CatalogDetailLoader _loadDetail;
  final CatalogDetailEnricher _enrichDetail;
  final CatalogPlaybackPrefetcher _prefetchPlayback;
  final List<AnimeSubject> _fallbackSeries;
  final List<AnimeSubject> _fallbackMovies;
  final DateTime Function() _now;

  late CatalogSnapshot _snapshot;
  ExternalServiceSettings _services = const ExternalServiceSettings();
  String? _accountId;
  var _contextVersion = 0;
  var _scopeEpoch = 0;
  var _homeRefreshVersion = 0;
  var _loaded = false;
  var _disposed = false;
  var _homeFresh = false;
  final _metadataRefreshes = <String, Future<List<AnimeSubject>>>{};
  final _latestMetadataRefreshes = <String, Future<List<AnimeSubject>>>{};
  Future<void> _writeQueue = Future<void>.value();

  CatalogSnapshot get snapshot => _snapshot;
  bool get homeFresh => _homeFresh;
  String? get accountId => _accountId;
  int get contextVersion => _contextVersion;

  Future<CatalogLoadResult> loadForAccount({
    required String? accountId,
    required int contextVersion,
    required ExternalServiceSettings services,
    required AnimeHomeFeed fallbackHomeFeed,
  }) async {
    _ensureNotDisposed();
    final scope = _CatalogScope(
      accountId: accountId,
      contextVersion: contextVersion,
      epoch: ++_scopeEpoch,
    );
    _accountId = accountId;
    _contextVersion = contextVersion;
    _services = services;
    _loaded = false;
    _homeRefreshVersion++;
    _metadataRefreshes.clear();
    _latestMetadataRefreshes.clear();
    await _writeQueue;
    _ensureConfigured(scope);
    final cached = _readHomeFeedCache(_servicesSignature(services));
    _snapshot = _freeze(
      CatalogSnapshot(
        homeFeed: cached.feed ?? fallbackHomeFeed,
        selectedSubjects: const {},
      ),
    );
    _homeFresh = cached.fresh;
    _loaded = true;
    return CatalogLoadResult(snapshot: _snapshot, homeFresh: _homeFresh);
  }

  Future<List<AnimeSubject>> search(String keyword) async {
    final scope = _scope();
    final query = keyword.trim();
    if (query.isEmpty) return const [];
    final result = await _search(query, _services).onError((_, _) => const []);
    _ensureScope(scope);
    return result;
  }

  Future<List<AnimeSubject>> categorySubjects(String name) async =>
      (await discoverSubjects(waitForRefresh: true))
          .where((item) => item.categories.any((value) => value.name == name))
          .toList(growable: false);

  Future<List<AnimeSubject>> tagSubjects(String name) async =>
      (await discoverSubjects(waitForRefresh: true))
          .where((item) => item.tags.any((value) => value.name == name))
          .toList(growable: false);

  Future<List<AnimeSubject>> discoverSubjects({bool waitForRefresh = false}) {
    final fallback = _homeSubjects
        .where(
          (subject) =>
              subjectMatchesContentType(subject, SubjectContentType.anime),
        )
        .toList(growable: false);
    return _metadataSubjects(
      key: animeMetadataCacheKey,
      signature: _metadataSignature('anime'),
      contentType: SubjectContentType.anime,
      fallback: fallback,
      waitForRefresh: waitForRefresh,
    );
  }

  Future<List<AnimeSubject>> seriesSubjects({bool waitForRefresh = false}) {
    if (!_services.mediaMetadataEnabled) {
      return Future.value(
        _subjectsOfType(_fallbackSeries, SubjectContentType.series),
      );
    }
    return _metadataSubjects(
      key: seriesMetadataCacheKey,
      signature: _metadataSignature('series'),
      contentType: SubjectContentType.series,
      fallback: _fallbackSeries,
      waitForRefresh: waitForRefresh,
    );
  }

  Future<List<AnimeSubject>> movieSubjects({bool waitForRefresh = false}) {
    if (!_services.mediaMetadataEnabled) {
      return Future.value(
        _subjectsOfType(_fallbackMovies, SubjectContentType.movie),
      );
    }
    return _metadataSubjects(
      key: movieMetadataCacheKey,
      signature: _metadataSignature('movie'),
      contentType: SubjectContentType.movie,
      fallback: _fallbackMovies,
      waitForRefresh: waitForRefresh,
    );
  }

  Future<Map<int, List<AnimeSubject>>> weeklySchedule() async {
    final subjects = await discoverSubjects(waitForRefresh: true);
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
    final scope = _scope();
    final cacheKey = Object.hash(subject.source, subject.platform, subject.id);
    final cached = _snapshot.selectedSubjects[cacheKey];
    if (cached != null) {
      _prefetchPlayback(cached.subject, cached.episodes);
      return cached;
    }
    final base = await _loadDetail(subject, _services);
    _ensureScope(scope);
    final detail = await _enrichDetail(base, _services);
    _ensureScope(scope);
    _publish(
      scope,
      _snapshot.copyWith(
        selectedSubjects: {..._snapshot.selectedSubjects, cacheKey: detail},
      ),
    );
    _prefetchPlayback(detail.subject, detail.episodes);
    return detail;
  }

  Future<void> refreshHome() async {
    final scope = _scope();
    final refreshVersion = ++_homeRefreshVersion;
    final groups =
        await Future.wait([
          _loadHome(SubjectContentType.anime, _services),
          _loadHome(SubjectContentType.series, _services),
          _loadHome(SubjectContentType.movie, _services),
        ]).onError(
          (_, _) => const [
            <AnimeSubject>[],
            <AnimeSubject>[],
            <AnimeSubject>[],
          ],
        );
    if (!_isCurrent(scope) || refreshVersion != _homeRefreshVersion) return;
    final anime = _uniqueSubjects(groups[0]);
    if (anime.isEmpty) return;
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
    await _enqueueWrite(scope, homeFeedCacheKey, {
      'version': _homeFeedCacheVersion,
      'signature': _servicesSignature(_services),
      'fetchedAt': _now().toUtc().toIso8601String(),
      'feed': feed.toJson(),
    });
    if (!_isCurrent(scope) || refreshVersion != _homeRefreshVersion) return;
    _homeFresh = true;
    _publish(scope, _snapshot.copyWith(homeFeed: feed));
  }

  Future<void> applyServices(
    ExternalServiceSettings services, {
    required int contextVersion,
  }) async {
    final scope = _scope();
    if (scope.contextVersion != contextVersion) return;
    final changed =
        _servicesSignature(_services) != _servicesSignature(services);
    _services = services;
    if (!changed) return;
    _homeRefreshVersion++;
    _metadataRefreshes.clear();
    _latestMetadataRefreshes.clear();
    _publish(scope, _snapshot.copyWith(selectedSubjects: const {}));
    await _writeQueue;
    _ensureScope(scope);
    await Future.wait([
      _storage.delete(homeFeedCacheKey),
      _storage.delete(animeMetadataCacheKey),
      _storage.delete(seriesMetadataCacheKey),
      _storage.delete(movieMetadataCacheKey),
    ]);
    _ensureScope(scope);
    unawaited(refreshHome().onError((_, _) {}));
  }

  void clearDetailCache() {
    final scope = _scope();
    if (_snapshot.selectedSubjects.isEmpty) return;
    _publish(scope, _snapshot.copyWith(selectedSubjects: const {}));
  }

  Future<void> invalidateTmdbCredential() async {
    final scope = _scope();
    _homeRefreshVersion++;
    _latestMetadataRefreshes.remove(seriesMetadataCacheKey);
    _latestMetadataRefreshes.remove(movieMetadataCacheKey);
    _publish(scope, _snapshot.copyWith(selectedSubjects: const {}));
    await _writeQueue;
    _ensureScope(scope);
    await Future.wait([
      _storage.delete(homeFeedCacheKey),
      _storage.delete(seriesMetadataCacheKey),
      _storage.delete(movieMetadataCacheKey),
    ]);
    _ensureScope(scope);
    if (_services.mediaMetadataEnabled) {
      unawaited(refreshHome().onError((_, _) {}));
    }
  }

  Future<void> invalidateMetadataCache(String kind) {
    final key = switch (kind) {
      'series' => seriesMetadataCacheKey,
      'movie' => movieMetadataCacheKey,
      _ => animeMetadataCacheKey,
    };
    return _storage.delete(key);
  }

  Future<void> settleWrites() => _writeQueue;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _loaded = false;
    _scopeEpoch++;
    _homeRefreshVersion++;
    _metadataRefreshes.clear();
    _latestMetadataRefreshes.clear();
  }

  Future<List<AnimeSubject>> _metadataSubjects({
    required String key,
    required String signature,
    required SubjectContentType contentType,
    required List<AnimeSubject> fallback,
    required bool waitForRefresh,
  }) async {
    final scope = _scope();
    final cached = _readSubjectCache(key, signature);
    final cachedSubjects = _subjectsOfType(cached.subjects, contentType);
    final fallbackSubjects = _subjectsOfType(fallback, contentType);
    final initial = _uniqueSubjects([...cachedSubjects, ...fallbackSubjects]);
    if (cached.fresh) return initial;
    final refresh = _refreshSubjectCache(
      scope,
      key,
      signature,
      contentType,
    ).onError((_, _) => const <AnimeSubject>[]);
    if (!waitForRefresh) {
      unawaited(refresh);
      return initial;
    }
    final refreshed = _subjectsOfType(await refresh, contentType);
    _ensureScope(scope);
    return refreshed.isEmpty
        ? initial
        : _uniqueSubjects([
            ...refreshed,
            ...cachedSubjects,
            ...fallbackSubjects,
          ]);
  }

  Future<List<AnimeSubject>> _refreshSubjectCache(
    _CatalogScope scope,
    String key,
    String signature,
    SubjectContentType type,
  ) {
    final services = _services;
    final operationKey = '$key\u0000$signature';
    final active = _metadataRefreshes[operationKey];
    if (active != null && identical(_latestMetadataRefreshes[key], active)) {
      return active;
    }
    late final Future<List<AnimeSubject>> task;
    task = () async {
      final refreshed = uniqueCatalogSubjects(
        await _loadHome(type, services),
        preferChinese: services.preferBangumiChinese,
      );
      if (refreshed.isEmpty || !_isCurrent(scope)) {
        return const <AnimeSubject>[];
      }
      final subjects = _uniqueSubjects([
        ...refreshed,
        ..._compatibleCachedSubjects(key, signature),
      ]);
      if (!identical(_latestMetadataRefreshes[key], task)) {
        return const <AnimeSubject>[];
      }
      await _enqueueWrite(scope, key, {
        'version': _metadataCacheVersion,
        'signature': signature,
        'fetchedAt': _now().toUtc().toIso8601String(),
        'refreshCount': refreshed.length,
        'subjects': subjects
            .take(_metadataCacheLimit)
            .map((item) => item.toJson())
            .toList(growable: false),
      });
      return _isCurrent(scope) && identical(_latestMetadataRefreshes[key], task)
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

  _HomeFeedCacheSnapshot _readHomeFeedCache(String signature) {
    final value = _storage.get(homeFeedCacheKey);
    if (value is! Map ||
        value['version'] != _homeFeedCacheVersion ||
        value['signature']?.toString() != signature ||
        value['feed'] is! Map) {
      return const _HomeFeedCacheSnapshot();
    }
    try {
      final feed = AnimeHomeFeed.fromJson(
        (value['feed'] as Map).cast<String, dynamic>(),
      );
      final fetchedAt = DateTime.tryParse(value['fetchedAt']?.toString() ?? '');
      final age = fetchedAt == null
          ? null
          : _now().toUtc().difference(fetchedAt.toUtc());
      return _HomeFeedCacheSnapshot(
        feed: feed,
        fresh: age != null && !age.isNegative && age <= _homeFeedCacheTtl,
      );
    } catch (_) {
      return const _HomeFeedCacheSnapshot();
    }
  }

  _SubjectCacheSnapshot _readSubjectCache(String key, String signature) {
    final value = _storage.get(key);
    if (value is! Map || value['subjects'] is! List) {
      return const _SubjectCacheSnapshot();
    }
    final subjects = <AnimeSubject>[];
    for (final raw in (value['subjects'] as List).whereType<Map>()) {
      try {
        final subject = AnimeSubject.fromJson(raw.cast<String, dynamic>());
        if (subject.title.trim().isNotEmpty) subjects.add(subject);
      } catch (_) {
        // Preserve malformed cache data; skip only the unreadable row.
      }
    }
    final fetchedAt = DateTime.tryParse(value['fetchedAt']?.toString() ?? '');
    final refreshCount = (value['refreshCount'] as num?)?.toInt() ?? 0;
    final ttl = _isSparseMetadataResult(key, refreshCount)
        ? _sparseMetadataCacheTtl
        : _metadataCacheTtl;
    final age = fetchedAt == null ? null : _now().difference(fetchedAt);
    return _SubjectCacheSnapshot(
      subjects: subjects,
      fresh:
          value['version'] == _metadataCacheVersion &&
          value['signature']?.toString() == signature &&
          age != null &&
          !age.isNegative &&
          age <= ttl,
    );
  }

  List<AnimeSubject> _compatibleCachedSubjects(String key, String signature) {
    final value = _storage.get(key);
    if (value is! Map ||
        value['version'] != _metadataCacheVersion ||
        value['signature']?.toString() != signature ||
        value['subjects'] is! List) {
      return const [];
    }
    final subjects = <AnimeSubject>[];
    for (final raw in (value['subjects'] as List).whereType<Map>()) {
      try {
        final subject = AnimeSubject.fromJson(raw.cast<String, dynamic>());
        if (subject.title.trim().isNotEmpty) subjects.add(subject);
      } catch (_) {
        // Keep refresh resilient without rewriting the unreadable source row.
      }
    }
    return subjects;
  }

  bool _isSparseMetadataResult(String key, int count) {
    final expected = switch (key) {
      animeMetadataCacheKey => 120,
      seriesMetadataCacheKey => 250,
      movieMetadataCacheKey => 250,
      _ => 1,
    };
    return count < expected;
  }

  List<AnimeSubject> _subjectsOfType(
    Iterable<AnimeSubject> subjects,
    SubjectContentType type,
  ) => _uniqueSubjects(
    subjects.where((subject) => subjectMatchesContentType(subject, type)),
  );

  List<AnimeSubject> get _homeSubjects => _uniqueSubjects([
    _snapshot.homeFeed.hero,
    ..._snapshot.homeFeed.index,
    ..._snapshot.homeFeed.recommended,
    ..._snapshot.homeFeed.recent,
  ]);

  String _metadataSignature(String kind) =>
      '$kind:${_servicesSignature(_services)}';

  String _servicesSignature(ExternalServiceSettings services) =>
      '${SettingsController.servicesSignature(services)}|'
      '${SettingsController.playbackBackendSignature(services)}';

  Future<void> _enqueueWrite(_CatalogScope scope, String key, Object value) {
    final operation = _writeQueue.then((_) async {
      if (!_isCurrent(scope)) return;
      await _storage.put(key, value);
    });
    _writeQueue = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  void _publish(_CatalogScope scope, CatalogSnapshot snapshot) {
    _ensureScope(scope);
    _snapshot = _freeze(snapshot);
    _publishSnapshot(_snapshot);
  }

  CatalogSnapshot _freeze(CatalogSnapshot snapshot) => CatalogSnapshot(
    homeFeed: snapshot.homeFeed,
    selectedSubjects: Map<int, AnimeDetailBundle>.unmodifiable(
      snapshot.selectedSubjects,
    ),
  );

  _CatalogScope _scope() {
    _ensureNotDisposed();
    if (!_loaded) throw StateError('CatalogController has not been loaded');
    return _CatalogScope(
      accountId: _accountId,
      contextVersion: _contextVersion,
      epoch: _scopeEpoch,
    );
  }

  bool _isConfigured(_CatalogScope scope) =>
      !_disposed &&
      scope.accountId == _accountId &&
      scope.contextVersion == _contextVersion &&
      scope.epoch == _scopeEpoch;

  bool _isCurrent(_CatalogScope scope) => _loaded && _isConfigured(scope);

  void _ensureConfigured(_CatalogScope scope) {
    if (!_isConfigured(scope)) {
      throw const AccountException('账号已切换，请重新打开内容目录');
    }
  }

  void _ensureScope(_CatalogScope scope) {
    if (!_isCurrent(scope)) {
      throw const AccountException('账号已切换，请在当前账号下重新操作');
    }
  }

  void _ensureNotDisposed() {
    if (_disposed) throw StateError('CatalogController has been disposed');
  }

  List<AnimeSubject> _uniqueSubjects(Iterable<AnimeSubject> subjects) =>
      uniqueCatalogSubjects(
        subjects,
        preferChinese: _services.preferBangumiChinese,
      );
}

final class _CatalogScope {
  const _CatalogScope({
    required this.accountId,
    required this.contextVersion,
    required this.epoch,
  });

  final String? accountId;
  final int contextVersion;
  final int epoch;
}

final class _HomeFeedCacheSnapshot {
  const _HomeFeedCacheSnapshot({this.feed, this.fresh = false});

  final AnimeHomeFeed? feed;
  final bool fresh;
}

final class _SubjectCacheSnapshot {
  const _SubjectCacheSnapshot({this.subjects = const [], this.fresh = false});

  final List<AnimeSubject> subjects;
  final bool fresh;
}

List<AnimeSubject> uniqueCatalogSubjects(
  Iterable<AnimeSubject> subjects, {
  required bool preferChinese,
}) {
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
      preferChinese: preferChinese,
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
    stableKey: primary.identityKey,
    legacyId: primary.legacyId,
    legacyIds: primary.legacyIds,
  );
}

int _subjectQuality(AnimeSubject subject) {
  var score = 0;
  if ((subject.bannerUrl ?? '').isNotEmpty) score += 16;
  if ((subject.coverUrl ?? '').isNotEmpty) score += 8;
  if (isLikelyChineseTitle(subject.title)) score += 4;
  if (!isMetadataPlaceholder(subject.summary) && subject.summary.length >= 80) {
    score += 3;
  }
  if (subject.ratingScore != null) score += 3;
  if (subject.totalEpisodes > 0) score += 2;
  return score;
}

bool _isDirectPlayable(AnimeSubject subject) =>
    subject.source.startsWith('archive:') ||
    subject.source.startsWith('peertube:') ||
    subject.source.startsWith('commons:');

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
