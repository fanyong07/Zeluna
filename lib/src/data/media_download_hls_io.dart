import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../core/network/network_security.dart';
import 'media_download_backend.dart';
import 'media_download_result.dart';
import 'media_download_storage_io.dart';

Future<MediaDownloadResult> downloadHlsMedia({
  required MediaDownloadRequest request,
  required MediaDownloadControl control,
  required void Function(MediaDownloadProgress progress) onProgress,
  required http.Client Function() clientFactory,
  required Future<Directory> Function() directoryProvider,
  required DownloadAvailableBytesProvider availableBytesProvider,
}) async {
  final sourceUri = Uri.tryParse(request.url.trim());
  if (sourceUri == null ||
      (sourceUri.scheme != 'http' && sourceUri.scheme != 'https')) {
    return const MediaDownloadResult(
      outcome: MediaDownloadOutcome.failed,
      message: 'HLS 下载地址无效',
    );
  }

  final root = await directoryProvider();
  await root.create(recursive: true);
  final safeId = _safeName(request.taskId, 60);
  final safeTitle = _safeName(request.title, 80);
  var temporary =
      await _managedDirectory(root, request.temporaryPath) ??
      Directory('${root.path}${Platform.pathSeparator}$safeId.hls.part');
  final suppliedTarget = await _managedFile(root, request.targetPath);
  final finalDirectory = suppliedTarget?.parent.path.endsWith('.hls') == true
      ? suppliedTarget!.parent
      : Directory(
          '${root.path}${Platform.pathSeparator}${safeTitle}_$safeId.hls',
        );
  final targetManifest = File(
    '${finalDirectory.path}${Platform.pathSeparator}index.m3u8',
  );
  var downloadedBytes = 0;
  var totalBytes = 0;
  var completedUnits = 0;
  var totalUnits = 0;
  String? sourceEtag = request.etag;
  String? sourceLastModified = request.lastModified;
  var lastProgressAt = DateTime.fromMillisecondsSinceEpoch(0);
  var finalized = false;

  void emitProgress({bool force = false}) {
    final now = DateTime.now();
    if (!force &&
        now.difference(lastProgressAt) < const Duration(milliseconds: 180)) {
      return;
    }
    lastProgressAt = now;
    onProgress(
      MediaDownloadProgress(
        downloadedBytes: downloadedBytes,
        totalBytes: totalBytes,
        temporaryPath: temporary.path,
        targetPath: targetManifest.path,
        etag: sourceEtag,
        lastModified: sourceLastModified,
        completedUnits: completedUnits,
        totalUnits: totalUnits,
      ),
    );
  }

  MediaDownloadResult stoppedResult() {
    final cancelled = control.reason == MediaDownloadStopReason.cancel;
    return MediaDownloadResult(
      outcome: cancelled
          ? MediaDownloadOutcome.cancelled
          : MediaDownloadOutcome.paused,
      message: cancelled ? 'HLS 下载已取消' : 'HLS 下载已暂停',
      path: targetManifest.path,
      temporaryPath: cancelled ? null : temporary.path,
      bytes: cancelled ? 0 : downloadedBytes,
      totalBytes: cancelled ? 0 : totalBytes,
      etag: sourceEtag,
      lastModified: sourceLastModified,
      completedUnits: cancelled ? 0 : completedUnits,
      totalUnits: cancelled ? 0 : totalUnits,
    );
  }

  void throwIfStopped() {
    if (control.isStopped) throw _HlsStopped(control.reason!);
  }

  try {
    throwIfStopped();
    final selection = await _resolveHlsSelection(
      sourceUri,
      credentialOrigin: sourceUri,
      headers: request.headers,
      control: control,
      clientFactory: clientFactory,
    );
    final requestSourceValidator = _validatorOrNull(
      request.etag,
      request.lastModified,
    );
    final currentSourceValidator = _validatorOrNull(
      selection.sourceEtag,
      selection.sourceLastModified,
    );
    final requestSourceChanged = _validatorChanged(
      requestSourceValidator,
      currentSourceValidator,
    );
    sourceEtag = selection.sourceEtag ?? sourceEtag;
    sourceLastModified = selection.sourceLastModified ?? sourceLastModified;
    final video = _parseMediaPlaylist(
      selection.video.text,
      selection.video.uri,
      trackName: 'video',
    );
    _HlsTrack? audio;
    final playlistValidators = <String, _HlsValidator>{
      ...selection.playlistValidators,
    };
    if (selection.audio != null) {
      final fetchedAudio = await _fetchPlaylist(
        selection.audio!.uri!,
        credentialOrigin: sourceUri,
        headers: request.headers,
        control: control,
        clientFactory: clientFactory,
      );
      final audioValidator = _validatorOrNull(
        fetchedAudio.etag,
        fetchedAudio.lastModified,
      );
      if (audioValidator != null) {
        playlistValidators['audio:0'] = audioValidator;
      }
      if (_parseMaster(fetchedAudio.text, fetchedAudio.uri) != null) {
        throw const _HlsUnsupported('暂不支持使用 master 清单的独立 HLS 音轨');
      }
      audio = _parseMediaPlaylist(
        fetchedAudio.text,
        fetchedAudio.uri,
        trackName: 'audio',
      );
    }
    final tracks = [video, ?audio];
    final fingerprint = sha256
        .convert(
          utf8.encode(
            tracks
                .expand((track) => track.items)
                .map((item) => item.fingerprintPart)
                .join('\n'),
          ),
        )
        .toString();
    final metadataFile = File(
      '${temporary.path}${Platform.pathSeparator}download.json',
    );
    var metadata = await _readMetadata(metadataFile);
    final playlistValidatorChanged =
        metadata != null &&
        _playlistValidatorsChanged(
          metadata.playlistValidators,
          playlistValidators,
        );
    if (metadata == null ||
        metadata.fingerprint != fingerprint ||
        requestSourceChanged ||
        playlistValidatorChanged) {
      if (await temporary.exists()) await temporary.delete(recursive: true);
      temporary = Directory(temporary.path);
      await temporary.create(recursive: true);
      metadata = _HlsMetadata(
        fingerprint: fingerprint,
        playlistValidators: playlistValidators,
      );
      await _writeMetadata(metadataFile, metadata);
    } else {
      metadata = metadata.withPlaylistValidators(playlistValidators);
      await _writeMetadata(metadataFile, metadata);
    }
    var activeMetadata = metadata;

    final itemFiles = <_HlsItem, ({File finalFile, File partialFile})>{};
    for (final track in tracks) {
      final trackDirectory = Directory(
        '${temporary.path}${Platform.pathSeparator}${track.name}',
      );
      final segmentDirectory = Directory(
        '${trackDirectory.path}${Platform.pathSeparator}segments',
      );
      await segmentDirectory.create(recursive: true);
      for (final item in track.items) {
        final finalFile = File(
          '${trackDirectory.path}${Platform.pathSeparator}${item.localPath.replaceAll('/', Platform.pathSeparator)}',
        );
        itemFiles[item] = (
          finalFile: finalFile,
          partialFile: File('${finalFile.path}.part'),
        );
      }
    }

    totalUnits = itemFiles.length;
    final knownLengths = itemFiles.keys
        .map((item) => item.rangeLength)
        .toList();
    totalBytes = knownLengths.every((length) => length != null)
        ? knownLengths.whereType<int>().fold(0, (sum, length) => sum + length)
        : 0;
    for (final files in itemFiles.values) {
      if (await files.finalFile.exists()) {
        completedUnits++;
        downloadedBytes += await files.finalFile.length();
      } else if (await files.partialFile.exists()) {
        downloadedBytes += await files.partialFile.length();
      }
    }
    emitProgress(force: true);
    throwIfStopped();

    for (final entry in itemFiles.entries) {
      throwIfStopped();
      final item = entry.key;
      final files = entry.value;
      if (await files.finalFile.exists()) continue;
      final before = await files.partialFile.exists()
          ? await files.partialFile.length()
          : 0;
      var recordedForItem = before;
      final validator = activeMetadata.validators[item.key];
      final result = await _downloadHlsItem(
        item: item,
        finalFile: files.finalFile,
        partialFile: files.partialFile,
        headers: headersForNetworkRedirect(
          sourceUri,
          item.uri,
          request.headers,
        ),
        control: control,
        clientFactory: clientFactory,
        availableBytesProvider: availableBytesProvider,
        validator: validator,
        onValidator: (next) async {
          activeMetadata = activeMetadata.withValidator(item.key, next);
          await _writeMetadata(metadataFile, activeMetadata);
        },
        onBytes: (bytes) {
          downloadedBytes += bytes - recordedForItem;
          recordedForItem = bytes;
          emitProgress();
        },
      );
      downloadedBytes += result.bytes - recordedForItem;
      completedUnits++;
      emitProgress(force: true);
      throwIfStopped();
    }

    for (final track in tracks) {
      throwIfStopped();
      final playlist = File(
        '${temporary.path}${Platform.pathSeparator}${track.name}${Platform.pathSeparator}index.m3u8',
      );
      await playlist.writeAsString(
        '${track.rewrittenLines.join('\n')}\n',
        encoding: utf8,
        flush: true,
      );
      throwIfStopped();
    }
    final rootManifest = File(
      '${temporary.path}${Platform.pathSeparator}index.m3u8',
    );
    await rootManifest.writeAsString(
      _localMasterPlaylist(selection, hasAudio: audio != null),
      encoding: utf8,
      flush: true,
    );
    throwIfStopped();
    final packageBytesBeforeCommit = await _verifyHlsPackage(
      temporary,
      itemFiles,
    );
    await recoverInterruptedDirectoryCommit(finalDirectory);
    throwIfStopped();
    await atomicReplaceDirectory(temporary, finalDirectory);
    finalized = true;
    throwIfStopped();
    downloadedBytes = await _packageBytes(finalDirectory);
    if (downloadedBytes != packageBytesBeforeCommit ||
        !await targetManifest.exists()) {
      throw const _HlsFailure('HLS 离线包完整性校验失败');
    }
    throwIfStopped();
    totalBytes = downloadedBytes;
    completedUnits = totalUnits;
    emitProgress(force: true);
    throwIfStopped();
    return MediaDownloadResult(
      outcome: MediaDownloadOutcome.completed,
      message: 'HLS 离线缓存完成',
      path: targetManifest.path,
      temporaryPath: null,
      bytes: downloadedBytes,
      totalBytes: totalBytes,
      etag: sourceEtag,
      lastModified: sourceLastModified,
      completedUnits: completedUnits,
      totalUnits: totalUnits,
    );
  } on _HlsStopped catch (stopped) {
    if (finalized && await finalDirectory.exists()) {
      if (stopped.reason == MediaDownloadStopReason.cancel) {
        await finalDirectory.delete(recursive: true);
      } else {
        if (await temporary.exists()) {
          await temporary.delete(recursive: true);
        }
        await finalDirectory.rename(temporary.path);
      }
      finalized = false;
    }
    if (stopped.reason == MediaDownloadStopReason.cancel &&
        await temporary.exists()) {
      await temporary.delete(recursive: true);
    }
    return stoppedResult();
  } on _HlsUnsupported catch (error) {
    if (await temporary.exists()) await temporary.delete(recursive: true);
    return MediaDownloadResult(
      outcome: MediaDownloadOutcome.unsupported,
      message: error.message,
      path: targetManifest.path,
      temporaryPath: null,
      bytes: 0,
      totalBytes: 0,
      etag: sourceEtag,
      lastModified: sourceLastModified,
    );
  } on InsufficientDownloadSpace catch (error) {
    return MediaDownloadResult(
      outcome: MediaDownloadOutcome.failed,
      message: '磁盘空间不足，至少需要 ${_hlsSizeLabel(error.requiredBytes)} 可用空间',
      path: targetManifest.path,
      temporaryPath: temporary.path,
      bytes: downloadedBytes,
      totalBytes: totalBytes,
      etag: sourceEtag,
      lastModified: sourceLastModified,
      completedUnits: completedUnits,
      totalUnits: totalUnits,
    );
  } on _HlsFailure catch (error) {
    if (finalized && await finalDirectory.exists()) {
      await finalDirectory.delete(recursive: true);
      finalized = false;
    }
    return MediaDownloadResult(
      outcome: MediaDownloadOutcome.failed,
      message: error.message,
      path: targetManifest.path,
      temporaryPath: temporary.path,
      bytes: downloadedBytes,
      totalBytes: totalBytes,
      etag: sourceEtag,
      lastModified: sourceLastModified,
      completedUnits: completedUnits,
      totalUnits: totalUnits,
    );
  } catch (_) {
    if (finalized && await finalDirectory.exists()) {
      await finalDirectory.delete(recursive: true);
      finalized = false;
    }
    return MediaDownloadResult(
      outcome: MediaDownloadOutcome.failed,
      message: 'HLS 下载失败，可稍后重试',
      path: targetManifest.path,
      temporaryPath: temporary.path,
      bytes: downloadedBytes,
      totalBytes: totalBytes,
      etag: sourceEtag,
      lastModified: sourceLastModified,
      completedUnits: completedUnits,
      totalUnits: totalUnits,
    );
  }
}

