import 'dart:io';

import 'package:anime/src/data/media_download_result.dart';
import 'package:anime/src/data/media_download_service.dart';
import 'package:anime/src/data/media_download_service_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'HLS master selects highest variant and rewrites MAP and BYTERANGE locally',
    () async {
      final root = await Directory.systemTemp.createTemp('anime-hls-master-');
      final media = List<int>.generate(16, (index) => index);
      final ranges = <String>[];
      var lowRequested = false;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        switch (request.uri.path) {
          case '/master.m3u8':
            await _text(request.response, '''#EXTM3U
#EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="cc",NAME="CC1",INSTREAM-ID="CC1"
#EXT-X-STREAM-INF:BANDWIDTH=500000,RESOLUTION=640x360
low/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1920x1080,CLOSED-CAPTIONS="cc"
high/index.m3u8
''');
          case '/low/index.m3u8':
            lowRequested = true;
            await _text(request.response, '#EXTM3U\n#EXT-X-ENDLIST\n');
          case '/high/index.m3u8':
            await _text(request.response, '''#EXTM3U
#EXT-X-VERSION:6
#EXT-X-TARGETDURATION:4
#EXT-X-MAP:URI="../media.mp4",BYTERANGE="4@0"
#EXTINF:4.0,
#EXT-X-BYTERANGE:4@4
../media.mp4
#EXTINF:4.0,
#EXT-X-BYTERANGE:4
../media.mp4
#EXT-X-ENDLIST
''');
          case '/media.mp4':
            final range = request.headers.value(HttpHeaders.rangeHeader)!;
            ranges.add(range);
            final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range)!;
            final start = int.parse(match.group(1)!);
            final end = int.parse(match.group(2)!);
            request.response.statusCode = HttpStatus.partialContent;
            request.response.headers.contentType = ContentType('video', 'mp4');
            request.response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes $start-$end/${media.length}',
            );
            request.response.headers.contentLength = end - start + 1;
            request.response.add(media.sublist(start, end + 1));
            await request.response.close();
          default:
            request.response.statusCode = HttpStatus.notFound;
            await request.response.close();
        }
      });
      addTearDown(() async {
        await subscription.cancel();
        await server.close(force: true);
        if (await root.exists()) await root.delete(recursive: true);
      });

      final service = MediaDownloadService(
        backend: IoMediaDownloadBackend(directoryProvider: () async => root),
      );
      addTearDown(service.dispose);
      final result = await service.download(
        taskId: 'master',
        url: 'http://${server.address.host}:${server.port}/master.m3u8',
        title: 'Master HLS',
        headers: const {},
        format: 'HLS',
      );

      expect(result.outcome, MediaDownloadOutcome.completed);
      expect(result.completedUnits, 3);
      expect(result.totalUnits, 3);
      expect(lowRequested, isFalse);
      expect(ranges, ['bytes=0-3', 'bytes=4-7', 'bytes=8-11']);
      final rootManifest = File(result.path!);
      expect(await rootManifest.exists(), isTrue);
      final rootPlaylist = await rootManifest.readAsString();
      expect(rootPlaylist, contains('video/index.m3u8'));
      expect(rootPlaylist, isNot(contains('CLOSED-CAPTIONS')));
      final videoDirectory = Directory(
        '${rootManifest.parent.path}${Platform.pathSeparator}video',
      );
      final localPlaylist = await File(
        '${videoDirectory.path}${Platform.pathSeparator}index.m3u8',
      ).readAsString();
      expect(localPlaylist, contains('segments/init_00000.mp4'));
      expect(localPlaylist, contains('segments/segment_000000.mp4'));
      expect(localPlaylist, isNot(contains('BYTERANGE')));
      expect(localPlaylist, isNot(contains('http://')));
      expect(
        await File(
          '${videoDirectory.path}${Platform.pathSeparator}segments${Platform.pathSeparator}init_00000.mp4',
        ).readAsBytes(),
        media.sublist(0, 4),
      );
      expect(
        await File(
          '${videoDirectory.path}${Platform.pathSeparator}segments${Platform.pathSeparator}segment_000001.mp4',
        ).readAsBytes(),
        media.sublist(8, 12),
      );
    },
  );

  test('HLS redirects resolve relative segments from the final URI', () async {
    final root = await Directory.systemTemp.createTemp('anime-hls-redirect-');
    final segment = List<int>.generate(4096, (index) => index % 181);
    final paths = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      paths.add(request.uri.path);
      switch (request.uri.path) {
        case '/start.m3u8':
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(
            HttpHeaders.locationHeader,
            '/cdn/path/vod.m3u8',
          );
          await request.response.close();
        case '/cdn/path/vod.m3u8':
          await _text(
            request.response,
            '#EXTM3U\n#EXTINF:4,\nsegment.ts\n#EXT-X-ENDLIST\n',
          );
        case '/cdn/path/segment.ts':
          await _segment(request, segment);
        default:
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
      }
    });
    addTearDown(() async {
      await subscription.cancel();
      await server.close(force: true);
      if (await root.exists()) await root.delete(recursive: true);
    });

    final service = MediaDownloadService(
      backend: IoMediaDownloadBackend(directoryProvider: () async => root),
    );
    addTearDown(service.dispose);
    final result = await service.download(
      taskId: 'redirect-hls',
      url: 'http://${server.address.host}:${server.port}/start.m3u8',
      title: 'Redirect HLS',
      headers: const {},
      format: 'HLS',
    );

    expect(
      result.outcome,
      MediaDownloadOutcome.completed,
      reason: '${result.message}; paths=$paths',
    );
    expect(paths, contains('/cdn/path/segment.ts'));
    expect(paths, isNot(contains('/segment.ts')));
    final localSegment = File(
      '${File(result.path!).parent.path}${Platform.pathSeparator}video${Platform.pathSeparator}segments${Platform.pathSeparator}segment_000000.ts',
    );
    expect(await localSegment.readAsBytes(), segment);
  });

  test('HLS segment pauses and resumes with Range', () async {
    final root = await Directory.systemTemp.createTemp('anime-hls-resume-');
    final segment = List<int>.generate(192 * 1024, (index) => index % 241);
    final ranges = <String?>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      if (request.uri.path == '/vod.m3u8') {
        await _text(request.response, '''#EXTM3U
#EXT-X-TARGETDURATION:10
#EXTINF:10.0,
segment.ts
#EXT-X-ENDLIST
''');
        return;
      }
      if (request.uri.path != '/segment.ts') {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final range = request.headers.value(HttpHeaders.rangeHeader);
      ranges.add(range);
      var start = 0;
      if (range != null) {
        start = int.parse(
          RegExp(r'^bytes=(\d+)-$').firstMatch(range)!.group(1)!,
        );
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-${segment.length - 1}/${segment.length}',
        );
      }
      request.response.headers.contentType = ContentType('video', 'mp2t');
      request.response.headers.contentLength = segment.length - start;
      request.response.headers.set(HttpHeaders.etagHeader, '"segment-v1"');
      try {
        for (var offset = start; offset < segment.length; offset += 4096) {
          final end = (offset + 4096).clamp(0, segment.length);
          request.response.add(segment.sublist(offset, end));
          await request.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 14));
        }
        await request.response.close();
      } on HttpException {
        await request.response.close();
      } on SocketException {
        await request.response.close();
      }
    });
    addTearDown(() async {
      await subscription.cancel();
      await server.close(force: true);
      if (await root.exists()) await root.delete(recursive: true);
    });

    final service = MediaDownloadService(
      backend: IoMediaDownloadBackend(directoryProvider: () async => root),
    );
    addTearDown(service.dispose);
    final url = 'http://${server.address.host}:${server.port}/vod.m3u8';
    var pauseRequested = false;
    final paused = await service.download(
      taskId: 'resume-hls',
      url: url,
      title: 'Resume HLS',
      headers: const {},
      format: 'HLS',
      onProgress: (progress) {
        if (!pauseRequested && progress.downloadedBytes >= 24 * 1024) {
          pauseRequested = true;
          service.pause('resume-hls');
        }
      },
    );

    expect(paused.outcome, MediaDownloadOutcome.paused, reason: paused.message);
    expect(paused.bytes, greaterThan(0));
    expect(paused.completedUnits, 0);
    expect(await Directory(paused.temporaryPath!).exists(), isTrue);

    final completed = await service.download(
      taskId: 'resume-hls',
      url: url,
      title: 'Resume HLS',
      headers: const {},
      format: 'HLS',
      temporaryPath: paused.temporaryPath,
      targetPath: paused.path,
      etag: paused.etag,
      lastModified: paused.lastModified,
    );

    expect(completed.outcome, MediaDownloadOutcome.completed);
    expect(completed.completedUnits, 1);
    expect(ranges.first, isNull);
    expect(ranges.whereType<String>().single, 'bytes=${paused.bytes}-');
    expect(await File(completed.path!).exists(), isTrue);
    expect(await Directory(paused.temporaryPath!).exists(), isFalse);
  });

  test('HLS oversized partial segment restarts after HTTP 416', () async {
    final root = await Directory.systemTemp.createTemp('anime-hls-shrink-');
    final firstVersion = List<int>.generate(96 * 1024, (index) => index % 229);
    final secondVersion = List<int>.generate(8 * 1024, (index) => index % 173);
    var version = 1;
    final ranges = <String?>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      if (request.uri.path == '/vod.m3u8') {
        await _text(
          request.response,
          '#EXTM3U\n#EXTINF:4,\nsegment.ts\n#EXT-X-ENDLIST\n',
        );
        return;
      }
      if (request.uri.path != '/segment.ts') {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final bytes = version == 1 ? firstVersion : secondVersion;
      final range = request.headers.value(HttpHeaders.rangeHeader);
      ranges.add(range);
      var start = 0;
      if (range != null) {
        start = int.parse(
          RegExp(r'^bytes=(\d+)-$').firstMatch(range)!.group(1)!,
        );
        if (start >= bytes.length) {
          request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes */${bytes.length}',
          );
          await request.response.close();
          return;
        }
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-${bytes.length - 1}/${bytes.length}',
        );
      }
      request.response.headers.contentType = ContentType('video', 'mp2t');
      request.response.headers.contentLength = bytes.length - start;
      try {
        for (var offset = start; offset < bytes.length; offset += 4096) {
          final end = (offset + 4096).clamp(0, bytes.length);
          request.response.add(bytes.sublist(offset, end));
          await request.response.flush();
          if (version == 1) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        }
        await request.response.close();
      } on HttpException {
        await request.response.close();
      } on SocketException {
        await request.response.close();
      }
    });
    addTearDown(() async {
      await subscription.cancel();
      await server.close(force: true);
      if (await root.exists()) await root.delete(recursive: true);
    });

    final service = MediaDownloadService(
      backend: IoMediaDownloadBackend(directoryProvider: () async => root),
    );
    addTearDown(service.dispose);
    final url = 'http://${server.address.host}:${server.port}/vod.m3u8';
    var pauseRequested = false;
    final paused = await service.download(
      taskId: 'shrink-hls',
      url: url,
      title: 'Shrink HLS',
      headers: const {},
      format: 'HLS',
      onProgress: (progress) {
        if (!pauseRequested && progress.downloadedBytes >= 24 * 1024) {
          pauseRequested = true;
          service.pause('shrink-hls');
        }
      },
    );
    expect(paused.outcome, MediaDownloadOutcome.paused);
    expect(paused.bytes, greaterThan(secondVersion.length));

    version = 2;
    final completed = await service.download(
      taskId: 'shrink-hls',
      url: url,
      title: 'Shrink HLS',
      headers: const {},
      format: 'HLS',
      temporaryPath: paused.temporaryPath,
      targetPath: paused.path,
      etag: paused.etag,
      lastModified: paused.lastModified,
    );

    expect(completed.outcome, MediaDownloadOutcome.completed);
    expect(ranges.whereType<String>(), ['bytes=${paused.bytes}-']);
    expect(ranges.last, isNull);
    final localSegment = File(
      '${File(completed.path!).parent.path}${Platform.pathSeparator}video${Platform.pathSeparator}segments${Platform.pathSeparator}segment_000000.ts',
    );
    expect(await localSegment.readAsBytes(), secondVersion);
  });

  test(
    'media playlist ETag change discards completed HLS segments',
    () => _expectPlaylistValidatorChangeResetsPackage(
      changeMaster: false,
      useLastModified: false,
    ),
  );

  test(
    'master playlist Last-Modified change discards completed HLS segments',
    () => _expectPlaylistValidatorChangeResetsPackage(
      changeMaster: true,
      useLastModified: true,
    ),
  );

  test(
    'HLS managed paths reject the download root and parent traversal',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'anime-hls-path-safety-',
      );
      final root = Directory(
        '${workspace.path}${Platform.pathSeparator}downloads',
      );
      final outside = Directory(
        '${workspace.path}${Platform.pathSeparator}outside',
      );
      await root.create(recursive: true);
      await outside.create(recursive: true);
      final rootSentinel = File(
        '${root.path}${Platform.pathSeparator}keep-root.txt',
      );
      final outsideSentinel = File(
        '${outside.path}${Platform.pathSeparator}keep-outside.txt',
      );
      await rootSentinel.writeAsString('root');
      await outsideSentinel.writeAsString('outside');

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        if (request.uri.path == '/vod.m3u8') {
          await _text(
            request.response,
            '#EXTM3U\n#EXTINF:4,\nsegment.ts\n#EXT-X-ENDLIST\n',
          );
          return;
        }
        if (request.uri.path == '/segment.ts') {
          await _segment(request, List<int>.generate(64, (index) => index));
          return;
        }
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      });
      addTearDown(() async {
        await subscription.cancel();
        await server.close(force: true);
        if (await workspace.exists()) await workspace.delete(recursive: true);
      });

      final service = MediaDownloadService(
        backend: IoMediaDownloadBackend(directoryProvider: () async => root),
      );
      addTearDown(service.dispose);
      final url = 'http://${server.address.host}:${server.port}/vod.m3u8';

      final rootPathResult = await service.download(
        taskId: 'root-path',
        url: url,
        title: 'Root Path',
        headers: const {},
        format: 'HLS',
        temporaryPath: root.path,
      );
      expect(
        rootPathResult.outcome,
        MediaDownloadOutcome.completed,
        reason: rootPathResult.message,
      );
      expect(await rootSentinel.exists(), isTrue);

      final traversalPath =
          '${root.path}${Platform.pathSeparator}nested${Platform.pathSeparator}..${Platform.pathSeparator}..${Platform.pathSeparator}outside';
      final traversalResult = await service.download(
        taskId: 'traversal-path',
        url: url,
        title: 'Traversal Path',
        headers: const {},
        format: 'HLS',
        temporaryPath: traversalPath,
      );
      expect(
        traversalResult.outcome,
        MediaDownloadOutcome.completed,
        reason: traversalResult.message,
      );
      expect(await rootSentinel.exists(), isTrue);
      expect(await outsideSentinel.exists(), isTrue);
    },
  );

  test('cancelling HLS removes its partial package', () async {
    final root = await Directory.systemTemp.createTemp('anime-hls-cancel-');
    final segment = List<int>.generate(96 * 1024, (index) => index % 211);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      if (request.uri.path == '/cancel.m3u8') {
        await _text(
          request.response,
          '#EXTM3U\n#EXTINF:5,\nsegment.ts\n#EXT-X-ENDLIST\n',
        );
        return;
      }
      request.response.headers.contentType = ContentType('video', 'mp2t');
      request.response.headers.contentLength = segment.length;
      try {
        for (var offset = 0; offset < segment.length; offset += 4096) {
          final end = (offset + 4096).clamp(0, segment.length);
          request.response.add(segment.sublist(offset, end));
          await request.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 14));
        }
        await request.response.close();
      } on HttpException {
        await request.response.close();
      } on SocketException {
        await request.response.close();
      }
    });
    addTearDown(() async {
      await subscription.cancel();
      await server.close(force: true);
      if (await root.exists()) await root.delete(recursive: true);
    });

    final service = MediaDownloadService(
      backend: IoMediaDownloadBackend(directoryProvider: () async => root),
    );
    addTearDown(service.dispose);
    var cancelRequested = false;
    final result = await service.download(
      taskId: 'cancel-hls',
      url: 'http://${server.address.host}:${server.port}/cancel.m3u8',
      title: 'Cancel HLS',
      headers: const {},
      format: 'HLS',
      onProgress: (progress) {
        if (!cancelRequested && progress.downloadedBytes >= 16 * 1024) {
          cancelRequested = true;
          service.cancel('cancel-hls');
        }
      },
    );

    expect(result.outcome, MediaDownloadOutcome.cancelled);
    expect(result.bytes, 0);
    expect(
      await root
          .list()
          .where((entity) => entity.path.endsWith('.hls.part'))
          .toList(),
      isEmpty,
    );
  });

  test(
    'cancelling HLS from final progress removes the completed package',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'anime-hls-final-cancel-',
      );
      final segment = List<int>.generate(16 * 1024, (index) => index % 197);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        if (request.uri.path == '/vod.m3u8') {
          await _text(
            request.response,
            '#EXTM3U\n#EXTINF:4,\nsegment.ts\n#EXT-X-ENDLIST\n',
          );
          return;
        }
        await _segment(request, segment);
      });
      addTearDown(() async {
        await subscription.cancel();
        await server.close(force: true);
        if (await root.exists()) await root.delete(recursive: true);
      });

      final service = MediaDownloadService(
        backend: IoMediaDownloadBackend(directoryProvider: () async => root),
      );
      addTearDown(service.dispose);
      var cancelled = false;
      final result = await service.download(
        taskId: 'final-cancel-hls',
        url: 'http://${server.address.host}:${server.port}/vod.m3u8',
        title: 'Final Cancel HLS',
        headers: const {},
        format: 'HLS',
        onProgress: (progress) {
          if (!cancelled &&
              progress.totalUnits == 1 &&
              progress.completedUnits == 1) {
            cancelled = true;
            service.cancel('final-cancel-hls');
          }
        },
      );

      expect(result.outcome, MediaDownloadOutcome.cancelled);
      expect(result.bytes, 0);
      expect(await root.list().toList(), isEmpty);
    },
  );

  test('HLS rejects HTML error pages returned as media segments', () async {
    final root = await Directory.systemTemp.createTemp('anime-hls-html-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      if (request.uri.path == '/vod.m3u8') {
        await _text(
          request.response,
          '#EXTM3U\n#EXTINF:4,\nsegment.ts\n#EXT-X-ENDLIST\n',
        );
        return;
      }
      if (request.uri.path == '/segment.ts') {
        final bytes = '<html>authorization required</html>'.codeUnits;
        request.response.headers.contentType = ContentType.html;
        request.response.headers.contentLength = bytes.length;
        request.response.add(bytes);
        await request.response.close();
        return;
      }
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    });
    addTearDown(() async {
      await subscription.cancel();
      await server.close(force: true);
      if (await root.exists()) await root.delete(recursive: true);
    });

    final service = MediaDownloadService(
      backend: IoMediaDownloadBackend(directoryProvider: () async => root),
    );
    addTearDown(service.dispose);
    final result = await service.download(
      taskId: 'html-segment',
      url: 'http://${server.address.host}:${server.port}/vod.m3u8',
      title: 'HTML Segment',
      headers: const {},
      format: 'HLS',
    );

    expect(result.outcome, MediaDownloadOutcome.failed);
    expect(result.message, contains('不是媒体内容'));
    expect(await File(result.path!).exists(), isFalse);
  });

  test('live and encrypted HLS playlists are rejected clearly', () async {
    final root = await Directory.systemTemp.createTemp('anime-hls-reject-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      final playlist = switch (request.uri.path) {
        '/live.m3u8' => '#EXTM3U\n#EXTINF:4,\nsegment.ts\n',
        '/aes.m3u8' =>
          '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n#EXTINF:4,\nsegment.ts\n#EXT-X-ENDLIST\n',
        '/sample.m3u8' =>
          '#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI="key.bin"\n#EXTINF:4,\nsegment.ts\n#EXT-X-ENDLIST\n',
        _ => null,
      };
      if (playlist == null) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      } else {
        await _text(request.response, playlist);
      }
    });
    addTearDown(() async {
      await subscription.cancel();
      await server.close(force: true);
      if (await root.exists()) await root.delete(recursive: true);
    });

    final service = MediaDownloadService(
      backend: IoMediaDownloadBackend(directoryProvider: () async => root),
    );
    addTearDown(service.dispose);
    Future<MediaDownloadResult> download(String path, String id) =>
        service.download(
          taskId: id,
          url: 'http://${server.address.host}:${server.port}/$path',
          title: id,
          headers: const {},
          format: 'HLS',
        );

    final live = await download('live.m3u8', 'live');
    final aes = await download('aes.m3u8', 'aes');
    final sample = await download('sample.m3u8', 'sample');

    expect(live.outcome, MediaDownloadOutcome.unsupported);
    expect(live.message, contains('直播'));
    expect(aes.outcome, MediaDownloadOutcome.unsupported);
    expect(aes.message, contains('AES-128'));
    expect(sample.outcome, MediaDownloadOutcome.unsupported);
    expect(sample.message, contains('SAMPLE-AES'));
  });
}

