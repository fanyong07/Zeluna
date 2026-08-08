import 'dart:io';

import 'package:flutter/services.dart';

typedef DownloadAvailableBytesProvider =
    Future<int?> Function(Directory directory);

const int downloadStorageHeadroomBytes = 64 * 1024 * 1024;
const MethodChannel _storageChannel = MethodChannel('app.anime.anime/storage');

final class InsufficientDownloadSpace implements Exception {
  const InsufficientDownloadSpace({
    required this.availableBytes,
    required this.requiredBytes,
  });

  final int availableBytes;
  final int requiredBytes;

  @override
  String toString() => 'InsufficientDownloadSpace';
}

Future<int?> platformAvailableDownloadBytes(Directory directory) async {
  if (!Platform.isAndroid && !Platform.isWindows) return null;
  try {
    final value = await _storageChannel.invokeMethod<num>(
      'getAvailableBytes',
      <String, Object?>{'path': directory.path},
    );
    final bytes = value?.toInt();
    return bytes == null || bytes < 0 ? null : bytes;
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  } catch (_) {
    return null;
  }
}

Future<void> ensureDownloadCapacity({
  required Directory directory,
  required int requiredBytes,
  required DownloadAvailableBytesProvider availableBytesProvider,
}) async {
  if (requiredBytes <= 0) return;
  final availableBytes = await availableBytesProvider(directory);
  if (availableBytes == null) return;
  final requiredWithHeadroom = requiredBytes + downloadStorageHeadroomBytes;
  if (availableBytes < requiredWithHeadroom) {
    throw InsufficientDownloadSpace(
      availableBytes: availableBytes,
      requiredBytes: requiredWithHeadroom,
    );
  }
}

Future<void> recoverInterruptedFileCommit(File target) async {
  final backup = File(_backupPath(target.path));
  if (!await backup.exists()) return;
  if (await target.exists()) {
    await _deleteFileBestEffort(backup);
    return;
  }
  await backup.rename(target.path);
}

Future<void> atomicReplaceFile(File temporary, File target) async {
  await target.parent.create(recursive: true);
  await recoverInterruptedFileCommit(target);
  final backup = File(_backupPath(target.path));
  var movedExisting = false;
  if (await target.exists()) {
    await target.rename(backup.path);
    movedExisting = true;
  }
  try {
    await temporary.rename(target.path);
  } catch (_) {
    if (movedExisting && await backup.exists() && !await target.exists()) {
      await backup.rename(target.path);
    }
    rethrow;
  }
  await _deleteFileBestEffort(backup);
}

Future<void> recoverInterruptedDirectoryCommit(Directory target) async {
  final backup = Directory(_backupPath(target.path));
  if (!await backup.exists()) return;
  if (await target.exists()) {
    await _deleteDirectoryBestEffort(backup);
    return;
  }
  await backup.rename(target.path);
}

Future<void> atomicReplaceDirectory(
  Directory temporary,
  Directory target,
) async {
  await target.parent.create(recursive: true);
  await recoverInterruptedDirectoryCommit(target);
  final backup = Directory(_backupPath(target.path));
  var movedExisting = false;
  if (await target.exists()) {
    await target.rename(backup.path);
    movedExisting = true;
  }
  try {
    await temporary.rename(target.path);
  } catch (_) {
    if (movedExisting && await backup.exists() && !await target.exists()) {
      await backup.rename(target.path);
    }
    rethrow;
  }
  await _deleteDirectoryBestEffort(backup);
}

String _backupPath(String targetPath) => '$targetPath.zeluna-replace';

Future<void> _deleteFileBestEffort(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } on FileSystemException {
    // The new target is already committed. A later recovery/cleanup pass can
    // remove the stale backup without invalidating the completed download.
  }
}

Future<void> _deleteDirectoryBestEffort(Directory directory) async {
  try {
    if (await directory.exists()) await directory.delete(recursive: true);
  } on FileSystemException {
    // See _deleteFileBestEffort.
  }
}
