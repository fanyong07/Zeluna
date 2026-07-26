import 'media_download_backend.dart';
import 'media_download_result.dart';

bool get mediaDownloadsSupported => false;

MediaDownloadBackend createMediaDownloadBackend() => _StubDownloadBackend();

class _StubDownloadBackend implements MediaDownloadBackend {
  @override
  Future<MediaDownloadResult> download({
    required MediaDownloadRequest request,
    required MediaDownloadControl control,
    required void Function(MediaDownloadProgress progress) onProgress,
  }) async {
    return const MediaDownloadResult(
      outcome: MediaDownloadOutcome.unsupported,
      message: '网页版暂不支持离线下载，请使用桌面或移动客户端。',
    );
  }

  @override
  Future<void> deleteFile(String path) async {}

  @override
  Future<bool> fileExists(String path) async => false;
}
