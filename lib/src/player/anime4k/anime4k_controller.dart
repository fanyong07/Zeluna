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

/// Owns Anime4K shader operations, frame-rate detection, performance
/// monitoring and fallback decisions for one native player.
final class Anime4KController extends ChangeNotifier {
  Anime4KController({
    required TargetPlatform platform,
    required Anime4KPropertyGetter getProperty,
    required Anime4KPropertySetter setProperty,
    Anime4KPipelineInstaller? installPipeline,
    Anime4KSupportResolver? resolveSupport,
    Anime4KShaderManager? shaderManager,
    Duration performanceSampleInterval = const Duration(seconds: 4),
  }) : _platform = platform,
       _getProperty = getProperty,
       _resolveSupport =
           resolveSupport ??
           (() => Anime4KShaderManager.currentPlatformSupport),
       _performanceSampleInterval = performanceSampleInterval {
    final shaders = shaderManager ?? Anime4KShaderManager();
    _runtime = Anime4KMpvRuntime(
      platform: platform,
      installPipeline:
          installPipeline ??
          (profile, tier, customShaderNames) => shaders.ensureInstalled(
            profile,
            tier: tier,
            customShaderNames: customShaderNames,
          ),
      getProperty: getProperty,
      setProperty: setProperty,
    );
  }

  final TargetPlatform _platform;
  final Anime4KPropertyGetter _getProperty;
  final Anime4KSupportResolver _resolveSupport;
  final Duration _performanceSampleInterval;
  late final Anime4KMpvRuntime _runtime;

  PlaybackSettings _settings = const PlaybackSettings();
  String? _appliedKey;
  Anime4KProfile? _activeProfile;
  Anime4KTier? _activeTier;
  Anime4KSelection? _activeSelection;
  int _sourceWidth = 0;
  int _sourceHeight = 0;
  Size _viewportPhysicalSize = Size.zero;
  double? _sourceFramesPerSecond;
  bool _frameRateIsMeasured = false;
  int _frameRateQuerySerial = 0;
  String? _statusMessage;
  Future<void> _operationQueue = Future<void>.value();
  bool _handlingFailure = false;
  bool _previewingOriginal = false;
  Timer? _performanceTimer;
  final Map<String, int> _performanceCounters = {};
  int _overloadSamples = 0;
  int _applySerial = 0;
  bool _playing = false;
  bool _buffering = false;
  bool _disposed = false;

  Anime4KSelection? get activeSelection => _activeSelection;
  Anime4KTier? get activeTier => _activeTier;
  String? get statusMessage => _statusMessage;
  bool get previewingOriginal => _previewingOriginal;
  bool get isActive => _activeSelection != null && !_previewingOriginal;
  bool get isDisposed => _disposed;
  Future<void> get settled => _operationQueue;

  Anime4KDisplayStatus? get displayStatus {
    final selection = _activeSelection;
    if (selection == null) return null;
    final mode = _previewingOriginal
        ? '原画预览'
        : selection.expectsUpscale
        ? '超分运行中'
        : selection.resolvedProfile.restoresWithoutScaling
        ? '画质修复中'
        : '当前尺寸无需放大';
    final dimensions = selection.resolutionDescription(
      previewingOriginal: _previewingOriginal,
    );
    final frameRate = selection.frameRateLabel;
    return Anime4KDisplayStatus(
      title: mode,
      detail:
          '$dimensions${frameRate == null ? '' : ' · $frameRate'} · '
          '${selection.activeModeLabel} · ${selection.tier.label}',
      previewingOriginal: _previewingOriginal,
    );
  }

