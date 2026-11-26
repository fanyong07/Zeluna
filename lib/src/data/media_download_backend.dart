import 'dart:async';

import 'media_download_result.dart';

enum MediaDownloadStopReason { pause, cancel }

class MediaDownloadControl {
  final Completer<MediaDownloadStopReason> _stopCompleter =
      Completer<MediaDownloadStopReason>();

  MediaDownloadStopReason? _reason;

  bool get isStopped => _reason != null;
  MediaDownloadStopReason? get reason => _reason;
  Future<MediaDownloadStopReason> get whenStopped => _stopCompleter.future;

  void pause() => _stop(MediaDownloadStopReason.pause);

  void cancel() => _stop(MediaDownloadStopReason.cancel);

  void _stop(MediaDownloadStopReason reason) {
    if (_reason != null) return;
    _reason = reason;
    _stopCompleter.complete(reason);
  }
}

class MediaDownloadRequest {
  const MediaDownloadRequest({
    required this.taskId,
    required this.url,
    required this.title,
    required this.headers,
    required this.format,
    this.temporaryPath,
    this.targetPath,
    this.etag,
    this.lastModified,
  });

  final String taskId;
  final String url;
  final String title;
  final Map<String, String> headers;
  final String format;
  final String? temporaryPath;
  final String? targetPath;
  final String? etag;
  final String? lastModified;
}

abstract interface class MediaDownloadBackend {
  Future<MediaDownloadResult> download({
    required MediaDownloadRequest request,
    required MediaDownloadControl control,
    required void Function(MediaDownloadProgress progress) onProgress,
  });

  Future<bool> fileExists(String path);

  Future<MediaDownloadVerification> verifyFile(
    String path, {
    int? expectedBytes,
  });

  Future<List<MediaDownloadStorageEntry>> listStorageEntries();

  Future<void> deleteFile(String path);
}
