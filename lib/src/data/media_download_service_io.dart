import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../core/network/network_http_client.dart';
import 'media_download_backend.dart';
import 'media_download_hls_io.dart';
import 'media_download_result.dart';
import 'media_download_storage_io.dart';

bool get mediaDownloadsSupported => true;

MediaDownloadBackend createMediaDownloadBackend() => IoMediaDownloadBackend();

class IoMediaDownloadBackend implements MediaDownloadBackend {
  IoMediaDownloadBackend({
    http.Client Function()? clientFactory,
    Future<Directory> Function()? directoryProvider,
    DownloadAvailableBytesProvider? availableBytesProvider,
  }) : _clientFactory = clientFactory ?? createMediaDownloadHttpClient,
       _directoryProvider = directoryProvider ?? _defaultDirectory,
       _availableBytesProvider =
           availableBytesProvider ?? platformAvailableDownloadBytes;

  final http.Client Function() _clientFactory;
  final Future<Directory> Function() _directoryProvider;
  final DownloadAvailableBytesProvider _availableBytesProvider;

  @override
  Future<MediaDownloadResult> download({
    required MediaDownloadRequest request,
    required MediaDownloadControl control,
    required void Function(MediaDownloadProgress progress) onProgress,
  }) async {
    final uri = Uri.tryParse(request.url.trim());
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return const MediaDownloadResult(
        outcome: MediaDownloadOutcome.failed,
        message: '下载地址无效',
      );
    }
    if (_looksLikeDashMedia(uri, request.format)) {
      return const MediaDownloadResult(
        outcome: MediaDownloadOutcome.unsupported,
        message: '该线路不支持离线下载',
      );
    }
    if (_looksLikeHlsMedia(uri, request.format)) {
      return downloadHlsMedia(
        request: request,
        control: control,
        onProgress: onProgress,
        clientFactory: _clientFactory,
        directoryProvider: _directoryProvider,
        availableBytesProvider: _availableBytesProvider,
      );
    }
    final progressDispatcher = _DownloadProgressDispatcher(onProgress);

    final directory = await _directoryProvider();
    await directory.create(recursive: true);
    final safeId = _safeFileName(request.taskId, maxLength: 60);
    final suppliedTemporary = await _managedFile(
      directory,
      request.temporaryPath,
    );
    final temporary =
        suppliedTemporary ??
        File('${directory.path}${Platform.pathSeparator}$safeId.part');
    var existingBytes = await temporary.exists() ? await temporary.length() : 0;
    final client = _clientFactory();
    IOSink? sink;
    StreamIterator<List<int>>? iterator;
    var target = await _managedFile(directory, request.targetPath);
    var totalBytes = 0;
    String? etag = request.etag;
    String? lastModified = request.lastModified;

    MediaDownloadResult stoppedResult() {
      final outcome = control.reason == MediaDownloadStopReason.cancel
          ? MediaDownloadOutcome.cancelled
          : MediaDownloadOutcome.paused;
      return MediaDownloadResult(
        outcome: outcome,
        message: outcome == MediaDownloadOutcome.cancelled ? '下载已取消' : '下载已暂停',
        path: target?.path,
        temporaryPath: temporary.path,
        bytes: existingBytes,
        totalBytes: totalBytes,
        etag: etag,
        lastModified: lastModified,
      );
    }

    void emitProgress({bool force = false}) {
      progressDispatcher.add(
        MediaDownloadProgress(
          downloadedBytes: existingBytes,
          totalBytes: totalBytes,
          temporaryPath: temporary.path,
          targetPath: target?.path ?? '',
          etag: etag,
          lastModified: lastModified,
        ),
        force: force,
      );
    }

