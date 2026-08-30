import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Anime4K quality tier. Selects the CNN size the mode's chain is built at,
/// mirroring upstream's two shipped templates plus one lighter step.
///
/// Measured against AniCh 1.5.23 on Android (see [Anime4KMode] for the chain
/// shapes): `quality` reproduces upstream's High-end template exactly and
/// `balance` reproduces Low-end exactly. `efficiency` has no upstream
/// counterpart -- it drops to S and omits every stage that would use the
/// secondary size, which was confirmed for both Mode A and Mode A+A.
enum Anime4KTier {
  quality('quality', '质量', '最高画质，需要较强 GPU', primary: 'VL', secondary: 'M'),
  balance('balance', '均衡', '画质与性能兼顾', primary: 'M', secondary: 'S'),
  efficiency('efficiency', '性能', '低开销，适合移动设备', primary: 'S'),
  custom('custom', '高级', '手动组合 Anime4K 着色器');

  const Anime4KTier(
    this.settingValue,
    this.label,
    this.description, {
    this.primary,
    this.secondary,
  });

  final String settingValue;
  final String label;
  final String description;

  /// CNN size for the first restore/upscale pass. Null for [custom].
  final String? primary;

  /// CNN size for the second pass. Null when the tier runs a single pass.
  final String? secondary;

  bool get isCustom => this == Anime4KTier.custom;

  static Anime4KTier fromSetting(String? value) {
    return switch (value) {
      // Settings written by the previous profile/tier UI.
      'performance' => Anime4KTier.efficiency,
      'balanced' => Anime4KTier.balance,
      'auto' || 'clear' || 'soft' || 'low_resolution' || 'strong' =>
        Anime4KTier.quality,
      'advanced' => Anime4KTier.custom,
      _ => values.firstWhere(
        (tier) => tier.settingValue == value,
        orElse: () => Anime4KTier.quality,
      ),
    };
  }
}

/// Anime4K mode. Selects the shape of the shader chain.
///
/// The stage order here is upstream's, transcribed from
/// `md/Template/GLSL_Windows_High-end/input.conf` and confirmed by measuring
/// AniCh. Note the deliberate asymmetry: A+A places its second restore pass
/// *before* the AutoDownscalePre pair while B+B and C+A place theirs *after*.
/// That is upstream's own ordering, not a transcription slip.
enum Anime4KMode {
  a(
    'a',
    '模式A',
    bestFor: '大部分 1080p、部分较老的 720p，以及多数老旧标清片源',
    upside: '重建大部分受损线条，去除压缩痕迹与大量模糊，同时降噪',
    downside: '画面原有的振铃或色带会被一并放大，强降噪可能让纹理发糊',
  ),
  b(
    'b',
    '模式B',
    bestFor: '大部分 720p，以及由 1080p 缩小而来的片源',
    upside: '去除压缩痕迹，重建部分线条，减轻振铃与锯齿',
    downside: '部分瑕疵去不掉，线条可能仍然偏软',
  ),
  c(
    'c',
    '模式C',
    bestFor: '由 1080p 缩小到 480p 的片源，以及本身没有损伤的画面、插画、壁纸',
    upside: '只降噪，最大限度保留原画细节',
    downside: '观感提升有限，原有的振铃和缩放痕迹会被放大',
  ),
  aa(
    'aa',
    '模式A+A',
    bestFor: '与模式A 相同，追求最强线条重建时使用',
    upside: '几乎重建所有受损线条，观感最好',
    downside: '可能引入明显振铃、色带与锯齿，比模式A 慢',
  ),
  bb(
    'bb',
    '模式B+B',
    bestFor: '与模式B 相同，追求更好观感时使用',
    upside: '在模式B 的基础上进一步提升观感',
    downside: '与模式B 相同，且更慢',
  ),
  ca(
    'ca',
    '模式C+A',
    bestFor: '与模式C 相同，希望降噪后补一轮线条重建时使用',
    upside: '在模式C 的基础上略微提升观感',
    downside: '与模式C 相同，且更慢',
  );

  const Anime4KMode(
    this.settingValue,
    this.label, {
    required this.bestFor,
    required this.upside,
    required this.downside,
  });

  final String settingValue;
  final String label;

  /// Which sources this mode targets, from upstream's "Optimized for?" column.
  final String bestFor;

  /// Upstream's "Positive effects".
  final String upside;

