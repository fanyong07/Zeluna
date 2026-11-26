import 'dart:async';

import 'package:hive_ce_flutter/hive_flutter.dart';

import '../accounts/account_controller.dart';
import '../accounts/local_account_repository.dart';
import '../core/identity/stable_identity.dart';
import '../data/media_download_line_selector.dart';
import '../data/media_download_result.dart';
import '../data/media_download_service.dart';
import '../data/media_download_task.dart';
import '../domain/anime_models.dart';

abstract interface class DownloadStorage {
  Object? get(String key);

  Future<void> put(String key, Object? value);
}

final class HiveDownloadStorage implements DownloadStorage {
  const HiveDownloadStorage(this._box);

  final Box<dynamic> _box;

  @override
  Object? get(String key) => _box.get(key);

  @override
  Future<void> put(String key, Object? value) => _box.put(key, value);
}

typedef DownloadLineResolver =
    Future<List<PlaybackLine>> Function(
      AnimeSubject subject,
      AnimeEpisode episode,
    );
typedef DownloadSnapshotPublisher = void Function(DownloadSnapshot snapshot);

final class DownloadSnapshot {
  const DownloadSnapshot({this.tasks = const []});

  final List<MediaDownloadTask> tasks;
}

final class DownloadStorageSnapshot {
  const DownloadStorageSnapshot({
    required this.totalBytes,
    required this.accountBytes,
    required this.byWorkBytes,
    required this.orphanedPaths,
    required this.failedPaths,
    required this.expiredTemporaryPaths,
    required this.entries,
  });

  final int totalBytes;
  final int accountBytes;
  final Map<String, int> byWorkBytes;
  final List<String> orphanedPaths;
  final List<String> failedPaths;
  final List<String> expiredTemporaryPaths;
  final List<MediaDownloadStorageEntry> entries;
}

/// Owns account-scoped download state, file lifecycle, ordered persistence,
/// and guarded asynchronous runs.
///
/// A stable task id identifies the media across restarts. Each live run also
/// receives a separate control id, so a late old-account callback can never
/// pause, cancel, publish into, or persist a new account's task with the same
/// stable id.
final class DownloadController {
  DownloadController({
    required DownloadStorage storage,
    required MediaDownloadService service,
    required DownloadLineResolver resolveLines,
    required DownloadSnapshotPublisher publishSnapshot,
    DateTime Function()? now,
    this.progressPersistInterval = const Duration(seconds: 1),
    this.quiesceTimeout = const Duration(seconds: 3),
    this.maxConcurrentDownloads = 2,
    this.retryAttemptsPerLine = 2,
    this.retryBaseDelay = const Duration(milliseconds: 250),
  }) : assert(maxConcurrentDownloads > 0),
       assert(retryAttemptsPerLine > 0),
       _storage = storage,
       _service = service,
       _resolveLines = resolveLines,
       _publishSnapshot = publishSnapshot,
       _now = now ?? DateTime.now;

  final DownloadStorage _storage;
  final MediaDownloadService _service;
  final DownloadLineResolver _resolveLines;
  final DownloadSnapshotPublisher _publishSnapshot;
  final DateTime Function() _now;
  final Duration progressPersistInterval;
  final Duration quiesceTimeout;
  final int maxConcurrentDownloads;
  final int retryAttemptsPerLine;
  final Duration retryBaseDelay;

  DownloadSnapshot _snapshot = const DownloadSnapshot();
  String? _accountId;
  var _contextVersion = 0;
  var _scopeEpoch = 0;
  var _runSequence = 0;
  var _loaded = false;
  var _disposed = false;
  var _activeSlots = 0;
  final _runs = <String, _DownloadRun>{};
  final _slotWaiters = <Completer<void>>[];
  final _persistedAt = <String, DateTime>{};
  Future<void> _writeQueue = Future<void>.value();
  Timer? _persistTimer;
  _DownloadScope? _persistTimerScope;

  DownloadSnapshot get snapshot => _snapshot;
  String? get accountId => _accountId;
  int get contextVersion => _contextVersion;
  bool get isLoaded => _loaded;
  bool get supportsDownloads => _service.supportsDownloads;

  Future<DownloadSnapshot> loadForAccount({
    required String? accountId,
    required int contextVersion,
  }) async {
    _ensureNotDisposed();
    final previousScope = _loaded ? _currentScope : null;
    final previousTasks = _snapshot.tasks;
    final hadPendingProgress = _cancelPersistTimer();

    final scope = _DownloadScope(
      accountId: accountId,
      contextVersion: contextVersion,
      epoch: ++_scopeEpoch,
    );
    _accountId = accountId;
    _contextVersion = contextVersion;
    _loaded = false;
    _wakeSlotWaiters(force: true);

    if (hadPendingProgress && previousScope != null) {
      await _persistSnapshot(previousScope, previousTasks);
    }
    await _writeQueue;
    _ensureConfigured(scope);

    final restored = await _readTasks(scope);
    _ensureConfigured(scope);
    _snapshot = DownloadSnapshot(
      tasks: List<MediaDownloadTask>.unmodifiable(restored),
    );
    _loaded = true;
    return _snapshot;
  }

