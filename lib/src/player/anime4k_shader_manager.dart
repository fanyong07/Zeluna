import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

enum Anime4KProfile {
  performance('performance', '性能'),
  balanced('balanced', '均衡'),
  quality('quality', '高质量');

  const Anime4KProfile(this.settingValue, this.label);

  final String settingValue;
  final String label;

  static Anime4KProfile fromSetting(String? value) {
    return values.firstWhere(
      (profile) => profile.settingValue == value,
      orElse: () => Anime4KProfile.balanced,
    );
  }

  List<Anime4KProfile> get fallbackOrder => switch (this) {
    Anime4KProfile.quality => const [
      Anime4KProfile.quality,
      Anime4KProfile.balanced,
      Anime4KProfile.performance,
    ],
    Anime4KProfile.balanced => const [
      Anime4KProfile.balanced,
      Anime4KProfile.performance,
    ],
    Anime4KProfile.performance => const [Anime4KProfile.performance],
  };
}

class Anime4KPlatformSupport {
  const Anime4KPlatformSupport._({required this.supported, this.reason});

  const Anime4KPlatformSupport.supported() : this._(supported: true);

  const Anime4KPlatformSupport.unsupported(String reason)
    : this._(supported: false, reason: reason);

  final bool supported;
  final String? reason;
}

class Anime4KShaderPipeline {
  const Anime4KShaderPipeline({
    required this.profile,
    required this.assetPaths,
    this.installedPaths = const [],
  });

  final Anime4KProfile profile;
  final List<String> assetPaths;
  final List<String> installedPaths;

  Anime4KShaderPipeline withInstalledPaths(List<String> paths) {
    return Anime4KShaderPipeline(
      profile: profile,
      assetPaths: assetPaths,
      installedPaths: List.unmodifiable(paths),
    );
  }
}

class Anime4KApplyResult {
  const Anime4KApplyResult({
    required this.requestedProfile,
    this.activeProfile,
    this.failures = const [],
  });

  final Anime4KProfile requestedProfile;
  final Anime4KProfile? activeProfile;
  final List<Object> failures;

  bool get enabled => activeProfile != null;
  bool get usedFallback => enabled && activeProfile != requestedProfile;
}

typedef Anime4KPropertyGetter = Future<String> Function(String property);
typedef Anime4KPropertySetter =
    Future<void> Function(String property, String value);
typedef Anime4KPipelineInstaller =
    Future<Anime4KShaderPipeline> Function(Anime4KProfile profile);

/// Owns the mpv property changes made by Anime4K and restores the previous
/// shader list when the feature is disabled or every profile fails.
class Anime4KMpvRuntime {
  Anime4KMpvRuntime({
    required this.platform,
    required this.installPipeline,
    required this.getProperty,
    required this.setProperty,
  });

  final TargetPlatform platform;
  final Anime4KPipelineInstaller installPipeline;
  final Anime4KPropertyGetter getProperty;
  final Anime4KPropertySetter setProperty;

  String? _originalShaderList;
  Anime4KProfile? _activeProfile;

  Anime4KProfile? get activeProfile => _activeProfile;

  Future<Anime4KApplyResult> enable(
    Anime4KProfile requestedProfile, {
    Anime4KProfile? skipProfile,
  }) async {
    final failures = <Object>[];
    await _captureOriginalShaderList();

    var canTryProfile = skipProfile == null;
    for (final profile in requestedProfile.fallbackOrder) {
      if (!canTryProfile) {
        if (profile == skipProfile) canTryProfile = true;
        continue;
      }
      try {
        final pipeline = await installPipeline(profile);
        final value = Anime4KShaderManager.buildMpvShaderList(
          pipeline.installedPaths,
          platform: platform,
        );
        if (value.isEmpty) {
          throw StateError('Anime4K shader pipeline is empty.');
        }
        await setProperty('glsl-shaders', value);
        final applied = await getProperty('glsl-shaders');
        if (!_containsEveryShader(applied, pipeline.installedPaths)) {
          throw StateError('mpv did not accept the Anime4K shader pipeline.');
        }
        _activeProfile = profile;
        return Anime4KApplyResult(
          requestedProfile: requestedProfile,
          activeProfile: profile,
          failures: List.unmodifiable(failures),
        );
      } catch (error) {
        failures.add(error);
      }
    }

    await disable();
    return Anime4KApplyResult(
      requestedProfile: requestedProfile,
      failures: List.unmodifiable(failures),
    );
  }

  Future<void> disable() async {
    final original = _originalShaderList;
    if (original != null) {
      await setProperty('glsl-shaders', original);
    }
    _activeProfile = null;
  }

  Future<void> _captureOriginalShaderList() async {
    if (_originalShaderList != null) return;
    final scale = await getProperty('scale');
    if (scale.trim().isEmpty) {
      throw UnsupportedError('mpv video output is not ready for GLSL shaders.');
    }
    _originalShaderList = await getProperty('glsl-shaders');
  }

  bool _containsEveryShader(String value, List<String> shaderPaths) {
    if (value.trim().isEmpty) return false;
    return shaderPaths.every((path) {
      final fileName = path.replaceAll('\\', '/').split('/').last;
      return value.contains(fileName);
    });
  }
}

