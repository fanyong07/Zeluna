import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../domain/anime_models.dart';
import 'chinese_text.dart';

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

class BangumiTokenValidation {
  const BangumiTokenValidation._({
    required this.isValid,
    required this.message,
    this.userId,
    this.username,
    this.displayName,
  });

  const BangumiTokenValidation.valid({
    required String message,
    String? userId,
    String? username,
    String? displayName,
  }) : this._(
         isValid: true,
         message: message,
         userId: userId,
         username: username,
         displayName: displayName,
       );

  const BangumiTokenValidation.invalid(String message)
    : this._(isValid: false, message: message);

  final bool isValid;
  final String message;
  final String? userId;
  final String? username;
  final String? displayName;
}

class BangumiRateLimitException extends http.ClientException {
  BangumiRateLimitException({required this.retryAt, required Uri uri})
    : super('Bangumi requests are cooling down until $retryAt', uri);

  final DateTime retryAt;
}

class BangumiAccessCredential {
  const BangumiAccessCredential({required this.token, this.accountId});

  final String token;
  final String? accountId;

  @override
  String toString() => 'BangumiAccessCredential(accountId: $accountId)';
}

class BangumiMetadataRepository {
  BangumiMetadataRepository({
    http.Client? client,
    Future<BangumiAccessCredential?> Function()? accessCredentialProvider,
    Future<void> Function(BangumiAccessCredential credential)?
    onAccessTokenRejected,
    DateTime Function()? clock,
  }) : _client = client ?? http.Client(),
       _accessCredentialProvider = accessCredentialProvider,
       _onAccessTokenRejected = onAccessTokenRejected,
       _clock = clock ?? DateTime.now;

  final http.Client _client;
  final Future<BangumiAccessCredential?> Function()? _accessCredentialProvider;
  final Future<void> Function(BangumiAccessCredential credential)?
  _onAccessTokenRejected;
  final DateTime Function() _clock;
  bool _suppressAccessToken = false;
  int _credentialGeneration = 0;
  DateTime? _rateLimitedUntil;

  static const _baseUrl = 'https://api.bgm.tv';
  static const _recentWindow = Duration(days: 180);
  static const _distinctHomePrefix = 18;
  static const _subjectPageSize = 20;
  static const _episodePageSize = 100;
  static const _defaultRateLimitCooldown = Duration(seconds: 30);
  static const _maxRateLimitCooldown = Duration(minutes: 5);
  static const _headers = {
    'User-Agent':
        'fanyong/Zeluna/1.0 (Flutter; Android/Windows/Web) '
        '(https://github.com/fanyong07/anime)',
    'Accept': 'application/json',
  };

  void close() => _client.close();

  void resetAccessTokenState() {
    _credentialGeneration++;
    _suppressAccessToken = false;
  }

