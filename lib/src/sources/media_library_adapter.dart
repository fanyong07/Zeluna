import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../core/identity/stable_identity.dart';
import '../core/network/network_http_client.dart';
import '../core/network/network_security.dart';
import '../domain/anime_models.dart';
import '../domain/subject_content_type.dart';

final mediaLibraryAdapterProvider = Provider<MediaLibraryAdapter?>(
  (ref) => kIsWeb ? null : MediaLibraryAdapter(),
);

enum MediaLibraryKind {
  emby('Emby'),
  jellyfin('Jellyfin'),
  webdav('WebDAV / Alist');

  const MediaLibraryKind(this.label);
  final String label;
}

final class MediaLibraryConfig {
  MediaLibraryConfig._({
    required this.id,
    required String name,
    required this.kind,
    required String endpoint,
    required String username,
    required String secret,
    String userId = '',
  }) : name = name.trim(),
       endpoint = _libraryEndpoint(endpoint),
       _username = username.trim(),
       _secret = kind == MediaLibraryKind.webdav ? secret : secret.trim(),
       userId = userId.trim() {
    if (this.name.isEmpty) throw const FormatException('请输入媒体库名称');
    if (kind == MediaLibraryKind.webdav) {
      final hasUser = _username.isNotEmpty;
      final hasSecret = _secret.isNotEmpty;
      if (_username.contains(':') || (hasUser != hasSecret)) {
        throw const FormatException('请输入有效的 WebDAV 用户名和密码，或留空以匿名访问');
      }
    } else if (!RegExp(r'^[A-Za-z0-9._~-]+$').hasMatch(_secret)) {
      throw const FormatException('请输入有效的 API 密钥或访问令牌');
    }
  }

  final String id;
  final String name;
  final MediaLibraryKind kind;
  final Uri endpoint;
  final String _username;
  final String _secret;
  final String userId;

  factory MediaLibraryConfig._fromRecord(Map<String, dynamic> record) =>
      MediaLibraryConfig._(
        id: record['id'] as String,
        name: record['name'] as String,
        kind: MediaLibraryKind.values.byName(record['kind'] as String),
        endpoint: record['endpoint'] as String,
        username: (record['username'] as String?) ?? '',
        secret: (record['secret'] as String?) ?? '',
        userId: (record['userId'] as String?) ?? '',
      );

  Map<String, String> _toRecord() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'endpoint': endpoint.toString(),
    'username': _username,
    'secret': _secret,
    if (userId.isNotEmpty) 'userId': userId,
  };

  Map<String, String> _requestHeaders() => switch (kind) {
    MediaLibraryKind.emby => {'X-Emby-Token': _secret},
    MediaLibraryKind.jellyfin => {
      'Authorization':
          'MediaBrowser Token="$_secret", Client="Zeluna", '
          'Device="Zeluna", DeviceId="$id", Version="1"',
    },
    MediaLibraryKind.webdav =>
      _username.isEmpty && _secret.isEmpty
          ? const {}
          : {
              'Authorization':
                  'Basic ${base64Encode(utf8.encode('$_username:$_secret'))}',
            },
  };
}

/// A trust marker that public inventory/rule parsers cannot construct. Never
/// carry credentials on a generic [PlaybackLine] (e.g. into offline storage).
final class MediaLibraryPlaybackLine extends PlaybackLine {
  MediaLibraryPlaybackLine._({
    required MediaLibraryConfig library,
    required AnimeSubject subject,
    required AnimeEpisode episode,
    required Uri target,
    required super.format,
  }) : _libraryId = library.id,
       super(
         id: stablePlaybackLineKey(
           providerId: _provider(library),
           episodeKey: episode.identityKey(subjectKey: subject.identityKey),
           uri: target.toString(),
         ),
         episodeId: episode.id,
         providerId: _provider(library),
         providerName: library.name,
         title: subject.title,
         quality: '原画',

         url: target.toString(),
         queryLocation: 'client',
         available: true,
       );

  final String _libraryId;

  static String _provider(MediaLibraryConfig library) =>
      'private-library:${library.kind.name}:${library.id}';
}

/// Device-local configuration and on-demand discovery. Only the platform
/// secure store persists data; the DAV file index lives in memory.
final class MediaLibraryAdapter {
  MediaLibraryAdapter({
    FlutterSecureStorage? storage,
    http.Client Function()? createClient,
    DateTime Function()? now,
  }) : _storage = storage ?? _defaultStorage,
       _createClient = createClient,
       _now = now ?? DateTime.now;

