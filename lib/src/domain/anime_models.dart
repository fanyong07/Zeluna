enum AnimeHomeTab {
  recent('最近更新'),
  recommended('推荐'),
  browse('索引'),
  category('分类'),
  tag('标签');

  const AnimeHomeTab(this.label);
  final String label;
}

class AnimeSubject {
  const AnimeSubject({
    required this.id,
    required this.title,
    required this.originalTitle,
    required this.summary,
    required this.coverUrl,
    required this.bannerUrl,
    required this.date,
    required this.platform,
    required this.language,
    required this.region,
    required this.status,
    required this.categories,
    required this.tags,
    required this.totalEpisodes,
    this.ratingScore,
    this.ratingRank,
    this.ratingTotal,
    this.source = 'bangumi',
  });

  final int id;
  final String title;
  final String originalTitle;
  final String summary;
  final String? coverUrl;
  final String? bannerUrl;
  final String? date;
  final String platform;
  final String language;
  final String region;
  final String status;
  final List<AnimeCategory> categories;
  final List<AnimeTag> tags;
  final int totalEpisodes;
  final double? ratingScore;
  final int? ratingRank;
  final int? ratingTotal;
  final String source;

  String get year {
    final value = date;
    if (value == null || value.length < 4) return '未知';
    return value.substring(0, 4);
  }

  String get subtitle {
    final tags = categories
        .map((item) => tmdbGenreLabel(item.name))
        .where((name) => name.isNotEmpty)
        .take(3)
        .toList(growable: false);
    final normalizedYear = year.trim();
    return [
      if (normalizedYear.isNotEmpty && normalizedYear != '未知') normalizedYear,
      ...tags,
    ].join('/');
  }

  AnimeSubject copyWith({
    String? summary,
    String? status,
    List<AnimeCategory>? categories,
    List<AnimeTag>? tags,
    int? totalEpisodes,
    String? source,
  }) {
    return AnimeSubject(
      id: id,
      title: title,
      originalTitle: originalTitle,
      summary: summary ?? this.summary,
      coverUrl: coverUrl,
      bannerUrl: bannerUrl,
      date: date,
      platform: platform,
      language: language,
      region: region,
      status: status ?? this.status,
      categories: categories ?? this.categories,
      tags: tags ?? this.tags,
      totalEpisodes: totalEpisodes ?? this.totalEpisodes,
      ratingScore: ratingScore,
      ratingRank: ratingRank,
      ratingTotal: ratingTotal,
      source: source ?? this.source,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'originalTitle': originalTitle,
    'summary': summary,
    'coverUrl': coverUrl,
    'bannerUrl': bannerUrl,
    'date': date,
    'platform': platform,
    'language': language,
    'region': region,
    'status': status,
    'categories': categories.map((item) => item.toJson()).toList(),
    'tags': tags.map((item) => item.toJson()).toList(),
    'totalEpisodes': totalEpisodes,
    'ratingScore': ratingScore,
    'ratingRank': ratingRank,
    'ratingTotal': ratingTotal,
    'source': source,
  };

  factory AnimeSubject.fromJson(Map<String, dynamic> json) {
    return AnimeSubject(
      id: _intFromJson(json['id']),
      title: json['title']?.toString() ?? '',
      originalTitle: json['originalTitle']?.toString() ?? '',
      summary: json['summary']?.toString() ?? '',
      coverUrl: _blankToNull(json['coverUrl']?.toString()),
      bannerUrl: _blankToNull(json['bannerUrl']?.toString()),
      date: _blankToNull(json['date']?.toString()),
      platform: json['platform']?.toString() ?? 'TV',
      language: json['language']?.toString() ?? '日语',
      region: json['region']?.toString() ?? '日本',
      status: json['status']?.toString() ?? '',
      categories: _listFromJson(json['categories'], AnimeCategory.fromJson),
      tags: _listFromJson(json['tags'], AnimeTag.fromJson),
      totalEpisodes: _intFromJson(json['totalEpisodes']),
      ratingScore: (json['ratingScore'] as num?)?.toDouble(),
      ratingRank: _nullableIntFromJson(json['ratingRank']),
      ratingTotal: _nullableIntFromJson(json['ratingTotal']),
      source: json['source']?.toString() ?? 'bangumi',
    );
  }
}

bool sameSubjectIdentity(AnimeSubject first, AnimeSubject second) {
  return first.id == second.id &&
      first.source.trim().toLowerCase() == second.source.trim().toLowerCase();
}

class AnimeEpisode {
  const AnimeEpisode({
    required this.id,
    required this.subjectId,
    required this.number,
    required this.title,
    required this.airdate,
    required this.duration,
    required this.description,
    this.thumbnailUrl,
  });

  final int id;
  final int subjectId;
  final int number;
  final String title;
  final String? airdate;
  final String duration;
  final String description;
  final String? thumbnailUrl;

  String get displayTitle =>
      title.trim().isEmpty ? '第$number集' : '第$number集 $title';

  Map<String, dynamic> toJson() => {
    'id': id,
    'subjectId': subjectId,
    'number': number,
    'title': title,
    'airdate': airdate,
    'duration': duration,
    'description': description,
    'thumbnailUrl': thumbnailUrl,
  };

