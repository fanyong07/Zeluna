import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../domain/anime_models.dart';

extension _DateSeed on DateTime {
  int get dayOfYear => difference(DateTime(year)).inDays + 1;
}

class _PagedResponse {
  const _PagedResponse.succeeded({
    required this.data,
    required this.total,
    required this.limit,
  }) : succeeded = true;

  const _PagedResponse.failed()
    : data = const [],
      total = 0,
      limit = 0,
      succeeded = false;

  final List<dynamic> data;
  final int total;
  final int limit;
  final bool succeeded;
}

class BangumiMetadataRepository {
  BangumiMetadataRepository({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;

  static const _baseUrl = 'https://api.bgm.tv';
  static const _recentWindow = Duration(days: 180);
  static const _distinctHomePrefix = 18;
  static const _subjectPageSize = 20;
  static const _episodePageSize = 100;
  static const _headers = {
    'User-Agent': 'anime-app/1.0 (AniCh-style client)',
    'Accept': 'application/json',
  };

  AnimeHomeFeed fallbackHomeFeed() => _fallbackFeed;

  Future<AnimeHomeFeed> homeFeed() async {
    try {
      final recentFloor = _dateText(DateTime.now().subtract(_recentWindow));
      final batches = await Future.wait([
        _searchSubjectPages(
          keyword: '',
          sort: 'heat',
          filters: {
            'type': const [2],
            'air_date': ['>=$recentFloor'],
          },
          pageSize: 28,
          pages: 3,
        ),
        _searchSubjectPages(
          keyword: '',
          sort: 'score',
          filters: const {
            'type': [2],
          },
          pageSize: 30,
          pages: 3,
        ),
        _searchSubjectPages(
          keyword: '',
          sort: 'rank',
          filters: const {
            'type': [2],
          },
          pageSize: 42,
          pages: 3,
        ),
      ]).timeout(const Duration(seconds: 20));

      if (batches.every((items) => items.isEmpty)) return _fallbackFeed;

      final recentCandidates = _rankHomeSubjects(
        batches[0].isEmpty ? _fallbackSubjects : batches[0],
      );
      final recommendedCandidates = _rankHomeSubjects([
        ...(batches[1].isEmpty ? _fallbackSubjects : batches[1]),
        ...(batches[2].isEmpty ? _fallbackSubjects : batches[2]),
      ]);
      final index = _uniqueSubjects(
        batches[2].isEmpty ? _fallbackSubjects : batches[2],
      );
      final hero = _rankHomeSubjects([
        ...recentCandidates,
        ...recommendedCandidates,
      ]).firstOrNull;
      if (hero == null) return _fallbackFeed;

      final recent = recentCandidates
          .where((subject) => subject.id != hero.id)
          .toList(growable: false);
      final reservedIds = <int>{
        hero.id,
        ...recent.take(_distinctHomePrefix).map((subject) => subject.id),
      };
      final unseenRecommended = recommendedCandidates
          .where((subject) => !reservedIds.contains(subject.id))
          .toList(growable: false);
      final recommended = unseenRecommended.length < _distinctHomePrefix
          ? unseenRecommended
          : [
              ...unseenRecommended,
              ...recommendedCandidates.where(
                (subject) =>
                    subject.id != hero.id && reservedIds.contains(subject.id),
              ),
            ];
      return AnimeHomeFeed(
        hero: hero,
        recent: recent,
        recommended: recommended,
        index: index,
        categories: _buildCategories([
          hero,
          ...recent,
          ...recommended,
          ...index,
        ]),
        tags: _buildTags([hero, ...recent, ...recommended, ...index]),
      );
    } catch (_) {
      return _fallbackFeed;
    }
  }

  Future<List<AnimeSubject>> subjectsByCategory(String categoryName) async {
    final name = categoryName.trim();
    if (name.isEmpty) return const [];
    final results = await Future.wait([
      searchSubjects(
        keyword: '',
        sort: 'heat',
        filters: {
          'type': [2],
          'tag': [name],
        },
        limit: 48,
      ),
      searchSubjects(
        keyword: '',
        sort: 'heat',
        filters: {
          'type': [2],
          'meta_tags': [name],
        },
        limit: 48,
      ),
      searchSubjects(keyword: name, sort: 'match', limit: 24),
    ]).timeout(const Duration(seconds: 20), onTimeout: () => const []);
    return _uniqueSubjects(results.expand((items) => items));
  }

  Future<List<AnimeSubject>> subjectsByTag(String tagName) async {
    final name = tagName.trim();
    if (name.isEmpty) return const [];
    final results = await Future.wait([
      searchSubjects(
        keyword: '',
        sort: 'heat',
        filters: {
          'type': [2],
          'tag': [name],
        },
        limit: 60,
      ),
      searchSubjects(keyword: name, sort: 'match', limit: 36),
    ]).timeout(const Duration(seconds: 20), onTimeout: () => const []);
    return _uniqueSubjects(results.expand((items) => items));
  }

  Future<Map<int, List<AnimeSubject>>> weeklySchedule() async {
    final recentFloor = _dateText(DateTime.now().subtract(_recentWindow));
    final subjects = await _searchSubjectPages(
      keyword: '',
      sort: 'heat',
      filters: {
        'type': const [2],
        'air_date': ['>=$recentFloor'],
      },
      pageSize: 42,
      pages: 3,
    ).timeout(const Duration(seconds: 20), onTimeout: () => const []);
    return _groupByWeekday(subjects.isEmpty ? _fallbackSubjects : subjects);
  }

  Future<List<AnimeSubject>> discoverySubjects() async {
    final batches = await Future.wait([
      _searchSubjectPages(
        keyword: '',
        sort: 'heat',
        filters: const {
          'type': [2],
        },
        pageSize: 36,
        pages: 4,
      ).onError((_, _) => const <AnimeSubject>[]),
      _searchSubjectPages(
        keyword: '',
        sort: 'rank',
        filters: const {
          'type': [2],
        },
        pageSize: 36,
        pages: 4,
      ).onError((_, _) => const <AnimeSubject>[]),
      _searchSubjectPages(
        keyword: '',
        sort: 'score',
        filters: const {
          'type': [2],
        },
        pageSize: 36,
        pages: 4,
      ).onError((_, _) => const <AnimeSubject>[]),
    ]).timeout(const Duration(seconds: 20), onTimeout: () => const []);
    return _uniqueSubjects(batches.expand((items) => items));
  }

  Future<List<AnimeSubject>> searchSubjects({
    required String keyword,
    String sort = 'match',
    Map<String, Object?> filters = const {
      'type': [2],
    },
    int limit = 24,
    int offset = 0,
  }) async {
    final requestLimit = limit.clamp(1, _subjectPageSize).toInt();
    final uri = Uri.parse(
      '$_baseUrl/v0/search/subjects',
    ).replace(queryParameters: {'limit': '$requestLimit', 'offset': '$offset'});
    final response = await _client.post(
      uri,
      headers: const {..._headers, 'Content-Type': 'application/json'},
      body: jsonEncode({'keyword': keyword, 'sort': sort, 'filter': filters}),
    );
    if (response.statusCode != 200) return const [];
    final json = _decodeResponse(response);
    final data = json['data'];
    if (data is! List) return const [];
    return data
        .whereType<Map>()
        .map((item) => _subjectFromJson(item.cast<String, dynamic>()))
        .where((item) => item.title.trim().isNotEmpty)
        .toList();
  }

  Future<List<AnimeSubject>> _searchSubjectPages({
    required String keyword,
    required String sort,
    required Map<String, Object?> filters,
    required int pageSize,
    required int pages,
  }) async {
    final requestPageSize = pageSize.clamp(1, _subjectPageSize).toInt();
    final batches = await Future.wait([
      for (var page = 0; page < pages; page++)
        searchSubjects(
          keyword: keyword,
          sort: sort,
          filters: filters,
          limit: requestPageSize,
          offset: page * requestPageSize,
        ).onError((_, _) => const <AnimeSubject>[]),
    ]);
    return _uniqueSubjects(batches.expand((items) => items));
  }

  Future<AnimeDetailBundle> detail(int subjectId) async {
    try {
      final results = await Future.wait([
        _getObject('/v0/subjects/$subjectId'),
        _getAllPaged('/v0/episodes', {'subject_id': '$subjectId', 'type': '0'}),
        _getList('/v0/subjects/$subjectId/characters'),
        _getList('/v0/subjects/$subjectId/persons'),
        _getList('/v0/subjects/$subjectId/subjects'),
      ]).timeout(const Duration(seconds: 22));

      final subject = _subjectFromJson(results[0] as Map<String, dynamic>);
      final episodes =
          (results[1] as List)
              .whereType<Map>()
              .map(
                (item) =>
                    _episodeFromJson(item.cast<String, dynamic>(), subject),
              )
              .where((item) => item.number > 0)
              .toList()
            ..sort((a, b) => a.number.compareTo(b.number));
      final characters = (results[2] as List)
          .whereType<Map>()
          .map((item) => _characterFromJson(item.cast<String, dynamic>()))
          .toList();
      final staff = (results[3] as List)
          .whereType<Map>()
          .map((item) => _staffFromJson(item.cast<String, dynamic>()))
          .toList();
      final recommendations = (results[4] as List)
          .whereType<Map>()
          .map((item) => _recommendationFromJson(item.cast<String, dynamic>()))
          .whereType<AnimeRecommendation>()
          .toList();

      return AnimeDetailBundle(
        subject: subject.copyWith(
          totalEpisodes: episodes.isEmpty
              ? subject.totalEpisodes
              : episodes.length,
          status: episodes.isEmpty ? subject.status : '全${episodes.length}集',
        ),
        episodes: episodes.isEmpty ? _fallbackEpisodes(subject) : episodes,
        characters: characters.isEmpty ? _fallbackCharacters : characters,
        staff: staff.isEmpty ? _fallbackStaff : staff,
        recommendations: recommendations.isEmpty
            ? _fallbackRecommendations(subject)
            : recommendations,
      );
    } catch (_) {
      final subject = _fallbackSubjects.firstWhere(
        (item) => item.id == subjectId,
        orElse: () => _fallbackSubjects.first,
      );
      return AnimeDetailBundle(
        subject: subject,
        episodes: _fallbackEpisodes(subject),
        characters: _fallbackCharacters,
        staff: _fallbackStaff,
        recommendations: _fallbackRecommendations(subject),
      );
    }
  }

  Future<Map<String, dynamic>> _getObject(String path) async {
    final response = await _client.get(
      Uri.parse('$_baseUrl$path'),
      headers: _headers,
    );
    if (response.statusCode != 200) return const {};
    return _decodeResponse(response);
  }

  Future<List<dynamic>> _getList(String path) async {
    final response = await _client.get(
      Uri.parse('$_baseUrl$path'),
      headers: _headers,
    );
    if (response.statusCode != 200) return const [];
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    return decoded is List ? decoded : const [];
  }

  Future<List<dynamic>> _getAllPaged(
    String path,
    Map<String, String> query,
  ) async {
    final firstPage = await _getPagedPage(path, {
      ...query,
      'limit': '$_episodePageSize',
      'offset': '0',
    });
    if (!firstPage.succeeded) return const [];

    final items = <dynamic>[...firstPage.data];
    final total = firstPage.total > 0 ? firstPage.total : items.length;
    final pageSize = firstPage.limit > 0 ? firstPage.limit : _episodePageSize;
    if (items.length >= total || pageSize <= 0) return items;

    final remainingPages = await Future.wait([
      for (var offset = pageSize; offset < total; offset += pageSize)
        _getPagedPage(path, {
          ...query,
          'limit': '$pageSize',
          'offset': '$offset',
        }).onError((_, _) => const _PagedResponse.failed()),
    ]);
    for (final page in remainingPages) {
      if (page.succeeded) items.addAll(page.data);
    }
    return items;
  }

  Future<_PagedResponse> _getPagedPage(
    String path,
    Map<String, String> query,
  ) async {
    final response = await _client.get(
      Uri.parse('$_baseUrl$path').replace(queryParameters: query),
      headers: _headers,
    );
    if (response.statusCode != 200) return const _PagedResponse.failed();
    final json = _decodeResponse(response);
    final data = json['data'];
    if (data is! List) return const _PagedResponse.failed();
    return _PagedResponse.succeeded(
      data: data,
      total: _intValue(json['total']) ?? data.length,
      limit:
          _intValue(json['limit']) ??
          int.tryParse(query['limit'] ?? '') ??
          data.length,
    );
  }

  Map<String, dynamic> _decodeResponse(http.Response response) {
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    return decoded is Map<String, dynamic> ? decoded : const {};
  }

  AnimeSubject _subjectFromJson(Map<String, dynamic> json) {
    final images = _map(json['images']);
    final tags = _tagsFromJson(json['tags']);
    final metaTags = _stringList(json['meta_tags']);
    final categories = _categoriesFrom(
      metaTags,
      tags,
      json['platform']?.toString(),
    );
    final rating = _map(json['rating']);
    final title = _bestTitle(json['name_cn'], json['name']);
    final originalTitle = json['name']?.toString() ?? title;
    final date = _blankToNull(json['date']?.toString());
    final platform = _blankToNull(json['platform']?.toString()) ?? 'TV';
    final total =
        _intValue(json['total_episodes']) ?? _intValue(json['eps']) ?? 0;
    return AnimeSubject(
      id: _intValue(json['id']) ?? 0,
      title: title,
      originalTitle: originalTitle,
      summary: _cleanSummary(json['summary']?.toString()),
      coverUrl:
          _blankToNull(images['large']?.toString()) ??
          _blankToNull(images['common']?.toString()) ??
          _blankToNull(json['image']?.toString()),
      bannerUrl: null,
      date: date,
      platform: platform,
      language: _languageFrom(metaTags, originalTitle),
      region: _regionFrom(metaTags, originalTitle),
      status: total > 0 ? '全$total集' : '未确定',
      categories: categories,
      tags: tags,
      totalEpisodes: total,
      ratingScore: (rating['score'] as num?)?.toDouble(),
      ratingRank: _intValue(rating['rank']),
      ratingTotal: _intValue(rating['total']),
    );
  }

  AnimeEpisode _episodeFromJson(
    Map<String, dynamic> json,
    AnimeSubject subject,
  ) {
    final ep = (json['ep'] as num?)?.round();
    final sort = (json['sort'] as num?)?.round();
    final number = ep ?? sort ?? 0;
    final title = _bestTitle(json['name_cn'], json['name']);
    return AnimeEpisode(
      id: _intValue(json['id']) ?? number,
      subjectId: subject.id,
      number: number,
      title: title.startsWith('第') ? '' : title,
      airdate: _blankToNull(json['airdate']?.toString()),
      duration:
          _blankToNull(json['duration']?.toString()) ??
          _formatSeconds(_intValue(json['duration_seconds']) ?? 0),
      description: _cleanSummary(json['desc']?.toString()),
      thumbnailUrl: subject.coverUrl,
    );
  }

  AnimeCharacter _characterFromJson(Map<String, dynamic> json) {
    final actors = json['actors'] is List ? json['actors'] as List : const [];
    final cv = actors
        .whereType<Map>()
        .map((item) => _bestTitle(item['name_cn'], item['name']))
        .where((item) => item.isNotEmpty)
        .take(2)
        .join(' / ');
    return AnimeCharacter(
      id: _intValue(json['id']) ?? 0,
      name: _bestTitle(json['name_cn'], json['name']),
      relation: _blankToNull(json['relation']?.toString()) ?? '角色',
      cv: cv.isEmpty ? '未知' : cv,
      summary: _cleanSummary(json['summary']?.toString()),
      imageUrl: _imageFrom(json['images']),
    );
  }

  AnimeStaff _staffFromJson(Map<String, dynamic> json) {
    final career = _stringList(json['career']).join('/');
    return AnimeStaff(
      id: _intValue(json['id']) ?? 0,
      name: _bestTitle(json['name_cn'], json['name']),
      role: _blankToNull(json['relation']?.toString()) ?? '制作人员',
      career: career.isEmpty
          ? _blankToNull(json['eps']?.toString()) ?? '制作'
          : career,
      imageUrl: _imageFrom(json['images']),
    );
  }

  AnimeRecommendation? _recommendationFromJson(Map<String, dynamic> json) {
    final id = _intValue(json['id']);
    if (id == null) return null;
    final subject = AnimeSubject(
      id: id,
      title: _bestTitle(json['name_cn'], json['name']),
      originalTitle: json['name']?.toString() ?? '',
      summary: '',
      coverUrl: _imageFrom(json['images']),
      bannerUrl: null,
      date: null,
      platform: '',
      language: '日语',
      region: '日本',
      status: '',
      categories: const [AnimeCategory(name: '动画')],
      tags: const [],
      totalEpisodes: 0,
    );
    return AnimeRecommendation(
      subject: subject,
      relation: _blankToNull(json['relation']?.toString()) ?? '相关',
    );
  }

  List<AnimeTag> _tagsFromJson(Object? value) {
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map(
          (item) => AnimeTag(
            name: item['name']?.toString() ?? '',
            count: _intValue(item['count']) ?? 0,
          ),
        )
        .where((item) => item.name.isNotEmpty)
        .take(28)
        .toList();
  }

  List<AnimeCategory> _categoriesFrom(
    List<String> metaTags,
    List<AnimeTag> tags,
    String? platform,
  ) {
    final names = <String>{};
    final all = [...metaTags, ...tags.map((item) => item.name), ?platform];
    for (final item in all) {
      if (_categoryNames.contains(item)) names.add(item);
      if (item.contains('动画')) names.add('动画');
      if (item.contains('喜剧')) names.add('喜剧');
      if (item.contains('奇幻')) names.add('奇幻');
      if (item.contains('动作')) names.add('动作冒险');
      if (item.contains('冒险')) names.add('冒险');
      if (item.contains('剧情')) names.add('剧情');
      if (item.contains('科幻')) names.add('科幻');
      if (item.contains('校园')) names.add('校园');
    }
    if (names.isEmpty) names.add('动画');
    return names.take(4).map((name) => AnimeCategory(name: name)).toList();
  }

  List<AnimeCategory> _buildCategories(List<AnimeSubject> subjects) {
    final uniqueSubjects = _uniqueSubjects(subjects);
    final counts = <String, int>{};
    final candidates = <String, List<AnimeSubject>>{};
    for (final subject in uniqueSubjects) {
      for (final category in subject.categories) {
        counts[category.name] = (counts[category.name] ?? 0) + 1;
        candidates.putIfAbsent(category.name, () => []).add(subject);
      }
    }
    final entries = counts.entries.toList()
      ..sort((a, b) {
        final countOrder = b.value.compareTo(a.value);
        return countOrder != 0 ? countOrder : a.key.compareTo(b.key);
      });
    final usedImages = <String>{};
    return [
      for (final entry in entries.take(60))
        AnimeCategory(
          name: entry.key,
          count: entry.value,
          imageUrl: _representativeImage(
            candidates[entry.key] ?? const [],
            usedImages,
          ),
        ),
    ];
  }

  List<AnimeTag> _buildTags(List<AnimeSubject> subjects) {
    final uniqueSubjects = _uniqueSubjects(subjects);
    final counts = <String, int>{};
    final candidates = <String, List<AnimeSubject>>{};
    for (final subject in uniqueSubjects) {
      for (final tag in subject.tags) {
        counts[tag.name] = max(counts[tag.name] ?? 0, tag.count);
        candidates.putIfAbsent(tag.name, () => []).add(subject);
      }
    }
    final entries = counts.entries.toList()
      ..sort((a, b) {
        final countOrder = b.value.compareTo(a.value);
        return countOrder != 0 ? countOrder : a.key.compareTo(b.key);
      });
    final usedImages = <String>{};
    return [
      for (final entry in entries.take(90))
        AnimeTag(
          name: entry.key,
          count: entry.value,
          imageUrl: _representativeImage(
            candidates[entry.key] ?? const [],
            usedImages,
          ),
        ),
    ];
  }

  List<AnimeSubject> _uniqueSubjects(Iterable<AnimeSubject> subjects) {
    final seen = <int>{};
    final unique = <AnimeSubject>[];
    for (final subject in subjects) {
      if (subject.id <= 0 || !seen.add(subject.id)) continue;
      unique.add(subject);
    }
    return unique;
  }

  List<AnimeSubject> _rankHomeSubjects(Iterable<AnimeSubject> subjects) {
    final unique = _uniqueSubjects(subjects);
    if (unique.length <= 1) return unique;
    final now = DateTime.now();
    final seed = now.year * 1000 + now.dayOfYear;
    final ranked =
        [
          for (final subject in unique)
            MapEntry(_homeQualityScore(subject, now), subject),
        ]..sort((a, b) {
          final scoreOrder = b.key.compareTo(a.key);
          if (scoreOrder != 0) return scoreOrder;
          return _stableDailyScore(
            a.value,
            seed,
          ).compareTo(_stableDailyScore(b.value, seed));
        });
    return ranked.map((entry) => entry.value).toList(growable: false);
  }

  int _homeQualityScore(AnimeSubject subject, DateTime now) {
    var score = 0;
    if (subject.coverUrl != null) score += 1000;
    if (subject.bannerUrl != null) score += 250;

    final date = DateTime.tryParse(subject.date ?? '');
    if (date != null) {
      final age = now.difference(date).inDays;
      score += age < 0 ? 620 : max(0, 600 - age * 2);
    }

    final ratingScore = subject.ratingScore;
    if (ratingScore != null) score += 180 + (ratingScore * 18).round();
    final ratingTotal = subject.ratingTotal;
    if (ratingTotal != null && ratingTotal > 0) {
      score += min(180, (log(ratingTotal + 1) * 18).round());
    }
    final ratingRank = subject.ratingRank;
    if (ratingRank != null && ratingRank > 0) {
      score += max(0, 120 - ratingRank ~/ 100);
    }
    if (ratingScore != null && ratingTotal != null && ratingRank != null) {
      score += 120;
    }
    return score;
  }

  String? _representativeImage(
    Iterable<AnimeSubject> subjects,
    Set<String> usedImages,
  ) {
    final images = _rankHomeSubjects(subjects)
        .map((subject) => subject.bannerUrl ?? subject.coverUrl)
        .whereType<String>()
        .where((image) => image.trim().isNotEmpty)
        .toList(growable: false);
    for (final image in images) {
      if (usedImages.add(image)) return image;
    }
    return images.firstOrNull;
  }

  Map<int, List<AnimeSubject>> _groupByWeekday(List<AnimeSubject> subjects) {
    final result = {for (var i = 0; i < 7; i++) i: <AnimeSubject>[]};
    for (final subject in subjects) {
      final date = DateTime.tryParse(subject.date ?? '');
      final weekday = date == null ? subject.id % 7 : date.weekday % 7;
      result[weekday]!.add(subject);
    }
    for (final entry in result.entries) {
      entry.value.sort((a, b) => (b.date ?? '').compareTo(a.date ?? ''));
    }
    return result;
  }

  Map<String, dynamic> _map(Object? value) {
    if (value is Map) return value.cast<String, dynamic>();
    return const {};
  }

  List<String> _stringList(Object? value) {
    if (value is List) return value.map((item) => item.toString()).toList();
    if (value is String && value.isNotEmpty) return [value];
    return const [];
  }

  String? _imageFrom(Object? images) {
    final map = _map(images);
    return _blankToNull(map['large']?.toString()) ??
        _blankToNull(map['medium']?.toString()) ??
        _blankToNull(map['grid']?.toString()) ??
        _blankToNull(map['small']?.toString());
  }

  String _bestTitle(Object? cn, Object? original) {
    final cnText = cn?.toString().trim() ?? '';
    if (cnText.isNotEmpty) return cnText;
    return original?.toString().trim() ?? '';
  }

  int? _intValue(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '');
  }

  String? _blankToNull(String? value) {
    final text = value?.trim();
    if (text == null || text.isEmpty) return null;
    return text;
  }

  String _cleanSummary(String? value) {
    final text = value?.trim();
    if (text == null || text.isEmpty) return '暂无简介。';
    return text.replaceAll(RegExp(r'\s+'), ' ');
  }

  String _formatSeconds(int seconds) {
    if (seconds <= 0) return '';
    final minutes = (seconds ~/ 60).toString().padLeft(2, '0');
    final rest = (seconds % 60).toString().padLeft(2, '0');
    return '$minutes:$rest';
  }

  String _dateText(DateTime date) {
    final month = '${date.month}'.padLeft(2, '0');
    final day = '${date.day}'.padLeft(2, '0');
    return '${date.year}-$month-$day';
  }

  String _languageFrom(List<String> tags, String originalTitle) {
    final text = '${tags.join('/')} $originalTitle'.toLowerCase();
    if (text.contains('国产') || text.contains('中国')) return '国语';
    if (text.contains('欧美') || text.contains('english')) return '英语';
    if (text.contains('韩国')) return '韩语';
    return '日语';
  }

  String _regionFrom(List<String> tags, String originalTitle) {
    final text = '${tags.join('/')} $originalTitle'.toLowerCase();
    if (text.contains('国产') || text.contains('中国')) return '中国';
    if (text.contains('欧美') || text.contains('english')) return '欧美';
    if (text.contains('韩国')) return '韩国';
    return '日本';
  }
}

const _categoryNames = {
  '动画',
  '喜剧',
  '奇幻',
  '家庭',
  '儿童',
  '动作冒险',
  '剧情',
  '冒险',
  '动作',
  '科幻',
  '悬疑',
  '战斗',
  '音乐',
  '校园',
  '恋爱',
  '日常',
};

final _fallbackSubjects = [
  const AnimeSubject(
    id: 489888,
    title: '孤独摇滚！',
    originalTitle: 'ぼっち・ざ・ろっく！',
    summary: '极度怕生的少女后藤一里因为吉他结识乐队伙伴，在舞台和日常里一点点靠近自己真正想成为的样子。',
    coverUrl: 'https://lain.bgm.tv/pic/cover/l/39/88/328609_pRZqu.jpg',
    bannerUrl: null,
    date: '2022-10-08',
    platform: 'TV',
    language: '日语',
    region: '日本',
    status: '全12集',
    categories: [
      AnimeCategory(name: '动画'),
      AnimeCategory(name: '音乐'),
      AnimeCategory(name: '日常'),
    ],
    tags: [
      AnimeTag(name: '音乐', count: 120),
      AnimeTag(name: '乐队', count: 88),
      AnimeTag(name: '芳文社', count: 61),
    ],
    totalEpisodes: 12,
    ratingScore: 8.3,
    ratingRank: 130,
    ratingTotal: 12000,
  ),
  const AnimeSubject(
    id: 367247,
    title: '葬送的芙莉莲',
    originalTitle: '葬送のフリーレン',
    summary: '勇者一行讨伐魔王之后，长寿精灵芙莉莲重新踏上旅途，学习理解人类短暂却明亮的一生。',
    coverUrl: 'https://lain.bgm.tv/pic/cover/l/7f/b1/400602_Z4B4z.jpg',
    bannerUrl: null,
    date: '2023-09-29',
    platform: 'TV',
    language: '日语',
    region: '日本',
    status: '全28集',
    categories: [
      AnimeCategory(name: '动画'),
      AnimeCategory(name: '奇幻'),
      AnimeCategory(name: '冒险'),
    ],
    tags: [
      AnimeTag(name: '奇幻', count: 160),
      AnimeTag(name: '旅行', count: 70),
      AnimeTag(name: '漫画改', count: 110),
    ],
    totalEpisodes: 28,
    ratingScore: 8.8,
    ratingRank: 30,
    ratingTotal: 16000,
  ),
  const AnimeSubject(
    id: 464376,
    title: '迷宫饭',
    originalTitle: 'ダンジョン飯',
    summary: '一支冒险队深入地下城救人，同时认真研究如何把沿途魔物做成一顿像样的饭。',
    coverUrl: 'https://lain.bgm.tv/pic/cover/l/fb/84/395378_HoH00.jpg',
    bannerUrl: null,
    date: '2024-01-04',
    platform: 'TV',
    language: '日语',
    region: '日本',
    status: '全24集',
    categories: [
      AnimeCategory(name: '动画'),
      AnimeCategory(name: '奇幻'),
      AnimeCategory(name: '喜剧'),
    ],
    tags: [
      AnimeTag(name: '美食', count: 78),
      AnimeTag(name: '奇幻', count: 120),
      AnimeTag(name: 'TRIGGER', count: 64),
    ],
    totalEpisodes: 24,
    ratingScore: 8.1,
    ratingRank: 220,
    ratingTotal: 9800,
  ),
];

AnimeHomeFeed get _fallbackFeed {
  final recommended = _rotateSubjectsForToday(_fallbackSubjects);
  return AnimeHomeFeed(
    hero: recommended.firstOrNull ?? _fallbackSubjects.first,
    recent: _fallbackSubjects,
    recommended: recommended,
    index: _fallbackSubjects,
    categories: const [
      AnimeCategory(
        name: '动画',
        count: 35681,
        imageUrl: 'https://lain.bgm.tv/pic/cover/l/7f/b1/400602_Z4B4z.jpg',
      ),
      AnimeCategory(
        name: '喜剧',
        count: 11599,
        imageUrl: 'https://lain.bgm.tv/pic/cover/l/fb/84/395378_HoH00.jpg',
      ),
      AnimeCategory(
        name: '奇幻',
        count: 8676,
        imageUrl: 'https://lain.bgm.tv/pic/cover/l/39/88/328609_pRZqu.jpg',
      ),
    ],
    tags: const [
      AnimeTag(
        name: 'TV',
        count: 12883,
        imageUrl: 'https://lain.bgm.tv/pic/cover/l/39/88/328609_pRZqu.jpg',
      ),
      AnimeTag(
        name: '日本',
        count: 10822,
        imageUrl: 'https://lain.bgm.tv/pic/cover/l/7f/b1/400602_Z4B4z.jpg',
      ),
      AnimeTag(
        name: '漫画改',
        count: 5899,
        imageUrl: 'https://lain.bgm.tv/pic/cover/l/fb/84/395378_HoH00.jpg',
      ),
    ],
  );
}

List<AnimeEpisode> _fallbackEpisodes(AnimeSubject subject) {
  final count = subject.totalEpisodes <= 0
      ? 12
      : min(subject.totalEpisodes, 28);
  return [
    for (var i = 1; i <= count; i++)
      AnimeEpisode(
        id: subject.id * 1000 + i,
        subjectId: subject.id,
        number: i,
        title: '',
        airdate: subject.date,
        duration: '24:00',
        description: '${subject.title} 第$i集资料，播放线路后续从你自己的源接口接入。',
        thumbnailUrl: subject.coverUrl,
      ),
  ];
}

final _fallbackCharacters = [
  const AnimeCharacter(
    id: 1,
    name: '主角',
    relation: '主角',
    cv: '未知',
    summary: '角色资料待 Bangumi 返回。',
  ),
  const AnimeCharacter(
    id: 2,
    name: '伙伴',
    relation: '配角',
    cv: '未知',
    summary: '角色资料待 Bangumi 返回。',
  ),
];

final _fallbackStaff = [
  const AnimeStaff(
    id: 1,
    name: '制作团队',
    role: '动画制作',
    career: '制作',
    imageUrl: null,
  ),
  const AnimeStaff(
    id: 2,
    name: '监督',
    role: '监督',
    career: 'director',
    imageUrl: null,
  ),
];

List<AnimeRecommendation> _fallbackRecommendations(AnimeSubject subject) {
  return [
    for (final item in _fallbackSubjects.where((item) => item.id != subject.id))
      AnimeRecommendation(subject: item, relation: '推荐'),
  ];
}

List<AnimeSubject> _rotateSubjectsForToday(List<AnimeSubject> subjects) {
  if (subjects.length <= 1) return subjects;
  final now = DateTime.now();
  final seed = now.year * 1000 + now.dayOfYear;
  final decorated = [
    for (final subject in subjects)
      MapEntry(_stableDailyScore(subject, seed), subject),
  ]..sort((a, b) => a.key.compareTo(b.key));
  return decorated.map((entry) => entry.value).toList(growable: false);
}

int _stableDailyScore(AnimeSubject subject, int seed) {
  var value = subject.id ^ seed ^ _stableTextHash(subject.title);
  value = 0x1fffffff & (value + 0x7ed55d16 + (value << 12));
  value = 0x1fffffff & (value ^ 0xc761c23c ^ (value >> 19));
  value = 0x1fffffff & (value + 0x165667b1 + (value << 5));
  value = 0x1fffffff & (value + 0xd3a2646c ^ (value << 9));
  value = 0x1fffffff & (value + 0xfd7046c5 + (value << 3));
  value = 0x1fffffff & (value ^ 0xb55a4f09 ^ (value >> 16));
  return value;
}

int _stableTextHash(String text) {
  var hash = 0x811c9dc5;
  for (final unit in text.codeUnits) {
    hash ^= unit;
    hash = 0x1fffffff & (hash * 0x01000193);
  }
  return hash;
}

extension _FirstOrNull<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
