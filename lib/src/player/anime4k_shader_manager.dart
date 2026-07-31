import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

enum Anime4KProfile {
  automatic('auto', '自动', '根据片源分辨率与显示尺寸自动选择'),
  clear('clear', '动画清晰', '强化模糊线条并减少压缩痕迹'),
  soft('soft', '自然柔和', '适合常见 720p 与轻度锯齿片源'),
  lowResolution('low_resolution', '低清修复', '为 480p、低码率片源降噪后放大'),
  strong('strong', '强力增强', '放大达到 2 倍时启用二次修复，低倍率自动避免过锐'),
  advanced('advanced', '高级', '手动组合 Anime4K 着色器');

  const Anime4KProfile(this.settingValue, this.label, this.description);

  final String settingValue;
  final String label;
  final String description;

  static Anime4KProfile fromSetting(String? value) {
    // Preserve settings written by the original performance/balanced/quality
    // UI while moving users to content-aware presets.
    return switch (value) {
      'performance' => Anime4KProfile.lowResolution,
      'balanced' => Anime4KProfile.automatic,
      'quality' => Anime4KProfile.clear,
      _ => values.firstWhere(
        (profile) => profile.settingValue == value,
        orElse: () => Anime4KProfile.automatic,
      ),
    };
  }

  bool get restoresWithoutScaling =>
      this == Anime4KProfile.clear ||
      this == Anime4KProfile.soft ||
      this == Anime4KProfile.strong;
}

enum Anime4KTier {
  performance('performance', '节能'),
  balanced('balanced', '标准'),
  quality('quality', '高质量');

  const Anime4KTier(this.settingValue, this.label);

  final String settingValue;
  final String label;

  List<Anime4KTier> get fallbackOrder => switch (this) {
    Anime4KTier.quality => const [
      Anime4KTier.quality,
      Anime4KTier.balanced,
      Anime4KTier.performance,
    ],
    Anime4KTier.balanced => const [
      Anime4KTier.balanced,
      Anime4KTier.performance,
    ],
    Anime4KTier.performance => const [Anime4KTier.performance],
  };
}

class Anime4KSelection {
  const Anime4KSelection({
    required this.requestedProfile,
    required this.resolvedProfile,
    required this.tier,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.displayWidth,
    required this.displayHeight,
    this.sourceFramesPerSecond = 0,
  });

  final Anime4KProfile requestedProfile;
  final Anime4KProfile resolvedProfile;
  final Anime4KTier tier;
  final int sourceWidth;
  final int sourceHeight;
  final int displayWidth;
  final int displayHeight;
  final double sourceFramesPerSecond;

  bool get hasKnownDimensions =>
      sourceWidth > 0 &&
      sourceHeight > 0 &&
      displayWidth > 0 &&
      displayHeight > 0;

  double get scaleFactor {
    if (sourceWidth <= 0 ||
        sourceHeight <= 0 ||
        displayWidth <= 0 ||
        displayHeight <= 0) {
      return 1;
    }
    final widthScale = displayWidth / sourceWidth;
    final heightScale = displayHeight / sourceHeight;
    return widthScale < heightScale ? widthScale : heightScale;
  }

  bool get expectsUpscale => scaleFactor > 1.2;

  /// Anime4K's secondary A+A/B+B pass is intended for actual 2x (or higher)
  /// enlargement. Below that threshold the single-pass pipeline is both safer
  /// and substantially cheaper, while preserving the requested strong preset.
  bool get usesSecondaryPass =>
      resolvedProfile == Anime4KProfile.strong && scaleFactor >= 2.0;

  Anime4KProfile get pipelineProfile =>
      resolvedProfile == Anime4KProfile.strong && !usesSecondaryPass
      ? Anime4KProfile.clear
      : resolvedProfile;

  String get activeModeLabel =>
      resolvedProfile == Anime4KProfile.strong && !usesSecondaryPass
      ? '强力增强（当前倍率采用单次增强）'
      : resolvedProfile.label;

