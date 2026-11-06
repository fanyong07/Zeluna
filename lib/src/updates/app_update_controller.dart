import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_update_download.dart';
import 'app_update_models.dart';
import 'app_update_platform.dart';
import 'app_update_repository.dart';
import 'app_update_store.dart';

enum AppUpdatePhase {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  verifying,
  ready,
  permissionRequired,
  openingInstaller,
  installerOpened,
  failed,
  unsupported,
}

final appUpdateControllerProvider = Provider<AppUpdateController>((ref) {
  final controller = AppUpdateController(
    supported: !kIsWeb && defaultTargetPlatform == TargetPlatform.android,
    repository: ReleaseAppUpdateRepository(),
    downloader: createAppUpdateDownloader(),
    platform: const AndroidAppUpdatePlatform(),
    store: HiveAppUpdateStore(),
  );
  ref.onDispose(controller.dispose);
  return controller;
});

/// One app-scoped operation survives route changes. Downloads never auto-install;
/// permission returns only restore the explicit Install button.
class AppUpdateController extends ChangeNotifier {
  AppUpdateController({
    required this.supported,
    required AppUpdateRepository repository,
    required AppUpdateDownloader downloader,
    required AppUpdatePlatform platform,
    required AppUpdateStore store,
    DateTime Function()? now,
  }) : _repository = repository,
       _downloader = downloader,
       _platform = platform,
       _store = store,
       _now = now ?? DateTime.now;

  final bool supported;
  final AppUpdateRepository _repository;
  final AppUpdateDownloader _downloader;
  final AppUpdatePlatform _platform;
  final AppUpdateStore _store;
  final DateTime Function() _now;
  AppUpdatePhase phase = AppUpdatePhase.idle;
  InstalledUpdateEnvironment? environment;
  UpdateRelease? release;
  UpdateProgress? progress;
  String? errorMessage;
  String? _path;
  bool automaticChecks = false;
  DateTime? lastChecked;
  bool _disposed = false;
  bool _awaitingPermission = false;
  bool _resuming = false;
  bool _operationActive = false;
  int _settingsGeneration = 0;
  Future<void>? _initialization;
  bool _initialized = false;
  UpdateCancellation? _cancellation;
  int _generation = 0;
  Future<void> _writes = Future<void>.value();
  DateTime? _lastProgress;

  bool get busy =>
      _operationActive ||
      _resuming ||
      {
        AppUpdatePhase.checking,
        AppUpdatePhase.downloading,
        AppUpdatePhase.verifying,
        AppUpdatePhase.openingInstaller,
      }.contains(phase);
  bool get hasInstaller => _path != null && release != null;
  bool get canCancel =>
      phase == AppUpdatePhase.checking || phase == AppUpdatePhase.downloading;
  bool get initializing =>
      _initialization != null && environment == null && supported;

  Future<void> initialize() {
    if (_disposed || _initialized) return Future<void>.value();
    return _initialization ??= _initialize().whenComplete(() {
      _initialization = null;
    });
  }

  Future<void> _initialize() async {
    if (!supported) {
      phase = AppUpdatePhase.unsupported;
      _initialized = true;
      _notify();
      return;
    }
    try {
      final saved = await _store.read();
      if (_disposed) return;
      automaticChecks = saved['automaticChecks'] == true;
      lastChecked = DateTime.tryParse(saved['lastChecked']?.toString() ?? '');
      environment = await _platform.environment();
      if (_disposed) return;
      final pending = saved['pending'];
      if (pending is Map &&
          pending['release'] is Map &&
          pending['path'] is String) {
        try {
          final candidate = UpdateRelease.fromJson(
            Map<String, dynamic>.from(pending['release'] as Map),
          );
          if (_compatible(candidate) &&
              candidate.isNewerThan(
                environment!.versionName,
                environment!.versionCode,
              )) {
            phase = AppUpdatePhase.verifying;
            _notify();
            await _platform.verify(pending['path'] as String, candidate);
            if (_disposed) return;
            release = candidate;
            _path = pending['path'] as String;
            phase = AppUpdatePhase.ready;
          } else if (!candidate.isNewerThan(
            environment!.versionName,
            environment!.versionCode,
          )) {
            // Upgrades may kill the old process before it can remove its APK.
            // Delete only our strict filenames in the newly queried native dir.
            await _discardPrivate(pending['path'] as String);
          }
        } catch (_) {
          // Cache eviction, a stale version or a replaced package clears the
          // pending reference. Never delete an arbitrary persisted path.
          _path = null;
          phase = AppUpdatePhase.idle;
        }
      }
      if (!_disposed) {
        await _persist();
        _initialized = true;
        errorMessage = null;
        if (phase == AppUpdatePhase.failed) phase = AppUpdatePhase.idle;
        _notify();
      }
    } catch (error) {
      if (!_disposed) {
        phase = AppUpdatePhase.failed;
        errorMessage = updateErrorMessage(error);
        _notify();
      }
    }
  }