  static const _defaultStorage = FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.unlocked_this_device,
    ),
    mOptions: MacOsOptions(
      accessibility: KeychainAccessibility.unlocked_this_device,
    ),
  );
  static const _storageKey = 'zeluna.private-media-libraries.v1';
  static const _storageTimeout = Duration(seconds: 2);
  static const _indexTtl = Duration(minutes: 10);
  static final _random = Random.secure();

  final FlutterSecureStorage _storage;
  final http.Client Function()? _createClient;
  final DateTime Function() _now;
  List<MediaLibraryConfig>? _configured;
  Future<List<MediaLibraryConfig>?>? _loading;
  bool _writing = false;
  final _davIndexes =
      <String, ({DateTime expires, Future<List<Uri>> entries})>{};

  /// Null means the secure store could not be read, not an empty library list.
  Future<List<MediaLibraryConfig>?> libraries() {
    if (_configured case final configured?) return Future.value(configured);
    return _loading ??= _read().whenComplete(() => _loading = null);
  }

  Future<List<MediaLibraryConfig>?> _read() async {
    try {
      final raw = await _storage
          .read(key: _storageKey)
          .timeout(_storageTimeout);
      return _configured = List.unmodifiable([
        if (raw != null)
          for (final record in jsonDecode(raw) as List)
            MediaLibraryConfig._fromRecord(record as Map<String, dynamic>),
      ]);
    } catch (_) {
      // No fallback to Hive, and never overwrite unreadable credentials.
      return null;
    }
  }

  Future<bool> saveLibrary({
    String? replaceId,
    required String name,
    required MediaLibraryKind kind,
    required String endpoint,
    String username = '',
    required String secret,
    String userId = '',
  }) {
    final entry = MediaLibraryConfig._(
      // An edit invalidates previous lines, including same-origin path edits.
      id: List.generate(
        16,
        (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join(),
      name: name,
      kind: kind,
      endpoint: endpoint,
      username: username,
      secret: secret,
      userId: userId,
    );
    return _update(replaceId, entry);
  }

  /// Authenticates an Emby / Jellyfin user with username + password and returns
  /// the server-issued access token and user ID without storing the password.
  Future<({String token, String userId})> authenticateApiUser({
    required MediaLibraryKind kind,
    required String endpoint,
    required String username,
    required String password,
  }) async {
    if (kind == MediaLibraryKind.webdav) {
      throw const FormatException('WebDAV 不支持账号密码令牌登录');
    }
    final cleanUser = username.trim();
    if (cleanUser.isEmpty) throw const FormatException('请输入用户名');
    final uri = _libraryEndpoint(endpoint);
    final deviceId = List.generate(
      8,
      (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final authHeader =
        'MediaBrowser Client="Zeluna", Device="Zeluna", '
        'DeviceId="$deviceId", Version="1"';
    final headers = <String, String>{
      'Content-Type': 'application/json; charset=utf-8',
      if (kind == MediaLibraryKind.emby)
        'X-Emby-Authorization': authHeader
      else
        'Authorization': authHeader,
    };
    return _withOriginClient(uri, (client) async {
      final response = await client.post(
        uri.resolve('Users/AuthenticateByName'),
        headers: headers,
        body: jsonEncode({'Username': cleanUser, 'Pw': password}),
      );
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw const FormatException('用户名或密码不正确');
      }
      if (response.statusCode == 404) {
        throw const FormatException('未找到登录接口，请检查服务器地址（Emby 可尝试添加 /emby）');
      }
      if (response.statusCode != 200) {
        throw FormatException('登录失败：HTTP ${response.statusCode}');
      }
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      if (data is! Map<String, dynamic>) {
        throw const FormatException('服务器返回格式异常');
      }
      final token = (data['AccessToken'] as String?)?.trim() ?? '';
      final user = data['User'];
      final userId = user is Map ? (user['Id']?.toString().trim() ?? '') : '';
      if (token.isEmpty) {
        throw const FormatException('服务器未返回访问令牌');
      }
      return (token: token, userId: userId);
    });
  }

  /// Tests connectivity and credentials before saving a library configuration.
  Future<String> testConnection({
    required MediaLibraryKind kind,
    required String endpoint,
    String username = '',
    required String secret,
    bool usePasswordAuth = false,
    String userId = '',
  }) async {
    final uri = _libraryEndpoint(endpoint);
    try {
      if (kind == MediaLibraryKind.webdav) {
        final preview = MediaLibraryConfig._(
          id: 'probe',
          name: 'probe',
          kind: kind,
          endpoint: endpoint,
          username: username,
          secret: secret,
        );
        return await _withClient(preview, (client) async {
          final response = await http.Response.fromStream(
            await client.send(
              http.Request('PROPFIND', preview.endpoint)
                ..headers.addAll({
                  ...preview._requestHeaders(),
                  'Depth': '0',
                  'Content-Type': 'application/xml; charset=utf-8',
                })
                ..body = _propfindBody,
            ),
          );
          if (response.statusCode == 207 || response.statusCode == 200) {
            return 'WebDAV 连接成功';
          }
          if (response.statusCode == 401 || response.statusCode == 403) {
            throw const FormatException('WebDAV 认证失败，请检查用户名和密码');
          }
          if (response.statusCode == 404) {
            throw const FormatException('WebDAV 目录不存在，请检查路径');
          }
          if (response.statusCode == 405) {
            throw const FormatException('该地址不支持 WebDAV，Alist 请使用 /dav 路径');
          }
          throw FormatException('WebDAV 请求失败：HTTP ${response.statusCode}');
        });
      }
      if (usePasswordAuth) {
        await authenticateApiUser(
          kind: kind,
          endpoint: endpoint,
          username: username,
          password: secret,
        );
        return '${kind.label} 登录验证成功';
      }
      final preview = MediaLibraryConfig._(
        id: 'probe',
        name: 'probe',
        kind: kind,
        endpoint: endpoint,
        username: '',
        secret: secret,
        userId: userId,
      );
      return await _withClient(preview, (client) async {
        final path = preview.userId.isNotEmpty
            ? 'Users/${preview.userId}/Items'
            : 'Items';
        final response = await client.get(
          preview.endpoint
              .resolve(path)
              .replace(
                queryParameters: const {'Limit': '1', 'Recursive': 'false'},
              ),
          headers: preview._requestHeaders(),
        );
        if (response.statusCode == 200) return '${kind.label} 连接成功';
        if (response.statusCode == 401 || response.statusCode == 403) {
          throw const FormatException('API 密钥无效或没有访问权限');
        }
        if (response.statusCode == 404) {
          throw const FormatException('未找到媒体库接口，请检查地址（Emby 可尝试添加 /emby）');
        }
        throw FormatException('服务器返回 HTTP ${response.statusCode}');
      });
    } on FormatException {
      rethrow;
    } on TimeoutException {
      throw const FormatException('连接超时，请检查服务器地址与网络');
    } on NetworkSecurityException catch (error) {
      throw FormatException(error.message);
    } catch (error) {
      final text = error.toString();
      if (text.contains('HandshakeException') ||
          text.contains('CERTIFICATE_VERIFY_FAILED')) {
        throw FormatException(
          uri.scheme == 'https'
              ? 'HTTPS 证书校验失败；局域网设备可改用 http:// 地址'
              : 'TLS 连接失败',
        );
      }
      throw const FormatException('无法连接到服务器，请检查地址、端口和网络状态');
    }
  }

  Future<bool> removeLibrary(String id) => _update(id, null);

  Future<bool> _update(String? id, MediaLibraryConfig? entry) async {
    if (_writing) return false;
    _writing = true;
    try {
      final current = await libraries();
      if (current == null ||
          (id != null && !current.any((library) => library.id == id))) {
        return false;
      }
      final next = [
        for (final library in current)
          if (library.id != id) library else ?entry,
        if (id == null && entry != null) entry,
      ];
      await _storage
          .write(
            key: _storageKey,
            value: jsonEncode([
              for (final library in next) library._toRecord(),
            ]),
          )
          .timeout(_storageTimeout);
      _configured = List.unmodifiable(next);
      _davIndexes.remove(id);
      return true;
    } catch (_) {
      return false;
    } finally {
      _writing = false;
    }
  }

  /// Supplies credentials only at a native open and only for a live config.
  ({Uri origin, Map<String, String> headers}) playbackRequestFor(
    MediaLibraryPlaybackLine line,
  ) {
    final library = _configured
        ?.where((item) => item.id == line._libraryId)
        .firstOrNull;
    if (library == null) throw StateError('媒体库已变更，请重新查线');
    return (origin: library.endpoint, headers: library._requestHeaders());
  }

  /// Emit matches as libraries finish. A bad credential or offline server
  /// in one library cannot hide a usable line from another.
  Stream<MediaLibraryPlaybackLine> lookup(
    AnimeSubject subject,
    AnimeEpisode episode, {
    bool forceRefresh = false,
  }) async* {
    final source = subject.source.toLowerCase();
    if (source != 'bangumi' && !source.startsWith('tmdb:')) return;
    final configs = await libraries();
    if (configs == null || configs.isEmpty) return;
    final match = _LibraryMatch(subject, episode);
    yield* Stream.fromFutures([
          for (final library in configs)
            _lookupLibrary(library, subject, episode, match, forceRefresh),
        ])
        .where(
          (line) =>
              line != null &&
              _configured!.any((library) => library.id == line._libraryId),
        )
        .cast<MediaLibraryPlaybackLine>();
  }

  Future<MediaLibraryPlaybackLine?> _lookupLibrary(
    MediaLibraryConfig library,
    AnimeSubject subject,
    AnimeEpisode episode,
    _LibraryMatch match,
    bool forceRefresh,
  ) async {
    try {
      final dav = library.kind == MediaLibraryKind.webdav;
      final target = dav
          ? _findDavFile(await _davIndex(library, forceRefresh), match)
          : await _withClient(
              library,
              (client) => _findApiVideo(client, library, match),
            );
      if (target == null) return null;
      return MediaLibraryPlaybackLine._(
        library: library,
        subject: subject,
        episode: episode,
        target: target,
        format: dav
            ? target.pathSegments.last.split('.').last.toUpperCase()
            : 'Direct',
      );
    } catch (_) {
      // Never log an upstream error/body: it may contain library credentials.
      return null;
    }
  }

  Future<T> _withClient<T>(
    MediaLibraryConfig library,
    Future<T> Function(http.Client) run, {
    Duration overallTimeout = const Duration(seconds: 12),
  }) =>
      _withOriginClient(library.endpoint, run, overallTimeout: overallTimeout);

  Future<T> _withOriginClient<T>(
    Uri origin,
    Future<T> Function(http.Client) run, {
    Duration overallTimeout = const Duration(seconds: 12),
  }) async {
    final policy = NetworkRequestPolicy.privateMediaLibrary(
      origin: origin,
      maxResponseBytes: 4 * 1024 * 1024,
      requestTimeout: const Duration(seconds: 6),
      httpsOnly: false,
    );
    final wire = _createClient?.call();
    final client = wire == null
        ? createNetworkHttpClient(policy)
        : PolicyHttpClient(inner: wire, policy: policy);
    try {
      return await run(client).timeout(overallTimeout);
    } finally {
      client.close();
    }
  }

  Future<List<Uri>> _davIndex(
    MediaLibraryConfig library,
    bool forceRefresh,
  ) async {
    final cached = _davIndexes[library.id];
    if (!forceRefresh && cached != null && cached.expires.isAfter(_now())) {
      return cached.entries;
    }
    final entries = _withClient(
      library,
      (client) => _readDavIndex(client, library),
      overallTimeout: const Duration(seconds: 22),
    );
    _davIndexes[library.id] = (
      expires: _now().add(_indexTtl),
      entries: entries,
    );
    try {
      return await entries;
    } catch (_) {
      if (identical(_davIndexes[library.id]?.entries, entries)) {
        _davIndexes.remove(library.id);
      }
      rethrow;
    }
  }
}

Uri _libraryEndpoint(String endpoint) {
  final uri = Uri.tryParse(endpoint.trim());
  final scheme = uri?.scheme.toLowerCase();
  if (uri == null ||
      (scheme != 'https' && scheme != 'http') ||
      uri.host.isEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      uri.authority.contains('@') ||
      !_validPath(uri)) {
    throw const FormatException('请输入不含凭据、参数或片段的 HTTP 或 HTTPS 地址');
  }
  return _directory(uri);
}

Uri _directory(Uri uri) =>
    uri.path.endsWith('/') ? uri : uri.replace(path: '${uri.path}/');

bool _validPath(Uri uri) => !uri.pathSegments.any(
  (part) =>
      part == '.' || part == '..' || part.contains(RegExp(r'[/\\\x00-\x1f]')),
);

final _tmdbSourceId = RegExp(r'^tmdb:(?:movie|tv|series):(\d+)$');
final _seasonSuffix = RegExp(
  r'(?:[\s._-]+(?:season[\s._-]*|s)(\d+)|\s*第\s*(\d+)\s*[季期])$',
  caseSensitive: false,
);

final class _LibraryMatch {
  _LibraryMatch(AnimeSubject subject, AnimeEpisode episode)
    : movie = subjectContentTypeOf(subject) == SubjectContentType.movie,
      tmdbId = _tmdbSourceId.firstMatch(subject.source.toLowerCase())?.group(1),
      year = int.tryParse(subject.year) {
    final aliases = {subject.title.trim(), subject.originalTitle.trim()}
      ..remove('');
    final explicitSeason = aliases
        .map(_seasonSuffix.firstMatch)
        .nonNulls
        .firstOrNull;
    season =
        episode.seasonNumber ??
        int.tryParse(
          explicitSeason?.group(1) ?? explicitSeason?.group(2) ?? '',
        ) ??
        1;
    number = episode.seasonEpisodeNumber ?? episode.number;
    // Bangumi often catalogs a season as its own subject. Search the show
    // name as well, but only when an explicit season suffix matches.
    queries = {
      ...aliases,
      if (!movie)
        for (final alias in aliases)
          if (_seasonSuffix.firstMatch(alias) case final suffix?
              when int.tryParse(suffix.group(1) ?? suffix.group(2)!) == season)
            alias.substring(0, suffix.start).trim(),
    }..remove('');
    names = queries.map(_titleKey).where((name) => name.isNotEmpty).toSet();
  }

  final bool movie;
  final String? tmdbId;
  final int? year;
  late final int season;
  late final int number;
  late final Set<String> queries;
  late final Set<String> names;
}

final _titlePunctuation = RegExp(r'[^\p{L}\p{N}]', unicode: true);
String _titleKey(String value) =>
    value.toLowerCase().replaceAll(_titlePunctuation, '');

Future<Uri?> _findApiVideo(
  http.Client client,
  MediaLibraryConfig library,
  _LibraryMatch match,
) async {
  final type = match.movie ? 'Movie' : 'Series';
  final params = {
    'Recursive': 'true',
    'IncludeItemTypes': type,
    'Fields': 'ProviderIds,OriginalTitle',
    'EnableImages': 'false',
    'EnableUserData': 'false',
    'Limit': '50',
  };
  final itemsPath = library.userId.isNotEmpty
      ? 'Users/${library.userId}/Items'
      : 'Items';
  Future<List<Map<String, dynamic>>> items(Map<String, String> filters) =>
      _apiItems(client, library, itemsPath, {...params, ...filters}, type);

  Map<String, dynamic>? item;
  final tmdb = match.tmdbId;
  if (tmdb != null && library.kind == MediaLibraryKind.emby) {
    item = (await items({
      'AnyProviderIdEquals': 'tmdb.$tmdb',
    })).where((candidate) => _itemTmdb(candidate) == tmdb).firstOrNull;
  }
  if (item == null) {
    final byId = <String, Map<String, dynamic>>{};
    for (final hits in await Future.wait([
      for (final query in match.queries) items({'SearchTerm': query}),
    ])) {
      for (final hit in hits) {
        byId[hit['Id'] as String] = hit;
      }
    }
    final hits = byId.values;
    if (tmdb != null) {
      item = hits
          .where((candidate) => _itemTmdb(candidate) == tmdb)
          .firstOrNull;
    }
    if (item == null) {
      final exact = hits.where((candidate) {
        final provider = _itemTmdb(candidate);
        if (tmdb != null && provider != null && provider != tmdb) return false;
        final year = int.tryParse('${candidate['ProductionYear']}');
        if ((match.movie || tmdb != null) &&
            match.year != null &&
            year != null &&
            year != match.year) {
          return false;
        }
        return [
          candidate['Name'],
          candidate['OriginalTitle'],
        ].whereType<String>().map(_titleKey).any(match.names.contains);
      }).toList();
      if (exact.length == 1) item = exact.single;
    }
  }
  // Jellyfin does not expose Emby's AnyProviderIdEquals filter. On a title
  // miss, check a bounded page of ID-tagged items (including localized titles).
  if (item == null &&
      tmdb != null &&
      library.kind == MediaLibraryKind.jellyfin) {
    item = (await items({
      'HasTmdbId': 'true',
      if (match.year case final year?) 'Years': '$year',
      'Limit': '200',
    })).where((candidate) => _itemTmdb(candidate) == tmdb).firstOrNull;
  }
  if (item == null) return null;
  var id = item['Id'] as String;
  if (!match.movie) {
    if (match.number <= 0 || match.season < 0) return null;
    final episodes = await _apiItems(client, library, 'Shows/$id/Episodes', {
      if (library.userId.isNotEmpty) 'UserId': library.userId,
      'Season': '${match.season}',
      'IsMissing': 'false',
      'EnableImages': 'false',
      'EnableUserData': 'false',
    }, 'Episode');
    final episode = episodes.where((item) {
      final season = int.tryParse('${item['ParentIndexNumber']}');
      return (season == null || match.season == season) &&
          int.tryParse('${item['IndexNumber']}') == match.number;
    }).firstOrNull;
    if (episode == null) return null;
    id = episode['Id'] as String;
  }
  return library.endpoint
      .resolve('Videos/$id/stream')
      .replace(queryParameters: {'static': 'true'});
}

String? _itemTmdb(Map<String, dynamic> item) {
  final ids = item['ProviderIds'];
  if (ids is! Map<String, dynamic>) return null;
  final id = ids.entries
      .where((entry) => entry.key.toLowerCase() == 'tmdb')
      .firstOrNull
      ?.value;
  return id == null ? null : '$id';
}

final _apiId = RegExp(r'^[A-Za-z0-9_-]+$');

Future<List<Map<String, dynamic>>> _apiItems(
  http.Client client,
  MediaLibraryConfig library,
  String path,
  Map<String, String> params,
  String type,
) async {
  final response = await client.get(
    library.endpoint.resolve(path).replace(queryParameters: params),
    headers: library._requestHeaders(),
  );
  if (response.statusCode != 200) {
    throw const FormatException('Library query failed');
  }
  final data =
      jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  return (data['Items'] as List)
      .whereType<Map<String, dynamic>>()
      .where(
        (item) =>
            item['Type'] == type &&
            item['IsPlaceHolder'] != true &&
            item['LocationType'] != 'Virtual' &&
            _apiId.hasMatch('${item['Id'] ?? ''}') &&
            item['Id'] is String,
      )
      .toList();
}

const _videoExtensions = {
  'mp4',
  'mkv',
  'm4v',
  'mov',
  'avi',
  'webm',
  'wmv',
  'ts',
  'm2ts',
  'mpg',
  'mpeg',
};
String? _videoExtension(String name) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0) return null;
  final extension = name.substring(dot + 1).toLowerCase();
  return _videoExtensions.contains(extension) ? extension : null;
}

