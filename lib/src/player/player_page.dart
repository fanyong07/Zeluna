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

const _nativeResumeSeekMaxAttempts = 15;

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
  var _autoSwitching = false;
  var _autoSwitchRetryPending = false;
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
  Duration _lastPlaybackProgressPosition = Duration.zero;
  DateTime _lastPlaybackProgressAt = DateTime.now();
  DateTime? _lastStallRecoveryAt;
  DateTime? _stallWatchdogSuppressedUntil;
  Duration? _pendingInitialResumePosition;
  Duration? _pendingAutoSwitchResumePosition;
  Duration? _pendingNativeResumePosition;
  int? _pendingNativeResumeOpenSerial;
  var _nativeResumeSeekAttempts = 0;
  var _nativeResumeSeekInProgress = false;
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
  Timer? get _nativeResumeSeekTimer => _nativeVideo.resumeSeekTimer;
  set _nativeResumeSeekTimer(Timer? value) =>
      _nativeVideo.replaceResumeSeekTimer(value);
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
  String? get _preferredProviderId => _lineController.preferredProviderId;
  set _preferredProviderId(String? value) =>
      _lineController.preferredProviderId = value;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _nativeVideo = NativeVideoController();
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
          _handleNativeResumeProgress(value);
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
              _nudgePendingNativeResume(mediaReady: true);
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
    final now = DateTime.now();
    _lastPlaybackProgressPosition = position ?? _position;
    _lastPlaybackProgressAt = now;
    _stallWatchdogSuppressedUntil = grace > Duration.zero
        ? now.add(grace)
        : null;
  }

  void _notePlaybackProgress(Duration value) {
    final movedForward = value > _lastPlaybackProgressPosition;
    final jumpedBackward =
        _lastPlaybackProgressPosition - value > const Duration(seconds: 1);
    if (!movedForward && !jumpedBackward) return;
    _lastPlaybackProgressPosition = value;
    _lastPlaybackProgressAt = DateTime.now();
  }

  void _checkPlaybackStall() {
    if (!mounted ||
        _leaving ||
        _pendingNativeResumePosition != null ||
        _nativeResumeSeekInProgress) {
      return;
    }
    final now = DateTime.now();
    final suppressedUntil = _stallWatchdogSuppressedUntil;
    if (suppressedUntil != null && now.isBefore(suppressedUntil)) return;
    final lastRecovery = _lastStallRecoveryAt;
    final sinceLastRecovery = lastRecovery == null
        ? const Duration(days: 365)
        : now.difference(lastRecovery);
    if (!playbackShouldRecoverFromStall(
      appInForeground: _appInForeground,
      playing: _playing,
      buffering: _buffering,
      loading: _loadingLine,
      playbackFailed: _playbackFailed,
      position: _position,
      duration: _duration,
      buffer: _buffer,
      stalledFor: now.difference(_lastPlaybackProgressAt),
      sinceLastRecovery: sinceLastRecovery,
    )) {
      return;
    }
    final current = _line;
    if (!_isPlayableLine(current)) return;
    _lastStallRecoveryAt = now;
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
    _resetPlaybackStallWatchdog(grace: playbackStallRecoveryCooldown);
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
    _cancelPendingNativeResume();
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
        _armNativeResumeSeek(serial, requestedResumePosition);
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
    _failedLineIds.remove(lineId);
    _lineFailureCounts.remove(lineId);
  }

  bool _markLineFailure(PlaybackLine line, {bool definitive = false}) {
    final count = nextPlaybackLineFailureCount(
      _lineFailureCounts[line.id] ?? 0,
      definitive: definitive,
    );
    _lineFailureCounts[line.id] = count;
    if (!shouldRetryPlaybackLineAfterFailure(count)) {
      _failedLineIds.add(line.id);
    }
    return !shouldRetryPlaybackLineAfterFailure(count);
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
    final pending = _pendingNativeResumePosition;
    final position = pending != null && pending > _position
        ? pending
        : _position;
    return playbackRecoveryPosition(position);
  }

  void _cancelPendingNativeResume() {
    _nativeResumeSeekTimer?.cancel();
    _nativeResumeSeekTimer = null;
    _pendingNativeResumePosition = null;
    _pendingNativeResumeOpenSerial = null;
    _nativeResumeSeekAttempts = 0;
    _nativeResumeSeekInProgress = false;
  }

  void _armNativeResumeSeek(int serial, Duration position) {
    _pendingNativeResumePosition = position;
    _pendingNativeResumeOpenSerial = serial;
    _nativeResumeSeekAttempts = 0;
    _scheduleNativeResumeSeek(const Duration(milliseconds: 250));
  }

  void _scheduleNativeResumeSeek(Duration delay) {
    if (_pendingNativeResumePosition == null ||
        _nativeResumeSeekInProgress ||
        _nativeResumeSeekAttempts >= _nativeResumeSeekMaxAttempts ||
        _nativeResumeSeekTimer != null) {
      return;
    }
    _nativeResumeSeekTimer = Timer(delay, () {
      _nativeResumeSeekTimer = null;
      unawaited(_applyPendingNativeResume());
    });
  }

  Future<void> _applyPendingNativeResume() async {
    final position = _pendingNativeResumePosition;
    final serial = _pendingNativeResumeOpenSerial;
    if (!mounted ||
        position == null ||
        serial == null ||
        serial != _openLineSerial ||
        _nativeResumeSeekInProgress ||
        _nativeResumeSeekAttempts >= _nativeResumeSeekMaxAttempts) {
      return;
    }
    _nativeResumeSeekInProgress = true;
    _nativeResumeSeekAttempts++;
    try {
      await _player.seek(position);
    } catch (_) {
      // Some demuxers reject seeking until duration or the first frame exists.
    } finally {
      _nativeResumeSeekInProgress = false;
    }
    if (mounted &&
        serial == _openLineSerial &&
        _pendingNativeResumePosition != null) {
      _scheduleNativeResumeSeek(const Duration(seconds: 2));
    }
  }

  void _nudgePendingNativeResume({bool mediaReady = false}) {
    if (_pendingNativeResumeOpenSerial == _openLineSerial) {
      if (mediaReady) {
        _nativeResumeSeekTimer?.cancel();
        _nativeResumeSeekTimer = null;
        if (_nativeResumeSeekAttempts >= _nativeResumeSeekMaxAttempts) {
          _nativeResumeSeekAttempts = 0;
        }
      }
      _scheduleNativeResumeSeek(Duration.zero);
    }
  }

  void _handleNativeResumeProgress(Duration value) {
    final target = _pendingNativeResumePosition;
    if (target == null || _pendingNativeResumeOpenSerial != _openLineSerial) {
      return;
    }
    if (value >= target - const Duration(seconds: 2)) {
      _cancelPendingNativeResume();
      return;
    }
    if (value > Duration.zero) _nudgePendingNativeResume();
  }

  Future<void> _tryAutoSwitchLine({Duration? resumePosition}) async {
    if (!_currentSettings.autoSwitchLine) return;
    if (_autoSwitching) {
      _autoSwitchRetryPending = true;
      final pending = playbackRecoveryPosition(resumePosition ?? Duration.zero);
      if (pending > (_pendingAutoSwitchResumePosition ?? Duration.zero)) {
        _pendingAutoSwitchResumePosition = pending;
      }
      return;
    }
    final targetResumePosition = playbackRecoveryPosition(
      resumePosition ?? _pendingAutoSwitchResumePosition ?? Duration.zero,
    );
    _pendingAutoSwitchResumePosition = null;
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
    } finally {
      _autoSwitching = false;
      if (_autoSwitchRetryPending) {
        _autoSwitchRetryPending = false;
        final pendingResumePosition = _pendingAutoSwitchResumePosition;
        _pendingAutoSwitchResumePosition = null;
        scheduleMicrotask(
          () => _tryAutoSwitchLine(resumePosition: pendingResumePosition),
        );
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
    _autoSwitchRetryPending = false;
    _pendingInitialResumePosition = null;
    _pendingAutoSwitchResumePosition = null;
    _cancelPendingNativeResume();
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

class _LocalDanmakuOverlay extends StatelessWidget {
  const _LocalDanmakuOverlay({required this.entries, required this.settings});

  final List<LocalDanmakuEntry> entries;
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

  final LocalDanmakuEntry entry;
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

class _SuperResolutionPanelStatus extends StatelessWidget {
  const _SuperResolutionPanelStatus({
    required this.status,
    required this.onCompareStart,
    required this.onCompareEnd,
  });

  final Anime4KDisplayStatus status;
  final VoidCallback onCompareStart;
  final VoidCallback onCompareEnd;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.28)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
        child: Row(
          children: [
            Icon(
              status.previewingOriginal
                  ? Icons.visibility_outlined
                  : Icons.auto_awesome_rounded,
              size: 17,
              color: status.previewingOriginal
                  ? AppColors.theaterMuted
                  : AppColors.primary2,
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    status.title,
                    style: const TextStyle(
                      color: AppColors.theaterInk,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    status.detail,
                    style: const TextStyle(
                      color: AppColors.theaterMuted,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Semantics(
              button: true,
              label: '按住查看原画',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                onTapDown: (_) => onCompareStart(),
                onTapUp: (_) => onCompareEnd(),
                onTapCancel: onCompareEnd,
                onLongPressStart: (_) => onCompareStart(),
                onLongPressEnd: (_) => onCompareEnd(),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: status.previewingOriginal
                        ? AppColors.primary.withValues(alpha: 0.22)
                        : AppColors.theaterPanelHigh,
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                    child: Text(
                      '按住原画',
                      style: TextStyle(
                        color: AppColors.theaterInk,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SuperResolutionPanelNotice extends StatelessWidget {
  const _SuperResolutionPanelNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppStatusColors.probing.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: AppStatusColors.probing.withValues(alpha: 0.28),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.info_outline_rounded,
              size: 17,
              color: AppStatusColors.probing,
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(
                  color: AppColors.theaterInk,
                  fontSize: 11,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResponsivePlayerLayout extends StatelessWidget {
  const _ResponsivePlayerLayout({
    required this.portrait,
    required this.player,
    required this.subject,
    required this.episodes,
    required this.episode,
    required this.line,
    required this.lines,
    required this.failedLineIds,
    required this.loadingLines,
    required this.onEpisodePanel,
    required this.onEpisodeSelected,
    required this.onLinePanel,
    required this.onLineSelected,
  });

  final bool portrait;
  final Widget player;
  final AnimeSubject subject;
  final List<AnimeEpisode> episodes;
  final AnimeEpisode episode;
  final PlaybackLine? line;
  final List<PlaybackLine> lines;
  final Set<String> failedLineIds;
  final bool loadingLines;
  final VoidCallback onEpisodePanel;
  final ValueChanged<AnimeEpisode> onEpisodeSelected;
  final VoidCallback onLinePanel;
  final ValueChanged<PlaybackLine> onLineSelected;

  @override
  Widget build(BuildContext context) {
    if (!portrait) return player;
    return ColoredBox(
      key: const ValueKey('portraitPlayerLayout'),
      color: AppColors.theaterBg,
      child: Column(
        children: [
          AspectRatio(
            key: const ValueKey('portraitPlayerVideo'),
            aspectRatio: 16 / 9,
            child: player,
          ),
          const Divider(height: 1, color: AppColors.theaterBorder),
          Expanded(
            child: _PortraitPlayerDetails(
              subject: subject,
              episodes: episodes,
              episode: episode,
              line: line,
              lines: lines,
              failedLineIds: failedLineIds,
              loadingLines: loadingLines,
              onEpisodePanel: onEpisodePanel,
              onEpisodeSelected: onEpisodeSelected,
              onLinePanel: onLinePanel,
              onLineSelected: onLineSelected,
            ),
          ),
        ],
      ),
    );
  }
}

class _PortraitPlayerDetails extends StatefulWidget {
  const _PortraitPlayerDetails({
    required this.subject,
    required this.episodes,
    required this.episode,
    required this.line,
    required this.lines,
    required this.failedLineIds,
    required this.loadingLines,
    required this.onEpisodePanel,
    required this.onEpisodeSelected,
    required this.onLinePanel,
    required this.onLineSelected,
  });

  final AnimeSubject subject;
  final List<AnimeEpisode> episodes;
  final AnimeEpisode episode;
  final PlaybackLine? line;
  final List<PlaybackLine> lines;
  final Set<String> failedLineIds;
  final bool loadingLines;
  final VoidCallback onEpisodePanel;
  final ValueChanged<AnimeEpisode> onEpisodeSelected;
  final VoidCallback onLinePanel;
  final ValueChanged<PlaybackLine> onLineSelected;

  @override
  State<_PortraitPlayerDetails> createState() => _PortraitPlayerDetailsState();
}

class _PortraitPlayerDetailsState extends State<_PortraitPlayerDetails> {
  var _summaryExpanded = false;

  @override
  Widget build(BuildContext context) {
    final summary = _portraitPlayerSummary(widget.subject, widget.episode);
    final episodeIndex = widget.episodes.indexWhere(
      (item) => item.id == widget.episode.id,
    );
    final previewEpisodes = _portraitEpisodePreview(
      widget.episodes,
      widget.episode,
    );
    final availableLines = selectablePlaybackLinesForDisplay(
      widget.lines,
      failedLineIds: widget.failedLineIds,
    ).toList(growable: true);
    final selectedLine = widget.line;
    if (selectedLine != null &&
        selectedLine.available &&
        (selectedLine.url?.trim().isNotEmpty ?? false) &&
        !widget.failedLineIds.contains(selectedLine.id) &&
        !availableLines.any((item) => item.id == selectedLine.id)) {
      availableLines.insert(0, selectedLine);
    }
    final metadata = <String>[
      if (widget.subject.year != '未知') widget.subject.year,
      if (widget.subject.platform.trim().isNotEmpty) widget.subject.platform,
      ...widget.subject.categories
          .map((item) => item.name.trim())
          .where((item) => item.isNotEmpty)
          .take(3),
    ];
    return ListView(
      key: const ValueKey('portraitPlayerDetails'),
      padding: const EdgeInsets.only(bottom: 36),
      children: [
        _PortraitPlayerNavigation(
          episodeCount: widget.episodes.length,
          lineCount: availableLines.length,
          onEpisodePanel: widget.onEpisodePanel,
          onLinePanel: widget.onLinePanel,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.subject.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: AppColors.theaterInk,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                widget.episode.displayTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.primary2,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (metadata.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 7,
                  runSpacing: 7,
                  children: [
                    for (final item in metadata)
                      _PortraitMetadataChip(label: item),
                  ],
                ),
              ],
              const SizedBox(height: 14),
              Text(
                summary,
                maxLines: _summaryExpanded ? null : 3,
                overflow: _summaryExpanded
                    ? TextOverflow.visible
                    : TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.theaterMuted,
                  height: 1.55,
                ),
              ),
              if (summary.length > 72)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () =>
                        setState(() => _summaryExpanded = !_summaryExpanded),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.primary2,
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      minimumSize: const Size(0, 34),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(_summaryExpanded ? '收起' : '展开'),
                  ),
                ),
              const SizedBox(height: 18),
              _PortraitSectionCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _PortraitSectionHeader(
                      title: '选集 · ${widget.episode.displayTitle}',
                      trailing: widget.episodes.isEmpty
                          ? '0/0'
                          : '${episodeIndex < 0 ? 1 : episodeIndex + 1}/${widget.episodes.length}',
                      onTap: widget.onEpisodePanel,
                    ),
                    const Divider(height: 25, color: AppColors.theaterBorder),
                    if (previewEpisodes.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 4),
                        child: Text(
                          '暂无可选剧集',
                          style: TextStyle(color: AppColors.theaterMuted),
                        ),
                      )
                    else
                      SizedBox(
                        height: 142,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: previewEpisodes.length,
                          separatorBuilder: (context, index) =>
                              const SizedBox(width: 10),
                          itemBuilder: (context, index) {
                            final episode = previewEpisodes[index];
                            return _PortraitEpisodeCard(
                              subject: widget.subject,
                              episode: episode,
                              selected: episode.id == widget.episode.id,
                              onTap: () => widget.onEpisodeSelected(episode),
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _PortraitSectionCard(
                child: Column(
                  children: [
                    _PortraitSectionHeader(
                      title: '播放线路',
                      trailing: availableLines.isEmpty
                          ? (widget.loadingLines ? '查找中' : '暂无')
                          : '${availableLines.length} 条',
                      onTap: widget.onLinePanel,
                    ),
                    const Divider(height: 21, color: AppColors.theaterBorder),
                    if (availableLines.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(
                          children: [
                            if (widget.loadingLines) ...[
                              const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                              const SizedBox(width: 10),
                            ],
                            Expanded(
                              child: Text(
                                widget.loadingLines
                                    ? '正在查找并验证可用线路…'
                                    : '当前没有可直接播放的线路',
                                style: const TextStyle(
                                  color: AppColors.theaterMuted,
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: widget.onLinePanel,
                              child: const Text('管理'),
                            ),
                          ],
                        ),
                      )
                    else ...[
                      for (
                        var i = 0;
                        i < math.min(availableLines.length, 4);
                        i++
                      ) ...[
                        _PortraitPlaybackLineRow(
                          line: availableLines[i],
                          selected: availableLines[i].id == widget.line?.id,
                          onTap: () => widget.onLineSelected(availableLines[i]),
                        ),
                        if (i < math.min(availableLines.length, 4) - 1)
                          const Divider(
                            height: 1,
                            color: AppColors.theaterBorder,
                          ),
                      ],
                      if (availableLines.length > 4)
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: widget.onLinePanel,
                            child: Text('查看全部 ${availableLines.length} 条'),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PortraitPlayerNavigation extends StatelessWidget {
  const _PortraitPlayerNavigation({
    required this.episodeCount,
    required this.lineCount,
    required this.onEpisodePanel,
    required this.onLinePanel,
  });

  final int episodeCount;
  final int lineCount;
  final VoidCallback onEpisodePanel;
  final VoidCallback onLinePanel;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: AppColors.theaterBg,
        border: Border(bottom: BorderSide(color: AppColors.theaterBorder)),
      ),
      child: SizedBox(
        height: 50,
        child: Row(
          children: [
            const SizedBox(width: 10),
            const _PortraitNavigationItem(label: '简介', selected: true),
            _PortraitNavigationItem(
              label: '选集 $episodeCount',
              onTap: onEpisodePanel,
            ),
            _PortraitNavigationItem(label: '线路 $lineCount', onTap: onLinePanel),
          ],
        ),
      ),
    );
  }
}

class _PortraitNavigationItem extends StatelessWidget {
  const _PortraitNavigationItem({
    required this.label,
    this.selected = false,
    this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Expanded(
              child: Center(
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: selected
                        ? AppColors.primary2
                        : AppColors.theaterMuted,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  ),
                ),
              ),
            ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: selected ? 30 : 0,
              height: 3,
              decoration: BoxDecoration(
                color: AppColors.primary2,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PortraitMetadataChip extends StatelessWidget {
  const _PortraitMetadataChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.theaterPanelHigh,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.theaterBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: AppColors.theaterMuted,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _PortraitSectionCard extends StatelessWidget {
  const _PortraitSectionCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.theaterPanel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.theaterBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 13, 14, 14),
        child: child,
      ),
    );
  }
}

class _PortraitSectionHeader extends StatelessWidget {
  const _PortraitSectionHeader({
    required this.title,
    required this.trailing,
    required this.onTap,
  });

  final String title;
  final String trailing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: AppColors.theaterInk,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            trailing,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppColors.theaterMuted),
          ),
          const SizedBox(width: 2),
          const Icon(
            Icons.chevron_right_rounded,
            size: 20,
            color: AppColors.theaterMuted,
          ),
        ],
      ),
    );
  }
}

class _PortraitEpisodeCard extends StatelessWidget {
  const _PortraitEpisodeCard({
    required this.subject,
    required this.episode,
    required this.selected,
    required this.onTap,
  });

  final AnimeSubject subject;
  final AnimeEpisode episode;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 160,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(
                    color: selected
                        ? AppColors.primary2
                        : AppColors.theaterBorder,
                    width: selected ? 2 : 1,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      PosterArt(
                        coverUrl: episode.thumbnailUrl ?? subject.coverUrl,
                        title: episode.displayTitle,
                      ),
                      Positioned(
                        left: 6,
                        bottom: 5,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.68),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 3,
                            ),
                            child: Text(
                              episode.duration.trim().isEmpty
                                  ? '第${episode.number}集'
                                  : episode.duration,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 7),
            Text(
              episode.displayTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: selected ? AppColors.primary2 : AppColors.theaterInk,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              episode.airdate ?? '播出日期待补',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: AppColors.theaterFaint),
            ),
          ],
        ),
      ),
    );
  }
}

class _PortraitPlaybackLineRow extends StatelessWidget {
  const _PortraitPlaybackLineRow({
    required this.line,
    required this.selected,
    required this.onTap,
  });

  final PlaybackLine line;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final quality = playbackQualityChipLabel(line);
    final details = <String>[
      playbackLineLatencyLabel(line),
      ?quality,
    ].join(' · ');
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Row(
          children: [
            Icon(
              selected ? Icons.play_circle_fill_rounded : Icons.route_rounded,
              size: 21,
              color: selected ? AppColors.primary2 : AppColors.theaterMuted,
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    playbackLineProviderLabel(line),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: selected
                          ? AppColors.primary2
                          : AppColors.theaterInk,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    details,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: AppColors.theaterMuted,
                    ),
                  ),
                ],
              ),
            ),
            if (selected)
              const Icon(
                Icons.check_rounded,
                size: 19,
                color: AppColors.primary2,
              )
            else
              const Icon(
                Icons.chevron_right_rounded,
                size: 19,
                color: AppColors.theaterFaint,
              ),
          ],
        ),
      ),
    );
  }
}

