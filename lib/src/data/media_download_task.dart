import '../domain/anime_models.dart';

enum MediaDownloadTaskStatus {
  queued,
  resolving,
  downloading,
  paused,
  completed,
  failed,
  cancelled,
}

class MediaDownloadTask {
  const MediaDownloadTask({
    required this.id,
    required this.subject,
    required this.episode,
    required this.createdAt,
    required this.updatedAt,
    this.status = MediaDownloadTaskStatus.queued,
    this.lineId,
    this.providerName,
    this.format,
    this.url,
    this.headers = const {},
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.temporaryPath,
    this.localPath,
    this.etag,
    this.lastModified,
    this.completedUnits = 0,
    this.totalUnits = 0,
    this.message = '',
  });

  final String id;
  final AnimeSubject subject;
  final AnimeEpisode episode;
  final DateTime createdAt;
  final DateTime updatedAt;
  final MediaDownloadTaskStatus status;
  final String? lineId;
  final String? providerName;
  final String? format;
  final String? url;
  final Map<String, String> headers;
  final int downloadedBytes;
  final int totalBytes;
  final String? temporaryPath;
  final String? localPath;
  final String? etag;
  final String? lastModified;
  final int completedUnits;
  final int totalUnits;
  final String message;

  String get title => '${subject.title} · ${episode.displayTitle}';

  bool get isActive =>
      status == MediaDownloadTaskStatus.queued ||
      status == MediaDownloadTaskStatus.resolving ||
      status == MediaDownloadTaskStatus.downloading;

  bool get isPlayable =>
      status == MediaDownloadTaskStatus.completed &&
      (localPath?.trim().isNotEmpty ?? false);

  double? get progress {
    if (totalBytes > 0) {
      return (downloadedBytes / totalBytes).clamp(0.0, 1.0);
    }
    return totalUnits <= 0
        ? null
        : (completedUnits / totalUnits).clamp(0.0, 1.0);
  }

  String get statusLabel => switch (status) {
    MediaDownloadTaskStatus.queued => '等待下载',
    MediaDownloadTaskStatus.resolving => '正在查找线路',
    MediaDownloadTaskStatus.downloading => '正在下载',
    MediaDownloadTaskStatus.paused => '已暂停',
    MediaDownloadTaskStatus.completed => '已完成',
    MediaDownloadTaskStatus.failed => '下载失败',
    MediaDownloadTaskStatus.cancelled => '已取消',
  };

  PlaybackLine? get localPlaybackLine {
    final path = localPath?.trim();
    if (!isPlayable || path == null || path.isEmpty) return null;
    final isWindowsPath = RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(path);
    return PlaybackLine(
      id: 'offline:$id',
      episodeId: episode.id,
      providerId: 'offline',
      providerName: '本地下载',
      title: '本地 · ${episode.displayTitle}',
      quality: '离线',
      format: format?.trim().isNotEmpty == true
          ? format!.trim()
          : _formatFromPath(path),
      url: Uri.file(path, windows: isWindowsPath).toString(),
      sizeLabel: _byteSizeLabel(totalBytes > 0 ? totalBytes : downloadedBytes),
      available: true,
    );
  }

  MediaDownloadTask copyWith({
    AnimeSubject? subject,
    AnimeEpisode? episode,
    DateTime? createdAt,
    DateTime? updatedAt,
    MediaDownloadTaskStatus? status,
    Object? lineId = _unset,
    Object? providerName = _unset,
    Object? format = _unset,
    Object? url = _unset,
    Map<String, String>? headers,
    int? downloadedBytes,
    int? totalBytes,
    Object? temporaryPath = _unset,
    Object? localPath = _unset,
    Object? etag = _unset,
    Object? lastModified = _unset,
    int? completedUnits,
    int? totalUnits,
    String? message,
  }) {
    return MediaDownloadTask(
      id: id,
      subject: subject ?? this.subject,
      episode: episode ?? this.episode,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      status: status ?? this.status,
      lineId: identical(lineId, _unset) ? this.lineId : lineId as String?,
      providerName: identical(providerName, _unset)
          ? this.providerName
          : providerName as String?,
      format: identical(format, _unset) ? this.format : format as String?,
      url: identical(url, _unset) ? this.url : url as String?,
      headers: headers ?? this.headers,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      temporaryPath: identical(temporaryPath, _unset)
          ? this.temporaryPath
          : temporaryPath as String?,
      localPath: identical(localPath, _unset)
          ? this.localPath
          : localPath as String?,
      etag: identical(etag, _unset) ? this.etag : etag as String?,
      lastModified: identical(lastModified, _unset)
          ? this.lastModified
          : lastModified as String?,
      completedUnits: completedUnits ?? this.completedUnits,
      totalUnits: totalUnits ?? this.totalUnits,
      message: message ?? this.message,
    );
  }

