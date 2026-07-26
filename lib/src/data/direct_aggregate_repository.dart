// 内置聚合仓库 - 无需后端服务器
//
// 直接在客户端聚合多个免费 API，实现搜索和视频源获取：
//   - AniCh API (动漫) - protobuf 协议
//   - TVMaze API (美剧/英剧) - 免费 JSON API
//   - TVBox 社区源 (国产剧/电影) - JSON API
//   - M3U8 CDN 直链解析
//
// 所有网络请求直接从 Flutter 客户端发出，不依赖任何后端服务器。

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../domain/anime_models.dart';
import '../rules/rule_playback_resolver.dart';
import 'playback_source_repository.dart';

// ============================================================
// AniCh Protobuf 客户端 (Dart 原生，无后端依赖)
// ============================================================

/// 轻量 Protobuf 解析器，处理 AniCh API 的二进制响应
class _ProtoReader {
  final Uint8List _data;
  int _pos = 0;

  _ProtoReader(this._data);

  int? _readVarint() {
    int result = 0, shift = 0;
    while (_pos < _data.length) {
      final byte = _data[_pos++];
      result |= (byte & 0x7F) << shift;
      if ((byte & 0x80) == 0) return result;
      shift += 7;
    }
    return null;
  }

  (int, int)? readField() {
    final tagWire = _readVarint();
    if (tagWire == null) return null;
    return (tagWire >> 3, tagWire & 0x07);
  }

  int? readVarintField() => _readVarint();

  String? readStringField() {
    final len = _readVarint();
    if (len == null || _pos + len > _data.length) return null;
    final str = utf8.decode(
      _data.sublist(_pos, _pos + len),
      allowMalformed: true,
    );
    _pos += len;
    return str;
  }

  Uint8List? readBytesField() {
    final len = _readVarint();
    if (len == null || _pos + len > _data.length) return null;
    final bytes = _data.sublist(_pos, _pos + len);
    _pos += len;
    return bytes;
  }

  double? readDoubleField() {
    if (_pos + 8 > _data.length) return null;
    final view = ByteData.sublistView(_data, _pos, _pos + 8);
    _pos += 8;
    return view.getFloat64(0, Endian.little);
  }

  void skipField(int wireType) {
    switch (wireType) {
      case 0:
        _readVarint();
        break;
      case 1:
        _pos += 8;
        break;
      case 2:
        final len = _readVarint();
        if (len != null) _pos += len;
        break;
      case 5:
        _pos += 4;
        break;
      default:
        break;
    }
  }
}

/// AniCh 视频 URL 解码
String _decodeAnichUrl(String encoded) {
  try {
    // 跳过第4个字符 (位置3的垃圾字符)
    if (encoded.length <= 4) return '';
    final cleaned = encoded.substring(0, 3) + encoded.substring(4);
    // 标准化 base64
    var b64 = cleaned.replaceAll('-', '+').replaceAll('_', '/');
    while (b64.length % 4 != 0) {
      b64 += '=';
    }
    final decoded = utf8.decode(base64.decode(b64), allowMalformed: true);
    return decoded;
  } catch (_) {
    return '';
  }
}

/// 解析 AniCh vod_ 响应
List<Map<String, dynamic>> _parseAnichVod(List<int>? bytes) {
  if (bytes == null || bytes.isEmpty) return [];
  // 处理 JSON 整数数组格式
  Uint8List data;
  try {
    final str = utf8.decode(Uint8List.fromList(bytes), allowMalformed: true);
    if (str.startsWith('[')) {
      final list = (jsonDecode(str) as List).cast<int>();
      data = Uint8List.fromList(list);
    } else {
      data = Uint8List.fromList(bytes);
    }
  } catch (_) {
    data = Uint8List.fromList(bytes);
  }

  final reader = _ProtoReader(data);
  final items = <Map<String, dynamic>>[];

  while (reader._pos < data.length) {
    final field = reader.readField();
    if (field == null) break;
    final (fn, wt) = field;

    if (fn == 1 && wt == 2) {
      // repeated vod_item_ data
      final itemBytes = reader.readBytesField();
      if (itemBytes != null) {
        final item = _parseAnichVodItem(itemBytes);
        if (item.isNotEmpty) items.add(item);
      }
    } else {
      reader.skipField(wt);
    }
  }
  return items;
}