String _portraitPlayerSummary(AnimeSubject subject, AnimeEpisode episode) {
  final subjectSummary = subject.summary.trim();
  if (subjectSummary.isNotEmpty && !subjectSummary.startsWith('暂无')) {
    return subjectSummary;
  }
  final episodeSummary = episode.description.trim();
  if (episodeSummary.isNotEmpty && !episodeSummary.startsWith('暂无')) {
    return episodeSummary;
  }
  return '这部作品暂时没有可用的简介。';
}

List<AnimeEpisode> _portraitEpisodePreview(
  List<AnimeEpisode> episodes,
  AnimeEpisode selected,
) {
  if (episodes.length <= 4) return episodes;
  final selectedIndex = episodes.indexWhere((item) => item.id == selected.id);
  final safeIndex = selectedIndex < 0 ? 0 : selectedIndex;
  final start = (safeIndex - 1).clamp(0, episodes.length - 4);
  return episodes.sublist(start, start + 4);
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
    required this.superResolutionActive,
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
    required this.onPreviousEpisode,
    required this.onNextEpisode,
    required this.onRewind,
    required this.onForward,
    required this.onSeek,
    required this.onMute,
    required this.onVolumeChanged,
    required this.onGestureVolumeChanged,
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
    required this.onToggleControls,
    required this.onTemporaryDoubleSpeedStart,
    required this.onTemporaryDoubleSpeedEnd,
    required this.onVideoViewportSize,
    required this.onChromeHotZoneChanged,
  });

  final VideoController controller;
  final WebStreamPlayerController webPlayerController;
  final AnimeSubject subject;
  final List<AnimeEpisode> episodes;
  final AnimeEpisode episode;
  final PlaybackLine? line;
  final PlaybackSettings settings;
  final bool superResolutionActive;
  final ExternalServiceSettings services;
  final DanmakuSettings danmaku;
  final List<DanmakuComment> remoteDanmaku;
  final List<LocalDanmakuEntry> localDanmaku;
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
  final Future<void> Function()? onPreviousEpisode;
  final Future<void> Function()? onNextEpisode;
  final Future<void> Function() onRewind;
  final Future<void> Function() onForward;
  final Future<void> Function(Duration) onSeek;
  final Future<void> Function() onMute;
  final ValueChanged<double> onVolumeChanged;
  final ValueChanged<double> onGestureVolumeChanged;
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
  final VoidCallback onToggleControls;
  final VoidCallback onTemporaryDoubleSpeedStart;
  final VoidCallback onTemporaryDoubleSpeedEnd;
  final ValueChanged<Size> onVideoViewportSize;
  final ValueChanged<bool> onChromeHotZoneChanged;

  @override
  Widget build(BuildContext context) {
    final chromeVisible = controlsVisible || !autoHideChrome;
    final safePadding = MediaQuery.paddingOf(context);
    final compact = _isMobilePlayerLayout(context);
    final edgeToEdge = fullscreen || compact;
    final horizontalSafe = math.max(safePadding.left, safePadding.right);
    final horizontalInset =
        (compact ? 10.0 : (fullscreen ? 28.0 : 18.0)) + horizontalSafe;
    final topInset = (fullscreen ? 10.0 : 12.0) + safePadding.top;
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: AppColors.theaterBg),
        Padding(
          padding: EdgeInsets.fromLTRB(
            edgeToEdge ? 0 : 18,
            edgeToEdge ? 0 : 14,
            edgeToEdge ? 0 : 18,
            edgeToEdge ? 0 : 18,
          ),
          child: Row(
            children: [
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: AppColors.theaterBg,
                    borderRadius: edgeToEdge
                        ? BorderRadius.zero
                        : BorderRadius.circular(8),
                    border: edgeToEdge
                        ? null
                        : Border.all(color: AppColors.theaterBorderBright),
                  ),
                  child: ClipRRect(
                    borderRadius: edgeToEdge
                        ? BorderRadius.zero
                        : BorderRadius.circular(8),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final pixelRatio = MediaQuery.devicePixelRatioOf(
                          context,
                        );
                        final physicalViewport = Size(
                          constraints.maxWidth * pixelRatio,
                          constraints.maxHeight * pixelRatio,
                        );
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          onVideoViewportSize(physicalViewport);
                        });
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
                          child: PlayerGestureSurface(
                            volume: muted ? 0 : volume,
                            position: position,
                            duration: duration,
                            onSeek: onSeek,
                            onVolumeChanged: onGestureVolumeChanged,
                            onTap: onToggleControls,
                            onDoubleTapLeft: onRewind,
                            onDoubleTapCenter: onPlayPause,
                            onDoubleTapRight: onForward,
                            onLongPressStart: onTemporaryDoubleSpeedStart,
                            onLongPressEnd: onTemporaryDoubleSpeedEnd,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                _StreamVideoSurface(
                                  controller: controller,
                                  webPlayerController: webPlayerController,
                                  line: line,
                                  settings: settings,
                                  superResolutionActive: superResolutionActive,
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
                                        const Positioned(
                                          left: 0,
                                          right: 0,
                                          top: 0,
                                          height: 126,
                                          child: DecoratedBox(
                                            decoration: BoxDecoration(
                                              gradient:
                                                  AppOverlays.playerTopFade,
                                            ),
                                          ),
                                        ),
                                        const Positioned(
                                          left: 0,
                                          right: 0,
                                          bottom: 0,
                                          height: 190,
                                          child: DecoratedBox(
                                            decoration: BoxDecoration(
                                              gradient:
                                                  AppOverlays.playerBottomFade,
                                            ),
                                          ),
                                        ),
                                        Positioned(
                                          left: horizontalInset,
                                          right: horizontalInset,
                                          top: topInset,
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
                                          onPreviousEpisode: onPreviousEpisode,
                                          onNextEpisode: onNextEpisode,
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

enum _PlayerGestureKind { brightness, volume, speed, seek }

enum PlayerDoubleTapAction { rewind, togglePlayPause, forward }

@visibleForTesting
PlayerDoubleTapAction playerDoubleTapActionForPosition(
  double dx,
  double width,
) {
  if (dx < width * 0.35) return PlayerDoubleTapAction.rewind;
  if (dx > width * 0.65) return PlayerDoubleTapAction.forward;
  return PlayerDoubleTapAction.togglePlayPause;
}

@visibleForTesting
class PlayerGestureSurface extends StatefulWidget {
  const PlayerGestureSurface({
    super.key,
    required this.volume,
    required this.onVolumeChanged,
    required this.onTap,
    required this.onDoubleTapLeft,
    required this.onDoubleTapCenter,
    required this.onDoubleTapRight,
    required this.onLongPressStart,
    required this.onLongPressEnd,
    required this.child,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.onSeek,
    this.mobileGesturesEnabled,
  });

  final double volume;
  final ValueChanged<double> onVolumeChanged;
  final VoidCallback onTap;
  final Future<void> Function() onDoubleTapLeft;
  final Future<void> Function() onDoubleTapCenter;
  final Future<void> Function() onDoubleTapRight;
  final VoidCallback onLongPressStart;
  final VoidCallback onLongPressEnd;
  final Widget child;
  final Duration position;
  final Duration duration;
  final Future<void> Function(Duration position)? onSeek;
  final bool? mobileGesturesEnabled;

  @override
  State<PlayerGestureSurface> createState() => _PlayerGestureSurfaceState();
}

class _PlayerGestureSurfaceState extends State<PlayerGestureSurface> {
  _PlayerGestureKind? _gestureKind;
  double _brightness = 0.5;
  double _gestureValue = 0;
  Offset? _doubleTapPosition;
  Timer? _overlayTimer;
  bool _longPressActive = false;
  bool _brightnessAvailable = true;
  bool _brightnessWasChanged = false;
  Duration _seekAnchor = Duration.zero;
  double _horizontalDragDx = 0;
  Duration _seekTarget = Duration.zero;

  bool get _supportsMobileGestures =>
      widget.mobileGesturesEnabled ??
      (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS));

  bool get _canSeekHorizontally =>
      _supportsMobileGestures &&
      widget.onSeek != null &&
      widget.duration > Duration.zero;

  @override
  void initState() {
    super.initState();
    if (_supportsMobileGestures) unawaited(_loadBrightness());
  }

  @override
  void dispose() {
    _overlayTimer?.cancel();
    if (_longPressActive) widget.onLongPressEnd();
    if (_brightnessWasChanged) {
      unawaited(ScreenBrightness.instance.resetApplicationScreenBrightness());
    }
    super.dispose();
  }

  Future<void> _loadBrightness() async {
    try {
      final value = await ScreenBrightness.instance.application;
      if (mounted) _brightness = value.clamp(0.0, 1.0);
    } catch (_) {
      _brightnessAvailable = false;
    }
  }

  bool _insideVideoGestureZone(double dy) {
    final height = context.size?.height ?? 0;
    if (height <= 0) return true;
    return dy >= 72 && dy <= height - 132;
  }

  void _handleVerticalStart(DragStartDetails details) {
    if (!_supportsMobileGestures ||
        !_insideVideoGestureZone(details.localPosition.dy)) {
      _gestureKind = null;
      return;
    }
    _overlayTimer?.cancel();
    final width = context.size?.width ?? MediaQuery.sizeOf(context).width;
    final leftSide = details.localPosition.dx < width / 2;
    _gestureKind = leftSide
        ? _PlayerGestureKind.brightness
        : _PlayerGestureKind.volume;
    _gestureValue = leftSide ? _brightness : widget.volume;
    HapticFeedback.selectionClick();
    setState(() {});
  }

  void _handleVerticalUpdate(DragUpdateDetails details) {
    final kind = _gestureKind;
    if (kind != _PlayerGestureKind.brightness &&
        kind != _PlayerGestureKind.volume) {
      return;
    }
    final height = math.max(context.size?.height ?? 1, 1);
    final delta = -(details.primaryDelta ?? 0) / height;
    if (kind == _PlayerGestureKind.brightness) {
      final next = (_gestureValue + delta * 1.35).clamp(0.02, 1.0);
      _gestureValue = next;
      _brightness = next;
      if (_brightnessAvailable) {
        unawaited(_setBrightness(next));
      }
    } else {
      final next = (_gestureValue + delta * 200).clamp(0.0, 200.0);
      _gestureValue = next;
      widget.onVolumeChanged(next);
    }
    setState(() {});
  }

  Future<void> _setBrightness(double value) async {
    try {
      await ScreenBrightness.instance.setApplicationScreenBrightness(value);
      _brightnessWasChanged = true;
    } catch (_) {
      _brightnessAvailable = false;
      if (mounted) setState(() {});
    }
  }

  void _handleVerticalEnd(DragEndDetails details) {
    if (_gestureKind != _PlayerGestureKind.brightness &&
        _gestureKind != _PlayerGestureKind.volume) {
      return;
    }
    _scheduleOverlayHide();
  }

  void _handleVerticalCancel() {
    if (_gestureKind != _PlayerGestureKind.brightness &&
        _gestureKind != _PlayerGestureKind.volume) {
      return;
    }
    _scheduleOverlayHide();
  }

  void _handleHorizontalStart(DragStartDetails details) {
    if (!_canSeekHorizontally ||
        !_insideVideoGestureZone(details.localPosition.dy)) {
      _gestureKind = null;
      return;
    }
    _overlayTimer?.cancel();
    _gestureKind = _PlayerGestureKind.seek;
    _seekAnchor = widget.position;
    _seekTarget = widget.position;
    _horizontalDragDx = 0;
    final durationMs = math.max(widget.duration.inMilliseconds, 1);
    _gestureValue = (_seekTarget.inMilliseconds / durationMs).clamp(0.0, 1.0);
    HapticFeedback.selectionClick();
    setState(() {});
  }

  void _handleHorizontalUpdate(DragUpdateDetails details) {
    if (_gestureKind != _PlayerGestureKind.seek || widget.onSeek == null) {
      return;
    }
    final width = math.max(context.size?.width ?? 1.0, 1.0);
    final durationMs = widget.duration.inMilliseconds;
    if (durationMs <= 0) return;
    _horizontalDragDx += details.primaryDelta ?? 0;
    // One full screen width scrubs the entire timeline.
    final deltaMs = ((_horizontalDragDx / width) * durationMs).round();
    final targetMs = (_seekAnchor.inMilliseconds + deltaMs).clamp(
      0,
      durationMs,
    );
    _seekTarget = Duration(milliseconds: targetMs);
    _gestureValue = targetMs / durationMs;
    unawaited(widget.onSeek!(_seekTarget));
    setState(() {});
  }

  void _handleHorizontalEnd(DragEndDetails details) {
    if (_gestureKind != _PlayerGestureKind.seek) return;
    _scheduleOverlayHide();
  }

  void _handleHorizontalCancel() {
    if (_gestureKind != _PlayerGestureKind.seek) return;
    _scheduleOverlayHide();
  }

  void _scheduleOverlayHide() {
    _overlayTimer?.cancel();
    _overlayTimer = Timer(const Duration(milliseconds: 520), () {
      if (mounted) {
        setState(() {
          _gestureKind = null;
          _horizontalDragDx = 0;
        });
      }
    });
  }

  void _handleDoubleTap() {
    final width = context.size?.width ?? MediaQuery.sizeOf(context).width;
    final dx = _doubleTapPosition?.dx ?? width / 2;
    HapticFeedback.selectionClick();
    final callback = switch (playerDoubleTapActionForPosition(dx, width)) {
      PlayerDoubleTapAction.rewind => widget.onDoubleTapLeft,
      PlayerDoubleTapAction.togglePlayPause => widget.onDoubleTapCenter,
      PlayerDoubleTapAction.forward => widget.onDoubleTapRight,
    };
    unawaited(callback());
  }

  void _handleLongPressStart(LongPressStartDetails details) {
    if (!_supportsMobileGestures ||
        !_insideVideoGestureZone(details.localPosition.dy)) {
      return;
    }
    _overlayTimer?.cancel();
    _longPressActive = true;
    _gestureKind = _PlayerGestureKind.speed;
    _gestureValue = 2;
    widget.onLongPressStart();
    setState(() {});
  }

  void _handleLongPressEnd() {
    if (!_longPressActive) return;
    _longPressActive = false;
    widget.onLongPressEnd();
    _scheduleOverlayHide();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const ValueKey('playerGestureSurface'),
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onDoubleTapDown: (details) => _doubleTapPosition = details.localPosition,
      onDoubleTap: _handleDoubleTap,
      onVerticalDragStart: _supportsMobileGestures
          ? _handleVerticalStart
          : null,
      onVerticalDragUpdate: _supportsMobileGestures
          ? _handleVerticalUpdate
          : null,
      onVerticalDragEnd: _supportsMobileGestures ? _handleVerticalEnd : null,
      onVerticalDragCancel: _supportsMobileGestures
          ? _handleVerticalCancel
          : null,
      onHorizontalDragStart: _canSeekHorizontally
          ? _handleHorizontalStart
          : null,
      onHorizontalDragUpdate: _canSeekHorizontally
          ? _handleHorizontalUpdate
          : null,
      onHorizontalDragEnd: _canSeekHorizontally ? _handleHorizontalEnd : null,
      onHorizontalDragCancel: _canSeekHorizontally
          ? _handleHorizontalCancel
          : null,
      onLongPressStart: _supportsMobileGestures ? _handleLongPressStart : null,
      onLongPressEnd: _supportsMobileGestures
          ? (_) => _handleLongPressEnd()
          : null,
      onLongPressCancel: _supportsMobileGestures ? _handleLongPressEnd : null,
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          IgnorePointer(
            child: _PlayerGestureIndicator(
              kind: _gestureKind,
              value: _gestureValue,
              brightnessAvailable: _brightnessAvailable,
              seekTarget: _seekTarget,
              seekDuration: widget.duration,
            ),
          ),
        ],
      ),
    );
  }
}

