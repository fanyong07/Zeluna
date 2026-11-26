import 'dart:async';

import 'package:anime/src/updates/app_update_controller.dart';
import 'package:anime/src/updates/app_update_download.dart';
import 'package:anime/src/updates/app_update_models.dart';
import 'package:anime/src/updates/app_update_platform.dart';
import 'package:anime/src/updates/app_update_repository.dart';
import 'package:anime/src/updates/app_update_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'check/download verify then explicit install, never auto install',
    () async {
      final f = _Fixture();
      addTearDown(f.controller.dispose);
      await f.controller.check();
      expect(f.controller.phase, AppUpdatePhase.available);
      expect(f.downloader.downloads, 0);
      await f.controller.download();
      expect(f.controller.phase, AppUpdatePhase.ready);
      expect(f.platform.verifications, 1);
      expect(f.platform.installs, 0);
      expect(f.store.value['pending'], isNotNull);
      await f.controller.install();
      expect(f.controller.phase, AppUpdatePhase.installerOpened);
      expect(f.platform.installs, 1);
    },
  );

  test(
    'installer denied then permission return restores button without launch',
    () async {
      final f = _Fixture();
      addTearDown(f.controller.dispose);
      await f.controller.check();
      await f.controller.download();
      f.platform.allowed = false;
      await f.controller.install();
      expect(f.controller.phase, AppUpdatePhase.permissionRequired);
      await f.controller.openPermissionSettings();
      expect(f.platform.permissionOpens, 1);
      f.platform.allowed = true;
      await f.controller.onResumed();
      expect(f.controller.phase, AppUpdatePhase.ready);
      expect(
        f.platform.installs,
        1,
        reason: 'Settings return is not consent to install',
      );
      await f.controller.install();
      expect(f.platform.installs, 2);
    },
  );

  test(
    'new process restores ready metadata only after native reverification',
    () async {
      final f = _Fixture();
      await f.controller.check();
      await f.controller.download();
      f.controller.dispose();
      final next = f.newController();
      addTearDown(next.dispose);
      await next.initialize();
      expect(next.phase, AppUpdatePhase.ready);
      expect(f.platform.verifications, 2);
      expect(f.platform.installs, 0);
      await next.discardDownload();
      expect(next.hasInstaller, isFalse);
      expect(f.downloader.discarded.last, '/private/app_updates/fixture.apk');
      expect(f.downloader.discardDirectory, '/private/app_updates');
    },
  );

  test(
    'expired pending package is cleared without installing/deleting untrusted path',
    () async {
      final f = _Fixture();
      addTearDown(f.controller.dispose);
      f.store.value = {
        'pending': {
          'path': '/other/untrusted.apk',
          'release': _release.toJson(),
        },
      };
      f.platform.failure = PlatformException(code: 'update_invalid_path');
      await f.controller.initialize();
      expect(f.controller.hasInstaller, isFalse);
      expect(f.store.value['pending'], isNull);
      expect(f.downloader.discarded, isEmpty);
      expect(f.platform.installs, 0);
    },
  );

  test('low disk refuses download before fetching bytes', () async {
    final f = _Fixture();
    addTearDown(f.controller.dispose);
    f.platform.available = 0;
    await f.controller.check();
    await f.controller.download();
    expect(f.controller.phase, AppUpdatePhase.failed);
    expect(f.controller.errorMessage, contains('空间不足'));
    expect(f.downloader.downloads, 0);
  });

  test(
    'signature failure cleans downloaded package and never exposes install',
    () async {
      final f = _Fixture();
      addTearDown(f.controller.dispose);
      await f.controller.check();
      f.platform.failure = PlatformException(code: 'update_signature_mismatch');
      await f.controller.download();
      expect(f.controller.phase, AppUpdatePhase.failed);
      expect(f.controller.errorMessage, contains('签名'));
      expect(f.controller.hasInstaller, isFalse);
      expect(f.downloader.discarded, hasLength(1));
    },
  );

  test(
    'cancellation keeps slot until old request cleanup, late check ignored',
    () async {
      final f = _Fixture();
      addTearDown(f.controller.dispose);
      final pending = Completer<UpdateRelease?>();
      f.repository.pending = pending.future;
      final check = f.controller.check();
      await Future<void>.delayed(Duration.zero);
      expect(f.controller.phase, AppUpdatePhase.checking);
      f.controller.cancel();
      await f.controller.check();
      expect(f.repository.calls, 1);
      pending.complete(_release);
      await check;
      expect(f.controller.release, isNull);
      expect(f.controller.phase, AppUpdatePhase.idle);
    },
  );

  test(
    'concurrent downloads single-flight and disposal suppresses late publish',
    () async {
      final f = _Fixture();
      await f.controller.check();
      final pending = Completer<String>();
      f.downloader.pending = pending.future;
      final download = f.controller.download();
      await Future<void>.delayed(Duration.zero);
      await f.controller.download();
      expect(f.downloader.downloads, 1);
      f.controller.dispose();
      pending.complete('/private/app_updates/fixture.apk');
      await download;
      expect(f.platform.installs, 0);
      expect(f.platform.verifications, 0);
      expect(f.downloader.discarded, hasLength(1));
    },
  );

  test(
    'automatic checks opt-in and limited to 24h including failures',
    () async {
      final f = _Fixture();
      addTearDown(f.controller.dispose);
      await f.controller.maybeCheckAutomatically();
      expect(f.repository.calls, 0);
      await f.controller.setAutomaticChecks(true);
      f.repository.failure = const UpdateFailure('offline', '网络异常');
      await f.controller.maybeCheckAutomatically();
      await f.controller.maybeCheckAutomatically();
      expect(f.repository.calls, 1);
      f.now = f.now.add(const Duration(hours: 25));
      await f.controller.maybeCheckAutomatically();
      expect(f.repository.calls, 2);
    },
  );

  test(
    'same/older build and incompatible ABI do not become downloadable',
    () async {
      final f = _Fixture();
      addTearDown(f.controller.dispose);
      f.platform.versionCode = 100;
      await f.controller.check();
      expect(f.controller.phase, AppUpdatePhase.upToDate);
      f.platform.versionCode = 87;
      f.platform.abis = ['armeabi-v7a'];
      await f.controller.check();
      expect(f.controller.phase, AppUpdatePhase.failed);
      expect(f.controller.hasInstaller, isFalse);
    },
  );

  test(
    'non-Android initialization performs no storage/network/platform work',
    () async {
      final f = _Fixture(supported: false);
      addTearDown(f.controller.dispose);
      await f.controller.check();
      expect(f.controller.phase, AppUpdatePhase.unsupported);
      expect(f.repository.calls, 0);
      expect(f.platform.reads, 0);
      expect(f.store.reads, 0);
    },
  );

  test(
    'initialization failure retries without overwriting existing preferences',
    () async {
      final f = _Fixture();
      addTearDown(f.controller.dispose);
      f.store.value = {'automaticChecks': true};
      f.store.readFailure = StateError('temporary storage failure');
      await f.controller.check();
      expect(f.repository.calls, 0);
      expect(f.store.value['automaticChecks'], isTrue);
      f.store.readFailure = null;
      await f.controller.check();
      expect(f.controller.automaticChecks, isTrue);
      expect(f.repository.calls, 1);
    },
  );

  test('delete holds operation slot until file cleanup completes', () async {
    final f = _Fixture();
    addTearDown(f.controller.dispose);
    await f.controller.check();
    await f.controller.download();
    final cleanup = Completer<void>();
    f.downloader.pendingDiscard = cleanup.future;
    final deleting = f.controller.discardDownload();
    await Future<void>.delayed(Duration.zero);
    expect(f.controller.busy, isTrue);
    await f.controller.download();
    await f.controller.check();
    await f.controller.install();
    expect(f.downloader.downloads, 1);
    expect(f.platform.installs, 0);
    cleanup.complete();
    await deleting;
    expect(f.controller.busy, isFalse);
    await f.controller.download();
    expect(f.downloader.downloads, 2);
  });

  test(
    'verification failure holds slot through asynchronous cleanup',
    () async {
      final f = _Fixture();
      addTearDown(f.controller.dispose);
      await f.controller.check();
      f.platform.failure = PlatformException(code: 'update_hash_mismatch');
      final cleanup = Completer<void>();
      f.downloader.pendingDiscard = cleanup.future;
      final first = f.controller.download();
      await Future<void>.delayed(Duration.zero);
      expect(f.downloader.discarded, hasLength(1));
      expect(f.controller.busy, isTrue);
      await f.controller.download();
      expect(f.downloader.downloads, 1);
      cleanup.complete();
      await first;
      expect(f.controller.busy, isFalse);
    },
  );

  test(
    'permission return serializes with deletion and installer launch',
    () async {
      final f = _Fixture();
      addTearDown(f.controller.dispose);
      await f.controller.check();
      await f.controller.download();
      f.platform.allowed = false;
      await f.controller.install();
      final gate = Completer<InstalledUpdateEnvironment>();
      f.platform.pendingEnvironment = gate.future;
      final returning = f.controller.onResumed();
      await Future<void>.delayed(Duration.zero);
      await f.controller.discardDownload();
      await f.controller.install();
      expect(f.platform.installs, 1);
      expect(f.downloader.discarded, isEmpty);
      f.platform.pendingEnvironment = null;
      f.platform.allowed = true;
      gate.complete(await f.platform.environment());
      await returning;
      expect(f.controller.phase, AppUpdatePhase.ready);
      expect(f.controller.busy, isFalse);
    },
  );

  test(
    'old failed settings write cannot roll back newer successful choice',
    () async {
      final f = _Fixture();
      addTearDown(f.controller.dispose);
      await f.controller.initialize();
      final gate = Completer<void>();
      f.store.nextWrite = gate.future;
      final first = f.controller.setAutomaticChecks(true);
      await Future<void>.delayed(Duration.zero);
      final second = f.controller.setAutomaticChecks(false);
      final third = f.controller.setAutomaticChecks(true);
      gate.completeError(StateError('disk'));
      await Future.wait([first, second, third]);
      expect(f.controller.automaticChecks, isTrue);
      expect(f.store.value['automaticChecks'], isTrue);
    },
  );

  test(
    'installer revalidation failure clears pending and enables redownload',
    () async {
      final f = _Fixture();
      addTearDown(f.controller.dispose);
      await f.controller.check();
      await f.controller.download();
      f.platform.failure = PlatformException(code: 'update_hash_mismatch');
      await f.controller.install();
      expect(f.controller.hasInstaller, isFalse);
      expect(f.controller.phase, AppUpdatePhase.failed);
      expect(f.store.value['pending'], isNull);
      expect(f.downloader.discarded, hasLength(1));
      f.platform.failure = null;
      await f.controller.download();
      expect(f.controller.hasInstaller, isTrue);
    },
  );

  test('resuming after a completed upgrade clears pending state', () async {
    final f = _Fixture();
    addTearDown(f.controller.dispose);
    await f.controller.check();
    await f.controller.download();
    await f.controller.install();
    f.platform.versionCode = 88;
    f.platform.versionName = '1.3.2';
    await f.controller.onResumed();
    expect(f.controller.phase, AppUpdatePhase.upToDate);
    expect(f.store.value['pending'], isNull);
  });
}