  bool _compatible(UpdateRelease value) {
    final env = environment;
    return env != null &&
        env.packageName == 'app.anime.anime' &&
        (value.minSdk == null || value.minSdk! <= env.sdkInt) &&
        (value.abis.isEmpty || value.abis.any(env.supportedAbis.contains));
  }

  Future<void> setAutomaticChecks(bool value) async {
    await initialize();
    if (_disposed || !_initialized || !supported) return;
    final previous = automaticChecks;
    final own = ++_settingsGeneration;
    automaticChecks = value;
    try {
      await _persist();
    } catch (_) {
      if (!_disposed && own == _settingsGeneration) {
        automaticChecks = previous;
        errorMessage = '更新设置保存失败，请稍后重试';
      }
    }
    _notify();
  }

  /// Called on a non-player route; enabled checks run at most once per 24h,
  /// including failures, so startup never loops on an unavailable endpoint.
  Future<void> maybeCheckAutomatically({bool Function()? canCheck}) async {
    await initialize();
    if (canCheck != null && !canCheck()) return;
    if (_disposed ||
        !_initialized ||
        !automaticChecks ||
        busy ||
        hasInstaller) {
      return;
    }
    final age = lastChecked == null ? null : _now().difference(lastChecked!);
    if (age != null && (age.isNegative || age < const Duration(hours: 24))) {
      return;
    }
    await check();
  }

  Future<void> check() async {
    await initialize();
    if (_disposed || !_initialized || !supported || busy || hasInstaller) {
      return;
    }
    final own = ++_generation;
    _operationActive = true;
    final token = _cancellation = UpdateCancellation();
    phase = AppUpdatePhase.checking;
    errorMessage = null;
    progress = null;
    lastChecked = _now();
    _notify();
    try {
      await _persist();
      environment = await _platform.environment();
      token.throwIfCancelled();
      final candidate = await _repository.check(token);
      token.throwIfCancelled();
      if (!_current(own)) return;
      if (candidate == null ||
          !candidate.isNewerThan(
            environment!.versionName,
            environment!.versionCode,
          )) {
        release = null;
        phase = AppUpdatePhase.upToDate;
      } else if (!_compatible(candidate)) {
        release = null;
        throw const UpdateFailure('incompatible', '新版本暂不适用于此设备，请等待兼容的安装包');
      } else {
        release = candidate;
        phase = AppUpdatePhase.available;
      }
    } on UpdateCancelled {
      if (_current(own)) {
        phase = release == null
            ? AppUpdatePhase.idle
            : AppUpdatePhase.available;
      }
    } catch (error) {
      if (_current(own)) {
        phase = AppUpdatePhase.failed;
        errorMessage = updateErrorMessage(error);
      }
    } finally {
      if (_current(own)) {
        _cancellation = null;
        _operationActive = false;
        _notify();
      }
    }
  }

  Future<void> download() async {
    await initialize();
    final selected = release;
    if (_disposed ||
        !_initialized ||
        !supported ||
        busy ||
        selected == null ||
        hasInstaller) {
      return;
    }
    final own = ++_generation;
    _operationActive = true;
    final token = _cancellation = UpdateCancellation();
    phase = AppUpdatePhase.downloading;
    errorMessage = null;
    progress = UpdateProgress(received: 0, total: selected.bytes);
    _lastProgress = null;
    _notify();
    String? downloaded;
    try {
      final directory = await _platform.downloadDirectory();
      token.throwIfCancelled();
      // Space for the archive plus installation staging; this is an early
      // check, not a guarantee about Android's system installation partition.
      if (directory.availableBytes < selected.bytes * 2 + 32 * 1024 * 1024) {
        throw const UpdateFailure('space', '可用空间不足，请清理空间后重试');
      }
      downloaded = await _downloader.download(
        selected,
        directory: directory.path,
        cancellation: token,
        onProgress: (value) {
          if (!_current(own)) return;
          progress = value;
          final now = _now();
          if (_lastProgress == null ||
              now.difference(_lastProgress!) >=
                  const Duration(milliseconds: 200) ||
              value.received == value.total) {
            _lastProgress = now;
            _notify();
          }
        },
      );
      token.throwIfCancelled();
      if (!_current(own)) return;
      phase = AppUpdatePhase.verifying;
      _notify();
      await _platform.verify(downloaded, selected);
      if (!_current(own)) return;
      _path = downloaded;
      phase = AppUpdatePhase.ready;
      await _persist();
    } on UpdateCancelled {
      if (_current(own)) phase = AppUpdatePhase.available;
    } catch (error) {
      if (_current(own)) {
        _path = null;
        phase = AppUpdatePhase.failed;
        errorMessage = updateErrorMessage(error);
      }
    } finally {
      if (downloaded != null && _path != downloaded) {
        try {
          await _downloader.discard(downloaded);
        } catch (_) {}
      }
      if (_current(own)) {
        _cancellation = null;
        _operationActive = false;
        _notify();
      }
    }
  }