class _PlayerGestureIndicator extends StatelessWidget {
  const _PlayerGestureIndicator({
    required this.kind,
    required this.value,
    required this.brightnessAvailable,
    this.seekTarget = Duration.zero,
    this.seekDuration = Duration.zero,
  });

  final _PlayerGestureKind? kind;
  final double value;
  final bool brightnessAvailable;
  final Duration seekTarget;
  final Duration seekDuration;

  @override
  Widget build(BuildContext context) {
    final visible = kind != null;
    final isBrightness = kind == _PlayerGestureKind.brightness;
    final isSpeed = kind == _PlayerGestureKind.speed;
    final isSeek = kind == _PlayerGestureKind.seek;
    final progress = switch (kind) {
      _PlayerGestureKind.brightness => value,
      _PlayerGestureKind.volume => value / 200,
      _PlayerGestureKind.seek => value,
      _PlayerGestureKind.speed || null => 0.0,
    };
    final label = switch (kind) {
      _PlayerGestureKind.brightness =>
        brightnessAvailable ? '亮度 ${(value * 100).round()}%' : '当前设备不支持亮度调节',
      _PlayerGestureKind.volume => '音量 ${value.round()}%',
      _PlayerGestureKind.speed => '2.0x  松开恢复',
      _PlayerGestureKind.seek =>
        '${_durationLabel(seekTarget)} / ${_durationLabel(seekDuration)}',
      null => '',
    };
    return Center(
      child: AnimatedOpacity(
        key: const ValueKey('playerGestureIndicator'),
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 140),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppOverlays.theaterBar(0.88),
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: AppColors.theaterBorder),
          ),
          child: SizedBox(
            width: isSpeed || isSeek ? 176 : 156,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 15),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isSeek
                        ? Icons.timeline_rounded
                        : isSpeed
                        ? Icons.fast_forward_rounded
                        : isBrightness
                        ? Icons.brightness_6_rounded
                        : Icons.volume_up_rounded,
                    color: AppColors.theaterInk,
                    size: 30,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: AppColors.theaterInk,
                      fontWeight: FontWeight.w800,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  if (!isSpeed &&
                      (isSeek || brightnessAvailable || !isBrightness)) ...[
                    const SizedBox(height: 10),
                    LinearProgressIndicator(
                      value: progress.clamp(0.0, 1.0),
                      minHeight: 5,
                      borderRadius: BorderRadius.circular(999),
                      backgroundColor: AppColors.theaterFaint,
                      color: AppColors.primary2,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
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
        if (!hasStream || failed || loading)
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: AppOverlays.theaterBar(0.72),
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.theaterBorder),
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
                            color: AppColors.theaterInk,
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
                        color: AppOverlays.theaterBar(0.84),
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                        border: Border.all(color: AppColors.theaterBorder),
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
                              ?.copyWith(color: AppColors.theaterMuted),
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

BoxFit _fitForVideoScale(String value) {
  return switch (value) {
    '铺满' => BoxFit.cover,
    '拉伸' => BoxFit.fill,
    '原始' => BoxFit.none,
    _ => BoxFit.contain,
  };
}

@visibleForTesting
bool usesMobilePlayerLayoutForSize(Size size, TargetPlatform platform) {
  final mobilePlatform =
      platform == TargetPlatform.android || platform == TargetPlatform.iOS;
  return size.width < 640 || (mobilePlatform && size.shortestSide < 600);
}

@visibleForTesting
bool usesPortraitPlayerPageLayoutForSize(
  Size size,
  TargetPlatform platform, {
  required bool fullscreen,
}) {
  return !fullscreen &&
      size.height > size.width &&
      usesMobilePlayerLayoutForSize(size, platform);
}

bool _isMobilePlayerLayout(BuildContext context) =>
    usesMobilePlayerLayoutForSize(
      MediaQuery.sizeOf(context),
      defaultTargetPlatform,
    );

@visibleForTesting
SafeArea buildPlayerSafeArea({
  required bool fullscreen,
  required Widget child,
}) {
  return SafeArea(
    left: !fullscreen,
    top: !fullscreen,
    right: !fullscreen,
    bottom: !fullscreen,
    child: child,
  );
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
    final compact = _isMobilePlayerLayout(context);
    if (compact) {
      return SizedBox(
        height: 58,
        child: Row(
          children: [
            IconButton(
              tooltip: '返回',
              onPressed: onBack,
              icon: const Icon(
                Icons.arrow_back_rounded,
                color: AppColors.theaterInk,
                size: 30,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    subject.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: AppColors.theaterInk,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    [
                      episode.displayTitle,
                      if (playbackQualityChipLabel(line) != null)
                        playbackQualityChipLabel(line)!,
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.theaterMuted,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: '刷新线路',
              onPressed: onReload,
              icon: const Icon(
                Icons.refresh_rounded,
                color: AppColors.theaterInk,
              ),
            ),
            IconButton(
              tooltip: '截图',
              onPressed: onScreenshot,
              icon: const Icon(
                Icons.camera_alt_outlined,
                color: AppColors.theaterInk,
              ),
            ),
            IconButton(
              tooltip: '播放设置',
              onPressed: onSettings,
              icon: const Icon(
                Icons.more_vert_rounded,
                color: AppColors.theaterInk,
              ),
            ),
          ],
        ),
      );
    }
    return SizedBox(
      height: 52,
      child: Row(
        children: [
          IconButton(
            onPressed: onBack,
            icon: const Icon(
              Icons.arrow_back_rounded,
              color: AppColors.theaterInk,
            ),
          ),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    subject.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: AppColors.theaterInk,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                const SizedBox(width: 12),
                Text(
                  episode.displayTitle,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.theaterMuted,
                  ),
                ),
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
    required this.onPreviousEpisode,
    required this.onNextEpisode,
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
  final Future<void> Function()? onPreviousEpisode;
  final Future<void> Function()? onNextEpisode;
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
    final size = MediaQuery.sizeOf(context);
    final safePadding = MediaQuery.paddingOf(context);
    final compact = _isMobilePlayerLayout(context);
    final mobileLandscape = compact && size.width > size.height;
    final progress = _progress(position, duration);
    final bufferProgress = _progress(
      buffer > position ? buffer : position,
      duration,
    );
    final canSeek = duration > Duration.zero;
    return Positioned(
      left: (compact ? 10 : (fullscreen ? 28 : 18)) + safePadding.left,
      right: (compact ? 10 : (fullscreen ? 28 : 18)) + safePadding.right,
      bottom: (compact ? 10 : (fullscreen ? 18 : 12)) + safePadding.bottom,
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
            height: compact ? (mobileLandscape ? 42 : 96) : 52,
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
                    onPreviousEpisode: onPreviousEpisode,
                    onNextEpisode: onNextEpisode,
                    onMute: onMute,
                    onFullscreen: onFullscreen,
                    onEpisodePanel: onEpisodePanel,
                    onLinePanel: onLinePanel,
                    landscape: mobileLandscape,
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
                                ? AppColors.theaterInk
                                : AppColors.theaterFaint,
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
                                border: Border.all(
                                  color: AppColors.theaterBorder,
                                ),
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
                                          color: AppColors.theaterInk,
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
                          color: AppColors.theaterInk,
                        ),
                        label: const Text(
                          '选集',
                          style: TextStyle(color: AppColors.theaterInk),
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
                                ? AppColors.theaterInk
                                : AppColors.theaterFaint,
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
                          style: const TextStyle(color: AppColors.theaterInk),
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
                color: AppColors.theaterInk,
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
    required this.onPreviousEpisode,
    required this.onNextEpisode,
    required this.onMute,
    required this.onFullscreen,
    required this.onEpisodePanel,
    required this.onLinePanel,
    required this.landscape,
  });

  final PlaybackLine? line;
  final PlaybackSettings settings;
  final bool playing;
  final bool buffering;
  final bool loadingLine;
  final bool fullscreen;
  final bool muted;
  final Future<void> Function() onPlayPause;
  final Future<void> Function()? onPreviousEpisode;
  final Future<void> Function()? onNextEpisode;
  final Future<void> Function() onMute;
  final Future<void> Function() onFullscreen;
  final VoidCallback onEpisodePanel;
  final VoidCallback onLinePanel;
  final bool landscape;

  @override
  Widget build(BuildContext context) {
    final compactTextButtonStyle = TextButton.styleFrom(
      foregroundColor: AppColors.theaterInk,
      minimumSize: const Size(0, 40),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
      textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
    );
    if (landscape) {
      return Row(
        children: [
          _ControlIconButton(
            icon: Icons.skip_previous_rounded,
            tooltip: onPreviousEpisode == null ? '已经是第一集' : '上一集',
            onPressed: onPreviousEpisode,
            size: 25,
            compact: true,
          ),
          const SizedBox(width: 2),
          _ControlIconButton(
            icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            tooltip: playing ? '暂停' : '播放',
            size: 32,
            busy: loadingLine || buffering,
            onPressed: onPlayPause,
            compact: true,
          ),
          const SizedBox(width: 2),
          _ControlIconButton(
            icon: Icons.skip_next_rounded,
            tooltip: onNextEpisode == null ? '已经是最后一集' : '下一集',
            onPressed: onNextEpisode,
            size: 25,
            compact: true,
          ),
          const Spacer(),
          _ControlIconButton(
            icon: muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
            tooltip: muted ? '取消静音' : '静音',
            onPressed: onMute,
            size: 24,
            compact: true,
          ),
          const SizedBox(width: 2),
          TextButton(
            onPressed: onEpisodePanel,
            style: compactTextButtonStyle,
            child: const Text('选集'),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 152),
            child: TextButton(
              onPressed: onLinePanel,
              style: compactTextButtonStyle,
              child: Text(
                line == null ? '线路' : playbackLineProviderLabel(line!),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          const SizedBox(width: 2),
          _ControlIconButton(
            icon: fullscreen
                ? Icons.fullscreen_exit_rounded
                : Icons.fullscreen_rounded,
            tooltip: fullscreen ? '退出全屏' : '全屏',
            onPressed: onFullscreen,
            size: 27,
            compact: true,
          ),
        ],
      );
    }
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _ControlIconButton(
              icon: Icons.skip_previous_rounded,
              tooltip: onPreviousEpisode == null ? '已经是第一集' : '上一集',
              onPressed: onPreviousEpisode,
              size: 25,
              compact: true,
            ),
            _ControlIconButton(
              icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              tooltip: playing ? '暂停' : '播放',
              size: 34,
              busy: loadingLine || buffering,
              onPressed: onPlayPause,
              compact: true,
            ),
            _ControlIconButton(
              icon: Icons.skip_next_rounded,
              tooltip: onNextEpisode == null ? '已经是最后一集' : '下一集',
              onPressed: onNextEpisode,
              size: 25,
              compact: true,
            ),
            _ControlIconButton(
              icon: muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
              tooltip: muted ? '取消静音' : '静音',
              onPressed: onMute,
              size: 24,
              compact: true,
            ),
            _ControlIconButton(
              icon: fullscreen
                  ? Icons.fullscreen_exit_rounded
                  : Icons.fullscreen_rounded,
              tooltip: fullscreen ? '退出全屏' : '全屏',
              onPressed: onFullscreen,
              size: 27,
              compact: true,
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
                style: compactTextButtonStyle,
                icon: const Icon(Icons.alt_route_rounded, size: 16),
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
                style: compactTextButtonStyle,
                icon: const Icon(Icons.video_library_outlined, size: 16),
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
                            border: Border.all(color: AppColors.theaterBorder),
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
                    left: (thumbX - 4.5).clamp(0.0, width - 9),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      width: enabled ? 9 : 0,
                      height: enabled ? 9 : 0,
                      decoration: BoxDecoration(
                        // High-contrast scrubber knob on the video frame.
                        color: AppColors.theaterInk,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.theaterBg.withValues(alpha: 0.55),
                            blurRadius: 6,
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
      Rect.fromLTWH(0, centerY - 1.5, size.width, 3),
      const Radius.circular(999),
    );
    // High-contrast track on video is intentional (theater chrome on pixels).
    final background = Paint()
      ..color = AppColors.theaterInk.withValues(alpha: enabled ? 0.24 : 0.12);
    final cache = Paint()
      ..color = AppColors.theaterInk.withValues(alpha: enabled ? 0.48 : 0.22);
    final active = Paint()..color = AppColors.theaterInk;

    canvas.drawRRect(trackRect, background);
    if (buffered > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0, centerY - 1.5, size.width * buffered, 3),
          const Radius.circular(999),
        ),
        cache,
      );
    }
    if (played > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0, centerY - 1.5, size.width * played, 3),
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
    this.compact = false,
  });

  final IconData icon;
  final String tooltip;
  final Future<void> Function()? onPressed;
  final double size;
  final bool busy;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        constraints: compact
            ? const BoxConstraints.tightFor(width: 40, height: 40)
            : null,
        visualDensity: compact ? VisualDensity.compact : null,
        icon: busy
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                icon,
                color: onPressed == null
                    ? AppColors.theaterFaint
                    : AppColors.theaterInk,
                size: size,
              ),
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
      ? '正在确认哪些线路可以流畅播放$progress…'
      : '正在查找可用播放线路$progress…';
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
      return '这个直播暂时无法打开。请稍后再试，或检查相关扩展是否已开启。';
    }
    if (source.startsWith('archive:') ||
        source.startsWith('peertube:') ||
        source.startsWith('commons:')) {
      return '这个公开视频暂时没有可播文件，可能还在处理、已下架或暂时访问不了。';
    }
    if (isMetadataOnly) {
      return '目前只有作品资料，还没有找到可以播放的线路。';
    }
    return '还没有找到适合这部作品的播放线路。可在「扩展来源」里添加更多来源后再试。';
  }
  if (isMetadataOnly) {
    return '已检查 ${lines.length} 条候选线路，但暂时都不能播放。';
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
    return '找到了 $backendCount 条候选线路，但当前网络下无法打开视频。请检查网络或代理后重试。';
  }
  final deadCount = unavailableLines
      .where((line) => (line.message ?? '').contains('视频 CDN'))
      .length;
  if (deadCount > 0) {
    return '找到 $total 条线路，其中 $deadCount 条已失效或连接超时，暂时不能播放。';
  }
  return '找到 $total 条线路，但需要额外验证或当前环境不支持，暂时无法直接播放。';
}

String _friendlyPlaybackError(Object error) {
  final text = error.toString();
  if (text.contains('TimeoutException')) return '连接超时';
  if (text.contains('SocketException')) return '网络不可用，或对方暂时无法访问';
  if (text.contains('HTTP 403') || text.contains('403')) return '对方拒绝了访问';
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
                            ? AppColors.primary2
                            : AppColors.theaterInk,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Text(
                      episode.airdate ?? '播出日期待补',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: AppColors.theaterMuted,
                      ),
                    ),
                    Text(
                      episode.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: AppColors.theaterMuted,
                      ),
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

enum _PlaybackSourceMode { lines, local, network, search }

class PlaybackSourcePanel extends StatefulWidget {
  const PlaybackSourcePanel({
    super.key,
    required this.selected,
    required this.lines,
    required this.failedLineIds,
    required this.scanning,
    required this.completedRules,
    required this.totalRules,
    required this.onSelected,
    required this.onPickLocal,
    required this.onOpenNetwork,
    required this.onSearch,
  });