  factory AnimeEpisode.fromJson(Map<String, dynamic> json) {
    return AnimeEpisode(
      id: _intFromJson(json['id']),
      subjectId: _intFromJson(json['subjectId']),
      number: _intFromJson(json['number']),
      title: json['title']?.toString() ?? '',
      airdate: _blankToNull(json['airdate']?.toString()),
      duration: json['duration']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      thumbnailUrl: _blankToNull(json['thumbnailUrl']?.toString()),
    );
  }
}

class PlaybackLine {
  const PlaybackLine({
    required this.id,
    required this.episodeId,
    required this.providerId,
    required this.providerName,
    required this.title,
    required this.quality,
    required this.format,
    this.url,
    this.headers = const {},
    this.latency,
    this.sizeLabel,
    this.sizeBytes,
    this.sizeEstimated = false,
    this.videoWidth,
    this.videoHeight,
    this.bitrate,
    this.codecs,
    this.isLive = false,
    this.adaptive = false,
    this.publicHttpOnly = false,
    this.serverVerified = false,
    this.requiresClientProbe = false,
    this.clientVerified = false,
    this.cacheState = 'unknown',
    this.sourceErrorCategory = '',
    this.expiresAt,
    this.available = false,
    this.message,
  });

  final String id;
  final int episodeId;
  final String providerId;
  final String providerName;
  final String title;
  final String quality;
  final String format;
  final String? url;
  final Map<String, String> headers;
  final Duration? latency;
  final String? sizeLabel;
  final int? sizeBytes;
  final bool sizeEstimated;
  final int? videoWidth;
  final int? videoHeight;
  final int? bitrate;
  final String? codecs;
  final bool isLive;
  final bool adaptive;

  /// Keeps untrusted rule output on public HTTP(S) addresses during every
  /// resolver-side verification, including manifest child resources.
  final bool publicHttpOnly;
  final bool serverVerified;
  final bool requiresClientProbe;
  final bool clientVerified;
  final String cacheState;
  final String sourceErrorCategory;
  final DateTime? expiresAt;
  final bool available;
  final String? message;
}

class SubtitleCandidate {
  const SubtitleCandidate({
    required this.provider,
    required this.title,
    required this.language,
    this.fileName,
    this.downloadUrl,
    this.downloadCount = 0,
    this.available = false,
    this.message,
  });

  final String provider;
  final String title;
  final String language;
  final String? fileName;
  final String? downloadUrl;
  final int downloadCount;
  final bool available;
  final String? message;
}

class DanmakuMatch {
  const DanmakuMatch({
    required this.provider,
    required this.title,
    required this.episodeTitle,
    required this.episodeId,
    this.commentCount = 0,
    this.available = false,
    this.message,
  });

  final String provider;
  final String title;
  final String episodeTitle;
  final String episodeId;
  final int commentCount;
  final bool available;
  final String? message;
}

enum DanmakuMode { scroll, bottom, top, reverse, advanced }

class DanmakuComment {
  const DanmakuComment({
    required this.id,
    required this.provider,
    required this.time,
    required this.mode,
    required this.color,
    required this.text,
  });

  final String id;
  final String provider;
  final Duration time;
  final DanmakuMode mode;
  final int color;
  final String text;
}

class DanmakuTimeline {
  const DanmakuTimeline({this.sources = const [], this.comments = const []});

  final List<DanmakuMatch> sources;
  final List<DanmakuComment> comments;

  bool get isEmpty => comments.isEmpty;
}

class AnimeCharacter {
  const AnimeCharacter({
    required this.id,
    required this.name,
    required this.relation,
    required this.cv,
    required this.summary,
    this.imageUrl,
  });

  final int id;
  final String name;
  final String relation;
  final String cv;
  final String summary;
  final String? imageUrl;
}

class AnimeStaff {
  const AnimeStaff({
    required this.id,
    required this.name,
    required this.role,
    required this.career,
    this.imageUrl,
  });

  final int id;
  final String name;
  final String role;
  final String career;
  final String? imageUrl;
}

class AnimeRecommendation {
  const AnimeRecommendation({required this.subject, required this.relation});

  final AnimeSubject subject;
  final String relation;
}

/// TMDB genre ids in Chinese. Aggregated feeds occasionally deliver raw
/// genre ids as category names; those must never surface in the UI.
const _tmdbGenreNames = <String, String>{
  '12': '冒险',
  '14': '奇幻',
  '16': '动画',
  '18': '剧情',
  '27': '恐怖',
  '28': '动作',
  '35': '喜剧',
  '36': '历史',
  '37': '西部',
  '53': '惊悚',
  '80': '犯罪',
  '99': '纪录',
  '878': '科幻',
  '9648': '悬疑',
  '10402': '音乐',
  '10749': '爱情',
  '10751': '家庭',
  '10752': '战争',
  '10759': '动作冒险',
  '10762': '儿童',
  '10763': '新闻',
  '10764': '真人秀',
  '10765': '科幻奇幻',
  '10766': '肥皂剧',
  '10767': '脱口秀',
  '10768': '战争政治',
  '10770': '电视电影',
};

/// Human label for a category name. Numeric TMDB genre ids translate to
/// Chinese; unknown numeric ids resolve to empty so callers can drop them.
String tmdbGenreLabel(String raw) {
  final name = raw.trim();
  if (name.isEmpty) return '';
  if (RegExp(r'^\d+$').hasMatch(name)) {
    return _tmdbGenreNames[name] ?? '';
  }
  return name;
}

class AnimeCategory {
  const AnimeCategory({required this.name, this.count = 0, this.imageUrl});

  final String name;
  final int count;
  final String? imageUrl;

  Map<String, dynamic> toJson() => {
    'name': name,
    'count': count,
    'imageUrl': imageUrl,
  };

