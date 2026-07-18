import 'media_download_backend.dart';
import 'media_download_result.dart';
import 'media_download_service_stub.dart'
    if (dart.library.io) 'media_download_service_io.dart'
    as implementation;

class MediaDownloadService {
  MediaDownloadService({MediaDownloadBackend? backend})
    : _backend = backend ?? implementation.createMediaDownloadBackend();

  final MediaDownloadBackend _backend;
  final Map<String, MediaDownloadControl> _active = {};

  bool get supportsDownloads => implementation.mediaDownloadsSupported;

  Future<MediaDownloadResult> download({
    required String taskId,
    required String url,
    required String title,
    required Map<String, String> headers,
    required String format,
    String? temporaryPath,
    String? targetPath,
    String? etag,
    String? lastModified,
    void Function(MediaDownloadProgress progress)? onProgress,
  }) {
    if (_active.containsKey(taskId)) {
      return Future.value(
        const MediaDownloadResult(
          outcome: MediaDownloadOutcome.failed,
          message: '该任务已经在下载中',
        ),
      );
    }
    final control = MediaDownloadControl();
    _active[taskId] = control;
    return _backend
        .download(
          request: MediaDownloadRequest(
            taskId: taskId,
            url: url,
            title: title,
            headers: headers,
            format: format,
            temporaryPath: temporaryPath,
            targetPath: targetPath,
            etag: etag,
            lastModified: lastModified,
          ),
          control: control,
          onProgress: onProgress ?? (_) {},
        )
        .whenComplete(() {
          if (identical(_active[taskId], control)) {
            _active.remove(taskId);
          }
        });
  }

  bool pause(String taskId) {
    final control = _active[taskId];
    if (control == null) return false;
    control.pause();
    return true;
  }

  bool cancel(String taskId) {
    final control = _active[taskId];
    if (control == null) return false;
    control.cancel();
    return true;
  }

  bool isActive(String taskId) => _active.containsKey(taskId);

  Future<bool> fileExists(String? path) {
    if (path == null || path.trim().isEmpty) return Future.value(false);
    return _backend.fileExists(path);
  }

  Future<void> deleteFiles(Iterable<String?> paths) async {
    for (final path in paths) {
      if (path == null || path.trim().isEmpty) continue;
      await _backend.deleteFile(path);
    }
  }

  void dispose() {
    for (final control in _active.values) {
      control.pause();
    }
    _active.clear();
  }
}