  void cancel() {
    if (!canCancel) return;
    // Keep the operation busy until its cleanup completes. A replacement
    // download must not race deletion of its own part file by an old task.
    _cancellation?.cancel();
  }

  Future<void> install() async {
    await initialize();
    final selected = release;
    final path = _path;
    if (_disposed ||
        !_initialized ||
        busy ||
        selected == null ||
        path == null) {
      return;
    }
    ++_generation;
    _operationActive = true;
    phase = AppUpdatePhase.openingInstaller;
    errorMessage = null;
    _notify();
    try {
      final launched = await _platform.install(path, selected);
      if (_disposed) return;
      phase = launched
          ? AppUpdatePhase.installerOpened
          : AppUpdatePhase.permissionRequired;
    } catch (error) {
      if (!_disposed) {
        if (updateErrorInvalidatesPackage(error)) {
          await _discardPrivate(path);
          if (_disposed) return;
          _path = null;
          try {
            await _persist();
          } catch (_) {}
        }
        phase = AppUpdatePhase.failed;
        errorMessage = updateErrorMessage(error);
      }
    } finally {
      _operationActive = false;
      _notify();
    }
  }

  Future<void> openPermissionSettings() async {
    if (_disposed ||
        busy ||
        phase != AppUpdatePhase.permissionRequired ||
        _awaitingPermission) {
      return;
    }
    _awaitingPermission = true;
    try {
      if (!await _platform.openInstallPermission()) {
        _awaitingPermission = false;
        errorMessage = '请在系统设置中允许 Zeluna 安装应用后返回';
      }
    } catch (error) {
      _awaitingPermission = false;
      errorMessage = updateErrorMessage(error);
    }
    _notify();
  }

  Future<void> onResumed() async {
    if (_disposed ||
        _resuming ||
        busy ||
        !hasInstaller ||
        (!_awaitingPermission &&
            phase != AppUpdatePhase.installerOpened &&
            phase != AppUpdatePhase.permissionRequired)) {
      return;
    }
    _resuming = true;
    final own = _generation;
    _notify();
    try {
      final env = await _platform.environment();
      if (!_current(own)) return;
      environment = env;
      if (!release!.isNewerThan(env.versionName, env.versionCode)) {
        await _discardPrivate(_path!);
        if (!_current(own)) return;
        _path = null;
        release = null;
        phase = AppUpdatePhase.upToDate;
        await _persist();
      } else if (_awaitingPermission ||
          phase == AppUpdatePhase.permissionRequired) {
        // Returning from Settings never launches an installer without a fresh tap.
        phase = env.canRequestInstallPackages
            ? AppUpdatePhase.ready
            : AppUpdatePhase.permissionRequired;
      }
      errorMessage = null;
    } catch (error) {
      if (!_disposed) errorMessage = updateErrorMessage(error);
    } finally {
      _awaitingPermission = false;
      _resuming = false;
      _notify();
    }
  }

  Future<void> discardDownload() async {
    if (_disposed || busy || !hasInstaller) return;
    final own = ++_generation;
    final path = _path!;
    _operationActive = true;
    _awaitingPermission = false;
    _notify();
    try {
      final directory = await _platform.downloadDirectory();
      if (!_current(own)) return;
      await _downloader.discard(path, directory: directory.path);
      if (!_current(own)) return;
      _path = null;
      phase = release == null ? AppUpdatePhase.idle : AppUpdatePhase.available;
      await _persist();
      errorMessage = null;
    } catch (_) {
      if (_current(own)) errorMessage = '安装包清理未完成，可稍后重试';
    } finally {
      if (_current(own)) {
        _operationActive = false;
        _notify();
      }
    }
  }

  Future<void> _discardPrivate(String path) async {
    try {
      final directory = await _platform.downloadDirectory();
      if (_disposed) return;
      await _downloader.discard(path, directory: directory.path);
    } catch (_) {
      // Cleanup is best effort; the installer reference is invalidated even
      // when Android already evicted the private cache file.
    }
  }

  bool _current(int own) => !_disposed && own == _generation;
  Future<void> _persist() {
    final snapshot = <String, dynamic>{
      'automaticChecks': automaticChecks,
      'lastChecked': lastChecked?.toIso8601String(),
      if (hasInstaller)
        'pending': {'path': _path, 'release': release!.toJson()},
    };
    final write = _writes.then((_) => _store.write(snapshot));
    _writes = write.catchError((Object _) {});
    return write;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _cancellation?.cancel();
    super.dispose();
  }
}
