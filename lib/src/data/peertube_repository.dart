import 'dart:convert';

import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import '../domain/anime_models.dart';

const _peerTubeSourcePrefix = 'peertube:';

/// Discovers explicitly open-licensed videos through Sepia Search and resolves
/// their playable files from the originating PeerTube instance.
class PeerTubeRepository {
  PeerTubeRepository({
    http.Client? client,
    Uri? searchEndpoint,
    this.requestTimeout = const Duration(seconds: 16),
  }) : _client = client ?? http.Client(),
       _searchEndpoint =
           searchEndpoint ??
           Uri.parse('https://sepiasearch.org/api/v1/search/videos');

  static const _maxApiCount = 50;
  static const _oversamplingFactor = 3;

  final http.Client _client;
  final Uri _searchEndpoint;
  final Duration requestTimeout;

  Future<List<AnimeSubject>> trending({int page = 1, int limit = 24}) {
    return _discover(page: page, limit: limit, sort: '-hot');
  }

  Future<List<AnimeSubject>> search(
    String keyword, {
    int page = 1,
    int limit = 24,
  }) {
    final query = keyword.trim();
    if (query.isEmpty) return Future.value(const []);
    return _discover(keyword: query, page: page, limit: limit);
  }

  Future<List<PlaybackLine>> linesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode,
  ) async {
    final source = _decodeSource(subject.source);
    if (source == null) return const [];

    try {
      final response = await _client
          .get(
            source.origin.resolve(
              '/api/v1/videos/${Uri.encodeComponent(source.uuid)}',
            ),
            headers: const {'Accept': 'application/json'},
          )
          .timeout(requestTimeout);
      if (response.statusCode != 200) return const [];

      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map) return const [];
      final json = decoded.cast<String, dynamic>();
      if (json['nsfw'] != false) return const [];
      final license = _openLicense(json['licence']);
      if (license == null) return const [];

      final candidates = _playbackCandidates(json, source.origin);
      if (candidates.isEmpty) return const [];
      return candidates
          .take(12)
          .map(
            (candidate) => PlaybackLine(
              id: 'peertube:${source.uuid}:${_stableId(candidate.url.toString())}',
              episodeId: episode.id,
              providerId: 'peertube',
              providerName: 'PeerTube · ${source.origin.host}',
              title: '${subject.title} · ${candidate.quality}',
              quality: candidate.quality,
              format: candidate.format,
              url: candidate.url.toString(),
              sizeLabel: _sizeLabel(candidate.size),
              available: true,
              message: '开放许可：${license.label}',
            ),
          )
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Future<List<AnimeSubject>> _discover({
    String? keyword,
    String? sort,
    required int page,
    required int limit,
  }) async {
    final pageSize = limit.clamp(1, _maxApiCount).toInt();
    final fetchCount = (pageSize * _oversamplingFactor)
        .clamp(pageSize, _maxApiCount)
        .toInt();
    final normalizedPage = page < 1 ? 1 : page;
    final query = <String, String>{
      'start': '${(normalizedPage - 1) * fetchCount}',
      'count': '$fetchCount',
      'nsfw': 'false',
      if (keyword != null && keyword.isNotEmpty) 'search': keyword,
      if (sort != null && sort.isNotEmpty) 'sort': sort,
    };

    try {
      final response = await _client
          .get(
            _searchEndpoint.replace(queryParameters: query),
            headers: const {'Accept': 'application/json'},
          )
          .timeout(requestTimeout);
      if (response.statusCode != 200) return const [];

      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      final data = decoded is Map ? decoded['data'] : null;
      if (data is! List) return const [];
      return data
          .whereType<Map>()
          .map((item) => _subjectFromSearchResult(item.cast<String, dynamic>()))
          .whereType<AnimeSubject>()
          .take(pageSize)
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  AnimeSubject? _subjectFromSearchResult(Map<String, dynamic> json) {
    if (json['nsfw'] != false) return null;
    final license = _openLicense(json['licence']);
    if (license == null) return null;

    final uuid = json['uuid']?.toString().trim() ?? '';
    if (!_isPeerTubeUuid(uuid)) return null;
    final origin = _originFromSearchResult(json);
    if (origin == null) return null;
    final title = json['name']?.toString().trim() ?? '';
    if (title.isEmpty) return null;

    final category = _mapLabel(json['category']);
    final language = _mapLabel(json['language']);
    final description = _plainText(
      json['description']?.toString() ??
          json['truncatedDescription']?.toString() ??
          '',
    );
    final coverUrl = _mediaUrl(
      json['thumbnailUrl'] ?? _thumbnailUrl(json['thumbnails'], largest: false),
      origin,
    );
    final bannerUrl = _mediaUrl(
      json['previewUrl'] ?? _thumbnailUrl(json['thumbnails'], largest: true),
      origin,
    );
    final tags = _subjectTags(json['tags'], license.label);

    return AnimeSubject(
      id: _stableId('${origin.host}|$uuid'),
      title: title,
      originalTitle: title,
      summary: description,
      coverUrl: coverUrl?.toString(),
      bannerUrl: bannerUrl?.toString() ?? coverUrl?.toString(),
      date: _nonBlank(
        json['originallyPublishedAt']?.toString(),
        fallback: json['publishedAt']?.toString(),
      ),
      platform: json['isLive'] == true ? 'Live' : 'PeerTube',
      language: language.isEmpty ? '未知' : language,
      region: origin.host,
      status: '开放许可 · ${license.label}',
      categories: [AnimeCategory(name: category.isEmpty ? '开放视频' : category)],
      tags: tags,
      totalEpisodes: 1,
      source: _encodeSource(origin, uuid),
    );
  }
}

List<_PlaybackCandidate> _playbackCandidates(
  Map<String, dynamic> json,
  Uri origin,
) {
  final candidates = <_PlaybackCandidate>[];
  final playlists = json['streamingPlaylists'];
  if (playlists is List) {
    for (final rawPlaylist in playlists.whereType<Map>()) {
      final playlist = rawPlaylist.cast<String, dynamic>();
      final master = _mediaUrl(playlist['playlistUrl'], origin);
      if (master != null) {
        candidates.add(
          _PlaybackCandidate(
            url: master,
            format: 'HLS',
            quality: '自动',
            size: null,
          ),
        );
      }
      final files = playlist['files'];
      if (files is List) {
        for (final rawFile in files.whereType<Map>()) {
          _addPeerTubeFileCandidates(
            candidates,
            rawFile.cast<String, dynamic>(),
            origin,
            includePlaylist: true,
          );
        }
      }
    }
  }

  final files = json['files'];
  if (files is List) {
    for (final rawFile in files.whereType<Map>()) {
      _addPeerTubeFileCandidates(
        candidates,
        rawFile.cast<String, dynamic>(),
        origin,
        includePlaylist: false,
      );
    }
  }

  final byUrl = <String, _PlaybackCandidate>{};
  for (final candidate in candidates) {
    byUrl.putIfAbsent(candidate.url.toString(), () => candidate);
  }
  final result = byUrl.values.toList(growable: false)
    ..sort((a, b) {
      final formatOrder = _formatOrder(
        a.format,
      ).compareTo(_formatOrder(b.format));
      if (formatOrder != 0) return formatOrder;
      return _resolutionScore(b.quality).compareTo(_resolutionScore(a.quality));
    });
  return result;
}

void _addPeerTubeFileCandidates(
  List<_PlaybackCandidate> candidates,
  Map<String, dynamic> file,
  Uri origin, {
  required bool includePlaylist,
}) {
  final quality = _resolutionLabel(file['resolution']);
  final size = _intValue(file['size']);
  if (includePlaylist) {
    final playlistUrl = _mediaUrl(file['playlistUrl'], origin);
    if (playlistUrl != null) {
      candidates.add(
        _PlaybackCandidate(
          url: playlistUrl,
          format: 'HLS',
          quality: quality,
          size: size,
        ),
      );
    }
  }
  final fileUrl = _mediaUrl(file['fileUrl'], origin);
  if (fileUrl != null) {
    candidates.add(
      _PlaybackCandidate(
        url: fileUrl,
        format: 'MP4',
        quality: quality,
        size: size,
      ),
    );
  }
}

_OpenLicense? _openLicense(Object? value) {
  if (value is! Map) return null;
  final id = _intValue(value['id']);
  final label = value['label']?.toString().trim() ?? '';
  if (label.isEmpty || id == 9) return null;
  final lower = label.toLowerCase();
  if (_containsAny(lower, const [
    'all rights reserved',
    'copyright',
    'unknown',
    'unspecified',
    'no licence',
    'no license',
  ])) {
    return null;
  }
  if (id != null && id >= 1 && id <= 8) {
    return _OpenLicense(id: id, label: label);
  }
  if (_containsAny(lower, const [
    'attribution',
    'creative commons',
    'public domain',
    'cc by',
    'cc0',
    'copyleft',
    'art libre',
  ])) {
    return _OpenLicense(id: id, label: label);
  }
  return null;
}

Uri? _originFromSearchResult(Map<String, dynamic> json) {
  for (final value in [
    json['url'],
    json['embedUrl'],
    if (json['account'] is Map) (json['account'] as Map)['url'],
    if (json['channel'] is Map) (json['channel'] as Map)['url'],
  ]) {
    final uri = Uri.tryParse(value?.toString() ?? '');
    if (uri != null && _isSafePublicHttpUri(uri)) {
      return Uri(
        scheme: uri.scheme,
        host: uri.host,
        port: uri.hasPort ? uri.port : null,
      );
    }
  }
  for (final value in [
    if (json['account'] is Map) (json['account'] as Map)['host'],
    if (json['channel'] is Map) (json['channel'] as Map)['host'],
  ]) {
    final uri = Uri.tryParse('https://${value?.toString().trim() ?? ''}');
    if (uri != null && _isSafePublicHttpUri(uri)) {
      return Uri(
        scheme: 'https',
        host: uri.host,
        port: uri.hasPort ? uri.port : null,
      );
    }
  }
  return null;
}

String _encodeSource(Uri origin, String uuid) {
  return '$_peerTubeSourcePrefix${Uri.encodeComponent(origin.toString())}|$uuid';
}

_PeerTubeSource? _decodeSource(String value) {
  if (!value.startsWith(_peerTubeSourcePrefix)) return null;
  final payload = value.substring(_peerTubeSourcePrefix.length);
  final separator = payload.lastIndexOf('|');
  if (separator <= 0 || separator == payload.length - 1) return null;
  Uri? origin;
  try {
    origin = Uri.tryParse(Uri.decodeComponent(payload.substring(0, separator)));
  } catch (_) {
    return null;
  }
  final uuid = payload.substring(separator + 1).trim();
  if (origin == null ||
      !_isSafePublicHttpUri(origin) ||
      !_isPeerTubeUuid(uuid)) {
    return null;
  }
  return _PeerTubeSource(
    origin: Uri(
      scheme: origin.scheme,
      host: origin.host,
      port: origin.hasPort ? origin.port : null,
    ),
    uuid: uuid,
  );
}

Uri? _mediaUrl(Object? value, Uri origin) {
  final text = value?.toString().trim() ?? '';
  if (text.isEmpty) return null;
  final uri = origin.resolve(text);
  return _isSafePublicHttpUri(uri) ? uri : null;
}

Object? _thumbnailUrl(Object? value, {required bool largest}) {
  if (value is! List) return null;
  final thumbnails = value.whereType<Map>().toList(growable: false);
  if (thumbnails.isEmpty) return null;
  thumbnails.sort(
    (a, b) =>
        (_intValue(a['width']) ?? 0).compareTo(_intValue(b['width']) ?? 0),
  );
  final selected = largest ? thumbnails.last : thumbnails.first;
  return selected['fileUrl'] ?? selected['url'] ?? selected['path'];
}

List<AnimeTag> _subjectTags(Object? value, String licenseLabel) {
  final names = <String>['PeerTube', licenseLabel];
  if (value is List) {
    names.addAll(
      value
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .take(4),
    );
  }
  final seen = <String>{};
  return names
      .where((name) => seen.add(name.toLowerCase()))
      .map((name) => AnimeTag(name: name))
      .toList(growable: false);
}

String _mapLabel(Object? value) {
  if (value is! Map) return '';
  return value['label']?.toString().trim() ??
      value['id']?.toString().trim() ??
      '';
}

String _resolutionLabel(Object? value) {
  if (value is Map) {
    final label = value['label']?.toString().trim() ?? '';
    if (label.isNotEmpty) return label;
    final id = _intValue(value['id']);
    if (id != null && id > 0) return '${id}p';
  }
  return '原画';
}

int _formatOrder(String format) => format == 'HLS' ? 0 : 1;

int _resolutionScore(String value) {
  if (value == '自动') return 100000;
  return int.tryParse(RegExp(r'\d+').firstMatch(value)?.group(0) ?? '') ?? 0;
}

String? _sizeLabel(int? bytes) {
  if (bytes == null || bytes <= 0) return null;
  final megabytes = bytes / 1024 / 1024;
  if (megabytes >= 1024) {
    return '${(megabytes / 1024).toStringAsFixed(1)} GB';
  }
  return '${megabytes.toStringAsFixed(1)} MB';
}

String _plainText(String value) {
  final withoutMarkdownLinks = value
      .replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), '')
      .replaceAllMapped(
        RegExp(r'\[([^\]]+)\]\([^)]*\)'),
        (match) => match.group(1) ?? '',
      );
  return html_parser
          .parseFragment(withoutMarkdownLinks)
          .text
          ?.replaceAll(RegExp(r'\s+'), ' ')
          .trim() ??
      '';
}