  factory AnimeCategory.fromJson(Map<String, dynamic> json) {
    return AnimeCategory(
      name: json['name']?.toString() ?? '',
      count: _intFromJson(json['count']),
      imageUrl: _blankToNull(json['imageUrl']?.toString()),
    );
  }
}

class AnimeTag {
  const AnimeTag({required this.name, this.count = 0, this.imageUrl});

  final String name;
  final int count;
  final String? imageUrl;

  Map<String, dynamic> toJson() => {
    'name': name,
    'count': count,
    'imageUrl': imageUrl,
  };

  factory AnimeTag.fromJson(Map<String, dynamic> json) {
    return AnimeTag(
      name: json['name']?.toString() ?? '',
      count: _intFromJson(json['count']),
      imageUrl: _blankToNull(json['imageUrl']?.toString()),
    );
  }
}

class AnimeHomeFeed {
  const AnimeHomeFeed({
    required this.hero,
    required this.recent,
    required this.recommended,
    required this.index,
    required this.categories,
    required this.tags,
    this.seriesHighlights = const [],
    this.movieHighlights = const [],
  });

  final AnimeSubject hero;
  final List<AnimeSubject> recent;
  final List<AnimeSubject> recommended;
  final List<AnimeSubject> index;
  final List<AnimeCategory> categories;
  final List<AnimeTag> tags;
  final List<AnimeSubject> seriesHighlights;
  final List<AnimeSubject> movieHighlights;

  Map<String, dynamic> toJson() => {
    'hero': hero.toJson(),
    'recent': recent.map((item) => item.toJson()).toList(),
    'recommended': recommended.map((item) => item.toJson()).toList(),
    'index': index.map((item) => item.toJson()).toList(),
    'categories': categories.map((item) => item.toJson()).toList(),
    'tags': tags.map((item) => item.toJson()).toList(),
    'seriesHighlights': seriesHighlights.map((item) => item.toJson()).toList(),
    'movieHighlights': movieHighlights.map((item) => item.toJson()).toList(),
  };

  factory AnimeHomeFeed.fromJson(Map<String, dynamic> json) {
    final heroJson = json['hero'];
    if (heroJson is! Map) {
      throw const FormatException('home feed hero is missing');
    }
    return AnimeHomeFeed(
      hero: AnimeSubject.fromJson(heroJson.cast<String, dynamic>()),
      recent: _listFromJson(json['recent'], AnimeSubject.fromJson),
      recommended: _listFromJson(json['recommended'], AnimeSubject.fromJson),
      index: _listFromJson(json['index'], AnimeSubject.fromJson),
      categories: _listFromJson(json['categories'], AnimeCategory.fromJson),
      tags: _listFromJson(json['tags'], AnimeTag.fromJson),
      seriesHighlights: _listFromJson(
        json['seriesHighlights'],
        AnimeSubject.fromJson,
      ),
      movieHighlights: _listFromJson(
        json['movieHighlights'],
        AnimeSubject.fromJson,
      ),
    );
  }
}

class ExternalWatchLink {
  const ExternalWatchLink({
    required this.provider,
    required this.title,
    required this.url,
  });

  final String provider;
  final String title;
  final String url;
}

class AnimeDetailBundle {
  const AnimeDetailBundle({
    required this.subject,
    required this.episodes,
    required this.characters,
    required this.staff,
    required this.recommendations,
    this.watchLinks = const [],
  });

  final AnimeSubject subject;
  final List<AnimeEpisode> episodes;
  final List<AnimeCharacter> characters;
  final List<AnimeStaff> staff;
  final List<AnimeRecommendation> recommendations;
  final List<ExternalWatchLink> watchLinks;
}

class PlaySessionRequest {
  const PlaySessionRequest({
    required this.subject,
    required this.episodes,
    required this.episode,
    this.initialLine,
    this.offlineOnly = false,
    this.resumePosition,
  });

  final AnimeSubject subject;
  final List<AnimeEpisode> episodes;
  final AnimeEpisode episode;
  final PlaybackLine? initialLine;
  final bool offlineOnly;

  /// Position to seek to once the opening episode renders its first frame.
  final Duration? resumePosition;
}

class LibraryEntry {
  const LibraryEntry({
    required this.subject,
    required this.updatedAt,
    this.episode,
    this.note = '',
    this.positionSeconds = 0,
    this.durationSeconds = 0,
  });

  final AnimeSubject subject;
  final AnimeEpisode? episode;
  final DateTime updatedAt;
  final String note;

  /// Last playback position within [episode]; 0 means "never played" or
  /// "finished" (near-complete positions are dropped on save).
  final int positionSeconds;
  final int durationSeconds;

  String get title => episode == null
      ? subject.title
      : '${subject.title} · ${episode!.displayTitle}';

  /// 0..1 progress through the recorded episode, null without a usable pair.
  double? get playbackProgress {
    if (positionSeconds <= 0 || durationSeconds <= 0) return null;
    return (positionSeconds / durationSeconds).clamp(0.0, 1.0);
  }

  String get positionLabel {
    final total = Duration(seconds: positionSeconds);
    final hours = total.inHours;
    final minutes = total.inMinutes % 60;
    final seconds = total.inSeconds % 60;
    String pad(int value) => value.toString().padLeft(2, '0');
    return hours > 0
        ? '$hours:${pad(minutes)}:${pad(seconds)}'
        : '${pad(minutes)}:${pad(seconds)}';
  }