Map<String, dynamic> _parseAnichVodItem(Uint8List data) {
  final item = <String, dynamic>{};
  final reader = _ProtoReader(data);
  while (reader._pos < data.length) {
    final field = reader.readField();
    if (field == null) break;
    final (fn, wt) = field;
    switch (fn) {
      case 1:
        item['url'] = reader.readStringField() ?? '';
        break;
      case 2:
        item['sort'] = reader.readVarintField() ?? 0;
        break;
      case 3:
        item['type'] = reader.readStringField() ?? '';
        break;
      case 4:
        item['caption'] = reader.readStringField() ?? '';
        break;
      default:
        reader.skipField(wt);
    }
  }
  return item;
}

/// 解析 AniCh bangumi_list_ 响应
List<Map<String, dynamic>> _parseAnichBangumiList(List<int> bytes) {
  final data = Uint8List.fromList(bytes);
  final reader = _ProtoReader(data);
  final items = <Map<String, dynamic>>[];

  while (reader._pos < data.length) {
    final field = reader.readField();
    if (field == null) break;
    final (fn, wt) = field;

    if (fn == 1 && wt == 2) {
      final itemBytes = reader.readBytesField();
      if (itemBytes != null) {
        items.add(_parseAnichListItem(itemBytes));
      }
    } else {
      reader.skipField(wt);
    }
  }
  return items;
}

Map<String, dynamic> _parseAnichListItem(Uint8List data) {
  final item = <String, dynamic>{};
  final reader = _ProtoReader(data);
  while (reader._pos < data.length) {
    final field = reader.readField();
    if (field == null) break;
    final (fn, wt) = field;
    switch (fn) {
      case 1:
        item['id'] = reader.readVarintField() ?? 0;
        break;
      case 2:
        item['title'] = reader.readStringField() ?? '';
        break;
      case 3:
        item['episode'] = reader.readVarintField() ?? 0;
        break;
      case 4:
        item['episodes_total'] = reader.readVarintField() ?? 0;
        break;
      case 5:
        item['status'] = reader.readStringField() ?? '';
        break;
      case 6:
        item['date'] = reader.readDoubleField();
        break;
      case 7:
        item['image'] = reader.readStringField() ?? '';
        break;
      case 8:
        item['tagline'] = reader.readStringField() ?? '';
        break;
      default:
        reader.skipField(wt);
    }
  }
  return item;
}

/// 解析 AniCh bangumi_episodes_ 响应
List<Map<String, dynamic>> _parseAnichEpisodes(List<int> bytes) {
  final data = Uint8List.fromList(bytes);
  final reader = _ProtoReader(data);
  final items = <Map<String, dynamic>>[];

  while (reader._pos < data.length) {
    final field = reader.readField();
    if (field == null) break;
    final (fn, wt) = field;

    if (fn == 1 && wt == 2) {
      final epBytes = reader.readBytesField();
      if (epBytes != null) {
        items.add(_parseAnichEpisode(epBytes));
      }
    } else {
      reader.skipField(wt);
    }
  }
  return items;
}

Map<String, dynamic> _parseAnichEpisode(Uint8List data) {
  final ep = <String, dynamic>{};
  final reader = _ProtoReader(data);
  while (reader._pos < data.length) {
    final field = reader.readField();
    if (field == null) break;
    final (fn, wt) = field;
    switch (fn) {
      case 1:
        ep['status'] = (reader.readVarintField() ?? 0) != 0;
        break;
      case 2:
        ep['sort'] = reader.readVarintField() ?? 0;
        break;
      case 3:
        ep['airdate'] = reader.readDoubleField();
        break;
      case 4:
        ep['duration'] = reader.readVarintField() ?? 0;
        break;
      case 7:
        ep['image'] = reader.readStringField() ?? '';
        break;
      case 8:
        ep['title'] = reader.readStringField() ?? '';
        break;
      case 9:
        ep['overview'] = reader.readStringField() ?? '';
        break;
      default:
        reader.skipField(wt);
    }
  }
  return ep;
}

// ============================================================
// AniCh API 客户端
// ============================================================

class _AnichApiClient {
  static const _baseUrl = 'https://anich.sends.eu.org';
  final http.Client _http;

  _AnichApiClient(this._http);

  Future<http.Response> _get(String path, [Map<String, String>? params]) {
    final uri = Uri.parse('$_baseUrl$path').replace(queryParameters: params);
    return _http.get(
      uri,
      headers: {'User-Agent': 'com.anich.app windows 1.4.2', 'Accept': '*/*'},
    );
  }

