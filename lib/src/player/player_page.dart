import 'dart:async';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../app/anime_app.dart';
import '../data/anime_controller.dart';
import '../data/playback_source_repository.dart';
import '../domain/anime_models.dart';
import '../rules/rule_playback_resolver.dart';
import '../settings/settings_page.dart';
import '../shared_ui/app_chrome.dart';
import '../shared_ui/app_navigation.dart';
import '../shared_ui/poster_card.dart';
import 'anime4k_shader_manager.dart';
import 'danmaku_overlay.dart';
import 'playback_line_display.dart';
import 'web_stream_player.dart';

class PlayerPage extends ConsumerStatefulWidget {
  const PlayerPage({super.key, required this.request});

  final PlaySessionRequest request;

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage> {
  late AnimeEpisode _episode;
  late final Player _player;
  late final VideoController _controller;
  late final WebStreamPlayerController _webPlayerController;
  late final FocusNode _shortcutFocusNode;
  final _anime4kShaders = Anime4KShaderManager();
  final _subscriptions = <StreamSubscription<dynamic>>[];
  StreamSubscription<PlaybackLineLookupUpdate>? _lineLookupSubscription;
  RulePlaybackCancellationToken? _lineLookupCancellationToken;
  final _failedLineIds = <String>{};
  PlaybackLine? _line;
  List<PlaybackLine> _lines = const [];
  String? _loadedUrl;
  String? _playerMessage;
  String? _lineLookupMessage;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffer = Duration.zero;
  double _volume = 100;
  double _lastNonZeroVolume = 100;
  double? _appliedRate;
  double? _appliedVolume;
  String? _appliedSuperResolutionKey;
  Anime4KMpvRuntime? _anime4kRuntime;
  Anime4KProfile? _activeSuperResolutionProfile;
  String? _superResolutionStatusMessage;
  String? _lastSuperResolutionNotice;
  DateTime? _superResolutionAppliedAt;
  Future<void> _superResolutionQueue = Future<void>.value();
  bool _handlingSuperResolutionFailure = false;
  bool _controlsVisible = true;
  bool _pointerInChromeHotZone = false;
  var _playing = false;
  var _buffering = false;
  var _loadingLine = false;
  var _lineLookupInProgress = false;
  var _lineScanInProgress = false;
  var _lineScanComplete = false;
  var _lineScanCompletedRules = 0;
  var _lineScanTotalRules = 0;
  var _playbackFailed = false;
  var _fullscreen = false;
  var _muted = false;
  var _autoSwitching = false;
  var _autoSwitchRetryPending = false;
  var _leaving = false;
  var _lineLookupSerial = 0;
  var _openLineSerial = 0;
  var _superResolutionApplySerial = 0;
  PlaybackSettings _currentSettings = const PlaybackSettings();
  Timer? _controlsHideTimer;
  Timer? _webLoadTimer;
  Timer? _nativeFirstFrameTimer;
  Timer? _expandedLookupDelayTimer;
  String? _preferredProviderId;
  final _localDanmakuTimers = <Timer>[];
  bool _episodePanel = false;
  bool _linePanel = false;
  bool _subtitlePanel = false;
  bool _danmakuPanel = false;
  bool _settingsPanel = false;
  bool _theaterMode = false;
  SubtitleCandidate? _selectedSubtitle;
  final _danmakuInput = TextEditingController();
  final List<_LocalDanmakuEntry> _localDanmaku = [];
  List<DanmakuComment> _remoteDanmaku = const [];
  var _danmakuLoadSerial = 0;
  int? _danmakuRequestedEpisodeId;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);
    _webPlayerController = WebStreamPlayerController();
    _shortcutFocusNode = FocusNode(debugLabel: 'player-shortcuts');
    _episode = widget.request.episode;
    _line = widget.request.initialLine;
    _lines = initialPlaybackLinesForDisplay(widget.request.initialLine);
    _bindPlayer();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _requestPlayerFocus();
      _applyPlaybackSettings(_currentSettings);
      if (_isPlayableLine(_line)) {
        unawaited(_openLine(_line!, force: true));
        if (!widget.request.offlineOnly &&
            widget.request.subject.source != 'direct') {
          unawaited(_resolveLinesForCurrentEpisode(autoplay: false));
        }
      } else if (!widget.request.offlineOnly) {
        unawaited(_resolveLinesForCurrentEpisode());
      }
    });
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _controlsHideTimer?.cancel();
    _webLoadTimer?.cancel();
    _nativeFirstFrameTimer?.cancel();
    _expandedLookupDelayTimer?.cancel();
    _lineLookupCancellationToken?.cancel();
    unawaited(_lineLookupSubscription?.cancel());
    for (final timer in _localDanmakuTimers) {
      timer.cancel();
    }
    _localDanmakuTimers.clear();
    unawaited(_restoreSystemUi());
    unawaited(_player.dispose());
    _danmakuInput.dispose();
    _shortcutFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AsyncAnimeGate(
      builder: (context, state) {
        _applyPlaybackSettings(state.settings);
        final panelOpen = _hasOpenPanel;
        return PopScope<Object?>(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop) unawaited(_handleBack());
          },
          child: Scaffold(
            backgroundColor: AppColors.theaterBg,
            body: Focus(
              focusNode: _shortcutFocusNode,
              autofocus: true,
              onKeyEvent: (node, event) =>
                  _handleShortcut(event, state.settings),
              child: SafeArea(
                top: !_fullscreen,
                bottom: !_fullscreen,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _PlayerCanvas(
                      controller: _controller,
                      webPlayerController: _webPlayerController,
                      subject: widget.request.subject,
                      episodes: widget.request.episodes,
                      episode: _episode,
                      line: _line,
                      settings: state.settings,
                      superResolutionProfile: _activeSuperResolutionProfile,
                      services: state.services,
                      danmaku: state.danmaku,
                      remoteDanmaku: _remoteDanmaku,
                      localDanmaku: _localDanmaku,
                      theaterMode: _theaterMode,
                      position: _position,
                      duration: _duration,
                      buffer: _buffer,
                      volume: _volume,
                      playing: _playing,
                      buffering: _buffering,
                      loadingLine: _loadingLine,
                      lineLookupInProgress: _lineLookupInProgress,
                      playbackFailed: _playbackFailed,
                      fullscreen: _fullscreen,
                      muted: _muted,
                      controlsVisible: _controlsVisible,
                      autoHideChrome: _shouldAutoHidePlayerControls,
                      playerMessage: _surfaceMessage,
                      onUserInteraction: _revealPlayerControls,
                      onChromeHotZoneChanged: _handlePlayerChromeHotZoneChanged,
                      onBack: _handleBack,
                      onReload: _reloadCurrentLine,
                      onScreenshot: _captureScreenshot,
                      onTheaterMode: _toggleTheaterMode,
                      onCast: _showExternalPlayback,
                      onPlayPause: _togglePlayPause,
                      onRewind: () => _seekBy(
                        Duration(seconds: -state.settings.rewindSeconds),
                      ),
                      onForward: () => _seekBy(
                        Duration(seconds: state.settings.forwardSeconds),
                      ),
                      onSeek: _seekTo,
                      onMute: _toggleMute,
                      onVolumeChanged: _setVolume,
                      onSpeedSelected: _selectSpeed,
                      onFullscreen: () => _setFullscreen(!_fullscreen),
                      onEpisodePanel: _toggleEpisodePanel,
                      onEpisodeSelected: _selectEpisode,
                      onLinePanel: _toggleLinePanel,
                      onSubtitlePanel: _toggleSubtitlePanel,
                      onDanmakuPanel: _toggleDanmakuPanel,
                      danmakuInput: _danmakuInput,
                      onSendDanmaku: (text) =>
                          _sendLocalDanmaku(text, settings: state.danmaku),
                      onWebReady: _handleWebReady,
                      onWebError: _handleWebError,
                      onWebPosition: _handleWebPosition,
                      onWebDuration: _handleWebDuration,
                      onWebPlaying: _handleWebPlaying,
                      onSettingsPanel: _toggleSettingsPanel,
                    ),
                    if (panelOpen)
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _closePanels,
                          child: ColoredBox(
                            color: Colors.black.withValues(
                              alpha: _fullscreen ? 0.20 : 0.08,
                            ),
                          ),
                        ),
                      ),
                    if (_episodePanel)
                      _SideSheet(
                        title: '选集',
                        onClose: _closePanels,
                        child: _EpisodePanel(
                          subject: widget.request.subject,
                          episodes: widget.request.episodes,
                          selected: _episode,
                          onSelected: _selectEpisode,
                        ),
                      ),
                    if (_linePanel)
                      _SideSheet(
                        title: '切换线路',
                        onClose: _closePanels,
                        child: _LinePanel(
                          selected: _line,
                          lines: _lines,
                          failedLineIds: _failedLineIds,
                          scanning: _lineScanInProgress,
                          completedRules: _lineScanCompletedRules,
                          totalRules: _lineScanTotalRules,
                          onSelected: _selectLine,
                        ),
                      ),
                    if (_subtitlePanel)
                      _SideSheet(
                        title: '字幕源',
                        onClose: _closePanels,
                        child: _SubtitlePanel(
                          subject: widget.request.subject,
                          episode: _episode,
                          selected: _selectedSubtitle,
                          onSelected: _selectSubtitle,
                          onDisabled: _disableSubtitle,
                        ),
                      ),
                    if (_danmakuPanel)
                      _SideSheet(
                        title: '弹幕源',
                        onClose: _closePanels,
                        child: _DanmakuPanel(
                          subject: widget.request.subject,
                          episode: _episode,
                        ),
                      ),
                    if (_settingsPanel)
                      _SideSheet(
                        title: '',
                        onClose: _closePanels,
                        child: PlaybackSettingsView(
                          compact: true,
                          subject: widget.request.subject,
                          episode: _episode,
                          line: _line,
                          playbackMessage: _surfaceMessage,
                          settings: state.settings,
                          onChanged: (settings) => ref
                              .read(animeControllerProvider.notifier)
                              .updateSettings(settings),
                          onBack: () => setState(() => _settingsPanel = false),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  String? get _surfaceMessage {
    if (_lineLookupInProgress) return '正在查找可播放线路...';
    if (_loadingLine) {
      return '正在连接 ${_line == null ? '播放源' : playbackLineProviderLabel(_line!)}...';
    }
    if (_playbackFailed) return _playerMessage ?? '当前线路无法播放，请切换线路。';
    if (!_isPlayableLine(_line)) {
      return _lineLookupMessage ?? '当前集还没有选中可播放线路。';
    }
    if (_buffering) return '缓冲中...';
    return _playerMessage ?? _superResolutionStatusMessage;
  }

  bool get _usesWebPlayer {
    final loadedUrl = _loadedUrl?.trim() ?? '';
    final url = loadedUrl.isNotEmpty ? loadedUrl : _line?.url?.trim() ?? '';
    return supportsWebStreamPlayer && shouldUseWebStreamPlayer(url);
  }

  bool get _shouldAutoHidePlayerControls {
    return _playing &&
        !_buffering &&
        !_loadingLine &&
        !_lineLookupInProgress &&
        !_playbackFailed &&
        !_hasOpenPanel;
  }

  void _revealPlayerControls() {
    if (!mounted) return;
    _controlsHideTimer?.cancel();
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
    if (!_shouldAutoHidePlayerControls || _pointerInChromeHotZone) return;
    _scheduleControlsHide();
  }

  void _handlePlayerChromeHotZoneChanged(bool inHotZone) {
    if (!mounted || _pointerInChromeHotZone == inHotZone) return;
    _pointerInChromeHotZone = inHotZone;
    if (inHotZone) {
      _controlsHideTimer?.cancel();
      if (!_controlsVisible) setState(() => _controlsVisible = true);
      return;
    }
    _scheduleControlsHide();
  }

  void _scheduleControlsHide() {
    _controlsHideTimer?.cancel();
    if (!_shouldAutoHidePlayerControls) return;
    _controlsHideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted ||
          !_shouldAutoHidePlayerControls ||
          _pointerInChromeHotZone) {
        return;
      }
      setState(() => _controlsVisible = false);
    });
  }

  void _requestPlayerFocus() {
    if (!mounted) return;
    FocusScope.of(context).requestFocus(_shortcutFocusNode);
  }

  KeyEventResult _handleShortcut(KeyEvent event, PlaybackSettings settings) {
    if (!settings.keyboardShortcutsEnabled) return KeyEventResult.ignored;
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      if (_hasOpenPanel) {
        _closePanels();
      } else if (_fullscreen) {
        unawaited(_setFullscreen(false));
      } else {
        return KeyEventResult.ignored;
      }
      _requestPlayerFocus();
      return KeyEventResult.handled;
    }
    if (_hasOpenPanel) return KeyEventResult.ignored;
    _revealPlayerControls();
    if (settings.shortcutPlayPause &&
        (key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.keyK)) {
      unawaited(_togglePlayPause());
      return KeyEventResult.handled;
    }
    if (settings.shortcutSeek && key == LogicalKeyboardKey.arrowLeft) {
      unawaited(_seekBy(Duration(seconds: -settings.rewindSeconds)));
      return KeyEventResult.handled;
    }
    if (settings.shortcutSeek && key == LogicalKeyboardKey.arrowRight) {
      unawaited(_seekBy(Duration(seconds: settings.forwardSeconds)));
      return KeyEventResult.handled;
    }
    if (settings.shortcutVolume && key == LogicalKeyboardKey.arrowUp) {
      unawaited(_adjustVolume(8));
      return KeyEventResult.handled;
    }
    if (settings.shortcutVolume && key == LogicalKeyboardKey.arrowDown) {
      unawaited(_adjustVolume(-8));
      return KeyEventResult.handled;
    }
    if (settings.shortcutFullscreen && key == LogicalKeyboardKey.keyF) {
      unawaited(_setFullscreen(!_fullscreen));
      return KeyEventResult.handled;
    }
    if (settings.shortcutMute && key == LogicalKeyboardKey.keyM) {
      unawaited(_toggleMute());
      return KeyEventResult.handled;
    }
    if (settings.shortcutReload && key == LogicalKeyboardKey.keyR) {
      unawaited(_reloadCurrentLine());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _bindPlayer() {
    _subscriptions
      ..add(
        _player.stream.playing.listen((value) {
          if (!mounted || _usesWebPlayer) return;
          setState(() => _playing = value);
          if (value) {
            _scheduleControlsHide();
          } else {
            _controlsHideTimer?.cancel();
            if (!_controlsVisible) setState(() => _controlsVisible = true);
          }
        }),
      )
      ..add(
        _player.stream.position.listen((value) {
          if (!mounted || _usesWebPlayer) return;
          final previousPosition = _position;
          final reachedFirstFrame =
              _nativeFirstFrameTimer != null &&
              nativePlaybackReachedFirstFrame(
                previousPosition: previousPosition,
                currentPosition: value,
              );
          if (reachedFirstFrame) {
            _nativeFirstFrameTimer?.cancel();
            _nativeFirstFrameTimer = null;
            final current = _line;
            if (current != null) {
              _failedLineIds.remove(current.id);
              _preferredProviderId = current.providerId;
            }
          }
          setState(() {
            _position = value;
            if (reachedFirstFrame) {
              _loadingLine = false;
              _playbackFailed = false;
              _playerMessage = null;
            }
          });
          if (reachedFirstFrame) {
            _scheduleExpandedLineLookup();
          }
        }),
      )
      ..add(
        _player.stream.duration.listen((value) {
          if (mounted && !_usesWebPlayer) setState(() => _duration = value);
        }),
      )
      ..add(
        _player.stream.buffer.listen((value) {
          if (mounted && !_usesWebPlayer) setState(() => _buffer = value);
        }),
      )
      ..add(
        _player.stream.videoParams.listen((value) {
          if (mounted && !_usesWebPlayer) _refreshSuperResolutionShader();
        }),
      )
      ..add(
        _player.stream.buffering.listen((value) {
          if (mounted && !_usesWebPlayer) setState(() => _buffering = value);
        }),
      )
      ..add(
        _player.stream.volume.listen((value) {
          if (mounted) {
            setState(() {
              _volume = value;
              if (!_muted && value > 0) _lastNonZeroVolume = value;
            });
          }
        }),
      )
      ..add(
        _player.stream.completed.listen((completed) {
          if (_usesWebPlayer) return;
          if (completed && _currentSettings.autoNext) _playNextEpisode();
        }),
      )
      ..add(
        _player.stream.error.listen((error) {
          if (_usesWebPlayer) return;
          _handlePlayerError(error);
        }),
      )
      ..add(_player.stream.log.listen(_handleSuperResolutionLog));
  }

  void _applyPlaybackSettings(PlaybackSettings settings) {
    _currentSettings = settings;
    final targetRate = settings.speed <= 0 ? 1.0 : settings.speed;
    if (_appliedRate != targetRate) {
      _appliedRate = targetRate;
      unawaited(_player.setRate(targetRate));
    }
    final targetVolume = _muted ? 0.0 : _volumeFromSettings(settings);
    if (_appliedVolume != targetVolume) {
      _appliedVolume = targetVolume;
      unawaited(_player.setVolume(targetVolume));
    }
    _applyVideoRenderSettings(settings);
    if (settings.autoFullscreen && !_fullscreen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_fullscreen) unawaited(_setFullscreen(true));
      });
    }
  }

  void _applyVideoRenderSettings(
    PlaybackSettings settings, {
    bool force = false,
  }) {
    final profile = Anime4KProfile.fromSetting(settings.superResolutionProfile);
    final key = '${settings.superResolution}:${profile.settingValue}';
    if (!force && _appliedSuperResolutionKey == key) {
      return;
    }
    _appliedSuperResolutionKey = key;
    final serial = ++_superResolutionApplySerial;
    _superResolutionQueue = _superResolutionQueue
        .then(
          (_) => _setSuperResolutionShader(
            enabled: settings.superResolution,
            requestedProfile: profile,
            serial: serial,
          ),
        )
        .catchError((Object _) {});
  }

  Future<void> _setSuperResolutionShader({
    required bool enabled,
    required Anime4KProfile requestedProfile,
    required int serial,
    Anime4KProfile? skipProfile,
  }) async {
    if (serial != _superResolutionApplySerial) return;
    try {
      if (!enabled) {
        await _anime4kRuntime?.disable();
        if (!mounted || serial != _superResolutionApplySerial) return;
        setState(() {
          _activeSuperResolutionProfile = null;
          _superResolutionStatusMessage = null;
          _lastSuperResolutionNotice = null;
        });
        return;
      }

      final support = Anime4KShaderManager.currentPlatformSupport;
      if (!support.supported) {
        if (!mounted || serial != _superResolutionApplySerial) return;
        _showSuperResolutionUnavailable(
          support.reason ?? '当前平台不支持实时超分，已使用普通画质。',
        );
        return;
      }

      final runtime = _anime4kRuntime ??= _createAnime4KRuntime();
      final result = await runtime.enable(
        requestedProfile,
        skipProfile: skipProfile,
      );
      if (!mounted || serial != _superResolutionApplySerial) return;
      if (!result.enabled) {
        _showSuperResolutionUnavailable('当前设备无法运行 Anime4K 超分，已自动恢复普通画质。');
        return;
      }

      setState(() {
        _activeSuperResolutionProfile = result.activeProfile;
        _superResolutionStatusMessage = null;
      });
      _superResolutionAppliedAt = DateTime.now();
      if (result.usedFallback) {
        _showPlayerToast(
          '${requestedProfile.label}档负载过高，已切换为'
          '${result.activeProfile!.label}超分。',
        );
      }
    } catch (error) {
      if (!mounted || !enabled || serial != _superResolutionApplySerial) {
        return;
      }
      _showSuperResolutionUnavailable('当前播放器无法启用实时超分，已自动恢复普通画质。');
    }
  }

  Anime4KMpvRuntime _createAnime4KRuntime() {
    final platform = _player.platform;
    if (platform is! NativePlayer) {
      throw UnsupportedError('The current player is not backed by libmpv.');
    }
    final nativePlayer = platform as dynamic;
    return Anime4KMpvRuntime(
      platform: defaultTargetPlatform,
      installPipeline: _anime4kShaders.ensureInstalled,
      getProperty: (property) async {
        final value = await nativePlayer.getProperty(property);
        return value?.toString() ?? '';
      },
      setProperty: (property, value) async {
        await nativePlayer.setProperty(property, value);
      },
    );
  }

  void _handleSuperResolutionLog(PlayerLog log) {
    final activeProfile = _activeSuperResolutionProfile;
    final appliedAt = _superResolutionAppliedAt;
    if (activeProfile == null ||
        appliedAt == null ||
        DateTime.now().difference(appliedAt) > const Duration(seconds: 4) ||
        _handlingSuperResolutionFailure ||
        !_currentSettings.superResolution) {
      return;
    }
    final message = '${log.prefix} ${log.text}'.toLowerCase();
    final isShaderFailure =
        message.contains('shader') &&
        (message.contains('error') ||
            message.contains('failed') ||
            message.contains('compile') ||
            message.contains('could not'));
    if (!isShaderFailure) return;

    _handlingSuperResolutionFailure = true;
    final requestedProfile = Anime4KProfile.fromSetting(
      _currentSettings.superResolutionProfile,
    );
    final serial = ++_superResolutionApplySerial;
    _superResolutionQueue = _superResolutionQueue
        .then(
          (_) => _setSuperResolutionShader(
            enabled: true,
            requestedProfile: requestedProfile,
            serial: serial,
            skipProfile: activeProfile,
          ),
        )
        .catchError((Object _) {})
        .whenComplete(() => _handlingSuperResolutionFailure = false);
  }

  void _showSuperResolutionUnavailable(String message) {
    final shouldNotify = _lastSuperResolutionNotice != message;
    setState(() {
      _activeSuperResolutionProfile = null;
      _superResolutionStatusMessage = message;
      _lastSuperResolutionNotice = message;
    });
    if (shouldNotify) _showPlayerToast(message);
  }

  void _refreshSuperResolutionShader() {
    _applyVideoRenderSettings(_currentSettings, force: true);
  }

  double _volumeFromSettings(PlaybackSettings settings) {
    return (100 + settings.volumeBoost * 100).clamp(0, 200).toDouble();
  }

  Future<void> _resolveLinesForCurrentEpisode({bool autoplay = true}) async {
    final serial = ++_lineLookupSerial;
    _expandedLookupDelayTimer?.cancel();
    _expandedLookupDelayTimer = null;
    _lineLookupCancellationToken?.cancel();
    final previousSubscription = _lineLookupSubscription;
    _lineLookupSubscription = null;
    if (previousSubscription != null) await previousSubscription.cancel();
    if (!mounted || serial != _lineLookupSerial) return;
    final cancellationToken = RulePlaybackCancellationToken();
    _lineLookupCancellationToken = cancellationToken;
    final usesProgressiveLookup = _usesProgressiveRuleLookup(
      widget.request.subject,
    );
    setState(() {
      _lineLookupInProgress = true;
      _lineScanInProgress = false;
      _lineScanComplete = !usesProgressiveLookup;
      _lineScanCompletedRules = 0;
      _lineScanTotalRules = 0;
      _lineLookupMessage = null;
      _playerMessage = null;
      _playbackFailed = false;
    });
    try {
      final discoveredLines = await ref
          .read(animeControllerProvider.notifier)
          .linesForEpisode(
            widget.request.subject,
            _episode,
            cancellationToken: cancellationToken,
          );
      if (!mounted ||
          serial != _lineLookupSerial ||
          cancellationToken.isCancelled) {
        return;
      }
      final controller = ref.read(animeControllerProvider.notifier);
      final lines = await verifyPlaybackLinesBeforeDisplay(
        discoveredLines,
        verify: (line) => controller.verifyPlaybackLine(
          line,
          enrichMetadata: false,
          cancellationToken: cancellationToken,
        ),
      );
      if (!mounted ||
          serial != _lineLookupSerial ||
          cancellationToken.isCancelled) {
        return;
      }
      final available = _availableLines(lines);
      PlaybackLine? nextLine = _line;
      if (!_isPlayableLine(nextLine) && available.isNotEmpty) {
        nextLine = _preferredPlayableLine(available);
      }
      setState(() {
        _lines = lines;
        _line = nextLine;
        _lineLookupInProgress = available.isEmpty && usesProgressiveLookup;
        _lineLookupMessage = available.isEmpty
            ? '快速查找暂未发现可用线路，正在后台继续扫描…'
            : null;
      });
      if (autoplay && _isPlayableLine(nextLine)) {
        await _openLine(nextLine!, force: true);
      } else if (available.isEmpty && usesProgressiveLookup) {
        _startExpandedLineLookup(autoplay: autoplay);
      } else if (available.isEmpty) {
        await _player.stop();
      }
    } catch (error) {
      if (!mounted || serial != _lineLookupSerial) return;
      setState(() {
        _lines = const [];
        _lineLookupInProgress = false;
        _lineLookupMessage = '线路解析失败：${_friendlyPlaybackError(error)}';
        _playbackFailed = true;
      });
    }
  }

  void _scheduleExpandedLineLookup() {
    if (!_usesProgressiveRuleLookup(widget.request.subject) ||
        _lineScanComplete ||
        _lineScanInProgress ||
        _lineLookupSubscription != null ||
        widget.request.offlineOnly) {
      return;
    }
    if (_expandedLookupDelayTimer != null) return;
    _expandedLookupDelayTimer = Timer(const Duration(milliseconds: 450), () {
      _expandedLookupDelayTimer = null;
      _startExpandedLineLookup();
    });
  }

  void _startExpandedLineLookup({bool autoplay = false}) {
    if (!mounted ||
        widget.request.offlineOnly ||
        !_usesProgressiveRuleLookup(widget.request.subject) ||
        _lineScanComplete ||
        _lineScanInProgress ||
        _lineLookupSubscription != null) {
      return;
    }
    _expandedLookupDelayTimer?.cancel();
    _expandedLookupDelayTimer = null;
    final serial = _lineLookupSerial;
    final episodeId = _episode.id;
    final cancellationToken = _lineLookupCancellationToken ??=
        RulePlaybackCancellationToken();
    if (cancellationToken.isCancelled) return;
    setState(() {
      _lineScanInProgress = true;
      _lineScanCompletedRules = 0;
      _lineScanTotalRules = 0;
      if (!_isPlayableLine(_line)) _lineLookupInProgress = true;
    });

    late final StreamSubscription<PlaybackLineLookupUpdate> subscription;
    subscription = ref
        .read(animeControllerProvider.notifier)
        .lineUpdatesForEpisode(
          widget.request.subject,
          _episode,
          cancellationToken: cancellationToken,
        )
        .listen(
          (update) {
            if (!mounted ||
                serial != _lineLookupSerial ||
                episodeId != _episode.id ||
                cancellationToken.isCancelled) {
              return;
            }
            var merged = mergePlaybackLineSnapshot(
              currentLines: _lines,
              snapshotLines: update.lines,
              replacedProviderId:
                  update.phase == PlaybackLineLookupPhase.verification
                  ? update.resolvedProviderId
                  : null,
              authoritative: update.isComplete,
            );
            merged = _preserveLoadedLineIfProbeDisagrees(merged);
            final available = _availableLines(merged);
            PlaybackLine? selected = _line;
            if (selected != null) {
              final refreshed = _lineById(merged, selected.id);
              if (refreshed != null &&
                  (refreshed.available || _playbackFailed)) {
                selected = refreshed;
              }
            }
            final currentFailed =
                _playbackFailed ||
                (selected != null && _failedLineIds.contains(selected.id));
            final target = currentFailed || !_isPlayableLine(selected)
                ? _preferredPlayableLine(available)
                : selected;
            final shouldOpen =
                target != null &&
                !_failedLineIds.contains(target.id) &&
                ((autoplay &&
                        (!_isPlayableLine(_line) || _loadedUrl == null)) ||
                    (currentFailed && _currentSettings.autoSwitchLine));
            setState(() {
              _lines = merged;
              _line = shouldOpen ? target : selected;
              _lineScanInProgress = !update.isComplete;
              _lineScanComplete = update.isComplete;
              _lineScanCompletedRules = update.completedRules;
              _lineScanTotalRules = update.totalRules;
              _lineLookupInProgress = available.isEmpty && !update.isComplete;
              _lineLookupMessage = available.isEmpty
                  ? update.isComplete
                        ? _emptyLineMessage(
                            merged,
                            subject: widget.request.subject,
                          )
                        : _progressiveLookupMessage(update)
                  : null;
            });
            if (shouldOpen) unawaited(_openLine(target, force: true));
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!mounted ||
                serial != _lineLookupSerial ||
                episodeId != _episode.id) {
              return;
            }
            setState(() {
              _lineScanInProgress = false;
              _lineLookupInProgress = false;
              _lineLookupMessage = '线路解析失败：${_friendlyPlaybackError(error)}';
            });
          },
          onDone: () {
            if (identical(_lineLookupSubscription, subscription)) {
              _lineLookupSubscription = null;
            }
            if (!mounted ||
                serial != _lineLookupSerial ||
                episodeId != _episode.id) {
              return;
            }
            setState(() {
              _lineScanInProgress = false;
              _lineScanComplete = true;
              _lineLookupInProgress = false;
            });
          },
        );
    _lineLookupSubscription = subscription;
  }

  List<PlaybackLine> _preserveLoadedLineIfProbeDisagrees(
    List<PlaybackLine> lines,
  ) {
    final current = _line;
    if (current == null) return lines;
    final replacement = _lineById(lines, current.id);
    if (!shouldPreserveLoadedPlaybackLine(
      currentLine: current,
      replacementLine: replacement,
      loadedUrl: _loadedUrl,
      failedLineIds: _failedLineIds,
      playbackFailed: _playbackFailed,
    )) {
      return lines;
    }
    return <String, PlaybackLine>{
      for (final line in lines) line.id: line,
      current.id: current,
    }.values.toList(growable: false);
  }

  PlaybackLine? _preferredPlayableLine(List<PlaybackLine> lines) {
    if (lines.isEmpty) return null;
    final preferredProviderId = _preferredProviderId;
    if (preferredProviderId != null) {
      for (final line in lines) {
        if (line.providerId == preferredProviderId &&
            !_failedLineIds.contains(line.id)) {
          return line;
        }
      }
    }
    for (final line in lines) {
      if (!_failedLineIds.contains(line.id)) return line;
    }
    return null;
  }

  Future<void> _openLine(
    PlaybackLine requestedLine, {
    bool force = false,
  }) async {
    var line = requestedLine;
    if (!_isPlayableLine(line)) {
      await _player.stop();
      if (!mounted) return;
      setState(() {
        _loadedUrl = null;
        _loadingLine = false;
        _playbackFailed = true;
        _playerMessage = line.message ?? '这条线路没有返回可播放地址。';
      });
      return;
    }
    final requestedUrl = line.url!.trim();
    if (!force && _loadedUrl == requestedUrl && !_playbackFailed) return;
    final serial = ++_openLineSerial;
    _webLoadTimer?.cancel();
    _nativeFirstFrameTimer?.cancel();
    _revealPlayerControls();
    setState(() {
      _line = line;
      _loadingLine = true;
      _playbackFailed = false;
      _playerMessage = '正在确认这条线路可以真实播放…';
      _position = Duration.zero;
      _duration = Duration.zero;
      _buffer = Duration.zero;
    });
    line = await ref
        .read(animeControllerProvider.notifier)
        .verifyPlaybackLine(
          line,
          forceRefresh: true,
          cancellationToken: _lineLookupCancellationToken,
        );
    if (!mounted || serial != _openLineSerial) return;
    _lines = upsertPlaybackLine(_lines, line);
    if (!_isPlayableLine(line)) {
      _failedLineIds.add(line.id);
      setState(() {
        _line = line;
        _loadingLine = false;
        _playbackFailed = true;
        _playerMessage = '这条线路验证失败，正在自动寻找可播放线路…';
      });
      _startExpandedLineLookup(autoplay: true);
      unawaited(_tryAutoSwitchLine());
      return;
    }
    final url = line.url!.trim();
    setState(() {
      _line = line;
      _loadedUrl = url;
      _playerMessage = null;
    });
    if (supportsWebStreamPlayer && shouldUseWebStreamPlayer(url)) {
      if (!mounted || serial != _openLineSerial) return;
      unawaited(_player.stop());
      _webLoadTimer = Timer(const Duration(seconds: 7), () {
        if (!mounted ||
            serial != _openLineSerial ||
            _loadedUrl != url ||
            !webPlaybackStartupTimedOut(waitingForReady: _loadingLine)) {
          return;
        }
        if (webPlaybackShouldSwitchAtSoftTimeout(
          waitingForReady: _loadingLine,
          hasAlternative: _nextPlayableLine() != null,
        )) {
          _handleWebError(message: '当前线路 7 秒内未出画面，已尝试切换备用线路。');
          return;
        }
        _webLoadTimer = Timer(const Duration(seconds: 18), () {
          if (!mounted ||
              serial != _openLineSerial ||
              _loadedUrl != url ||
              !webPlaybackStartupTimedOut(waitingForReady: _loadingLine)) {
            return;
          }
          _handleWebError(message: '当前线路长时间未能起播，已尝试切换其他线路。');
        });
      });
      setState(() {
        _loadingLine = true;
        _playbackFailed = false;
        // This is the desired state passed to WebStreamPlayer. The browser
        // events below remain authoritative and will set it back to false if
        // autoplay is blocked or the user pauses playback.
        _playing = true;
        _playerMessage = null;
      });
      return;
    }
    try {
      if (supportsWebStreamPlayer) _webPlayerController.pause();
      const nativeSoftTimeout = Duration(seconds: 7);
      const nativeHardTimeout = Duration(seconds: 25);
      const nativeFallbackPollInterval = Duration(seconds: 1);
      late void Function(Duration delay, Duration elapsed)
      scheduleNativeStartupCheck;
      scheduleNativeStartupCheck = (delay, elapsed) {
        _nativeFirstFrameTimer = Timer(delay, () {
          if (!mounted ||
              serial != _openLineSerial ||
              _loadedUrl != url ||
              nativePlaybackHasFirstFrame(
                playing: _playing,
                position: _position,
              )) {
            return;
          }
          final hardTimedOut = elapsed >= nativeHardTimeout;
          final hasAlternative = _nextPlayableLine() != null;
          if (!hardTimedOut &&
              !nativePlaybackShouldSwitchAtSoftTimeout(
                position: _position,
                hasAlternative: hasAlternative,
              )) {
            final remaining = nativeHardTimeout - elapsed;
            final nextDelay = remaining < nativeFallbackPollInterval
                ? remaining
                : nativeFallbackPollInterval;
            scheduleNativeStartupCheck(nextDelay, elapsed + nextDelay);
            return;
          }
          _nativeFirstFrameTimer = null;
          _failedLineIds.add(line.id);
          setState(() {
            _loadingLine = false;
            _playbackFailed = true;
            _playerMessage = hardTimedOut
                ? '当前线路长时间未能起播，正在查找其他线路。'
                : '当前线路 7 秒内未出画面，已切换备用线路。';
          });
          _startExpandedLineLookup(autoplay: true);
          unawaited(_tryAutoSwitchLine());
        });
      };
      scheduleNativeStartupCheck(nativeSoftTimeout, nativeSoftTimeout);
      final media = line.headers.isEmpty
          ? Media(url)
          : Media(url, httpHeaders: line.headers);
      await _player.open(media, play: true);
      _refreshSuperResolutionShader();
      if (!mounted || serial != _openLineSerial) return;
      setState(() {
        _loadingLine = false;
        _playbackFailed = false;
        _playerMessage = null;
      });
    } catch (error) {
      if (!mounted || serial != _openLineSerial) return;
      _nativeFirstFrameTimer?.cancel();
      _failedLineIds.add(line.id);
      setState(() {
        _loadingLine = false;
        _playbackFailed = true;
        _playerMessage = _currentSettings.autoSwitchLine
            ? '当前线路不可播放，正在自动切换备用线路…'
            : '当前线路无法播放：${_friendlyPlaybackError(error)}';
      });
      unawaited(_tryAutoSwitchLine());
    }
  }

  void _handlePlayerError(Object error) {
    _nativeFirstFrameTimer?.cancel();
    if (!_isPlayableLine(_line)) {
      if (!mounted) return;
      setState(() {
        _loadingLine = false;
        _playbackFailed = false;
        _playerMessage = null;
      });
      return;
    }
    final current = _line;
    if (current != null) _failedLineIds.add(current.id);
    if (!mounted) return;
    setState(() {
      _loadingLine = false;
      _playbackFailed = true;
      _playerMessage = _currentSettings.autoSwitchLine
          ? '当前线路不可播放，正在自动切换备用线路…'
          : '当前线路无法播放：${_friendlyPlaybackError(error)}';
    });
    unawaited(_tryAutoSwitchLine());
  }

  Future<void> _tryAutoSwitchLine() async {
    if (!_currentSettings.autoSwitchLine) return;
    if (_autoSwitching) {
      _autoSwitchRetryPending = true;
      return;
    }
    _autoSwitching = true;
    try {
      final next = _nextPlayableLine();
      if (next == null) {
        if (!widget.request.offlineOnly && !_lineScanComplete) {
          _startExpandedLineLookup(autoplay: true);
          if (mounted) {
            setState(() {
              _playerMessage = '当前线路失败，正在后台搜索备用线路…';
            });
          }
        } else if (mounted) {
          setState(() {
            _playerMessage = _emptyLineMessage(
              _lines,
              subject: widget.request.subject,
            );
          });
        }
        return;
      }
      if (!mounted) return;
      final switchTarget = next;
      setState(() {
        _line = switchTarget;
        _playerMessage =
            '当前线路失败，已切换到 ${playbackLineProviderLabel(switchTarget)}。';
      });
      await _openLine(switchTarget, force: true);
    } finally {
      _autoSwitching = false;
      if (_autoSwitchRetryPending) {
        _autoSwitchRetryPending = false;
        scheduleMicrotask(_tryAutoSwitchLine);
      }
    }
  }

  PlaybackLine? _nextPlayableLine() {
    final currentId = _line?.id;
    for (final line in _availableLines(_lines)) {
      if (line.id == currentId || _failedLineIds.contains(line.id)) continue;
      return line;
    }
    return null;
  }

  Future<void> _togglePlayPause() async {
    _revealPlayerControls();
    if (!_isPlayableLine(_line)) {
      await _resolveLinesForCurrentEpisode();
      return;
    }
    if (_playbackFailed) {
      await _openLine(_line!, force: true);
      return;
    }
    if (_usesWebPlayer) {
      if (_playing) {
        _webPlayerController.pause();
      } else {
        _webPlayerController.play();
      }
      return;
    }
    await _player.playOrPause();
  }

  Future<void> _seekBy(Duration delta) {
    _revealPlayerControls();
    return _seekTo(_position + delta);
  }

  Future<void> _seekTo(Duration target) async {
    _revealPlayerControls();
    if (_duration <= Duration.zero) return;
    final max = _duration.inMilliseconds;
    final clamped = target.inMilliseconds.clamp(0, max);
    final position = Duration(milliseconds: clamped);
    if (_usesWebPlayer) {
      _webPlayerController.seek(position);
      setState(() => _position = position);
      return;
    }
    await _player.seek(position);
  }

  Future<void> _setVolume(double value) async {
    _revealPlayerControls();
    final clamped = value.clamp(0, 200).toDouble();
    setState(() {
      _muted = clamped <= 0;
      _volume = clamped;
      if (clamped > 0) _lastNonZeroVolume = clamped;
    });
    _appliedVolume = clamped;
    if (!_usesWebPlayer) await _player.setVolume(clamped);
  }

  Future<void> _selectSpeed(double value) async {
    final settings = ref.read(animeControllerProvider).value?.settings;
    if (settings == null || settings.speed == value) return;
    await ref
        .read(animeControllerProvider.notifier)
        .updateSettings(settings.copyWith(speed: value));
  }

  Future<void> _adjustVolume(double delta) async {
    _revealPlayerControls();
    final next = (_muted ? _lastNonZeroVolume : _volume) + delta;
    final clamped = next.clamp(0, 200).toDouble();
    if (clamped <= 0) {
      setState(() {
        _muted = true;
        _volume = 0;
      });
      _appliedVolume = 0;
      if (!_usesWebPlayer) await _player.setVolume(0);
      return;
    }
    setState(() {
      _muted = false;
      _volume = clamped;
      _lastNonZeroVolume = clamped;
    });
    final targetVolume = clamped;
    _appliedVolume = targetVolume;
    if (!_usesWebPlayer) await _player.setVolume(targetVolume);
  }

  Future<void> _toggleMute() async {
    _revealPlayerControls();
    final next = !_muted;
    final volume = next
        ? 0.0
        : (_lastNonZeroVolume > 0
              ? _lastNonZeroVolume
              : _volumeFromSettings(_currentSettings));
    setState(() {
      _muted = next;
      _volume = volume;
      if (!next && volume > 0) _lastNonZeroVolume = volume;
    });
    _appliedVolume = volume;
    if (!_usesWebPlayer) await _player.setVolume(volume);
  }

  Future<void> _reloadCurrentLine() async {
    _revealPlayerControls();
    _failedLineIds.remove(_line?.id);
    if (_isPlayableLine(_line)) {
      await _openLine(_line!, force: true);
    } else {
      await _resolveLinesForCurrentEpisode();
    }
  }

  void _selectEpisode(AnimeEpisode episode) {
    _revealPlayerControls();
    if (widget.request.offlineOnly) {
      if (episode.id != _episode.id) {
        _showPlayerToast('离线播放只能打开已经下载的当前集。');
      }
      setState(() => _episodePanel = false);
      return;
    }
    ++_danmakuLoadSerial;
    final playbackSerial = ++_openLineSerial;
    _danmakuRequestedEpisodeId = null;
    _webLoadTimer?.cancel();
    _nativeFirstFrameTimer?.cancel();
    _failedLineIds.clear();
    _autoSwitchRetryPending = false;
    setState(() {
      _episode = episode;
      _line = null;
      _lines = const [];
      _loadedUrl = null;
      _playerMessage = null;
      _lineLookupMessage = null;
      _lineScanInProgress = false;
      _lineScanComplete = false;
      _lineScanCompletedRules = 0;
      _lineScanTotalRules = 0;
      _playbackFailed = false;
      _remoteDanmaku = const [];
      _episodePanel = false;
    });
    unawaited(
      _stopAndResolveSelectedEpisode(
        episodeId: episode.id,
        playbackSerial: playbackSerial,
      ),
    );
  }

  Future<void> _stopAndResolveSelectedEpisode({
    required int episodeId,
    required int playbackSerial,
  }) async {
    try {
      await _player.stop();
    } catch (_) {
      // A stale native open may already have torn down the previous media.
    }
    if (!mounted ||
        playbackSerial != _openLineSerial ||
        _episode.id != episodeId) {
      return;
    }
    await _resolveLinesForCurrentEpisode();
  }

  void _selectLine(PlaybackLine line) {
    _revealPlayerControls();
    _failedLineIds.remove(line.id);
    _preferredProviderId = line.providerId;
    setState(() {
      _line = line;
      _linePanel = false;
      _playerMessage = null;
      _playbackFailed = false;
    });
    unawaited(_openLine(line, force: true));
  }

  Future<void> _playNextEpisode() async {
    if (widget.request.offlineOnly) return;
    final index = widget.request.episodes.indexWhere(
      (episode) => episode.id == _episode.id,
    );
    if (index < 0 || index >= widget.request.episodes.length - 1) return;
    _selectEpisode(widget.request.episodes[index + 1]);
  }

  Future<void> _setFullscreen(bool enabled) async {
    _revealPlayerControls();
    if (_fullscreen == enabled) return;
    setState(() {
      _fullscreen = enabled;
      if (enabled) {
        _episodePanel = false;
        _linePanel = false;
        _subtitlePanel = false;
        _danmakuPanel = false;
        _settingsPanel = false;
      }
    });
    if (enabled) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      await _restoreSystemUi();
    }
  }

  Future<void> _restoreSystemUi() async {
    await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  Future<void> _handleBack() async {
    if (_hasOpenPanel) {
      _closePanels();
      return;
    }
    if (_fullscreen) {
      await _setFullscreen(false);
      return;
    }
    if (_leaving) return;
    _leaving = true;
    _lineLookupCancellationToken?.cancel();
    _expandedLookupDelayTimer?.cancel();
    await _lineLookupSubscription?.cancel();
    await _restoreSystemUi();
    await _player.stop();
    if (mounted) safeNavigateBack(context);
  }

  bool get _hasOpenPanel =>
      _episodePanel ||
      _linePanel ||
      _subtitlePanel ||
      _danmakuPanel ||
      _settingsPanel;

  void _closePanels() {
    if (!_hasOpenPanel) return;
    setState(() {
      _episodePanel = false;
      _linePanel = false;
      _subtitlePanel = false;
      _danmakuPanel = false;
      _settingsPanel = false;
    });
    _revealPlayerControls();
  }

  void _toggleEpisodePanel() {
    _revealPlayerControls();
    setState(() {
      _episodePanel = !_episodePanel;
      _linePanel = false;
      _subtitlePanel = false;
      _danmakuPanel = false;
      _settingsPanel = false;
    });
  }

  void _toggleLinePanel() {
    _revealPlayerControls();
    final opening = !_linePanel;
    setState(() {
      _linePanel = opening;
      _episodePanel = false;
      _subtitlePanel = false;
      _danmakuPanel = false;
      _settingsPanel = false;
    });
    if (opening) _startExpandedLineLookup();
  }

  void _toggleSubtitlePanel() {
    _revealPlayerControls();
    setState(() {
      _subtitlePanel = !_subtitlePanel;
      _episodePanel = false;
      _linePanel = false;
      _danmakuPanel = false;
      _settingsPanel = false;
    });
  }

  void _toggleDanmakuPanel() {
    _revealPlayerControls();
    final opening = !_danmakuPanel;
    setState(() {
      _danmakuPanel = opening;
      _episodePanel = false;
      _linePanel = false;
      _subtitlePanel = false;
      _settingsPanel = false;
    });
    // Danmaku is intentionally opt-in during playback. Fetching and parsing a
    // full XML timeline competes with rule lookup and video startup, so only a
    // deliberate visit to the danmaku panel starts this work.
    if (opening) unawaited(_loadDanmakuForCurrentEpisode());
  }

  void _toggleSettingsPanel() {
    _revealPlayerControls();
    setState(() {
      _settingsPanel = !_settingsPanel;
      _episodePanel = false;
      _linePanel = false;
      _subtitlePanel = false;
      _danmakuPanel = false;
    });
  }

  Future<void> _captureScreenshot() async {
    _revealPlayerControls();
    try {
      final bytes = await _player.screenshot(format: 'image/png');
      if (bytes == null || bytes.isEmpty) {
        _showPlayerToast('当前平台或视频线路不支持截图');
        return;
      }
      final safeTitle = widget.request.subject.title.replaceAll(
        RegExp(r'[\\/:*?"<>|]'),
        '_',
      );
      final path = await FilePicker.platform.saveFile(
        dialogTitle: '保存视频截图',
        fileName:
            '${safeTitle}_EP${_episode.number}_${DateTime.now().millisecondsSinceEpoch}.png',
        bytes: bytes,
      );
      if (path != null || kIsWeb) _showPlayerToast('截图已保存');
    } catch (error) {
      _showPlayerToast('截图失败：${_friendlyPlaybackError(error)}');
    }
  }

  void _toggleTheaterMode() {
    _revealPlayerControls();
    setState(() => _theaterMode = !_theaterMode);
  }

  Future<void> _showExternalPlayback() async {
    final url = _line?.url?.trim() ?? '';
    if (url.isEmpty) {
      _showPlayerToast('当前没有可分享的播放地址');
      return;
    }
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('投屏与外部播放'),
        content: const Text(
          '已复制当前播放地址。可以粘贴到支持 DLNA、AirPlay 或 Chromecast 的播放器中。应用内原生投屏仍取决于设备平台能力。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _selectSubtitle(SubtitleCandidate candidate) async {
    final url = candidate.downloadUrl?.trim() ?? '';
    if (!candidate.available || url.isEmpty) {
      _showPlayerToast(candidate.message ?? '该字幕暂不可用');
      return;
    }
    try {
      await _player.setSubtitleTrack(
        SubtitleTrack.uri(
          url,
          title: candidate.title,
          language: candidate.language,
        ),
      );
      if (!mounted) return;
      setState(() {
        _selectedSubtitle = candidate;
        _subtitlePanel = false;
      });
      _showPlayerToast('已加载字幕：${candidate.title}');
    } catch (error) {
      _showPlayerToast('字幕加载失败：${_friendlyPlaybackError(error)}');
    }
  }

  Future<void> _disableSubtitle() async {
    await _player.setSubtitleTrack(SubtitleTrack.no());
    if (!mounted) return;
    setState(() {
      _selectedSubtitle = null;
      _subtitlePanel = false;
    });
    _showPlayerToast('字幕已关闭');
  }

  Future<void> _loadDanmakuForCurrentEpisode() async {
    final episode = _episode;
    if (_danmakuRequestedEpisodeId == episode.id) return;
    _danmakuRequestedEpisodeId = episode.id;
    final serial = ++_danmakuLoadSerial;
    try {
      final timeline = await ref
          .read(animeControllerProvider.notifier)
          .danmakuTimelineForEpisode(widget.request.subject, episode);
      if (!mounted ||
          serial != _danmakuLoadSerial ||
          episode.id != _episode.id) {
        return;
      }
      setState(() => _remoteDanmaku = timeline.comments);
    } catch (_) {
      if (!mounted ||
          serial != _danmakuLoadSerial ||
          episode.id != _episode.id) {
        return;
      }
      _danmakuRequestedEpisodeId = null;
      setState(() => _remoteDanmaku = const []);
    }
  }

  void _sendLocalDanmaku(String text, {required DanmakuSettings settings}) {
    final value = text.trim();
    if (value.isEmpty) return;
    if (!settings.enabled) {
      _showPlayerToast('请先在弹幕设置中启用弹幕');
      return;
    }
    if (settings.blockKeywords.any(value.contains)) {
      _showPlayerToast('内容命中了本地屏蔽词');
      return;
    }
    final entry = _LocalDanmakuEntry(
      id: DateTime.now().microsecondsSinceEpoch,
      text: value,
    );
    setState(() {
      _localDanmaku.add(entry);
      _danmakuInput.clear();
    });
    late final Timer timer;
    timer = Timer(const Duration(seconds: 9), () {
      _localDanmakuTimers.remove(timer);
      if (!mounted) return;
      setState(() => _localDanmaku.removeWhere((item) => item.id == entry.id));
    });
    _localDanmakuTimers.add(timer);
  }

  void _handleWebReady() {
    if (!mounted) return;
    _webLoadTimer?.cancel();
    _webLoadTimer = null;
    setState(() {
      _loadingLine = false;
      _playbackFailed = false;
      _playerMessage = null;
    });
  }

  void _handleWebError({String? message}) {
    if (!mounted) return;
    _webLoadTimer?.cancel();
    final current = _line;
    if (current != null) _failedLineIds.add(current.id);
    setState(() {
      _loadingLine = false;
      _playbackFailed = true;
      _playing = false;
      _playerMessage = _currentSettings.autoSwitchLine
          ? '当前线路不可播放，正在自动切换备用线路…'
          : message ?? '网页播放器无法打开当前地址，可能被源站跨域或防盗链限制。';
    });
    _startExpandedLineLookup(autoplay: true);
    unawaited(_tryAutoSwitchLine());
  }

  void _handleWebPosition(Duration value) {
    if (!mounted) return;
    setState(() => _position = value);
  }

  void _handleWebDuration(Duration value) {
    if (!mounted || value.isNegative) return;
    setState(() => _duration = value);
  }

  void _handleWebPlaying(bool value) {
    if (!mounted ||
        _playing == value ||
        !webPlaybackShouldApplyPlayingUpdate(
          loading: _loadingLine,
          playing: value,
        )) {
      return;
    }
    setState(() => _playing = value);
    if (value) {
      _webLoadTimer?.cancel();
      _webLoadTimer = null;
      if (_line != null) _preferredProviderId = _line!.providerId;
      _scheduleExpandedLineLookup();
    }
  }

  void _showPlayerToast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }
}

