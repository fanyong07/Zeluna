import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../domain/anime_models.dart';
import '../anime4k_shader_manager.dart';

typedef Anime4KSupportResolver = Anime4KPlatformSupport Function();

@immutable
final class Anime4KDisplayStatus {
  const Anime4KDisplayStatus({
    required this.title,
    required this.detail,
    required this.previewingOriginal,
  });

  final String title;
  final String detail;
  final bool previewingOriginal;
}

/// Owns Anime4K shader operations for one native player.
///
/// The tier the user picked is the tier that runs. There is no frame-drop
/// monitor and no tier fallback: if the pipeline cannot be applied the feature
/// is disabled and says so, rather than quietly substituting a weaker chain.
final class Anime4KController extends ChangeNotifier {
  Anime4KController({
    required TargetPlatform platform,
    required Anime4KPropertyGetter getProperty,
    required Anime4KPropertySetter setProperty,
    Anime4KPipelineInstaller? installPipeline,
    Anime4KSupportResolver? resolveSupport,
    Anime4KShaderManager? shaderManager,
  }) : _resolveSupport =
           resolveSupport ??
           (() => Anime4KShaderManager.currentPlatformSupport) {
    final shaders = shaderManager ?? Anime4KShaderManager();
    _runtime = Anime4KMpvRuntime(
      platform: platform,
      installPipeline:
          installPipeline ??
          (tier, mode, customShaderNames) => shaders.ensureInstalled(
            tier,
            mode: mode,
            customShaderNames: customShaderNames,
          ),
      getProperty: getProperty,
      setProperty: setProperty,
    );
  }

  final Anime4KSupportResolver _resolveSupport;
  late final Anime4KMpvRuntime _runtime;

  PlaybackSettings _settings = const PlaybackSettings();
  String? _appliedKey;
  Anime4KSelection? _activeSelection;
  int _sourceWidth = 0;
  int _sourceHeight = 0;
  Size _viewportPhysicalSize = Size.zero;
  String? _statusMessage;
  Future<void> _operationQueue = Future<void>.value();
  bool _previewingOriginal = false;
  int _applySerial = 0;
  bool _disposed = false;

  Anime4KSelection? get activeSelection => _activeSelection;
  Anime4KTier? get activeTier => _activeSelection?.tier;
  Anime4KMode? get activeMode => _activeSelection?.mode;
  String? get statusMessage => _statusMessage;
  bool get previewingOriginal => _previewingOriginal;
  bool get isActive => _activeSelection != null && !_previewingOriginal;
  bool get isDisposed => _disposed;
  Future<void> get settled => _operationQueue;

  Anime4KDisplayStatus? get displayStatus {
    final selection = _activeSelection;
    if (selection == null) return null;
    final title = _previewingOriginal
        ? '原画预览'
        : selection.expectsUpscale
        ? '超分运行中'
        : '画质修复中';
    return Anime4KDisplayStatus(
      title: title,
      detail:
          '${selection.resolutionDescription(previewingOriginal: _previewingOriginal)}'
          ' · ${selection.activeModeLabel}',
      previewingOriginal: _previewingOriginal,
    );
  }

  void applySettings(PlaybackSettings settings, {bool force = false}) {
    if (_disposed) return;
    _settings = settings;
    final selection = _selectionFor(settings);
    final customShaders = settings.superResolutionCustomShaders;
    final key =
        '${settings.superResolution}:${selection.tier.settingValue}:'
        '${selection.mode.settingValue}:${customShaders.join('|')}';
    if (!force && _appliedKey == key) {
      // Dimensions or viewport may have moved, so keep the status line current
      // -- but only while a chain is actually running. Refreshing this when the
      // feature is off would fabricate an active selection.
      if (_activeSelection != null) _activeSelection = selection;
      return;
    }

    _appliedKey = key;
    final serial = ++_applySerial;
    _enqueue(
      () => _setShader(
        enabled: settings.superResolution,
        selection: selection,
        customShaderNames: customShaders,
        serial: serial,
      ),
    );
  }

  void refresh() {
    if (_disposed) return;
    applySettings(
      _settings,
      force: _settings.superResolution && _activeSelection == null,
    );
  }

  void updateVideoDimensions({required int width, required int height}) {
    if (_disposed || (_sourceWidth == width && _sourceHeight == height)) return;
    _sourceWidth = width;
    _sourceHeight = height;
    refresh();
    notifyListeners();
  }

