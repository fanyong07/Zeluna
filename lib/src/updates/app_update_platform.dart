import 'package:flutter/services.dart';

import 'app_update_models.dart';

class UpdateDownloadDirectory {
  const UpdateDownloadDirectory(this.path, this.availableBytes);
  final String path;
  final int availableBytes;
}

abstract interface class AppUpdatePlatform {
  Future<InstalledUpdateEnvironment> environment();
  Future<UpdateDownloadDirectory> downloadDirectory();
  Future<void> verify(String path, UpdateRelease release);
  Future<bool> openInstallPermission();

  /// True means the system installer was opened, not that installation succeeded.
  Future<bool> install(String path, UpdateRelease release);
}

class AndroidAppUpdatePlatform implements AppUpdatePlatform {
  const AndroidAppUpdatePlatform({
    MethodChannel channel = const MethodChannel('app.anime.anime/app-update'),
  }) : _channel = channel;
  final MethodChannel _channel;

  @override
  Future<InstalledUpdateEnvironment> environment() async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'getEnvironment',
    );
    if (result == null) {
      throw const UpdateFailure('environment', '读取应用版本失败，请重试');
    }
    return InstalledUpdateEnvironment.fromMap(result);
  }

  @override
  Future<UpdateDownloadDirectory> downloadDirectory() async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'getDownloadDirectory',
    );
    if (result?['path'] is! String || result?['availableBytes'] is! int) {
      throw const UpdateFailure('storage', '读取更新存储空间失败，请重试');
    }
    return UpdateDownloadDirectory(
      result!['path'] as String,
      result['availableBytes'] as int,
    );
  }

  Map<String, Object?> _arguments(String path, UpdateRelease release) => {
    'path': path,
    'sha256': release.sha256,
    'bytes': release.bytes,
    'versionName': release.version,
    'versionCode': release.buildNumber,
  };

  @override
  Future<void> verify(String path, UpdateRelease release) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'verifyPackage',
      _arguments(path, release),
    );
    if (result?['verified'] != true) {
      throw const UpdateFailure('verification', '安装包验证未通过，请重新下载');
    }
  }

  @override
  Future<bool> openInstallPermission() async =>
      await _channel.invokeMethod<bool>('openInstallPermission') ?? false;

  @override
  Future<bool> install(String path, UpdateRelease release) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'installPackage',
      _arguments(path, release),
    );
    if (result?['status'] == 'permissionRequired') return false;
    if (result?['status'] == 'launched') return true;
    throw const UpdateFailure('installation', '打开系统安装界面失败，请重试');
  }
}

bool updateErrorInvalidatesPackage(Object error) =>
    error is PlatformException &&
    const {
      'update_invalid_path',
      'update_hash_mismatch',
      'update_size_mismatch',
      'update_package_mismatch',
      'update_version_mismatch',
      'update_not_newer',
      'update_signature_mismatch',
      'update_incompatible',
    }.contains(error.code);

String updateErrorMessage(Object error) {
  if (error is UpdateFailure) return error.message;
  if (error is MissingPluginException) return '当前安装包尚未包含更新组件，请先手动安装新版';
  if (error is PlatformException) {
    return switch (error.code) {
      'update_signature_mismatch' => '安装包签名与当前应用不同，请使用相同签名的正式更新包',
      'update_package_mismatch' => '安装包与当前应用不匹配，请检查更新来源',
      'update_not_newer' => '当前版本已更新，无需重复安装',
      'update_version_mismatch' => '安装包版本与更新清单不一致，请重新检查更新',
      'update_hash_mismatch' || 'update_size_mismatch' => '安装包校验失败，请重新下载',
      'update_invalid_path' => '安装包已失效，请重新下载',
      'update_incompatible' => '此安装包不适用于当前 Android 版本或设备',
      'update_busy' => '正在验证安装包，请稍后重试',
      'update_closed' => '安装页面已关闭，请重新打开更新页面',
      _ => '系统更新操作未完成，请稍后重试',
    };
  }
  return '更新操作失败，请检查网络或存储空间后重试';
}