    Future<MediaDownloadResult?> stoppedIfRequested({
      File? finalizedFile,
    }) async {
      if (!control.isStopped) return null;
      if (control.reason == MediaDownloadStopReason.cancel) {
        if (await temporary.exists()) await temporary.delete();
        if (finalizedFile != null && await finalizedFile.exists()) {
          await finalizedFile.delete();
        }
        existingBytes = 0;
      } else if (finalizedFile != null && await finalizedFile.exists()) {
        if (await temporary.exists()) await temporary.delete();
        await finalizedFile.rename(temporary.path);
      }
      emitProgress(force: true);
      return stoppedResult();
    }

    try {
      final initiallyStopped = await stoppedIfRequested();
      if (initiallyStopped != null) return initiallyStopped;

      final headers = _requestHeaders(request.headers);
      if (existingBytes > 0) {
        headers['Range'] = 'bytes=$existingBytes-';
        final validator = _ifRangeValidator(request.etag, request.lastModified);
        if (validator != null && validator.trim().isNotEmpty) {
          headers['If-Range'] = validator;
        }
      }
      final httpRequest = http.Request('GET', uri)..headers.addAll(headers);
      final sendFuture = client
          .send(httpRequest)
          .timeout(const Duration(seconds: 30));
      final responseOrStop = await Future.any<Object>([
        sendFuture,
        control.whenStopped,
      ]);
      if (responseOrStop is MediaDownloadStopReason) {
        client.close();
        if (responseOrStop == MediaDownloadStopReason.cancel &&
            await temporary.exists()) {
          await temporary.delete();
          existingBytes = 0;
        }
        return stoppedResult();
      }
      final response = responseOrStop as http.StreamedResponse;
      final responseEtag = response.headers['etag'];
      final responseLastModified = response.headers['last-modified'];
      final validatorChanged =
          existingBytes > 0 &&
          response.statusCode == HttpStatus.partialContent &&
          _resumeValidatorChanged(
            requestEtag: request.etag,
            requestLastModified: request.lastModified,
            responseEtag: responseEtag,
            responseLastModified: responseLastModified,
          );
      etag = responseEtag ?? etag;
      lastModified = responseLastModified ?? lastModified;
      if (validatorChanged) {
        if (await temporary.exists()) await temporary.delete();
        existingBytes = 0;
        return MediaDownloadResult(
          outcome: MediaDownloadOutcome.failed,
          message: '远端文件已经更新，将从头重新下载',
          path: target?.path,
          temporaryPath: temporary.path,
          bytes: 0,
          totalBytes: 0,
          etag: etag,
          lastModified: lastModified,
        );
      }

      if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable &&
          existingBytes > 0) {
        final remoteLength = _unsatisfiedRangeLength(
          response.headers['content-range'],
        );
        if (remoteLength == existingBytes) {
          target ??= _targetFile(directory, request, uri, response.headers);
          await recoverInterruptedFileCommit(target);
          if (await temporary.length() != existingBytes) {
            return MediaDownloadResult(
              outcome: MediaDownloadOutcome.failed,
              message: '临时文件大小不一致，请重新下载',
              path: target.path,
              temporaryPath: temporary.path,
              bytes: existingBytes,
              totalBytes: existingBytes,
              etag: etag,
              lastModified: lastModified,
            );
          }
          final stoppedBeforeFinalize = await stoppedIfRequested();
          if (stoppedBeforeFinalize != null) return stoppedBeforeFinalize;
          final stoppedBeforeRename = await stoppedIfRequested();
          if (stoppedBeforeRename != null) return stoppedBeforeRename;
          await atomicReplaceFile(temporary, target);
          emitProgress(force: true);
          final stoppedAfterFinalize = await stoppedIfRequested(
            finalizedFile: target,
          );
          if (stoppedAfterFinalize != null) return stoppedAfterFinalize;
          return MediaDownloadResult(
            outcome: MediaDownloadOutcome.completed,
            message: '下载完成',
            path: target.path,
            temporaryPath: null,
            bytes: existingBytes,
            totalBytes: existingBytes,
            etag: etag,
            lastModified: lastModified,
          );
        }
        if (remoteLength != null && remoteLength < existingBytes) {
          if (await temporary.exists()) await temporary.delete();
          existingBytes = 0;
          emitProgress(force: true);
          final stoppedBeforeRestart = await stoppedIfRequested();
          if (stoppedBeforeRestart != null) return stoppedBeforeRestart;
          client.close();
          return await download(
            request: request,
            control: control,
            onProgress: onProgress,
          );
        }
      }

