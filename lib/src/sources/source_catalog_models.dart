enum VideoSourceKind {
  tvBox('TVBox 配置'),
  liveM3u('M3U 直播'),
  torrent('BT/磁力'),
  publicMedia('公开媒体'),
  unknown('未知类型');

  const VideoSourceKind(this.label);

  final String label;

  factory VideoSourceKind.fromJson(Object? value) {
    return switch (value?.toString()) {
      'tvBox' => VideoSourceKind.tvBox,
      'liveM3u' => VideoSourceKind.liveM3u,
      'publicMedia' => VideoSourceKind.publicMedia,
      'torrent' || 'magnet' || 'bt' => VideoSourceKind.torrent,
      _ => VideoSourceKind.unknown,
    };
  }
}

class SourceCatalogState {
  const SourceCatalogState({
    this.version = 0,
    this.generatedAt,
    this.totalSources = 0,
    this.sources = const [],
    this.playbackRuleCounts = const {},
    this.availablePlaybackRuleCount = 0,
    this.activePlaybackRuleCount = 0,
    this.loadError,
  });

  final int version;
  final DateTime? generatedAt;
  final int totalSources;
  final List<VideoSource> sources;
  final Map<String, int> playbackRuleCounts;
  final int availablePlaybackRuleCount;
  final int activePlaybackRuleCount;
  final String? loadError;

  int get importedCount => sources.length;

  int get enabledCount => sources.where((source) => source.enabled).length;

  int get disabledCount => importedCount - enabledCount;

  int get searchableCount =>
      sources.where((source) => source.supportsSearch).length;

  int get liveCount =>
      sources.where((source) => source.kind == VideoSourceKind.liveM3u).length;

  int get torrentCount =>
      sources.where((source) => source.kind == VideoSourceKind.torrent).length;

  int get playbackConnectedCount => sources
      .where(
        (source) => source.enabled && (playbackRuleCounts[source.id] ?? 0) > 0,
      )
      .length;

  int playbackRuleCountFor(String sourceId) =>
      playbackRuleCounts[sourceId] ?? 0;

  bool get hasError => loadError != null;

  Map<String, bool> get enabledById => {
    for (final source in sources) source.id: source.enabled,
  };

  SourceCatalogState copyWith({
    int? version,
    DateTime? generatedAt,
    int? totalSources,
    List<VideoSource>? sources,
    Map<String, int>? playbackRuleCounts,
    int? availablePlaybackRuleCount,
    int? activePlaybackRuleCount,
    String? loadError,
  }) {
    return SourceCatalogState(
      version: version ?? this.version,
      generatedAt: generatedAt ?? this.generatedAt,
      totalSources: totalSources ?? this.totalSources,
      sources: sources ?? this.sources,
      playbackRuleCounts: playbackRuleCounts ?? this.playbackRuleCounts,
      availablePlaybackRuleCount:
          availablePlaybackRuleCount ?? this.availablePlaybackRuleCount,
      activePlaybackRuleCount:
          activePlaybackRuleCount ?? this.activePlaybackRuleCount,
      loadError: loadError,
    );
  }

  SourceCatalogState applyEnabledOverrides(Map<String, bool> overrides) {
    if (overrides.isEmpty) return this;
    return copyWith(
      sources: [
        for (final source in sources)
          source.copyWith(enabled: overrides[source.id] ?? source.enabled),
      ],
      loadError: loadError,
    );
  }

  SourceCatalogState toggleSource(String id, bool enabled) {
    return copyWith(
      sources: [
        for (final source in sources)
          source.id == id ? source.copyWith(enabled: enabled) : source,
      ],
      loadError: loadError,
    );
  }

  VideoSource? sourceById(String id) {
    for (final source in sources) {
      if (source.id == id) return source;
    }
    return null;
  }

  factory SourceCatalogState.fromJson(
    Map<String, dynamic> json, {
    Map<String, bool> enabledOverrides = const {},
  }) {
    final sourcesValue = json['sources'];
    final sources = sourcesValue is List
        ? sourcesValue
              .whereType<Map>()
              .map((item) => VideoSource.fromJson(item.cast<String, dynamic>()))
              .where((source) => source.id.trim().isNotEmpty)
              .toList(growable: false)
        : const <VideoSource>[];
    return SourceCatalogState(
      version: _intFromJson(json['version']),
      generatedAt: _dateFromJson(json['generatedAt']),
      totalSources: _intFromJson(
        json['totalSources'],
        fallback: sources.length,
      ),
      sources: sources,
    ).applyEnabledOverrides(enabledOverrides);
  }

  factory SourceCatalogState.failed(Object error) {
    return SourceCatalogState(loadError: error.toString());
  }
}

