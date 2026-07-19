import 'dart:convert';

import 'package:http/http.dart' as http;

import '../domain/anime_models.dart';

const _commonsSourcePrefix = 'commons:';

/// Discovers and resolves openly licensed video files from Wikimedia Commons.
///
/// Only Public Domain, CC0, CC BY and CC BY-SA items are accepted. The media
/// URL is resolved again before playback so cached catalogue data never turns
/// into an unverified direct link.
class WikimediaCommonsRepository {
  WikimediaCommonsRepository({
    http.Client? client,
    Uri? endpoint,
    this.requestTimeout = const Duration(seconds: 18),
  }) : _client = client ?? http.Client(),
       _endpoint =
           endpoint ?? Uri.parse('https://commons.wikimedia.org/w/api.php');

  final http.Client _client;
  final Uri _endpoint;
  final Duration requestTimeout;

  static const _discoveryGroups = <_CommonsGroup>[
    _CommonsGroup(
      query: 'filetype:video incategory:"Animated films"',
      label: '开放动画',
    ),
    _CommonsGroup(
      query: 'filetype:video incategory:"Animated short films"',
      label: '动画短片',
    ),
    _CommonsGroup(
      query: 'filetype:video incategory:"Documentary films"',
      label: '开放纪录片',
    ),
    _CommonsGroup(
      query: 'filetype:video incategory:"Short films"',
      label: '开放短片',
    ),
  ];

  Future<List<AnimeSubject>> trending({int page = 1, int limit = 24}) async {
    final safeLimit = limit.clamp(1, 48).toInt();
    final perGroup = ((safeLimit / _discoveryGroups.length).ceil() + 2).clamp(
      4,
      16,
    );
    final groups = await Future.wait([
      for (final group in _discoveryGroups)
        _discover(
          query: group.query,
          label: group.label,
          page: page,
          limit: perGroup,
        ).onError((_, _) => const <AnimeSubject>[]),
    ]);
    return _interleave(groups).take(safeLimit).toList(growable: false);
  }

  Future<List<AnimeSubject>> search(
    String keyword, {
    int page = 1,
    int limit = 24,
  }) {
    final query = keyword.trim();
    if (query.isEmpty) return Future.value(const []);
    return _discover(
      query: 'filetype:video $query',
      label: '开放视频',
      page: page,
      limit: limit.clamp(1, 48).toInt(),
    );
  }