      if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.partialContent) {
        return MediaDownloadResult(
          outcome: MediaDownloadOutcome.failed,
          message: '下载失败：HTTP ${response.statusCode}',
          path: target?.path,
          temporaryPath: temporary.path,
          bytes: existingBytes,
          totalBytes: totalBytes,
          etag: etag,
          lastModified: lastModified,
        );
      }

      final contentType = response.headers['content-type']?.toLowerCase() ?? '';
      if (_isSegmentedContentType(contentType)) {
        return MediaDownloadResult(
          outcome: MediaDownloadOutcome.unsupported,
          message: '该线路不支持离线下载',
          temporaryPath: temporary.path,
          bytes: existingBytes,
          etag: etag,
          lastModified: lastModified,
        );
      }
      if (_isUnexpectedDocument(contentType)) {
        return MediaDownloadResult(
          outcome: MediaDownloadOutcome.failed,
          message: '该线路返回的不是视频文件',
          temporaryPath: temporary.path,
          bytes: existingBytes,
          etag: etag,
          lastModified: lastModified,
        );
      }

      final partialResponse = response.statusCode == HttpStatus.partialContent;
      if (partialResponse) {
        final rangeStart = _satisfiedRangeStart(
          response.headers['content-range'],
        );
        if (rangeStart != existingBytes) {
          return MediaDownloadResult(
            outcome: MediaDownloadOutcome.failed,
            message: '服务器返回的续传范围不正确，请重新下载',
            temporaryPath: temporary.path,
            bytes: existingBytes,
            etag: etag,
            lastModified: lastModified,
          );
        }
      }
      var append = existingBytes > 0 && partialResponse;
      if (!partialResponse && existingBytes > 0) {
        existingBytes = 0;
        append = false;
      }

      totalBytes = _responseTotalBytes(response, existingBytes);
      target ??= _targetFile(directory, request, uri, response.headers);
      await recoverInterruptedFileCommit(target);
      await ensureDownloadCapacity(
        directory: directory,
        requiredBytes: totalBytes > 0
            ? (totalBytes - existingBytes).clamp(0, totalBytes).toInt()
            : 0,
        availableBytesProvider: _availableBytesProvider,
      );
      final outputSink = temporary.openWrite(
        mode: append ? FileMode.append : FileMode.write,
      );
      sink = outputSink;
      emitProgress(force: true);
      iterator = StreamIterator<List<int>>(
        response.stream.timeout(const Duration(seconds: 30)),
      );
      while (true) {
        final nextOrStop = await Future.any<Object>([
          iterator.moveNext(),
          control.whenStopped,
        ]);
        if (nextOrStop is MediaDownloadStopReason) {
          await iterator.cancel();
          await outputSink.flush();
          await outputSink.close();
          sink = null;
          if (nextOrStop == MediaDownloadStopReason.cancel &&
              await temporary.exists()) {
            await temporary.delete();
            existingBytes = 0;
          }
          emitProgress(force: true);
          return stoppedResult();
        }
        if (nextOrStop == false) break;
        final chunk = iterator.current;
        outputSink.add(chunk);
        existingBytes += chunk.length;
        emitProgress();
      }
      await outputSink.flush();
      await outputSink.close();
      sink = null;
      final storedLength = await temporary.length();
      if (storedLength != existingBytes) {
        return MediaDownloadResult(
          outcome: MediaDownloadOutcome.failed,
          message: '下载结果大小不一致，可稍后继续下载',
          path: target.path,
          temporaryPath: temporary.path,
          bytes: storedLength,
          totalBytes: totalBytes,
          etag: etag,
          lastModified: lastModified,
        );
      }
      emitProgress(force: true);
      final stoppedAfterStream = await stoppedIfRequested();
      if (stoppedAfterStream != null) return stoppedAfterStream;

      if (totalBytes > 0 && existingBytes != totalBytes) {
        return MediaDownloadResult(
          outcome: MediaDownloadOutcome.failed,
          message: '下载中断：文件大小不完整，可稍后继续',
          path: target.path,
          temporaryPath: temporary.path,
          bytes: existingBytes,
          totalBytes: totalBytes,
          etag: etag,
          lastModified: lastModified,
        );
      }
      final stoppedBeforeFinalize = await stoppedIfRequested();
      if (stoppedBeforeFinalize != null) return stoppedBeforeFinalize;
      final stoppedBeforeRename = await stoppedIfRequested();
      if (stoppedBeforeRename != null) return stoppedBeforeRename;
      await atomicReplaceFile(temporary, target);
      final stoppedAfterFinalize = await stoppedIfRequested(
        finalizedFile: target,
      );
      if (stoppedAfterFinalize != null) return stoppedAfterFinalize;
      return MediaDownloadResult(
        outcome: MediaDownloadOutcome.completed,
        message: '下载完成',
        path: target.path,
        temporaryPath: null,
        bytes: existingBytes,
        totalBytes: totalBytes > 0 ? totalBytes : existingBytes,
        etag: etag,
        lastModified: lastModified,
      );
    } on InsufficientDownloadSpace catch (error) {
      return MediaDownloadResult(
        outcome: MediaDownloadOutcome.failed,
        message: '磁盘空间不足，至少需要 ${_sizeLabel(error.requiredBytes)} 可用空间',
        path: target?.path,
        temporaryPath: temporary.path,
        bytes: existingBytes,
        totalBytes: totalBytes,
        etag: etag,
        lastModified: lastModified,
      );
    } on TimeoutException {
      return MediaDownloadResult(
        outcome: MediaDownloadOutcome.failed,
        message: '下载连接超时，可稍后继续',
        path: target?.path,
        temporaryPath: temporary.path,
        bytes: existingBytes,
        totalBytes: totalBytes,
        etag: etag,
        lastModified: lastModified,
      );
    } catch (_) {
      if (control.reason == MediaDownloadStopReason.cancel) {
        if (await temporary.exists()) await temporary.delete();
        existingBytes = 0;
        return stoppedResult();
      }
      if (control.reason == MediaDownloadStopReason.pause) {
        return stoppedResult();
      }
      return MediaDownloadResult(
        outcome: MediaDownloadOutcome.failed,
        message: '下载连接失败，可稍后继续',
        path: target?.path,
        temporaryPath: temporary.path,
        bytes: existingBytes,
        totalBytes: totalBytes,
        etag: etag,
        lastModified: lastModified,
      );
    } finally {
      progressDispatcher.flush();
      await iterator?.cancel();
      await sink?.close();
      client.close();
    }
  }

  @override
  Future<bool> fileExists(String path) async {
    final directory = await _directoryProvider();
    final file = await _managedFile(directory, path);
    if (file == null) return false;
    return await File(file.path).exists() ||
        await Directory(file.path).exists();
  }

  @override
  Future<MediaDownloadVerification> verifyFile(
    String path, {
    int? expectedBytes,
  }) async {
    final directory = await _directoryProvider();
    final file = await _managedFile(directory, path);
    if (file == null) {
      return const MediaDownloadVerification(
        status: MediaDownloadFileStatus.missing,
      );
    }
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      return const MediaDownloadVerification(
        status: MediaDownloadFileStatus.missing,
      );
    }
    final bytes = type == FileSystemEntityType.directory
        ? await _directoryBytes(Directory(file.path))
        : type == FileSystemEntityType.file
        ? await file.length()
        : 0;
    final valid = expectedBytes == null || expectedBytes <= 0
        ? bytes > 0
        : bytes == expectedBytes;
    return MediaDownloadVerification(
      status: valid
          ? MediaDownloadFileStatus.valid
          : MediaDownloadFileStatus.corrupt,
      bytes: bytes,
    );
  }

  @override
  Future<List<MediaDownloadStorageEntry>> listStorageEntries() async {
    final directory = await _directoryProvider();
    if (!await directory.exists()) return const [];
    final entries = <MediaDownloadStorageEntry>[];
    await for (final entity in directory.list(
      recursive: false,
      followLinks: false,
    )) {
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type != FileSystemEntityType.file &&
          type != FileSystemEntityType.directory) {
        continue;
      }
      final bytes = type == FileSystemEntityType.directory
          ? await _directoryBytes(Directory(entity.path))
          : await File(entity.path).length();
      final modifiedAt = (await FileStat.stat(entity.path)).modified;
      entries.add(
        MediaDownloadStorageEntry(
          path: entity.path,
          bytes: bytes,
          modifiedAt: modifiedAt,
        ),
      );
    }
    entries.sort((left, right) => left.path.compareTo(right.path));
    return entries;
  }

  @override
  Future<void> deleteFile(String path) async {
    final directory = await _directoryProvider();
    final file = await _managedFile(directory, path);
    if (file == null) return;
    final packageDirectory = file.parent.path.endsWith('.hls')
        ? file.parent
        : null;
    if (packageDirectory != null && await packageDirectory.exists()) {
      await packageDirectory.delete(recursive: true);
      return;
    }
    final entityType = await FileSystemEntity.type(file.path);
    if (entityType == FileSystemEntityType.directory) {
      await Directory(file.path).delete(recursive: true);
    } else if (entityType == FileSystemEntityType.file) {
      await file.delete();
    }
  }
}