  final PlaybackLine? selected;
  final List<PlaybackLine> lines;
  final Set<String> failedLineIds;
  final bool scanning;
  final int completedRules;
  final int totalRules;
  final ValueChanged<PlaybackLine> onSelected;
  final Future<void> Function() onPickLocal;
  final Future<void> Function(String url, Map<String, String> headers)
  onOpenNetwork;
  final Future<void> Function() onSearch;

  @override
  State<PlaybackSourcePanel> createState() => _LinePanelState();
}

class _LinePanelState extends State<PlaybackSourcePanel> {
  final _networkUrl = TextEditingController();
  final _networkHeaders = TextEditingController();
  _PlaybackSourceMode _mode = _PlaybackSourceMode.lines;
  bool _working = false;
  String? _error;

  @override
  void dispose() {
    _networkUrl.dispose();
    _networkHeaders.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
          child: _LineModeBar(
            selected: _mode,
            onSelected: (mode) => setState(() {
              _mode = mode;
              _error = null;
            }),
          ),
        ),
        Expanded(child: _modeBody(context)),
      ],
    );
  }

  Widget _modeBody(BuildContext context) {
    return switch (_mode) {
      _PlaybackSourceMode.lines => _LinePanelBody(
        lines: widget.lines,
        selected: widget.selected,
        failedLineIds: widget.failedLineIds,
        scanning: widget.scanning,
        completedRules: widget.completedRules,
        totalRules: widget.totalRules,
        onSelected: widget.onSelected,
      ),
      _PlaybackSourceMode.local => _sourceAction(
        context,
        icon: Icons.folder_open_rounded,
        title: '播放本地视频',
        message: '选择设备中的 MP4、MKV、WebM、HLS 或 DASH 文件，不会上传文件。',
        buttonLabel: '选择视频文件',
        onPressed: _pickLocal,
      ),
      _PlaybackSourceMode.network => _networkSource(context),
      _PlaybackSourceMode.search => _sourceAction(
        context,
        icon: Icons.manage_search_rounded,
        title: '重新搜索播放线路',
        message: widget.scanning
            ? '正在检查可用来源：${widget.completedRules}/${widget.totalRules}'
            : '重新查找本集可用的播放线路，并确认能否正常打开。',
        buttonLabel: widget.scanning ? '正在搜索' : '搜索全部线路',
        onPressed: widget.scanning ? null : _search,
      ),
    };
  }

  Widget _sourceAction(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String message,
    required String buttonLabel,
    required Future<void> Function()? onPressed,
  }) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 100),
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: AppColors.theaterPanelHigh,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.theaterBorder),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Icon(
                  icon,
                  size: 42,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 14),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: AppColors.theaterInk,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.theaterMuted,
                    height: 1.5,
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: _working || onPressed == null ? null : onPressed,
                  icon: _working
                      ? const SizedBox.square(
                          dimension: 17,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(icon, size: 19),
                  label: Text(_working ? '处理中' : buttonLabel),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _networkSource(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 100),
      children: [
        TextField(
          key: const ValueKey('lineNetworkUrl'),
          controller: _networkUrl,
          keyboardType: TextInputType.url,
          minLines: 2,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: '视频直链',
            hintText: 'https://example.com/video.m3u8',
            prefixIcon: Icon(Icons.link_rounded),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('lineNetworkHeaders'),
          controller: _networkHeaders,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: '请求头（可选，每行一个）',
            hintText: 'Referer: https://example.com/\nUser-Agent: ...',
            prefixIcon: Icon(Icons.http_rounded),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: 16),
        FilledButton.icon(
          key: const ValueKey('lineNetworkPlay'),
          onPressed: _working ? null : _openNetwork,
          icon: _working
              ? const SizedBox.square(
                  dimension: 17,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.play_arrow_rounded),
          label: Text(_working ? '正在打开' : '播放网络地址'),
        ),
      ],
    );
  }

  Future<void> _pickLocal() async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await widget.onPickLocal();
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyPlaybackError(error));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _openNetwork() async {
    final url = _networkUrl.text.trim();
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !const {'http', 'https'}.contains(uri.scheme.toLowerCase()) ||
        uri.host.isEmpty) {
      setState(() => _error = '请输入完整的 http/https 视频地址');
      return;
    }
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await widget.onOpenNetwork(
        url,
        _parseNetworkHeaders(_networkHeaders.text),
      );
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyPlaybackError(error));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _search() async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await widget.onSearch();
      if (mounted) setState(() => _mode = _PlaybackSourceMode.lines);
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyPlaybackError(error));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Map<String, String> _parseNetworkHeaders(String text) {
    final result = <String, String>{};
    for (final line in text.split(RegExp(r'[\r\n]+'))) {
      final separator = line.indexOf(':');
      if (separator <= 0) continue;
      final name = line.substring(0, separator).trim();
      final value = line.substring(separator + 1).trim();
      if (name.isNotEmpty && value.isNotEmpty) result[name] = value;
    }
    return result;
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
    final displayLines = allPlaybackLinesForDisplay(lines);
    final playableCount = lines.where((line) => line.available).length;
    final progress = totalRules <= 0 ? '' : '（$completedRules/$totalRules）';
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 110),
      children: [
        if (scanning || displayLines.isNotEmpty) ...[
          _PanelInlineStatus(
            loading: scanning,
            text: scanning
                ? '正在查找可播放线路$progress · 已确认 $playableCount 条可播'
                : '共 ${displayLines.length} 个来源 · $playableCount 条可播',
          ),
          const SizedBox(height: 12),
        ],
        if (displayLines.isEmpty && scanning)
          const Center(child: CircularProgressIndicator())
        else if (displayLines.isEmpty)
          _PanelEmpty(
            title: '当前没有可播放线路',
            message: lines.isEmpty
                ? '仍在查找中，目前还没有确认可播的线路。'
                : _unavailableLinesMessage(lines),
          )
        else
          Material(
            color: AppColors.theaterPanelHigh,
            borderRadius: BorderRadius.circular(10),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < displayLines.length; i++) ...[
                  _LineTile(
                    key: ValueKey(displayLines[i].id),
                    index: i,
                    line: displayLines[i],
                    selected: selected?.id == displayLines[i].id,
                    runtimeFailed: failedLineIds.contains(displayLines[i].id),
                    onTap: displayLines[i].available
                        ? () => onSelected(displayLines[i])
                        : null,
                  ),
                  if (i != displayLines.length - 1)
                    const Divider(
                      height: 1,
                      indent: 12,
                      endIndent: 12,
                      color: AppColors.theaterBorder,
                    ),
                ],
              ],
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
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppStatusColors.probing,
                ),
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
    return AppEmptyState(
      onTheater: true,
      compact: true,
      icon: Icons.inbox_outlined,
      title: title,
      message: message,
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
        color: AppColors.theaterPanelHigh,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.theaterBorder),
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
                color: AppStatusColors.available,
              ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: AppColors.theaterMuted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LineModeBar extends StatelessWidget {
  const _LineModeBar({required this.selected, required this.onSelected});

  final _PlaybackSourceMode selected;
  final ValueChanged<_PlaybackSourceMode> onSelected;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.theaterPanelHigh,
        borderRadius: BorderRadius.circular(8),
      ),
      child: SizedBox(
        height: 48,
        child: Row(
          children: [
            _mode(_PlaybackSourceMode.lines, Icons.alt_route_rounded, '线路'),
            _mode(_PlaybackSourceMode.local, Icons.folder_rounded, '本地'),
            _mode(_PlaybackSourceMode.network, Icons.link_rounded, '直链'),
            _mode(_PlaybackSourceMode.search, Icons.search_rounded, '搜索'),
          ],
        ),
      ),
    );
  }

  Widget _mode(_PlaybackSourceMode mode, IconData icon, String label) {
    return Expanded(
      child: _ModeItem(
        icon,
        label,
        selected: selected == mode,
        onTap: () => onSelected(mode),
      ),
    );
  }
}

