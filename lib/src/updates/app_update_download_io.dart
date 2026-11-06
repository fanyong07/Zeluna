import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;

import '../core/network/network_security.dart';
import 'app_update_download.dart';
import 'app_update_models.dart';
import 'app_update_repository.dart';

AppUpdateDownloader createAppUpdateDownloader({
  http.Client Function()? clientFactory,
}) => IoAppUpdateDownloader(clientFactory: clientFactory);

class IoAppUpdateDownloader implements AppUpdateDownloader {
  IoAppUpdateDownloader({
    http.Client Function()? clientFactory,
    this.headerTimeout = const Duration(seconds: 20),
    this.idleTimeout = const Duration(seconds: 30),
    this.totalTimeout = const Duration(minutes: 15),
  }) : _clientFactory = clientFactory;

  final http.Client Function()? _clientFactory;
  final Duration headerTimeout;
  final Duration idleTimeout;
  final Duration totalTimeout;
  final Set<String> _ownedDirectories = {};
  static final _ownedName = RegExp(
    r'^app-[1-9][0-9]*-[0-9a-f]{64}\.apk(?:\.part)?$',
  );

  @override
  Future<String> download(
    UpdateRelease release, {
    required String directory,
    required UpdateCancellation cancellation,
    required void Function(UpdateProgress) onProgress,
  }) async {
    cancellation.throwIfCancelled();
    final checked = UpdateRelease.fromJson(release.toJson());
    final operation = UpdateCancellation();
    var timedOut = false;
    http.Client? client;
    StreamIterator<List<int>>? iterator;
    RandomAccessFile? output;
    String? partPath;
    String? finalPath;
    var ownsPart = false;
    var ownsFinal = false;
    final aborted = Completer<http.StreamedResponse>();
    final unlinkParent = cancellation.register(operation.cancel);
    final unlinkTransport = operation.register(() {
      client?.close();
      final activeIterator = iterator;
      if (activeIterator != null) unawaited(activeIterator.cancel());
      if (!aborted.isCompleted) aborted.completeError(const UpdateCancelled());
    });
    // Observe cancellation even if it happens before the first HTTP await.
    unawaited(aborted.future.then<void>((_) {}, onError: (Object _) {}));
    final timer = Timer(totalTimeout, () {
      timedOut = true;
      operation.cancel();
    });
    try {
      final root = await _registerDirectory(directory);
      operation.throwIfCancelled();
      final basename = 'app-${checked.buildNumber}-${checked.sha256}.apk';
      finalPath = File.fromUri(Directory(root).uri.resolve(basename)).path;
      partPath = '$finalPath.part';
      await _removeOwnedFile(partPath);
      await _assertRegularOrMissing(finalPath);
      await _cleanOldFiles(root, basename);
      operation.throwIfCancelled();
      // Exclusive creation never follows a pre-existing symlink or other node.
      await File(partPath).create(exclusive: true);
      ownsPart = true;
      await _assertRegularOrMissing(partPath, mustExist: true);
      output = await File(partPath).open(mode: FileMode.writeOnly);
      operation.throwIfCancelled();
      final policy = NetworkRequestPolicy(
        service: NetworkServiceKind.metadataApi,
        httpsOnly: true,
        allowPrivateNetwork: false,
        maxResponseBytes: appUpdateMaxApkBytes,
        requestTimeout: headerTimeout,
        allowSyntheticDns: true,
        rejectRedirects: false,
      );
      client = createAppUpdateHttpClient(policy, clientFactory: _clientFactory);
      final request = http.Request('GET', checked.apkUri)
        ..headers.addAll(const {
          'user-agent': 'Zeluna-App-Updater',
          'accept': 'application/vnd.android.package-archive',
          'accept-encoding': 'identity',
        });
      final pendingResponse = client.send(request).then((response) async {
        if (operation.isCancelled) {
          await response.stream.listen(null).cancel();
          throw const UpdateCancelled();
        }
        return response;
      });
      final response = await Future.any([
        pendingResponse,
        aborted.future,
      ]).timeout(headerTimeout);
      if (operation.isCancelled ||
          response.statusCode != 200 ||
          (response.contentLength != null &&
              response.contentLength != checked.bytes)) {
        await response.stream.listen(null).cancel();
        operation.throwIfCancelled();
        if (response.statusCode != 200) {
          throw const UpdateFailure('download_http', '下载安装包失败，请稍后重试');
        }
        throw const UpdateFailure('size_mismatch', '安装包大小校验失败，请重新下载');
      }
      iterator = StreamIterator<List<int>>(
        response.stream.timeout(idleTimeout),
      );
      final digest = _DigestSink();
      final hashInput = crypto.sha256.startChunkedConversion(digest);
      var received = 0;
      onProgress(UpdateProgress(received: 0, total: checked.bytes));
      while (await iterator.moveNext()) {
        operation.throwIfCancelled();
        final chunk = iterator.current;
        received += chunk.length;
        if (received > checked.bytes) {
          throw const UpdateFailure('size_mismatch', '安装包大小校验失败，请重新下载');
        }
        hashInput.add(chunk);
        // Backpressure: at most one incoming chunk is pending a disk write.
        await output.writeFrom(chunk);
        operation.throwIfCancelled();
        onProgress(UpdateProgress(received: received, total: checked.bytes));
      }
      operation.throwIfCancelled();
      hashInput.close();
      if (received != checked.bytes) {
        throw const UpdateFailure('size_mismatch', '安装包大小校验失败，请重新下载');
      }
      if (digest.value.toString() != checked.sha256) {
        throw const UpdateFailure('hash_mismatch', '安装包完整性校验失败，请重新下载');
      }
      await output.flush();
      await output.close();
      output = null;
      operation.throwIfCancelled();
      await _assertRegularOrMissing(partPath, mustExist: true);
      await _assertRegularOrMissing(finalPath);
      operation.throwIfCancelled();
      await File(partPath).rename(finalPath);
      ownsPart = false;
      ownsFinal = true;
      operation.throwIfCancelled();
      return finalPath;
    } catch (error) {
      if (output != null) {
        try {
          await output.close();
        } catch (_) {}
        output = null;
      }
      if (ownsPart && partPath != null) await _bestEffortRemove(partPath);
      if (ownsFinal && finalPath != null) await _bestEffortRemove(finalPath);
      if (cancellation.isCancelled) throw const UpdateCancelled();
      if (timedOut || error is TimeoutException) {
        throw const UpdateFailure('download_timeout', '下载超时，请检查网络后重试');
      }
      if (error is UpdateFailure || error is UpdateCancelled) rethrow;
      if (error is FileSystemException) {
        throw const UpdateFailure('storage_error', '保存安装包失败，请检查可用空间后重试');
      }
      if (error is NetworkSecurityException) {
        throw const UpdateFailure('network_policy', '更新地址或响应不符合要求');
      }
      throw const UpdateFailure('download_network', '下载失败，请检查网络后重试');
    } finally {
      timer.cancel();
      unlinkParent();
      unlinkTransport();
      operation.cancel();
      if (iterator != null) await iterator.cancel();
      client?.close();
    }
  }