Future<_HlsSelection> _resolveHlsSelection(
  Uri source, {
  required Uri credentialOrigin,
  required Map<String, String> headers,
  required MediaDownloadControl control,
  required http.Client Function() clientFactory,
}) async {
  var fetched = await _fetchPlaylist(
    source,
    credentialOrigin: credentialOrigin,
    headers: headers,
    control: control,
    clientFactory: clientFactory,
  );
  final sourceEtag = fetched.etag;
  final sourceLastModified = fetched.lastModified;
  final playlistValidators = <String, _HlsValidator>{};
  var playlistIndex = 0;

  void recordPlaylistValidator(_FetchedPlaylist playlist) {
    final validator = _validatorOrNull(playlist.etag, playlist.lastModified);
    if (validator != null) {
      playlistValidators['video:$playlistIndex'] = validator;
    }
    playlistIndex++;
  }

  recordPlaylistValidator(fetched);
  Map<String, String>? variantAttributes;
  _HlsRendition? audio;
  for (var depth = 0; depth < 4; depth++) {
    final master = _parseMaster(fetched.text, fetched.uri);
    if (master == null) {
      return _HlsSelection(
        video: fetched,
        variantAttributes: variantAttributes,
        audio: audio,
        sourceEtag: sourceEtag,
        sourceLastModified: sourceLastModified,
        playlistValidators: playlistValidators,
      );
    }
    final variant = master.variants.reduce(
      (left, right) => left.score >= right.score ? left : right,
    );
    variantAttributes = variant.attributes;
    final audioGroup = variant.attributes['AUDIO'];
    if (audioGroup != null) {
      final matching = master.renditions
          .where(
            (item) =>
                item.type == 'AUDIO' &&
                item.groupId == audioGroup &&
                item.uri != null,
          )
          .toList();
      if (matching.isNotEmpty) {
        audio = matching.firstWhere(
          (item) => item.attributes['DEFAULT'] == 'YES',
          orElse: () => matching.first,
        );
      }
    }
    fetched = await _fetchPlaylist(
      variant.uri,
      credentialOrigin: credentialOrigin,
      headers: headers,
      control: control,
      clientFactory: clientFactory,
    );
    recordPlaylistValidator(fetched);
  }
  throw const _HlsUnsupported('HLS master 清单嵌套层级过深');
}