const _dav = 'DAV:';
final _davOk = RegExp(r'\s2\d\d(?:\s|$)');
const _propfindBody =
    '<d:propfind xmlns:d="DAV:"><d:prop>'
    '<d:resourcetype/></d:prop></d:propfind>';

Future<List<Uri>> _readDavIndex(
  http.Client client,
  MediaLibraryConfig library,
) async {
  final root = library.endpoint;
  final queue = Queue.of([root]);
  final seen = {root};
  final files = <Uri>{};
  const maxDirs = 400;
  const maxFiles = 15000;
  const concurrency = 6;
  const scanBudget = Duration(seconds: 18);
  final watch = Stopwatch()..start();
  var scanned = 0;

  Future<void> scanDirectory(Uri directory, {required bool isRoot}) async {
    try {
      final response = await http.Response.fromStream(
        await client.send(
          http.Request('PROPFIND', directory)
            ..headers.addAll({
              ...library._requestHeaders(),
              'Depth': '1',
              'Content-Type': 'application/xml; charset=utf-8',
            })
            ..body = _propfindBody,
        ),
      );
      if (response.statusCode != 207) {
        if (isRoot) throw const FormatException('DAV listing failed');
        return;
      }
      final xml = XmlDocument.parse(utf8.decode(response.bodyBytes));
      for (final item in xml.rootElement.findElements(
        'response',
        namespace: _dav,
      )) {
        final href = item.getElement('href', namespace: _dav)?.innerText.trim();
        if (href == null || href.isEmpty) continue;
        final reference = Uri.tryParse(href);
        if (reference == null || !_validPath(reference)) continue;
        final target = directory.resolveUri(reference);
        if (target.scheme != root.scheme ||
            target.host != root.host ||
            target.port != root.port ||
            target.authority.contains('@') ||
            target.hasQuery ||
            target.hasFragment ||
            !target.path.startsWith(directory.path) ||
            target.path == directory.path ||
            !_validPath(target)) {
          continue;
        }
        final props = item
            .findElements('propstat', namespace: _dav)
            .where(
              (stat) => _davOk.hasMatch(
                stat.getElement('status', namespace: _dav)?.innerText ?? '',
              ),
            )
            .map((stat) => stat.getElement('prop', namespace: _dav))
            .nonNulls;
        final type = props
            .map((prop) => prop.getElement('resourcetype', namespace: _dav))
            .nonNulls
            .firstOrNull;
        if (type == null) continue;
        if (type.getElement('collection', namespace: _dav) != null) {
          final child = _directory(target);
          if (seen.length < maxDirs && seen.add(child)) queue.add(child);
        } else if (_videoExtension(target.pathSegments.last) != null) {
          files.add(target);
          if (files.length >= maxFiles) break;
        }
      }
    } catch (_) {
      if (isRoot) rethrow;
    }
  }

  // Always scan the root directory first so auth/URL failures surface cleanly.
  if (queue.isNotEmpty) {
    scanned++;
    await scanDirectory(queue.removeFirst(), isRoot: true);
  }
  while (queue.isNotEmpty &&
      scanned < maxDirs &&
      files.length < maxFiles &&
      watch.elapsed < scanBudget) {
    final batch = <Uri>[];
    while (queue.isNotEmpty &&
        batch.length < concurrency &&
        scanned < maxDirs) {
      batch.add(queue.removeFirst());
      scanned++;
    }
    await Future.wait([
      for (final dir in batch) scanDirectory(dir, isRoot: false),
    ]);
  }
  return files.toList()..sort((a, b) => a.path.compareTo(b.path));
}