  Future<String> queueOffline(
    AnimeSubject subject,
    AnimeEpisode? episode,
  ) async {
    final scope = _scope();
    if (episode == null) return '当前条目没有可下载的集数';
    if (!supportsDownloads) {
      return '网页版暂不支持离线下载，请使用桌面或移动客户端';
    }

    final existing = _snapshot.tasks
        .where(
          (item) =>
              sameSubjectIdentity(item.subject, subject) &&
              item.episode.id == episode.id,
        )
        .firstOrNull;
    if (existing != null) {
      if (existing.isActive) return '该集已经在下载队列中';
      if (existing.isPlayable &&
          await _service.fileExists(existing.localPath)) {
        _ensureScope(scope);
        return '该集已经下载完成';
      }
      _ensureScope(scope);
      await _resumeDownload(scope, existing.id);
      return '已重新开始下载';
    }

    final timestamp = _now();
    final subjectKey = subject.identityKey;
    final episodeKey = episode.identityKey(subjectKey: subjectKey);
    final task = MediaDownloadTask(
      id: stableDownloadTaskKey(subjectKey: subjectKey, episodeKey: episodeKey),
      subject: subject,
      episode: episode,
      createdAt: timestamp,
      updatedAt: timestamp,
      status: MediaDownloadTaskStatus.resolving,
      message: '正在查找可下载线路',
    );
    _publish(scope, DownloadSnapshot(tasks: [task, ..._snapshot.tasks]));
    await _persistNow(scope);
    _ensureScope(scope);
    unawaited(_launchDownload(scope, task.id));
    return '已加入下载队列';
  }

  Future<void> pauseDownload(String taskId) => _pauseDownload(_scope(), taskId);

  Future<void> resumeDownload(String taskId) =>
      _resumeDownload(_scope(), taskId);

  Future<void> cancelDownload(String taskId) =>
      _cancelDownload(_scope(), taskId);

  Future<void> removeDownload(String taskId) =>
      _removeDownload(_scope(), taskId);

  Future<void> clearDownloads() async {
    final scope = _scope();
    final taskIds = _snapshot.tasks
        .map((task) => task.id)
        .toList(growable: false);
    for (final taskId in taskIds) {
      _ensureScope(scope);
      await _removeDownload(scope, taskId);
    }
  }

  Future<DownloadStorageSnapshot> storageSnapshot() async {
    final scope = _scope();
    final entries = await _service.listStorageEntries();
    _ensureScope(scope);
    final bytesByPath = <String, int>{
      for (final entry in entries) entry.path.trim(): entry.bytes,
    };
    final ownedPaths = <String>{};
    final failedPaths = <String>{};
    final byWork = <String, int>{};
    for (final task in _snapshot.tasks) {
      final taskPaths = <String>{
        if (task.temporaryPath?.trim().isNotEmpty == true)
          task.temporaryPath!.trim(),
        if (task.localPath?.trim().isNotEmpty == true) task.localPath!.trim(),
      };
      ownedPaths.addAll(taskPaths);
      if (task.status == MediaDownloadTaskStatus.failed ||
          task.status == MediaDownloadTaskStatus.corrupt) {
        failedPaths.addAll(taskPaths);
      }
      final workKey = task.subject.identityKey;
      byWork[workKey] =
          (byWork[workKey] ?? 0) +
          taskPaths.fold<int>(
            0,
            (total, path) => total + (bytesByPath[path] ?? 0),
          );
    }
    final totalBytes = entries.fold<int>(
      0,
      (total, entry) => total + entry.bytes,
    );
    final accountBytes = ownedPaths.fold<int>(
      0,
      (total, path) => total + (bytesByPath[path] ?? 0),
    );
    final orphanedPaths = entries
        .map((entry) => entry.path)
        .where((path) => !ownedPaths.contains(path.trim()))
        .toList(growable: false);
    final expiry = _now().subtract(const Duration(days: 7));
    final expiredTemporaryPaths = entries
        .where(
          (entry) =>
              entry.modifiedAt.isBefore(expiry) &&
              _isTemporaryStoragePath(entry.path),
        )
        .map((entry) => entry.path)
        .toList(growable: false);
    return DownloadStorageSnapshot(
      totalBytes: totalBytes,
      accountBytes: accountBytes,
      byWorkBytes: Map.unmodifiable(byWork),
      orphanedPaths: List.unmodifiable(orphanedPaths),
      failedPaths: List.unmodifiable(failedPaths),
      expiredTemporaryPaths: List.unmodifiable(expiredTemporaryPaths),
      entries: List.unmodifiable(entries),
    );
  }

  /// Deletes only paths explicitly selected by the user after reviewing
  /// [storageSnapshot]. No automatic orphan cleanup is performed.
  Future<void> deleteConfirmedStorageEntries(Iterable<String> paths) async {
    final scope = _scope();
    await _service.deleteFiles(paths);
    _ensureScope(scope);
  }