  String? get frameRateLabel {
    if (sourceFramesPerSecond <= 0) return null;
    final rounded = sourceFramesPerSecond.roundToDouble();
    final value = (sourceFramesPerSecond - rounded).abs() < 0.05
        ? rounded.toInt().toString()
        : sourceFramesPerSecond.toStringAsFixed(2);
    return '${value}fps';
  }

  String resolutionDescription({bool previewingOriginal = false}) {
    if (!hasKnownDimensions) return '正在识别片源尺寸';
    final source = '片源 $sourceWidth×$sourceHeight';
    final display = '$displayWidth×$displayHeight';
    if (previewingOriginal) {
      return '$source · 显示区域 $display · 原画';
    }
    if (expectsUpscale) return '$source → 超分至 $display';
    if (resolvedProfile.restoresWithoutScaling) {
      return '$source · 显示区域 $display · 仅画质修复';
    }
    return '$source · 显示区域 $display · 当前尺寸无需放大';
  }

  Anime4KSelection withTier(Anime4KTier value) {
    return Anime4KSelection(
      requestedProfile: requestedProfile,
      resolvedProfile: resolvedProfile,
      tier: value,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      displayWidth: displayWidth,
      displayHeight: displayHeight,
      sourceFramesPerSecond: sourceFramesPerSecond,
    );
  }
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
    required this.tier,
    required this.assetPaths,
    this.installedPaths = const [],
  });

  final Anime4KProfile profile;
  final Anime4KTier tier;
  final List<String> assetPaths;
  final List<String> installedPaths;

  Anime4KShaderPipeline withInstalledPaths(List<String> paths) {
    return Anime4KShaderPipeline(
      profile: profile,
      tier: tier,
      assetPaths: assetPaths,
      installedPaths: List.unmodifiable(paths),
    );
  }
}

class Anime4KApplyResult {
  const Anime4KApplyResult({
    required this.requestedProfile,
    required this.requestedTier,
    this.activeProfile,
    this.activeTier,
    this.failures = const [],
  });

  final Anime4KProfile requestedProfile;
  final Anime4KTier requestedTier;
  final Anime4KProfile? activeProfile;
  final Anime4KTier? activeTier;
  final List<Object> failures;

  bool get enabled => activeProfile != null;
  bool get usedFallback => enabled && activeTier != requestedTier;
}

typedef Anime4KPropertyGetter = Future<String> Function(String property);
typedef Anime4KPropertySetter =
    Future<void> Function(String property, String value);
