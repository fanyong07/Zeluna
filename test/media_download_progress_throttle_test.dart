import 'dart:io';

import 'package:anime/src/data/media_download_result.dart';
import 'package:anime/src/data/media_download_service.dart';
import 'package:anime/src/data/media_download_service_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  test(
    'download progress is rate limited and completion is published',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'anime-progress-throttle-',
      );
      final bytes = List<int>.generate(120 * 1024, (index) => index % 251);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        request.response.headers.contentType = ContentType('video', 'mp4');
        request.response.headers.contentLength = bytes.length;
        for (var offset = 0; offset < bytes.length; offset += 2048) {
          final end = (offset + 2048).clamp(0, bytes.length);
          request.response.add(bytes.sublist(offset, end));
          await request.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await request.response.close();
      });
      addTearDown(() async {
        await subscription.cancel();
        await server.close(force: true);
        if (await root.exists()) await root.delete(recursive: true);
      });

      final service = MediaDownloadService(
        backend: IoMediaDownloadBackend(
          clientFactory: http.Client.new,
          directoryProvider: () async => root,
        ),
      );
      addTearDown(service.dispose);
      final publishedAt = <DateTime>[];
      final published = <MediaDownloadProgress>[];

      final result = await service.download(
        taskId: 'progress-throttle',
        url: 'http://${server.address.host}:${server.port}/video.mp4',
        title: 'Progress',
        headers: const {},
        format: 'MP4',
        onProgress: (progress) {
          publishedAt.add(DateTime.now());
          published.add(progress);
        },
      );
      final completedAt = DateTime.now();

      expect(result.outcome, MediaDownloadOutcome.completed);
      expect(published, isNotEmpty);
      expect(published.length, lessThanOrEqualTo(5));
      expect(published.last.downloadedBytes, bytes.length);
      expect(published.last.totalBytes, bytes.length);
      expect(
        completedAt.difference(publishedAt.last),
        lessThan(const Duration(milliseconds: 250)),
      );
    },
  );
}