  List<AccountOwnedDownload> ownedDownloads() => List.unmodifiable(
    _snapshot.tasks.map(
      (task) => AccountOwnedDownload(
        id: task.id,
        temporaryPath: task.temporaryPath,
        localPath: task.localPath,
      ),
    ),
  );

  /// Used by durable account-deletion recovery after the UI scope has moved
  /// on. The account id is mandatory to avoid cancelling a new account's run
  /// that happens to have the same stable task id.
  void cancelOwnedDownload(String accountId, String taskId) {
    final matches = _runs.values
        .where(
          (run) => run.scope.accountId == accountId && run.taskId == taskId,
        )
        .toList(growable: false);
    for (final run in matches) {
      _service.cancel(taskId, controlId: run.controlId);
    }
  }

  Future<void> quiesce() async {
    if (!_loaded || _disposed) {
      await _writeQueue;
      return;
    }
    final scope = _scope();
    final activeIds = _snapshot.tasks
        .where((task) => task.isActive)
        .map((task) => task.id)
        .toList(growable: false);
    for (final taskId in activeIds) {
      if (!_isCurrent(scope)) break;
      await _pauseDownload(scope, taskId);
    }
    if (_isCurrent(scope)) await _persistNow(scope);

    final runs = _runs.values
        .where((run) => run.scope == scope)
        .map((run) => run.future)
        .toList(growable: false);
    if (runs.isNotEmpty) {
      await Future.wait(
        runs,
      ).timeout(quiesceTimeout, onTimeout: () => const <void>[]);
    }
    await settleWrites();
  }

  Future<void> settleWrites() async {
    final scope = _loaded && !_disposed ? _currentScope : null;
    final hadPendingProgress = _cancelPersistTimer();
    if (hadPendingProgress && scope != null && _isCurrent(scope)) {
      await _persistSnapshot(scope, _snapshot.tasks);
    }
    await _writeQueue;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _loaded = false;
    _scopeEpoch++;
    _wakeSlotWaiters();
    _cancelPersistTimer();
    for (final run in _runs.values.toList(growable: false)) {
      run.stop();
      _service.pause(run.taskId, controlId: run.controlId);
    }
    _runs.clear();
  }

  Future<void> _pauseDownload(_DownloadScope scope, String taskId) async {
    _ensureScope(scope);
    final task = _task(taskId);
    if (task == null || !task.isActive) return;
    final run = _run(scope, taskId);
    if (run != null) {
      _service.pause(taskId, controlId: run.controlId);
      run.stop();
    }
    _replaceTask(
      scope,
      task.copyWith(
        status: MediaDownloadTaskStatus.paused,
        updatedAt: _now(),
        message: '下载已暂停',
      ),
    );
    await _persistNow(scope);
  }

  Future<void> _resumeDownload(_DownloadScope scope, String taskId) async {
    _ensureScope(scope);
    if (!supportsDownloads) return;
    var task = _task(taskId);
    if (task == null || task.isActive) return;

    final finishingRun = _run(scope, taskId);
    if (finishingRun != null) {
      await finishingRun.future;
      _ensureScope(scope);
      task = _task(taskId);
      if (task == null || task.isActive) return;
    }

    if (task.isPlayable && await _service.fileExists(task.localPath)) {
      _ensureScope(scope);
      return;
    }
    _ensureScope(scope);
    if (task.status == MediaDownloadTaskStatus.cancelled ||
        task.status == MediaDownloadTaskStatus.missing ||
        task.status == MediaDownloadTaskStatus.corrupt ||
        (task.status == MediaDownloadTaskStatus.completed &&
            !await _service.fileExists(task.localPath))) {
      _ensureScope(scope);
      await _service.deleteFiles([task.temporaryPath, task.localPath]);
      _ensureScope(scope);
      task = task.copyWith(
        downloadedBytes: 0,
        totalBytes: 0,
        completedUnits: 0,
        totalUnits: 0,
        temporaryPath: null,
        localPath: null,
        etag: null,
        lastModified: null,
        url: null,
        lineId: null,
        providerName: null,
        format: null,
        headers: const {},
      );
    }
    task = task.copyWith(
      status: MediaDownloadTaskStatus.queued,
      updatedAt: _now(),
      message: task.downloadedBytes > 0 ? '等待继续下载' : '等待下载',
    );
    _replaceTask(scope, task);
    await _persistNow(scope);
    _ensureScope(scope);
    unawaited(
      _launchDownload(
        scope,
        taskId,
        preferStoredLine: task.url?.trim().isNotEmpty == true,
      ),
    );
  }

  Future<void> _cancelDownload(_DownloadScope scope, String taskId) async {
    _ensureScope(scope);
    final task = _task(taskId);
    if (task == null || task.status == MediaDownloadTaskStatus.completed) {
      return;
    }
    final run = _run(scope, taskId);
    final stopped =
        run != null && _service.cancel(taskId, controlId: run.controlId);
    run?.stop();
    if (!stopped) {
      await _service.deleteFiles([task.temporaryPath]);
      _ensureScope(scope);
    }
    _replaceTask(
      scope,
      task.copyWith(
        status: MediaDownloadTaskStatus.cancelled,
        updatedAt: _now(),
        downloadedBytes: 0,
        totalBytes: 0,
        completedUnits: 0,
        totalUnits: 0,
        temporaryPath: null,
        localPath: null,
        etag: null,
        lastModified: null,
        message: '下载已取消',
      ),
    );
    await _persistNow(scope);
  }