  LibraryEntry copyWith({
    AnimeSubject? subject,
    AnimeEpisode? episode,
    DateTime? updatedAt,
    String? note,
    int? positionSeconds,
    int? durationSeconds,
  }) {
    return LibraryEntry(
      subject: subject ?? this.subject,
      episode: episode ?? this.episode,
      updatedAt: updatedAt ?? this.updatedAt,
      note: note ?? this.note,
      positionSeconds: positionSeconds ?? this.positionSeconds,
      durationSeconds: durationSeconds ?? this.durationSeconds,
    );
  }

  Map<String, dynamic> toJson() => {
    'subject': subject.toJson(),
    'episode': episode?.toJson(),
    'updatedAt': updatedAt.toIso8601String(),
    'note': note,
    if (positionSeconds > 0) 'positionSeconds': positionSeconds,
    if (durationSeconds > 0) 'durationSeconds': durationSeconds,
  };

  factory LibraryEntry.fromJson(Map<String, dynamic> json) {
    final subjectJson = json['subject'];
    final episodeJson = json['episode'];
    return LibraryEntry(
      subject: subjectJson is Map
          ? AnimeSubject.fromJson(subjectJson.cast<String, dynamic>())
          : AnimeSubject.fromJson(const {}),
      episode: episodeJson is Map
          ? AnimeEpisode.fromJson(episodeJson.cast<String, dynamic>())
          : null,
      updatedAt:
          DateTime.tryParse(json['updatedAt']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      note: json['note']?.toString() ?? '',
      positionSeconds: (json['positionSeconds'] as num?)?.toInt() ?? 0,
      durationSeconds: (json['durationSeconds'] as num?)?.toInt() ?? 0,
    );
  }
}

class UserProfileSettings {
  const UserProfileSettings({
    this.nickname = '游客',
    this.uid = '',
    this.density = 0,
    this.coins = 0,
  });

  final String nickname;
  final String uid;
  final int density;
  final int coins;

  String get avatarText {
    final text = nickname.trim();
    return text.isEmpty
        ? 'A'
        : String.fromCharCode(text.runes.first).toUpperCase();
  }

  UserProfileSettings copyWith({
    String? nickname,
    String? uid,
    int? density,
    int? coins,
  }) {
    return UserProfileSettings(
      nickname: nickname ?? this.nickname,
      uid: uid ?? this.uid,
      density: density ?? this.density,
      coins: coins ?? this.coins,
    );
  }

  Map<String, dynamic> toJson() => {
    'nickname': nickname,
    'uid': uid,
    'density': density,
    'coins': coins,
  };

  factory UserProfileSettings.fromJson(Map<String, dynamic> json) {
    return UserProfileSettings(
      nickname: json['nickname']?.toString() ?? '游客',
      uid: json['uid']?.toString() ?? '',
      density: _intFromJson(json['density'], fallback: 0),
      coins: _intFromJson(json['coins'], fallback: 0),
    );
  }
}

class HomePreferences {
  const HomePreferences({this.defaultTab = AnimeHomeTab.recommended});

  final AnimeHomeTab defaultTab;

  HomePreferences copyWith({AnimeHomeTab? defaultTab}) {
    return HomePreferences(defaultTab: defaultTab ?? this.defaultTab);
  }

  Map<String, dynamic> toJson() => {'defaultTab': defaultTab.name};

  factory HomePreferences.fromJson(Map<String, dynamic> json) {
    final tabName = json['defaultTab']?.toString();
    final tab = AnimeHomeTab.values.firstWhere(
      (item) => item.name == tabName,
      orElse: () => AnimeHomeTab.recommended,
    );
    return HomePreferences(defaultTab: tab);
  }
}

class AppearanceSettings {
  const AppearanceSettings({
    this.followSystem = false,
    this.darkMode = true,
    this.compactMode = false,
    this.reduceMotion = false,
  });

  final bool followSystem;
  final bool darkMode;
  final bool compactMode;
  final bool reduceMotion;

  AppearanceSettings copyWith({
    bool? followSystem,
    bool? darkMode,
    bool? compactMode,
    bool? reduceMotion,
  }) {
    return AppearanceSettings(
      followSystem: followSystem ?? this.followSystem,
      darkMode: darkMode ?? this.darkMode,
      compactMode: compactMode ?? this.compactMode,
      reduceMotion: reduceMotion ?? this.reduceMotion,
    );
  }

  Map<String, dynamic> toJson() => {
    'followSystem': followSystem,
    'darkMode': darkMode,
    'compactMode': compactMode,
    'reduceMotion': reduceMotion,
  };

  factory AppearanceSettings.fromJson(Map<String, dynamic> json) {
    return AppearanceSettings(
      followSystem: json['followSystem'] as bool? ?? false,
      darkMode: json['darkMode'] as bool? ?? true,
      compactMode: json['compactMode'] as bool? ?? false,
      reduceMotion: json['reduceMotion'] as bool? ?? false,
    );
  }
}

class DanmakuSettings {
  const DanmakuSettings({
    this.enabled = false,
    this.opacity = 0.86,
    this.fontSize = 18,
    this.blockTop = false,
    this.blockScroll = false,
    this.blockKeywords = const [],
  });

  final bool enabled;
  final double opacity;
  final double fontSize;
  final bool blockTop;
  final bool blockScroll;
  final List<String> blockKeywords;

  DanmakuSettings copyWith({
    bool? enabled,
    double? opacity,
    double? fontSize,
    bool? blockTop,
    bool? blockScroll,
    List<String>? blockKeywords,
  }) {
    return DanmakuSettings(
      enabled: enabled ?? this.enabled,
      opacity: opacity ?? this.opacity,
      fontSize: fontSize ?? this.fontSize,
      blockTop: blockTop ?? this.blockTop,
      blockScroll: blockScroll ?? this.blockScroll,
      blockKeywords: blockKeywords ?? this.blockKeywords,
    );
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'opacity': opacity,
    'fontSize': fontSize,
    'blockTop': blockTop,
    'blockScroll': blockScroll,
    'blockKeywords': blockKeywords,
  };