class _LocalDanmakuEntry {
  const _LocalDanmakuEntry({required this.id, required this.text});

  final int id;
  final String text;
}

class _LocalDanmakuOverlay extends StatelessWidget {
  const _LocalDanmakuOverlay({required this.entries, required this.settings});

  final List<_LocalDanmakuEntry> entries;
  final DanmakuSettings settings;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final visible = entries.reversed.take(12).toList().reversed.toList();
          return ClipRect(
            child: Stack(
              children: [
                for (final entry in visible)
                  _LocalDanmakuBullet(
                    key: ValueKey(entry.id),
                    entry: entry,
                    lane: entry.id.remainder(6),
                    width: constraints.maxWidth,
                    settings: settings,
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _LocalDanmakuBullet extends StatefulWidget {
  const _LocalDanmakuBullet({
    super.key,
    required this.entry,
    required this.lane,
    required this.width,
    required this.settings,
  });

  final _LocalDanmakuEntry entry;
  final int lane;
  final double width;
  final DanmakuSettings settings;

  @override
  State<_LocalDanmakuBullet> createState() => _LocalDanmakuBulletState();
}

class _LocalDanmakuBulletState extends State<_LocalDanmakuBullet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(seconds: 7 + widget.entry.text.length.clamp(0, 4)),
    )..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fontSize = widget.settings.fontSize.clamp(12, 30).toDouble();
    final estimatedWidth = math.max(120.0, widget.entry.text.length * fontSize);
    return Positioned(
      top: 68 + widget.lane * (fontSize + 12),
      left: 0,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final x =
              widget.width -
              (widget.width + estimatedWidth) * _controller.value;
          return Transform.translate(offset: Offset(x, 0), child: child);
        },
        child: Text(
          widget.entry.text,
          maxLines: 1,
          style: TextStyle(
            color: Colors.white.withValues(alpha: widget.settings.opacity),
            fontSize: fontSize,
            fontWeight: FontWeight.w700,
            shadows: const [
              Shadow(color: Colors.black, blurRadius: 2, offset: Offset(1, 1)),
              Shadow(
                color: Colors.black,
                blurRadius: 2,
                offset: Offset(-1, -1),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class MissingPlayerPage extends StatelessWidget {
  const MissingPlayerPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: AppColors.theaterBg,
      body: Center(child: Text('没有可播放内容')),
    );
  }
}

class _PlayerCanvas extends StatelessWidget {
  const _PlayerCanvas({
    required this.controller,
    required this.webPlayerController,
    required this.subject,
    required this.episodes,
    required this.episode,
    required this.line,
    required this.settings,
    required this.superResolutionProfile,
    required this.services,
    required this.danmaku,
    required this.remoteDanmaku,
    required this.localDanmaku,
    required this.theaterMode,
    required this.position,
    required this.duration,
    required this.buffer,
    required this.volume,
    required this.playing,
    required this.buffering,
    required this.loadingLine,
    required this.lineLookupInProgress,
    required this.playbackFailed,
    required this.fullscreen,
    required this.muted,
    required this.playerMessage,
    required this.onBack,
    required this.onReload,
    required this.onScreenshot,
    required this.onTheaterMode,
    required this.onCast,
    required this.onPlayPause,
    required this.onRewind,
    required this.onForward,
    required this.onSeek,
    required this.onMute,
    required this.onVolumeChanged,
    required this.onSpeedSelected,
    required this.onFullscreen,
    required this.onEpisodePanel,
    required this.onEpisodeSelected,
    required this.onLinePanel,
    required this.onSubtitlePanel,
    required this.onDanmakuPanel,
    required this.danmakuInput,
    required this.onSendDanmaku,
    required this.onWebReady,
    required this.onWebError,
    required this.onWebPosition,
    required this.onWebDuration,
    required this.onWebPlaying,
    required this.onSettingsPanel,
    required this.controlsVisible,
    required this.autoHideChrome,
    required this.onUserInteraction,
    required this.onChromeHotZoneChanged,
  });

  final VideoController controller;
  final WebStreamPlayerController webPlayerController;
  final AnimeSubject subject;
  final List<AnimeEpisode> episodes;
  final AnimeEpisode episode;
  final PlaybackLine? line;
  final PlaybackSettings settings;
  final Anime4KProfile? superResolutionProfile;
  final ExternalServiceSettings services;
  final DanmakuSettings danmaku;
  final List<DanmakuComment> remoteDanmaku;
  final List<_LocalDanmakuEntry> localDanmaku;
  final bool theaterMode;
  final Duration position;
  final Duration duration;
  final Duration buffer;
  final double volume;
  final bool playing;
  final bool buffering;
  final bool loadingLine;
  final bool lineLookupInProgress;
  final bool playbackFailed;
  final bool fullscreen;
  final bool muted;
  final String? playerMessage;
  final bool controlsVisible;
  final bool autoHideChrome;
  final Future<void> Function() onBack;
  final Future<void> Function() onReload;
  final Future<void> Function() onScreenshot;
  final VoidCallback onTheaterMode;
  final Future<void> Function() onCast;
  final Future<void> Function() onPlayPause;
  final Future<void> Function() onRewind;
  final Future<void> Function() onForward;
  final Future<void> Function(Duration) onSeek;
  final Future<void> Function() onMute;
  final ValueChanged<double> onVolumeChanged;
  final ValueChanged<double> onSpeedSelected;
  final Future<void> Function() onFullscreen;
  final VoidCallback onEpisodePanel;
  final ValueChanged<AnimeEpisode> onEpisodeSelected;
  final VoidCallback onLinePanel;
  final VoidCallback onSubtitlePanel;
  final VoidCallback onDanmakuPanel;
  final TextEditingController danmakuInput;
  final ValueChanged<String> onSendDanmaku;
  final VoidCallback onWebReady;
  final VoidCallback onWebError;
  final ValueChanged<Duration> onWebPosition;
  final ValueChanged<Duration> onWebDuration;
  final ValueChanged<bool> onWebPlaying;
  final VoidCallback onSettingsPanel;
  final VoidCallback onUserInteraction;
  final ValueChanged<bool> onChromeHotZoneChanged;

  @override
  Widget build(BuildContext context) {
    final chromeVisible = controlsVisible || !autoHideChrome;
    final compact = MediaQuery.sizeOf(context).width < 640;
    final horizontalInset = compact ? 14.0 : (fullscreen ? 28.0 : 18.0);
    final topInset = fullscreen ? 10.0 : 12.0;
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: AppColors.bg),
        Padding(
          padding: EdgeInsets.fromLTRB(
            fullscreen ? 0 : 18,
            fullscreen ? 0 : 14,
            fullscreen ? 0 : 18,
            fullscreen ? 0 : 18,
          ),
          child: Row(
            children: [
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: fullscreen
                        ? BorderRadius.zero
                        : BorderRadius.circular(8),
                    border: fullscreen
                        ? null
                        : Border.all(color: AppColors.borderBright),
                  ),
                  child: ClipRRect(
                    borderRadius: fullscreen
                        ? BorderRadius.zero
                        : BorderRadius.circular(8),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final hotZoneHeight = math.min(
                          constraints.maxHeight * 0.28,
                          compact ? 132.0 : 116.0,
                        );
                        final bottomHotZoneStart =
                            constraints.maxHeight - hotZoneHeight;

                        void updateHotZone(Offset localPosition) {
                          final inHotZone =
                              localPosition.dy <= hotZoneHeight ||
                              localPosition.dy >= bottomHotZoneStart;
                          onChromeHotZoneChanged(inHotZone);
                        }

                        return MouseRegion(
                          hitTestBehavior: HitTestBehavior.translucent,
                          onEnter: (event) =>
                              updateHotZone(event.localPosition),
                          onHover: (event) =>
                              updateHotZone(event.localPosition),
                          onExit: (_) => onChromeHotZoneChanged(false),
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTapDown: (_) => onUserInteraction(),
                            onPanDown: (_) => onUserInteraction(),
                            onTap: () {
                              onUserInteraction();
                              if (chromeVisible) onPlayPause();
                            },
                            onDoubleTap: () {
                              onUserInteraction();
                              onFullscreen();
                            },
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                _StreamVideoSurface(
                                  controller: controller,
                                  webPlayerController: webPlayerController,
                                  line: line,
                                  settings: settings,
                                  superResolutionActive:
                                      superResolutionProfile != null,
                                  playing: playing,
                                  volume: muted ? 0 : volume / 100,
                                  position: position,
                                  loading: loadingLine || lineLookupInProgress,
                                  failed: playbackFailed,
                                  message: playerMessage,
                                  onWebReady: onWebReady,
                                  onWebError: onWebError,
                                  onWebPosition: onWebPosition,
                                  onWebDuration: onWebDuration,
                                  onWebPlaying: onWebPlaying,
                                  poster: PosterArt(
                                    coverUrl: subject.bannerUrl,
                                    fallbackCoverUrl: subject.coverUrl,
                                    title: subject.title,
                                  ),
                                ),
                                if (danmaku.enabled && remoteDanmaku.isNotEmpty)
                                  RemoteDanmakuOverlay(
                                    comments: remoteDanmaku,
                                    position: position,
                                    settings: danmaku,
                                  ),
                                if (danmaku.enabled && localDanmaku.isNotEmpty)
                                  _LocalDanmakuOverlay(
                                    entries: localDanmaku,
                                    settings: danmaku,
                                  ),
                                AnimatedOpacity(
                                  opacity: chromeVisible ? 1 : 0,
                                  duration: const Duration(milliseconds: 180),
                                  child: IgnorePointer(
                                    ignoring: !chromeVisible,
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        Positioned(
                                          left: horizontalInset,
                                          right: horizontalInset,
                                          top: topInset,
                                          child: _PlayerChromePanel(
                                            child: _PlayerHeader(
                                              subject: subject,
                                              episode: episode,
                                              line: line,
                                              onBack: onBack,
                                              onReload: onReload,
                                              onScreenshot: onScreenshot,
                                              onTheaterMode: onTheaterMode,
                                              theaterMode: theaterMode,
                                              onCast: onCast,
                                              onSettings: onSettingsPanel,
                                            ),
                                          ),
                                        ),
                                        Positioned(
                                          right: horizontalInset,
                                          top: compact ? 62 : 72,
                                          child: Wrap(
                                            spacing: 8,
                                            children: [
                                              if (superResolutionProfile !=
                                                  null)
                                                SmallBadge(
                                                  label:
                                                      'SR · ${superResolutionProfile!.label}',
                                                  active: true,
                                                ),
                                            ],
                                          ),
                                        ),
                                        _PlayerBottomBar(
                                          line: line,
                                          settings: settings,
                                          services: services,
                                          danmaku: danmaku,
                                          position: position,
                                          duration: duration,
                                          buffer: buffer,
                                          volume: volume,
                                          playing: playing,
                                          buffering: buffering,
                                          loadingLine:
                                              loadingLine ||
                                              lineLookupInProgress,
                                          fullscreen: fullscreen,
                                          muted: muted,
                                          onPlayPause: onPlayPause,
                                          onRewind: onRewind,
                                          onForward: onForward,
                                          onSeek: onSeek,
                                          onMute: onMute,
                                          onVolumeChanged: onVolumeChanged,
                                          onSpeedSelected: onSpeedSelected,
                                          onFullscreen: onFullscreen,
                                          onSubtitlePanel: onSubtitlePanel,
                                          onDanmakuPanel: onDanmakuPanel,
                                          danmakuInput: danmakuInput,
                                          onSendDanmaku: onSendDanmaku,
                                          onEpisodePanel: onEpisodePanel,
                                          onLinePanel: onLinePanel,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StreamVideoSurface extends StatelessWidget {
  const _StreamVideoSurface({
    required this.controller,
    required this.webPlayerController,
    required this.line,
    required this.settings,
    required this.superResolutionActive,
    required this.playing,
    required this.volume,
    required this.position,
    required this.loading,
    required this.failed,
    required this.message,
    required this.onWebReady,
    required this.onWebError,
    required this.onWebPosition,
    required this.onWebDuration,
    required this.onWebPlaying,
    required this.poster,
  });

  final VideoController controller;
  final WebStreamPlayerController webPlayerController;
  final PlaybackLine? line;
  final PlaybackSettings settings;
  final bool superResolutionActive;
  final bool playing;
  final double volume;
  final Duration position;
  final bool loading;
  final bool failed;
  final String? message;
  final VoidCallback onWebReady;
  final VoidCallback onWebError;
  final ValueChanged<Duration> onWebPosition;
  final ValueChanged<Duration> onWebDuration;
  final ValueChanged<bool> onWebPlaying;
  final Widget poster;

  @override
  Widget build(BuildContext context) {
    final hasStream =
        line?.available == true && (line?.url?.trim().isNotEmpty ?? false);
    final shouldShowVideo = hasStream && !failed;
    final url = line?.url?.trim() ?? '';
    final useWebPlayer = shouldUseWebStreamPlayer(url);
    final Widget video;
    if (!shouldShowVideo) {
      video = const SizedBox.shrink();
    } else if (useWebPlayer) {
      video = WebStreamPlayer(
        url: url,
        controller: webPlayerController,
        playing: playing,
        volume: volume.clamp(0.0, 1.0),
        position: position,
        rate: settings.speed,
        headers: line?.headers ?? const {},
        forceHls: _isHlsLine(line),
        onReady: onWebReady,
        onError: onWebError,
        onPosition: onWebPosition,
        onDuration: onWebDuration,
        onPlaying: onWebPlaying,
      );
    } else {
      video = Video(
        controller: controller,
        controls: null,
        fit: _fitForVideoScale(settings.videoScale),
        filterQuality: superResolutionActive
            ? FilterQuality.high
            : FilterQuality.low,
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        if (shouldShowVideo) video else poster,
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                const Color(0x331B1A18),
                const Color(0x111B1A18),
                const Color(0xDD1B1A18),
              ],
            ),
          ),
        ),
        if (!hasStream || failed || loading)
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: AppColors.bg.withValues(alpha: 0.48),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white24),
                  ),
                  child: SizedBox(
                    width: 82,
                    height: 82,
                    child: loading
                        ? const Padding(
                            padding: EdgeInsets.all(22),
                            child: CircularProgressIndicator(strokeWidth: 3),
                          )
                        : Icon(
                            failed
                                ? Icons.error_outline_rounded
                                : Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 48,
                          ),
                  ),
                ),
                if ((message ?? '').trim().isNotEmpty) ...[
                  const SizedBox(height: 14),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 460),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: AppColors.bg.withValues(alpha: 0.68),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        child: Text(
                          message!,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: Colors.white70),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _PlayerChromePanel extends StatelessWidget {
  const _PlayerChromePanel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.bg.withValues(alpha: 0.74),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: child,
      ),
    );
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

class _PlayerHeader extends StatelessWidget {
  const _PlayerHeader({
    required this.subject,
    required this.episode,
    required this.line,
    required this.onBack,
    required this.onReload,
    required this.onScreenshot,
    required this.onTheaterMode,
    required this.theaterMode,
    required this.onCast,
    required this.onSettings,
  });

  final AnimeSubject subject;
  final AnimeEpisode episode;
  final PlaybackLine? line;
  final Future<void> Function() onBack;
  final Future<void> Function() onReload;
  final Future<void> Function() onScreenshot;
  final VoidCallback onTheaterMode;
  final bool theaterMode;
  final Future<void> Function() onCast;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 640;
    if (compact) {
      return SizedBox(
        height: 44,
        child: Row(
          children: [
            IconButton(onPressed: onBack, icon: const Icon(Icons.arrow_back)),
            Expanded(
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  SmallBadge(label: '第${episode.number}集', active: true),
                  SmallBadge(
                    label: line == null
                        ? '找线路'
                        : playbackLineProviderLabel(line!),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: '刷新线路',
              onPressed: onReload,
              icon: const Icon(Icons.refresh_rounded),
            ),
            IconButton(
              tooltip: '截图',
              onPressed: onScreenshot,
              icon: const Icon(Icons.camera_alt_outlined),
            ),
            IconButton(
              tooltip: '播放设置',
              onPressed: onSettings,
              icon: const Icon(Icons.tune_rounded),
            ),
          ],
        ),
      );
    }
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          IconButton(onPressed: onBack, icon: const Icon(Icons.arrow_back)),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    subject.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: AppColors.text,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                SmallBadge(label: '第${episode.number}集'),
                const SizedBox(width: 8),
                if (playbackQualityChipLabel(line) != null)
                  SmallBadge(label: playbackQualityChipLabel(line)!),
              ],
            ),
          ),
          _HeaderIcon(Icons.refresh, tooltip: '刷新', onPressed: onReload),
          _HeaderIcon(
            Icons.camera_alt_outlined,
            tooltip: '保存截图',
            onPressed: onScreenshot,
          ),
          _HeaderIcon(
            theaterMode ? Icons.close_fullscreen : Icons.crop_16_9_rounded,
            tooltip: theaterMode ? '退出影院模式' : '影院模式',
            onPressed: onTheaterMode,
          ),
          _HeaderIcon(Icons.cast, tooltip: '投屏 / 外部播放', onPressed: onCast),
          IconButton(
            tooltip: '播放设置',
            onPressed: onSettings,
            icon: const Icon(Icons.tune),
          ),
        ],
      ),
    );
  }
}

class _PlayerBottomBar extends StatelessWidget {
  const _PlayerBottomBar({
    required this.line,
    required this.settings,
    required this.services,
    required this.danmaku,
    required this.position,
    required this.duration,
    required this.buffer,
    required this.volume,
    required this.playing,
    required this.buffering,
    required this.loadingLine,
    required this.fullscreen,
    required this.muted,
    required this.onPlayPause,
    required this.onRewind,
    required this.onForward,
    required this.onSeek,
    required this.onMute,
    required this.onVolumeChanged,
    required this.onSpeedSelected,
    required this.onFullscreen,
    required this.onSubtitlePanel,
    required this.onDanmakuPanel,
    required this.danmakuInput,
    required this.onSendDanmaku,
    required this.onEpisodePanel,
    required this.onLinePanel,
  });

  final PlaybackLine? line;
  final PlaybackSettings settings;
  final ExternalServiceSettings services;
  final DanmakuSettings danmaku;
  final Duration position;
  final Duration duration;
  final Duration buffer;
  final double volume;
  final bool playing;
  final bool buffering;
  final bool loadingLine;
  final bool fullscreen;
  final bool muted;
  final Future<void> Function() onPlayPause;
  final Future<void> Function() onRewind;
  final Future<void> Function() onForward;
  final Future<void> Function(Duration) onSeek;
  final Future<void> Function() onMute;
  final ValueChanged<double> onVolumeChanged;
  final ValueChanged<double> onSpeedSelected;
  final Future<void> Function() onFullscreen;
  final VoidCallback onSubtitlePanel;
  final VoidCallback onDanmakuPanel;
  final TextEditingController danmakuInput;
  final ValueChanged<String> onSendDanmaku;
  final VoidCallback onEpisodePanel;
  final VoidCallback onLinePanel;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 640;
    final progress = _progress(position, duration);
    final bufferProgress = _progress(
      buffer > position ? buffer : position,
      duration,
    );
    final canSeek = duration > Duration.zero;
    return Positioned(
      left: compact ? 14 : (fullscreen ? 28 : 18),
      right: compact ? 14 : (fullscreen ? 28 : 18),
      bottom: compact ? 14 : (fullscreen ? 18 : 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (compact)
            Text(
              '${_durationLabel(position)} / ${_durationLabel(duration)}',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: AppColors.theaterInk,
                fontWeight: FontWeight.w700,
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: _BufferedSeekBar(
              progress: progress,
              buffered: bufferProgress,
              enabled: canSeek,
              duration: duration,
              onSeek: (value) => onSeek(
                Duration(
                  milliseconds: (duration.inMilliseconds * value).round(),
                ),
              ),
            ),
          ),
          SizedBox(
            height: compact ? 104 : 52,
            child: compact
                ? _MobilePlayerControls(
                    line: line,
                    settings: settings,
                    playing: playing,
                    buffering: buffering,
                    loadingLine: loadingLine,
                    fullscreen: fullscreen,
                    muted: muted,
                    onPlayPause: onPlayPause,
                    onRewind: onRewind,
                    onForward: onForward,
                    onMute: onMute,
                    onFullscreen: onFullscreen,
                    onEpisodePanel: onEpisodePanel,
                    onLinePanel: onLinePanel,
                  )
                : Row(
                    children: [
                      _ControlIconButton(
                        icon: playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        tooltip: playing ? '暂停' : '播放',
                        size: 32,
                        busy: loadingLine || buffering,
                        onPressed: onPlayPause,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        '${_durationLabel(position)} / ${_durationLabel(duration)}',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AppColors.theaterMuted,
                          fontWeight: FontWeight.w600,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      const SizedBox(width: 18),
                      Tooltip(
                        message:
                            services.dandanplayDanmakuEnabled ||
                                services.bilibiliDanmakuEnabled
                            ? '弹幕源与显示设置'
                            : '弹幕源已关闭',
                        child: IconButton(
                          onPressed: onDanmakuPanel,
                          padding: EdgeInsets.zero,
                          icon: Icon(
                            Icons.comment_outlined,
                            color:
                                services.dandanplayDanmakuEnabled ||
                                    services.bilibiliDanmakuEnabled
                                ? Colors.white
                                : Colors.white38,
                          ),
                          iconSize: 23,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 520),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: AppColors.theaterBg.withValues(
                                  alpha: 0.72,
                                ),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Colors.white12),
                              ),
                              child: SizedBox(
                                height: 36,
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: TextField(
                                        controller: danmakuInput,
                                        enabled: danmaku.enabled,
                                        textInputAction: TextInputAction.send,
                                        onSubmitted: onSendDanmaku,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 13,
                                        ),
                                        decoration: InputDecoration(
                                          isDense: true,
                                          filled: false,
                                          border: InputBorder.none,
                                          enabledBorder: InputBorder.none,
                                          focusedBorder: InputBorder.none,
                                          hintText: danmaku.enabled
                                              ? '发条弹幕吧…'
                                              : '弹幕已关闭',
                                          contentPadding:
                                              const EdgeInsets.symmetric(
                                                horizontal: 14,
                                                vertical: 9,
                                              ),
                                        ),
                                      ),
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.only(right: 4),
                                      child: TextButton(
                                        onPressed: danmaku.enabled
                                            ? () => onSendDanmaku(
                                                danmakuInput.text,
                                              )
                                            : null,
                                        style: TextButton.styleFrom(
                                          minimumSize: const Size(0, 30),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 12,
                                          ),
                                          foregroundColor: AppColors.primary2,
                                        ),
                                        child: const Text('发送'),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      TextButton.icon(
                        onPressed: onEpisodePanel,
                        icon: const Icon(
                          Icons.video_library_outlined,
                          size: 18,
                          color: Colors.white,
                        ),
                        label: const Text(
                          '选集',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                      const SizedBox(width: 6),
                      _SpeedMenuButton(
                        current: settings.speed,
                        onSelected: onSpeedSelected,
                      ),
                      const SizedBox(width: 10),
                      Tooltip(
                        message: services.bilibiliSubtitleEnabled
                            ? 'Bilibili 字幕 · ${services.subtitleLanguage}'
                            : 'Bilibili 字幕已关闭',
                        child: IconButton(
                          onPressed: onSubtitlePanel,
                          padding: EdgeInsets.zero,
                          icon: Icon(
                            Icons.subtitles_outlined,
                            color: services.bilibiliSubtitleEnabled
                                ? Colors.white
                                : Colors.white38,
                          ),
                          iconSize: 23,
                        ),
                      ),
                      const SizedBox(width: 6),
                      TextButton(
                        onPressed: onLinePanel,
                        child: Text(
                          line == null
                              ? '线路'
                              : playbackLineProviderLabel(line!),
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                      const SizedBox(width: 6),
                      _VolumeButton(
                        volume: volume,
                        muted: muted,
                        onMute: onMute,
                        onVolumeChanged: onVolumeChanged,
                      ),
                      const SizedBox(width: 6),
                      _ControlIconButton(
                        icon: fullscreen
                            ? Icons.fullscreen_exit_rounded
                            : Icons.fullscreen_rounded,
                        tooltip: fullscreen ? '退出全屏' : '全屏',
                        onPressed: onFullscreen,
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _SpeedMenuButton extends StatelessWidget {
  const _SpeedMenuButton({required this.current, required this.onSelected});

  static const _speeds = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];

  final double current;
  final ValueChanged<double> onSelected;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      alignmentOffset: const Offset(0, -8),
      style: const MenuStyle(alignment: Alignment.topLeft),
      menuChildren: [
        for (final speed in _speeds.reversed)
          MenuItemButton(
            onPressed: () => onSelected(speed),
            trailingIcon: (speed - current).abs() < 0.001
                ? Icon(
                    Icons.check_rounded,
                    size: 16,
                    color: Theme.of(context).colorScheme.primary,
                  )
                : null,
            child: Text(_speedLabel(speed)),
          ),
      ],
      builder: (context, controller, child) {
        return Tooltip(
          message: '播放速度',
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: () =>
                controller.isOpen ? controller.close() : controller.open(),
            child: SmallBadge(label: _speedLabel(current)),
          ),
        );
      },
    );
  }
}

class _VolumeButton extends StatefulWidget {
  const _VolumeButton({
    required this.volume,
    required this.muted,
    required this.onMute,
    required this.onVolumeChanged,
  });

  final double volume;
  final bool muted;
  final Future<void> Function() onMute;
  final ValueChanged<double> onVolumeChanged;

  @override
  State<_VolumeButton> createState() => _VolumeButtonState();
}

class _VolumeButtonState extends State<_VolumeButton> {
  final MenuController _menu = MenuController();
  Timer? _closeTimer;

  void _scheduleClose() {
    _closeTimer?.cancel();
    _closeTimer = Timer(const Duration(milliseconds: 160), () {
      if (mounted && _menu.isOpen) _menu.close();
    });
  }

  void _cancelClose() => _closeTimer?.cancel();

  @override
  void dispose() {
    _closeTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final effective = widget.muted ? 0.0 : widget.volume;
    return MenuAnchor(
      controller: _menu,
      alignmentOffset: const Offset(-6, -8),
      menuChildren: [
        MouseRegion(
          onEnter: (_) => _cancelClose(),
          onExit: (_) => _scheduleClose(),
          child: SizedBox(
            height: 148,
            width: 44,
            child: Column(
              children: [
                const SizedBox(height: 6),
                Text(
                  '${effective.round()}',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                Expanded(
                  child: RotatedBox(
                    quarterTurns: -1,
                    child: Slider(
                      value: effective.clamp(0, 200),
                      max: 200,
                      onChanged: widget.onVolumeChanged,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
              ],
            ),
          ),
        ),
      ],
      builder: (context, controller, child) {
        return MouseRegion(
          onEnter: (_) {
            _cancelClose();
            if (!controller.isOpen) controller.open();
          },
          onExit: (_) => _scheduleClose(),
          child: Tooltip(
            message: widget.muted
                ? '已静音，点击恢复'
                : '音量 ${widget.volume.round()}%，点击静音',
            child: IconButton(
              onPressed: widget.onMute,
              padding: EdgeInsets.zero,
              icon: Icon(
                widget.muted || widget.volume <= 0
                    ? Icons.volume_off_rounded
                    : Icons.volume_up_rounded,
                color: Colors.white,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MobilePlayerControls extends StatelessWidget {
  const _MobilePlayerControls({
    required this.line,
    required this.settings,
    required this.playing,
    required this.buffering,
    required this.loadingLine,
    required this.fullscreen,
    required this.muted,
    required this.onPlayPause,
    required this.onRewind,
    required this.onForward,
    required this.onMute,
    required this.onFullscreen,
    required this.onEpisodePanel,
    required this.onLinePanel,
  });

  final PlaybackLine? line;
  final PlaybackSettings settings;
  final bool playing;
  final bool buffering;
  final bool loadingLine;
  final bool fullscreen;
  final bool muted;
  final Future<void> Function() onPlayPause;
  final Future<void> Function() onRewind;
  final Future<void> Function() onForward;
  final Future<void> Function() onMute;
  final Future<void> Function() onFullscreen;
  final VoidCallback onEpisodePanel;
  final VoidCallback onLinePanel;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _ControlIconButton(
              icon: Icons.replay_10_rounded,
              tooltip: '快退 ${settings.rewindSeconds} 秒',
              onPressed: onRewind,
            ),
            _ControlIconButton(
              icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              tooltip: playing ? '暂停' : '播放',
              size: 38,
              busy: loadingLine || buffering,
              onPressed: onPlayPause,
            ),
            _ControlIconButton(
              icon: Icons.forward_10_rounded,
              tooltip: '快进 ${settings.forwardSeconds} 秒',
              onPressed: onForward,
            ),
            _ControlIconButton(
              icon: muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
              tooltip: muted ? '取消静音' : '静音',
              onPressed: onMute,
            ),
            _ControlIconButton(
              icon: fullscreen
                  ? Icons.fullscreen_exit_rounded
                  : Icons.fullscreen_rounded,
              tooltip: fullscreen ? '退出全屏' : '全屏',
              onPressed: onFullscreen,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            SmallBadge(label: _speedLabel(settings.speed)),
            const SizedBox(width: 8),
            Expanded(
              child: TextButton.icon(
                onPressed: onLinePanel,
                icon: const Icon(Icons.alt_route_rounded, size: 18),
                label: Text(
                  line == null ? '线路' : playbackLineProviderLabel(line!),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextButton.icon(
                onPressed: onEpisodePanel,
                icon: const Icon(Icons.video_library_outlined, size: 18),
                label: const Text('选集'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _BufferedSeekBar extends StatefulWidget {
  const _BufferedSeekBar({
    required this.progress,
    required this.buffered,
    required this.enabled,
    required this.duration,
    required this.onSeek,
  });

  final double progress;
  final double buffered;
  final bool enabled;
  final Duration duration;
  final ValueChanged<double> onSeek;

  @override
  State<_BufferedSeekBar> createState() => _BufferedSeekBarState();
}

class _BufferedSeekBarState extends State<_BufferedSeekBar> {
  double? _hoverX;

  double get progress => widget.progress;
  double get buffered => widget.buffered;
  bool get enabled => widget.enabled;
  ValueChanged<double> get onSeek => widget.onSeek;

  void _updateHover(double dx, double width) {
    if (!enabled || widget.duration <= Duration.zero) return;
    setState(() => _hoverX = dx.clamp(0.0, width));
  }

  @override
  Widget build(BuildContext context) {
    final played = progress.clamp(0.0, 1.0);
    final cached = buffered.clamp(played, 1.0);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final thumbX = width * played;
        final hoverX = _hoverX;
        final hoverLabel = hoverX == null || width <= 0
            ? null
            : _durationLabel(
                Duration(
                  milliseconds:
                      (widget.duration.inMilliseconds * (hoverX / width))
                          .round(),
                ),
              );
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: enabled
              ? (details) => _seekFromDx(details.localPosition.dx, width)
              : null,
          onHorizontalDragUpdate: enabled
              ? (details) {
                  _updateHover(details.localPosition.dx, width);
                  _seekFromDx(details.localPosition.dx, width);
                }
              : null,
          onHorizontalDragEnd: (_) => setState(() => _hoverX = null),
          child: MouseRegion(
            cursor: enabled
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            onHover: (event) => _updateHover(event.localPosition.dx, width),
            onExit: (_) => setState(() => _hoverX = null),
            child: SizedBox(
              height: 28,
              child: Stack(
                alignment: Alignment.centerLeft,
                clipBehavior: Clip.none,
                children: [
                  if (hoverLabel != null)
                    Positioned(
                      left: (hoverX! - 26).clamp(0.0, width - 52),
                      top: -26,
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: AppColors.theaterBg.withValues(alpha: 0.92),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: Colors.white12),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            child: Text(
                              hoverLabel,
                              style: const TextStyle(
                                color: AppColors.theaterInk,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _BufferedSeekBarPainter(
                        played: played,
                        buffered: cached,
                        enabled: enabled,
                      ),
                    ),
                  ),
                  Positioned(
                    left: (thumbX - 6).clamp(0.0, width - 12),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      width: enabled ? 12 : 0,
                      height: enabled ? 12 : 0,
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.primary.withValues(alpha: 0.42),
                            blurRadius: 12,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _seekFromDx(double dx, double width) {
    if (width <= 0) return;
    onSeek((dx / width).clamp(0.0, 1.0));
  }
}

class _BufferedSeekBarPainter extends CustomPainter {
  const _BufferedSeekBarPainter({
    required this.played,
    required this.buffered,
    required this.enabled,
  });

  final double played;
  final double buffered;
  final bool enabled;

  @override
  void paint(Canvas canvas, Size size) {
    final centerY = size.height / 2;
    final trackRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, centerY - 2.5, size.width, 5),
      const Radius.circular(999),
    );
    final background = Paint()
      ..color = Colors.white.withValues(alpha: enabled ? 0.18 : 0.10);
    final cache = Paint()
      ..color = Colors.white.withValues(alpha: enabled ? 0.38 : 0.20);
    final active = Paint()
      ..shader = const LinearGradient(
        colors: [AppColors.primary, AppColors.primary2],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));

    canvas.drawRRect(trackRect, background);
    if (buffered > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0, centerY - 2.5, size.width * buffered, 5),
          const Radius.circular(999),
        ),
        cache,
      );
    }
    if (played > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0, centerY - 2.5, size.width * played, 5),
          const Radius.circular(999),
        ),
        active,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BufferedSeekBarPainter oldDelegate) {
    return oldDelegate.played != played ||
        oldDelegate.buffered != buffered ||
        oldDelegate.enabled != enabled;
  }
}

class _ControlIconButton extends StatelessWidget {
  const _ControlIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.size = 28,
    this.busy = false,
  });

  final IconData icon;
  final String tooltip;
  final Future<void> Function() onPressed;
  final double size;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        icon: busy
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(icon, color: Colors.white, size: size),
      ),
    );
  }
}

String _speedLabel(double value) {
  if (value == 1) return '1.0x';
  var text = value.toStringAsFixed(2);
  text = text.replaceFirst(RegExp(r'0$'), '');
  text = text.replaceFirst(RegExp(r'\.0$'), '');
  return '${text}x';
}

double _progress(Duration value, Duration total) {
  if (total <= Duration.zero) return 0;
  return (value.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
}

String _durationLabel(Duration duration) {
  final totalSeconds = duration.inSeconds;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  final secondText = seconds.toString().padLeft(2, '0');
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:$secondText';
  }
  return '$minutes:$secondText';
}

bool _isPlayableLine(PlaybackLine? line) {
  return line?.available == true && (line?.url?.trim().isNotEmpty ?? false);
}

PlaybackLine? _lineById(List<PlaybackLine> lines, String id) {
  for (final line in lines) {
    if (line.id == id) return line;
  }
  return null;
}

bool _usesProgressiveRuleLookup(AnimeSubject subject) {
  final source = subject.source.toLowerCase();
  return source != 'direct' &&
      !source.startsWith('m3u-channel:') &&
      !source.startsWith('peertube:') &&
      !source.startsWith('archive:') &&
      !source.startsWith('commons:');
}

String _progressiveLookupMessage(PlaybackLineLookupUpdate update) {
  final progress = update.totalRules <= 0
      ? ''
      : ' ${update.completedRules}/${update.totalRules}';
  return update.phase == PlaybackLineLookupPhase.verification
      ? '正在后台测速并补全线路信息$progress…'
      : '正在并行检索全部线路$progress…';
}

bool _isHlsLine(PlaybackLine? line) {
  if (line == null) return false;
  final format = line.format.trim().toLowerCase();
  if (format.contains('hls') ||
      format.contains('m3u8') ||
      format.contains('mpegurl')) {
    return true;
  }
  final url = line.url?.trim().toLowerCase() ?? '';
  return RegExp(r'\.m3u8(?:$|[?#])').hasMatch(url) ||
      url.contains('type=m3u8') ||
      url.contains('format=m3u8');
}

List<PlaybackLine> _availableLines(List<PlaybackLine> lines) {
  return playablePlaybackLinesInSourceOrder(lines);
}

String _emptyLineMessage(
  List<PlaybackLine> lines, {
  required AnimeSubject subject,
}) {
  final source = subject.source.toLowerCase();
  final isMetadataOnly =
      source.startsWith('cinemeta:') ||
      source.startsWith('tvmaze') ||
      source == 'wikidata';
  if (lines.isEmpty) {
    if (source.startsWith('m3u-channel:')) {
      return '这个直播频道暂时无法读取。请检查外部源是否启用，或稍后重试。';
    }
    if (source.startsWith('archive:') ||
        source.startsWith('peertube:') ||
        source.startsWith('commons:')) {
      return '这个开放媒体暂时没有返回可播放文件，可能正在转码、已下架或源站暂时不可用。';
    }
    if (isMetadataOnly) {
      return '这部作品目前仅有影视资料，聚合后端暂未找到可播放线路。';
    }
    return '已安装规则里没有适合当前内容的可解析线路，可以到规则仓库安装同类型规则。';
  }
  if (isMetadataOnly) {
    return '聚合后端已检查 ${lines.length} 条候选线路，但暂时没有可播放地址。';
  }
  final unavailableCount = lines.where((line) => !line.available).length;
  return _unavailableLinesMessage(lines, count: unavailableCount);
}

String _unavailableLinesMessage(List<PlaybackLine> lines, {int? count}) {
  final unavailableLines = lines.where((line) => !line.available).toList();
  final total = count ?? unavailableLines.length;
  final backendCount = unavailableLines
      .where((line) => line.providerId.startsWith('zeluna:'))
      .length;
  if (backendCount > 0) {
    return '聚合后端找到了 $backendCount 条候选线路，但客户端未能读取视频清单或分片。请检查代理/CDN 连接后重试。';
  }
  final deadCount = unavailableLines
      .where((line) => (line.message ?? '').contains('视频 CDN'))
      .length;
  if (deadCount > 0) {
    return '找到 $total 条线路，但其中 $deadCount 条视频 CDN 已失效、拒绝访问或连接超时，暂时不会当作可播放线路。';
  }
  return '找到 $total 条规则，但它们需要验证码、WebView 或对应执行器，暂时无法直接播放。';
}

String _friendlyPlaybackError(Object error) {
  final text = error.toString();
  if (text.contains('TimeoutException')) return '连接超时';
  if (text.contains('SocketException')) return '网络不可用或源站无法访问';
  if (text.contains('HTTP 403') || text.contains('403')) return '源站拒绝访问';
  if (text.contains('HTTP 404') || text.contains('404')) return '视频地址已失效';
  if (text.contains('FormatException')) return '视频地址格式不正确';
  if (text.contains('Failed to open')) return '播放器无法打开这个地址';
  if (text.contains('Empty src') || text.contains('MEDIA_ELEMENT_ERROR')) {
    return '当前没有可播放地址';
  }
  return text.length > 90 ? '${text.substring(0, 90)}...' : text;
}

class _EpisodePanel extends StatelessWidget {
  const _EpisodePanel({
    required this.subject,
    required this.episodes,
    required this.selected,
    required this.onSelected,
  });

  final AnimeSubject subject;
  final List<AnimeEpisode> episodes;
  final AnimeEpisode selected;
  final ValueChanged<AnimeEpisode> onSelected;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 110),
      itemCount: episodes.length,
      separatorBuilder: (context, index) => const SizedBox(height: 14),
      itemBuilder: (context, index) {
        final episode = episodes[index];
        final active = episode.id == selected.id;
        return InkWell(
          onTap: () => onSelected(episode),
          child: Row(
            children: [
              SizedBox(
                width: 186,
                height: 96,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(7),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      PosterArt(
                        coverUrl: episode.thumbnailUrl ?? subject.coverUrl,
                        title: episode.displayTitle,
                      ),
                      const Positioned(
                        left: 64,
                        bottom: 6,
                        child: _PanelPill('有资源'),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      episode.displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: active
                            ? Theme.of(context).colorScheme.primary
                            : Colors.white,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Text(
                      episode.airdate ?? '播出日期待补',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
                    ),
                    Text(
                      episode.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _LinePanel extends StatelessWidget {
  const _LinePanel({
    required this.selected,
    required this.lines,
    required this.failedLineIds,
    required this.scanning,
    required this.completedRules,
    required this.totalRules,
    required this.onSelected,
  });

  final PlaybackLine? selected;
  final List<PlaybackLine> lines;
  final Set<String> failedLineIds;
  final bool scanning;
  final int completedRules;
  final int totalRules;
  final ValueChanged<PlaybackLine> onSelected;

  @override
  Widget build(BuildContext context) {
    return _LinePanelBody(
      lines: lines,
      selected: selected,
      failedLineIds: failedLineIds,
      scanning: scanning,
      completedRules: completedRules,
      totalRules: totalRules,
      onSelected: onSelected,
    );
  }
}

class _LinePanelBody extends StatelessWidget {
  const _LinePanelBody({
    required this.lines,
    required this.selected,
    required this.failedLineIds,
    required this.scanning,
    required this.completedRules,
    required this.totalRules,
    required this.onSelected,
  });

  final List<PlaybackLine> lines;
  final PlaybackLine? selected;
  final Set<String> failedLineIds;
  final bool scanning;
  final int completedRules;
  final int totalRules;
  final ValueChanged<PlaybackLine> onSelected;

  @override
  Widget build(BuildContext context) {
    final displayLines = selectablePlaybackLinesForDisplay(
      lines,
      failedLineIds: failedLineIds,
    );
    final excludedCount = lines.length - displayLines.length;
    final progress = totalRules <= 0 ? '' : '（$completedRules/$totalRules）';
    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 110),
      children: [
        const _LineModeBar(),
        const SizedBox(height: 14),
        if (scanning || excludedCount > 0 || displayLines.isNotEmpty) ...[
          _PanelInlineStatus(
            loading: scanning,
            text: scanning
                ? '正在后台验证线路$progress · 已确认 ${displayLines.length} 条可播'
                : '已确认 ${displayLines.length} 条可播${excludedCount > 0 ? ' · 自动跳过 $excludedCount 条失效或不兼容线路' : ''}',
          ),
          const SizedBox(height: 12),
        ],
        if (displayLines.isEmpty && scanning)
          const Center(child: CircularProgressIndicator())
        else if (displayLines.isEmpty)
          _PanelEmpty(
            title: '当前没有可播放线路',
            message: lines.isEmpty
                ? '正在保留并尝试已启用规则，目前还没有找到真实可播地址。'
                : _unavailableLinesMessage(lines),
          )
        else
          DecoratedBox(
            decoration: BoxDecoration(
              color: AppColors.panelHigh,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Column(
                children: [
                  for (var i = 0; i < displayLines.length; i++) ...[
                    _LineTile(
                      key: ValueKey(displayLines[i].id),
                      index: i,
                      line: displayLines[i],
                      selected: selected?.id == displayLines[i].id,
                      onTap: displayLines[i].available
                          ? () => onSelected(displayLines[i])
                          : null,
                    ),
                    if (i != displayLines.length - 1)
                      const Divider(height: 1, color: Color(0xFF35322E)),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _SubtitlePanel extends ConsumerWidget {
  const _SubtitlePanel({
    required this.subject,
    required this.episode,
    required this.selected,
    required this.onSelected,
    required this.onDisabled,
  });

  final AnimeSubject subject;
  final AnimeEpisode episode;
  final SubtitleCandidate? selected;
  final ValueChanged<SubtitleCandidate> onSelected;
  final VoidCallback onDisabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder<List<SubtitleCandidate>>(
      future: ref
          .read(animeControllerProvider.notifier)
          .subtitlesForEpisode(subject, episode),
      builder: (context, snapshot) {
        final items = snapshot.data ?? const <SubtitleCandidate>[];
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return _PanelEmpty(
            title: '字幕读取失败',
            message: _friendlyPlaybackError(snapshot.error!),
          );
        }
        if (items.isEmpty) {
          return const _PanelEmpty(
            title: '没有匹配字幕',
            message: 'B 站公开接口没有返回当前集字幕，可能该条目没有官方字幕或需要登录权限。',
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 110),
          itemCount: items.length + 1,
          separatorBuilder: (context, index) => const SizedBox(height: 10),
          itemBuilder: (context, index) {
            if (index == 0) {
              return _PanelRow(
                title: '关闭字幕',
                subtitle: '不显示外部字幕轨道',
                trailing: selected == null ? '当前' : '',
                selected: selected == null,
                onTap: onDisabled,
              );
            }
            final item = items[index - 1];
            return _PanelRow(
              title: item.title,
              subtitle:
                  '${item.provider} · ${item.language} · 下载 ${item.downloadCount}',
              trailing: selected?.downloadUrl == item.downloadUrl
                  ? '当前'
                  : item.available
                  ? '加载'
                  : item.message ?? '待配置',
              selected: selected?.downloadUrl == item.downloadUrl,
              onTap: item.available ? () => onSelected(item) : null,
            );
          },
        );
      },
    );
  }
}

class _DanmakuPanel extends ConsumerStatefulWidget {
  const _DanmakuPanel({required this.subject, required this.episode});

  final AnimeSubject subject;
  final AnimeEpisode episode;

  @override
  ConsumerState<_DanmakuPanel> createState() => _DanmakuPanelState();
}

class _DanmakuPanelState extends ConsumerState<_DanmakuPanel> {
  late Future<List<DanmakuMatch>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void didUpdateWidget(covariant _DanmakuPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.subject.id != widget.subject.id ||
        oldWidget.subject.source != widget.subject.source ||
        oldWidget.episode.id != widget.episode.id) {
      _future = _load();
    }
  }

  Future<List<DanmakuMatch>> _load() {
    return ref
        .read(animeControllerProvider.notifier)
        .danmakuForEpisode(widget.subject, widget.episode);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<DanmakuMatch>>(
      future: _future,
      builder: (context, snapshot) {
        final items = snapshot.data ?? const <DanmakuMatch>[];
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return _PanelEmpty(
            title: '弹幕源读取失败',
            message: _friendlyPlaybackError(snapshot.error!),
          );
        }
        if (items.isEmpty) {
          return const _PanelEmpty(
            title: '没有匹配弹幕',
            message: 'B 站公开接口没有返回当前集弹幕，可能没有匹配到番剧或该集弹幕不可公开访问。',
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 110),
          itemCount: items.length,
          separatorBuilder: (context, index) => const SizedBox(height: 10),
          itemBuilder: (context, index) {
            final item = items[index];
            return _PanelRow(
              title: item.title.isEmpty ? widget.subject.title : item.title,
              subtitle:
                  '${item.provider} · ${item.episodeTitle.isEmpty ? widget.episode.displayTitle : item.episodeTitle}',
              trailing: item.available
                  ? '${item.commentCount} 条'
                  : item.message ?? '待配置',
            );
          },
        );
      },
    );
  }
}

class _PanelRow extends StatelessWidget {
  const _PanelRow({
    required this.title,
    required this.subtitle,
    required this.trailing,
    this.selected = false,
    this.onTap,
  });

  final String title;
  final String subtitle;
  final String trailing;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? Theme.of(context).colorScheme.secondaryContainer
          : Theme.of(context).colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurface,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                trailing,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: Colors.orangeAccent),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PanelEmpty extends StatelessWidget {
  const _PanelEmpty({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.inbox_outlined,
              color: Theme.of(context).colorScheme.primary,
              size: 38,
            ),
            const SizedBox(height: 12),
            Text(
              title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.white60),
            ),
          ],
        ),
      ),
    );
  }
}

class _PanelInlineStatus extends StatelessWidget {
  const _PanelInlineStatus({required this.text, this.loading = true});

  final String text;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.panelHigh,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF35322E)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            if (loading)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              const Icon(
                Icons.verified_rounded,
                size: 18,
                color: Colors.greenAccent,
              ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: Colors.white60),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LineModeBar extends StatelessWidget {
  const _LineModeBar();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.panelHigh,
        borderRadius: BorderRadius.circular(8),
      ),
      child: SizedBox(
        height: 50,
        child: Row(
          children: const [
            Expanded(child: _ModeItem(Icons.folder, '本地视频')),
            VerticalDivider(width: 1, color: Color(0xFF3B3833)),
            Expanded(child: _ModeItem(Icons.link, '网络视频')),
            VerticalDivider(width: 1, color: Color(0xFF3B3833)),
            Expanded(child: _ModeItem(Icons.search, '搜索视频')),
          ],
        ),
      ),
    );
  }
}

class _ModeItem extends StatelessWidget {
  const _ModeItem(this.icon, this.label);

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white, size: 20),
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LineTile extends StatelessWidget {
  const _LineTile({
    super.key,
    required this.index,
    required this.line,
    required this.selected,
    required this.onTap,
  });

  final int index;
  final PlaybackLine line;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final latency = line.available
        ? playbackLineLatencyLabel(line)
        : _playbackLineFailureLabel(line);
    final metadata = playbackLineMediaLabel(line);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    '线路${index + 1} · ${playbackLineProviderLabel(line)} · ${line.title}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: selected
                          ? Theme.of(context).colorScheme.primary
                          : Colors.white,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  latency,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: line.available
                        ? Colors.greenAccent
                        : Colors.redAccent,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              line.url ?? line.message ?? '后续从你自己的播放源接口返回 url',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: Colors.white54),
            ),
            if (line.available) ...[
              const SizedBox(height: 5),
              Text(
                metadata,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: Colors.white70),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _playbackLineFailureLabel(PlaybackLine line) {
  final message = (line.message ?? '').toLowerCase();
  if (message.contains('403') || message.contains('拒绝')) return '403';
  if (message.contains('404') || message.contains('失效')) return '404';
  if (message.contains('超时') || message.contains('timeout')) return '超时';
  if (message.contains('验证码')) return '需验证';
  if (message.contains('执行器')) return '不支持';
  return '不可用';
}

class _SideSheet extends StatelessWidget {
  const _SideSheet({
    required this.title,
    required this.child,
    required this.onClose,
  });

  final String title;
  final Widget child;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return Align(
      alignment: Alignment.centerRight,
      child: Material(
        color: AppColors.bg,
        child: SizedBox(
          width: width < 700 ? width * 0.86 : 430,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 6, 8),
                child: Row(
                  children: [
                    if (title.isNotEmpty)
                      Expanded(
                        child: Text(
                          title,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(
                                color: AppColors.text,
                                fontWeight: FontWeight.w800,
                              ),
                        ),
                      )
                    else
                      const Spacer(),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: onClose,
                      icon: const Icon(
                        Icons.close_rounded,
                        color: AppColors.text,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(child: child),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeaderIcon extends StatelessWidget {
  const _HeaderIcon(this.icon, {required this.tooltip, this.onPressed});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon, color: AppColors.text),
      ),
    );
  }
}

class _PanelPill extends StatelessWidget {
  const _PanelPill(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.58),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        child: Text(text, style: const TextStyle(color: Colors.white)),
      ),
    );
  }
}
