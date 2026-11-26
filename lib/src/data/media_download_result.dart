enum MediaDownloadOutcome { completed, paused, cancelled, failed, unsupported }

enum MediaDownloadFileStatus { valid, missing, corrupt }

class MediaDownloadVerification {
  const MediaDownloadVerification({required this.status, this.bytes = 0});

  final MediaDownloadFileStatus status;
  final int bytes;

  bool get isValid => status == MediaDownloadFileStatus.valid;
}

class MediaDownloadStorageEntry {
  const MediaDownloadStorageEntry({
    required this.path,
    required this.bytes,
    required this.modifiedAt,
  });

  final String path;
  final int bytes;
  final DateTime modifiedAt;
}

class MediaDownloadProgress {
  const MediaDownloadProgress({
    required this.downloadedBytes,
    required this.totalBytes,
    required this.temporaryPath,
    required this.targetPath,
    this.etag,
    this.lastModified,
    this.completedUnits = 0,
    this.totalUnits = 0,
  });

  final int downloadedBytes;
  final int totalBytes;
  final String temporaryPath;
  final String targetPath;
  final String? etag;
  final String? lastModified;
  final int completedUnits;
  final int totalUnits;

  double? get fraction {
    if (totalBytes > 0) {
      return (downloadedBytes / totalBytes).clamp(0.0, 1.0);
    }
    return totalUnits <= 0
        ? null
        : (completedUnits / totalUnits).clamp(0.0, 1.0);
  }
}

class MediaDownloadResult {
  const MediaDownloadResult({
    required this.outcome,
    required this.message,
    this.path,
    this.temporaryPath,
    this.bytes = 0,
    this.totalBytes = 0,
    this.etag,
    this.lastModified,
    this.completedUnits = 0,
    this.totalUnits = 0,
  });

  final MediaDownloadOutcome outcome;
  final String message;
  final String? path;
  final String? temporaryPath;
  final int bytes;
  final int totalBytes;
  final String? etag;
  final String? lastModified;
  final int completedUnits;
  final int totalUnits;

  bool get success => outcome == MediaDownloadOutcome.completed;
  bool get paused => outcome == MediaDownloadOutcome.paused;
  bool get cancelled => outcome == MediaDownloadOutcome.cancelled;
}