  factory DanmakuSettings.fromJson(Map<String, dynamic> json) {
    return DanmakuSettings(
      enabled: json['enabled'] as bool? ?? false,
      opacity: (json['opacity'] as num?)?.toDouble() ?? 0.86,
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 18,
      blockTop: json['blockTop'] as bool? ?? false,
      blockScroll: json['blockScroll'] as bool? ?? false,
      blockKeywords: _stringListFromJson(json['blockKeywords']),
    );
  }
}

class MiscSettings {
  const MiscSettings({
    this.autoCheckUpdates = true,
    this.wifiOnlyCache = true,
    this.keepScreenOn = true,
    this.saveCrashLog = true,
  });

  final bool autoCheckUpdates;
  final bool wifiOnlyCache;
  final bool keepScreenOn;
  final bool saveCrashLog;

  MiscSettings copyWith({
    bool? autoCheckUpdates,
    bool? wifiOnlyCache,
    bool? keepScreenOn,
    bool? saveCrashLog,
  }) {
    return MiscSettings(
      autoCheckUpdates: autoCheckUpdates ?? this.autoCheckUpdates,
      wifiOnlyCache: wifiOnlyCache ?? this.wifiOnlyCache,
      keepScreenOn: keepScreenOn ?? this.keepScreenOn,
      saveCrashLog: saveCrashLog ?? this.saveCrashLog,
    );
  }

  Map<String, dynamic> toJson() => {
    'autoCheckUpdates': autoCheckUpdates,
    'wifiOnlyCache': wifiOnlyCache,
    'keepScreenOn': keepScreenOn,
    'saveCrashLog': saveCrashLog,
  };

  factory MiscSettings.fromJson(Map<String, dynamic> json) {
    return MiscSettings(
      autoCheckUpdates: json['autoCheckUpdates'] as bool? ?? true,
      wifiOnlyCache: json['wifiOnlyCache'] as bool? ?? true,
      keepScreenOn: json['keepScreenOn'] as bool? ?? true,
      saveCrashLog: json['saveCrashLog'] as bool? ?? true,
    );
  }
}

const _defaultPlaybackBackendEnabled = bool.fromEnvironment(
  'ZELUNA_BACKEND_ENABLED',
  defaultValue: true,
);
const _defaultPlaybackBackendEndpoint = String.fromEnvironment(
  'ZELUNA_BACKEND_URL',
  defaultValue: 'https://api.zeluna.top',
);

class ExternalServiceSettings {
  const ExternalServiceSettings({
    this.mediaMetadataEnabled = true,
    this.mediaMetadataProvider = 'TMDB + Cinemeta + TVMaze',
    this.tmdbEnabled = true,
    this.cinemetaEnabled = true,
    this.watchHubEnabled = false,
    this.peerTubeEnabled = true,
    this.wikimediaCommonsEnabled = true,
    this.anilistEnabled = true,
    this.jikanEnabled = true,
    this.kitsuEnabled = true,
    this.bangumiEnabled = true,
    this.preferBangumiChinese = true,
    this.publicCollectionSyncEnabled = true,
    this.bilibiliSubtitleEnabled = true,
    this.subtitleLanguage = 'zh-CN',
    this.autoMatchSubtitle = true,
    this.dandanplayDanmakuEnabled = true,
    this.dandanplayAppId = '',
    this.dandanplayAppSecret = '',
    this.bilibiliDanmakuEnabled = true,
    this.customDanmakuEnabled = false,
    this.customDanmakuEndpoint = '',
    this.danmakuTimelineSync = true,
    this.playbackBackendEnabled = _defaultPlaybackBackendEnabled,
    this.playbackBackendEndpoint = _defaultPlaybackBackendEndpoint,
  });

  final bool mediaMetadataEnabled;
  final String mediaMetadataProvider;
  final bool tmdbEnabled;
  final bool cinemetaEnabled;
  final bool watchHubEnabled;
  final bool peerTubeEnabled;
  final bool wikimediaCommonsEnabled;
  final bool anilistEnabled;
  final bool jikanEnabled;
  final bool kitsuEnabled;
  final bool bangumiEnabled;
  final bool preferBangumiChinese;
  final bool publicCollectionSyncEnabled;
  final bool bilibiliSubtitleEnabled;
  final String subtitleLanguage;
  final bool autoMatchSubtitle;
  final bool dandanplayDanmakuEnabled;
  final String dandanplayAppId;
  final String dandanplayAppSecret;
  final bool bilibiliDanmakuEnabled;
  final bool customDanmakuEnabled;
  final String customDanmakuEndpoint;
  final bool danmakuTimelineSync;
  final bool playbackBackendEnabled;
  final String playbackBackendEndpoint;