  Future<void> _removeDownload(_DownloadScope scope, String taskId) async {
    _ensureScope(scope);
    var task = _task(taskId);
    if (task == null) return;
    final paths = <String?>[task.temporaryPath, task.localPath];
    if (task.status != MediaDownloadTaskStatus.completed) {
      await _cancelDownload(scope, taskId);
      _ensureScope(scope);
      task = _task(taskId) ?? task;
      paths.addAll([task.temporaryPath, task.localPath]);
    }
    final run = _run(scope, taskId);
    _publish(
      scope,
      DownloadSnapshot(
        tasks: _snapshot.tasks
            .where((item) => item.id != taskId)
            .toList(growable: false),
      ),
    );
    await _persistNow(scope);

    Future<void> cleanup() async {
      if (run != null) await run.future;
      await _service.deleteFiles(paths);
    }

    if (run == null) {
      await cleanup();
    } else {
      unawaited(cleanup().onError((_, _) {}));
    }
  }

  Future<void> _launchDownload(
    _DownloadScope scope,
    String taskId, {
    bool preferStoredLine = false,
  }) {
    _ensureScope(scope);
    final key = _runKey(scope, taskId);
    final active = _runs[key];
    if (active != null) return active.future;

    final run = _DownloadRun(
      scope: scope,
      taskId: taskId,
      controlId: 'download-control:${scope.epoch}:${++_runSequence}:$taskId',
    );
    _runs[key] = run;
    run.future = _runDownload(run, preferStoredLine: preferStoredLine);
    return run.future;
  }

  Future<void> _runDownload(
    _DownloadRun run, {
    required bool preferStoredLine,
  }) async {
    var acquired = false;
    try {
      acquired = await _acquireSlot(run);
      if (!acquired) return;
      await _performDownload(run, preferStoredLine: preferStoredLine);
    } catch (_) {
      final task = _taskForRun(run);
      if (task != null &&
          task.status != MediaDownloadTaskStatus.cancelled &&
          task.status != MediaDownloadTaskStatus.paused) {
        _replaceTask(
          run.scope,
          task.copyWith(
            status: MediaDownloadTaskStatus.failed,
            updatedAt: _now(),
            message: '下载失败，可稍后重试',
          ),
        );
        await _persistNow(run.scope);
      }
    } finally {
      if (acquired) _releaseSlot();
      final key = _runKey(run.scope, run.taskId);
      if (identical(_runs[key], run)) _runs.remove(key);
    }
  }

