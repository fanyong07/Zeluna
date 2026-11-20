import 'dart:async';
import 'dart:io';

import 'package:anime/src/updates/app_update_download_io.dart';
import 'package:anime/src/updates/app_update_models.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'app_update_repository_test.dart' show StreamClient;

void main() {
  late Directory root;
  final data = List<int>.generate(65537, (i) => i % 251);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('zeluna-update-test-');
  });
  tearDown(() async {
    // This fixture exclusively owns the temporary directory returned above.
    await root.delete(recursive: true);
  });

  UpdateRelease release({String? hash, int? bytes}) => UpdateRelease(
    version: '1.3.2',
    buildNumber: 88,
    apkUri: Uri.parse('https://github.com/fanyong07/Zeluna/app.apk'),
    sha256: hash ?? sha256.convert(data).toString(),
    bytes: bytes ?? data.length,
    notes: '',
  );

  test(
    'streams bounded chunks to verified atomic filename and permits discard',
    () async {
      final client = StreamClient((request) async {
        expect(request.followRedirects, isFalse);
        return http.StreamedResponse(
          Stream.fromIterable([
            data.sublist(0, 100),
            data.sublist(100, 32768),
            data.sublist(32768),
          ]),
          200,
          contentLength: data.length,
        );
      });
      final downloader = IoAppUpdateDownloader(clientFactory: () => client);
      final progress = <UpdateProgress>[];
      final result = await downloader.download(
        release(),
        directory: root.path,
        cancellation: UpdateCancellation(),
        onProgress: progress.add,
      );
      expect(
        File(result).uri.pathSegments.last,
        'app-88-${release().sha256}.apk',
      );
      expect(await File(result).readAsBytes(), data);
      expect(await File('$result.part').exists(), isFalse);
      expect(progress.first.received, 0);
      expect(progress.last.received, data.length);
      expect(progress.every((p) => p.total == data.length), isTrue);
      expect(client.closed, isTrue);
      await downloader.discard(result);
      expect(await File(result).exists(), isFalse);
    },
  );

  test('size/hash mismatch never leaves final or partial APK', () async {
    final cases = [
      (release(hash: 'a' * 64), data, 'hash_mismatch'),
      (release(bytes: data.length + 1), data, 'size_mismatch'),
      (release(bytes: data.length - 1), data, 'size_mismatch'),
    ];
    for (final item in cases) {
      final client = StreamClient(
        (_) async => http.StreamedResponse(Stream.value(item.$2), 200),
      );
      await expectLater(
        IoAppUpdateDownloader(clientFactory: () => client).download(
          item.$1,
          directory: root.path,
          cancellation: UpdateCancellation(),
          onProgress: (_) {},
        ),
        throwsA(isA<UpdateFailure>().having((e) => e.code, 'code', item.$3)),
      );
      expect(await root.list().toList(), isEmpty);
      expect(client.closed, isTrue);
    }
  });

  test(
    'wrong content length and HTTP failures cancel body without writing',
    () async {
      for (final status in [200, 404]) {
        var cancelled = false;
        final body = StreamController<List<int>>(
          onCancel: () {
            cancelled = true;
          },
        );
        final client = StreamClient(
          (_) async => http.StreamedResponse(
            body.stream,
            status,
            contentLength: data.length + 1,
          ),
        );
        await expectLater(
          IoAppUpdateDownloader(clientFactory: () => client).download(
            release(),
            directory: root.path,
            cancellation: UpdateCancellation(),
            onProgress: (_) {},
          ),
          throwsA(isA<UpdateFailure>()),
        );
        expect(cancelled, isTrue);
        expect(await root.list().toList(), isEmpty);
        await body.close();
      }
    },
  );

  test(
    'cancel during streaming closes client, cancels body and removes own part',
    () async {
      final firstProgress = Completer<void>();
      var cancelled = false;
      final body = StreamController<List<int>>(
        onCancel: () {
          cancelled = true;
        },
      );
      final client = StreamClient(
        (_) async => http.StreamedResponse(body.stream, 200),
      );
      final token = UpdateCancellation();
      final pending = IoAppUpdateDownloader(clientFactory: () => client)
          .download(
            release(),
            directory: root.path,
            cancellation: token,
            onProgress: (progress) {
              if (progress.received > 0) firstProgress.complete();
            },
          );
      final assertion = expectLater(pending, throwsA(isA<UpdateCancelled>()));
      body.add(data.sublist(0, 100));
      await firstProgress.future;
      token.cancel();
      await assertion;
      expect(client.closed, isTrue);
      expect(cancelled, isTrue);
      expect(await root.list().toList(), isEmpty);
      await body.close();
    },
  );

  test(
    'cancel before HTTP headers is prompt and late response is cancelled',
    () async {
      final headers = Completer<http.StreamedResponse>();
      final sent = Completer<void>();
      final client = StreamClient((_) {
        sent.complete();
        return headers.future;
      });
      final token = UpdateCancellation();
      final pending = IoAppUpdateDownloader(clientFactory: () => client)
          .download(
            release(),
            directory: root.path,
            cancellation: token,
            onProgress: (_) {},
          );
      final assertion = expectLater(pending, throwsA(isA<UpdateCancelled>()));
      await sent.future;
      token.cancel();
      await assertion;
      expect(client.closed, isTrue);
      expect(await root.list().toList(), isEmpty);
      final cancelled = Completer<void>();
      final body = StreamController<List<int>>(onCancel: cancelled.complete);
      headers.complete(http.StreamedResponse(body.stream, 200));
      await cancelled.future;
      await body.close();
    },
  );

  test('cancel on final progress never publishes ready APK', () async {
    final token = UpdateCancellation();
    final client = StreamClient(
      (_) async => http.StreamedResponse(Stream.value(data), 200),
    );
    await expectLater(
      IoAppUpdateDownloader(clientFactory: () => client).download(
        release(),
        directory: root.path,
        cancellation: token,
        onProgress: (p) {
          if (p.received == p.total) token.cancel();
        },
      ),
      throwsA(isA<UpdateCancelled>()),
    );
    expect(await root.list().toList(), isEmpty);
  });

  test(
    'header, idle and total timeouts have fixed codes and remove partial file',
    () async {
      for (final phase in ['header', 'idle', 'total']) {
        final body = StreamController<List<int>>();
        final headers = Completer<http.StreamedResponse>();
        final client = StreamClient(
          (_) => phase == 'header'
              ? headers.future
              : Future.value(http.StreamedResponse(body.stream, 200)),
        );
        final downloader = IoAppUpdateDownloader(
          clientFactory: () => client,
          headerTimeout: Duration(milliseconds: phase == 'header' ? 30 : 1000),
          idleTimeout: Duration(milliseconds: phase == 'idle' ? 30 : 1000),
          totalTimeout: Duration(milliseconds: phase == 'total' ? 30 : 1000),
        );
        await expectLater(
          downloader.download(
            release(),
            directory: root.path,
            cancellation: UpdateCancellation(),
            onProgress: (_) {},
          ),
          throwsA(
            isA<UpdateFailure>().having(
              (e) => e.code,
              'code',
              'download_timeout',
            ),
          ),
        );
        expect(await root.list().toList(), isEmpty);
        expect(client.closed, isTrue);
        if (phase == 'header') {
          headers.complete(http.StreamedResponse(const Stream.empty(), 200));
        }
        if (phase != 'header') await body.close();
      }
    },
  );

  test('redirects preserve public HTTPS policy at each hop', () async {
    for (final target in [
      'https://cdn.example/app.apk',
      'http://cdn.example/app.apk',
      'https://127.0.0.1/app.apk',
    ]) {
      var requests = 0;
      final client = StreamClient((request) async {
        requests++;
        expect(request.followRedirects, isFalse);
        if (requests == 1) {
          return http.StreamedResponse(
            const Stream.empty(),
            302,
            headers: {'location': target},
          );
        }
        return http.StreamedResponse(Stream.value(data), 200);
      });
      final downloader = IoAppUpdateDownloader(clientFactory: () => client);
      final pending = downloader.download(
        release(),
        directory: root.path,
        cancellation: UpdateCancellation(),
        onProgress: (_) {},
      );
      if (target.startsWith('https://cdn.')) {
        await downloader.discard(await pending);
        expect(requests, 2);
      } else {
        await expectLater(pending, throwsA(isA<UpdateFailure>()));
        expect(requests, 1);
      }
    }
  });

  test(
    'discard accepts restored owned basename only under supplied directory',
    () async {
      final downloader = IoAppUpdateDownloader();
      final owned = File(
        '${root.path}${Platform.pathSeparator}app-88-${'b' * 64}.apk',
      );
      final other = File('${root.path}${Platform.pathSeparator}personal.txt');
      await owned.writeAsString('owned');
      await other.writeAsString('keep');
      await expectLater(
        downloader.discard(owned.path),
        throwsA(isA<UpdateFailure>()),
      );
      await downloader.discard(owned.path, directory: root.path);
      expect(await owned.exists(), isFalse);
      await expectLater(
        downloader.discard(other.path, directory: root.path),
        throwsA(isA<UpdateFailure>()),
      );
      expect(await other.readAsString(), 'keep');
    },
  );

  test(
    'bounded orphan cleanup deletes only matching partials, preserves old APK',
    () async {
      final old = File(
        '${root.path}${Platform.pathSeparator}app-87-${'b' * 64}.apk',
      );
      final part = File(
        '${root.path}${Platform.pathSeparator}app-86-${'c' * 64}.apk.part',
      );
      final unrelated = File('${root.path}${Platform.pathSeparator}keep.part');
      await old.writeAsString('installer may still read this');
      await part.writeAsString('orphan');
      await unrelated.writeAsString('keep');
      final client = StreamClient(
        (_) async => http.StreamedResponse(Stream.value(data), 200),
      );
      await IoAppUpdateDownloader(clientFactory: () => client).download(
        release(),
        directory: root.path,
        cancellation: UpdateCancellation(),
        onProgress: (_) {},
      );
      expect(await old.exists(), isTrue);
      expect(await part.exists(), isFalse);
      expect(await unrelated.exists(), isTrue);
    },
  );

  test(
    'directory node at owned file path is never removed or followed',
    () async {
      final path =
          '${root.path}${Platform.pathSeparator}app-88-${release().sha256}.apk.part';
      await Directory(path).create();
      await expectLater(
        IoAppUpdateDownloader().download(
          release(),
          directory: root.path,
          cancellation: UpdateCancellation(),
          onProgress: (_) {},
        ),
        throwsA(
          isA<UpdateFailure>().having((e) => e.code, 'code', 'storage_path'),
        ),
      );
      expect(await Directory(path).exists(), isTrue);
    },
  );
}
