import 'dart:io';

import 'package:anime/src/updates/app_update_controller.dart';
import 'package:anime/src/updates/app_update_download_io.dart';
import 'package:anime/src/updates/app_update_models.dart';
import 'package:anime/src/updates/app_update_platform.dart';
import 'package:anime/src/updates/app_update_repository.dart';
import 'package:anime/src/updates/app_update_store.dart';
import 'package:anime/src/updates/windows_app_update_platform.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'app_update_repository_test.dart'
    show productionManifest, githubRelease, jsonResponse;

// Empty ZIP archive: end-of-central-directory record, no entries.
final zip = [0x50, 0x4b, 5, 6, ...List.filled(18, 0)];
final hash = sha256.convert(zip).toString();
const name = 'Zeluna-v1.3.1-Windows.zip';

ReleaseAppUpdateRepository repository({int? assetBytes}) {
  final manifest = productionManifest();
  (manifest['artifacts'] as List).add({
    'name': name,
    'bytes': zip.length,
    'sha256': hash,
  });
  final github = githubRelease(manifest);
  (github['assets'] as List).add({
    'name': name,
    'size': assetBytes ?? zip.length,
  });
  return ReleaseAppUpdateRepository(
    targetPlatform: 'windows',
    clientFactory: () => MockClient((request) async {
      if (request.url.host == 'api.github.com') return jsonResponse(github);
      expect(request.url.pathSegments.last, 'Zeluna-v1.3.1-manifest.json');
      return jsonResponse(manifest);
    }),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('zeluna-update-test-');
  });
  tearDown(() => dir.delete(recursive: true));
  test(
    'selects exact Windows asset without native ABIs and cross-checks bytes',
    () async {
      final release = (await repository().check(UpdateCancellation()))!;
      expect(release.platform, 'windows');
      expect(release.abis, isEmpty);
      expect(release.apkUri.pathSegments.last, name);
      expect(release.sha256, hash);
      await expectLater(
        repository(assetBytes: 1).check(UpdateCancellation()),
        throwsA(isA<UpdateFailure>()),
      );
    },
  );
  test(
    'uses application support/updates and never opens a ZIP outside it',
    () async {
      const platform = WindowsAppUpdatePlatform();
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      const storage = MethodChannel('app.anime.anime/storage');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(paths, (call) async {
        expect(call.method, 'getApplicationSupportDirectory');
        return dir.path;
      });
      messenger.setMockMethodCallHandler(storage, (call) async {
        expect(call.method, 'getAvailableBytes');
        expect(
          Directory(call.arguments['path'] as String).uri,
          dir.uri.resolve('updates/'),
        );
        return 123456;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(paths, null);
        messenger.setMockMethodCallHandler(storage, null);
      });
      final target = await platform.downloadDirectory();
      expect(target.availableBytes, 123456);
      expect(await Directory(target.path).exists(), isTrue);
      final release = (await repository().check(UpdateCancellation()))!;
      final outside = File.fromUri(dir.uri.resolve('app-87-$hash.zip'));
      await outside.writeAsBytes(zip);
      await expectLater(
        platform.install(outside.path, release),
        throwsA(
          isA<UpdateFailure>().having((e) => e.code, 'code', 'storage_path'),
        ),
      );
    },
  );
  test(
    'Windows version comes from package info with fallback for a missing build',
    () async {
      for (final build in ['99', '']) {
        PackageInfo.setMockInitialValues(
          appName: 'Zeluna',
          packageName: 'Zeluna',
          version: '3.0.8',
          buildNumber: build,
          buildSignature: '',
        );
        final env = await const WindowsAppUpdatePlatform().environment();
        expect(env.packageName, appUpdatePackageName);
        expect(env.versionName, '3.0.8');
        expect(env.versionCode, build.isEmpty ? 1 : 99);
        expect(env.supportedAbis, ['windows-x64']);
        expect(env.sdkInt, 0);
      }
    },
  );
  test(
    'streamed ZIP verification rejects same-length tampering and truncation',
    () async {
      const platform = WindowsAppUpdatePlatform();
      final release = (await repository().check(UpdateCancellation()))!;
      final file = File.fromUri(dir.uri.resolve(name));
      await file.writeAsBytes(zip);
      await platform.verify(file.path, release);
      await file.writeAsBytes([...zip]..[0] = 0);
      await expectLater(
        platform.verify(file.path, release),
        throwsA(isA<UpdateFailure>()),
      );
      await file.writeAsBytes([1]);
      await expectLater(
        platform.verify(file.path, release),
        throwsA(isA<UpdateFailure>()),
      );
    },
  );
  test(
    'Windows controller downloads an owned ZIP, verifies, persists and discards it',
    () async {
      final store = _Store();
      final controller = AppUpdateController(
        supported: true,
        repository: repository(),
        platform: _Platform(dir),
        store: store,
        downloader: IoAppUpdateDownloader(
          clientFactory: () => MockClient((request) async {
            expect(request.url.pathSegments.last, name);
            expect(request.headers['accept'], 'application/zip');
            return http.Response.bytes(zip, 200);
          }),
        ),
      );
      addTearDown(controller.dispose);
      final phases = <AppUpdatePhase>[];
      controller.addListener(() => phases.add(controller.phase));
      await controller.check();
      await controller.download();
      expect(
        phases,
        containsAllInOrder([
          AppUpdatePhase.checking,
          AppUpdatePhase.available,
          AppUpdatePhase.downloading,
          AppUpdatePhase.verifying,
          AppUpdatePhase.ready,
        ]),
      );
      expect(store.value['pending']['release']['platform'], 'windows');
      final file = File(store.value['pending']['path'] as String);
      expect(file.uri.pathSegments.last, 'app-87-$hash.zip');
      expect(await file.readAsBytes(), zip);
      await controller.discardDownload();
      expect(await file.exists(), isFalse);
    },
  );
}

class _Platform extends WindowsAppUpdatePlatform {
  const _Platform(this.dir);
  final Directory dir;
  @override
  Future<InstalledUpdateEnvironment> environment() async =>
      const InstalledUpdateEnvironment(
        packageName: appUpdatePackageName,
        versionName: '1.3.0',
        versionCode: 86,
        sdkInt: 0,
        supportedAbis: ['windows-x64'],
        canRequestInstallPackages: true,
      );
  @override
  Future<UpdateDownloadDirectory> downloadDirectory() async =>
      UpdateDownloadDirectory(dir.path, 1024 * 1024 * 1024);
}

class _Store implements AppUpdateStore {
  Map<String, dynamic> value = {};
  @override
  Future<Map<String, dynamic>> read() async => value;
  @override
  Future<void> write(Map<String, dynamic> next) async {
    value = next;
  }
}