Future<void> _expectPlaylistValidatorChangeResetsPackage({
  required bool changeMaster,
  required bool useLastModified,
}) async {
  final root = await Directory.systemTemp.createTemp(
    'anime-hls-playlist-validator-',
  );
  final firstVersion = List<int>.filled(16 * 1024, 1);
  final secondVersion = List<int>.filled(16 * 1024, 2);
  final longFirstVersion = List<int>.filled(256 * 1024, 11);
  final longSecondVersion = List<int>.filled(256 * 1024, 22);
  var version = 1;
  var firstSegmentRequests = 0;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final subscription = server.listen((request) async {
    final responseVersion = version;
    switch (request.uri.path) {
      case '/master.m3u8':
        await _text(
          request.response,
          '''#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=1000000
media.m3u8
''',
          etag: changeMaster || useLastModified ? null : '"master-stable"',
          lastModified: changeMaster && useLastModified
              ? responseVersion == 1
                    ? 'Wed, 01 Jul 2026 00:00:00 GMT'
                    : 'Thu, 02 Jul 2026 00:00:00 GMT'
              : null,
        );
      case '/media.m3u8':
        await _text(
          request.response,
          '''#EXTM3U
#EXT-X-TARGETDURATION:10
#EXTINF:4,
segment-0.ts
#EXTINF:10,
segment-1.ts
#EXT-X-ENDLIST
''',
          etag: !changeMaster && !useLastModified
              ? '"media-v$responseVersion"'
              : '"media-stable"',
        );
      case '/segment-0.ts':
        firstSegmentRequests++;
        await _segment(
          request,
          responseVersion == 1 ? firstVersion : secondVersion,
          etag: '"segment-0-v$responseVersion"',
        );
      case '/segment-1.ts':
        await _segment(
          request,
          responseVersion == 1 ? longFirstVersion : longSecondVersion,
          etag: '"segment-1-v$responseVersion"',
          slow: true,
        );
      default:
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
    }
  });
  addTearDown(() async {
    await subscription.cancel();
    await server.close(force: true);
    if (await root.exists()) await root.delete(recursive: true);
  });

  final service = MediaDownloadService(
    backend: IoMediaDownloadBackend(directoryProvider: () async => root),
  );
  addTearDown(service.dispose);
  final url = 'http://${server.address.host}:${server.port}/master.m3u8';
  var pauseRequested = false;
  final paused = await service.download(
    taskId: changeMaster ? 'master-validator' : 'media-validator',
    url: url,
    title: 'Validator HLS',
    headers: const {},
    format: 'HLS',
    onProgress: (progress) {
      if (!pauseRequested &&
          progress.completedUnits == 1 &&
          progress.downloadedBytes >= firstVersion.length + 24 * 1024) {
        pauseRequested = true;
        service.pause(changeMaster ? 'master-validator' : 'media-validator');
      }
    },
  );

  expect(paused.outcome, MediaDownloadOutcome.paused);
  expect(paused.completedUnits, 1);
  expect(firstSegmentRequests, 1);
  version = 2;

  final completed = await service.download(
    taskId: changeMaster ? 'master-validator' : 'media-validator',
    url: url,
    title: 'Validator HLS',
    headers: const {},
    format: 'HLS',
    temporaryPath: paused.temporaryPath,
    targetPath: paused.path,
    etag: paused.etag,
    lastModified: paused.lastModified,
  );

  expect(completed.outcome, MediaDownloadOutcome.completed);
  expect(firstSegmentRequests, 2);
  final localFirstSegment = File(
    '${File(completed.path!).parent.path}${Platform.pathSeparator}video${Platform.pathSeparator}segments${Platform.pathSeparator}segment_000000.ts',
  );
  expect(await localFirstSegment.readAsBytes(), secondVersion);
}