Future<_FetchedPlaylist> _fetchPlaylist(
  Uri uri, {
  required Uri credentialOrigin,
  required Map<String, String> headers,
  required MediaDownloadControl control,
  required http.Client Function() clientFactory,
}) async {
  final client = clientFactory();
  StreamIterator<List<int>>? iterator;
  try {
    if (control.isStopped) throw _HlsStopped(control.reason!);
    final request = http.Request('GET', uri)
      ..headers.addAll(
        _downloadHeaders(
          headersForNetworkRedirect(credentialOrigin, uri, headers),
        ),
      );
    final responseOrStop = await Future.any<Object>([
      client.send(request).timeout(const Duration(seconds: 30)),
      control.whenStopped,
    ]);
    if (responseOrStop is MediaDownloadStopReason) {
      throw _HlsStopped(responseOrStop);
    }
    final response = responseOrStop as http.StreamedResponse;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _HlsFailure('清单请求返回 HTTP ${response.statusCode}');
    }
    final bytes = <int>[];
    iterator = StreamIterator<List<int>>(
      response.stream.timeout(const Duration(seconds: 30)),
    );
    while (true) {
      final nextOrStop = await Future.any<Object>([
        iterator.moveNext(),
        control.whenStopped,
      ]);
      if (nextOrStop is MediaDownloadStopReason) {
        throw _HlsStopped(nextOrStop);
      }
      if (nextOrStop == false) break;
      bytes.addAll(iterator.current);
      if (bytes.length > 2 * 1024 * 1024) {
        throw const _HlsUnsupported('HLS 清单超过 2 MB，已停止处理');
      }
    }
    final text = utf8
        .decode(bytes, allowMalformed: true)
        .replaceFirst('\ufeff', '');
    if (!text.trimLeft().startsWith('#EXTM3U')) {
      throw const _HlsFailure('返回内容不是有效的 HLS 清单');
    }
    final reportedUri = switch (response) {
      http.BaseResponseWithUrl(:final url) => url,
      _ => response.request?.url ?? uri,
    };
    final effectiveUri = reportedUri.hasScheme
        ? reportedUri
        : (response.request?.url ?? uri).resolveUri(reportedUri);
    return _FetchedPlaylist(
      text: text,
      uri: effectiveUri,
      etag: response.headers['etag'],
      lastModified: response.headers['last-modified'],
    );
  } finally {
    await iterator?.cancel();
    client.close();
  }
}