  /// Upstream's "Negative effects (If used incorrectly)". Worth surfacing:
  /// picking the wrong mode makes the picture worse, not merely slower.
  final String downside;

  /// One-line summary for a collapsed settings row.
  String get description => '适合$bestFor';

  /// Full text for an expanded picker entry.
  String get detailedDescription =>
      '适合：$bestFor\n改善：$upside\n代价：$downside';

  static Anime4KMode fromSetting(String? value) {
    return values.firstWhere(
      (mode) => mode.settingValue == value,
      orElse: () => Anime4KMode.a,
    );
  }

  /// Shader file names for this mode at [tier].
  ///
  /// When the tier has no secondary size every stage that would reference it is
  /// dropped, which collapses the doubled modes onto their single-pass form.
  /// Measured: Mode A and Mode A+A both yield the same five stages at
  /// `efficiency`.
  List<String> fileNames(Anime4KTier tier) {
    final primary = tier.primary;
    if (primary == null) {
      throw ArgumentError('Tier ${tier.settingValue} has no built-in pipeline.');
    }
    final secondary = tier.secondary;

    const clamp = 'Anime4K_Clamp_Highlights.glsl';
    const downscale = [
      'Anime4K_AutoDownscalePre_x2.glsl',
      'Anime4K_AutoDownscalePre_x4.glsl',
    ];
    final tail = secondary == null
        ? const <String>[]
        : ['Anime4K_Upscale_CNN_x2_$secondary.glsl'];

    return switch (this) {
      Anime4KMode.a => [
        clamp,
        'Anime4K_Restore_CNN_$primary.glsl',
        'Anime4K_Upscale_CNN_x2_$primary.glsl',
        ...downscale,
        ...tail,
      ],
      Anime4KMode.b => [
        clamp,
        'Anime4K_Restore_CNN_Soft_$primary.glsl',
        'Anime4K_Upscale_CNN_x2_$primary.glsl',
        ...downscale,
        ...tail,
      ],
      Anime4KMode.c => [
        clamp,
        'Anime4K_Upscale_Denoise_CNN_x2_$primary.glsl',
        ...downscale,
        ...tail,
      ],
      // A+A restores again *before* the downscale pair -- upstream's ordering.
      Anime4KMode.aa => [
        clamp,
        'Anime4K_Restore_CNN_$primary.glsl',
        'Anime4K_Upscale_CNN_x2_$primary.glsl',
        if (secondary != null) 'Anime4K_Restore_CNN_$secondary.glsl',
        ...downscale,
        ...tail,
      ],
      Anime4KMode.bb => [
        clamp,
        'Anime4K_Restore_CNN_Soft_$primary.glsl',
        'Anime4K_Upscale_CNN_x2_$primary.glsl',
        ...downscale,
        if (secondary != null) 'Anime4K_Restore_CNN_Soft_$secondary.glsl',
        ...tail,
      ],
      Anime4KMode.ca => [
        clamp,
        'Anime4K_Upscale_Denoise_CNN_x2_$primary.glsl',
        ...downscale,
        if (secondary != null) 'Anime4K_Restore_CNN_$secondary.glsl',
        ...tail,
      ],
    };
  }
}

/// What the player is currently running, for the status line.
class Anime4KSelection {
  const Anime4KSelection({
    required this.tier,
    required this.mode,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.displayWidth,
    required this.displayHeight,
  });

  final Anime4KTier tier;
  final Anime4KMode mode;
  final int sourceWidth;
  final int sourceHeight;
  final int displayWidth;
  final int displayHeight;

  bool get hasKnownDimensions =>
      sourceWidth > 0 &&
      sourceHeight > 0 &&
      displayWidth > 0 &&
      displayHeight > 0;

  double get scaleFactor {
    if (!hasKnownDimensions) return 1;
    final widthScale = displayWidth / sourceWidth;
    final heightScale = displayHeight / sourceHeight;
    return widthScale < heightScale ? widthScale : heightScale;
  }

  /// AutoDownscalePre only engages between 1.2x and 2x (per its own `//!WHEN`
  /// guard), so this reports whether real enlargement is happening rather than
  /// whether the chain is active -- the chain still restores at 1:1.
  bool get expectsUpscale => scaleFactor > 1.2;

  String get activeModeLabel =>
      tier.isCustom ? '${tier.label} · 自定义组合' : '${mode.label} · ${tier.label}';

