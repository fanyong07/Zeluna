import 'dart:async';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:screen_brightness/screen_brightness.dart';

import '../app/anime_app.dart';
import '../data/anime_controller.dart';
import '../data/playback_source_repository.dart';
import '../domain/anime_models.dart';
import '../rules/rule_playback_resolver.dart';
import '../settings/settings_page.dart';
import '../shared_ui/app_chrome.dart';
import '../shared_ui/app_navigation.dart';
import '../shared_ui/poster_card.dart';
import 'anime4k/anime4k_controller.dart';
import 'app_fullscreen.dart';
import 'danmaku/danmaku_controller.dart';
import 'danmaku_overlay.dart';
import 'gestures/player_gesture_controller.dart';
import 'lines/playback_line_controller.dart';
import 'lines/playback_recovery_controller.dart';
import 'playback_line_display.dart';
import 'playback_performance_trace.dart';
import 'session/playback_session_controller.dart';
import 'session/playback_session_event.dart';
import 'subtitles/subtitle_controller.dart';
import 'video/native_video_controller.dart';
import 'video/web_video_controller.dart';
import 'web_stream_player.dart';

part 'ui/player_canvas.dart';
part 'ui/player_chrome.dart';
part 'ui/player_panels.dart';
part 'ui/player_mobile_layout.dart';
part 'ui/player_desktop_layout.dart';

class PlayerPage extends ConsumerStatefulWidget {
  const PlayerPage({super.key, required this.request});