_HlsMaster? _parseMaster(String text, Uri baseUri) {
  final lines = const LineSplitter().convert(text);
  final variants = <_HlsVariant>[];
  final renditions = <_HlsRendition>[];
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.startsWith('#EXT-X-SESSION-KEY:')) {
      _validateKey(line.substring(line.indexOf(':') + 1));
    }
    if (line.startsWith('#EXT-X-MEDIA:')) {
      final attributes = _parseAttributes(
        line.substring(line.indexOf(':') + 1),
      );
      final uriText = attributes['URI'];
      renditions.add(
        _HlsRendition(
          type: attributes['TYPE'] ?? '',
          groupId: attributes['GROUP-ID'] ?? '',
          uri: uriText == null ? null : baseUri.resolve(uriText),
          attributes: attributes,
        ),
      );
    }
    if (!line.startsWith('#EXT-X-STREAM-INF:')) continue;
    final attributes = _parseAttributes(line.substring(line.indexOf(':') + 1));
    String? uriText;
    for (var j = i + 1; j < lines.length; j++) {
      final candidate = lines[j].trim();
      if (candidate.isEmpty) continue;
      if (candidate.startsWith('#')) break;
      uriText = candidate;
      i = j;
      break;
    }
    if (uriText == null) continue;
    variants.add(
      _HlsVariant(uri: baseUri.resolve(uriText), attributes: attributes),
    );
  }
  if (variants.isEmpty) return null;
  return _HlsMaster(variants: variants, renditions: renditions);
}

_HlsTrack _parseMediaPlaylist(
  String text,
  Uri baseUri, {
  required String trackName,
}) {
  final lines = const LineSplitter().convert(text);
  final output = <String>[];
  final items = <_HlsItem>[];
  final nextRangeOffsets = <String, int>{};
  String? pendingByteRange;
  var hasEndList = false;
  var segmentIndex = 0;
  var mapIndex = 0;
  for (final rawLine in lines) {
    final line = rawLine.trim();
    if (line.isEmpty) {
      output.add('');
      continue;
    }
    if (line == '#EXT-X-ENDLIST') hasEndList = true;
    if (line.startsWith('#EXT-X-KEY:')) {
      _validateKey(line.substring(line.indexOf(':') + 1));
      output.add(line);
      continue;
    }
    if (line.startsWith('#EXT-X-SESSION-KEY:')) {
      _validateKey(line.substring(line.indexOf(':') + 1));
      output.add(line);
      continue;
    }
    if (line.startsWith('#EXT-X-PART:') ||
        line.startsWith('#EXT-X-PRELOAD-HINT:')) {
      throw const _HlsUnsupported('暂不支持 Low-Latency HLS 离线缓存');
    }
    if (line.startsWith('#EXT-X-BYTERANGE:')) {
      pendingByteRange = line.substring(line.indexOf(':') + 1).trim();
      continue;
    }
    if (line.startsWith('#EXT-X-MAP:')) {
      final attributes = _parseAttributes(
        line.substring(line.indexOf(':') + 1),
      );
      final uriText = attributes['URI'];
      if (uriText == null || uriText.trim().isEmpty) {
        throw const _HlsFailure('EXT-X-MAP 缺少 URI');
      }
      final uri = baseUri.resolve(uriText);
      final range = _parseByteRange(
        attributes['BYTERANGE'],
        uri,
        nextRangeOffsets,
      );
      final localPath =
          'segments/init_${mapIndex.toString().padLeft(5, '0')}${_extension(uri, fallback: '.mp4')}';
      mapIndex++;
      items.add(
        _HlsItem(
          key: '$trackName:$localPath',
          uri: uri,
          localPath: localPath,
          rangeStart: range?.start,
          rangeLength: range?.length,
        ),
      );
      attributes['URI'] = localPath;
      attributes.remove('BYTERANGE');
      output.add('#EXT-X-MAP:${_serializeAttributes(attributes)}');
      continue;
    }
    if (!line.startsWith('#')) {
      final uri = baseUri.resolve(line);
      final range = _parseByteRange(pendingByteRange, uri, nextRangeOffsets);
      pendingByteRange = null;
      final localPath =
          'segments/segment_${segmentIndex.toString().padLeft(6, '0')}${_extension(uri, fallback: '.ts')}';
      segmentIndex++;
      items.add(
        _HlsItem(
          key: '$trackName:$localPath',
          uri: uri,
          localPath: localPath,
          rangeStart: range?.start,
          rangeLength: range?.length,
        ),
      );
      output.add(localPath);
      continue;
    }
    output.add(line);
  }
  if (!hasEndList) {
    throw const _HlsUnsupported('检测到直播或未结束的 HLS 清单，暂不支持离线缓存');
  }
  if (items.isEmpty) throw const _HlsFailure('HLS 清单没有可下载分片');
  return _HlsTrack(name: trackName, rewrittenLines: output, items: items);
}

void _validateKey(String rawAttributes) {
  final attributes = _parseAttributes(rawAttributes);
  final method = (attributes['METHOD'] ?? '').toUpperCase();
  if (method.isEmpty || method == 'NONE') return;
  if (method == 'AES-128') {
    throw const _HlsUnsupported('暂不支持 AES-128 加密 HLS 离线缓存');
  }
  if (method.startsWith('SAMPLE-AES')) {
    throw const _HlsUnsupported('暂不支持 SAMPLE-AES/DRM HLS 离线缓存');
  }
  throw _HlsUnsupported('暂不支持加密 HLS：$method');
}