  Future<void> _performDownload(
    _DownloadRun run, {
    required bool preferStoredLine,
  }) async {
    var task = _taskForRun(run);
    if (!_canContinue(task)) return;

    MediaDownloadResult? lastResult;
    if (preferStoredLine && task!.url?.trim().isNotEmpty == true) {
      final storedLine = PlaybackLine(
        id: task.lineId ?? 'download:${task.id}',
        episodeId: task.episode.id,
        providerId: task.lineId ?? 'download',
        providerName: task.providerName ?? '已保存线路',
        title: task.providerName ?? '已保存线路',
        quality: '离线下载',
        format: task.format ?? 'MP4',
        url: task.url,
        headers: task.headers,
        available: true,
      );
      lastResult = await _downloadLine(run, storedLine);
      if (lastResult.success || lastResult.paused || lastResult.cancelled) {
        return;
      }
    }

    task = _taskForRun(run);
    if (!_canContinue(task)) return;
    _replaceTask(
      run.scope,
      task!.copyWith(
        status: MediaDownloadTaskStatus.resolving,
        updatedAt: _now(),
        message: lastResult == null ? '正在查找可下载线路' : '当前线路失败，正在换线',
      ),
    );
    await _persistNow(run.scope);
    task = _taskForRun(run);
    if (!_canContinue(task)) return;

    List<PlaybackLine> lines;
    try {
      lines = await _resolveLines(task!.subject, task.episode);
    } catch (_) {
      final latest = _taskForRun(run);
      if (!_canContinue(latest)) return;
      _replaceTask(
        run.scope,
        latest!.copyWith(
          status: MediaDownloadTaskStatus.failed,
          updatedAt: _now(),
          message: '查找下载线路失败，请稍后重试',
        ),
      );
      await _persistNow(run.scope);
      return;
    }

    task = _taskForRun(run);
    if (!_canContinue(task)) return;
    final previousUrl = task!.url;
    final candidates = [
      ...singleFileDownloadCandidates(lines),
      ...hlsDownloadCandidates(lines),
    ].where((line) => line.url != previousUrl).toList(growable: false);
    if (candidates.isEmpty) {
      final onlySegmented = lines.any(
        (line) => line.available && isSegmentedDownloadLine(line),
      );
      _replaceTask(
        run.scope,
        task.copyWith(
          status: MediaDownloadTaskStatus.failed,
          updatedAt: _now(),
          message: onlySegmented
              ? '没有找到可以离线下载的线路'
              : (lastResult?.message ?? '没有找到可直接下载的单文件线路'),
        ),
      );
      await _persistNow(run.scope);
      return;
    }

    for (var index = 0; index < candidates.length; index++) {
      final latest = _taskForRun(run);
      if (!_canContinue(latest)) return;
      final activeTask = latest!;
      if (lastResult != null ||
          (activeTask.url != null && activeTask.url != candidates[index].url)) {
        await _discardPartialDownload(run, activeTask);
        if (!_canContinue(_taskForRun(run))) return;
      }
      var attempt = 0;
      while (true) {
        lastResult = await _downloadLine(run, candidates[index]);
        if (lastResult.success || lastResult.paused || lastResult.cancelled) {
          return;
        }
        attempt++;
        if (attempt >= retryAttemptsPerLine) break;
        final retryTask = _taskForRun(run);
        if (!_canContinue(retryTask)) return;
        await _discardPartialDownload(run, retryTask!);
        final delay = _retryDelay(attempt);
        _replaceTask(
          run.scope,
          retryTask.copyWith(
            status: MediaDownloadTaskStatus.resolving,
            updatedAt: _now(),
            message: '线路暂时失败，${delay.inMilliseconds}ms 后重试',
          ),
        );
        await _persistNow(run.scope);
        if (!await _waitForRetry(run, delay)) return;
      }
      if (index + 1 < candidates.length) {
        final failed = _taskForRun(run);
        if (!_canContinue(failed)) return;
        _replaceTask(
          run.scope,
          failed!.copyWith(
            status: MediaDownloadTaskStatus.resolving,
            updatedAt: _now(),
            message: '${failed.providerName ?? '当前线路'}失败，正在尝试下一条',
          ),
        );
        await _persistNow(run.scope);
      }
    }

    final failed = _taskForRun(run);
    if (_canContinue(failed)) {
      _replaceTask(
        run.scope,
        failed!.copyWith(
          status: MediaDownloadTaskStatus.failed,
          updatedAt: _now(),
          message: lastResult?.message ?? '所有可下载线路都失败',
        ),
      );
      await _persistNow(run.scope);
    }
  }

  Future<MediaDownloadResult> _downloadLine(
    _DownloadRun run,
    PlaybackLine line,
  ) async {
    var task = _taskForRun(run);
    if (!_canContinue(task) || line.url == null) return _staleResult;
    task = task!.copyWith(
      status: MediaDownloadTaskStatus.downloading,
      updatedAt: _now(),
      lineId: line.id,
      providerName: line.providerName,
      format: line.format,
      url: line.url,
      headers: line.headers,
      message: '正在通过 ${line.providerName} 下载',
    );
    _replaceTask(run.scope, task);
    await _persistNow(run.scope);
    final persistedTask = _taskForRun(run);
    if (!_canContinue(persistedTask)) return _staleResult;
    task = persistedTask!;

    final producedPaths = <String?>{task.temporaryPath, task.localPath};
    MediaDownloadResult result;
    try {
      result = await _service.download(
        // The stable task id belongs to persisted product state. A separate
        // run-scoped file id prevents a timed-out old account/run from
        // writing to the same default path as a newer run of the same media.
        taskId: _fileTaskId(run),
        controlId: run.controlId,
        url: line.url!,
        title: '${task.subject.title}_EP${task.episode.number}',
        headers: line.headers,
        format: line.format,
        temporaryPath: task.temporaryPath,
        targetPath: task.localPath,
        etag: task.etag,
        lastModified: task.lastModified,
        onProgress: (progress) {
          producedPaths
            ..add(progress.temporaryPath)
            ..add(progress.targetPath);
          _updateDownloadProgress(run, progress);
        },
      );
    } catch (_) {
      if (_taskForRun(run) == null) {
        await _deleteFilesNotOwnedByCurrentSnapshot(producedPaths);
      }
      rethrow;
    }

    var latest = _taskForRun(run);
    if (latest == null || latest.status == MediaDownloadTaskStatus.cancelled) {
      await _deleteFilesNotOwnedByCurrentSnapshot({
        ...producedPaths,
        result.temporaryPath,
        result.path,
      });
      return result;
    }
    if (latest.status == MediaDownloadTaskStatus.paused) {
      if (result.success) {
        // A backend may finish just after pause wins the controller race.
        // Keep the user-visible task paused and remove the untracked final
        // artifact rather than silently promoting or leaking it.
        await _service.deleteFiles([result.path]);
      }
      return result;
    }
    if (result.success) {
      _replaceTask(
        run.scope,
        latest.copyWith(
          status: MediaDownloadTaskStatus.verifying,
          updatedAt: _now(),
          message: '正在校验下载文件',
        ),
      );
      await _persistNow(run.scope);
      final verification = await _service.verifyFile(
        result.path,
        expectedBytes: result.bytes > 0 ? result.bytes : null,
      );
      final verifiedTask = _taskForRun(run);
      if (verifiedTask == null ||
          verifiedTask.status == MediaDownloadTaskStatus.cancelled) {
        await _deleteFilesNotOwnedByCurrentSnapshot({result.path});
        return result;
      }
      if (verifiedTask.status == MediaDownloadTaskStatus.paused) {
        await _service.deleteFiles([result.path]);
        return result;
      }
      if (!verification.isValid) {
        final status = verification.status == MediaDownloadFileStatus.missing
            ? MediaDownloadTaskStatus.missing
            : MediaDownloadTaskStatus.corrupt;
        _replaceTask(
          run.scope,
          verifiedTask.copyWith(
            status: status,
            updatedAt: _now(),
            message: status == MediaDownloadTaskStatus.missing
                ? '下载完成后找不到本地文件'
                : '下载文件完整性校验失败，请重新下载',
          ),
        );
        await _persistNow(run.scope);
        return MediaDownloadResult(
          outcome: MediaDownloadOutcome.failed,
          message: status == MediaDownloadTaskStatus.missing
              ? '下载完成后找不到本地文件'
              : '下载文件完整性校验失败，请重新下载',
          path: result.path,
          bytes: verification.bytes,
          totalBytes: result.totalBytes,
          etag: result.etag,
          lastModified: result.lastModified,
        );
      }
      latest = verifiedTask;
    }
    final nextStatus = switch (result.outcome) {
      MediaDownloadOutcome.completed => MediaDownloadTaskStatus.completed,
      MediaDownloadOutcome.paused => MediaDownloadTaskStatus.paused,
      MediaDownloadOutcome.cancelled => MediaDownloadTaskStatus.cancelled,
      MediaDownloadOutcome.failed ||
      MediaDownloadOutcome.unsupported => MediaDownloadTaskStatus.failed,
    };
    _replaceTask(
      run.scope,
      latest.copyWith(
        status: nextStatus,
        updatedAt: _now(),
        downloadedBytes: result.cancelled ? 0 : result.bytes,
        totalBytes: result.cancelled ? 0 : result.totalBytes,
        completedUnits: result.cancelled ? 0 : result.completedUnits,
        totalUnits: result.cancelled ? 0 : result.totalUnits,
        temporaryPath: result.cancelled ? null : result.temporaryPath,
        localPath: result.success ? result.path : latest.localPath,
        etag: result.cancelled ? null : result.etag,
        lastModified: result.cancelled ? null : result.lastModified,
        message: result.message,
      ),
    );
    await _persistNow(run.scope);
    return result;
  }

