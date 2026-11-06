import 'package:http/http.dart' as http;

import 'app_update_download_stub.dart'
    if (dart.library.io) 'app_update_download_io.dart'
    as platform;
import 'app_update_models.dart';

abstract interface class AppUpdateDownloader {
  Future<String> download(
    UpdateRelease release, {
    required String directory,
    required UpdateCancellation cancellation,
    required void Function(UpdateProgress) onProgress,
  });

  Future<void> discard(String path, {String? directory});
}

AppUpdateDownloader createAppUpdateDownloader({
  http.Client Function()? clientFactory,
}) => platform.createAppUpdateDownloader(clientFactory: clientFactory);
