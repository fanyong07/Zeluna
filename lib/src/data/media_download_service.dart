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
    String? controlId,
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
    final activeId = controlId ?? taskId;
    if (_active.containsKey(activeId)) {
      return Future.value(
        const MediaDownloadResult(
          outcome: MediaDownloadOutcome.failed,
          message: '该任务已经在下载中',
        ),
      );
    }
    final control = MediaDownloadControl();
    _active[activeId] = control;
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
          if (identical(_active[activeId], control)) {
            _active.remove(activeId);
          }
        });
  }

  bool pause(String taskId, {String? controlId}) {
    final control = _active[controlId ?? taskId];
    if (control == null) return false;
    control.pause();
    return true;
  }

  bool cancel(String taskId, {String? controlId}) {
    final control = _active[controlId ?? taskId];
    if (control == null) return false;
    control.cancel();
    return true;
  }

  bool isActive(String taskId, {String? controlId}) =>
      _active.containsKey(controlId ?? taskId);

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
