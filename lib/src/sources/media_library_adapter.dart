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
  }) : name = name.trim(),
       endpoint = _libraryEndpoint(endpoint),
       _username = username.trim(),
       _secret = kind == MediaLibraryKind.webdav ? secret : secret.trim() {
    if (this.name.isEmpty) throw const FormatException('请输入媒体库名称');
    if (kind == MediaLibraryKind.webdav) {
      if (_username.isEmpty || _username.contains(':') || _secret.isEmpty) {
        throw const FormatException('请输入有效的 WebDAV 用户名和密码');
      }
    } else if (!RegExp(r'^[A-Za-z0-9._~-]+$').hasMatch(_secret)) {
      throw const FormatException('请输入有效的 API 密钥');
    }
  }

  final String id;
  final String name;
  final MediaLibraryKind kind;
  final Uri endpoint;
  final String _username;
  final String _secret;

  factory MediaLibraryConfig._fromRecord(Map<String, dynamic> record) =>
      MediaLibraryConfig._(
        id: record['id'] as String,
        name: record['name'] as String,
        kind: MediaLibraryKind.values.byName(record['kind'] as String),
        endpoint: record['endpoint'] as String,
        username: record['username'] as String,
        secret: record['secret'] as String,
      );

  Map<String, String> _toRecord() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'endpoint': endpoint.toString(),
    'username': _username,
    'secret': _secret,
  };

  Map<String, String> _requestHeaders() => switch (kind) {
    MediaLibraryKind.emby => {'X-Emby-Token': _secret},
    MediaLibraryKind.jellyfin => {
      'Authorization':
          'MediaBrowser Token="$_secret", Client="Zeluna", '
          'Device="Zeluna", DeviceId="$id", Version="1"',
    },
    MediaLibraryKind.webdav => {
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
    );
    return _update(replaceId, entry);
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
    Future<T> Function(http.Client) run,
  ) async {
    final policy = NetworkRequestPolicy.privateMediaLibrary(
      origin: library.endpoint,
      maxResponseBytes: 4 * 1024 * 1024,
      requestTimeout: const Duration(seconds: 4),
    );
    final wire = _createClient?.call();
    final client = wire == null
        ? createNetworkHttpClient(policy)
        : PolicyHttpClient(inner: wire, policy: policy);
    try {
      return await run(client).timeout(const Duration(seconds: 12));
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
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      uri.authority.contains('@') ||
      !_validPath(uri)) {
    throw const FormatException('请输入不含凭据、参数或片段的 HTTPS 地址');
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
  Future<List<Map<String, dynamic>>> items(Map<String, String> filters) =>
      _apiItems(client, library, 'Items', {...params, ...filters}, type);

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
  // Depth: infinity is disabled by common DAV servers. Bound a walk instead.
  for (
    var scanned = 0;
    scanned < 256 && queue.isNotEmpty && files.length < 10000;
    scanned++
  ) {
    final directory = queue.removeFirst();
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
      throw const FormatException('DAV listing failed');
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
        if (seen.length < 256 && seen.add(child)) queue.add(child);
      } else if (_videoExtension(target.pathSegments.last) != null) {
        files.add(target);
        if (files.length >= 10000) break;
      }
    }
  }
  return files.toList()..sort((a, b) => a.path.compareTo(b.path));
}

final _davEpisode = RegExp(
  r'^(.+?)[\s._-]+S(\d+)E(\d+)(?:[\s._-].*)?$',
  caseSensitive: false,
);
final _davMovie = RegExp(r'^(.+)[\s._(-]+((?:18|19|20)\d{2})(?=$|[\s._)\-])');

Uri? _findDavFile(List<Uri> entries, _LibraryMatch match) {
  Uri? unqualifiedMovie;
  final moviesByYear = <int, Uri>{};
  for (final entry in entries) {
    final name = entry.pathSegments.last;
    final stem = name.substring(0, name.lastIndexOf('.'));
    final episode = _davEpisode.firstMatch(stem);
    if (match.movie) {
      if (episode != null) continue;
      final movie = _davMovie.firstMatch(stem);
      if (movie != null && match.names.contains(_titleKey(movie.group(1)!))) {
        final year = int.parse(movie.group(2)!);
        if (year == match.year) return entry;
        if (match.year == null) moviesByYear.putIfAbsent(year, () => entry);
      }
      if (match.names.contains(_titleKey(stem))) unqualifiedMovie ??= entry;
    } else if (episode != null &&
        match.names.contains(_titleKey(episode.group(1)!)) &&
        int.tryParse(episode.group(2)!) == match.season &&
        int.tryParse(episode.group(3)!) == match.number) {
      return entry;
    }
  }
  return unqualifiedMovie ??
      (moviesByYear.length == 1 ? moviesByYear.values.single : null);
}
