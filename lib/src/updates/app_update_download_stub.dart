import 'package:http/http.dart' as http;

import 'app_update_download.dart';
import 'app_update_models.dart';

AppUpdateDownloader createAppUpdateDownloader({
  http.Client Function()? clientFactory,
}) => const _UnsupportedAppUpdateDownloader();

class _UnsupportedAppUpdateDownloader implements AppUpdateDownloader {
  const _UnsupportedAppUpdateDownloader();

  @override
  Future<String> download(
    UpdateRelease release, {
    required String directory,
    required UpdateCancellation cancellation,
    required void Function(UpdateProgress) onProgress,
  }) async {
    cancellation.throwIfCancelled();
    throw const UpdateFailure('unsupported_platform', '当前平台暂不支持应用内更新');
  }

  @override
  Future<void> discard(String path, {String? directory}) async {}
}