Future<_HlsItemResult> _downloadHlsItem({
  required _HlsItem item,
  required File finalFile,
  required File partialFile,
  required Map<String, String> headers,
  required MediaDownloadControl control,
  required http.Client Function() clientFactory,
  required DownloadAvailableBytesProvider availableBytesProvider,
  required _HlsValidator? validator,
  required Future<void> Function(_HlsValidator validator) onValidator,
  required void Function(int bytes) onBytes,
  int attempt = 0,
}) async {
  await partialFile.parent.create(recursive: true);
  var existing = await partialFile.exists() ? await partialFile.length() : 0;
  if (item.rangeLength != null && existing == item.rangeLength) {
    await atomicReplaceFile(partialFile, finalFile);
    return _HlsItemResult(bytes: existing);
  }
  if (item.rangeLength != null && existing > item.rangeLength!) {
    await partialFile.delete();
    existing = 0;
  }
  final requestHeaders = _downloadHeaders(headers);
  final absoluteStart = (item.rangeStart ?? 0) + existing;
  final needsRange = item.rangeLength != null || existing > 0;
  if (needsRange) {
    final end = item.rangeLength == null
        ? ''
        : '${item.rangeStart! + item.rangeLength! - 1}';
    requestHeaders['Range'] = 'bytes=$absoluteStart-$end';
    final ifRange = _ifRangeValidator(validator?.etag, validator?.lastModified);
    if (ifRange != null) requestHeaders['If-Range'] = ifRange;
  }

  final client = clientFactory();
  StreamIterator<List<int>>? iterator;
  IOSink? sink;
  try {
    final request = http.Request('GET', item.uri)
      ..headers.addAll(requestHeaders);
    final responseOrStop = await Future.any<Object>([
      client.send(request).timeout(const Duration(seconds: 30)),
      control.whenStopped,
    ]);
    if (responseOrStop is MediaDownloadStopReason) {
      throw _HlsStopped(responseOrStop);
    }
    final response = responseOrStop as http.StreamedResponse;
    final responseValidator = _HlsValidator(
      etag: response.headers['etag'],
      lastModified: response.headers['last-modified'],
    );
    if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable &&
        existing > 0) {
      final remoteLength = _unsatisfiedRangeLength(
        response.headers['content-range'],
      );
      final expected = item.rangeLength ?? remoteLength;
      if (expected == existing) {
        onBytes(existing);
        if (control.isStopped) throw _HlsStopped(control.reason!);
        await atomicReplaceFile(partialFile, finalFile);
        return _HlsItemResult(bytes: existing);
      }
      if (item.rangeLength == null &&
          remoteLength != null &&
          remoteLength < existing) {
        if (await partialFile.exists()) await partialFile.delete();
        onBytes(0);
        if (attempt >= 1) {
          throw const _HlsFailure('HLS 分片长度持续变化，无法继续下载');
        }
        return _downloadHlsItem(
          item: item,
          finalFile: finalFile,
          partialFile: partialFile,
          headers: headers,
          control: control,
          clientFactory: clientFactory,
          availableBytesProvider: availableBytesProvider,
          validator: responseValidator,
          onValidator: onValidator,
          onBytes: onBytes,
          attempt: attempt + 1,
        );
      }
    }
    if (needsRange && response.statusCode == HttpStatus.partialContent) {
      final responseStart = _contentRangeStart(
        response.headers['content-range'],
      );
      if (responseStart != absoluteStart) {
        throw const _HlsFailure('HLS 分片返回了错误的续传范围');
      }
      if (_validatorChanged(validator, responseValidator)) {
        if (await partialFile.exists()) await partialFile.delete();
        if (attempt >= 1) throw const _HlsFailure('HLS 分片版本持续变化');
        return _downloadHlsItem(
          item: item,
          finalFile: finalFile,
          partialFile: partialFile,
          headers: headers,
          control: control,
          clientFactory: clientFactory,
          availableBytesProvider: availableBytesProvider,
          validator: responseValidator,
          onValidator: onValidator,
          onBytes: onBytes,
          attempt: attempt + 1,
        );
      }
    } else if (needsRange && response.statusCode == HttpStatus.ok) {
      if (item.rangeLength != null) {
        throw const _HlsUnsupported('分片服务器不支持 EXT-X-BYTERANGE 范围请求');
      }
      existing = 0;
    } else if (response.statusCode != HttpStatus.ok &&
        response.statusCode != HttpStatus.partialContent) {
      throw _HlsFailure('分片请求返回 HTTP ${response.statusCode}');
    }
    if (_isUnexpectedHlsItemContentType(response.headers['content-type'])) {
      throw const _HlsFailure('HLS 分片返回的不是媒体内容');
    }
    await onValidator(responseValidator);
    final append =
        existing > 0 && response.statusCode == HttpStatus.partialContent;
    final expected = item.rangeLength ?? _responseTotal(response, existing);
    await ensureDownloadCapacity(
      directory: finalFile.parent,
      requiredBytes: expected == null
          ? 0
          : (expected - existing).clamp(0, expected).toInt(),
      availableBytesProvider: availableBytesProvider,
    );
    final output = partialFile.openWrite(
      mode: append ? FileMode.append : FileMode.write,
    );
    sink = output;
    var downloaded = existing;
    onBytes(downloaded);
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
        await output.flush();
        await output.close();
        sink = null;
        if (nextOrStop == MediaDownloadStopReason.cancel &&
            await partialFile.exists()) {
          await partialFile.delete();
        }
        throw _HlsStopped(nextOrStop);
      }
      if (nextOrStop == false) break;
      final chunk = iterator.current;
      output.add(chunk);
      downloaded += chunk.length;
      onBytes(downloaded);
    }
    await output.flush();
    await output.close();
    sink = null;
    if (control.isStopped) throw _HlsStopped(control.reason!);
    if (expected != null && downloaded != expected) {
      throw const _HlsFailure('HLS 分片大小不完整，可稍后继续');
    }
    if (control.isStopped) throw _HlsStopped(control.reason!);
    await atomicReplaceFile(partialFile, finalFile);
    return _HlsItemResult(bytes: downloaded);
  } finally {
    await iterator?.cancel();
    await sink?.close();
    client.close();
  }
}