String? _nonBlank(String? value, {String? fallback}) {
  final text = value?.trim() ?? '';
  if (text.isNotEmpty) return text;
  final fallbackText = fallback?.trim() ?? '';
  return fallbackText.isEmpty ? null : fallbackText;
}

int? _intValue(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  return int.tryParse(value?.toString() ?? '');
}

bool _isPeerTubeUuid(String value) {
  return RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    caseSensitive: false,
  ).hasMatch(value);
}

bool _isSafePublicHttpUri(Uri uri) {
  if ((uri.scheme != 'https' && uri.scheme != 'http') ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return false;
  }
  final host = uri.host.toLowerCase();
  if (host == 'localhost' ||
      host == '::1' ||
      host.endsWith('.local') ||
      host.endsWith('.internal')) {
    return false;
  }
  final ipv4 = host.split('.').map(int.tryParse).toList(growable: false);
  if (ipv4.length == 4 && ipv4.every((part) => part != null)) {
    final first = ipv4[0]!;
    final second = ipv4[1]!;
    if (first == 0 ||
        first == 10 ||
        first == 127 ||
        first >= 224 ||
        (first == 169 && second == 254) ||
        (first == 172 && second >= 16 && second <= 31) ||
        (first == 192 && second == 168)) {
      return false;
    }
  }
  return true;
}

bool _containsAny(String text, List<String> values) {
  return values.any(text.contains);
}

int _stableId(String value) {
  var hash = 0x811c9dc5;
  for (final codeUnit in value.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  final result = hash & 0x7fffffff;
  return result == 0 ? 1 : result;
}

class _OpenLicense {
  const _OpenLicense({required this.id, required this.label});

  final int? id;
  final String label;
}

class _PeerTubeSource {
  const _PeerTubeSource({required this.origin, required this.uuid});

  final Uri origin;
  final String uuid;
}

class _PlaybackCandidate {
  const _PlaybackCandidate({
    required this.url,
    required this.format,
    required this.quality,
    required this.size,
  });

  final Uri url;
  final String format;
  final String quality;
  final int? size;
}