  @override
  Future<void> discard(String path, {String? directory}) async {
    try {
      if (directory != null) {
        final root = await _registerDirectory(directory);
        final parent = File.fromUri(
          File(path).absolute.uri.normalizePath(),
        ).parent;
        if (_key(parent.path) != _key(root)) {
          throw const UpdateFailure('storage_path', '安装包文件位置不正确');
        }
      }
      await _removeOwnedFile(path);
    } on UpdateFailure {
      rethrow;
    } on FileSystemException {
      throw const UpdateFailure('storage_error', '清理安装包失败，请稍后重试');
    }
  }

  Future<String> _registerDirectory(String path) async {
    final directory = Directory.fromUri(
      Directory(path).absolute.uri.normalizePath(),
    );
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const UpdateFailure('storage_directory', '更新目录不可用，请稍后重试');
    }
    final canonical = await directory.resolveSymbolicLinks();
    if (_key(canonical) != _key(directory.path)) {
      throw const UpdateFailure('storage_directory', '更新目录不可用，请稍后重试');
    }
    _ownedDirectories.add(_key(canonical));
    return canonical;
  }

  Future<void> _assertRegularOrMissing(
    String path, {
    bool mustExist = false,
  }) async {
    final file = File.fromUri(File(path).absolute.uri.normalizePath());
    final parent = file.parent;
    final name = file.uri.pathSegments.last;
    if (!_ownedDirectories.contains(_key(parent.path)) ||
        !_ownedName.hasMatch(name) ||
        _key(await parent.resolveSymbolicLinks()) != _key(parent.path)) {
      throw const UpdateFailure('storage_path', '安装包文件位置不正确');
    }
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type != FileSystemEntityType.file &&
        (mustExist || type != FileSystemEntityType.notFound)) {
      throw const UpdateFailure('storage_path', '安装包文件位置不正确');
    }
  }

  Future<void> _removeOwnedFile(String path) async {
    await _assertRegularOrMissing(path);
    if (await FileSystemEntity.type(path, followLinks: false) ==
        FileSystemEntityType.file) {
      await File(path).delete();
    }
  }

  Future<void> _bestEffortRemove(String path) async {
    try {
      await _removeOwnedFile(path);
    } catch (_) {}
  }

  Future<void> _cleanOldFiles(String root, String keep) async {
    var inspected = 0;
    var removed = 0;
    await for (final entry in Directory(root).list(followLinks: false)) {
      if (++inspected > 128 || removed >= 8) break;
      final name = entry.uri.pathSegments.last;
      if (entry is! File ||
          !_ownedName.hasMatch(name) ||
          !name.endsWith('.part') ||
          name == '$keep.part') {
        continue;
      }
      await _bestEffortRemove(entry.path);
      removed++;
    }
  }

  static String _key(String value) {
    final normalized = value
        .replaceAll('\\', '/')
        .replaceFirst(RegExp(r'/+$'), '');
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }
}

class _DigestSink implements Sink<crypto.Digest> {
  crypto.Digest? value;

  @override
  void add(crypto.Digest data) => value = data;

  @override
  void close() {}
}
