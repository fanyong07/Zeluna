import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'app_update_models.dart';
import 'app_update_platform.dart';

class WindowsAppUpdatePlatform implements AppUpdatePlatform {
  const WindowsAppUpdatePlatform();

  @override
  Future<InstalledUpdateEnvironment> environment() async {
    final info = await PackageInfo.fromPlatform();
    return InstalledUpdateEnvironment(
      packageName: appUpdatePackageName,
      versionName: info.version,
      versionCode: int.tryParse(info.buildNumber) ?? 1,
      sdkInt: 0,
      supportedAbis: const ['windows-x64'],
      canRequestInstallPackages: true,
    );
  }

  Future<Directory> _updates() async => Directory.fromUri(
    (await getApplicationSupportDirectory()).uri.resolve('updates/'),
  );

  @override
  Future<UpdateDownloadDirectory> downloadDirectory() async {
    final dir = await (await _updates()).create(recursive: true);
    final bytes = await const MethodChannel(
      'app.anime.anime/storage',
    ).invokeMethod<int>('getAvailableBytes', {'path': dir.path});
    if (bytes == null || bytes < 0) {
      throw const UpdateFailure('storage', '读取更新存储空间失败，请重试');
    }
    return UpdateDownloadDirectory(dir.path, bytes);
  }

  @override
  Future<void> verify(String path, UpdateRelease release) async {
    const failure = UpdateFailure('verification', '更新包校验失败，请重新下载');
    final file = File(path);
    try {
      if (await FileSystemEntity.type(path, followLinks: false) !=
              FileSystemEntityType.file ||
          await file.length() != release.bytes ||
          (await sha256.bind(file.openRead()).first).toString() !=
              release.sha256) {
        throw failure;
      }
    } on FileSystemException {
      throw failure;
    }
  }

  @override
  Future<bool> openInstallPermission() async => true;

  @override
  Future<bool> install(String path, UpdateRelease release) async {
    final root = await _updates();
    final expected = File.fromUri(
      root.uri.resolve('app-${release.buildNumber}-${release.sha256}.zip'),
    ).absolute.path;
    final file = File(path);
    const invalid = UpdateFailure('storage_path', '更新包文件位置不正确，请重新下载');
    if (path.toLowerCase() != expected.toLowerCase() ||
        !await file.exists() ||
        (await file.resolveSymbolicLinks()).toLowerCase() !=
            expected.toLowerCase()) {
      throw invalid;
    }
    await verify(path, release);
    final explorer = File(
      '${Platform.environment['SystemRoot']}\\explorer.exe',
    );
    if (!explorer.isAbsolute || !await explorer.exists()) {
      throw const UpdateFailure('explorer', '找不到 Windows 资源管理器');
    }
    await Process.start(explorer.path, [
      '/select,',
      path,
    ], mode: ProcessStartMode.detached);
    return true;
  }
}
