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
import '../domain/anime_models.dart';
import '../settings/settings_page.dart';
import '../shared_ui/app_chrome.dart';
import '../shared_ui/app_navigation.dart';
import '../shared_ui/poster_card.dart';
import 'anime4k_shader_manager.dart';
import 'danmaku_overlay.dart';
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
  var _playbackFailed = false;
  var _fullscreen = false;
  var _muted = false;
  var _autoSwitching = false;
  var _leaving = false;
  var _lineLookupSerial = 0;
  var _openLineSerial = 0;
  var _superResolutionApplySerial = 0;
  PlaybackSettings _currentSettings = const PlaybackSettings();
  Timer? _controlsHideTimer;
  Timer? _webLoadTimer;
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

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);
    _webPlayerController = WebStreamPlayerController();
    _shortcutFocusNode = FocusNode(debugLabel: 'player-shortcuts');
    _episode = widget.request.episode;
    _line = widget.request.initialLine;
    _lines = widget.request.initialLine == null
        ? const []
        : [widget.request.initialLine!];
    _bindPlayer();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _requestPlayerFocus();
      _applyPlaybackSettings(_currentSettings);
      if (!widget.request.offlineOnly) {
        unawaited(_loadDanmakuForCurrentEpisode());
      }
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
            backgroundColor: AppColors.bg,
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
                          subject: widget.request.subject,
                          episode: _episode,
                          selected: _line,
                          initialLines: _lines,
                          offlineOnly: widget.request.offlineOnly,
                          onLinesLoaded: _mergeLinesFromPanel,
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
    if (_loadingLine) return '正在连接 ${_line?.providerName ?? '播放源'}...';
    if (_playbackFailed) return _playerMessage ?? '当前线路无法播放，请切换线路。';
    if (!_isPlayableLine(_line)) {
      return _lineLookupMessage ?? '当前集还没有选中可播放线路。';
    }
    if (_buffering) return '缓冲中...';
    return _playerMessage ?? _superResolutionStatusMessage;
  }

  bool get _usesWebPlayer {
    final url = _line?.url?.trim() ?? '';
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
          if (!mounted) return;
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
          if (mounted) setState(() => _position = value);
        }),
      )
      ..add(
        _player.stream.duration.listen((value) {
          if (mounted) setState(() => _duration = value);
        }),
      )
      ..add(
        _player.stream.buffer.listen((value) {
          if (mounted) setState(() => _buffer = value);
        }),
      )
      ..add(
        _player.stream.videoParams.listen((value) {
          if (mounted) _refreshSuperResolutionShader();
        }),
      )
      ..add(
        _player.stream.buffering.listen((value) {
          if (mounted) setState(() => _buffering = value);
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
          if (completed && _currentSettings.autoNext) _playNextEpisode();
        }),
      )
      ..add(
        _player.stream.error.listen((error) {
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
    setState(() {
      _lineLookupInProgress = true;
      _lineLookupMessage = null;
      _playerMessage = null;
      _playbackFailed = false;
    });
    try {
      final lines = await ref
          .read(animeControllerProvider.notifier)
          .linesForEpisode(widget.request.subject, _episode);
      if (!mounted || serial != _lineLookupSerial) return;
      final available = _availableLines(lines);
      PlaybackLine? nextLine = _line;
      if (!_isPlayableLine(nextLine) && available.isNotEmpty) {
        nextLine = available.first;
      }
      setState(() {
        _lines = lines;
        _line = nextLine;
        _lineLookupInProgress = false;
        _lineLookupMessage = available.isEmpty
            ? '快速查找暂未发现可用线路，正在后台继续扫描…'
            : null;
      });
      unawaited(
        _continueExpandedLineLookup(
          serial: serial,
          autoplay: autoplay,
          initialLines: lines,
          delay: available.isEmpty
              ? Duration.zero
              : const Duration(milliseconds: 700),
        ),
      );
      if (autoplay && _isPlayableLine(nextLine)) {
        await _openLine(nextLine!, force: true);
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

  Future<void> _continueExpandedLineLookup({
    required int serial,
    required bool autoplay,
    required List<PlaybackLine> initialLines,
    Duration delay = Duration.zero,
  }) async {
    try {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      if (!mounted || serial != _lineLookupSerial) return;
      final expandedLines = await ref
          .read(animeControllerProvider.notifier)
          .linesForEpisodeMode(
            widget.request.subject,
            _episode,
            expandAll: true,
          );
      if (!mounted || serial != _lineLookupSerial) return;
      final lines = _mergeLineLists(initialLines, expandedLines);
      final available = _availableLines(lines);
      final currentLine = _line;
      final currentFailed =
          _playbackFailed ||
          (currentLine != null && _failedLineIds.contains(currentLine.id));
      PlaybackLine? nextLine = currentLine;
      if (!currentFailed && currentLine != null) {
        for (final candidate in available) {
          if (candidate.id == currentLine.id) {
            nextLine = candidate;
            break;
          }
        }
      }
      if (currentFailed || !_isPlayableLine(nextLine)) {
        nextLine = null;
        for (final candidate in available) {
          if (_failedLineIds.contains(candidate.id)) continue;
          nextLine = candidate;
          break;
        }
      }
      final shouldOpen =
          autoplay &&
          _isPlayableLine(nextLine) &&
          (currentFailed || !_isPlayableLine(currentLine));
      setState(() {
        _lines = lines;
        _line = nextLine;
        _lineLookupMessage = available.isEmpty
            ? _emptyLineMessage(lines, subject: widget.request.subject)
            : null;
      });
      if (shouldOpen) {
        await _openLine(nextLine!, force: true);
      }
    } catch (error) {
      if (!mounted || serial != _lineLookupSerial) return;
      setState(() {
        _lineLookupMessage = '线路解析失败：${_friendlyPlaybackError(error)}';
      });
    }
  }

  Future<void> _openLine(PlaybackLine line, {bool force = false}) async {
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
    final url = line.url!.trim();
    if (!force && _loadedUrl == url && !_playbackFailed) return;
    final serial = ++_openLineSerial;
    _revealPlayerControls();
    setState(() {
      _line = line;
      _loadedUrl = url;
      _loadingLine = true;
      _playbackFailed = false;
      _playerMessage = null;
      _position = Duration.zero;
      _duration = Duration.zero;
      _buffer = Duration.zero;
    });
    if (supportsWebStreamPlayer && shouldUseWebStreamPlayer(url)) {
      if (!mounted || serial != _openLineSerial) return;
      _webLoadTimer?.cancel();
      _webLoadTimer = Timer(const Duration(seconds: 14), () {
        if (!mounted ||
            serial != _openLineSerial ||
            _loadedUrl != url ||
            !_loadingLine) {
          return;
        }
        _handleWebError(message: '网页播放器连接超时，已尝试切换其他线路。');
      });
      setState(() {
        _loadingLine = true;
        _playbackFailed = false;
        _playing = false;
        _playerMessage = null;
      });
      return;
    }
    try {
      await _player.stop();
      await _player.setRate(
        _currentSettings.speed <= 0 ? 1.0 : _currentSettings.speed,
      );
      await _player.setVolume(
        _muted ? 0 : _volumeFromSettings(_currentSettings),
      );
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
      _failedLineIds.add(line.id);
      setState(() {
        _loadingLine = false;
        _playbackFailed = true;
        _playerMessage = '当前线路无法播放：${_friendlyPlaybackError(error)}';
      });
      unawaited(_tryAutoSwitchLine());
    }
  }

  void _handlePlayerError(Object error) {
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
      _playerMessage = '当前线路无法播放：${_friendlyPlaybackError(error)}';
    });
    unawaited(_tryAutoSwitchLine());
  }

  Future<void> _tryAutoSwitchLine() async {
    if (_autoSwitching || !_currentSettings.autoSwitchLine) return;
    _autoSwitching = true;
    try {
      var next = _nextPlayableLine();
      if (next == null && _lines.isEmpty) {
        await _resolveLinesForCurrentEpisode(autoplay: false);
        next = _nextPlayableLine();
      }
      if (next == null || !mounted) return;
      final switchTarget = next;
      setState(() {
        _line = switchTarget;
        _playerMessage = '当前线路失败，已切换到 ${switchTarget.providerName}。';
      });
      await _openLine(switchTarget, force: true);
    } finally {
      _autoSwitching = false;
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
    setState(() {
      _episode = episode;
      _line = null;
      _lines = const [];
      _loadedUrl = null;
      _playerMessage = null;
      _lineLookupMessage = null;
      _playbackFailed = false;
      _remoteDanmaku = const [];
      _episodePanel = false;
    });
    unawaited(_player.stop());
    unawaited(_loadDanmakuForCurrentEpisode());
    unawaited(_resolveLinesForCurrentEpisode());
  }

  void _selectLine(PlaybackLine line) {
    _revealPlayerControls();
    _failedLineIds.remove(line.id);
    setState(() {
      _line = line;
      _linePanel = false;
      _playerMessage = null;
      _playbackFailed = false;
    });
    unawaited(_openLine(line, force: true));
  }

  void _mergeLinesFromPanel(List<PlaybackLine> lines) {
    if (!mounted || lines.isEmpty) return;
    final merged = <String, PlaybackLine>{
      for (final line in _lines) line.id: line,
      for (final line in lines) line.id: line,
    };
    setState(() {
      _lines = merged.values.toList(growable: false);
      if (!_isPlayableLine(_line)) {
        final available = _availableLines(_lines);
        if (available.isNotEmpty) _line = available.first;
      }
    });
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
    setState(() {
      _linePanel = !_linePanel;
      _episodePanel = false;
      _subtitlePanel = false;
      _danmakuPanel = false;
      _settingsPanel = false;
    });
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
    setState(() {
      _danmakuPanel = !_danmakuPanel;
      _episodePanel = false;
      _linePanel = false;
      _subtitlePanel = false;
      _settingsPanel = false;
    });
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
    final serial = ++_danmakuLoadSerial;
    final episode = _episode;
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
    Timer(const Duration(seconds: 9), () {
      if (!mounted) return;
      setState(() => _localDanmaku.removeWhere((item) => item.id == entry.id));
    });
  }

  void _handleWebReady() {
    if (!mounted) return;
    _webLoadTimer?.cancel();
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
      _playerMessage = message ?? '网页播放器无法打开当前地址，可能被源站跨域或防盗链限制。';
    });
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
    if (!mounted || _playing == value) return;
    setState(() => _playing = value);
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
      backgroundColor: AppColors.bg,
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
    final showSideList =
        MediaQuery.sizeOf(context).width >= 1120 && !theaterMode;
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
                                    coverUrl:
                                        subject.bannerUrl ?? subject.coverUrl,
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
                                              SmallBadge(
                                                label: line?.quality ?? '高清',
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
              if (showSideList && !fullscreen) ...[
                const SizedBox(width: 18),
                SizedBox(
                  width: 340,
                  child: _PlayerEpisodeRail(
                    subject: subject,
                    episodes: episodes,
                    selected: episode,
                    onEpisodePanel: onEpisodePanel,
                    onEpisodeSelected: onEpisodeSelected,
                    onLinePanel: onLinePanel,
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
                const Color(0x33060912),
                const Color(0x11060912),
                const Color(0xDD060912),
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
                  SmallBadge(label: line?.providerName ?? '找线路'),
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
                SmallBadge(label: line?.quality ?? '观看中'),
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
          Text(
            '${_durationLabel(position)} / ${_durationLabel(duration)}',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: AppColors.text,
              fontWeight: FontWeight.w700,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: _BufferedSeekBar(
              progress: progress,
              buffered: bufferProgress,
              enabled: canSeek,
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
                        icon: Icons.replay_10_rounded,
                        tooltip: '快退 ${settings.rewindSeconds} 秒',
                        onPressed: onRewind,
                      ),
                      const SizedBox(width: 10),
                      _ControlIconButton(
                        icon: playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        tooltip: playing ? '暂停' : '播放',
                        size: 34,
                        busy: loadingLine || buffering,
                        onPressed: onPlayPause,
                      ),
                      const SizedBox(width: 10),
                      _ControlIconButton(
                        icon: Icons.forward_10_rounded,
                        tooltip: '快进 ${settings.forwardSeconds} 秒',
                        onPressed: onForward,
                      ),
                      const SizedBox(width: 16),
                      SmallBadge(label: _speedLabel(settings.speed)),
                      const SizedBox(width: 12),
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
                          iconSize: 26,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Tooltip(
                        message:
                            services.dandanplayDanmakuEnabled ||
                                services.bilibiliDanmakuEnabled
                            ? '弹幕源'
                            : '弹幕源已关闭',
                        child: IconButton(
                          onPressed: onDanmakuPanel,
                          padding: EdgeInsets.zero,
                          icon: Icon(
                            Icons.sports_esports_outlined,
                            color:
                                services.dandanplayDanmakuEnabled ||
                                    services.bilibiliDanmakuEnabled
                                ? Colors.white
                                : Colors.white38,
                          ),
                          iconSize: 26,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: AppColors.bg.withValues(alpha: 0.72),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: Colors.white12),
                          ),
                          child: SizedBox(
                            height: 40,
                            child: TextField(
                              controller: danmakuInput,
                              enabled: danmaku.enabled,
                              textInputAction: TextInputAction.send,
                              onSubmitted: onSendDanmaku,
                              style: const TextStyle(color: Colors.white),
                              decoration: InputDecoration(
                                isDense: true,
                                filled: false,
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
                                hintText: danmaku.enabled
                                    ? '发送本地弹幕，按 Enter 发送'
                                    : '弹幕已关闭',
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 11,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Tooltip(
                        message: muted
                            ? '已静音，点击恢复'
                            : '音量 ${volume.round()}%，点击静音',
                        child: IconButton(
                          onPressed: onMute,
                          padding: EdgeInsets.zero,
                          icon: Icon(
                            muted || volume <= 0
                                ? Icons.volume_off_rounded
                                : Icons.volume_up_rounded,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
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
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: onLinePanel,
                        child: Text(
                          line?.providerName ?? '线路',
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                      const SizedBox(width: 8),
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
                  line?.providerName ?? '线路',
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

class _BufferedSeekBar extends StatelessWidget {
  const _BufferedSeekBar({
    required this.progress,
    required this.buffered,
    required this.enabled,
    required this.onSeek,
  });

  final double progress;
  final double buffered;
  final bool enabled;
  final ValueChanged<double> onSeek;

  @override
  Widget build(BuildContext context) {
    final played = progress.clamp(0.0, 1.0);
    final cached = buffered.clamp(played, 1.0);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final thumbX = width * played;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: enabled
              ? (details) => _seekFromDx(details.localPosition.dx, width)
              : null,
          onHorizontalDragUpdate: enabled
              ? (details) => _seekFromDx(details.localPosition.dx, width)
              : null,
          child: MouseRegion(
            cursor: enabled
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            child: SizedBox(
              height: 28,
              child: Stack(
                alignment: Alignment.centerLeft,
                children: [
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

class _PlayerEpisodeRail extends StatelessWidget {
  const _PlayerEpisodeRail({
    required this.subject,
    required this.episodes,
    required this.selected,
    required this.onEpisodePanel,
    required this.onEpisodeSelected,
    required this.onLinePanel,
  });

  final AnimeSubject subject;
  final List<AnimeEpisode> episodes;
  final AnimeEpisode selected;
  final VoidCallback onEpisodePanel;
  final ValueChanged<AnimeEpisode> onEpisodeSelected;
  final VoidCallback onLinePanel;

  @override
  Widget build(BuildContext context) {
    return AppPanel(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          SectionTitle(
            title: '选集',
            subtitle: '当前第 ${selected.number} 集',
            action: TextButton.icon(
              onPressed: onEpisodePanel,
              icon: const Icon(Icons.sort, size: 16),
              label: const Text('全部'),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: ListView.separated(
              itemCount: episodes.length,
              separatorBuilder: (context, index) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final episode = episodes[index];
                final active = episode.id == selected.id;
                return InkWell(
                  onTap: active ? null : () => onEpisodeSelected(episode),
                  borderRadius: BorderRadius.circular(8),
                  child: AppPanel(
                    padding: const EdgeInsets.all(8),
                    color: active
                        ? Theme.of(context).colorScheme.primaryContainer
                        : AppColors.bg2,
                    borderColor: active
                        ? Theme.of(context).colorScheme.primary
                        : AppColors.border,
                    child: Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: SizedBox(
                            width: 76,
                            height: 46,
                            child: PosterArt(
                              coverUrl:
                                  selected.thumbnailUrl ?? subject.coverUrl,
                              title: subject.title,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                episode.displayTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.labelLarge
                                    ?.copyWith(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurface,
                                      fontWeight: FontWeight.w900,
                                    ),
                              ),
                              Text(
                                active ? '正在播放' : '23:40 · 待播放',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                    ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: '线路',
                          onPressed: onLinePanel,
                          icon: Icon(
                            active ? Icons.graphic_eq : Icons.download_outlined,
                            color: active ? AppColors.primary : AppColors.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: onEpisodePanel,
              child: const Text('展开全部剧集'),
            ),
          ),
        ],
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
  return lines.where(_isPlayableLine).toList(growable: false);
}

List<PlaybackLine> _mergeLineLists(
  List<PlaybackLine> first,
  List<PlaybackLine> second,
) {
  if (first.isEmpty) return second;
  if (second.isEmpty) return first;
  return <String, PlaybackLine>{
    for (final line in first) line.id: line,
    for (final line in second) line.id: line,
  }.values.toList(growable: false);
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
      return '这部作品目前仅有影视资料，暂无可直接播放线路。可到播放规则页添加或启用规则。';
    }
    return '已安装规则里没有适合当前内容的可解析线路，可以到规则仓库安装同类型规则。';
  }
  if (isMetadataOnly) {
    return '这部作品目前仅有影视资料；已尝试 ${lines.length} 条规则，但没有可直接播放的地址。可到播放规则页添加或启用规则。';
  }
  final unavailableCount = lines.where((line) => !line.available).length;
  return _unavailableLinesMessage(lines, count: unavailableCount);
}

String _unavailableLinesMessage(List<PlaybackLine> lines, {int? count}) {
  final unavailableLines = lines.where((line) => !line.available).toList();
  final total = count ?? unavailableLines.length;
  final deadCount = unavailableLines
      .where((line) => (line.message ?? '').contains('视频 CDN'))
      .length;
  if (deadCount > 0) {
    return '找到 $total 条线路，但其中 $deadCount 条视频 CDN 已失效、拒绝访问或连接超时，暂时不会当作可播放线路。';
  }
  return '找到 $total 条规则，但它们需要验证码、WebView 或对应执行器，暂时无法直接播放。';
}

String _hiddenLinesMessage(List<PlaybackLine> lines) {
  final unavailableLines = lines.where((line) => !line.available).toList();
  final deadCount = unavailableLines
      .where((line) => (line.message ?? '').contains('视频 CDN'))
      .length;
  if (deadCount > 0) return '已隐藏 $deadCount 条失效或被拒绝的 CDN 线路';
  return '已隐藏 ${unavailableLines.length} 条不可直接播放的规则';
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

class _LinePanel extends ConsumerStatefulWidget {
  const _LinePanel({
    required this.subject,
    required this.episode,
    required this.selected,
    required this.initialLines,
    required this.offlineOnly,
    required this.onLinesLoaded,
    required this.onSelected,
  });

  final AnimeSubject subject;
  final AnimeEpisode episode;
  final PlaybackLine? selected;
  final List<PlaybackLine> initialLines;
  final bool offlineOnly;
  final ValueChanged<List<PlaybackLine>> onLinesLoaded;
  final ValueChanged<PlaybackLine> onSelected;

  @override
  ConsumerState<_LinePanel> createState() => _LinePanelState();
}

class _LinePanelState extends ConsumerState<_LinePanel> {
  Future<List<PlaybackLine>>? _future;
  var _notifiedFutureResult = false;

  @override
  void initState() {
    super.initState();
    _future = _futureForWidget();
  }

  @override
  void didUpdateWidget(covariant _LinePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.episode.id != widget.episode.id ||
        oldWidget.subject.id != widget.subject.id) {
      _notifiedFutureResult = false;
      _future = _futureForWidget();
    }
  }

  Future<List<PlaybackLine>> _futureForWidget() {
    if (widget.offlineOnly) return Future.value(widget.initialLines);
    return ref
        .read(animeControllerProvider.notifier)
        .linesForEpisodeMode(widget.subject, widget.episode, expandAll: true);
  }

  @override
  Widget build(BuildContext context) {
    final initialLines = widget.initialLines;
    return FutureBuilder<List<PlaybackLine>>(
      future: _future,
      builder: (context, snapshot) {
        final expandedLines = snapshot.data ?? const <PlaybackLine>[];
        if (expandedLines.isNotEmpty && !_notifiedFutureResult) {
          _notifiedFutureResult = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) widget.onLinesLoaded(expandedLines);
          });
        }
        final lines = _mergeLineLists(initialLines, expandedLines);
        return _LinePanelBody(
          lines: lines,
          selected: widget.selected,
          loading:
              snapshot.connectionState == ConnectionState.waiting &&
              initialLines.isEmpty,
          expanding:
              snapshot.connectionState == ConnectionState.waiting &&
              initialLines.isNotEmpty,
          onSelected: widget.onSelected,
        );
      },
    );
  }
}

class _LinePanelBody extends StatelessWidget {
  const _LinePanelBody({
    required this.lines,
    required this.selected,
    required this.loading,
    required this.expanding,
    required this.onSelected,
  });

  final List<PlaybackLine> lines;
  final PlaybackLine? selected;
  final bool loading;
  final bool expanding;
  final ValueChanged<PlaybackLine> onSelected;

  @override
  Widget build(BuildContext context) {
    final availableLines = lines.where((line) => line.available).toList();
    final unavailableCount = lines.length - availableLines.length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 110),
      children: [
        const _LineModeBar(),
        const SizedBox(height: 14),
        if (expanding) ...[
          _PanelInlineStatus(text: '正在继续扫描更多已启用规则，已找到的线路可以先用。'),
          const SizedBox(height: 12),
        ],
        if (loading)
          const Center(child: CircularProgressIndicator())
        else if (availableLines.isEmpty)
          _PanelEmpty(
            title: '当前没有可播放线路',
            message: lines.isEmpty
                ? '已安装规则里没有适合当前内容的可解析线路，可以到规则仓库安装同类型规则。'
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
                  if (unavailableCount > 0) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Text(
                        _hiddenLinesMessage(lines),
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: Colors.white54),
                      ),
                    ),
                    const Divider(height: 1, color: Color(0xFF303030)),
                  ],
                  for (var i = 0; i < availableLines.length; i++) ...[
                    _LineTile(
                      index: i,
                      line: availableLines[i],
                      selected: selected?.id == availableLines[i].id,
                      onTap: () => onSelected(availableLines[i]),
                    ),
                    if (i != availableLines.length - 1)
                      const Divider(height: 1, color: Color(0xFF303030)),
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

class _DanmakuPanel extends ConsumerWidget {
  const _DanmakuPanel({required this.subject, required this.episode});

  final AnimeSubject subject;
  final AnimeEpisode episode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder<List<DanmakuMatch>>(
      future: ref
          .read(animeControllerProvider.notifier)
          .danmakuForEpisode(subject, episode),
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
              title: item.title.isEmpty ? subject.title : item.title,
              subtitle:
                  '${item.provider} · ${item.episodeTitle.isEmpty ? episode.displayTitle : item.episodeTitle}',
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
  const _PanelInlineStatus({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.panelHigh,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF303030)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
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
            VerticalDivider(width: 1, color: Color(0xFF383838)),
            Expanded(child: _ModeItem(Icons.link, '网络视频')),
            VerticalDivider(width: 1, color: Color(0xFF383838)),
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
    );
  }
}

class _LineTile extends StatelessWidget {
  const _LineTile({
    required this.index,
    required this.line,
    required this.selected,
    required this.onTap,
  });

  final int index;
  final PlaybackLine line;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final status = line.available
        ? '${line.latency?.inMilliseconds ?? 0}ms · ${line.sizeLabel ?? '--'}'
        : line.message ?? '待接入';
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '线路${index + 1} · ${line.providerName} · ${line.title}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: selected
                          ? Theme.of(context).colorScheme.primary
                          : Colors.white,
                      fontWeight: FontWeight.w800,
                    ),
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
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text(
              status,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: line.available
                    ? Colors.greenAccent
                    : Colors.orangeAccent,
              ),
            ),
          ],
        ),
      ),
    );
  }
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
