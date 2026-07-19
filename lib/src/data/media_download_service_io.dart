import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'media_download_result.dart';

Future<MediaDownloadResult> downloadMedia({
  required String url,
  required String title,
  required Map<String, String> headers,
}) async {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme) {
    return const MediaDownloadResult(success: false, message: '下载地址无效');
  }
  final lowerPath = uri.path.toLowerCase();
  if (lowerPath.endsWith('.m3u8') || lowerPath.endsWith('.mpd')) {
    return const MediaDownloadResult(
      success: false,
      message: '当前离线下载先支持单文件视频，HLS/DASH 分片下载仍在完善。',
    );
  }

  final client = http.Client();
  File? output;
  IOSink? sink;
  try {
    final request = http.Request('GET', uri)..headers.addAll(headers);
    final response = await client
        .send(request)
        .timeout(const Duration(seconds: 30));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return MediaDownloadResult(
        success: false,
        message: '下载失败：HTTP ${response.statusCode}',
      );
    }

    final root = await getApplicationDocumentsDirectory();
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}anime_downloads',
    );
    await directory.create(recursive: true);
    final extension = _extensionOf(uri.path, response.headers['content-type']);
    final safeTitle = _safeFileName(title);
    output = File(
      '${directory.path}${Platform.pathSeparator}${safeTitle}_${DateTime.now().millisecondsSinceEpoch}$extension',
    );
    sink = output.openWrite();
    var bytes = 0;
    await for (final chunk in response.stream) {
      sink.add(chunk);
      bytes += chunk.length;
    }
    await sink.flush();
    await sink.close();
    sink = null;
    return MediaDownloadResult(
      success: true,
      message: '下载完成',
      path: output.path,
      bytes: bytes,
    );
  } on TimeoutException {
    return const MediaDownloadResult(success: false, message: '下载连接超时');
  } catch (error) {
    if (output != null && await output.exists()) await output.delete();
    return MediaDownloadResult(success: false, message: '下载失败：$error');
  } finally {
    await sink?.close();
    client.close();
  }
}

String _safeFileName(String value) {
  final cleaned = value.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  return cleaned.isEmpty ? 'video' : cleaned;
}

String _extensionOf(String path, String? contentType) {
  final match = RegExp(r'\.[a-zA-Z0-9]{2,5}$').firstMatch(path);
  if (match != null) return match.group(0)!.toLowerCase();
  final type = contentType?.toLowerCase() ?? '';
  if (type.contains('webm')) return '.webm';
  if (type.contains('matroska')) return '.mkv';
  if (type.contains('quicktime')) return '.mov';
  return '.mp4';
}