  Future<BangumiTokenValidation> validateAccessToken(String token) async {
    final normalized = token.trim();
    if (normalized.length < 16 ||
        normalized.length > 512 ||
        RegExp(r'\s').hasMatch(normalized)) {
      return const BangumiTokenValidation.invalid('令牌格式不正确');
    }
    try {
      final response = await _sendGet(
        Uri.parse('$_baseUrl/v0/me'),
        headers: {..._headers, 'Authorization': 'Bearer $normalized'},
      ).timeout(const Duration(seconds: 12));
      if (response.statusCode == 401) {
        return const BangumiTokenValidation.invalid('令牌无效或已过期');
      }
      if (response.statusCode == 403) {
        return const BangumiTokenValidation.invalid(
          'Bangumi 拒绝了本次验证，请稍后重试或检查令牌权限',
        );
      }
      if (response.statusCode == 429) {
        return const BangumiTokenValidation.invalid('请求过于频繁，请稍后再试');
      }
      if (response.statusCode != 200) {
        return BangumiTokenValidation.invalid(
          'Bangumi 暂时无法验证令牌（HTTP ${response.statusCode}）',
        );
      }
      final json = _decodeResponse(response);
      final userId = _blankToNull(json['id']?.toString());
      final username = _blankToNull(json['username']?.toString());
      final displayName =
          _blankToNull(json['nickname']?.toString()) ?? username;
      if (userId == null && username == null) {
        return const BangumiTokenValidation.invalid('Bangumi 返回了无法识别的账号信息');
      }
      final label = displayName ?? username ?? 'Bangumi 用户';
      return BangumiTokenValidation.valid(
        message: '验证成功：$label',
        userId: userId,
        username: username,
        displayName: displayName,
      );
    } on BangumiRateLimitException {
      return const BangumiTokenValidation.invalid('请求过于频繁，请稍后再试');
    } on TimeoutException {
      return const BangumiTokenValidation.invalid('连接 Bangumi 超时，请检查网络后重试');
    } catch (_) {
      return const BangumiTokenValidation.invalid('无法连接 Bangumi，请检查网络后重试');
    }
  }

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
    } on BangumiRateLimitException {
      rethrow;
    } catch (_) {
      return _fallbackFeed;
    }
  }

  Future<List<AnimeSubject>> subjectsByCategory(String categoryName) async {
    final name = categoryName.trim();
    if (name.isEmpty) return const [];
    final queryNames = _bangumiQueryNames(name);
    final results = await Future.wait([
      for (final queryName in queryNames)
        searchSubjects(
          keyword: '',
          sort: 'heat',
          filters: {
            'type': [2],
            'tag': [queryName],
          },
          limit: 48,
        ),
      for (final queryName in queryNames)
        searchSubjects(
          keyword: '',
          sort: 'heat',
          filters: {
            'type': [2],
            'meta_tags': [queryName],
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
    final queryNames = _bangumiQueryNames(name);
    final results = await Future.wait([
      for (final queryName in queryNames)
        searchSubjects(
          keyword: '',
          sort: 'heat',
          filters: {
            'type': [2],
            'tag': [queryName],
          },
          limit: 60,
        ),
      searchSubjects(keyword: name, sort: 'match', limit: 36),
    ]).timeout(const Duration(seconds: 20), onTimeout: () => const []);
    return _uniqueSubjects(results.expand((items) => items));
  }

  Future<Map<int, List<AnimeSubject>>> weeklySchedule() async {
    try {
      final response = await _sendGet(
        Uri.parse('$_baseUrl/calendar'),
        headers: _headers,
      ).timeout(const Duration(seconds: 16));
      if (response.statusCode != 200) return const {};
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! List) return const {};

      final schedule = {
        for (var day = 0; day < 7; day++) day: <AnimeSubject>[],
      };
      for (final rawGroup in decoded.whereType<Map>()) {
        final group = rawGroup.cast<String, dynamic>();
        final weekday = _intValue(_map(group['weekday'])['id']);
        final items = group['items'];
        if (weekday == null || weekday < 1 || items is! List) continue;
        final day = weekday % 7;
        schedule[day]!.addAll(
          items
              .whereType<Map>()
              .map(
                (item) =>
                    _subjectFromCalendarJson(item.cast<String, dynamic>()),
              )
              .where((item) => item.id > 0 && item.title.trim().isNotEmpty),
        );
      }
      if (schedule.values.every((items) => items.isEmpty)) return const {};
      return {
        for (final entry in schedule.entries)
          entry.key: _uniqueSubjects(entry.value),
      };
    } on BangumiRateLimitException {
      rethrow;
    } catch (_) {
      return const {};
    }
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
      ).onError(_emptySubjectsOnRecoverableError),
      _searchSubjectPages(
        keyword: '',
        sort: 'rank',
        filters: const {
          'type': [2],
        },
        pageSize: 36,
        pages: 4,
      ).onError(_emptySubjectsOnRecoverableError),
      _searchSubjectPages(
        keyword: '',
        sort: 'score',
        filters: const {
          'type': [2],
        },
        pageSize: 36,
        pages: 4,
      ).onError(_emptySubjectsOnRecoverableError),
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
    final response = await _sendPost(
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
        ).onError(_emptySubjectsOnRecoverableError),
    ]);
    return _uniqueSubjects(batches.expand((items) => items));
  }

  Future<AnimeDetailBundle> detail(
    int subjectId, {
    AnimeSubject? fallbackSubject,
  }) async {
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
    } on BangumiRateLimitException {
      rethrow;
    } catch (_) {
      final subject =
          fallbackSubject ??
          _fallbackSubjects.where((item) => item.id == subjectId).firstOrNull ??
          _unavailableSubject(subjectId);
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
    final response = await _getWithOptionalAuth(Uri.parse('$_baseUrl$path'));
    if (response.statusCode != 200) {
      throw http.ClientException(
        'Bangumi request failed with HTTP ${response.statusCode}',
        Uri.parse('$_baseUrl$path'),
      );
    }
    return _decodeResponse(response);
  }

  Future<List<dynamic>> _getList(String path) async {
    final response = await _getWithOptionalAuth(Uri.parse('$_baseUrl$path'));
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
        }).onError(_failedPageOnRecoverableError),
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
    final response = await _getWithOptionalAuth(
      Uri.parse('$_baseUrl$path').replace(queryParameters: query),
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

  List<AnimeSubject> _emptySubjectsOnRecoverableError(
    Object error,
    StackTrace stackTrace,
  ) {
    if (error is BangumiRateLimitException) {
      Error.throwWithStackTrace(error, stackTrace);
    }
    return const <AnimeSubject>[];
  }

  _PagedResponse _failedPageOnRecoverableError(
    Object error,
    StackTrace stackTrace,
  ) {
    if (error is BangumiRateLimitException) {
      Error.throwWithStackTrace(error, stackTrace);
    }
    return const _PagedResponse.failed();
  }

  Future<http.Response> _sendGet(
    Uri uri, {
    required Map<String, String> headers,
  }) async {
    _ensureRequestAllowed(uri);
    final response = await _client.get(uri, headers: headers);
    return _acceptResponse(response, uri);
  }

  Future<http.Response> _sendPost(
    Uri uri, {
    required Map<String, String> headers,
    Object? body,
  }) async {
    _ensureRequestAllowed(uri);
    final response = await _client.post(uri, headers: headers, body: body);
    return _acceptResponse(response, uri);
  }

  http.Response _acceptResponse(http.Response response, Uri uri) {
    if (response.statusCode != 429) return response;
    final seconds = int.tryParse(response.headers['retry-after']?.trim() ?? '');
    final cooldownSeconds = seconds == null
        ? _defaultRateLimitCooldown.inSeconds
        : seconds.clamp(1, _maxRateLimitCooldown.inSeconds).toInt();
    final candidate = _clock().toUtc().add(Duration(seconds: cooldownSeconds));
    final current = _rateLimitedUntil;
    if (current == null || candidate.isAfter(current)) {
      _rateLimitedUntil = candidate;
    }
    throw BangumiRateLimitException(retryAt: _rateLimitedUntil!, uri: uri);
  }

  void _ensureRequestAllowed(Uri uri) {
    final until = _rateLimitedUntil;
    if (until == null) return;
    if (!until.isAfter(_clock().toUtc())) {
      _rateLimitedUntil = null;
      return;
    }
    throw BangumiRateLimitException(retryAt: until, uri: uri);
  }

  Future<http.Response> _getWithOptionalAuth(Uri uri) async {
    final credentialGeneration = _credentialGeneration;
    final credential = await _readAccessCredential();
    if (credential == null || credentialGeneration != _credentialGeneration) {
      return _sendGet(uri, headers: _headers);
    }

    final response = await _sendGet(
      uri,
      headers: {..._headers, 'Authorization': 'Bearer ${credential.token}'},
    );
    if (credentialGeneration != _credentialGeneration) {
      return _sendGet(uri, headers: _headers);
    }
    if (response.statusCode == 401) {
      _suppressAccessToken = true;
      _credentialGeneration++;
      try {
        await _onAccessTokenRejected?.call(credential);
      } catch (_) {
        // Credential status persistence must never block anonymous metadata.
      }
      return _sendGet(uri, headers: _headers);
    }
    if (response.statusCode == 403) {
      return _sendGet(uri, headers: _headers);
    }
    return response;
  }

  Future<BangumiAccessCredential?> _readAccessCredential() async {
    if (_suppressAccessToken) return null;
    try {
      final credential = await _accessCredentialProvider?.call();
      final token = credential?.token.trim() ?? '';
      if (token.isEmpty || RegExp(r'[\r\n]').hasMatch(token)) return null;
      return BangumiAccessCredential(
        token: token,
        accountId: credential?.accountId,
      );
    } catch (_) {
      return null;
    }
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
    final title = _bestSubjectTitle(json);
    final originalTitle = json['name']?.toString() ?? title;
    final date = _blankToNull(json['date']?.toString());
    final platform = _blankToNull(json['platform']?.toString()) ?? 'TV';
    final total =
        _intValue(json['total_episodes']) ?? _intValue(json['eps']) ?? 0;
    return AnimeSubject(
      id: _intValue(json['id']) ?? 0,
      title: title,
      originalTitle: originalTitle,
      summary: _cleanChineseSummary(json['summary']?.toString()),
      coverUrl:
          _blankToNull(images['common']?.toString()) ??
          _blankToNull(images['large']?.toString()) ??
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

  AnimeSubject _subjectFromCalendarJson(Map<String, dynamic> json) {
    final rating = _map(json['rating']);
    return _subjectFromJson({
      ...json,
      'date': json['air_date'],
      'platform': _blankToNull(json['platform']?.toString()) ?? 'TV',
      'rating': {...rating, if (json['rank'] != null) 'rank': json['rank']},
    });
  }

  AnimeEpisode _episodeFromJson(
    Map<String, dynamic> json,
    AnimeSubject subject,
  ) {
    final ep = (json['ep'] as num?)?.round();
    final sort = (json['sort'] as num?)?.round();
    final number = ep ?? sort ?? 0;
    final title = _bestChineseTitle(json['name_cn']);
    return AnimeEpisode(
      id: _intValue(json['id']) ?? number,
      subjectId: subject.id,
      number: number,
      title: title.startsWith('第') ? '' : title,
      airdate: _blankToNull(json['airdate']?.toString()),
      duration:
          _blankToNull(json['duration']?.toString()) ??
          _formatSeconds(_intValue(json['duration_seconds']) ?? 0),
      description: _cleanChineseDescription(json['desc']?.toString()),
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
      summary: _cleanChineseSummary(json['summary']?.toString()),
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
      title: _bestSubjectTitle(json),
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
      relation:
          verifiedChineseText(json['relation']?.toString(), title: true) ??
          '相关',
    );
  }

  List<AnimeTag> _tagsFromJson(Object? value) {
    if (value is! List) return const [];
    final localized = <String, AnimeTag>{};
    for (final item in value.whereType<Map>()) {
      final name = _localizedTagName(item['name']?.toString() ?? '');
      if (!isLikelyChineseTitle(name)) continue;
      final tag = AnimeTag(name: name, count: _intValue(item['count']) ?? 0);
      final current = localized[name];
      if (current == null || tag.count > current.count) localized[name] = tag;
      if (localized.length >= 28) break;
    }
    return localized.values.toList(growable: false);
  }

  List<AnimeCategory> _categoriesFrom(
    List<String> metaTags,
    List<AnimeTag> tags,
    String? platform,
  ) {
    final names = <String>{};
    final all = [...metaTags, ...tags.map((item) => item.name), ?platform];
    for (final rawItem in all) {
      final item = _localizedTagName(rawItem);
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

  String _bestSubjectTitle(Map<String, dynamic> json) {
    final candidates = <({int score, String value})>[];

    void addCandidate(Object? rawValue, int score) {
      final value = verifiedChineseText(rawValue?.toString(), title: true);
      if (value == null) return;
      candidates.add((score: score, value: value));
    }

    final chineseName = json['name_cn']?.toString().trim() ?? '';
    addCandidate(chineseName, 1000);
    final infobox = json['infobox'];
    if (infobox is List) {
      for (final rawItem in infobox.whereType<Map>()) {
        final item = rawItem.cast<Object?, Object?>();
        final key = item['key']?.toString().trim() ?? '';
        if (!_isChineseTitleInfoboxKey(key)) continue;
        final baseScore = _chineseTitleKeyScore(key);
        final value = item['value'];
        if (value is List) {
          for (final rawAlias in value) {
            if (rawAlias is Map) {
              final aliasKey =
                  rawAlias['k']?.toString().trim() ??
                  rawAlias['key']?.toString().trim() ??
                  '';
              final aliasValue =
                  rawAlias['v'] ?? rawAlias['value'] ?? rawAlias['name'];
              addCandidate(
                aliasValue,
                baseScore + _chineseTitleKeyScore(aliasKey),
              );
            } else {
              addCandidate(rawAlias, baseScore);
            }
          }
        } else if (value is Map) {
          final aliasKey =
              value['k']?.toString().trim() ??
              value['key']?.toString().trim() ??
              '';
          addCandidate(
            value['v'] ?? value['value'] ?? value['name'],
            baseScore + _chineseTitleKeyScore(aliasKey),
          );
        } else {
          addCandidate(value, baseScore);
        }
      }
    }
    if (candidates.isNotEmpty) {
      candidates.sort((first, second) {
        final scoreOrder = second.score.compareTo(first.score);
        if (scoreOrder != 0) return scoreOrder;
        return first.value.length.compareTo(second.value.length);
      });
      return candidates.first.value;
    }
    if (chineseName.isNotEmpty) return chineseName;
    return json['name']?.toString().trim() ?? '';
  }

  String _bestChineseTitle(Object? cn) {
    return verifiedChineseText(cn?.toString(), title: true) ?? '';
  }

  bool _isChineseTitleInfoboxKey(String value) {
    final key = value.toLowerCase();
    return key.contains('中文名') ||
        key.contains('中文译') ||
        key.contains('简体') ||
        key.contains('大陆') ||
        key == '别名';
  }

  int _chineseTitleKeyScore(String value) {
    final key = value.toLowerCase();
    if (key.contains('大陆版权译') || key.contains('大陆官方')) return 1200;
    if (key.contains('简体中文') || key.contains('简中')) return 1100;
    if (key.contains('中文名') || key.contains('中文译')) return 900;
    if (key.contains('大陆') || key.contains('中文')) return 800;
    if (key == '别名') return 40;
    return 0;
  }

  String _localizedTagName(String value) {
    final text = value.trim();
    if (text.isEmpty) return '';
    return _bangumiTagTranslations[text.toLowerCase()] ?? text;
  }

  List<String> _bangumiQueryNames(String value) {
    return <String>{
      value,
      ?_bangumiLocalizedQueryAliases[value],
    }.toList(growable: false);
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

  String _cleanChineseSummary(String? value) {
    final text = value?.trim();
    if (text == null || text.isEmpty) return '暂无中文简介。';
    final extracted = _extractChineseSummary(text);
    return extracted ?? '暂无中文简介。';
  }

  String _cleanChineseDescription(String? value) {
    final text = value?.trim();
    if (text == null || text.isEmpty) return '';
    return _extractChineseSummary(text) ?? '';
  }

  String? _extractChineseSummary(String value) {
    final normalized = value.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final chineseMarker = RegExp(
      r'[\[【（(]\s*(?:中文简介|中文介绍|中文剧情简介)\s*[\]】）)]',
      caseSensitive: false,
    );
    final originalMarker = RegExp(
      r'[\[【（(]\s*(?:简介原文|原文简介|原文)\s*[\]】）)]',
      caseSensitive: false,
    );

    final chineseMatch = chineseMarker.firstMatch(normalized);
    if (chineseMatch != null) {
      var localized = normalized.substring(chineseMatch.end);
      final followingOriginal = originalMarker.firstMatch(localized);
      if (followingOriginal != null) {
        localized = localized.substring(0, followingOriginal.start);
      }
      final selected = _bestChineseSummaryBlock(localized);
      if (selected != null) return selected;
    }

    final originalMatch = originalMarker.firstMatch(normalized);
    if (originalMatch != null) {
      final selected = _bestChineseSummaryBlock(
        normalized.substring(0, originalMatch.start),
      );
      if (selected != null) return selected;
    }
    return _bestChineseSummaryBlock(normalized);
  }

  String? _bestChineseSummaryBlock(String value) {
    final candidates = <String>[];

    void addGroup(List<String> blocks) {
      if (blocks.isEmpty) return;
      final text = blocks.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
      if (isLikelyChineseText(text)) candidates.add(text);
    }

    void collect(Iterable<String> rawBlocks) {
      var group = <String>[];
      for (final rawBlock in rawBlocks) {
        final block = rawBlock.replaceAll(RegExp(r'\s+'), ' ').trim();
        if (block.isEmpty) continue;
        if (isLikelyChineseText(block)) {
          group.add(block);
        } else {
          addGroup(group);
          group = <String>[];
        }
      }
      addGroup(group);
    }

    final paragraphs = value.split(RegExp(r'\n\s*\n+'));
    if (paragraphs.length > 1) collect(paragraphs);
    final lines = value.split('\n');
    if (lines.length > 1) collect(lines);
    final sentences = <String>[];
    var sentenceStart = 0;
    for (final match in RegExp(r'[。！？!?]+').allMatches(value)) {
      sentences.add(value.substring(sentenceStart, match.end));
      sentenceStart = match.end;
    }
    if (sentenceStart < value.length) {
      sentences.add(value.substring(sentenceStart));
    }
    if (sentences.length > 1) collect(sentences);
    final compact = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (candidates.isEmpty && isLikelyChineseText(compact)) {
      candidates.add(compact);
    }
    if (candidates.isEmpty) return null;
    candidates.sort((first, second) {
      final firstHan = RegExp(r'[\u3400-\u9fff]').allMatches(first).length;
      final secondHan = RegExp(r'[\u3400-\u9fff]').allMatches(second).length;
      final hanOrder = secondHan.compareTo(firstHan);
      return hanOrder != 0 ? hanOrder : second.length.compareTo(first.length);
    });
    return candidates.first;
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

const _bangumiTagTranslations = <String, String>{
  'anime': '动画',
  'animation': '动画',
  'tv': '电视动画',
  'web': '网络动画',
  'movie': '动画电影',
  'ova': '原创动画录像',
  'ona': '网络动画',
  'action': '动作',
  'adventure': '冒险',
  'comedy': '喜剧',
  'drama': '剧情',
  'fantasy': '奇幻',
  'romance': '恋爱',
  'mystery': '悬疑',
  'horror': '恐怖',
  'music': '音乐',
  'school': '校园',
  'sci-fi': '科幻',
  'science fiction': '科幻',
  'slice of life': '日常',
  'supernatural': '超自然',
  'manga adaptation': '漫画改',
  'novel adaptation': '小说改',
  'original': '原创',
};

const _bangumiLocalizedQueryAliases = <String, String>{
  '动画': 'Animation',
  '电视动画': 'TV',
  '网络动画': 'ONA',
  '动画电影': 'Movie',
  '原创动画录像': 'OVA',
  '动作': 'Action',
  '动作冒险': 'Action',
  '冒险': 'Adventure',
  '喜剧': 'Comedy',
  '剧情': 'Drama',
  '奇幻': 'Fantasy',
  '恋爱': 'Romance',
  '悬疑': 'Mystery',
  '恐怖': 'Horror',
  '音乐': 'Music',
  '校园': 'School',
  '科幻': 'Sci-Fi',
  '日常': 'Slice of Life',
  '超自然': 'Supernatural',
  '漫画改': 'Manga adaptation',
  '小说改': 'Novel adaptation',
  '原创': 'Original',
};

const _categoryNames = {
  '动画',
  '电视动画',
  '网络动画',
  '动画电影',
  '原创动画录像',
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
  '恐怖',
  '战斗',
  '音乐',
  '校园',
  '恋爱',
  '日常',
  '超自然',
};

const _fallbackBocchiId = 328609;
const _fallbackBocchiCoverUrl =
    'https://api.bgm.tv/v0/subjects/328609/image?type=common';
const _fallbackFrierenId = 400602;
const _fallbackFrierenCoverUrl =
    'https://api.bgm.tv/v0/subjects/400602/image?type=common';
const _fallbackDungeonMeshiId = 395378;
const _fallbackDungeonMeshiCoverUrl =
    'https://api.bgm.tv/v0/subjects/395378/image?type=common';

AnimeSubject _unavailableSubject(int subjectId) => AnimeSubject(
  id: subjectId,
  title: 'Bangumi 条目 $subjectId',
  originalTitle: 'Bangumi subject $subjectId',
  summary: 'Bangumi 资料暂时不可用，请稍后重试。',
  coverUrl: 'https://api.bgm.tv/v0/subjects/$subjectId/image?type=common',
  bannerUrl: null,
  date: null,
  platform: 'TV',
  language: '未知',
  region: '未知',
  status: '资料暂不可用',
  categories: const [],
  tags: const [],
  totalEpisodes: 0,
);

final _fallbackSubjects = [
  const AnimeSubject(
    id: _fallbackBocchiId,
    title: '孤独摇滚！',
    originalTitle: 'ぼっち・ざ・ろっく！',
    summary: '极度怕生的少女后藤一里因为吉他结识乐队伙伴，在舞台和日常里一点点靠近自己真正想成为的样子。',
    coverUrl: _fallbackBocchiCoverUrl,
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
    id: _fallbackFrierenId,
    title: '葬送的芙莉莲',
    originalTitle: '葬送のフリーレン',
    summary: '勇者一行讨伐魔王之后，长寿精灵芙莉莲重新踏上旅途，学习理解人类短暂却明亮的一生。',
    coverUrl: _fallbackFrierenCoverUrl,
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
    id: _fallbackDungeonMeshiId,
    title: '迷宫饭',
    originalTitle: 'ダンジョン飯',
    summary: '一支冒险队深入地下城救人，同时认真研究如何把沿途魔物做成一顿像样的饭。',
    coverUrl: _fallbackDungeonMeshiCoverUrl,
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
        imageUrl: _fallbackFrierenCoverUrl,
      ),
      AnimeCategory(
        name: '喜剧',
        count: 11599,
        imageUrl: _fallbackDungeonMeshiCoverUrl,
      ),
      AnimeCategory(name: '奇幻', count: 8676, imageUrl: _fallbackBocchiCoverUrl),
    ],
    tags: const [
      AnimeTag(name: 'TV', count: 12883, imageUrl: _fallbackBocchiCoverUrl),
      AnimeTag(name: '日本', count: 10822, imageUrl: _fallbackFrierenCoverUrl),
      AnimeTag(
        name: '漫画改',
        count: 5899,
        imageUrl: _fallbackDungeonMeshiCoverUrl,
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
