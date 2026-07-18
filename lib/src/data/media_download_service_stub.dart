import 'media_download_result.dart';

Future<MediaDownloadResult> downloadMedia({
  required String url,
  required String title,
  required Map<String, String> headers,
}) async {
  return const MediaDownloadResult(
    success: false,
    message: '网页版暂不支持离线下载，请使用 Windows、Android、iOS、macOS 或 Linux 客户端。',
  );
}