final _release = UpdateRelease(
  version: '1.3.2',
  buildNumber: 88,
  apkUri: Uri.parse('https://example.com/app.apk'),
  sha256: 'a' * 64,
  bytes: 1234,
  notes: '修复与改进',
  abis: const ['arm64-v8a'],
  minSdk: 24,
);

class _Fixture {
  _Fixture({bool supported = true}) {
    controller = newController(supported: supported);
  }
  final repository = _Repository();
  final downloader = _Downloader();
  final platform = _Platform();
  final store = _Store();
  var now = DateTime.utc(2026, 11, 7);
  late AppUpdateController controller;
  AppUpdateController newController({bool supported = true}) =>
      AppUpdateController(
        supported: supported,
        repository: repository,
        downloader: downloader,
        platform: platform,
        store: store,
        now: () => now,
      );
}

class _Repository implements AppUpdateRepository {
  int calls = 0;
  Future<UpdateRelease?>? pending;
  Object? failure;
  @override
  Future<UpdateRelease?> check(UpdateCancellation cancellation) async {
    calls++;
    if (failure != null) throw failure!;
    final result = await (pending ?? Future.value(_release));
    cancellation.throwIfCancelled();
    return result;
  }
}

class _Downloader implements AppUpdateDownloader {
  int downloads = 0;
  Future<String>? pending;
  Future<void>? pendingDiscard;
  final discarded = <String>[];
  String? discardDirectory;
  @override
  Future<String> download(
    UpdateRelease release, {
    required String directory,
    required UpdateCancellation cancellation,
    required void Function(UpdateProgress) onProgress,
  }) async {
    downloads++;
    onProgress(UpdateProgress(received: release.bytes, total: release.bytes));
    return pending ?? Future.value('$directory/fixture.apk');
  }

