import 'dart:async';
import 'dart:io';

import 'package:anime/src/data/media_download_result.dart';
import 'package:anime/src/data/media_download_service.dart';
import 'package:anime/src/data/media_download_service_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  test('single-file download pauses and resumes with HTTP Range', () async {
    final root = await Directory.systemTemp.createTemp('anime-download-test-');
    final bytes = List<int>.generate(192 * 1024, (index) => index % 251);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final ranges = <String?>[];
    final subscription = server.listen((request) {
      unawaited(_serveVideo(request, bytes, ranges));
    });
    addTearDown(() async {
      await subscription.cancel();
      await server.close(force: true);
      if (await root.exists()) await root.delete(recursive: true);
    });

    final service = MediaDownloadService(backend: _loopbackBackend(root));
    addTearDown(service.dispose);
    final url = 'http://${server.address.host}:${server.port}/video.mp4';
    var requestedPause = false;
    final paused = await service.download(
      taskId: 'pause-resume',
      url: url,
      title: 'Episode 1',
      headers: const {},
      format: 'MP4',
      onProgress: (progress) {
        if (!requestedPause && progress.downloadedBytes >= 24 * 1024) {
          requestedPause = true;
          service.pause('pause-resume');
        }
      },
    );

    expect(paused.outcome, MediaDownloadOutcome.paused);
    expect(paused.bytes, greaterThan(0));
    expect(paused.bytes, lessThan(bytes.length));
    expect(paused.temporaryPath, isNotNull);
    expect(await File(paused.temporaryPath!).exists(), isTrue);

    final completed = await service.download(
      taskId: 'pause-resume',
      url: url,
      title: 'Episode 1',
      headers: const {},
      format: 'MP4',
      temporaryPath: paused.temporaryPath,
      targetPath: paused.path,
      etag: paused.etag,
      lastModified: paused.lastModified,
    );

    expect(completed.outcome, MediaDownloadOutcome.completed);
    expect(completed.bytes, bytes.length);
    expect(await File(completed.path!).readAsBytes(), bytes);
    expect(ranges.first, isNull);
    expect(ranges.whereType<String>().single, 'bytes=${paused.bytes}-');
    expect(await File(paused.temporaryPath!).exists(), isFalse);
  });

  test('cancelling removes the partial file', () async {
    final root = await Directory.systemTemp.createTemp('anime-cancel-test-');
    final bytes = List<int>.generate(128 * 1024, (index) => index % 199);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) {
      unawaited(_serveVideo(request, bytes, <String?>[]));
    });
    addTearDown(() async {
      await subscription.cancel();
      await server.close(force: true);
      if (await root.exists()) await root.delete(recursive: true);
    });

    final service = MediaDownloadService(backend: _loopbackBackend(root));
    addTearDown(service.dispose);
    final result = await service.download(
      taskId: 'cancel',
      url: 'http://${server.address.host}:${server.port}/video.mp4',
      title: 'Episode 2',
      headers: const {},
      format: 'MP4',
      onProgress: (progress) {
        if (progress.downloadedBytes >= 24 * 1024) service.cancel('cancel');
      },
    );

    expect(result.outcome, MediaDownloadOutcome.cancelled);
    expect(result.bytes, 0);
    expect(await File(result.temporaryPath!).exists(), isFalse);
  });

  test(
    'cancelling from the final progress callback removes the file',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'anime-final-cancel-test-',
      );
      final bytes = List<int>.generate(32 * 1024, (index) => index % 193);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        request.response.headers.contentType = ContentType('video', 'mp4');
        request.response.headers.contentLength = bytes.length;
        request.response.add(bytes);
        await request.response.close();
      });
      addTearDown(() async {
        await subscription.cancel();
        await server.close(force: true);
        if (await root.exists()) await root.delete(recursive: true);
      });

      final service = MediaDownloadService(backend: _loopbackBackend(root));
      addTearDown(service.dispose);
      var cancelled = false;
      final result = await service.download(
        taskId: 'final-cancel',
        url: 'http://${server.address.host}:${server.port}/video.mp4',
        title: 'Final Cancel',
        headers: const {},
        format: 'MP4',
        onProgress: (progress) {
          if (!cancelled &&
              progress.totalBytes > 0 &&
              progress.downloadedBytes == progress.totalBytes) {
            cancelled = true;
            service.cancel('final-cancel');
          }
        },
      );

      expect(result.outcome, MediaDownloadOutcome.cancelled);
      expect(result.bytes, 0);
      expect(await root.list().toList(), isEmpty);
    },
  );

  test('changed resume validator never appends incompatible bytes', () async {
    final root = await Directory.systemTemp.createTemp('anime-etag-test-');
    final partial = File('${root.path}/validator.part');
    await partial.writeAsBytes(List<int>.filled(4096, 1));
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.contentType = ContentType('video', 'mp4');
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes 4096-8191/8192',
      );
      request.response.headers.set(HttpHeaders.etagHeader, '"video-v2"');
      request.response.headers.contentLength = 4096;
      request.response.add(List<int>.filled(4096, 2));
      await request.response.close();
    });
    addTearDown(() async {
      await subscription.cancel();
      await server.close(force: true);
      if (await root.exists()) await root.delete(recursive: true);
    });

    final service = MediaDownloadService(backend: _loopbackBackend(root));
    addTearDown(service.dispose);
    final result = await service.download(
      taskId: 'validator',
      url: 'http://${server.address.host}:${server.port}/video.mp4',
      title: 'Validator',
      headers: const {},
      format: 'MP4',
      temporaryPath: partial.path,
      etag: '"video-v1"',
    );

    expect(result.outcome, MediaDownloadOutcome.failed);
    expect(result.message, contains('从头重新下载'));
    expect(result.bytes, 0);
    expect(result.etag, '"video-v2"');
    expect(await partial.exists(), isFalse);
  });

  test('server ignoring Range safely restarts instead of appending', () async {
    final root = await Directory.systemTemp.createTemp('anime-range-reset-');
    final bytes = List<int>.generate(32 * 1024, (index) => index % 173);
    final partial = File('${root.path}/range-reset.part');
    await partial.writeAsBytes(List<int>.filled(4096, 255));
    String? receivedRange;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      receivedRange = request.headers.value(HttpHeaders.rangeHeader);
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType('video', 'mp4');
      request.response.headers.contentLength = bytes.length;
      request.response.add(bytes);
      await request.response.close();
    });
    addTearDown(() async {
      await subscription.cancel();
      await server.close(force: true);
      if (await root.exists()) await root.delete(recursive: true);
    });

    final service = MediaDownloadService(backend: _loopbackBackend(root));
    addTearDown(service.dispose);
    final result = await service.download(
      taskId: 'range-reset',
      url: 'http://${server.address.host}:${server.port}/video.mp4',
      title: 'Range Reset',
      headers: const {},
      format: 'MP4',
      temporaryPath: partial.path,
      etag: '"old"',
    );

    expect(receivedRange, 'bytes=4096-');
    expect(result.outcome, MediaDownloadOutcome.completed);
    expect(result.bytes, bytes.length);
    expect(await File(result.path!).readAsBytes(), bytes);
  });

  test('oversized partial file restarts after HTTP 416', () async {
    final root = await Directory.systemTemp.createTemp('anime-range-shrink-');
    final bytes = List<int>.generate(8 * 1024, (index) => index % 167);
    final partial = File('${root.path}/range-shrink.part');
    await partial.writeAsBytes(List<int>.filled(24 * 1024, 255));
    final ranges = <String?>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      final range = request.headers.value(HttpHeaders.rangeHeader);
      ranges.add(range);
      request.response.headers.contentType = ContentType('video', 'mp4');
      if (range != null) {
        request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes */${bytes.length}',
        );
        await request.response.close();
        return;
      }
      request.response.headers.contentLength = bytes.length;
      request.response.add(bytes);
      await request.response.close();
    });
    addTearDown(() async {
      await subscription.cancel();
      await server.close(force: true);
      if (await root.exists()) await root.delete(recursive: true);
    });

    final service = MediaDownloadService(backend: _loopbackBackend(root));
    addTearDown(service.dispose);
    final result = await service.download(
      taskId: 'range-shrink',
      url: 'http://${server.address.host}:${server.port}/video.mp4',
      title: 'Range Shrink',
      headers: const {},
      format: 'MP4',
      temporaryPath: partial.path,
    );

    expect(result.outcome, MediaDownloadOutcome.completed);
    expect(ranges, ['bytes=${24 * 1024}-', null]);
    expect(await File(result.path!).readAsBytes(), bytes);
    expect(await partial.exists(), isFalse);
  });

  test(
    'managed deletion rejects the download root and traversal paths',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'anime-delete-guard-root-',
      );
      final outside = await Directory.systemTemp.createTemp(
        'anime-delete-guard-outside-',
      );
      final rootSentinel = File(
        '${root.path}${Platform.pathSeparator}keep.txt',
      );
      final outsideSentinel = File(
        '${outside.path}${Platform.pathSeparator}outside.txt',
      );
      await rootSentinel.writeAsString('keep');
      await outsideSentinel.writeAsString('outside');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
        if (await outside.exists()) await outside.delete(recursive: true);
      });
      final service = MediaDownloadService(backend: _loopbackBackend(root));
      addTearDown(service.dispose);
      final outsideName = outside.path.split(Platform.pathSeparator).last;
      final traversal =
          '${root.path}${Platform.pathSeparator}..${Platform.pathSeparator}'
          '$outsideName${Platform.pathSeparator}outside.txt';

      await service.deleteFiles([root.path, traversal, outsideSentinel.path]);

      expect(await root.exists(), isTrue);
      expect(await rootSentinel.exists(), isTrue);
      expect(await outsideSentinel.exists(), isTrue);
      expect(await service.fileExists(root.path), isFalse);
      expect(await service.fileExists(traversal), isFalse);
    },
  );

  test('DASH URLs are rejected before creating a partial file', () async {
    final root = await Directory.systemTemp.createTemp('anime-dash-test-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final service = MediaDownloadService(backend: _loopbackBackend(root));
    addTearDown(service.dispose);

    final result = await service.download(
      taskId: 'dash',
      url: 'https://cdn.example/play?type=mpd',
      title: 'DASH',
      headers: const {},
      format: 'DASH',
    );

    expect(result.outcome, MediaDownloadOutcome.unsupported);
    expect(await root.list().toList(), isEmpty);
  });
}