  ExternalServiceSettings copyWith({
    bool? mediaMetadataEnabled,
    String? mediaMetadataProvider,
    bool? tmdbEnabled,
    bool? cinemetaEnabled,
    bool? watchHubEnabled,
    bool? peerTubeEnabled,
    bool? wikimediaCommonsEnabled,
    bool? anilistEnabled,
    bool? jikanEnabled,
    bool? kitsuEnabled,
    bool? bangumiEnabled,
    bool? preferBangumiChinese,
    bool? publicCollectionSyncEnabled,
    bool? bilibiliSubtitleEnabled,
    String? subtitleLanguage,
    bool? autoMatchSubtitle,
    bool? dandanplayDanmakuEnabled,
    String? dandanplayAppId,
    String? dandanplayAppSecret,
    bool? bilibiliDanmakuEnabled,
    bool? customDanmakuEnabled,
    String? customDanmakuEndpoint,
    bool? danmakuTimelineSync,
    bool? playbackBackendEnabled,
    String? playbackBackendEndpoint,
  }) {
    return ExternalServiceSettings(
      mediaMetadataEnabled: mediaMetadataEnabled ?? this.mediaMetadataEnabled,
      mediaMetadataProvider:
          mediaMetadataProvider ?? this.mediaMetadataProvider,
      tmdbEnabled: tmdbEnabled ?? this.tmdbEnabled,
      cinemetaEnabled: cinemetaEnabled ?? this.cinemetaEnabled,
      watchHubEnabled: watchHubEnabled ?? this.watchHubEnabled,
      peerTubeEnabled: peerTubeEnabled ?? this.peerTubeEnabled,
      wikimediaCommonsEnabled:
          wikimediaCommonsEnabled ?? this.wikimediaCommonsEnabled,
      anilistEnabled: anilistEnabled ?? this.anilistEnabled,
      jikanEnabled: jikanEnabled ?? this.jikanEnabled,
      kitsuEnabled: kitsuEnabled ?? this.kitsuEnabled,
      bangumiEnabled: bangumiEnabled ?? this.bangumiEnabled,
      preferBangumiChinese: preferBangumiChinese ?? this.preferBangumiChinese,
      publicCollectionSyncEnabled:
          publicCollectionSyncEnabled ?? this.publicCollectionSyncEnabled,
      bilibiliSubtitleEnabled:
          bilibiliSubtitleEnabled ?? this.bilibiliSubtitleEnabled,
      subtitleLanguage: subtitleLanguage ?? this.subtitleLanguage,
      autoMatchSubtitle: autoMatchSubtitle ?? this.autoMatchSubtitle,
      dandanplayDanmakuEnabled:
          dandanplayDanmakuEnabled ?? this.dandanplayDanmakuEnabled,
      dandanplayAppId: dandanplayAppId ?? this.dandanplayAppId,
      dandanplayAppSecret: dandanplayAppSecret ?? this.dandanplayAppSecret,
      bilibiliDanmakuEnabled:
          bilibiliDanmakuEnabled ?? this.bilibiliDanmakuEnabled,
      customDanmakuEnabled: customDanmakuEnabled ?? this.customDanmakuEnabled,
      customDanmakuEndpoint:
          customDanmakuEndpoint ?? this.customDanmakuEndpoint,
      danmakuTimelineSync: danmakuTimelineSync ?? this.danmakuTimelineSync,
      playbackBackendEnabled:
          playbackBackendEnabled ?? this.playbackBackendEnabled,
      playbackBackendEndpoint:
          playbackBackendEndpoint ?? this.playbackBackendEndpoint,
    );
  }

  Map<String, dynamic> toJson() => {
    'mediaMetadataEnabled': mediaMetadataEnabled,
    'mediaMetadataProvider': mediaMetadataProvider,
    'tmdbEnabled': tmdbEnabled,
    'cinemetaEnabled': cinemetaEnabled,
    'watchHubEnabled': watchHubEnabled,
    'peerTubeEnabled': peerTubeEnabled,
    'wikimediaCommonsEnabled': wikimediaCommonsEnabled,
    'anilistEnabled': anilistEnabled,
    'jikanEnabled': jikanEnabled,
    'kitsuEnabled': kitsuEnabled,
    'bangumiEnabled': bangumiEnabled,
    'preferBangumiChinese': preferBangumiChinese,
    'publicCollectionSyncEnabled': publicCollectionSyncEnabled,
    'bilibiliSubtitleEnabled': bilibiliSubtitleEnabled,
    'subtitleLanguage': subtitleLanguage,
    'autoMatchSubtitle': autoMatchSubtitle,
    'dandanplayDanmakuEnabled': dandanplayDanmakuEnabled,
    'dandanplayAppId': dandanplayAppId,
    'dandanplayAppSecret': dandanplayAppSecret,
    'bilibiliDanmakuEnabled': bilibiliDanmakuEnabled,
    'customDanmakuEnabled': customDanmakuEnabled,
    'customDanmakuEndpoint': customDanmakuEndpoint,
    'danmakuTimelineSync': danmakuTimelineSync,
    'playbackBackendEnabled': playbackBackendEnabled,
    'playbackBackendEndpoint': playbackBackendEndpoint,
  };