Future<void> _segment(
  HttpRequest request,
  List<int> bytes, {
  String? etag,
  bool slow = false,
}) async {
  final range = request.headers.value(HttpHeaders.rangeHeader);
  var start = 0;
  if (range != null) {
    start = int.parse(RegExp(r'^bytes=(\d+)-$').firstMatch(range)!.group(1)!);
    request.response.statusCode = HttpStatus.partialContent;
    request.response.headers.set(
      HttpHeaders.contentRangeHeader,
      'bytes $start-${bytes.length - 1}/${bytes.length}',
    );
  }
  request.response.headers.contentType = ContentType('video', 'mp2t');
  request.response.headers.contentLength = bytes.length - start;
  if (etag != null) {
    request.response.headers.set(HttpHeaders.etagHeader, etag);
  }
  try {
    for (var offset = start; offset < bytes.length; offset += 4096) {
      final end = (offset + 4096).clamp(0, bytes.length);
      request.response.add(bytes.sublist(offset, end));
      if (slow) {
        await request.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 14));
      }
    }
    await request.response.close();
  } on HttpException {
    await request.response.close();
  } on SocketException {
    await request.response.close();
  }
}

Future<void> _text(
  HttpResponse response,
  String value, {
  String? etag,
  String? lastModified,
}) async {
  final bytes = value.codeUnits;
  response.headers.contentType = ContentType(
    'application',
    'vnd.apple.mpegurl',
    charset: 'utf-8',
  );
  if (etag != null) response.headers.set(HttpHeaders.etagHeader, etag);
  if (lastModified != null) {
    response.headers.set(HttpHeaders.lastModifiedHeader, lastModified);
  }
  response.headers.contentLength = bytes.length;
  response.add(bytes);
  await response.close();
}