final _davEpisode = RegExp(
  r'^(.+?)[\s._-]+S(\d+)E(\d+)(?:[\s._-].*)?$',
  caseSensitive: false,
);
final _davNamedEpisode = RegExp(
  r'^(.+?)[\s._\-\[\(【]+(?:'
  r'第\s*0*(\d{1,4})\s*[集话話回]'
  r'|(?:ep|e)\s*0*(\d{1,4})(?=$|[\s._\-\]\)】])'
  r'|-\s*0*(\d{1,3})(?=$|[\s._\-\[\(【])'
  r'|\[0*(\d{1,3})\]'
  r')',
  caseSensitive: false,
);
final _davStandaloneEpisode = RegExp(
  r'(?:^|[\s._\-\[\(【])(?:'
  r'S(\d+)E(\d+)'
  r'|第\s*0*(\d{1,4})\s*[集话話回]'
  r'|(?:ep|e)\s*0*(\d{1,4})(?=$|[\s._\-\]\)】])'
  r'|-\s*0*(\d{1,3})(?=$|[\s._\-\[\(【])'
  r'|\[0*(\d{1,3})\]'
  r'|^0*(\d{1,3})(?=$|[\s._\-\[\(【])'
  r')',
  caseSensitive: false,
);
final _davSeasonFolder = RegExp(
  r'^(?:(?:season[\s._-]*|s)0*(\d+)|第\s*([一二三四五六七八九十两\d]+)\s*[季部期])$',
  caseSensitive: false,
);
final _davMovie = RegExp(
  r'^(.+?)[\s._(\[【-]+((?:18|19|20)\d{2})(?=$|[\s._)\-\]】])',
);
final _davLeadingTags = RegExp(r'^(?:\s*(?:\[[^\]]*\]|【[^】]*】|\([^)]*\)))+\s*');
final _davTrailingTags = RegExp(
  r'(?:[\s._-]+(?:2160p|1080p|720p|4k|uhd|web-?dl|bluray|bdrip|remux|hevc|x265|x264|hdr\d*|aac|flac).*|\s*(?:\[[^\]]*\]|【[^】]*】|\((?:18|19|20)\d{2}\)))+$',
  caseSensitive: false,
);
final _davTrailer = RegExp(
  r'(?:^sample$|[\s._\-\[\(【]sample(?:$|[\s._\-\]\)】])|(?:^|[\s._\-\[\(【])(?:trailer|teaser|pv\d*|预告|預告|花絮|特辑|特輯)(?:$|[\s._\-\]\)】]))',
  caseSensitive: false,
);