  Map<String, dynamic> toJson() => {
    'version': 2,
    'id': id,
    'subject': subject.toJson(),
    'episode': episode.toJson(),
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'status': status.name,
    'lineId': lineId,
    'providerName': providerName,
    'format': format,
    // Remote URLs and headers can carry short-lived credentials. Persisted
    // tasks resolve a fresh playback line instead of storing either value.
    'url': null,
    'headers': const <String, String>{},
    'downloadedBytes': downloadedBytes,
    'totalBytes': totalBytes,
    'temporaryPath': temporaryPath,
    'localPath': localPath,
    'etag': etag,
    'lastModified': lastModified,
    'completedUnits': completedUnits,
    'totalUnits': totalUnits,
    'message': _persistableMessage(message, status),
  };

  factory MediaDownloadTask.fromJson(Map<String, dynamic> json) {
    final subjectJson = json['subject'];
    final episodeJson = json['episode'];
    return MediaDownloadTask(
      id: json['id']?.toString() ?? '',
      subject: subjectJson is Map
          ? AnimeSubject.fromJson(subjectJson.cast<String, dynamic>())
          : AnimeSubject.fromJson(const {}),
      episode: episodeJson is Map
          ? AnimeEpisode.fromJson(episodeJson.cast<String, dynamic>())
          : AnimeEpisode.fromJson(const {}),
      createdAt:
          DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      updatedAt:
          DateTime.tryParse(json['updatedAt']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      status: MediaDownloadTaskStatus.values.firstWhere(
        (item) => item.name == json['status']?.toString(),
        orElse: () => MediaDownloadTaskStatus.failed,
      ),
      lineId: _blankToNull(json['lineId']),
      providerName: _blankToNull(json['providerName']),
      format: _blankToNull(json['format']),
      url: null,
      headers: const {},
      downloadedBytes: _intValue(json['downloadedBytes']),
      totalBytes: _intValue(json['totalBytes']),
      temporaryPath: _blankToNull(json['temporaryPath']),
      localPath: _blankToNull(json['localPath']),
      etag: _blankToNull(json['etag']),
      lastModified: _blankToNull(json['lastModified']),
      completedUnits: _intValue(json['completedUnits']),
      totalUnits: _intValue(json['totalUnits']),
      message: _persistableMessage(
        json['message']?.toString() ?? '',
        MediaDownloadTaskStatus.values.firstWhere(
          (item) => item.name == json['status']?.toString(),
          orElse: () => MediaDownloadTaskStatus.failed,
        ),
      ),
    );
  }

  factory MediaDownloadTask.fromLegacy(LibraryEntry entry) {
    final lines = entry.note.split('\n');
    final path = lines.length > 1 ? _blankToNull(lines.last) : null;
    final completed = entry.note.startsWith('已下载') && path != null;
    return MediaDownloadTask(
      id: 'legacy-${entry.subject.source}-${entry.subject.id}-${entry.episode?.id ?? 0}',
      subject: entry.subject,
      episode:
          entry.episode ??
          AnimeEpisode(
            id: 0,
            subjectId: entry.subject.id,
            number: 1,
            title: '',
            airdate: null,
            duration: '',
            description: '',
          ),
      createdAt: entry.updatedAt,
      updatedAt: entry.updatedAt,
      status: completed
          ? MediaDownloadTaskStatus.completed
          : MediaDownloadTaskStatus.failed,
      localPath: path,
      message: completed ? '从旧版下载记录迁移' : '旧下载记录无法继续，请重新下载',
    );
  }
}

const _unset = Object();

String _persistableMessage(String message, MediaDownloadTaskStatus status) {
  final text = message.trim();
  if (text.isEmpty) return '';
  final lower = text.toLowerCase();
  final mayContainCredentials =
      RegExp(r'https?://', caseSensitive: false).hasMatch(text) ||
      lower.contains('authorization') ||
      lower.contains('bearer ') ||
      lower.contains('cookie') ||
      lower.contains('credential') ||
      lower.contains('signature') ||
      lower.contains('token=') ||
      lower.contains('secret=');
  if (mayContainCredentials) {
    return status == MediaDownloadTaskStatus.failed
        ? '下载失败，可稍后重试'
        : status.statusSafeMessage;
  }
  return text.length <= 240 ? text : '${text.substring(0, 240)}…';
}

extension on MediaDownloadTaskStatus {
  String get statusSafeMessage => switch (this) {
    MediaDownloadTaskStatus.queued => '等待下载',
    MediaDownloadTaskStatus.resolving => '正在查找线路',
    MediaDownloadTaskStatus.downloading => '正在下载',
    MediaDownloadTaskStatus.paused => '下载已暂停',
    MediaDownloadTaskStatus.completed => '下载完成',
    MediaDownloadTaskStatus.failed => '下载失败，可稍后重试',
    MediaDownloadTaskStatus.cancelled => '下载已取消',
  };
}

String? _blankToNull(Object? value) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? null : text;
}

int _intValue(Object? value) => switch (value) {
  final int number => number,
  final num number => number.toInt(),
  _ => int.tryParse(value?.toString() ?? '') ?? 0,
};

String _formatFromPath(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.webm')) return 'WebM';
  if (lower.endsWith('.mkv')) return 'MKV';
  if (lower.endsWith('.mov')) return 'MOV';
  if (lower.endsWith('.m4v')) return 'M4V';
  return 'MP4';
}

String? _byteSizeLabel(int bytes) {
  if (bytes <= 0) return null;
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024).toStringAsFixed(1)} KB';
}