  @override
  Future<void> discard(String path, {String? directory}) async {
    discarded.add(path);
    discardDirectory = directory;
    if (pendingDiscard != null) await pendingDiscard;
  }
}

class _Platform implements AppUpdatePlatform {
  int reads = 0, verifications = 0, installs = 0, permissionOpens = 0;
  int available = 1024 * 1024 * 1024, versionCode = 87;
  String versionName = '1.3.1';
  List<String> abis = ['arm64-v8a'];
  bool allowed = true;
  Object? failure;
  Future<InstalledUpdateEnvironment>? pendingEnvironment;
  @override
  Future<InstalledUpdateEnvironment> environment() async {
    reads++;
    if (pendingEnvironment != null) return pendingEnvironment!;
    return InstalledUpdateEnvironment(
      packageName: 'app.anime.anime',
      versionName: versionName,
      versionCode: versionCode,
      sdkInt: 35,
      supportedAbis: abis,
      canRequestInstallPackages: allowed,
    );
  }

  @override
  Future<UpdateDownloadDirectory> downloadDirectory() async =>
      UpdateDownloadDirectory('/private/app_updates', available);
  @override
  Future<void> verify(String path, UpdateRelease release) async {
    verifications++;
    if (failure != null) throw failure!;
  }

  @override
  Future<bool> install(String path, UpdateRelease release) async {
    installs++;
    if (failure != null) throw failure!;
    return allowed;
  }

  @override
  Future<bool> openInstallPermission() async {
    permissionOpens++;
    return true;
  }
}

class _Store implements AppUpdateStore {
  Map<String, dynamic> value = {};
  int reads = 0;
  Future<void>? nextWrite;
  Object? readFailure;
  @override
  Future<Map<String, dynamic>> read() async {
    reads++;
    if (readFailure != null) throw readFailure!;
    return value;
  }

  @override
  Future<void> write(Map<String, dynamic> data) async {
    final gate = nextWrite;
    nextWrite = null;
    if (gate != null) await gate;
    value = data;
  }
}