int? _parseSeasonNumberText(String raw) {
  final trimmed = raw.trim();
  final digits = int.tryParse(trimmed);
  if (digits != null) return digits;
  const map = {
    '一': 1,
    '二': 2,
    '两': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
    '十': 10,
  };
  if (map.containsKey(trimmed)) return map[trimmed];
  if (trimmed.contains('十')) {
    final parts = trimmed.split('十');
    final tens = parts[0].isEmpty ? 1 : map[parts[0]];
    final ones = parts[1].isEmpty ? 0 : map[parts[1]];
    if (tens != null && ones != null) return tens * 10 + ones;
  }
  return null;
}

({String title, int? season}) _cleanDavShowName(String raw) {
  var cleaned = raw.replaceFirst(_davLeadingTags, '').trim();
  cleaned = cleaned.replaceFirst(_davTrailingTags, '').trim();
  final suffix = _seasonSuffix.firstMatch(cleaned);
  if (suffix != null) {
    final season = _parseSeasonNumberText(
      suffix.group(1) ?? suffix.group(2) ?? '',
    );
    final base = cleaned.substring(0, suffix.start).trim();
    if (base.isNotEmpty) return (title: base, season: season);
  }
  return (title: cleaned, season: null);
}

({int? season, int episode})? _extractDavEpisodeNumber(String stem) {
  final stripped = stem.replaceFirst(_davLeadingTags, '').trim();
  final sxe = RegExp(
    r'S(\d+)E(\d+)',
    caseSensitive: false,
  ).firstMatch(stripped);
  if (sxe != null) {
    final s = int.tryParse(sxe.group(1)!);
    final e = int.tryParse(sxe.group(2)!);
    if (s != null && e != null) return (season: s, episode: e);
  }
  final m = _davStandaloneEpisode.firstMatch(stripped);
  if (m == null) return null;
  if (m.group(1) != null && m.group(2) != null) {
    final s = int.tryParse(m.group(1)!);
    final e = int.tryParse(m.group(2)!);
    if (s != null && e != null) return (season: s, episode: e);
  }
  for (var i = 3; i <= 7; i++) {
    final raw = m.group(i);
    if (raw != null) {
      final num = int.tryParse(raw);
      if (num != null && num > 0 && num != 480 && num != 720 && num != 1080) {
        return (season: null, episode: num);
      }
    }
  }
  return null;
}