typedef Anime4KPipelineInstaller =
    Future<Anime4KShaderPipeline> Function(
      Anime4KProfile profile,
      Anime4KTier tier,
      List<String> customShaderNames,
    );

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
  Anime4KTier? _activeTier;
  String? _activeShaderList;
  bool _previewingOriginal = false;

  Anime4KProfile? get activeProfile => _activeProfile;
  Anime4KTier? get activeTier => _activeTier;
  bool get previewingOriginal => _previewingOriginal;

  Future<Anime4KApplyResult> enable(
    Anime4KProfile requestedProfile, {
    required Anime4KTier requestedTier,
    Anime4KTier? skipTier,
    List<String> customShaderNames = const [],
  }) async {
    final failures = <Object>[];
    await _captureOriginalShaderList();

    final tiers = requestedProfile == Anime4KProfile.advanced
        ? <Anime4KTier>[requestedTier]
        : requestedTier.fallbackOrder;
    var canTryTier = skipTier == null;
    for (final tier in tiers) {
      if (!canTryTier) {
        if (tier == skipTier) canTryTier = true;
        continue;
      }
      try {
        final pipeline = await installPipeline(
          requestedProfile,
          tier,
          customShaderNames,
        );
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
        _activeProfile = requestedProfile;
        _activeTier = tier;
        _activeShaderList = value;
        _previewingOriginal = false;
        return Anime4KApplyResult(
          requestedProfile: requestedProfile,
          requestedTier: requestedTier,
          activeProfile: requestedProfile,
          activeTier: tier,
          failures: List.unmodifiable(failures),
        );
      } catch (error) {
        failures.add(error);
      }
    }

    await disable();
    return Anime4KApplyResult(
      requestedProfile: requestedProfile,
      requestedTier: requestedTier,
      failures: List.unmodifiable(failures),
    );
  }

  Future<void> setPreviewOriginal(bool enabled) async {
    final original = _originalShaderList;
    final active = _activeShaderList;
    if (original == null || active == null || _activeProfile == null) return;
    await setProperty('glsl-shaders', enabled ? original : active);
    _previewingOriginal = enabled;
  }

  Future<int?> readCounter(String property) async {
    final value = (await getProperty(property)).trim();
    if (value.isEmpty || value == 'N/A') return null;
    return int.tryParse(value);
  }

  Future<void> disable() async {
    final original = _originalShaderList;
    if (original != null) {
      await setProperty('glsl-shaders', original);
    }
    _activeProfile = null;
    _activeTier = null;
    _activeShaderList = null;
    _previewingOriginal = false;
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
  final Map<String, Future<Anime4KShaderPipeline>> _installedPipelines = {};

  static const availableShaderFileNames = <String>[
    'Anime4K_Clamp_Highlights.glsl',
    'Anime4K_AutoDownscalePre_x2.glsl',
    'Anime4K_AutoDownscalePre_x4.glsl',
    'Anime4K_Denoise_Bilateral_Mean.glsl',
    'Anime4K_Denoise_Bilateral_Median.glsl',
    'Anime4K_Denoise_Bilateral_Mode.glsl',
    'Anime4K_Restore_CNN_S.glsl',
    'Anime4K_Restore_CNN_M.glsl',
    'Anime4K_Restore_CNN_L.glsl',
    'Anime4K_Restore_CNN_UL.glsl',
    'Anime4K_Restore_CNN_VL.glsl',
    'Anime4K_Restore_CNN_Soft_S.glsl',
    'Anime4K_Restore_CNN_Soft_M.glsl',
    'Anime4K_Restore_CNN_Soft_L.glsl',
    'Anime4K_Restore_CNN_Soft_UL.glsl',
    'Anime4K_Restore_CNN_Soft_VL.glsl',
    'Anime4K_Restore_GAN_UL.glsl',
    'Anime4K_Restore_GAN_UUL.glsl',
    'Anime4K_Deblur_DoG.glsl',
    'Anime4K_Deblur_Original.glsl',
    'Anime4K_Darken_VeryFast.glsl',
    'Anime4K_Darken_Fast.glsl',
    'Anime4K_Darken_HQ.glsl',
    'Anime4K_Thin_VeryFast.glsl',
    'Anime4K_Thin_Fast.glsl',
    'Anime4K_Thin_HQ.glsl',
    'Anime4K_3DGraphics_AA_Upscale_x2_US.glsl',
    'Anime4K_3DGraphics_Upscale_x2_US.glsl',
    'Anime4K_Upscale_Original_x2.glsl',
    'Anime4K_Upscale_DoG_x2.glsl',
    'Anime4K_Upscale_DTD_x2.glsl',
    'Anime4K_Upscale_Deblur_DoG_x2.glsl',
    'Anime4K_Upscale_Deblur_Original_x2.glsl',
    'Anime4K_Upscale_CNN_x2_S.glsl',
    'Anime4K_Upscale_CNN_x2_M.glsl',
    'Anime4K_Upscale_CNN_x2_L.glsl',
    'Anime4K_Upscale_CNN_x2_UL.glsl',
    'Anime4K_Upscale_CNN_x2_VL.glsl',
    'Anime4K_Upscale_Denoise_CNN_x2_S.glsl',
    'Anime4K_Upscale_Denoise_CNN_x2_M.glsl',
    'Anime4K_Upscale_Denoise_CNN_x2_L.glsl',
    'Anime4K_Upscale_Denoise_CNN_x2_UL.glsl',
    'Anime4K_Upscale_Denoise_CNN_x2_VL.glsl',
    'Anime4K_Upscale_GAN_x2_S.glsl',
    'Anime4K_Upscale_GAN_x2_M.glsl',
    'Anime4K_Upscale_GAN_x3_L.glsl',
    'Anime4K_Upscale_GAN_x3_VL.glsl',
    'Anime4K_Upscale_GAN_x4_UL.glsl',
    'Anime4K_Upscale_GAN_x4_UUL.glsl',
  ];

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

  static Anime4KSelection select({
    required Anime4KProfile requestedProfile,
    required TargetPlatform platform,
    required int sourceWidth,
    required int sourceHeight,
    required int displayWidth,
    required int displayHeight,
    double sourceFramesPerSecond = 0,
  }) {
    final widthScale = sourceWidth > 0 ? displayWidth / sourceWidth : 1.0;
    final heightScale = sourceHeight > 0 ? displayHeight / sourceHeight : 1.0;
    final scale = widthScale < heightScale ? widthScale : heightScale;
    final resolvedProfile = requestedProfile == Anime4KProfile.automatic
        ? _automaticProfileFor(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            scale: scale,
          )
        : requestedProfile;
    return Anime4KSelection(
      requestedProfile: requestedProfile,
      resolvedProfile: resolvedProfile,
      tier: _recommendedTier(
        profile: resolvedProfile,
        platform: platform,
        sourceHeight: sourceHeight,
        outputPixels: displayWidth * displayHeight,
        scale: scale,
        sourceFramesPerSecond: sourceFramesPerSecond,
      ),
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      displayWidth: displayWidth,
      displayHeight: displayHeight,
      sourceFramesPerSecond: sourceFramesPerSecond,
    );
  }

  static Anime4KProfile _automaticProfileFor({
    required int sourceWidth,
    required int sourceHeight,
    required double scale,
  }) {
    if (sourceHeight > 0 && sourceHeight <= 576) {
      return Anime4KProfile.lowResolution;
    }
    final aspectRatio = sourceHeight > 0 ? sourceWidth / sourceHeight : 0.0;
    if (sourceHeight <= 768 &&
        scale >= 1.35 &&
        aspectRatio > 0 &&
        aspectRatio <= 1.5) {
      // Older 4:3 animation commonly carries blur and resampling damage.
      // Anime4K Mode A (clear) reconstructs those lines more visibly than
      // the soft Mode B intended for ordinary downscaled 720p sources.
      return Anime4KProfile.clear;
    }
    if (sourceHeight > 0 && sourceHeight <= 900) {
      return Anime4KProfile.soft;
    }
    return Anime4KProfile.clear;
  }

  static Anime4KTier _recommendedTier({
    required Anime4KProfile profile,
    required TargetPlatform platform,
    required int sourceHeight,
    required int outputPixels,
    required double scale,
    required double sourceFramesPerSecond,
  }) {
    if (profile == Anime4KProfile.advanced) return Anime4KTier.balanced;
    final highFrameRate = sourceFramesPerSecond >= 50;
    final mobile =
        platform == TargetPlatform.android || platform == TargetPlatform.iOS;
    if (mobile) {
      if (highFrameRate) return Anime4KTier.performance;
      if (profile == Anime4KProfile.strong && sourceHeight <= 720) {
        return Anime4KTier.balanced;
      }
      return Anime4KTier.performance;
    }
    if (highFrameRate) {
      const maxBalancedPixels = 2560 * 1440;
      if (profile == Anime4KProfile.strong ||
          outputPixels > maxBalancedPixels) {
        return Anime4KTier.performance;
      }
      return Anime4KTier.balanced;
    }
    if (profile == Anime4KProfile.strong) return Anime4KTier.quality;
    const maxQualityPixels = 2560 * 1440;
    if (sourceHeight > 0 &&
        sourceHeight <= 1080 &&
        scale > 1.2 &&
        outputPixels > 0 &&
        outputPixels <= maxQualityPixels) {
      return Anime4KTier.quality;
    }
    return Anime4KTier.balanced;
  }

  static double? parseFrameRate(Object? value) {
    final parsed = value is num
        ? value.toDouble()
        : double.tryParse(value?.toString().trim() ?? '');
    if (parsed == null || !parsed.isFinite || parsed < 1 || parsed > 240) {
      return null;
    }
    return parsed;
  }

  static Anime4KShaderPipeline pipelineFor(
    Anime4KProfile profile, {
    Anime4KTier tier = Anime4KTier.balanced,
    List<String> customShaderNames = const [],
  }) {
    final names = profile == Anime4KProfile.advanced
        ? availableShaderFileNames
              .where(customShaderNames.toSet().contains)
              .toList(growable: false)
        : _pipelineFileNames(profile, tier);
    return Anime4KShaderPipeline(
      profile: profile,
      tier: tier,
      assetPaths: List.unmodifiable(names.map((name) => '$_assetRoot$name')),
    );
  }

  static List<String> _pipelineFileNames(
    Anime4KProfile profile,
    Anime4KTier tier,
  ) {
    if (profile == Anime4KProfile.automatic ||
        profile == Anime4KProfile.advanced) {
      throw ArgumentError(
        'Profile must be resolved before building a pipeline.',
      );
    }
    final primary = switch (tier) {
      Anime4KTier.performance => 'S',
      Anime4KTier.balanced => 'M',
      Anime4KTier.quality => 'L',
    };
    final secondary = switch (tier) {
      Anime4KTier.performance => null,
      Anime4KTier.balanced => 'S',
      Anime4KTier.quality => 'M',
    };
    final clamp = 'Anime4K_Clamp_Highlights.glsl';
    final downscale = <String>[
      'Anime4K_AutoDownscalePre_x2.glsl',
      'Anime4K_AutoDownscalePre_x4.glsl',
    ];
    final fallbackUpscale = secondary == null
        ? 'Anime4K_Upscale_Original_x2.glsl'
        : 'Anime4K_Upscale_CNN_x2_$secondary.glsl';

    if (profile == Anime4KProfile.lowResolution) {
      return [
        clamp,
        'Anime4K_Upscale_Denoise_CNN_x2_$primary.glsl',
        ...downscale,
        fallbackUpscale,
      ];
    }

    final soft = profile == Anime4KProfile.soft;
    final restorePrefix = soft
        ? 'Anime4K_Restore_CNN_Soft_'
        : 'Anime4K_Restore_CNN_';
    final base = <String>[
      clamp,
      '$restorePrefix$primary.glsl',
      'Anime4K_Upscale_CNN_x2_$primary.glsl',
      ...downscale,
    ];
    if (profile == Anime4KProfile.strong && secondary != null) {
      return [
        ...base,
        'Anime4K_Restore_CNN_$secondary.glsl',
        'Anime4K_Upscale_CNN_x2_$secondary.glsl',
      ];
    }
    return [...base, fallbackUpscale];
  }

  static String shaderCategory(String fileName) {
    if (fileName.contains('Clamp') || fileName.contains('Downscale')) {
      return '预处理';
    }
    if (fileName.contains('Restore') || fileName.contains('Denoise')) {
      return '修复与降噪';
    }
    if (fileName.contains('Darken') ||
        fileName.contains('Thin') ||
        (fileName.contains('Deblur') && !fileName.contains('Upscale'))) {
      return '线条增强';
    }
    return '放大';
  }

  static String shaderLabel(String fileName) {
    return fileName
        .replaceFirst('Anime4K_', '')
        .replaceFirst(RegExp(r'\.glsl$'), '')
        .replaceAll('_', ' ');
  }

  static String buildMpvShaderList(
    List<String> paths, {
    required TargetPlatform platform,
  }) {
    final separator = platform == TargetPlatform.windows ? ';' : ':';
    return paths.join(separator);
  }

  Future<Anime4KShaderPipeline> ensureInstalled(
    Anime4KProfile profile, {
    Anime4KTier tier = Anime4KTier.balanced,
    List<String> customShaderNames = const [],
  }) async {
    final key =
        '${profile.settingValue}:${tier.settingValue}:${customShaderNames.join('|')}';
    final cached = _installedPipelines[key];
    if (cached != null) return cached;
    final install = _install(profile, tier, customShaderNames);
    _installedPipelines[key] = install;
    try {
      return await install;
    } catch (_) {
      if (identical(_installedPipelines[key], install)) {
        _installedPipelines.remove(key);
      }
      rethrow;
    }
  }

  Future<Anime4KShaderPipeline> _install(
    Anime4KProfile profile,
    Anime4KTier tier,
    List<String> customShaderNames,
  ) async {
    final pipeline = pipelineFor(
      profile,
      tier: tier,
      customShaderNames: customShaderNames,
    );
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