const _downloadProgressInterval = Duration(milliseconds: 500);

class _DownloadProgressDispatcher {
  _DownloadProgressDispatcher(this._onProgress);

  final void Function(MediaDownloadProgress progress) _onProgress;
  DateTime _lastPublishedAt = DateTime.fromMillisecondsSinceEpoch(0);
  MediaDownloadProgress? _pending;

  void add(MediaDownloadProgress progress, {bool force = false}) {
    _pending = progress;
    final now = DateTime.now();
    if (!force &&
        !_isTerminal(progress) &&
        now.difference(_lastPublishedAt) < _downloadProgressInterval) {
      return;
    }
    _publish(now);
  }

  void flush() {
    if (_pending == null) return;
    _publish(DateTime.now());
  }

  void _publish(DateTime now) {
    final progress = _pending;
    if (progress == null) return;
    _pending = null;
    _lastPublishedAt = now;
    _onProgress(progress);
  }

  bool _isTerminal(MediaDownloadProgress progress) {
    final bytesComplete =
        progress.totalBytes > 0 &&
        progress.downloadedBytes >= progress.totalBytes;
    final unitsComplete =
        progress.totalUnits > 0 &&
        progress.completedUnits >= progress.totalUnits;
    return bytesComplete || unitsComplete;
  }
}