  Future<List<PlaybackLine>> linesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode,
  ) async {
    final pageId = _pageIdFromSource(subject.source);
    if (pageId == null) return const [];
    try {
      final response = await _client
          .get(
            _endpoint.replace(
              queryParameters: {
                'action': 'query',
                'pageids': '$pageId',
                'prop': 'videoinfo',
                'viprop': 'url|mime|mediatype|size|extmetadata|derivatives',
                'viurlwidth': '960',
                'format': 'json',
                'formatversion': '2',
                'origin': '*',
              },
            ),
            headers: const {
              'Accept': 'application/json',
              'User-Agent': 'anime-app/1.0 (open media client)',
            },
          )
          .timeout(requestTimeout);
      if (response.statusCode != 200) return const [];
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      final pages = decoded is Map && decoded['query'] is Map
          ? (decoded['query'] as Map)['pages']
          : null;
      if (pages is! List || pages.isEmpty || pages.first is! Map) {
        return const [];
      }
      final page = (pages.first as Map).cast<String, dynamic>();
      final info = _videoInfo(page);
      if (info == null) return const [];
      final media = _verifiedMediaCandidates(info);
      if (media.isEmpty) return const [];
      return media
          .take(8)
          .map(
            (item) => PlaybackLine(
              id: 'commons:$pageId:${_stableId(item.url)}',
              episodeId: episode.id,
              providerId: 'wikimedia_commons',
              providerName: 'Wikimedia Commons',
              title: '${subject.title} · ${item.quality}',
              quality: item.quality,
              format: item.format,
              url: item.url,
              sizeLabel: _sizeLabel(item.size),
              available: true,
              message: '开放许可：${_licenseLabelZh(item.license)}',
            ),
          )
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Future<List<AnimeSubject>> _discover({
    required String query,
    required String label,
    required int page,
    required int limit,
  }) async {
    final safeLimit = limit.clamp(1, 48).toInt();
    final normalizedPage = page < 1 ? 1 : page;
    try {
      final response = await _client
          .get(
            _endpoint.replace(
              queryParameters: {
                'action': 'query',
                'generator': 'search',
                'gsrsearch': query,
                'gsrnamespace': '6',
                'gsrlimit': '$safeLimit',
                'gsroffset': '${(normalizedPage - 1) * safeLimit}',
                'prop': 'videoinfo',
                'viprop': 'url|mime|mediatype|size|extmetadata|derivatives',
                'viurlwidth': '720',
                'format': 'json',
                'formatversion': '2',
                'origin': '*',
              },
            ),
            headers: const {
              'Accept': 'application/json',
              'User-Agent': 'anime-app/1.0 (open media client)',
            },
          )
          .timeout(requestTimeout);
      if (response.statusCode != 200) return const [];
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      final pages = decoded is Map && decoded['query'] is Map
          ? (decoded['query'] as Map)['pages']
          : null;
      if (pages is! List) return const [];
      return pages
          .whereType<Map>()
          .map((page) => _subjectFromPage(page.cast<String, dynamic>(), label))
          .whereType<AnimeSubject>()
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  AnimeSubject? _subjectFromPage(Map<String, dynamic> page, String kind) {
    final pageId = _intValue(page['pageid']);
    if (pageId == null || pageId <= 0) return null;
    final info = _videoInfo(page);
    if (info == null) return null;
    final mediaCandidates = _verifiedMediaCandidates(info);
    if (mediaCandidates.isEmpty) return null;
    final media = mediaCandidates.first;
    final metadata = _metadata(info);
    final rawTitle = _metadataValue(metadata, 'ObjectName');
    final originalTitle = _cleanFileTitle(
      rawTitle.isEmpty ? page['title']?.toString() ?? '' : rawTitle,
    );
    if (originalTitle.isEmpty) return null;
    final creator = _plainText(_metadataValue(metadata, 'Artist'));
    final dateText = _metadataValue(metadata, 'DateTimeOriginal');
    final year = RegExp(r'(18|19|20)\d{2}').firstMatch(dateText)?.group(0);
    final duration = _durationLabel(media.duration);
    final licenseZh = _licenseLabelZh(media.license);
    final description = [
      '来自 Wikimedia Commons 的$kind，已通过开放许可筛选，可直接播放。',
      if (duration.isNotEmpty) '时长 $duration。',
      if (creator.isNotEmpty) '创作者：$creator。',
      '许可：$licenseZh。',
      '作品原名：$originalTitle。',
    ].join();
    final displayTitle = _displayTitle(originalTitle, kind);
    return AnimeSubject(
      id: pageId,
      title: displayTitle,
      originalTitle: originalTitle,
      summary: description,
      coverUrl: media.thumbnailUrl,
      bannerUrl: media.thumbnailUrl,
      date: year == null ? null : '$year-01-01',
      platform: 'Movie',
      language: '未知',
      region: 'Wikimedia Commons',
      status: '$kind · $licenseZh',
      categories: [AnimeCategory(name: kind)],
      tags: [
        const AnimeTag(name: 'Wikimedia Commons'),
        AnimeTag(name: licenseZh),
      ],
      totalEpisodes: 1,
      source: '$_commonsSourcePrefix$pageId',
    );
  }
}

Map<String, dynamic>? _videoInfo(Map<String, dynamic> page) {
  final value = page['videoinfo'];
  if (value is! List || value.isEmpty || value.first is! Map) return null;
  return (value.first as Map).cast<String, dynamic>();
}

Map<String, dynamic> _metadata(Map<String, dynamic> info) {
  final value = info['extmetadata'];
  return value is Map ? value.cast<String, dynamic>() : const {};
}

String _metadataValue(Map<String, dynamic> metadata, String key) {
  final value = metadata[key];
  if (value is Map) return value['value']?.toString().trim() ?? '';
  return '';
}

List<_VerifiedMedia> _verifiedMediaCandidates(Map<String, dynamic> info) {
  final mime = info['mime']?.toString().trim().toLowerCase() ?? '';
  final metadata = _metadata(info);
  final license = _metadataValue(metadata, 'LicenseShortName');
  if (!_isAllowedLicense(license)) return const [];
  final duration = _doubleValue(info['duration']);
  if (duration != null && duration < 5) return const [];
  final thumbnail = info['thumburl']?.toString().trim() ?? '';
  final candidates = <_VerifiedMedia>[];
  final derivatives = info['derivatives'];
  if (derivatives is List) {
    for (final raw in derivatives.whereType<Map>()) {
      final derivative = raw.cast<String, dynamic>();
      final type = derivative['type']?.toString().toLowerCase() ?? '';
      if (!type.startsWith('video/webm') && !type.startsWith('video/mp4')) {
        continue;
      }
      final url = _safeMediaUrl(derivative['src']);
      if (url == null) continue;
      final width = _intValue(derivative['width']);
      final height = _intValue(derivative['height']);
      candidates.add(
        _VerifiedMedia(
          url: url,
          thumbnailUrl: thumbnail.isEmpty ? null : thumbnail,
          format: type.startsWith('video/mp4') ? 'MP4' : 'WebM',
          quality: _qualityLabel(width, height),
          license: license,
          size: null,
          duration: duration,
          height: height,
          derivative: true,
        ),
      );
    }
  }
  if (mime == 'video/webm' || mime == 'video/mp4') {
    final url = _safeMediaUrl(info['url']);
    if (url != null) {
      final width = _intValue(info['width']);
      final height = _intValue(info['height']);
      candidates.add(
        _VerifiedMedia(
          url: url,
          thumbnailUrl: thumbnail.isEmpty ? null : thumbnail,
          format: mime == 'video/mp4' ? 'MP4' : 'WebM',
          quality: '${_qualityLabel(width, height)} 原画',
          license: license,
          size: _intValue(info['size']),
          duration: duration,
          height: height,
          derivative: false,
        ),
      );
    }
  }
  final unique = <String, _VerifiedMedia>{};
  for (final candidate in candidates) {
    unique.putIfAbsent(candidate.url, () => candidate);
  }
  final result = unique.values.toList(growable: false)
    ..sort((a, b) {
      final derivativeOrder = (a.derivative ? 0 : 1).compareTo(
        b.derivative ? 0 : 1,
      );
      if (derivativeOrder != 0) return derivativeOrder;
      return _heightPreference(a.height).compareTo(_heightPreference(b.height));
    });
  return result;
}

String? _safeMediaUrl(Object? value) {
  final uri = Uri.tryParse(value?.toString().trim() ?? '');
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host != 'upload.wikimedia.org' ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri.toString();
}

String _qualityLabel(int? width, int? height) {
  if (height != null && height > 0) return '${height}p';
  if (width != null && width > 0) return '${width}px';
  return '原画';
}

int _heightPreference(int? height) {
  if (height == 720) return 0;
  if (height == 1080) return 1;
  if (height == 480) return 2;
  if (height == 360) return 3;
  if (height == 240) return 4;
  if (height == null || height <= 0) return 10000;
  if (height < 720) return 100 + (720 - height);
  return 1000 + (height - 720);
}

bool _isAllowedLicense(String value) {
  final normalized = value.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
  if (normalized.isEmpty) return false;
  if (normalized.contains('public domain') || normalized.contains('cc0')) {
    return true;
  }
  if (normalized.contains('-nc') ||
      normalized.contains('-nd') ||
      normalized.contains('noncommercial') ||
      normalized.contains('no derivatives')) {
    return false;
  }
  return normalized == 'cc by' ||
      normalized.startsWith('cc by ') ||
      normalized == 'cc by-sa' ||
      normalized.startsWith('cc by-sa ');
}

String _licenseLabelZh(String value) {
  final lower = value.toLowerCase();
  if (lower.contains('public domain')) return '公共领域';
  if (lower.contains('cc0')) return 'CC0';
  if (lower.contains('by-sa')) return 'CC BY-SA';
  if (lower.contains('cc by')) return 'CC BY';
  return value.trim().isEmpty ? '开放许可' : value.trim();
}

String _displayTitle(String originalTitle, String kind) {
  if (RegExp(r'[\u3400-\u9fff]').hasMatch(originalTitle)) return originalTitle;
  return '$kind · $originalTitle';
}

String _cleanFileTitle(String value) {
  return value
      .replaceFirst(RegExp(r'^File:', caseSensitive: false), '')
      .replaceFirst(RegExp(r'\.(webm|mp4|ogg|ogv)$', caseSensitive: false), '')
      .replaceAll('_', ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

String _plainText(String value) {
  return value
      .replaceAll(RegExp(r'<[^>]*>'), ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

String _durationLabel(double? seconds) {
  if (seconds == null || seconds <= 0) return '';
  final totalMinutes = (seconds / 60).round();
  if (totalMinutes < 60) return '$totalMinutes 分钟';
  final hours = totalMinutes ~/ 60;
  final minutes = totalMinutes % 60;
  return minutes == 0 ? '$hours 小时' : '$hours 小时 $minutes 分钟';
}

String? _sizeLabel(int? bytes) {
  if (bytes == null || bytes <= 0) return null;
  final megabytes = bytes / 1024 / 1024;
  if (megabytes >= 1024) {
    return '${(megabytes / 1024).toStringAsFixed(1)} GB';
  }
  return '${megabytes.toStringAsFixed(1)} MB';
}

int? _pageIdFromSource(String value) {
  if (!value.startsWith(_commonsSourcePrefix)) return null;
  return int.tryParse(value.substring(_commonsSourcePrefix.length));
}

List<AnimeSubject> _interleave(List<List<AnimeSubject>> groups) {
  final result = <AnimeSubject>[];
  final seen = <int>{};
  var index = 0;
  var added = true;
  while (added) {
    added = false;
    for (final group in groups) {
      if (index >= group.length) continue;
      final subject = group[index];
      if (seen.add(subject.id)) result.add(subject);
      added = true;
    }
    index++;
  }
  return result;
}

int? _intValue(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  return int.tryParse(value?.toString() ?? '');
}

double? _doubleValue(Object? value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '');
}

int _stableId(String value) {
  var hash = 0x811c9dc5;
  for (final codeUnit in value.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash & 0x7fffffff;
}

class _CommonsGroup {
  const _CommonsGroup({required this.query, required this.label});

  final String query;
  final String label;
}

class _VerifiedMedia {
  const _VerifiedMedia({
    required this.url,
    required this.thumbnailUrl,
    required this.format,
    required this.quality,
    required this.license,
    required this.size,
    required this.duration,
    required this.height,
    required this.derivative,
  });

  final String url;
  final String? thumbnailUrl;
  final String format;
  final String quality;
  final String license;
  final int? size;
  final double? duration;
  final int? height;
  final bool derivative;
}
