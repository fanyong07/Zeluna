part of '../player_page.dart';

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

class _PlayerCanvas extends StatelessWidget {
  const _PlayerCanvas({
    required this.controller,
    required this.webPlayerController,
    required this.playbackGeneration,
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
    required this.onWebEnded,
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
  final int playbackGeneration;
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
  final VoidCallback onWebEnded;
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
                                  playbackGeneration: playbackGeneration,
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
                                  onWebEnded: onWebEnded,
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
                                          left: 0,
                                          right: 0,
                                          top: 0,
                                          height: compact ? 88 : 126,
                                          child: DecoratedBox(
                                            decoration: BoxDecoration(
                                              gradient:
                                                  AppOverlays.playerTopFade,
                                            ),
                                          ),
                                        ),
                                        Positioned(
                                          left: 0,
                                          right: 0,
                                          bottom: 0,
                                          height: compact ? 124 : 190,
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
                                        PlayerBottomBar(
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
    required this.playbackGeneration,
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
    required this.onWebEnded,
    required this.poster,
  });

  final VideoController controller;
  final WebStreamPlayerController webPlayerController;
  final int playbackGeneration;
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
  final VoidCallback onWebEnded;
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
        key: ValueKey<int>(playbackGeneration),
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
        onEnded: onWebEnded,
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