Future<Directory> _defaultDirectory() async {
  final root = await getApplicationDocumentsDirectory();
  return Directory('${root.path}${Platform.pathSeparator}anime_downloads');
}

Map<String, String> _requestHeaders(Map<String, String> source) {
  final headers = <String, String>{};
  var hasAcceptEncoding = false;
  for (final entry in source.entries) {
    final lower = entry.key.toLowerCase();
    if (lower == 'range' || lower == 'if-range' || lower == 'content-length') {
      continue;
    }
    if (lower == 'accept-encoding') hasAcceptEncoding = true;
    headers[entry.key] = entry.value;
  }
  if (!hasAcceptEncoding) headers['Accept-Encoding'] = 'identity';
  return headers;
}

Future<File?> _managedFile(Directory directory, String? path) async {
  if (path == null || path.trim().isEmpty) return null;
  if (_containsParentTraversal(path)) return null;
  final rootPath = await _canonicalPath(directory.path);
  final candidatePath = await _canonicalPath(path);
  if (rootPath == null || candidatePath == null) return null;
  var root = rootPath;
  var candidate = candidatePath;
  if (Platform.isWindows) {
    root = root.toLowerCase();
    candidate = candidate.toLowerCase();
  }
  if (candidate == root) return null;
  final prefix = root.endsWith(Platform.pathSeparator)
      ? root
      : '$root${Platform.pathSeparator}';
  return candidate.startsWith(prefix) ? File(candidatePath) : null;
}