Future<int> _verifyHlsPackage(
  Directory temporary,
  Map<_HlsItem, ({File finalFile, File partialFile})> itemFiles,
) async {
  var total = 0;
  for (final entry in itemFiles.entries) {
    final files = entry.value;
    if (!await files.finalFile.exists() || await files.partialFile.exists()) {
      throw const _HlsFailure('HLS 离线包存在未完成分片');
    }
    final length = await files.finalFile.length();
    if (entry.key.rangeLength != null && length != entry.key.rangeLength) {
      throw const _HlsFailure('HLS 离线包分片大小校验失败');
    }
    total += length;
  }
  for (final track in const ['video', 'audio']) {
    final manifest = File(
      '${temporary.path}${Platform.pathSeparator}$track${Platform.pathSeparator}index.m3u8',
    );
    if (await manifest.exists()) total += await manifest.length();
  }
  final rootManifest = File(
    '${temporary.path}${Platform.pathSeparator}index.m3u8',
  );
  if (!await rootManifest.exists()) {
    throw const _HlsFailure('HLS 离线包缺少主清单');
  }
  total += await rootManifest.length();
  final metadata = File(
    '${temporary.path}${Platform.pathSeparator}download.json',
  );
  if (await metadata.exists()) total += await metadata.length();
  return total;
}

String _hlsSizeLabel(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024).ceil()} KB';
}

String _localMasterPlaylist(_HlsSelection selection, {required bool hasAudio}) {
  final attributes = <String, String>{
    ...?selection.variantAttributes,
    if (selection.variantAttributes?['BANDWIDTH'] == null) 'BANDWIDTH': '1',
  };
  attributes.remove('SUBTITLES');
  if (attributes['CLOSED-CAPTIONS'] != 'NONE') {
    attributes.remove('CLOSED-CAPTIONS');
  }
  if (!hasAudio) attributes.remove('AUDIO');
  final lines = <String>['#EXTM3U', '#EXT-X-VERSION:3'];
  if (hasAudio && selection.audio != null) {
    final audioAttributes = <String, String>{
      ...selection.audio!.attributes,
      'URI': 'audio/index.m3u8',
    };
    lines.add('#EXT-X-MEDIA:${_serializeAttributes(audioAttributes)}');
  }
  lines.add('#EXT-X-STREAM-INF:${_serializeAttributes(attributes)}');
  lines.add('video/index.m3u8');
  return '${lines.join('\n')}\n';
}

Map<String, String> _downloadHeaders(Map<String, String> source) {
  final headers = <String, String>{};
  var hasEncoding = false;
  for (final entry in source.entries) {
    final lower = entry.key.toLowerCase();
    if (lower == 'range' || lower == 'if-range' || lower == 'content-length') {
      continue;
    }
    if (lower == 'accept-encoding') hasEncoding = true;
    headers[entry.key] = entry.value;
  }
  if (!hasEncoding) headers['Accept-Encoding'] = 'identity';
  return headers;
}

bool _isUnexpectedHlsItemContentType(String? rawContentType) {
  final contentType = rawContentType?.split(';').first.trim().toLowerCase();
  if (contentType == null || contentType.isEmpty) return false;
  return contentType.startsWith('text/') ||
      contentType.contains('json') ||
      contentType.contains('xml') ||
      contentType.contains('mpegurl');
}

Map<String, String> _parseAttributes(String value) {
  final result = <String, String>{};
  final parts = <String>[];
  var quoted = false;
  var start = 0;
  for (var index = 0; index < value.length; index++) {
    final char = value[index];
    if (char == '"') quoted = !quoted;
    if (char == ',' && !quoted) {
      parts.add(value.substring(start, index));
      start = index + 1;
    }
  }
  parts.add(value.substring(start));
  for (final part in parts) {
    final equals = part.indexOf('=');
    if (equals <= 0) continue;
    final key = part.substring(0, equals).trim().toUpperCase();
    var item = part.substring(equals + 1).trim();
    if (item.length >= 2 && item.startsWith('"') && item.endsWith('"')) {
      item = item.substring(1, item.length - 1);
    }
    result[key] = item;
  }
  return result;
}

String _serializeAttributes(Map<String, String> attributes) {
  const unquotedKeys = {
    'BANDWIDTH',
    'AVERAGE-BANDWIDTH',
    'RESOLUTION',
    'FRAME-RATE',
    'TYPE',
    'VIDEO-RANGE',
    'HDCP-LEVEL',
    'DEFAULT',
    'AUTOSELECT',
    'FORCED',
    'METHOD',
  };
  return attributes.entries
      .map((entry) {
        final value = entry.value;
        if (unquotedKeys.contains(entry.key) ||
            (entry.key == 'CLOSED-CAPTIONS' && value == 'NONE') ||
            RegExp(r'^\d+(?:\.\d+)?$').hasMatch(value)) {
          return '${entry.key}=$value';
        }
        return '${entry.key}="${value.replaceAll('"', '')}"';
      })
      .join(',');
}