  void _updateDownloadProgress(
    _DownloadRun run,
    MediaDownloadProgress progress,
  ) {
    final task = _taskForRun(run);
    if (task == null || task.status != MediaDownloadTaskStatus.downloading) {
      return;
    }
    _replaceTask(
      run.scope,
      task.copyWith(
        updatedAt: _now(),
        downloadedBytes: progress.downloadedBytes,
        totalBytes: progress.totalBytes,
        completedUnits: progress.completedUnits,
        totalUnits: progress.totalUnits,
        temporaryPath: progress.temporaryPath,
        localPath: progress.targetPath.trim().isEmpty
            ? task.localPath
            : progress.targetPath,
        etag: progress.etag,
        lastModified: progress.lastModified,
      ),
    );
    _schedulePersist(run);
  }

  Future<void> _discardPartialDownload(
    _DownloadRun run,
    MediaDownloadTask task,
  ) async {
    await _service.deleteFiles([task.temporaryPath, task.localPath]);
    final latest = _taskForRun(run);
    if (latest == null) return;
    _replaceTask(
      run.scope,
      latest.copyWith(
        downloadedBytes: 0,
        totalBytes: 0,
        completedUnits: 0,
        totalUnits: 0,
        temporaryPath: null,
        localPath: null,
        etag: null,
        lastModified: null,
      ),
    );
    await _persistNow(run.scope);
  }

  Future<void> _deleteFilesNotOwnedByCurrentSnapshot(Iterable<String?> paths) {
    final ownedPaths = <String>{
      for (final task in _snapshot.tasks)
        if (task.temporaryPath?.trim().isNotEmpty == true)
          task.temporaryPath!.trim(),
      for (final task in _snapshot.tasks)
        if (task.localPath?.trim().isNotEmpty == true) task.localPath!.trim(),
    };
    return _service.deleteFiles(
      paths.where((path) => path == null || !ownedPaths.contains(path.trim())),
    );
  }