Uri? _findDavFile(List<Uri> entries, _LibraryMatch match) {
  Uri? unqualifiedMovie;
  final moviesByYear = <int, Uri>{};
  for (final entry in entries) {
    final segments = entry.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) continue;
    final name = segments.last;
    final dot = name.lastIndexOf('.');
    if (dot <= 0) continue;
    final stem = name.substring(0, dot);
    if (_davTrailer.hasMatch(stem)) continue;

    final strippedStem = stem.replaceFirst(_davLeadingTags, '').trim();
    final episode = _davEpisode.firstMatch(strippedStem);
    final parent = segments.length >= 2 ? segments[segments.length - 2] : '';
    final grandParent = segments.length >= 3
        ? segments[segments.length - 3]
        : '';

    if (match.movie) {
      if (episode != null) continue;
      // Try filename first, then parent folder (e.g. "电影名 (2024)/movie.mkv").
      for (final candidate in [strippedStem, parent]) {
        if (candidate.isEmpty) continue;
        final movie = _davMovie.firstMatch(candidate);
        if (movie != null) {
          final clean = _cleanDavShowName(movie.group(1)!).title;
          if (match.names.contains(_titleKey(clean))) {
            final year = int.parse(movie.group(2)!);
            if (year == match.year) return entry;
            if (match.year == null) moviesByYear.putIfAbsent(year, () => entry);
          }
        }
        final cleanFull = _cleanDavShowName(candidate).title;
        if (match.names.contains(_titleKey(cleanFull))) {
          unqualifiedMovie ??= entry;
        }
      }
      continue;
    }

    // 1. Direct filename match: Title.S01E01
    if (episode != null &&
        match.names.contains(
          _titleKey(_cleanDavShowName(episode.group(1)!).title),
        ) &&
        int.tryParse(episode.group(2)!) == match.season &&
        int.tryParse(episode.group(3)!) == match.number) {
      return entry;
    }

    // Check folder context (e.g. "/Show/Season 2/01.mkv" or "/Show 第2季/01.mkv").
    int? folderSeason;
    String showFolder = parent;
    final seasonMatch = _davSeasonFolder.firstMatch(parent.trim());
    if (seasonMatch != null && grandParent.isNotEmpty) {
      folderSeason = _parseSeasonNumberText(
        seasonMatch.group(1) ?? seasonMatch.group(2) ?? '',
      );
      showFolder = grandParent;
    }

    // 2. Direct filename match: "[SubGroup] 标题 - 01", "标题 第01集", "标题 EP01"
    final namedEp = _davNamedEpisode.firstMatch(strippedStem);
    if (namedEp != null) {
      final showInfo = _cleanDavShowName(namedEp.group(1)!);
      final epRaw =
          namedEp.group(2) ??
          namedEp.group(3) ??
          namedEp.group(4) ??
          namedEp.group(5);
      final epNum = int.tryParse(epRaw ?? '');
      final effectiveSeason = showInfo.season ?? folderSeason ?? 1;
      if (epNum == match.number &&
          effectiveSeason == match.season &&
          (match.names.contains(_titleKey(showInfo.title)) ||
              match.names.contains(_titleKey(namedEp.group(1)!)))) {
        return entry;
      }
    }

    // 3. Parent/grandparent folder holds the title, filename holds episode number.
    if (showFolder.isNotEmpty) {
      final folderInfo = _cleanDavShowName(showFolder);
      final titleMatches =
          match.names.contains(_titleKey(folderInfo.title)) ||
          match.names.contains(_titleKey(showFolder));
      if (titleMatches) {
        final parsed = _extractDavEpisodeNumber(stem);
        if (parsed != null) {
          final effectiveSeason =
              parsed.season ?? folderSeason ?? folderInfo.season ?? 1;
          if (effectiveSeason == match.season &&
              parsed.episode == match.number) {
            return entry;
          }
        }
      }
    }
  }
  return unqualifiedMovie ??
      (moviesByYear.length == 1 ? moviesByYear.values.single : null);
}