  Future<List<Map<String, dynamic>>> search(String keyword) async {
    try {
      final resp = await _get('/bangumi/search', {'keyword': keyword});
      if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) return [];
      // Handle JSON integer array format
      if (resp.bodyBytes.first == 0x5B) {
        final list = (jsonDecode(resp.body) as List).cast<int>();
        return _parseAnichBangumiList(list);
      }
      return _parseAnichBangumiList(resp.bodyBytes);
    } catch (_) {
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> getEpisodes(int bangumiId) async {
    try {
      final resp = await _get('/bangumi/episodes/$bangumiId');
      if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) return [];
      if (resp.bodyBytes.first == 0x5B) {
        final list = (jsonDecode(resp.body) as List).cast<int>();
        return _parseAnichEpisodes(list);
      }
      return _parseAnichEpisodes(resp.bodyBytes);
    } catch (_) {
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> getVod(int bangumiId, int episode) async {
    try {
      final resp = await _get('/vod/$bangumiId/$episode');
      if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) return [];
      return _parseAnichVod(resp.bodyBytes);
    } catch (_) {
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> getDanmaku(
    int bangumiId,
    int episode,
  ) async {
    try {
      final resp = await _get('/danmaku', {
        'bangumi': '$bangumiId',
        'episode': '$episode',
      });
      if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) return [];
      // Protobuf parsing for danmaku - simplified
      return _parseAnichVod(resp.bodyBytes); // reuse proto parser
    } catch (_) {
      return [];
    }
  }
}

// ============================================================
// TVMaze 客户端 (免费，无需 Key)
// ============================================================

class _TvmazeClient {
  static const _baseUrl = 'https://api.tvmaze.com';
  final http.Client _http;

  _TvmazeClient(this._http);

  Future<List<Map<String, dynamic>>> search(String keyword) async {
    try {
      final resp = await _http.get(
        Uri.parse('$_baseUrl/search/shows?q=${Uri.encodeComponent(keyword)}'),
        headers: {'Accept': 'application/json'},
      );
      if (resp.statusCode != 200) return [];
      final data = jsonDecode(resp.body) as List;
      return data.map((item) {
        final show = item['show'] as Map<String, dynamic>;
        final rating = show['rating'] as Map<String, dynamic>?;
        final image = show['image'] as Map<String, dynamic>?;
        return {
          'id': 'tvmaze_${show['id']}',
          'title': show['name'] ?? '',
          'summary': (show['summary'] ?? '').toString().replaceAll(
            RegExp(r'<[^>]+>'),
            '',
          ),
          'image': image?['original'] ?? image?['medium'] ?? '',
          'language': show['language'] ?? 'en',
          'year':
              int.tryParse(
                (show['premiered'] ?? '2024').toString().substring(0, 4),
              ) ??
              2024,
          'rating': (rating?['average'] as num?)?.toDouble() ?? 0.0,
          'genres': (show['genres'] as List?)?.cast<String>() ?? [],
          'type': 'tv',
          'source': 'tvmaze',
        };
      }).toList();
    } catch (_) {
      return [];
    }
  }

  Future<Map<String, dynamic>?> getShow(int showId) async {
    try {
      final resp = await _http.get(
        Uri.parse('$_baseUrl/shows/$showId?embed[]=episodes'),
        headers: {'Accept': 'application/json'},
      );
      if (resp.statusCode != 200) return null;
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final episodes = (data['_embedded']?['episodes'] as List?) ?? [];
      final image = data['image'] as Map<String, dynamic>?;
      final rating = data['rating'] as Map<String, dynamic>?;
      return {
        ...data,
        'image_url': image?['original'] ?? image?['medium'] ?? '',
        'rating_value': (rating?['average'] as num?)?.toDouble() ?? 0.0,
        'episodes': episodes
            .map(
              (ep) => {
                'number': ep['number'] ?? 0,
                'title': ep['name'] ?? '',
                'season': ep['season'] ?? 1,
              },
            )
            .toList(),
      };
    } catch (_) {
      return null;
    }
  }
}

// ============================================================
// TVBox 社区源客户端
// ============================================================

class _TvboxClient {
  static const _apis = [
    'https://cj.lziapi.com/api.php/provide/vod', // 量子
    'https://bfzyapi.com/api.php/provide/vod', // 暴风
  ];
  final http.Client _http;

  _TvboxClient(this._http);

  Future<List<Map<String, dynamic>>> search(String keyword) async {
    final results = <Map<String, dynamic>>[];
    final seen = <String>{};

    for (final base in _apis) {
      try {
        final resp = await _http.get(
          Uri.parse(
            base,
          ).replace(queryParameters: {'ac': 'detail', 'wd': keyword}),
          headers: {
            'User-Agent': 'okhttp/4.12.0',
            'Accept': 'application/json',
          },
        );
        if (resp.statusCode != 200) continue;
        final data = jsonDecode(resp.body);
        final items = (data is Map ? data['list'] : data) as List?;
        if (items == null) continue;

        for (final item in items.cast<Map<String, dynamic>>()) {
          final title = item['vod_name']?.toString() ?? '';
          if (title.isEmpty || seen.contains(title)) continue;
          seen.add(title);
          final typeName = item['type_name']?.toString() ?? '';
          results.add({
            'id': 'tvbox:${Uri.encodeComponent(base)}:${item['vod_id']}',
            'title': title,
            'image': item['vod_pic']?.toString() ?? '',
            'summary': _truncate(item['vod_content']?.toString() ?? '', 500),
            'type': typeName.contains('电影') ? 'movie' : 'tv',
            'year': int.tryParse(item['vod_year']?.toString() ?? '0') ?? 2024,
            'source': 'tvbox',
            '_api_base': base,
            '_vod_id': item['vod_id']?.toString() ?? '',
          });
        }
      } catch (_) {}
    }
    return results;
  }

  Future<List<Map<String, dynamic>>> getVideoUrls(
    String apiBase,
    String vodId,
    int episode,
  ) async {
    final lines = <Map<String, dynamic>>[];
    try {
      final resp = await _http.get(
        Uri.parse(
          apiBase,
        ).replace(queryParameters: {'ac': 'videolist', 'ids': vodId}),
        headers: {'User-Agent': 'okhttp/4.12.0', 'Accept': 'application/json'},
      );
      if (resp.statusCode != 200) return lines;

      final data = jsonDecode(resp.body);
      final items = (data is Map ? data['list'] : data) as List?;
      if (items == null || items.isEmpty) return lines;

      final item = items.first as Map<String, dynamic>;
      final playUrl = item['vod_play_url']?.toString() ?? '';

      if (playUrl.isEmpty) return lines;

      for (final group in playUrl.split(r'$$$')) {
        for (final epStr in group.split('#')) {
          final sep = epStr.indexOf(r'$');
          if (sep <= 0) continue;
          final epTitle = epStr.substring(0, sep).trim();
          final epUrl = epStr.substring(sep + 1).trim();
          if (epUrl.isEmpty) continue;

          final numMatch = RegExp(r'(\d+)').firstMatch(epTitle);
          final epNum = numMatch != null ? int.parse(numMatch.group(1)!) : 0;

          if (epNum == episode || lines.isEmpty) {
            lines.add({
              'url': epUrl,
              'title': epTitle,
              'format': epUrl.contains('m3u8') ? 'hls' : 'mp4',
              'source': 'tvbox',
            });
          }
        }
      }
    } catch (_) {}
    return lines;
  }
}

// ============================================================
// M3U8 直链提取器
// ============================================================

class _M3u8Extractor {
  /// 从文本中提取已知 CDN 的 m3u8/mp4 URL
  List<Map<String, dynamic>> extractFromText(String text) {
    final urls = <Map<String, dynamic>>[];
    final seen = <String>{};

    final patterns = [
      RegExp(
        r'(https?://v\d+\.adkwai\.com/\S+\.(?:m3u8|mp4)\S*)',
        caseSensitive: false,
      ),
      RegExp(r'(https?://v-cdn\.emmmm\.eu\.org/video/\S+)'),
      RegExp(r'(https?://vo-cdn\.emmmm\.eu\.org/video/\S+)'),
      RegExp(r'(https?://m3u8\d+\.yhdmm3u8\.top/\S+\.m3u8\S*)'),
      RegExp(r'(https?://apn\.moedot\.net/\S+\.(?:mp4|m3u8)\S*)'),
      RegExp(r'(https?://play\.xfvod\.pro\S+\.(?:mp4|m3u8)\S*)'),
      RegExp(
        r'(https?://v\.cdnlz\d+\.com/\S+\.(?:mp4|m3u8)\S*)',
        caseSensitive: false,
      ),
      RegExp(r'(https?://c\d+\.ddbbffcdn\.com/\S+\.m3u8\S*)'),
      RegExp(r'(https?://\S+\.m3u8\S*)', caseSensitive: false),
      RegExp(r'(https?://\S+\.mp4\S*)', caseSensitive: false),
    ];

    for (final pattern in patterns) {
      for (final match in pattern.allMatches(text)) {
        var url = match.group(1)!;
        url = url.replaceAll(r'\/', '/');
        // Clean trailing punctuation from URL
        url = _cleanUrl(url);
        if (seen.contains(url)) continue;
        seen.add(url);
        urls.add({
          'url': url,
          'format': url.contains('m3u8') ? 'hls' : 'mp4',
          'source': 'm3u8_direct',
        });
      }
    }
    return urls;
  }
}

// ============================================================
// 统一聚合仓库 (核心)
// ============================================================

class DirectAggregateRepository implements PlaybackSourceRepository {
  factory DirectAggregateRepository({
    http.Client? client,
    RulePlaybackResolver? verifier,
  }) {
    final httpClient = client ?? http.Client();
    return DirectAggregateRepository._(
      httpClient,
      verifier ?? RulePlaybackResolver(client: httpClient),
    );
  }

  DirectAggregateRepository._(this._http, this._verifier)
    : _anich = _AnichApiClient(_http),
      _tvmaze = _TvmazeClient(_http),
      _tvbox = _TvboxClient(_http),
      _m3u8 = _M3u8Extractor();

  final http.Client _http;
  final RulePlaybackResolver _verifier;
  final _AnichApiClient _anich;
  final _TvmazeClient _tvmaze;
  final _TvboxClient _tvbox;
  final _M3u8Extractor _m3u8;

  /// 从网页或接口文本中提取可直接播放的 HLS/MP4 地址。
  List<Map<String, dynamic>> extractDirectVideoUrls(String text) =>
      _m3u8.extractFromText(text);

  /// 统一搜索 - 从所有内置源并发搜索
  Future<List<Map<String, dynamic>>> search(
    String keyword, {
    List<String>? contentTypes,
  }) async {
    contentTypes ??= ['anime', 'tv', 'movie'];
    final results = <Map<String, dynamic>>[];
    final seen = <String>{};

    final futures = <Future<List<Map<String, dynamic>>>>[];

    if (contentTypes.contains('anime')) {
      futures.add(_anich.search(keyword));
    }
    if (contentTypes.any((t) => ['tv', 'movie'].contains(t))) {
      futures.add(_tvbox.search(keyword));
      futures.add(_tvmaze.search(keyword));
    }

    final allResults = await Future.wait(futures);
    for (final batch in allResults) {
      for (final item in batch) {
        final title = item['title']?.toString() ?? '';
        if (title.isEmpty || seen.contains(title.toLowerCase())) continue;
        seen.add(title.toLowerCase());
        results.add(item);
      }
    }
    return results;
  }

  /// 获取剧集
  Future<List<Map<String, dynamic>>> getEpisodes(
    String sourceId,
    int bangumiId,
  ) async {
    if (sourceId == 'anich') {
      final eps = await _anich.getEpisodes(bangumiId);
      return eps
          .map(
            (e) => {
              'number': e['sort'] ?? 0,
              'title': e['title'] ?? '',
              'airdate': e['airdate'],
            },
          )
          .toList();
    }
    if (sourceId == 'tvmaze') {
      final showId = bangumiId;
      final show = await _tvmaze.getShow(showId);
      if (show == null) return [];
      final eps = show['episodes'] as List? ?? [];
      return eps
          .map(
            (e) => {
              'number': e['number'] ?? 0,
              'title': e['title'] ?? '',
              'season': e['season'] ?? 1,
            },
          )
          .toList();
    }
    return [];
  }

  /// 获取视频线路 (核心)
  Future<List<Map<String, dynamic>>> getVideoLines(
    String sourceId,
    int subjectId,
    int episode,
  ) async {
    final lines = <Map<String, dynamic>>[];

    switch (sourceId) {
      case 'anich':
        final vodItems = await _anich.getVod(subjectId, episode);
        for (final item in vodItems) {
          final encodedUrl = item['url']?.toString() ?? '';
          final decodedUrl = _decodeAnichUrl(encodedUrl);
          if (decodedUrl.isNotEmpty) {
            lines.add({
              'url': decodedUrl,
              'title': item['caption']?.toString() ?? '',
              'format': item['type']?.toString() ?? 'auto',
              'source': 'anich',
            });
          }
        }
        break;

      case 'tvbox':
        // 从搜索结果中获取 api_base 和 vod_id
        // 这里简化处理，实际需要存储完整引用
        break;

      case 'tvmaze':
        // TVMaze 只有元数据没有视频，尝试 M3U8 fallback
        break;
    }
    return lines;
  }

  /// PlaybackSourceRepository 接口实现
  @override
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

  @override
  Future<List<PlaybackLine>> linesForEpisodeMode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    bool expandAll = false,
    RulePlaybackCancellationToken? cancellationToken,
  }) async {
    if (cancellationToken?.isCancelled ?? false) return [];

    final lines = <PlaybackLine>[];

    // 根据 source 字段决定用哪个 API
    if (subject.source == 'anich' || subject.source == 'bangumi') {
      try {
        final vodItems = await _anich.getVod(subject.id, episode.number);
        for (var i = 0; i < vodItems.length; i++) {
          final item = vodItems[i];
          final encodedUrl = item['url']?.toString() ?? '';
          final decodedUrl = _decodeAnichUrl(encodedUrl);
          if (decodedUrl.isNotEmpty) {
            lines.add(
              PlaybackLine(
                id: 'anich:${subject.id}:${episode.id}:$i',
                episodeId: episode.id,
                providerId: 'anich_builtin',
                providerName: 'AniCh 动漫源',
                title: item['caption']?.toString() ?? '线路${i + 1}',
                quality: 'HD',
                format: item['type']?.toString() ?? 'auto',
                url: decodedUrl,
                available: true,
                message: 'AniCh 内置聚合 (无需后端)',
              ),
            );
          }
        }
      } catch (_) {}
    }

    // 对源ID中包含 tvbox 的内容
    if (subject.source.startsWith('tvbox:')) {
      final parts = subject.source.split(':');
      if (parts.length >= 3) {
        try {
          final apiBase = 'https://${parts[1]}.com/api.php/provide/vod';
          final vodId = parts[2];
          final vodLines = await _tvbox.getVideoUrls(
            apiBase,
            vodId,
            episode.number,
          );
          for (var i = 0; i < vodLines.length; i++) {
            final l = vodLines[i];
            lines.add(
              PlaybackLine(
                id: 'tvbox:${subject.id}:${episode.id}:$i',
                episodeId: episode.id,
                providerId: 'tvbox_builtin',
                providerName: 'TVBox 社区源',
                title: l['title']?.toString() ?? '线路${i + 1}',
                quality: 'HD',
                format: l['format']?.toString() ?? 'auto',
                url: l['url']?.toString() ?? '',
                available: true,
                message: 'TVBox 内置聚合 (无需后端)',
              ),
            );
          }
        } catch (_) {}
      }
    }

    if (lines.isEmpty) {
      lines.add(
        PlaybackLine(
          id: 'builtin:${subject.id}:${episode.id}:unavailable',
          episodeId: episode.id,
          providerId: 'builtin',
          providerName: '内置聚合',
          title: '暂无内置源',
          quality: '--',
          format: '--',
          available: false,
          message: '当前内容类型未匹配到内置源。请尝试添加社区 TVBox 规则。',
        ),
      );
    }
    if (lines.every((line) => line.url?.trim().isEmpty ?? true)) return lines;
    return Future.wait([
      for (final line in lines)
        if (line.url?.trim().isNotEmpty ?? false)
          _verifier.verifyPlaybackLine(
            line: line,
            enrichMetadata: expandAll,
            cancellationToken: cancellationToken,
          )
        else
          Future<PlaybackLine>.value(line),
    ]);
  }

  @override
  Stream<PlaybackLineLookupUpdate> lineUpdatesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    RulePlaybackCancellationToken? cancellationToken,
  }) async* {
    final lines = await linesForEpisodeMode(
      subject,
      episode,
      expandAll: true,
      cancellationToken: cancellationToken,
    );
    if (cancellationToken?.isCancelled ?? false) return;
    yield PlaybackLineLookupUpdate(
      lines: lines,
      completedRules: 1,
      totalRules: 1,
      phase: PlaybackLineLookupPhase.complete,
    );
  }

  void dispose() {
    _http.close();
  }
}

String _truncate(String s, int maxLen) =>
    s.length <= maxLen ? s : s.substring(0, maxLen);

String _cleanUrl(String url) {
  // Remove trailing punctuation from URLs extracted from text
  const trailingChars = '),.;]}"\'';
  while (url.isNotEmpty && trailingChars.contains(url[url.length - 1])) {
    url = url.substring(0, url.length - 1);
  }
  return url;
}