  String resolutionDescription({bool previewingOriginal = false}) {
    if (!hasKnownDimensions) return '正在识别片源尺寸';
    final source = '片源 $sourceWidth×$sourceHeight';
    final display = '$displayWidth×$displayHeight';
    if (previewingOriginal) return '$source · 显示区域 $display · 原画';
    if (expectsUpscale) return '$source → 超分至 $display';
    return '$source · 显示区域 $display · 画质修复';
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
    required this.tier,
    required this.mode,
    required this.assetPaths,
    this.installedPaths = const [],
  });

  final Anime4KTier tier;
  final Anime4KMode mode;
  final List<String> assetPaths;
  final List<String> installedPaths;

  Anime4KShaderPipeline withInstalledPaths(List<String> paths) {
    return Anime4KShaderPipeline(
      tier: tier,
      mode: mode,
      assetPaths: assetPaths,
      installedPaths: List.unmodifiable(paths),
    );
  }
}

class Anime4KApplyResult {
  const Anime4KApplyResult({
    required this.tier,
    required this.mode,
    this.enabled = false,
    this.failure,
  });

  final Anime4KTier tier;
  final Anime4KMode mode;
  final bool enabled;
  final Object? failure;
}

typedef Anime4KPropertyGetter = Future<String> Function(String property);
typedef Anime4KPropertySetter =
    Future<void> Function(String property, String value);
typedef Anime4KPipelineInstaller =
    Future<Anime4KShaderPipeline> Function(
      Anime4KTier tier,
      Anime4KMode mode,
      List<String> customShaderNames,
    );

/// Owns the mpv property changes made by Anime4K and restores the previous
/// shader list when the feature is disabled or the pipeline fails.
///
/// There is no tier fallback: the tier the user picked is the tier that runs.
/// A failure disables the feature and surfaces a message instead of silently
/// substituting a weaker chain.
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
  Anime4KTier? _activeTier;
  Anime4KMode? _activeMode;
  String? _activeShaderList;
  bool _previewingOriginal = false;

  Anime4KTier? get activeTier => _activeTier;
  Anime4KMode? get activeMode => _activeMode;
  bool get previewingOriginal => _previewingOriginal;

  Future<Anime4KApplyResult> enable({
    required Anime4KTier tier,
    required Anime4KMode mode,
    List<String> customShaderNames = const [],
  }) async {
    await _captureOriginalShaderList();
    try {
      final pipeline = await installPipeline(tier, mode, customShaderNames);
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
      _activeTier = tier;
      _activeMode = mode;
      _activeShaderList = value;
      _previewingOriginal = false;
      return Anime4KApplyResult(tier: tier, mode: mode, enabled: true);
    } catch (error) {
      await disable();
      return Anime4KApplyResult(tier: tier, mode: mode, failure: error);
    }
  }

  Future<void> setPreviewOriginal(bool enabled) async {
    final original = _originalShaderList;
    final active = _activeShaderList;
    if (original == null || active == null || _activeTier == null) return;
    await setProperty('glsl-shaders', enabled ? original : active);
    _previewingOriginal = enabled;
  }

  Future<void> disable() async {
    final original = _originalShaderList;
    if (original != null) {
      await setProperty('glsl-shaders', original);
    }
    _activeTier = null;
    _activeMode = null;
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

  static Anime4KShaderPipeline pipelineFor(
    Anime4KTier tier, {
    Anime4KMode mode = Anime4KMode.a,
    List<String> customShaderNames = const [],
  }) {
    final names = tier.isCustom
        ? availableShaderFileNames
              .where(customShaderNames.toSet().contains)
              .toList(growable: false)
        : mode.fileNames(tier);
    return Anime4KShaderPipeline(
      tier: tier,
      mode: mode,
      assetPaths: List.unmodifiable(names.map((name) => '$_assetRoot$name')),
    );
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
    Anime4KTier tier, {
    Anime4KMode mode = Anime4KMode.a,
    List<String> customShaderNames = const [],
  }) async {
    final key =
        '${tier.settingValue}:${mode.settingValue}:'
        '${customShaderNames.join('|')}';
    final cached = _installedPipelines[key];
    if (cached != null) return cached;
    final install = _install(tier, mode, customShaderNames);
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
    Anime4KTier tier,
    Anime4KMode mode,
    List<String> customShaderNames,
  ) async {
    final pipeline = pipelineFor(
      tier,
      mode: mode,
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