  Future<List<MediaDownloadTask>> _readTasks(_DownloadScope scope) async {
    final storageKey = _storageKey(scope.accountId);
    final value = _storage.get(storageKey);
    if (value is! List) return const [];
    final tasks = <MediaDownloadTask>[];
    var migrated = false;
    for (final raw in value.whereType<Map>()) {
      final json = raw.cast<String, dynamic>();
      MediaDownloadTask task;
      try {
        if (json.containsKey('status') && json.containsKey('id')) {
          task = MediaDownloadTask.fromJson(json);
          final rawHeaders = json['headers'];
          final storedHeaders = rawHeaders is Map
              ? {
                  for (final entry in rawHeaders.entries)
                    entry.key.toString(): entry.value.toString(),
                }
              : const <String, String>{};
          final storedUrl = json['url']?.toString().trim() ?? '';
          final storedMessage = json['message']?.toString() ?? '';
          if (json['version'] != 3 ||
              !_sameStringMap(storedHeaders, task.headers) ||
              storedUrl != (task.url ?? '') ||
              storedMessage != task.message) {
            migrated = true;
          }
        } else {
          task = MediaDownloadTask.fromLegacy(LibraryEntry.fromJson(json));
          migrated = true;
        }
      } catch (_) {
        migrated = true;
        continue;
      }
      if (task.id.trim().isEmpty ||
          task.subject.title.trim().isEmpty ||
          task.episode.id == 0) {
        migrated = true;
        continue;
      }
      if (task.isActive) {
        task = task.copyWith(
          status: MediaDownloadTaskStatus.paused,
          updatedAt: _now(),
          message: '上次下载已中断，可以继续下载',
        );
        migrated = true;
      }
      if (task.status == MediaDownloadTaskStatus.completed) {
        final verification = await _service.verifyFile(
          task.localPath,
          expectedBytes: task.totalBytes > 0 ? task.totalBytes : null,
        );
        final nextStatus = switch (verification.status) {
          MediaDownloadFileStatus.valid => MediaDownloadTaskStatus.completed,
          MediaDownloadFileStatus.missing => MediaDownloadTaskStatus.missing,
          MediaDownloadFileStatus.corrupt => MediaDownloadTaskStatus.corrupt,
        };
        if (nextStatus != task.status) {
          task = task.copyWith(
            status: nextStatus,
            updatedAt: _now(),
            message: switch (nextStatus) {
              MediaDownloadTaskStatus.missing => '本地文件已不存在，请重新下载',
              MediaDownloadTaskStatus.corrupt => '本地文件大小异常，请重新下载',
              _ => task.message,
            },
          );
          migrated = true;
        }
      }
      if (task.downloadedBytes > 0 &&
          task.status != MediaDownloadTaskStatus.completed &&
          !await _service.fileExists(task.temporaryPath)) {
        task = task.copyWith(
          downloadedBytes: 0,
          totalBytes: 0,
          completedUnits: 0,
          totalUnits: 0,
          temporaryPath: null,
          etag: null,
          lastModified: null,
          message: task.status == MediaDownloadTaskStatus.paused
              ? '临时文件已不存在，将重新下载'
              : task.message,
        );
        migrated = true;
      }
      tasks.add(task);
    }
    if (migrated) {
      await _persistSnapshot(scope, tasks);
    }
    return tasks;
  }

  MediaDownloadTask? _task(String taskId) =>
      _snapshot.tasks.where((item) => item.id == taskId).firstOrNull;

  MediaDownloadTask? _taskForRun(_DownloadRun run) {
    if (!_isCurrent(run.scope) ||
        !identical(_runs[_runKey(run.scope, run.taskId)], run)) {
      return null;
    }
    return _task(run.taskId);
  }

  bool _canContinue(MediaDownloadTask? task) =>
      task != null &&
      task.status != MediaDownloadTaskStatus.paused &&
      task.status != MediaDownloadTaskStatus.cancelled;

  _DownloadRun? _run(_DownloadScope scope, String taskId) =>
      _runs[_runKey(scope, taskId)];

  void _replaceTask(_DownloadScope scope, MediaDownloadTask task) {
    _ensureScope(scope);
    _publish(
      scope,
      DownloadSnapshot(
        tasks: _snapshot.tasks
            .map((item) => item.id == task.id ? task : item)
            .toList(growable: false),
      ),
    );
  }

  void _publish(_DownloadScope scope, DownloadSnapshot value) {
    _ensureScope(scope);
    _snapshot = DownloadSnapshot(
      tasks: List<MediaDownloadTask>.unmodifiable(value.tasks),
    );
    _publishSnapshot(_snapshot);
  }

  void _schedulePersist(_DownloadRun run) {
    if (!_isCurrent(run.scope)) return;
    final key = _runKey(run.scope, run.taskId);
    final timestamp = _now();
    final last = _persistedAt[key];
    if (last == null || timestamp.difference(last) >= progressPersistInterval) {
      _persistedAt[key] = timestamp;
      unawaited(
        _persistSnapshot(run.scope, _snapshot.tasks).onError((_, _) {}),
      );
      return;
    }
    if (_persistTimer?.isActive ?? false) return;
    _persistTimerScope = run.scope;
    _persistTimer = Timer(progressPersistInterval, () {
      final scope = _persistTimerScope;
      _persistTimer = null;
      _persistTimerScope = null;
      if (scope == null || !_isCurrent(scope)) return;
      _persistedAt[key] = _now();
      unawaited(_persistSnapshot(scope, _snapshot.tasks).onError((_, _) {}));
    });
  }