  void applySettings(PlaybackSettings settings, {bool force = false}) {
    if (_disposed) return;
    _settings = settings;
    final selection = _selectionFor(settings);
    final customShaders = settings.superResolutionCustomShaders;
    final key =
        '${settings.superResolution}:${selection.requestedProfile.settingValue}:'
        '${selection.resolvedProfile.settingValue}:${selection.tier.settingValue}:'
        '${selection.pipelineProfile.settingValue}:'
        '${customShaders.join('|')}';
    if (!force && _appliedKey == key) {
      final activeTier = _activeTier;
      if (activeTier != null && _activeProfile == selection.resolvedProfile) {
        _activeSelection = selection.withTier(activeTier);
      }
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
    _sourceFramesPerSecond = null;
    _frameRateIsMeasured = false;
    _frameRateQuerySerial++;
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

  void updatePlaybackState({required bool playing, required bool buffering}) {
    _playing = playing;
    _buffering = buffering;
  }

  Future<void> refreshFrameRate({required bool usesWebPlayer}) async {
    if (_disposed || usesWebPlayer || _sourceWidth <= 0) return;
    final serial = ++_frameRateQuerySerial;

    Future<double?> readFrameRate(String property) async {
      try {
        return Anime4KShaderManager.parseFrameRate(
          await _getProperty(property),
        );
      } catch (_) {
        return null;
      }
    }

    final measured = await readFrameRate('estimated-vf-fps');
    if (_disposed || serial != _frameRateQuerySerial) return;
    final container = measured == null
        ? await readFrameRate('container-fps')
        : null;
    final value = measured ?? container;
    if (_disposed || serial != _frameRateQuerySerial || value == null) return;

    final isMeasured = measured != null;
    final current = _sourceFramesPerSecond;
    if (_frameRateIsMeasured && !isMeasured) return;
    if (_frameRateIsMeasured == isMeasured &&
        current != null &&
        value <= current + 0.5) {
      return;
    }
    _sourceFramesPerSecond = value;
    _frameRateIsMeasured = isMeasured;
    refresh();
    notifyListeners();
  }

  void handlePlayerLog({required String prefix, required String text}) {
    final activeProfile = _activeProfile;
    final activeTier = _activeTier;
    if (_disposed ||
        activeProfile == null ||
        activeTier == null ||
        _handlingFailure ||
        !_settings.superResolution) {
      return;
    }
    final message = '$prefix $text'.toLowerCase();
    final isShaderFailure =
        message.contains('shader') &&
        (message.contains('error') ||
            message.contains('failed') ||
            message.contains('compile') ||
            message.contains('could not'));
    if (!isShaderFailure) return;
    _scheduleFallback(activeTier);
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

  Future<void> samplePerformance() async {
    final activeTier = _activeTier;
    if (_disposed ||
        activeTier == null ||
        activeTier == Anime4KTier.performance ||
        !_playing ||
        _buffering ||
        _previewingOriginal ||
        _handlingFailure) {
      return;
    }

    var largestDelta = 0;
    var foundCounter = false;
    for (final property in const [
      'vo-drop-frame-count',
      'mistimed-frame-count',
      'delayed-frame-count',
    ]) {
      if (_disposed) return;
      try {
        final value = await _runtime.readCounter(property);
        if (_disposed) return;
        if (value == null) continue;
        foundCounter = true;
        final previous = _performanceCounters[property];
        _performanceCounters[property] = value;
        if (previous != null && value >= previous) {
          final delta = value - previous;
          if (delta > largestDelta) largestDelta = delta;
        }
      } catch (_) {
        // Some libmpv builds do not expose every rendering counter.
      }
    }
    if (_disposed || !foundCounter) return;
    if (largestDelta >= 4) {
      _overloadSamples++;
    } else {
      _overloadSamples = 0;
    }
    if (_overloadSamples < 2) return;

    _overloadSamples = 0;
    _scheduleFallback(activeTier);
  }

  Future<void> _setShader({
    required bool enabled,
    required Anime4KSelection selection,
    required List<String> customShaderNames,
    required int serial,
    Anime4KTier? skipTier,
  }) async {
    if (!_acceptsApply(serial)) return;
    try {
      if (!enabled) {
        await _runtime.disable();
        if (!_acceptsApply(serial)) return;
        _stopPerformanceMonitor();
        _activeProfile = null;
        _activeTier = null;
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
      if (selection.resolvedProfile == Anime4KProfile.advanced &&
          customShaderNames.isEmpty) {
        await _runtime.disable();
        if (!_acceptsApply(serial)) return;
        _showUnavailable('高级超分至少需要选择一个着色器。');
        return;
      }

      final result = await _runtime.enable(
        selection.pipelineProfile,
        requestedTier: selection.tier,
        skipTier: skipTier,
        customShaderNames: customShaderNames,
      );
      if (!_acceptsApply(serial)) return;
      if (!result.enabled) {
        _showUnavailable('当前设备无法运行 Anime4K 超分，已自动恢复普通画质。');
        return;
      }

      _activeProfile = selection.resolvedProfile;
      _activeTier = result.activeTier;
      _activeSelection = selection.withTier(result.activeTier!);
      _previewingOriginal = false;
      _statusMessage = result.usedFallback
          ? '${selection.resolvedProfile.label}已从${result.requestedTier.label}'
                '降为${result.activeTier!.label}，保证播放流畅。'
          : null;
      notifyListeners();
      _startPerformanceMonitor();
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
    return Anime4KShaderManager.select(
      requestedProfile: Anime4KProfile.fromSetting(
        settings.superResolutionProfile,
      ),
      platform: _platform,
      sourceWidth: _sourceWidth,
      sourceHeight: _sourceHeight,
      displayWidth: outputSize.width.round(),
      displayHeight: outputSize.height.round(),
      sourceFramesPerSecond: _sourceFramesPerSecond ?? 0,
    );
  }

  void _scheduleFallback(Anime4KTier activeTier) {
    if (_disposed || _handlingFailure) return;
    _handlingFailure = true;
    final selection = _selectionFor(_settings);
    final serial = ++_applySerial;
    _operationQueue = _operationQueue
        .then(
          (_) => _setShader(
            enabled: true,
            selection: selection,
            customShaderNames: _settings.superResolutionCustomShaders,
            serial: serial,
            skipTier: activeTier,
          ),
        )
        .catchError((Object _) {})
        .whenComplete(() => _handlingFailure = false);
  }

  void _showUnavailable(String message) {
    if (_disposed) return;
    _stopPerformanceMonitor();
    _activeProfile = null;
    _activeTier = null;
    _activeSelection = null;
    _previewingOriginal = false;
    _statusMessage = message;
    notifyListeners();
  }

  void _startPerformanceMonitor() {
    _stopPerformanceMonitor();
    if (_disposed) return;
    _performanceTimer = Timer.periodic(_performanceSampleInterval, (_) {
      if (!_disposed) unawaited(samplePerformance());
    });
  }

  void _stopPerformanceMonitor() {
    _performanceTimer?.cancel();
    _performanceTimer = null;
    _performanceCounters.clear();
    _overloadSamples = 0;
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
    _frameRateQuerySerial++;
    _stopPerformanceMonitor();
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
