import 'media_download_result.dart';
import 'media_download_service_stub.dart'
    if (dart.library.io) 'media_download_service_io.dart'
    as implementation;

class MediaDownloadService {
  const MediaDownloadService();

  Future<MediaDownloadResult> download({
    required String url,
    required String title,
    required Map<String, String> headers,
  }) {
    return implementation.downloadMedia(
      url: url,
      title: title,
      headers: headers,
    );
  }
}