  final PlaySessionRequest request;

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage>
    with WidgetsBindingObserver {
  late AnimeEpisode _episode;
  late final NativeVideoController _nativeVideo;
  late final WebVideoController _webVideo;
  late final PlayerGestureController _gestureController;
  late final PlaybackSessionController _sessionController;
  late final PlaybackLineController _lineController;
  late final PlaybackRecoveryController _recoveryController;
  late final DanmakuController _danmakuController;
  late final SubtitleController _subtitleController;
  late final Anime4KController _anime4kController;
  late PlaybackPerformanceTrace _playbackTrace;
  final _appFullscreen = AppFullscreenController();
  final _subscriptions = <StreamSubscription<dynamic>>[];
  int? _handledFailureOpenSerial;
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
  bool _controlsVisible = true;
  double? _temporaryPlaybackRate;
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
  var _leaving = false;
  var _lineLookupSerial = 0;
  var _openLineSerial = 0;
  int? _firstFrameTraceOpenSerial;
  String? _pendingRecoveryLineId;
  String? _pendingRecoveryStrategy;
  String? _pendingRecoveryFromProvider;
  var _finalFailureTraceRecorded = false;
  PlaybackSettings _currentSettings = const PlaybackSettings();
  DateTime? _ignoreNativeErrorsUntil;
  var _backupLookupInProgress = false;
  var _backupLookupSerial = 0;
  var _appInForeground = true;
  Duration? _pendingInitialResumePosition;
  bool _episodePanel = false;
  bool _linePanel = false;
  bool _subtitlePanel = false;
  bool _danmakuPanel = false;
  bool _settingsPanel = false;
  bool _theaterMode = false;

  Player get _player => _nativeVideo.player;
  VideoController get _controller => _nativeVideo.surfaceController;
  WebStreamPlayerController get _webPlayerController =>
      _webVideo.surfaceController;
  Timer? get _webLoadTimer => _webVideo.startupTimer;
  set _webLoadTimer(Timer? value) => _webVideo.replaceStartupTimer(value);
  Timer? get _backupLookupDelayTimer => _recoveryController.backupLookupTimer;
  set _backupLookupDelayTimer(Timer? value) =>
      _recoveryController.replaceBackupLookupTimer(value);
  Timer? get _nativeFirstFrameTimer => _nativeVideo.firstFrameTimer;
  set _nativeFirstFrameTimer(Timer? value) =>
      _nativeVideo.replaceFirstFrameTimer(value);
  FocusNode get _shortcutFocusNode => _gestureController.shortcutFocusNode;
  Timer? get _controlsHideTimer => _gestureController.controlsHideTimer;
  set _controlsHideTimer(Timer? value) =>
      _gestureController.replaceControlsHideTimer(value);
  StreamSubscription<PlaybackLineLookupUpdate>? get _lineLookupSubscription =>
      _lineController.lookupSubscription;
  set _lineLookupSubscription(
    StreamSubscription<PlaybackLineLookupUpdate>? value,
  ) => _lineController.lookupSubscription = value;
  RulePlaybackCancellationToken? get _lineLookupCancellationToken =>
      _lineController.lookupCancellationToken;
  set _lineLookupCancellationToken(RulePlaybackCancellationToken? value) =>
      _lineController.lookupCancellationToken = value;
  RulePlaybackCancellationToken? get _backupLookupCancellationToken =>
      _lineController.backupLookupCancellationToken;
  set _backupLookupCancellationToken(RulePlaybackCancellationToken? value) =>
      _lineController.backupLookupCancellationToken = value;
  Set<String> get _failedLineIds => _lineController.failedLineIds;
  Map<String, int> get _lineFailureCounts => _lineController.failureCounts;
  set _preferredProviderId(String? value) =>
      _lineController.preferredProviderId = value;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _nativeVideo = NativeVideoController(readOpenSerial: () => _openLineSerial);
    _webVideo = WebVideoController();
    _gestureController = PlayerGestureController();
    _episode = widget.request.episode;
    _sessionController = PlaybackSessionController(episodeId: _episode.id);
    _lineController = PlaybackLineController();
    _recoveryController = PlaybackRecoveryController();
    _danmakuController = DanmakuController()
      ..addListener(_handleDanmakuChanged);
    _subtitleController = SubtitleController(
      applyTrack: _player.setSubtitleTrack,
    )..addListener(_handleSubtitleChanged);
    _anime4kController = Anime4KController(
      platform: defaultTargetPlatform,
      getProperty: _readMpvProperty,
      setProperty: _writeMpvProperty,
    )..addListener(_handleAnime4KChanged);
    _startPlaybackTrace();
    _line = widget.request.initialLine;
    _lines = initialPlaybackLinesForDisplay(widget.request.initialLine);
    _pendingInitialResumePosition = widget.request.resumePosition;
    _loadingLine = _isPlayableLine(_line);
    _lineLookupInProgress = !_loadingLine && !widget.request.offlineOnly;
    _resetPlaybackStallWatchdog(
      position: widget.request.resumePosition,
      grace: const Duration(seconds: 5),
    );
    _recoveryController.startStallWatchdog(
      const Duration(seconds: 1),
      _checkPlaybackStall,
    );
    _bindPlayer();
    _subscriptions.add(
      _appFullscreen.changes.listen((enabled) {
        if (!mounted || _fullscreen == enabled) return;
        setState(() => _fullscreen = enabled);
        if (!enabled) unawaited(_restoreSystemUi());
      }),
    );
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
      } else {
        _recordFinalPlaybackFailure(reason: 'offline_line_unavailable');
      }
    });
  }

  void _handleDanmakuChanged() {
    if (mounted) setState(() {});
  }

  void _handleSubtitleChanged() {
    if (mounted) setState(() {});
  }

  void _handleAnime4KChanged() {
    if (mounted) setState(() {});
  }

  Future<String> _readMpvProperty(String property) async {
    final platform = _player.platform;
    if (platform is! NativePlayer) {
      throw UnsupportedError('The current player is not backed by libmpv.');
    }
    final nativePlayer = platform as dynamic;
    final value = await nativePlayer.getProperty(property);
    return value?.toString() ?? '';
  }

  Future<void> _writeMpvProperty(String property, String value) async {
    final platform = _player.platform;
    if (platform is! NativePlayer) {
      throw UnsupportedError('The current player is not backed by libmpv.');
    }
    final nativePlayer = platform as dynamic;
    await nativePlayer.setProperty(property, value);
  }

  void _startPlaybackTrace() {
    _playbackTrace = PlaybackPerformanceTrace();
    _firstFrameTraceOpenSerial = null;
    _pendingRecoveryLineId = null;
    _pendingRecoveryStrategy = null;
    _pendingRecoveryFromProvider = null;
    _finalFailureTraceRecorded = false;
    _playbackTrace.record(
      'play_requested',
      fields: <String, Object?>{
        'episode_number': _episode.number,
        'content_source': widget.request.subject.source,
        'offline': widget.request.offlineOnly,
      },
    );
  }

  Map<String, Object?> _lineTraceFields(PlaybackLine line) {
    return <String, Object?>{
      'provider': line.providerId,
      'format': line.format,
      'server_verified': line.serverVerified,
      'client_verified': line.clientVerified,
      'requires_client_probe': line.requiresClientProbe,
      'cache_state': line.cacheState,
      'source_error_category': line.sourceErrorCategory,
      if (line.latency != null)
        'source_latency_ms': line.latency!.inMilliseconds,
    };
  }

  void _recordFirstFrame(PlaybackLine line) {
    if (_firstFrameTraceOpenSerial == _openLineSerial) return;
    _firstFrameTraceOpenSerial = _openLineSerial;
    _sessionController.dispatch(PlaybackSessionEvent.firstFrame(line.id));
    _playbackTrace.record('first_frame', fields: _lineTraceFields(line));
    _playbackTrace.recordBufferingChanged(
      buffering: false,
      fields: <String, Object?>{
        ..._lineTraceFields(line),
        'outcome': 'resumed',
      },
    );
    final pendingRecoveryLineId = _pendingRecoveryLineId;
    if (pendingRecoveryLineId != null) {
      _playbackTrace.record(
        'playback_recovered',
        fields: <String, Object?>{
          ..._lineTraceFields(line),
          'recovery_strategy': pendingRecoveryLineId == line.id
              ? _pendingRecoveryStrategy ?? 'unknown'
              : 'manual_override',
          if (_pendingRecoveryFromProvider?.isNotEmpty == true)
            'from_provider': _pendingRecoveryFromProvider,
          'to_provider': line.providerId,
        },
      );
      _pendingRecoveryLineId = null;
      _pendingRecoveryStrategy = null;
      _pendingRecoveryFromProvider = null;
    }
    _finalFailureTraceRecorded = false;
  }

  void _beginPlaybackRecovery(
    PlaybackLine target, {
    required String strategy,
    PlaybackLine? previous,
    Duration position = Duration.zero,
  }) {
    if (strategy == 'auto_switch' && previous?.id != target.id) {
      _sessionController.dispatch(
        PlaybackSessionEvent.alternativeSelected(target.id),
      );
    }
    _pendingRecoveryLineId = target.id;
    _pendingRecoveryStrategy = strategy;
    _pendingRecoveryFromProvider = previous?.providerId;
    _playbackTrace.record(
      strategy == 'auto_switch' ? 'auto_switch_started' : 'recovery_started',
      fields: <String, Object?>{
        if (previous != null) 'from_provider': previous.providerId,
        'to_provider': target.providerId,
        'recovery_strategy': strategy,
        'position_ms': position.inMilliseconds,
      },
    );
  }

  void _recordFinalPlaybackFailure({required String reason}) {
    if (_finalFailureTraceRecorded) return;
    _finalFailureTraceRecorded = true;
    _sessionController.dispatch(
      PlaybackSessionEvent.mediaError(reason, hasAlternative: false),
    );
    final current = _line;
    _playbackTrace.recordBufferingChanged(
      buffering: false,
      fields: const <String, Object?>{'outcome': 'failed'},
    );
    _playbackTrace.record(
      'playback_failed',
      fields: <String, Object?>{
        if (current != null) ..._lineTraceFields(current),
        'reason': reason,
        'position_ms': _currentRecoveryPosition.inMilliseconds,
        'line_count': _lines.length,
        'failed_line_count': _failedLineIds.length,
      },
    );
    _pendingRecoveryLineId = null;
    _pendingRecoveryStrategy = null;
    _pendingRecoveryFromProvider = null;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _anime4kController.dispose();
    unawaited(_restoreSystemUi());
    if (_fullscreen) unawaited(_appFullscreen.setEnabled(false));
    _appFullscreen.dispose();
    unawaited(_nativeVideo.dispose());
    _webVideo.dispose();
    _recoveryController.dispose();
    unawaited(_lineController.dispose());
    _danmakuController.dispose();
    _subtitleController.dispose();
    _gestureController.dispose();
    _sessionController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final inForeground = state == AppLifecycleState.resumed;
    if (_appInForeground == inForeground) return;
    _appInForeground = inForeground;
    _sessionController.dispatch(
      inForeground
          ? PlaybackSessionEvent.applicationResumed()
          : PlaybackSessionEvent.applicationPaused(),
    );
    _resetPlaybackStallWatchdog(
      grace: inForeground ? const Duration(seconds: 3) : Duration.zero,
    );
    if (inForeground && _playing) {
      _scheduleSingleBackupLookup();
    } else {
      _backupLookupDelayTimer?.cancel();
      _backupLookupDelayTimer = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AsyncAnimeGate(
      builder: (context, state) {
        final effectiveSettings = _temporaryPlaybackRate == null
            ? state.settings
            : state.settings.copyWith(speed: _temporaryPlaybackRate);
        _applyPlaybackSettings(effectiveSettings);
        final superResolutionStatus = _anime4kController.displayStatus;
        final superResolutionPanelStatus = _buildSuperResolutionPanelStatus(
          superResolutionStatus,
        );
        final portraitPlayerLayout = usesPortraitPlayerPageLayoutForSize(
          MediaQuery.sizeOf(context),
          defaultTargetPlatform,
          fullscreen: _fullscreen,
        );
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
              child: buildPlayerSafeArea(
                fullscreen: _fullscreen,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _ResponsivePlayerLayout(
                      portrait: portraitPlayerLayout,
                      subject: widget.request.subject,
                      episodes: widget.request.episodes,
                      episode: _episode,
                      line: _line,
                      lines: _lines,
                      failedLineIds: _failedLineIds,
                      loadingLines:
                          _lineLookupInProgress || _lineScanInProgress,
                      onEpisodePanel: _toggleEpisodePanel,
                      onEpisodeSelected: _selectEpisode,
                      onLinePanel: _toggleLinePanel,
                      onLineSelected: _selectLine,
                      player: _PlayerCanvas(
                        controller: _controller,
                        webPlayerController: _webPlayerController,
                        subject: widget.request.subject,
                        episodes: widget.request.episodes,
                        episode: _episode,
                        line: _line,
                        settings: effectiveSettings,
                        superResolutionActive: _anime4kController.isActive,
                        services: state.services,
                        danmaku: state.danmaku,
                        remoteDanmaku: _danmakuController.remoteComments,
                        localDanmaku: _danmakuController.localComments,
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
                        onToggleControls: _togglePlayerControls,
                        onChromeHotZoneChanged:
                            _handlePlayerChromeHotZoneChanged,
                        onBack: _handleBack,
                        onReload: _reloadCurrentLine,
                        onScreenshot: _captureScreenshot,
                        onTheaterMode: _toggleTheaterMode,
                        onCast: _showExternalPlayback,
                        onPlayPause: _togglePlayPause,
                        onPreviousEpisode: _canPlayPreviousEpisode
                            ? _playPreviousEpisode
                            : null,
                        onNextEpisode: _canPlayNextEpisode
                            ? _playNextEpisode
                            : null,
                        onTemporaryDoubleSpeedStart: _startTemporaryDoubleSpeed,
                        onTemporaryDoubleSpeedEnd: _endTemporaryDoubleSpeed,
                        onVideoViewportSize: _handleVideoViewportSize,
                        onRewind: () => _seekBy(
                          Duration(seconds: -state.settings.rewindSeconds),
                        ),
                        onForward: () => _seekBy(
                          Duration(seconds: state.settings.forwardSeconds),
                        ),
                        onSeek: _seekTo,
                        onMute: _toggleMute,
                        onVolumeChanged: _setVolume,
                        onGestureVolumeChanged: _setGestureVolume,
                        onSpeedSelected: _selectSpeed,
                        onFullscreen: () => _setFullscreen(!_fullscreen),
                        onEpisodePanel: _toggleEpisodePanel,
                        onEpisodeSelected: _selectEpisode,
                        onLinePanel: _toggleLinePanel,
                        onSubtitlePanel: _toggleSubtitlePanel,
                        onDanmakuPanel: _toggleDanmakuPanel,
                        danmakuInput: _danmakuController.input,
                        onSendDanmaku: (text) =>
                            _sendLocalDanmaku(text, settings: state.danmaku),
                        onWebReady: _handleWebReady,
                        onWebError: _handleWebError,
                        onWebPosition: _handleWebPosition,
                        onWebDuration: _handleWebDuration,
                        onWebPlaying: _handleWebPlaying,
                        onSettingsPanel: _toggleSettingsPanel,
                      ),
                    ),
                    if (_episodePanel)
                      _PlayerFunctionPage(
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
                      _PlayerFunctionPage(
                        title: '播放来源',
                        onClose: _closePanels,
                        child: PlaybackSourcePanel(
                          selected: _line,
                          lines: _lines,
                          failedLineIds: _failedLineIds,
                          scanning: _lineScanInProgress,
                          completedRules: _lineScanCompletedRules,
                          totalRules: _lineScanTotalRules,
                          onSelected: _selectLine,
                          onPickLocal: _pickLocalPlaybackFile,
                          onOpenNetwork: _openNetworkPlayback,
                          onSearch: _searchPlaybackLines,
                        ),
                      ),
                    if (_subtitlePanel)
                      _PlayerFunctionPage(
                        title: '字幕源',
                        onClose: _closePanels,
                        child: _SubtitlePanel(
                          subject: widget.request.subject,
                          episode: _episode,
                          selected: _subtitleController.selected,
                          onSelected: _selectSubtitle,
                          onDisabled: _disableSubtitle,
                        ),
                      ),
                    if (_danmakuPanel)
                      _PlayerFunctionPage(
                        title: '弹幕源',
                        onClose: _closePanels,
                        child: _DanmakuPanel(
                          subject: widget.request.subject,
                          episode: _episode,
                        ),
                      ),
                    if (_settingsPanel)
                      _PlayerFunctionPage(
                        title: '',
                        onClose: _closePanels,
                        child: PlaybackSettingsView(
                          compact: true,
                          subject: widget.request.subject,
                          episode: _episode,
                          line: _line,
                          playbackMessage: _surfaceMessage,
                          superResolutionStatus: superResolutionPanelStatus,
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
    if (_lineLookupInProgress) return '正在查找可播放线路…';
    if (_loadingLine) {
      return '正在连接 ${_line == null ? '播放线路' : playbackLineProviderLabel(_line!)}…';
    }
    if (_playbackFailed) return _playerMessage ?? '当前线路无法播放，请切换线路。';
    if (!_isPlayableLine(_line)) {
      return _lineLookupMessage ?? '当前集还没有选中可播放线路。';
    }
    if (_buffering) return '缓冲中…';
    return _playerMessage;
  }

  Widget? _buildSuperResolutionPanelStatus(Anime4KDisplayStatus? status) {
    final notice = _anime4kController.statusMessage?.trim();
    if (status == null && (notice == null || notice.isEmpty)) return null;

    final children = <Widget>[
      if (status != null)
        _SuperResolutionPanelStatus(
          status: status,
          onCompareStart: () => _anime4kController.setOriginalPreview(true),
          onCompareEnd: () => _anime4kController.setOriginalPreview(false),
        ),
      if (status != null && notice != null && notice.isNotEmpty)
        const SizedBox(height: 8),
      if (notice != null && notice.isNotEmpty)
        _SuperResolutionPanelNotice(message: notice),
    ];
    return children.length == 1
        ? children.single
        : Column(mainAxisSize: MainAxisSize.min, children: children);
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

  void _togglePlayerControls() {
    if (!mounted || _hasOpenPanel) return;
    _controlsHideTimer?.cancel();
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleControlsHide();
  }

  void _startTemporaryDoubleSpeed() {
    if (!mounted || _temporaryPlaybackRate != null) return;
    HapticFeedback.selectionClick();
    setState(() => _temporaryPlaybackRate = 2.0);
  }

  void _endTemporaryDoubleSpeed() {
    if (!mounted || _temporaryPlaybackRate == null) return;
    setState(() => _temporaryPlaybackRate = null);
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
    _nativeVideo
      ..track(
        _player.stream.playing.listen((value) {
          if (!mounted || _usesWebPlayer) return;
          _sessionController.dispatch(
            value
                ? PlaybackSessionEvent.playbackResumed()
                : PlaybackSessionEvent.playbackPaused(),
          );
          setState(() => _playing = value);
          _anime4kController.updatePlaybackState(
            playing: value,
            buffering: _buffering,
          );
          _resetPlaybackStallWatchdog(
            grace: value ? const Duration(seconds: 2) : Duration.zero,
          );
          if (value) {
            _scheduleControlsHide();
            unawaited(
              _anime4kController.refreshFrameRate(
                usesWebPlayer: _usesWebPlayer,
              ),
            );
            _scheduleSingleBackupLookup();
          } else {
            _backupLookupDelayTimer?.cancel();
            _backupLookupDelayTimer = null;
            _controlsHideTimer?.cancel();
            if (!_controlsVisible) setState(() => _controlsVisible = true);
          }
        }),
      )
      ..track(
        _player.stream.position.listen((value) {
          if (!mounted || _usesWebPlayer) return;
          _notePlaybackProgress(value);
          _nativeVideo.resumeSeek.handleProgress(value);
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
            _ignoreNativeErrorsUntil = null;
            final current = _line;
            if (current != null) {
              _clearLineFailure(current.id);
              _preferredProviderId = current.providerId;
              _recordFirstFrame(current);
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
            _scheduleSingleBackupLookup();
          }
        }),
      )
      ..track(
        _player.stream.duration.listen((value) {
          if (mounted && !_usesWebPlayer) {
            setState(() => _duration = value);
            if (value > Duration.zero) {
              _nativeVideo.resumeSeek.nudge(mediaReady: true);
            }
          }
        }),
      )
      ..track(
        _player.stream.buffer.listen((value) {
          if (mounted && !_usesWebPlayer) setState(() => _buffer = value);
        }),
      )
      ..track(
        _player.stream.videoParams.listen((value) {
          if (mounted && !_usesWebPlayer) {
            _anime4kController.updateVideoDimensions(
              width: value.w ?? 0,
              height: value.h ?? 0,
            );
            unawaited(
              _anime4kController.refreshFrameRate(
                usesWebPlayer: _usesWebPlayer,
              ),
            );
          }
        }),
      )
      ..track(
        _player.stream.buffering.listen((value) {
          if (!mounted || _usesWebPlayer) return;
          _sessionController.dispatch(
            value
                ? PlaybackSessionEvent.bufferingStarted()
                : PlaybackSessionEvent.bufferingEnded(),
          );
          final changed = _buffering != value;
          final current = _line;
          if (changed) {
            _playbackTrace.recordBufferingChanged(
              buffering: value,
              fields: <String, Object?>{
                if (current != null) ..._lineTraceFields(current),
                'position_ms': _position.inMilliseconds,
                'buffer_ahead_ms': playbackBufferedAhead(
                  position: _position,
                  buffer: _buffer,
                ).inMilliseconds,
              },
            );
          }
          setState(() => _buffering = value);
          _anime4kController.updatePlaybackState(
            playing: _playing,
            buffering: value,
          );
          if (value) {
            _backupLookupDelayTimer?.cancel();
            _backupLookupDelayTimer = null;
          } else if (_playing) {
            _scheduleSingleBackupLookup();
          }
        }),
      )
      ..track(
        _player.stream.volume.listen((value) {
          if (mounted) {
            setState(() {
              _volume = value;
              if (!_muted && value > 0) _lastNonZeroVolume = value;
            });
          }
        }),
      )
      ..track(
        _player.stream.completed.listen((completed) {
          if (_usesWebPlayer) return;
          if (completed) {
            _sessionController.dispatch(PlaybackSessionEvent.playbackEnded());
            _backupLookupDelayTimer?.cancel();
            _backupLookupDelayTimer = null;
            _resetPlaybackStallWatchdog();
            if (_currentSettings.autoNext) _playNextEpisode();
          }
        }),
      )
      ..track(
        _player.stream.error.listen((error) {
          if (_usesWebPlayer) return;
          _handlePlayerError(error);
        }),
      )
      ..track(
        _player.stream.log.listen(
          (log) => _anime4kController.handlePlayerLog(
            prefix: log.prefix,
            text: log.text,
          ),
        ),
      );
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
    _anime4kController.applySettings(settings, force: force);
  }

  void _refreshSuperResolutionShader() {
    _anime4kController.refresh();
  }

  void _handleVideoViewportSize(Size physicalSize) {
    _anime4kController.updateViewport(physicalSize);
  }

  double _volumeFromSettings(PlaybackSettings settings) {
    return (100 + settings.volumeBoost * 100).clamp(0, 200).toDouble();
  }

  Future<void> _resolveLinesForCurrentEpisode({bool autoplay = true}) async {
    final serial = ++_lineLookupSerial;
    _sessionController.dispatch(PlaybackSessionEvent.lookupStarted());
    _cancelSingleBackupLookup();
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
    _playbackTrace.record('line_lookup_started');
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
      for (final discovered in available) {
        _sessionController.dispatch(
          PlaybackSessionEvent.lineDiscovered(discovered.id),
        );
        if (discovered.serverVerified || discovered.clientVerified) {
          _sessionController.dispatch(
            PlaybackSessionEvent.lineVerified(discovered.id),
          );
        }
      }
      PlaybackLine? nextLine = _line;
      if (!_isPlayableLine(nextLine) && available.isNotEmpty) {
        nextLine = _preferredPlayableLine(available);
      }
      setState(() {
        _lines = lines;
        _line = nextLine;
        _lineLookupInProgress = available.isEmpty && usesProgressiveLookup;
        _lineLookupMessage = available.isEmpty ? '暂时还没找到可用线路，仍在继续查找…' : null;
      });
      _playbackTrace.record(
        'line_lookup_completed',
        fields: <String, Object?>{
          'line_count': lines.length,
          'playable_count': available.length,
        },
      );
      if (autoplay && _isPlayableLine(nextLine)) {
        await _openLine(nextLine!, force: true);
      } else if (available.isEmpty && usesProgressiveLookup) {
        _startExpandedLineLookup(autoplay: autoplay);
      } else if (available.isEmpty) {
        await _player.stop();
        _recordFinalPlaybackFailure(reason: 'no_playable_line');
      }
    } catch (error) {
      if (!mounted || serial != _lineLookupSerial) return;
      _playbackTrace.record(
        'line_lookup_failed',
        fields: <String, Object?>{'error_type': error.runtimeType.toString()},
      );
      setState(() {
        _lines = const [];
        _lineLookupInProgress = false;
        _lineLookupMessage = '查找线路失败：${_friendlyPlaybackError(error)}';
        _playbackFailed = true;
      });
      _recordFinalPlaybackFailure(reason: 'line_lookup_failed');
    }
  }

  void _resetPlaybackStallWatchdog({
    Duration? position,
    Duration grace = Duration.zero,
  }) {
    _recoveryController.resetStallWatchdog(
      position: position ?? _position,
      grace: grace,
    );
  }

  void _notePlaybackProgress(Duration value) {
    _recoveryController.notePlaybackProgress(value);
  }

  void _checkPlaybackStall() {
    if (!_recoveryController.shouldRecoverFromStall(
      recoveryBlocked:
          !mounted ||
          _leaving ||
          !_isPlayableLine(_line) ||
          _nativeVideo.resumeSeek.isPending ||
          _nativeVideo.resumeSeek.isSeeking,
      appInForeground: _appInForeground,
      playing: _playing,
      buffering: _buffering,
      loading: _loadingLine,
      playbackFailed: _playbackFailed,
      position: _position,
      duration: _duration,
      buffer: _buffer,
    )) {
      return;
    }
    final current = _line;
    if (!_isPlayableLine(current)) return;
    _playbackTrace.record(
      'stall_detected',
      fields: <String, Object?>{
        ..._lineTraceFields(current!),
        'position_ms': _position.inMilliseconds,
        'buffer_ahead_ms': playbackBufferedAhead(
          position: _position,
          buffer: _buffer,
        ).inMilliseconds,
      },
    );
    _handleRuntimeLineFailure(current, message: '播放连续缓冲，正在尝试恢复当前线路。');
  }

  void _scheduleSingleBackupLookup({
    Duration delay = playbackBackupProbeDelay,
  }) {
    if (!mounted ||
        widget.request.offlineOnly ||
        !_usesProgressiveRuleLookup(widget.request.subject) ||
        _line == null ||
        _nextPlayableLine() != null ||
        _backupLookupDelayTimer != null ||
        _backupLookupInProgress ||
        _lineScanInProgress ||
        _lineLookupSubscription != null) {
      return;
    }
    _backupLookupDelayTimer = Timer(delay, () {
      _backupLookupDelayTimer = null;
      if (!mounted || _nextPlayableLine() != null) return;
      final canProbe = playbackShouldPrepareSingleBackup(
        appInForeground: _appInForeground,
        playing: _playing,
        buffering: _buffering,
        loading: _loadingLine,
        playbackFailed: _playbackFailed,
        hasAlternative: _nextPlayableLine() != null,
        position: _position,
        buffer: _buffer,
      );
      if (!canProbe) {
        if (_playing && _appInForeground) {
          _scheduleSingleBackupLookup(delay: const Duration(seconds: 4));
        }
        return;
      }
      unawaited(_prepareSingleBackupLine());
    });
  }

  Future<void> _prepareSingleBackupLine() async {
    final current = _line;
    if (!mounted ||
        current == null ||
        _backupLookupInProgress ||
        _nextPlayableLine() != null) {
      return;
    }
    final serial = ++_backupLookupSerial;
    final episodeId = _episode.id;
    final token = RulePlaybackCancellationToken();
    _backupLookupCancellationToken?.cancel();
    _backupLookupCancellationToken = token;
    _backupLookupInProgress = true;
    try {
      final snapshot = await ref
          .read(animeControllerProvider.notifier)
          .prepareSingleBackupForEpisode(
            widget.request.subject,
            _episode,
            currentLine: current,
            cancellationToken: token,
          );
      if (!mounted ||
          serial != _backupLookupSerial ||
          episodeId != _episode.id ||
          token.isCancelled ||
          snapshot.isEmpty) {
        return;
      }
      var merged = mergePlaybackLineSnapshot(
        currentLines: _lines,
        snapshotLines: snapshot,
      );
      merged = _preserveLoadedLineIfProbeDisagrees(merged);
      setState(() => _lines = merged);
      final backup = _nextPlayableLine();
      if (backup != null) {
        _playbackTrace.record('backup_ready', fields: _lineTraceFields(backup));
      }
    } catch (_) {
      // Backup preparation is best-effort and must never disturb playback.
    } finally {
      if (serial == _backupLookupSerial) {
        _backupLookupInProgress = false;
        if (identical(_backupLookupCancellationToken, token)) {
          _backupLookupCancellationToken = null;
        }
      }
    }
  }

  void _cancelSingleBackupLookup() {
    _backupLookupSerial++;
    _backupLookupDelayTimer?.cancel();
    _backupLookupDelayTimer = null;
    _backupLookupCancellationToken?.cancel();
    _backupLookupCancellationToken = null;
    _backupLookupInProgress = false;
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
    _cancelSingleBackupLookup();
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
            final previous = _line;
            final recoveryPosition = _currentRecoveryPosition;
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
            if (shouldOpen) {
              if (currentFailed) {
                _beginPlaybackRecovery(
                  target,
                  strategy: 'auto_switch',
                  previous: previous,
                  position: recoveryPosition,
                );
              }
              unawaited(
                _openLine(
                  target,
                  force: true,
                  resumePosition: recoveryPosition,
                ),
              );
            } else if (update.isComplete &&
                available.isEmpty &&
                (_playbackFailed || !_isPlayableLine(_line))) {
              _recordFinalPlaybackFailure(reason: 'source_scan_exhausted');
            }
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
              _lineLookupMessage = '查找线路失败：${_friendlyPlaybackError(error)}';
            });
            if (_playbackFailed || !_isPlayableLine(_line)) {
              _recordFinalPlaybackFailure(reason: 'source_scan_failed');
            }
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
            if (_availableLines(_lines).isEmpty &&
                (_playbackFailed || !_isPlayableLine(_line))) {
              _recordFinalPlaybackFailure(reason: 'source_scan_exhausted');
            }
          },
        );
    _lineLookupSubscription = subscription;
  }

  List<PlaybackLine> _preserveLoadedLineIfProbeDisagrees(
    List<PlaybackLine> lines,
  ) {
    return _lineController.preserveLoadedLineIfProbeDisagrees(
      lines: lines,
      currentLine: _line,
      loadedUrl: _loadedUrl,
      playbackFailed: _playbackFailed,
    );
  }

  PlaybackLine? _preferredPlayableLine(List<PlaybackLine> lines) {
    return _lineController.preferredPlayableLine(lines);
  }

  Future<void> _openLine(
    PlaybackLine requestedLine, {
    bool force = false,
    Duration? resumePosition,
  }) async {
    var line = requestedLine;
    _recoveryController.cancelCurrentLineRetry();
    if (!_isPlayableLine(line)) {
      await _player.stop();
      if (!mounted) return;
      setState(() {
        _loadedUrl = null;
        _loadingLine = false;
        _playbackFailed = true;
        _playerMessage = line.message ?? '这条线路没有返回可播放内容。';
      });
      return;
    }
    final requestedUrl = line.url!.trim();
    if (!force && _loadedUrl == requestedUrl && !_playbackFailed) return;
    final requestedResumePosition = playbackRecoveryPosition(
      resumePosition ?? _pendingInitialResumePosition ?? Duration.zero,
    );
    _sessionController.dispatch(
      PlaybackSessionEvent.openRequested(
        line.id,
        position: requestedResumePosition,
      ),
    );
    _nativeVideo.resumeSeek.cancel();
    final serial = ++_openLineSerial;
    _handledFailureOpenSerial = null;
    _playbackTrace.recordBufferingChanged(
      buffering: false,
      fields: const <String, Object?>{'outcome': 'line_changed'},
    );
    _playbackTrace.record(
      'line_open_requested',
      fields: _lineTraceFields(line),
    );
    _cancelSingleBackupLookup();
    _resetPlaybackStallWatchdog(
      position: Duration.zero,
      grace: const Duration(seconds: 5),
    );
    _webLoadTimer?.cancel();
    _nativeFirstFrameTimer?.cancel();
    _ignoreNativeErrorsUntil = null;
    _revealPlayerControls();
    _anime4kController.resetVideo();
    setState(() {
      _line = line;
      _loadingLine = true;
      _playbackFailed = false;
      _playerMessage = '正在确认这条线路可以正常播放…';
      _position = Duration.zero;
      _duration = Duration.zero;
      _buffer = Duration.zero;
    });
    if (!playbackLineCanStartImmediately(line)) {
      line = await ref
          .read(animeControllerProvider.notifier)
          .verifyPlaybackLine(
            line,
            forceRefresh: true,
            cancellationToken: _lineLookupCancellationToken,
          );
    }
    if (!mounted || serial != _openLineSerial) return;
    _lines = upsertPlaybackLine(_lines, line);
    if (!_isPlayableLine(line)) {
      _sessionController.dispatch(
        PlaybackSessionEvent.lineFailed(
          line.id,
          reason: 'verification_rejected',
          hasAlternative: _nextPlayableLine() != null,
        ),
      );
      _playbackTrace.record('line_rejected', fields: _lineTraceFields(line));
      _markLineFailure(line, definitive: true);
      setState(() {
        _line = line;
        _loadingLine = false;
        _playbackFailed = true;
        _playerMessage = '这条线路不可用，正在自动寻找其他可播线路…';
      });
      _startExpandedLineLookup(autoplay: true);
      unawaited(_tryAutoSwitchLine(resumePosition: requestedResumePosition));
      return;
    }
    final url = line.url!.trim();
    if (resumePosition == null && _pendingInitialResumePosition != null) {
      _pendingInitialResumePosition = null;
    }
    setState(() {
      _line = line;
      _loadedUrl = url;
      if (supportsWebStreamPlayer && shouldUseWebStreamPlayer(url)) {
        _position = requestedResumePosition;
      }
      _playerMessage = null;
    });
    if (supportsWebStreamPlayer && shouldUseWebStreamPlayer(url)) {
      if (!mounted || serial != _openLineSerial) return;
      _playbackTrace.record(
        'player_open_dispatched',
        fields: <String, Object?>{..._lineTraceFields(line), 'player': 'web'},
      );
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
          _sessionController.dispatch(
            PlaybackSessionEvent.softTimeout(hasAlternative: true),
          );
          _handleWebError(message: '7 秒内没有出画面，已尝试切换备用线路。');
          return;
        }
        _webLoadTimer = Timer(const Duration(seconds: 18), () {
          if (!mounted ||
              serial != _openLineSerial ||
              _loadedUrl != url ||
              !webPlaybackStartupTimedOut(waitingForReady: _loadingLine)) {
            return;
          }
          _sessionController.dispatch(
            PlaybackSessionEvent.hardTimeout(
              hasAlternative: _nextPlayableLine() != null,
            ),
          );
          _handleWebError(message: '长时间未能开始播放，已尝试切换其他线路。');
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
                buffer: _buffer,
                buffering: _buffering,
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
          _sessionController.dispatch(
            hardTimedOut
                ? PlaybackSessionEvent.hardTimeout(
                    hasAlternative: hasAlternative,
                  )
                : PlaybackSessionEvent.softTimeout(
                    hasAlternative: hasAlternative,
                  ),
          );
          _handleRuntimeLineFailure(
            line,
            message: hardTimedOut ? '长时间未能开始播放。' : '暂时没有出画面。',
          );
        });
      };
      scheduleNativeStartupCheck(nativeSoftTimeout, nativeSoftTimeout);
      final media = line.headers.isEmpty
          ? Media(url)
          : Media(url, httpHeaders: line.headers);
      _ignoreNativeErrorsUntil = DateTime.now().add(
        const Duration(milliseconds: 750),
      );
      _playbackTrace.record(
        'player_open_dispatched',
        fields: <String, Object?>{
          ..._lineTraceFields(line),
          'player': 'native',
        },
      );
      await _player.open(media, play: true);
      if (requestedResumePosition > Duration.zero) {
        _nativeVideo.resumeSeek.arm(
          openSerial: serial,
          position: requestedResumePosition,
        );
      }
      _refreshSuperResolutionShader();
      if (!mounted || serial != _openLineSerial) return;
      setState(() {
        _loadingLine = false;
        _playbackFailed = false;
        _playerMessage = null;
      });
    } catch (error) {
      if (!mounted || serial != _openLineSerial) return;
      _playbackTrace.record(
        'line_open_failed',
        fields: <String, Object?>{
          ..._lineTraceFields(line),
          'error_type': error.runtimeType.toString(),
        },
      );
      _nativeFirstFrameTimer?.cancel();
      _handleRuntimeLineFailure(
        line,
        message: '当前线路无法播放：${_friendlyPlaybackError(error)}',
      );
    }
  }

  void _clearLineFailure(String lineId) {
    _lineController.clearFailure(lineId);
  }

  bool _markLineFailure(PlaybackLine line, {bool definitive = false}) {
    return _lineController.markFailure(line, definitive: definitive);
  }

  void _handleRuntimeLineFailure(PlaybackLine line, {required String message}) {
    if (!mounted || _handledFailureOpenSerial == _openLineSerial) return;
    _handledFailureOpenSerial = _openLineSerial;
    _webLoadTimer?.cancel();
    _nativeFirstFrameTimer?.cancel();
    final resumePosition = _currentRecoveryPosition;
    final hasAlternative = _nextPlayableLine() != null;
    final shouldSwitch = _markLineFailure(
      line,
      definitive: shouldSwitchAfterPlaybackInterruption(
        position: resumePosition,
        hasAlternative: hasAlternative,
      ),
    );
    _sessionController.dispatch(
      PlaybackSessionEvent.lineFailed(
        line.id,
        reason: message,
        hasAlternative: hasAlternative,
      ),
    );
    _playbackTrace.record(
      'runtime_failure',
      fields: <String, Object?>{
        ..._lineTraceFields(line),
        'position_ms': resumePosition.inMilliseconds,
        'failure_count': _lineFailureCounts[line.id] ?? 0,
        'will_switch': shouldSwitch && _currentSettings.autoSwitchLine,
      },
    );
    _playbackTrace.recordBufferingChanged(
      buffering: false,
      fields: <String, Object?>{..._lineTraceFields(line), 'outcome': 'failed'},
    );
    setState(() {
      _loadingLine = false;
      _playbackFailed = true;
      _playing = false;
      _playerMessage = shouldSwitch
          ? (_currentSettings.autoSwitchLine
                ? '当前线路连续播放失败，正在自动切换备用线路…'
                : message)
          : '播放暂时中断，正在重试当前线路…';
    });
    if (!shouldSwitch) {
      _recoveryController.scheduleCurrentLineRetry(
        const Duration(milliseconds: 500),
        () async {
          if (!mounted ||
              _line?.id != line.id ||
              _lineFailureCounts[line.id] != 1) {
            return;
          }
          _beginPlaybackRecovery(
            line,
            strategy: 'current_line_retry',
            previous: line,
            position: resumePosition,
          );
          await _openLine(line, force: true, resumePosition: resumePosition);
        },
      );
      return;
    }
    if (!_currentSettings.autoSwitchLine) {
      _recordFinalPlaybackFailure(reason: 'auto_switch_disabled');
    }
    _startExpandedLineLookup(autoplay: true);
    unawaited(_tryAutoSwitchLine(resumePosition: resumePosition));
  }

  void _handlePlayerError(Object error) {
    final ignoreUntil = _ignoreNativeErrorsUntil;
    if (ignoreUntil != null && DateTime.now().isBefore(ignoreUntil)) {
      // stop/open can emit a delayed error from the previous media. The active
      // attempt still has its startup timer and will be judged independently.
      return;
    }
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
    if (!mounted) return;
    if (current != null) {
      _handleRuntimeLineFailure(
        current,
        message: '当前线路无法播放：${_friendlyPlaybackError(error)}',
      );
    }
  }

  Duration get _currentRecoveryPosition {
    return _nativeVideo.resumeSeek.recoveryPosition(_position);
  }

  Future<void> _tryAutoSwitchLine({Duration? resumePosition}) async {
    if (!_currentSettings.autoSwitchLine) return;
    await _recoveryController.runAutoSwitch(
      resumePosition: resumePosition,
      attempt: (targetResumePosition) async {
        if (!mounted || !_currentSettings.autoSwitchLine) return;
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
            _recordFinalPlaybackFailure(reason: 'no_backup_line');
          }
          return;
        }
        if (!mounted) return;
        final switchTarget = next;
        final previous = _line;
        _beginPlaybackRecovery(
          switchTarget,
          strategy: 'auto_switch',
          previous: previous,
          position: targetResumePosition,
        );
        setState(() {
          _line = switchTarget;
          _playerMessage =
              '当前线路失败，已切换到 ${playbackLineProviderLabel(switchTarget)}。';
        });
        await _openLine(
          switchTarget,
          force: true,
          resumePosition: targetResumePosition,
        );
      },
    );
  }

  PlaybackLine? _nextPlayableLine() {
    return _lineController.nextPlayableLine(currentLine: _line, lines: _lines);
  }

  Future<void> _togglePlayPause() async {
    _revealPlayerControls();
    if (!_isPlayableLine(_line)) {
      await _resolveLinesForCurrentEpisode();
      return;
    }
    if (_playbackFailed) {
      await _openLine(
        _line!,
        force: true,
        resumePosition: _currentRecoveryPosition,
      );
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
    _sessionController.dispatch(PlaybackSessionEvent.userSeek(position));
    _resetPlaybackStallWatchdog(
      position: position,
      grace: const Duration(seconds: 5),
    );
    if (_usesWebPlayer) {
      _webPlayerController.seek(position);
      setState(() => _position = position);
      return;
    }
    await _player.seek(position);
  }

  Future<void> _setVolume(double value) async {
    _revealPlayerControls();
    await _applyVolume(value);
  }

  Future<void> _setGestureVolume(double value) => _applyVolume(value);

  Future<void> _applyVolume(double value) async {
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
    _failedLineIds.clear();
    _lineFailureCounts.clear();
    _handledFailureOpenSerial = null;
    if (_isPlayableLine(_line)) {
      await _openLine(
        _line!,
        force: true,
        resumePosition: _currentRecoveryPosition,
      );
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
    _sessionController.dispatch(
      PlaybackSessionEvent.episodeChanged(episode.id),
    );
    _danmakuController.changeEpisode();
    _subtitleController.invalidatePendingAction();
    final playbackSerial = ++_openLineSerial;
    _webLoadTimer?.cancel();
    _nativeFirstFrameTimer?.cancel();
    _cancelSingleBackupLookup();
    _resetPlaybackStallWatchdog(
      position: Duration.zero,
      grace: const Duration(seconds: 5),
    );
    _failedLineIds.clear();
    _lineFailureCounts.clear();
    _handledFailureOpenSerial = null;
    _recoveryController.clearPendingAutoSwitch();
    _pendingInitialResumePosition = null;
    _nativeVideo.resumeSeek.cancel();
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
      _lineLookupInProgress = true;
      _playbackFailed = false;
      _position = Duration.zero;
      _duration = Duration.zero;
      _buffer = Duration.zero;
      _episodePanel = false;
    });
    _startPlaybackTrace();
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
    if (_line?.id != line.id) {
      _sessionController.dispatch(
        PlaybackSessionEvent.alternativeSelected(line.id),
      );
    }
    final resumePosition = _currentRecoveryPosition;
    _clearLineFailure(line.id);
    _handledFailureOpenSerial = null;
    _preferredProviderId = line.providerId;
    setState(() {
      _line = line;
      _linePanel = false;
      _playerMessage = null;
      _playbackFailed = false;
    });
    unawaited(_openLine(line, force: true, resumePosition: resumePosition));
  }

  Future<void> _pickLocalPlaybackFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const [
        'mp4',
        'mkv',
        'webm',
        'mov',
        'avi',
        'm3u8',
        'mpd',
      ],
    );
    final file = result?.files.singleOrNull;
    final path = file?.xFile.path.trim() ?? '';
    if (path.isEmpty || !mounted) return;
    final id = DateTime.now().microsecondsSinceEpoch;
    final line = PlaybackLine(
      id: 'local:$id',
      episodeId: _episode.id,
      providerId: 'local',
      providerName: '本地文件',
      title: file?.name ?? '本地视频',
      quality: '原始',
      format: _directPlaybackFormat(path),
      url: path,
      available: true,
    );
    setState(() {
      _lines = upsertPlaybackLine(_lines, line);
      _line = line;
      _linePanel = false;
      _playbackFailed = false;
      _playerMessage = null;
    });
    await _openLine(line, force: true);
  }

  Future<void> _openNetworkPlayback(
    String url,
    Map<String, String> headers,
  ) async {
    final value = url.trim();
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !const {'http', 'https'}.contains(uri.scheme.toLowerCase()) ||
        uri.host.isEmpty) {
      throw const FormatException('请输入完整的 http/https 视频地址');
    }
    final id = DateTime.now().microsecondsSinceEpoch;
    final line = PlaybackLine(
      id: 'network:$id',
      episodeId: _episode.id,
      providerId: 'network',
      providerName: '网络直链',
      title: uri.host,
      quality: '原始',
      format: _directPlaybackFormat(value),
      url: value,
      headers: headers,
      available: true,
    );
    if (!mounted) return;
    setState(() {
      _lines = upsertPlaybackLine(_lines, line);
      _line = line;
      _linePanel = false;
      _playbackFailed = false;
      _playerMessage = null;
    });
    await _openLine(line, force: true);
  }

  Future<void> _searchPlaybackLines() async {
    _failedLineIds.clear();
    _lineFailureCounts.clear();
    await _resolveLinesForCurrentEpisode(autoplay: false);
    if (!mounted) return;
    _startExpandedLineLookup(autoplay: false);
  }

  int get _currentEpisodeIndex => widget.request.episodes.indexWhere(
    (episode) => episode.id == _episode.id,
  );

  bool get _canPlayPreviousEpisode =>
      !widget.request.offlineOnly && _currentEpisodeIndex > 0;

  bool get _canPlayNextEpisode {
    if (widget.request.offlineOnly) return false;
    final index = _currentEpisodeIndex;
    return index >= 0 && index < widget.request.episodes.length - 1;
  }

  Future<void> _playPreviousEpisode() async {
    final index = _currentEpisodeIndex;
    if (widget.request.offlineOnly || index <= 0) return;
    _selectEpisode(widget.request.episodes[index - 1]);
  }

  Future<void> _playNextEpisode() async {
    final index = _currentEpisodeIndex;
    if (widget.request.offlineOnly) return;
    if (index < 0 || index >= widget.request.episodes.length - 1) return;
    _selectEpisode(widget.request.episodes[index + 1]);
  }

  Future<void> _setFullscreen(bool enabled) async {
    _revealPlayerControls();
    if (_fullscreen == enabled) return;
    bool changed;
    try {
      changed = await _appFullscreen.setEnabled(enabled);
    } catch (_) {
      changed = false;
    }
    if (!mounted) return;
    if (enabled && !changed) {
      _showPlayerToast('系统未允许进入全屏，请再次点击全屏按钮。');
      return;
    }
    if (enabled) {
      await _enterSystemFullscreen();
    } else {
      await _restoreSystemUi();
    }
    if (!mounted) return;
    setState(() {
      _fullscreen = enabled;
      if (!enabled) return;
      _episodePanel = false;
      _linePanel = false;
      _subtitlePanel = false;
      _danmakuPanel = false;
      _settingsPanel = false;
    });
  }

  Future<void> _enterSystemFullscreen() async {
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS)) {
      return;
    }
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  Future<void> _restoreSystemUi() async {
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS)) {
      return;
    }
    await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    await Future<void>.delayed(const Duration(milliseconds: 80));
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
    _cancelSingleBackupLookup();
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
    final result = await _subtitleController.select(candidate);
    if (!mounted) return;
    switch (result.status) {
      case SubtitleActionStatus.applied:
        setState(() => _subtitlePanel = false);
        _showPlayerToast('已加载字幕：${candidate.title}');
      case SubtitleActionStatus.unavailable:
        _showPlayerToast(result.message ?? '该字幕暂不可用');
      case SubtitleActionStatus.failed:
        _showPlayerToast('字幕加载失败：${_friendlyPlaybackError(result.error!)}');
      case SubtitleActionStatus.stale:
        break;
    }
  }

  Future<void> _disableSubtitle() async {
    final result = await _subtitleController.disable();
    if (!mounted) return;
    switch (result.status) {
      case SubtitleActionStatus.applied:
        setState(() => _subtitlePanel = false);
        _showPlayerToast('字幕已关闭');
      case SubtitleActionStatus.failed:
        _showPlayerToast('字幕关闭失败：${_friendlyPlaybackError(result.error!)}');
      case SubtitleActionStatus.unavailable:
      case SubtitleActionStatus.stale:
        break;
    }
  }

  Future<void> _loadDanmakuForCurrentEpisode() async {
    final episode = _episode;
    await _danmakuController.loadEpisode(
      episodeId: episode.id,
      load: () => ref
          .read(animeControllerProvider.notifier)
          .danmakuTimelineForEpisode(widget.request.subject, episode),
    );
  }

  void _sendLocalDanmaku(String text, {required DanmakuSettings settings}) {
    switch (_danmakuController.sendLocal(text, settings: settings)) {
      case LocalDanmakuSendResult.disabled:
        _showPlayerToast('请先在弹幕设置中启用弹幕');
      case LocalDanmakuSendResult.blocked:
        _showPlayerToast('内容命中了本地屏蔽词');
      case LocalDanmakuSendResult.accepted:
      case LocalDanmakuSendResult.empty:
        break;
    }
  }

  void _handleWebReady() {
    if (!mounted) return;
    _webLoadTimer?.cancel();
    _webLoadTimer = null;
    final current = _line;
    if (current != null) _clearLineFailure(current.id);
    setState(() {
      _loadingLine = false;
      _playbackFailed = false;
      _playerMessage = null;
    });
  }

  void _handleWebError({String? message}) {
    if (!mounted) return;
    final current = _line;
    if (current == null) return;
    _handleRuntimeLineFailure(
      current,
      message: message ?? '网页播放器暂时打不开当前线路，可能是网络限制或对方不允许网页直接播放。',
    );
  }

  void _handleWebPosition(Duration value) {
    if (!mounted) return;
    _notePlaybackProgress(value);
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
    _sessionController.dispatch(
      value
          ? PlaybackSessionEvent.playbackResumed()
          : PlaybackSessionEvent.playbackPaused(),
    );
    setState(() => _playing = value);
    _resetPlaybackStallWatchdog(
      grace: value ? const Duration(seconds: 2) : Duration.zero,
    );
    if (value) {
      _webLoadTimer?.cancel();
      _webLoadTimer = null;
      if (_line != null) {
        _clearLineFailure(_line!.id);
        _preferredProviderId = _line!.providerId;
        _recordFirstFrame(_line!);
      }
      _scheduleSingleBackupLookup();
    } else {
      _backupLookupDelayTimer?.cancel();
      _backupLookupDelayTimer = null;
    }
  }

  void _showPlayerToast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }
}