bool _containsParentTraversal(String path) =>
    path.split(RegExp(r'[\\/]+')).any((part) => part == '..');

Future<String?> _canonicalPath(String path) async {
  try {
    var current = _normalizedAbsolutePath(path);
    final missingParts = <String>[];
    var type = await FileSystemEntity.type(current, followLinks: false);
    while (type == FileSystemEntityType.notFound) {
      final parent = FileSystemEntity.parentOf(current);
      if (_samePath(parent, current)) return null;
      missingParts.insert(0, _baseName(current));
      current = parent;
      type = await FileSystemEntity.type(current, followLinks: false);
    }
    final resolved = switch (type) {
      FileSystemEntityType.directory => await Directory(
        current,
      ).resolveSymbolicLinks(),
      FileSystemEntityType.file => await File(current).resolveSymbolicLinks(),
      FileSystemEntityType.link => await Link(current).resolveSymbolicLinks(),
      _ => null,
    };
    if (resolved == null) return null;
    var result = _normalizedAbsolutePath(resolved);
    for (final part in missingParts) {
      result = '$result${Platform.pathSeparator}$part';
    }
    return _normalizedAbsolutePath(result);
  } on FileSystemException {
    return null;
  } on ArgumentError {
    return null;
  }
}

String _normalizedAbsolutePath(String path) => File(
  path,
).absolute.uri.normalizePath().toFilePath(windows: Platform.isWindows);

bool _samePath(String left, String right) => Platform.isWindows
    ? left.toLowerCase() == right.toLowerCase()
    : left == right;

String _baseName(String path) {
  final parent = FileSystemEntity.parentOf(path);
  return path
      .substring(parent.length)
      .replaceFirst(RegExp(r'^[\\/]+'), '')
      .replaceFirst(RegExp(r'[\\/]+$'), '');
}

File _targetFile(
  Directory directory,
  MediaDownloadRequest request,
  Uri uri,
  Map<String, String> responseHeaders,
) {
  final extension = _extensionOf(
    uri.path,
    responseHeaders['content-type'],
    request.format,
  );
  final safeTitle = _safeFileName(request.title, maxLength: 80);
  final safeId = _safeFileName(request.taskId, maxLength: 60);
  return File(
    '${directory.path}${Platform.pathSeparator}${safeTitle}_$safeId$extension',
  );
}

Future<int> _directoryBytes(Directory directory) async {
  var total = 0;
  await for (final entity in directory.list(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is File) total += await entity.length();
  }
  return total;
}

String _safeFileName(String value, {required int maxLength}) {
  final cleaned = value.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  final safe = cleaned.isEmpty ? 'video' : cleaned;
  return safe.length <= maxLength ? safe : safe.substring(0, maxLength);
}

String _sizeLabel(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024).ceil()} KB';
}

String _extensionOf(String path, String? contentType, String format) {
  final match = RegExp(
    r'\.(mp4|webm|mkv|mov|m4v|flv)$',
    caseSensitive: false,
  ).firstMatch(path);
  if (match != null) return '.${match.group(1)!.toLowerCase()}';
  final type = contentType?.toLowerCase() ?? '';
  if (type.contains('webm')) return '.webm';
  if (type.contains('matroska')) return '.mkv';
  if (type.contains('quicktime')) return '.mov';
  final lowerFormat = format.toLowerCase();
  if (lowerFormat.contains('webm')) return '.webm';
  if (lowerFormat.contains('mkv') || lowerFormat.contains('matroska')) {
    return '.mkv';
  }
  return '.mp4';
}