  factory ExternalServiceSettings.fromJson(Map<String, dynamic> json) {
    return ExternalServiceSettings(
      mediaMetadataEnabled: json['mediaMetadataEnabled'] as bool? ?? true,
      mediaMetadataProvider:
          json['mediaMetadataProvider']?.toString() ??
          'TMDB + Cinemeta + TVMaze',
      tmdbEnabled: json['tmdbEnabled'] as bool? ?? true,
      cinemetaEnabled: json['cinemetaEnabled'] as bool? ?? true,
      // Keep reading legacy settings JSON, but permanently migrate the
      // Retired external platform-link integration stays disabled.
      watchHubEnabled: false,
      peerTubeEnabled: json['peerTubeEnabled'] as bool? ?? true,
      wikimediaCommonsEnabled: json['wikimediaCommonsEnabled'] as bool? ?? true,
      anilistEnabled: json['anilistEnabled'] as bool? ?? true,
      jikanEnabled: json['jikanEnabled'] as bool? ?? true,
      kitsuEnabled: json['kitsuEnabled'] as bool? ?? true,
      bangumiEnabled: json['bangumiEnabled'] as bool? ?? true,
      preferBangumiChinese: json['preferBangumiChinese'] as bool? ?? true,
      publicCollectionSyncEnabled:
          json['publicCollectionSyncEnabled'] as bool? ?? true,
      bilibiliSubtitleEnabled: json['bilibiliSubtitleEnabled'] as bool? ?? true,
      subtitleLanguage: json['subtitleLanguage']?.toString() ?? 'zh-CN',
      autoMatchSubtitle: json['autoMatchSubtitle'] as bool? ?? true,
      dandanplayDanmakuEnabled:
          json['dandanplayDanmakuEnabled'] as bool? ?? true,
      dandanplayAppId: json['dandanplayAppId']?.toString() ?? '',
      dandanplayAppSecret: json['dandanplayAppSecret']?.toString() ?? '',
      bilibiliDanmakuEnabled: json['bilibiliDanmakuEnabled'] as bool? ?? true,
      customDanmakuEnabled: json['customDanmakuEnabled'] as bool? ?? false,
      customDanmakuEndpoint: json['customDanmakuEndpoint']?.toString() ?? '',
      danmakuTimelineSync: json['danmakuTimelineSync'] as bool? ?? true,
      playbackBackendEnabled:
          json['playbackBackendEnabled'] as bool? ??
          _defaultPlaybackBackendEnabled,
      playbackBackendEndpoint:
          (json['playbackBackendEndpoint']?.toString().trim().isNotEmpty ??
              false)
          ? json['playbackBackendEndpoint'].toString().trim()
          : _defaultPlaybackBackendEndpoint,
    );
  }
}

class LocalFeedback {
  const LocalFeedback({
    required this.id,
    required this.title,
    required this.content,
    required this.createdAt,
    this.subject,
  });

  final String id;
  final String title;
  final String content;
  final DateTime createdAt;
  final AnimeSubject? subject;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'content': content,
    'createdAt': createdAt.toIso8601String(),
    'subject': subject?.toJson(),
  };

  factory LocalFeedback.fromJson(Map<String, dynamic> json) {
    final subjectJson = json['subject'];
    return LocalFeedback(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      content: json['content']?.toString() ?? '',
      createdAt:
          DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      subject: subjectJson is Map
          ? AnimeSubject.fromJson(subjectJson.cast<String, dynamic>())
          : null,
    );
  }
}

class PlaybackSettings {
  const PlaybackSettings({
    this.volumeBoost = 0.26,
    this.superResolution = false,
    this.superResolutionProfile = 'auto',
    this.superResolutionCustomShaders = const [],
    this.videoScale = '适应',
    this.speed = 1.0,
    this.defaultSpeed = 1.0,
    this.holdSpeed = 2.0,
    this.edgeDoubleTap = true,
    this.rewindSeconds = 10,
    this.forwardSeconds = 10,
    this.compatibilityMode = true,
    this.autoNext = true,
    this.autoSwitchLine = true,
    this.autoFullscreen = false,
    this.rememberLine = true,
    this.keyboardShortcutsEnabled = true,
    this.shortcutPlayPause = true,
    this.shortcutSeek = true,
    this.shortcutVolume = true,
    this.shortcutFullscreen = true,
    this.shortcutMute = true,
    this.shortcutReload = true,
  });

  final double volumeBoost;
  final bool superResolution;
  final String superResolutionProfile;
  final List<String> superResolutionCustomShaders;
  final String videoScale;
  final double speed;
  final double defaultSpeed;
  final double holdSpeed;
  final bool edgeDoubleTap;
  final int rewindSeconds;
  final int forwardSeconds;
  final bool compatibilityMode;
  final bool autoNext;
  final bool autoSwitchLine;
  final bool autoFullscreen;
  final bool rememberLine;
  final bool keyboardShortcutsEnabled;
  final bool shortcutPlayPause;
  final bool shortcutSeek;
  final bool shortcutVolume;
  final bool shortcutFullscreen;
  final bool shortcutMute;
  final bool shortcutReload;

  PlaybackSettings copyWith({
    double? volumeBoost,
    bool? superResolution,
    String? superResolutionProfile,
    List<String>? superResolutionCustomShaders,
    String? videoScale,
    double? speed,
    double? defaultSpeed,
    double? holdSpeed,
    bool? edgeDoubleTap,
    int? rewindSeconds,
    int? forwardSeconds,
    bool? compatibilityMode,
    bool? autoNext,
    bool? autoSwitchLine,
    bool? autoFullscreen,
    bool? rememberLine,
    bool? keyboardShortcutsEnabled,
    bool? shortcutPlayPause,
    bool? shortcutSeek,
    bool? shortcutVolume,
    bool? shortcutFullscreen,
    bool? shortcutMute,
    bool? shortcutReload,
  }) {
    return PlaybackSettings(
      volumeBoost: volumeBoost ?? this.volumeBoost,
      superResolution: superResolution ?? this.superResolution,
      superResolutionProfile:
          superResolutionProfile ?? this.superResolutionProfile,
      superResolutionCustomShaders:
          superResolutionCustomShaders ?? this.superResolutionCustomShaders,
      videoScale: videoScale ?? this.videoScale,
      speed: speed ?? this.speed,
      defaultSpeed: defaultSpeed ?? this.defaultSpeed,
      holdSpeed: holdSpeed ?? this.holdSpeed,
      edgeDoubleTap: edgeDoubleTap ?? this.edgeDoubleTap,
      rewindSeconds: rewindSeconds ?? this.rewindSeconds,
      forwardSeconds: forwardSeconds ?? this.forwardSeconds,
      compatibilityMode: compatibilityMode ?? this.compatibilityMode,
      autoNext: autoNext ?? this.autoNext,
      autoSwitchLine: autoSwitchLine ?? this.autoSwitchLine,
      autoFullscreen: autoFullscreen ?? this.autoFullscreen,
      rememberLine: rememberLine ?? this.rememberLine,
      keyboardShortcutsEnabled:
          keyboardShortcutsEnabled ?? this.keyboardShortcutsEnabled,
      shortcutPlayPause: shortcutPlayPause ?? this.shortcutPlayPause,
      shortcutSeek: shortcutSeek ?? this.shortcutSeek,
      shortcutVolume: shortcutVolume ?? this.shortcutVolume,
      shortcutFullscreen: shortcutFullscreen ?? this.shortcutFullscreen,
      shortcutMute: shortcutMute ?? this.shortcutMute,
      shortcutReload: shortcutReload ?? this.shortcutReload,
    );
  }