class VideoSource {
  const VideoSource({
    required this.id,
    required this.name,
    required this.kind,
    required this.importUrl,
    required this.baseUrl,
    this.tags = const [],
    this.endpoints = const {},
    this.headers = const {},
    this.rawConfig = const {},
    this.version,
    this.license,
    this.author,
    this.supportsDanmaku = false,
    this.supportsSearch = false,
    this.supportsCategories = false,
    this.usesNativePlayer = false,
    this.antiCrawlerEnabled = false,
    this.executableUnsupported = false,
    this.enabled = true,
    this.health = 'unknown',
    this.message = '',
  });

  final String id;
  final String name;
  final VideoSourceKind kind;
  final String importUrl;
  final String baseUrl;
  final List<String> tags;
  final Map<String, String> endpoints;
  final Map<String, String> headers;
  final Map<String, dynamic> rawConfig;
  final String? version;
  final String? license;
  final String? author;
  final bool supportsDanmaku;
  final bool supportsSearch;
  final bool supportsCategories;
  final bool usesNativePlayer;
  final bool antiCrawlerEnabled;
  final bool executableUnsupported;
  final bool enabled;
  final String health;
  final String message;

  String get displayName => name.trim().isEmpty ? id : name.trim();

  String get healthLabel {
    if (executableUnsupported) return '当前不支持';
    if (antiCrawlerEnabled) return '需验证';
    return switch (health.trim().toLowerCase()) {
      'ok' || 'healthy' || 'pass' || 'available' => '正常',
      'warning' || 'degraded' || 'limited' => '注意',
      'error' || 'failed' || 'unhealthy' || 'offline' => '异常',
      _ => '未检测',
    };
  }

  String get endpointText {
    final text = baseUrl.trim().isNotEmpty ? baseUrl.trim() : importUrl.trim();
    return text.isEmpty ? '未提供地址' : text;
  }

  VideoSource copyWith({bool? enabled}) {
    return VideoSource(
      id: id,
      name: name,
      kind: kind,
      importUrl: importUrl,
      baseUrl: baseUrl,
      tags: tags,
      endpoints: endpoints,
      headers: headers,
      rawConfig: rawConfig,
      version: version,
      license: license,
      author: author,
      supportsDanmaku: supportsDanmaku,
      supportsSearch: supportsSearch,
      supportsCategories: supportsCategories,
      usesNativePlayer: usesNativePlayer,
      antiCrawlerEnabled: antiCrawlerEnabled,
      executableUnsupported: executableUnsupported,
      enabled: enabled ?? this.enabled,
      health: health,
      message: message,
    );
  }

  factory VideoSource.fromJson(Map<String, dynamic> json) {
    return VideoSource(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      kind: VideoSourceKind.fromJson(json['kind']),
      importUrl: json['importUrl']?.toString() ?? '',
      baseUrl: json['baseUrl']?.toString() ?? '',
      tags: _stringListFromJson(json['tags']),
      endpoints: _stringMapFromJson(json['endpoints']),
      headers: _stringMapFromJson(json['headers']),
      rawConfig: _dynamicMapFromJson(json['rawConfig']),
      version: _blankToNull(json['version']?.toString()),
      license: _blankToNull(json['license']?.toString()),
      author: _blankToNull(json['author']?.toString()),
      supportsDanmaku: _boolFromJson(json['supportsDanmaku']),
      supportsSearch: _boolFromJson(json['supportsSearch']),
      supportsCategories: _boolFromJson(json['supportsCategories']),
      usesNativePlayer: _boolFromJson(json['usesNativePlayer']),
      antiCrawlerEnabled: _boolFromJson(json['antiCrawlerEnabled']),
      executableUnsupported: _boolFromJson(json['executableUnsupported']),
      enabled: _boolFromJson(json['enabled'], fallback: true),
      health: json['health']?.toString() ?? 'unknown',
      message: json['message']?.toString() ?? '',
    );
  }
}

DateTime? _dateFromJson(Object? value) {
  final seconds = _intFromJson(value);
  if (seconds <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
}

int _intFromJson(Object? value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.round();
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

bool _boolFromJson(Object? value, {bool fallback = false}) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  final text = value?.toString().trim().toLowerCase();
  if (text == 'true' || text == '1' || text == 'yes') return true;
  if (text == 'false' || text == '0' || text == 'no') return false;
  return fallback;
}

String? _blankToNull(String? value) {
  final text = value?.trim();
  if (text == null || text.isEmpty) return null;
  return text;
}

List<String> _stringListFromJson(Object? value) {
  if (value is! List) return const [];
  return value
      .map((item) => item.toString().trim())
      .where((item) => item.isNotEmpty)
      .toList(growable: false);
}

Map<String, String> _stringMapFromJson(Object? value) {
  if (value is! Map) return const {};
  return {
    for (final entry in value.entries)
      if (entry.key.toString().trim().isNotEmpty)
        entry.key.toString(): entry.value?.toString() ?? '',
  };
}

Map<String, dynamic> _dynamicMapFromJson(Object? value) {
  if (value is! Map) return const {};
  return value.cast<String, dynamic>();
}