bool _looksLikeHlsMedia(Uri uri, String format) {
  final value = uri.toString().toLowerCase();
  final lowerFormat = format.toLowerCase();
  return RegExp(r'\.m3u8(?:$|[?#])').hasMatch(value) ||
      value.contains('type=m3u8') ||
      value.contains('format=m3u8') ||
      lowerFormat == 'hls' ||
      lowerFormat.contains('m3u8') ||
      lowerFormat.contains('mpegurl');
}

bool _looksLikeDashMedia(Uri uri, String format) {
  final value = uri.toString().toLowerCase();
  final lowerFormat = format.toLowerCase();
  return RegExp(r'\.mpd(?:$|[?#])').hasMatch(value) ||
      value.contains('type=mpd') ||
      value.contains('format=mpd') ||
      lowerFormat == 'dash' ||
      lowerFormat.contains('mpeg-dash') ||
      lowerFormat.contains('application/dash+xml');
}

bool _isSegmentedContentType(String value) =>
    value.contains('mpegurl') ||
    value.contains('application/dash+xml') ||
    value.contains('application/vnd.apple.mpegurl');

bool _isUnexpectedDocument(String value) =>
    value.contains('text/html') ||
    value.contains('application/json') ||
    value.contains('text/plain');

int _responseTotalBytes(http.StreamedResponse response, int existingBytes) {
  final rangeTotal = _satisfiedRangeTotal(response.headers['content-range']);
  if (rangeTotal != null) return rangeTotal;
  final contentLength = response.contentLength ?? 0;
  return contentLength <= 0 ? 0 : existingBytes + contentLength;
}

int? _satisfiedRangeStart(String? value) {
  if (value == null) return null;
  final match = RegExp(
    r'^bytes\s+(\d+)-\d+/(?:\d+|\*)$',
    caseSensitive: false,
  ).firstMatch(value.trim());
  return match == null ? null : int.tryParse(match.group(1)!);
}

int? _satisfiedRangeTotal(String? value) {
  if (value == null) return null;
  final match = RegExp(
    r'^bytes\s+\d+-\d+/(\d+)$',
    caseSensitive: false,
  ).firstMatch(value.trim());
  return match == null ? null : int.tryParse(match.group(1)!);
}

int? _unsatisfiedRangeLength(String? value) {
  if (value == null) return null;
  final match = RegExp(
    r'^bytes\s+\*/(\d+)$',
    caseSensitive: false,
  ).firstMatch(value.trim());
  return match == null ? null : int.tryParse(match.group(1)!);
}

bool _resumeValidatorChanged({
  required String? requestEtag,
  required String? requestLastModified,
  required String? responseEtag,
  required String? responseLastModified,
}) {
  final previousEtag = requestEtag?.trim();
  final currentEtag = responseEtag?.trim();
  if (previousEtag?.isNotEmpty == true && currentEtag?.isNotEmpty == true) {
    return previousEtag != currentEtag;
  }
  final previousModified = requestLastModified?.trim();
  final currentModified = responseLastModified?.trim();
  return previousModified?.isNotEmpty == true &&
      currentModified?.isNotEmpty == true &&
      previousModified != currentModified;
}

String? _ifRangeValidator(String? etag, String? lastModified) {
  final normalizedEtag = etag?.trim();
  if (normalizedEtag?.isNotEmpty == true &&
      !normalizedEtag!.toLowerCase().startsWith('w/')) {
    return normalizedEtag;
  }
  final normalizedModified = lastModified?.trim();
  return normalizedModified?.isNotEmpty == true ? normalizedModified : null;
}