class _ModeItem extends StatelessWidget {
  const _ModeItem(
    this.icon,
    this.label, {
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.all(4),
      child: Material(
        color: selected ? accent.withValues(alpha: 0.18) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          key: ValueKey('playbackSourceMode:$label'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                color: selected ? accent : AppColors.theaterMuted,
                size: 19,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: selected ? accent : AppColors.theaterMuted,
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                ),
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
    required this.runtimeFailed,
    required this.onTap,
  });

  final int index;
  final PlaybackLine line;
  final bool selected;
  final bool runtimeFailed;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final latency = runtimeFailed
        ? '可重试'
        : line.available
        ? playbackLineLatencyLabel(line)
        : line.requiresClientProbe
        ? playbackLineLatencyLabel(line)
        : playbackLineFailureLabel(line);
    final latencyColor = line.requiresClientProbe
        ? AppStatusColors.probing
        : line.available && !runtimeFailed
        ? line.latency == null
              ? AppStatusColors.probing
              : AppStatusColors.available
        : runtimeFailed
        ? AppStatusColors.probing
        : AppStatusColors.failed;
    final accent = AppStatusColors.selected;
    final provider = playbackLineProviderLabel(line);
    final detail = line.title.trim();
    final metadata = playbackLineMediaLabel(line);
    return Material(
      color: selected ? accent.withValues(alpha: 0.12) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(
            children: [
              SizedBox(
                width: 30,
                child: Text(
                  '${index + 1}',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: selected ? accent : AppColors.theaterMuted,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          provider,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(
                                color: selected ? accent : AppColors.theaterInk,
                                fontWeight: FontWeight.w800,
                              ),
                        ),
                        if (detail.isNotEmpty && detail != provider)
                          Expanded(
                            child: Text(
                              ' · $detail',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(
                                    color: selected
                                        ? accent
                                        : AppColors.theaterInk,
                                    fontWeight: FontWeight.w800,
                                  ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      line.available
                          ? line.url ?? line.message ?? '没有返回播放地址'
                          : line.message ?? line.url ?? '没有返回播放地址',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppColors.theaterFaint,
                      ),
                    ),
                    if (line.available && metadata.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        metadata,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppColors.theaterMuted,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    latency,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: latencyColor,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 5),
                  if (selected)
                    Text(
                      '当前',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: accent,
                        fontWeight: FontWeight.w800,
                      ),
                    )
                  else
                    Icon(
                      line.requiresClientProbe
                          ? Icons.schedule_rounded
                          : line.available
                          ? Icons.chevron_right_rounded
                          : Icons.block_rounded,
                      color: AppColors.theaterFaint,
                      size: 19,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _directPlaybackFormat(String value) {
  final path = value.toLowerCase().split('?').first;
  if (path.endsWith('.m3u8')) return 'HLS';
  if (path.endsWith('.mpd')) return 'DASH';
  if (path.endsWith('.mkv')) return 'MKV';
  if (path.endsWith('.webm')) return 'WebM';
  if (path.endsWith('.mov')) return 'MOV';
  if (path.endsWith('.avi')) return 'AVI';
  return 'MP4/媒体';
}

class _PlayerFunctionPage extends StatelessWidget {
  const _PlayerFunctionPage({
    required this.title,
    required this.child,
    required this.onClose,
  });

  final String title;
  final Widget child;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final sheetWidth = playerFunctionPanelWidthForSize(size);
    final theme = Theme.of(context);
    final panelTheme = theme.copyWith(
      textTheme: theme.textTheme.apply(fontSizeFactor: 0.88),
    );
    return PlayerPanelDismissLayer(
      onDismiss: onClose,
      panel: Align(
        alignment: Alignment.centerRight,
        child: Material(
          color: AppColors.theaterBg,
          elevation: 0,
          shape: const Border(left: BorderSide(color: AppColors.theaterBorder)),
          clipBehavior: Clip.antiAlias,
          child: Theme(
            data: panelTheme,
            child: SizedBox(
              width: sheetWidth,
              height: size.height,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (title.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 6, 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              style: panelTheme.textTheme.titleLarge?.copyWith(
                                color: AppColors.theaterInk,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: '关闭',
                            onPressed: onClose,
                            constraints: const BoxConstraints.tightFor(
                              width: 40,
                              height: 40,
                            ),
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(
                              Icons.close_rounded,
                              size: 20,
                              color: AppColors.theaterInk,
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
        ),
      ),
    );
  }
}

@visibleForTesting
double playerFunctionPanelWidthForSize(Size size) {
  if (size.height >= size.width) return size.width;
  final minimum = math.min(220.0, size.width);
  final maximum = math.min(520.0, size.width);
  return (size.width * 0.30).clamp(minimum, maximum).toDouble();
}

@visibleForTesting
class PlayerPanelDismissLayer extends StatelessWidget {
  const PlayerPanelDismissLayer({
    super.key,
    required this.panel,
    required this.onDismiss,
  });

  final Widget panel;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Semantics(
          button: true,
          label: '点击播放器区域关闭侧边面板',
          child: GestureDetector(
            key: const ValueKey('playerPanelDismissBarrier'),
            behavior: HitTestBehavior.opaque,
            onTap: onDismiss,
            child: const SizedBox.expand(),
          ),
        ),
        panel,
      ],
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
        icon: Icon(icon, color: AppColors.theaterInk),
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
        color: AppOverlays.theaterBar(0.72),
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        child: Text(text, style: const TextStyle(color: AppColors.theaterInk)),
      ),
    );
  }
}