IoMediaDownloadBackend _loopbackBackend(Directory root) =>
    IoMediaDownloadBackend(
      clientFactory: http.Client.new,
      directoryProvider: () async => root,
    );

Future<void> _serveVideo(
  HttpRequest request,
  List<int> bytes,
  List<String?> ranges,
) async {
  final range = request.headers.value(HttpHeaders.rangeHeader);
  ranges.add(range);
  var start = 0;
  if (range != null) {
    start = int.parse(RegExp(r'^bytes=(\d+)-$').firstMatch(range)!.group(1)!);
    request.response.statusCode = HttpStatus.partialContent;
    request.response.headers.set(
      HttpHeaders.contentRangeHeader,
      'bytes $start-${bytes.length - 1}/${bytes.length}',
    );
  }
  request.response.headers.contentType = ContentType('video', 'mp4');
  request.response.headers.contentLength = bytes.length - start;
  request.response.headers.set(HttpHeaders.etagHeader, '"video-v1"');
  try {
    for (var offset = start; offset < bytes.length; offset += 4096) {
      final end = (offset + 4096).clamp(0, bytes.length);
      request.response.add(bytes.sublist(offset, end));
      await request.response.flush();
      await Future<void>.delayed(const Duration(milliseconds: 14));
    }
    await request.response.close();
  } on HttpException {
    await request.response.close();
  } on SocketException {
    await request.response.close();
  }
}