  void resetVideo() {
    if (_disposed) return;
    _sourceWidth = 0;
    _sourceHeight = 0;
  }

  void updateViewport(Size physicalSize) {
    if (_disposed ||
        ((_viewportPhysicalSize.width - physicalSize.width).abs() < 1 &&
            (_viewportPhysicalSize.height - physicalSize.height).abs() < 1)) {
      return;
    }
    _viewportPhysicalSize = physicalSize;
    refresh();
    notifyListeners();
  }

  void setOriginalPreview(bool enabled) {
    if (_disposed ||
        _activeSelection == null ||
        _previewingOriginal == enabled) {
      return;
    }
    _previewingOriginal = enabled;
    notifyListeners();
    _enqueue(
      () => _runtime.setPreviewOriginal(enabled),
      onError: () {
        if (_disposed) return;
        _previewingOriginal = false;
        notifyListeners();
      },
    );
  }

  Future<void> _setShader({
    required bool enabled,
    required Anime4KSelection selection,
    required List<String> customShaderNames,
    required int serial,
  }) async {
    if (!_acceptsApply(serial)) return;
    try {
      if (!enabled) {
        await _runtime.disable();
        if (!_acceptsApply(serial)) return;
        _activeSelection = null;
        _previewingOriginal = false;
        _statusMessage = null;
        notifyListeners();
        return;
      }

      final support = _resolveSupport();
      if (!support.supported) {
        if (!_acceptsApply(serial)) return;
        _showUnavailable(support.reason ?? '当前平台不支持实时超分，已使用普通画质。');
        return;
      }
      if (selection.tier.isCustom && customShaderNames.isEmpty) {
        await _runtime.disable();
        if (!_acceptsApply(serial)) return;
        _showUnavailable('高级超分至少需要选择一个着色器。');
        return;
      }

      final result = await _runtime.enable(
        tier: selection.tier,
        mode: selection.mode,
        customShaderNames: customShaderNames,
      );
      if (!_acceptsApply(serial)) return;
      if (!result.enabled) {
        _showUnavailable('当前设备无法运行${selection.activeModeLabel}，已恢复普通画质。');
        return;
      }

      _activeSelection = selection;
      _previewingOriginal = false;
      _statusMessage = null;
      notifyListeners();
    } catch (_) {
      if (!_acceptsApply(serial) || !enabled) return;
      _showUnavailable('当前播放器无法启用实时超分，已自动恢复普通画质。');
    }
  }

  Anime4KSelection _selectionFor(PlaybackSettings settings) {
    var outputSize = _viewportPhysicalSize;
    if (_sourceWidth > 0 &&
        _sourceHeight > 0 &&
        outputSize.width > 0 &&
        outputSize.height > 0) {
      outputSize = applyBoxFit(
        _fitForVideoScale(settings.videoScale),
        Size(_sourceWidth.toDouble(), _sourceHeight.toDouble()),
        outputSize,
      ).destination;
    }
    if (outputSize == Size.zero && _sourceWidth > 0 && _sourceHeight > 0) {
      outputSize = Size(_sourceWidth.toDouble(), _sourceHeight.toDouble());
    }
    return Anime4KSelection(
      tier: Anime4KTier.fromSetting(settings.superResolutionTier),
      mode: Anime4KMode.fromSetting(settings.superResolutionMode),
      sourceWidth: _sourceWidth,
      sourceHeight: _sourceHeight,
      displayWidth: outputSize.width.round(),
      displayHeight: outputSize.height.round(),
    );
  }

  void _showUnavailable(String message) {
    if (_disposed) return;
    _activeSelection = null;
    _previewingOriginal = false;
    _statusMessage = message;
    notifyListeners();
  }

  void _enqueue(Future<void> Function() operation, {VoidCallback? onError}) {
    _operationQueue = _operationQueue
        .then((_) => _disposed ? null : operation())
        .catchError((Object _) => onError?.call());
  }

  bool _acceptsApply(int serial) => !_disposed && serial == _applySerial;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _applySerial++;
    super.dispose();
  }
}

BoxFit _fitForVideoScale(String value) {
  return switch (value) {
    '铺满' => BoxFit.cover,
    '拉伸' => BoxFit.fill,
    '原始' => BoxFit.none,
    _ => BoxFit.contain,
  };
}