_ByteRange? _parseByteRange(
  String? value,
  Uri uri,
  Map<String, int> nextOffsets,
) {
  if (value == null || value.trim().isEmpty) return null;
  final parts = value.replaceAll('"', '').split('@');
  final length = int.tryParse(parts.first.trim());
  if (length == null || length <= 0) {
    throw const _HlsFailure('HLS BYTERANGE 长度无效');
  }
  final key = uri.toString();
  final start = parts.length > 1
      ? int.tryParse(parts[1].trim())
      : nextOffsets[key] ?? 0;
  if (start == null || start < 0) {
    throw const _HlsFailure('HLS BYTERANGE 偏移无效');
  }
  nextOffsets[key] = start + length;
  return _ByteRange(start: start, length: length);
}

String _extension(Uri uri, {required String fallback}) {
  final match = RegExp(r'\.[a-zA-Z0-9]{2,5}$').firstMatch(uri.path);
  return match?.group(0)?.toLowerCase() ?? fallback;
}

int? _contentRangeStart(String? value) {
  if (value == null) return null;
  final match = RegExp(
    r'^bytes\s+(\d+)-\d+/(?:\d+|\*)$',
    caseSensitive: false,
  ).firstMatch(value.trim());
  return match == null ? null : int.tryParse(match.group(1)!);
}