  Future<void> _persistNow(_DownloadScope scope) {
    if (!_isCurrent(scope)) return Future<void>.value();
    _cancelPersistTimer();
    return _persistSnapshot(scope, _snapshot.tasks);
  }

  Future<void> _persistSnapshot(
    _DownloadScope scope,
    List<MediaDownloadTask> tasks,
  ) {
    final storageKey = _storageKey(scope.accountId);
    final serialized = tasks
        .map((task) => task.toJson())
        .toList(growable: false);
    final operation = _writeQueue.then(
      (_) => _storage.put(storageKey, serialized),
    );
    _writeQueue = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  Future<bool> _acquireSlot(_DownloadRun run) async {
    while (_activeSlots >= maxConcurrentDownloads) {
      if (!_canContinue(_taskForRun(run))) return false;
      final waiter = Completer<void>();
      _slotWaiters.add(waiter);
      await waiter.future;
    }
    if (!_canContinue(_taskForRun(run))) return false;
    _activeSlots++;
    return true;
  }

  void _releaseSlot() {
    if (_activeSlots > 0) _activeSlots--;
    _wakeSlotWaiters();
  }

  void _wakeSlotWaiters({bool force = false}) {
    while (_slotWaiters.isNotEmpty &&
        (force || _activeSlots < maxConcurrentDownloads || _disposed)) {
      _slotWaiters.removeAt(0).complete();
    }
  }

  Duration _retryDelay(int attempt) {
    final shift = (attempt - 1).clamp(0, 5).toInt();
    final multiplier = 1 << shift;
    final milliseconds = retryBaseDelay.inMilliseconds * multiplier;
    return Duration(milliseconds: milliseconds.clamp(0, 8000).toInt());
  }

  Future<bool> _waitForRetry(_DownloadRun run, Duration delay) async {
    final winner = await Future.any<Object?>([
      Future<Object?>.delayed(delay),
      run.stopSignal.future.then<Object?>((_) => true),
    ]);
    if (winner != null) return false;
    return _canContinue(_taskForRun(run));
  }

  bool _cancelPersistTimer() {
    final hadPending = _persistTimer?.isActive ?? false;
    _persistTimer?.cancel();
    _persistTimer = null;
    _persistTimerScope = null;
    return hadPending;
  }

  String _storageKey(String? accountId) =>
      AccountController.libraryKeyFor(accountId, 'offlineTasks');

  String _runKey(_DownloadScope scope, String taskId) =>
      '${scope.epoch}:$taskId';

  String _fileTaskId(_DownloadRun run) =>
      'download-${stableDigest(run.controlId)}';

  _DownloadScope get _currentScope => _DownloadScope(
    accountId: _accountId,
    contextVersion: _contextVersion,
    epoch: _scopeEpoch,
  );

  _DownloadScope _scope() {
    _ensureNotDisposed();
    if (!_loaded) throw StateError('DownloadController has not been loaded');
    return _currentScope;
  }

  bool _isConfigured(_DownloadScope scope) =>
      !_disposed &&
      _accountId == scope.accountId &&
      _contextVersion == scope.contextVersion &&
      _scopeEpoch == scope.epoch;

  bool _isCurrent(_DownloadScope scope) => _loaded && _isConfigured(scope);

  void _ensureConfigured(_DownloadScope scope) {
    if (!_isConfigured(scope)) {
      throw const AccountException('账号已切换，请重新打开下载管理');
    }
  }

  void _ensureScope(_DownloadScope scope) {
    if (!_isCurrent(scope)) {
      throw const AccountException('账号已切换，请在当前账号下重新操作');
    }
  }

  void _ensureNotDisposed() {
    if (_disposed) throw StateError('DownloadController has been disposed');
  }
}

final class _DownloadRun {
  _DownloadRun({
    required this.scope,
    required this.taskId,
    required this.controlId,
  });

  final _DownloadScope scope;
  final String taskId;
  final String controlId;
  final Completer<void> stopSignal = Completer<void>();
  late final Future<void> future;

  void stop() {
    if (!stopSignal.isCompleted) stopSignal.complete();
  }
}

final class _DownloadScope {
  const _DownloadScope({
    required this.accountId,
    required this.contextVersion,
    required this.epoch,
  });

  final String? accountId;
  final int contextVersion;
  final int epoch;

  @override
  bool operator ==(Object other) =>
      other is _DownloadScope &&
      other.accountId == accountId &&
      other.contextVersion == contextVersion &&
      other.epoch == epoch;

  @override
  int get hashCode => Object.hash(accountId, contextVersion, epoch);
}

const _staleResult = MediaDownloadResult(
  outcome: MediaDownloadOutcome.cancelled,
  message: '下载作用域已失效',
);

bool _sameStringMap(Map<String, String> left, Map<String, String> right) {
  if (left.length != right.length) return false;
  for (final entry in left.entries) {
    if (right[entry.key] != entry.value) return false;
  }
  return true;
}

bool _isTemporaryStoragePath(String path) {
  final lower = path.trim().toLowerCase();
  return lower.endsWith('.part') ||
      lower.endsWith('.hls.part') ||
      lower.endsWith('.zeluna-replace');
}
