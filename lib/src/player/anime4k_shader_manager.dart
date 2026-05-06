import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class Anime4KShaderManager {
  const Anime4KShaderManager();

  static const _assetPaths = <String>[
    'assets/shaders/anime4k/Anime4K_Upscale_Denoise_CNN_x2_VL.glsl',
  ];

  Future<List<String>> ensureInstalled() async {
    final supportDirectory = await getApplicationSupportDirectory();
    final shaderDirectory = Directory(
      '${supportDirectory.path}${Platform.pathSeparator}anime4k_shaders',
    );
    if (!await shaderDirectory.exists()) {
      await shaderDirectory.create(recursive: true);
    }

    final installedPaths = <String>[];
    for (final assetPath in _assetPaths) {
      final fileName = assetPath.split('/').last;
      final target = File(
        '${shaderDirectory.path}${Platform.pathSeparator}$fileName',
      );
      final source = await rootBundle.loadString(assetPath);
      if (!await target.exists() || await target.readAsString() != source) {
        await target.writeAsString(source);
      }
      installedPaths.add(target.path);
    }
    return installedPaths;
  }
}