class Anime4KShaderManager {
  Anime4KShaderManager();

  static const _assetRoot = 'assets/shaders/anime4k/';
  static const _shaderVersionDirectory = 'v4_0';
  final Map<Anime4KProfile, Future<Anime4KShaderPipeline>> _installedPipelines =
      {};

  static const _pipelines = <Anime4KProfile, List<String>>{
    // Lightweight Mode C. This is deliberately below the official low-end
    // preset so that mobile GPUs have a usable fallback.
    Anime4KProfile.performance: [
      '${_assetRoot}Anime4K_Clamp_Highlights.glsl',
      '${_assetRoot}Anime4K_Upscale_Denoise_CNN_x2_S.glsl',
      '${_assetRoot}Anime4K_AutoDownscalePre_x2.glsl',
      '${_assetRoot}Anime4K_AutoDownscalePre_x4.glsl',
      '${_assetRoot}Anime4K_Upscale_CNN_x2_S.glsl',
    ],
    // Official Anime4K v4 low-end Mode A preset.
    Anime4KProfile.balanced: [
      '${_assetRoot}Anime4K_Clamp_Highlights.glsl',
      '${_assetRoot}Anime4K_Restore_CNN_M.glsl',
      '${_assetRoot}Anime4K_Upscale_CNN_x2_M.glsl',
      '${_assetRoot}Anime4K_AutoDownscalePre_x2.glsl',
      '${_assetRoot}Anime4K_AutoDownscalePre_x4.glsl',
      '${_assetRoot}Anime4K_Upscale_CNN_x2_S.glsl',
    ],
    // Official Anime4K v4 high-end Mode A preset.
    Anime4KProfile.quality: [
      '${_assetRoot}Anime4K_Clamp_Highlights.glsl',
      '${_assetRoot}Anime4K_Restore_CNN_VL.glsl',
      '${_assetRoot}Anime4K_Upscale_CNN_x2_VL.glsl',
      '${_assetRoot}Anime4K_AutoDownscalePre_x2.glsl',
      '${_assetRoot}Anime4K_AutoDownscalePre_x4.glsl',
      '${_assetRoot}Anime4K_Upscale_CNN_x2_M.glsl',
    ],
  };

  static Anime4KPlatformSupport get currentPlatformSupport =>
      platformSupport(isWeb: kIsWeb, platform: defaultTargetPlatform);

  static Anime4KPlatformSupport platformSupport({
    required bool isWeb,
    required TargetPlatform platform,
  }) {
    if (isWeb) {
      return const Anime4KPlatformSupport.unsupported('网页版不支持实时超分，已使用普通画质。');
    }
    if (platform == TargetPlatform.android ||
        platform == TargetPlatform.iOS ||
        platform == TargetPlatform.windows ||
        platform == TargetPlatform.linux ||
        platform == TargetPlatform.macOS) {
      return const Anime4KPlatformSupport.supported();
    }
    return const Anime4KPlatformSupport.unsupported('当前平台不支持实时超分，已使用普通画质。');
  }

  static Anime4KShaderPipeline pipelineFor(Anime4KProfile profile) {
    return Anime4KShaderPipeline(
      profile: profile,
      assetPaths: List.unmodifiable(_pipelines[profile]!),
    );
  }

  static String buildMpvShaderList(
    List<String> paths, {
    required TargetPlatform platform,
  }) {
    final separator = platform == TargetPlatform.windows ? ';' : ':';
    return paths.join(separator);
  }

  Future<Anime4KShaderPipeline> ensureInstalled(Anime4KProfile profile) async {
    final cached = _installedPipelines[profile];
    if (cached != null) return cached;
    final install = _install(profile);
    _installedPipelines[profile] = install;
    try {
      return await install;
    } catch (_) {
      if (identical(_installedPipelines[profile], install)) {
        _installedPipelines.remove(profile);
      }
      rethrow;
    }
  }

  Future<Anime4KShaderPipeline> _install(Anime4KProfile profile) async {
    final pipeline = pipelineFor(profile);
    final supportDirectory = await getApplicationSupportDirectory();
    final shaderDirectory = Directory(
      '${supportDirectory.path}${Platform.pathSeparator}'
      'anime4k_shaders${Platform.pathSeparator}$_shaderVersionDirectory',
    );
    if (!await shaderDirectory.exists()) {
      await shaderDirectory.create(recursive: true);
    }

    final installedPaths = <String>[];
    for (final assetPath in pipeline.assetPaths) {
      final fileName = assetPath.split('/').last;
      final target = File(
        '${shaderDirectory.path}${Platform.pathSeparator}$fileName',
      );
      final source = await rootBundle.load(assetPath);
      final bytes = source.buffer.asUint8List(
        source.offsetInBytes,
        source.lengthInBytes,
      );
      final targetExists = await target.exists();
      final needsWrite =
          !targetExists ||
          await target.length() != bytes.length ||
          !listEquals(await target.readAsBytes(), bytes);
      if (needsWrite) {
        await target.writeAsBytes(bytes, flush: true);
      }
      installedPaths.add(target.path);
    }
    return pipeline.withInstalledPaths(installedPaths);
  }
}