int? _contentRangeTotal(String? value) {
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

int? _responseTotal(http.StreamedResponse response, int existing) {
  final rangeTotal = _contentRangeTotal(response.headers['content-range']);
  if (rangeTotal != null) return rangeTotal;
  final length = response.contentLength;
  return length == null ? null : existing + length;
}

bool _validatorChanged(_HlsValidator? previous, _HlsValidator? current) {
  if (previous == null || current == null) return false;
  final previousEtag = _nonBlank(previous.etag);
  final currentEtag = _nonBlank(current.etag);
  final previousModified = _nonBlank(previous.lastModified);
  final currentModified = _nonBlank(current.lastModified);
  return (previousEtag != null &&
          currentEtag != null &&
          previousEtag != currentEtag) ||
      (previousModified != null &&
          currentModified != null &&
          previousModified != currentModified);
}

bool _playlistValidatorsChanged(
  Map<String, _HlsValidator> previous,
  Map<String, _HlsValidator> current,
) {
  for (final entry in current.entries) {
    if (_validatorChanged(previous[entry.key], entry.value)) return true;
  }
  return false;
}

_HlsValidator? _validatorOrNull(String? etag, String? lastModified) {
  final normalizedEtag = _nonBlank(etag);
  final normalizedModified = _nonBlank(lastModified);
  if (normalizedEtag == null && normalizedModified == null) return null;
  return _HlsValidator(etag: normalizedEtag, lastModified: normalizedModified);
}

String? _nonBlank(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

String? _ifRangeValidator(String? etag, String? lastModified) {
  final normalizedEtag = etag?.trim();
  if (normalizedEtag?.isNotEmpty == true &&
      !normalizedEtag!.toLowerCase().startsWith('w/')) {
    return normalizedEtag;
  }
  final modified = lastModified?.trim();
  return modified?.isNotEmpty == true ? modified : null;
}

Future<_HlsMetadata?> _readMetadata(File file) async {
  if (!await file.exists()) return null;
  try {
    final decoded = jsonDecode(await file.readAsString());
    return decoded is Map
        ? _HlsMetadata.fromJson(decoded.cast<String, dynamic>())
        : null;
  } catch (_) {
    return null;
  }
}

Future<void> _writeMetadata(File file, _HlsMetadata metadata) async {
  await file.parent.create(recursive: true);
  await file.writeAsString(
    jsonEncode(metadata.toJson()),
    encoding: utf8,
    flush: true,
  );
}

Future<int> _packageBytes(Directory directory) async {
  var bytes = 0;
  await for (final entity in directory.list(recursive: true)) {
    if (entity is File) bytes += await entity.length();
  }
  return bytes;
}

Future<Directory?> _managedDirectory(Directory root, String? path) async {
  if (path == null || path.trim().isEmpty) return null;
  if (_containsParentTraversal(path)) return null;
  final canonical = await _canonicalPath(path);
  return canonical != null && await _insideRoot(root, canonical)
      ? Directory(canonical)
      : null;
}

Future<File?> _managedFile(Directory root, String? path) async {
  if (path == null || path.trim().isEmpty) return null;
  if (_containsParentTraversal(path)) return null;
  final canonical = await _canonicalPath(path);
  return canonical != null && await _insideRoot(root, canonical)
      ? File(canonical)
      : null;
}

Future<bool> _insideRoot(Directory root, String candidatePath) async {
  final canonicalRoot = await _canonicalPath(root.path);
  final canonicalCandidate = await _canonicalPath(candidatePath);
  if (canonicalRoot == null || canonicalCandidate == null) return false;
  var rootPath = canonicalRoot;
  var candidate = canonicalCandidate;
  if (Platform.isWindows) {
    rootPath = rootPath.toLowerCase();
    candidate = candidate.toLowerCase();
  }
  if (candidate == rootPath) return false;
  final prefix = rootPath.endsWith(Platform.pathSeparator)
      ? rootPath
      : '$rootPath${Platform.pathSeparator}';
  return candidate.startsWith(prefix);
}

bool _containsParentTraversal(String path) =>
    path.split(RegExp(r'[\\/]+')).any((part) => part == '..');

Future<String?> _canonicalPath(String path) async {
  try {
    var current = _normalizeAbsolutePath(path);
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
    var result = _normalizeAbsolutePath(resolved);
    for (final part in missingParts) {
      result = '$result${Platform.pathSeparator}$part';
    }
    return _normalizeAbsolutePath(result);
  } on FileSystemException {
    return null;
  } on ArgumentError {
    return null;
  }
}

String _normalizeAbsolutePath(String path) => File(
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

String _safeName(String value, int maxLength) {
  final cleaned = value.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  final safe = cleaned.isEmpty ? 'video' : cleaned;
  return safe.length <= maxLength ? safe : safe.substring(0, maxLength);
}

class _FetchedPlaylist {
  const _FetchedPlaylist({
    required this.text,
    required this.uri,
    this.etag,
    this.lastModified,
  });

  final String text;
  final Uri uri;
  final String? etag;
  final String? lastModified;
}

class _HlsSelection {
  const _HlsSelection({
    required this.video,
    required this.variantAttributes,
    required this.audio,
    required this.sourceEtag,
    required this.sourceLastModified,
    required this.playlistValidators,
  });

  final _FetchedPlaylist video;
  final Map<String, String>? variantAttributes;
  final _HlsRendition? audio;
  final String? sourceEtag;
  final String? sourceLastModified;
  final Map<String, _HlsValidator> playlistValidators;
}

class _HlsMaster {
  const _HlsMaster({required this.variants, required this.renditions});

  final List<_HlsVariant> variants;
  final List<_HlsRendition> renditions;
}

class _HlsVariant {
  const _HlsVariant({required this.uri, required this.attributes});

  final Uri uri;
  final Map<String, String> attributes;

  int get score {
    final resolution = attributes['RESOLUTION']?.split('x');
    final width = resolution == null ? 0 : int.tryParse(resolution.first) ?? 0;
    final height = resolution == null || resolution.length < 2
        ? 0
        : int.tryParse(resolution[1]) ?? 0;
    final bandwidth =
        int.tryParse(attributes['AVERAGE-BANDWIDTH'] ?? '') ??
        int.tryParse(attributes['BANDWIDTH'] ?? '') ??
        0;
    return width * height * 1000000 + bandwidth;
  }
}

class _HlsRendition {
  const _HlsRendition({
    required this.type,
    required this.groupId,
    required this.uri,
    required this.attributes,
  });

  final String type;
  final String groupId;
  final Uri? uri;
  final Map<String, String> attributes;
}

class _HlsTrack {
  const _HlsTrack({
    required this.name,
    required this.rewrittenLines,
    required this.items,
  });

  final String name;
  final List<String> rewrittenLines;
  final List<_HlsItem> items;
}

class _HlsItem {
  const _HlsItem({
    required this.key,
    required this.uri,
    required this.localPath,
    required this.rangeStart,
    required this.rangeLength,
  });

  final String key;
  final Uri uri;
  final String localPath;
  final int? rangeStart;
  final int? rangeLength;

  String get fingerprintPart =>
      '$key|$uri|${rangeStart ?? ''}|${rangeLength ?? ''}';
}

class _ByteRange {
  const _ByteRange({required this.start, required this.length});

  final int start;
  final int length;
}

class _HlsItemResult {
  const _HlsItemResult({required this.bytes});

  final int bytes;
}

class _HlsValidator {
  const _HlsValidator({this.etag, this.lastModified});

  final String? etag;
  final String? lastModified;

  _HlsValidator mergedWith(_HlsValidator other) => _HlsValidator(
    etag: _nonBlank(other.etag) ?? etag,
    lastModified: _nonBlank(other.lastModified) ?? lastModified,
  );

  Map<String, dynamic> toJson() => {'etag': etag, 'lastModified': lastModified};

  factory _HlsValidator.fromJson(Map<String, dynamic> json) => _HlsValidator(
    etag: json['etag']?.toString(),
    lastModified: json['lastModified']?.toString(),
  );
}

class _HlsMetadata {
  const _HlsMetadata({
    required this.fingerprint,
    this.playlistValidators = const {},
    this.validators = const {},
  });

  final String fingerprint;
  final Map<String, _HlsValidator> playlistValidators;
  final Map<String, _HlsValidator> validators;

  _HlsMetadata withPlaylistValidators(Map<String, _HlsValidator> current) =>
      _HlsMetadata(
        fingerprint: fingerprint,
        playlistValidators: {
          ...playlistValidators,
          for (final entry in current.entries)
            entry.key:
                playlistValidators[entry.key]?.mergedWith(entry.value) ??
                entry.value,
        },
        validators: validators,
      );

  _HlsMetadata withValidator(String key, _HlsValidator validator) =>
      _HlsMetadata(
        fingerprint: fingerprint,
        playlistValidators: playlistValidators,
        validators: {...validators, key: validator},
      );

  Map<String, dynamic> toJson() => {
    'version': 2,
    'fingerprint': fingerprint,
    'playlistValidators': {
      for (final entry in playlistValidators.entries)
        entry.key: entry.value.toJson(),
    },
    'validators': {
      for (final entry in validators.entries) entry.key: entry.value.toJson(),
    },
  };

  factory _HlsMetadata.fromJson(Map<String, dynamic> json) {
    final rawPlaylistValidators = json['playlistValidators'];
    final rawValidators = json['validators'];
    return _HlsMetadata(
      fingerprint: json['fingerprint']?.toString() ?? '',
      playlistValidators: rawPlaylistValidators is Map
          ? {
              for (final entry in rawPlaylistValidators.entries)
                if (entry.value is Map)
                  entry.key.toString(): _HlsValidator.fromJson(
                    (entry.value as Map).cast<String, dynamic>(),
                  ),
            }
          : const {},
      validators: rawValidators is Map
          ? {
              for (final entry in rawValidators.entries)
                if (entry.value is Map)
                  entry.key.toString(): _HlsValidator.fromJson(
                    (entry.value as Map).cast<String, dynamic>(),
                  ),
            }
          : const {},
    );
  }
}

class _HlsStopped implements Exception {
  const _HlsStopped(this.reason);

  final MediaDownloadStopReason reason;
}

class _HlsUnsupported implements Exception {
  const _HlsUnsupported(this.message);

  final String message;
}

class _HlsFailure implements Exception {
  const _HlsFailure(this.message);

  final String message;

  @override
  String toString() => message;
}