  Map<String, dynamic> toJson() => {
    'volumeBoost': volumeBoost,
    'superResolution': superResolution,
    'superResolutionProfile': superResolutionProfile,
    'superResolutionCustomShaders': superResolutionCustomShaders,
    'videoScale': videoScale,
    'speed': speed,
    'defaultSpeed': defaultSpeed,
    'holdSpeed': holdSpeed,
    'edgeDoubleTap': edgeDoubleTap,
    'rewindSeconds': rewindSeconds,
    'forwardSeconds': forwardSeconds,
    'compatibilityMode': compatibilityMode,
    'autoNext': autoNext,
    'autoSwitchLine': autoSwitchLine,
    'autoFullscreen': autoFullscreen,
    'rememberLine': rememberLine,
    'keyboardShortcutsEnabled': keyboardShortcutsEnabled,
    'shortcutPlayPause': shortcutPlayPause,
    'shortcutSeek': shortcutSeek,
    'shortcutVolume': shortcutVolume,
    'shortcutFullscreen': shortcutFullscreen,
    'shortcutMute': shortcutMute,
    'shortcutReload': shortcutReload,
  };

  factory PlaybackSettings.fromJson(Map<String, dynamic> json) {
    return PlaybackSettings(
      volumeBoost: (json['volumeBoost'] as num?)?.toDouble() ?? 0.26,
      superResolution: json['superResolution'] as bool? ?? false,
      superResolutionProfile: _normalizeSuperResolutionProfile(
        json['superResolutionProfile'],
      ),
      superResolutionCustomShaders: _stringListFromJson(
        json['superResolutionCustomShaders'],
      ),
      videoScale: json['videoScale'] as String? ?? '适应',
      speed: (json['speed'] as num?)?.toDouble() ?? 1.0,
      defaultSpeed: (json['defaultSpeed'] as num?)?.toDouble() ?? 1.0,
      holdSpeed: (json['holdSpeed'] as num?)?.toDouble() ?? 2.0,
      edgeDoubleTap: json['edgeDoubleTap'] as bool? ?? true,
      rewindSeconds: json['rewindSeconds'] as int? ?? 10,
      forwardSeconds: json['forwardSeconds'] as int? ?? 10,
      compatibilityMode: json['compatibilityMode'] as bool? ?? true,
      autoNext: json['autoNext'] as bool? ?? true,
      autoSwitchLine: json['autoSwitchLine'] as bool? ?? true,
      autoFullscreen: json['autoFullscreen'] as bool? ?? false,
      rememberLine: json['rememberLine'] as bool? ?? true,
      keyboardShortcutsEnabled:
          json['keyboardShortcutsEnabled'] as bool? ?? true,
      shortcutPlayPause: json['shortcutPlayPause'] as bool? ?? true,
      shortcutSeek: json['shortcutSeek'] as bool? ?? true,
      shortcutVolume: json['shortcutVolume'] as bool? ?? true,
      shortcutFullscreen: json['shortcutFullscreen'] as bool? ?? true,
      shortcutMute: json['shortcutMute'] as bool? ?? true,
      shortcutReload: json['shortcutReload'] as bool? ?? true,
    );
  }

  static String _normalizeSuperResolutionProfile(Object? value) {
    final profile = value?.toString();
    if (profile == 'performance') return 'low_resolution';
    if (profile == 'balanced') return 'auto';
    if (profile == 'quality') return 'clear';
    if (profile == 'auto' ||
        profile == 'clear' ||
        profile == 'soft' ||
        profile == 'low_resolution' ||
        profile == 'strong' ||
        profile == 'advanced') {
      return profile!;
    }
    return 'auto';
  }
}

int _intFromJson(Object? value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.round();
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

int? _nullableIntFromJson(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.round();
  return int.tryParse(value.toString());
}

String? _blankToNull(String? value) {
  final text = value?.trim();
  if (text == null || text.isEmpty) return null;
  return text;
}

List<T> _listFromJson<T>(
  Object? value,
  T Function(Map<String, dynamic> json) convert,
) {
  if (value is! List) return const [];
  return value
      .whereType<Map>()
      .map((item) => convert(item.cast<String, dynamic>()))
      .toList();
}

List<String> _stringListFromJson(Object? value) {
  if (value is List) return value.map((item) => item.toString()).toList();
  if (value is String && value.trim().isNotEmpty) {
    return value
        .split(RegExp(r'[,，\n]'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
  }
  return const [];
}
