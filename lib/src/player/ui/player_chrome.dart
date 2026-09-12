part of '../player_page.dart';

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
    final compact = usesCompactPlayerBottomControlsForSize(
      MediaQuery.sizeOf(context),
      defaultTargetPlatform,
    );
    if (compact) {
      final densePortrait =
          MediaQuery.sizeOf(context).height > MediaQuery.sizeOf(context).width;
      final iconButtonStyle = densePortrait
          ? IconButton.styleFrom(
              minimumSize: const Size(34, 34),
              fixedSize: const Size(34, 34),
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
            )
          : null;
      return SizedBox(
        height: densePortrait ? 46 : 58,
        child: Row(
          children: [
            IconButton(
              tooltip: '返回',
              onPressed: onBack,
              style: iconButtonStyle,
              icon: const Icon(
                Icons.arrow_back_rounded,
                color: AppColors.theaterInk,
                size: 26,
              ),
            ),
            SizedBox(width: densePortrait ? 2 : 6),
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
                      fontSize: densePortrait ? 14 : null,
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
                      fontSize: densePortrait ? 11 : null,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: '刷新线路',
              onPressed: onReload,
              style: iconButtonStyle,
              icon: const Icon(
                Icons.refresh_rounded,
                color: AppColors.theaterInk,
                size: 23,
              ),
            ),
            IconButton(
              tooltip: '截图',
              onPressed: onScreenshot,
              style: iconButtonStyle,
              icon: const Icon(
                Icons.camera_alt_outlined,
                color: AppColors.theaterInk,
                size: 23,
              ),
            ),
            IconButton(
              tooltip: '播放设置',
              onPressed: onSettings,
              style: iconButtonStyle,
              icon: const Icon(
                Icons.more_vert_rounded,
                color: AppColors.theaterInk,
                size: 23,
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
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    episode.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: AppColors.theaterMuted,
                    ),
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

class PlayerBottomBar extends StatelessWidget {
  const PlayerBottomBar({
    super.key,
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
    this.onControlMenuChanged,
    required this.onFullscreen,
    required this.onDanmakuPanel,
    this.onDanmakuEnabledChanged,
    required this.danmakuInput,
    this.danmakuInputFocus,
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
  final ValueChanged<bool>? onControlMenuChanged;
  final Future<void> Function() onFullscreen;
  final VoidCallback onDanmakuPanel;
  final ValueChanged<bool>? onDanmakuEnabledChanged;
  final TextEditingController danmakuInput;
  final FocusNode? danmakuInputFocus;
  final ValueChanged<String> onSendDanmaku;
  final VoidCallback onEpisodePanel;
  final VoidCallback onLinePanel;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final safePadding = MediaQuery.paddingOf(context);
    final compact = _isMobilePlayerLayout(context);
    final mobileLandscape = compact && size.width > size.height;
    final portraitMobile = usesCompactPlayerBottomControlsForSize(
      size,
      defaultTargetPlatform,
    );
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
          if (portraitMobile)
            Text(
              '${_durationLabel(position)} / ${_durationLabel(duration)}',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: AppColors.theaterInk,
                fontWeight: FontWeight.w700,
                fontSize: mobileLandscape ? null : 13,
              ),
            ),
          Padding(
            padding: EdgeInsets.symmetric(
              vertical: compact && !mobileLandscape ? 2 : 6,
            ),
            child: _BufferedSeekBar(
              progress: progress,
              buffered: bufferProgress,
              enabled: canSeek,
              duration: duration,
              height: portraitMobile ? 20 : 28,
              onSeek: (value) => onSeek(
                Duration(
                  milliseconds: (duration.inMilliseconds * value).round(),
                ),
              ),
            ),
          ),
          if (portraitMobile)
            SizedBox(
              height: 36,
              child: Row(
                children: [
                  Expanded(
                    child: _MobilePlayerControls(
                      playing: playing,
                      buffering: buffering,
                      loadingLine: loadingLine,
                      fullscreen: fullscreen,
                      onPlayPause: onPlayPause,
                      onPreviousEpisode: onPreviousEpisode,
                      onNextEpisode: onNextEpisode,
                      onFullscreen: onFullscreen,
                      landscape: false,
                    ),
                  ),
                  IconButton(
                    tooltip: '弹幕设置',
                    onPressed: onDanmakuPanel,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 36,
                      height: 36,
                    ),
                    icon: const Icon(
                      Icons.comment_outlined,
                      size: 18,
                      color: AppColors.theaterInk,
                    ),
                  ),
                  DanmakuQuickSwitch(
                    enabled: danmaku.enabled,
                    onChanged: onDanmakuEnabledChanged,
                  ),
                ],
              ),
            )
          else
            _UnifiedPlayerControls(
              line: line,
              settings: settings,
              services: services,
              danmaku: danmaku,
              danmakuInput: danmakuInput,
              danmakuInputFocus: danmakuInputFocus,
              onSendDanmaku: onSendDanmaku,
              position: position,
              duration: duration,
              volume: volume,
              playing: playing,
              buffering: buffering,
              loadingLine: loadingLine,
              fullscreen: fullscreen,
              muted: muted,
              onPlayPause: onPlayPause,
              onPreviousEpisode: onPreviousEpisode,
              onNextEpisode: onNextEpisode,
              onMute: onMute,
              onVolumeChanged: onVolumeChanged,
              onSpeedSelected: onSpeedSelected,
              onControlMenuChanged: onControlMenuChanged,
              onFullscreen: onFullscreen,
              onDanmakuPanel: onDanmakuPanel,
              onDanmakuEnabledChanged: onDanmakuEnabledChanged,
              onEpisodePanel: onEpisodePanel,
              onLinePanel: onLinePanel,
            ),
        ],
      ),
    );
  }
}

class _UnifiedPlayerControls extends StatelessWidget {
  const _UnifiedPlayerControls({
    required this.danmaku,
    required this.danmakuInput,
    this.danmakuInputFocus,
    required this.onSendDanmaku,
    required this.line,
    required this.settings,
    required this.services,
    required this.position,
    required this.duration,
    required this.volume,
    required this.playing,
    required this.buffering,
    required this.loadingLine,
    required this.fullscreen,
    required this.muted,
    required this.onPlayPause,
    required this.onPreviousEpisode,
    required this.onNextEpisode,
    required this.onMute,
    required this.onVolumeChanged,
    required this.onSpeedSelected,
    this.onControlMenuChanged,
    required this.onFullscreen,
    required this.onDanmakuPanel,
    this.onDanmakuEnabledChanged,
    required this.onEpisodePanel,
    required this.onLinePanel,
  });

  final DanmakuSettings danmaku;
  final TextEditingController danmakuInput;
  final FocusNode? danmakuInputFocus;
  final ValueChanged<String> onSendDanmaku;
  final PlaybackLine? line;
  final PlaybackSettings settings;
  final ExternalServiceSettings services;
  final Duration position;
  final Duration duration;
  final double volume;
  final bool playing;
  final bool buffering;
  final bool loadingLine;
  final bool fullscreen;
  final bool muted;
  final Future<void> Function() onPlayPause;
  final Future<void> Function()? onPreviousEpisode;
  final Future<void> Function()? onNextEpisode;
  final Future<void> Function() onMute;
  final ValueChanged<double> onVolumeChanged;
  final ValueChanged<double> onSpeedSelected;
  final ValueChanged<bool>? onControlMenuChanged;
  final Future<void> Function() onFullscreen;
  final VoidCallback onDanmakuPanel;
  final ValueChanged<bool>? onDanmakuEnabledChanged;
  final VoidCallback onEpisodePanel;
  final VoidCallback onLinePanel;

  @override
  Widget build(BuildContext context) {
    final touch =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    return LayoutBuilder(
      builder: (context, constraints) {
        // Keep the annotated Windows order on one row at every landscape
        // width. Reduce secondary label width, never move input below playback.
        final dense = constraints.maxWidth < 1000;
        final narrow = constraints.maxWidth < 600;
        _ControlIconButton action(
          IconData icon,
          String tooltip,
          Future<void> Function()? callback, {
          double size = 24,
          bool busy = false,
        }) => _ControlIconButton(
          icon: icon,
          tooltip: tooltip,
          onPressed: callback,
          size: dense ? size * 0.8 : size,
          busy: busy,
          compact: dense || touch,
          compactSize: 40,
        );

        Widget composer() => Row(
          children: [
            Tooltip(
              message: '弹幕设置',
              child: IconButton(
                key: const ValueKey('playerDanmakuSettings'),
                onPressed: onDanmakuPanel,
                style: IconButton.styleFrom(
                  minimumSize: const Size(40, 40),
                  maximumSize: const Size(40, 40),
                  padding: EdgeInsets.zero,
                ),
                icon: Icon(
                  Icons.comment_outlined,
                  size: dense ? 18 : 23,
                  color: AppColors.theaterInk,
                ),
              ),
            ),
            DanmakuQuickSwitch(
              enabled: danmaku.enabled,
              onChanged: onDanmakuEnabledChanged,
            ),
            SizedBox(width: dense ? 4 : 8),
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: AppColors.theaterBg.withValues(alpha: 0.72),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.theaterBorder),
                ),
                child: SizedBox(
                  height: dense ? 34 : 40,
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: danmakuInput,
                          focusNode: danmakuInputFocus,
                          enabled: danmaku.enabled,
                          textInputAction: TextInputAction.send,
                          onSubmitted: onSendDanmaku,
                          style: TextStyle(
                            color: AppColors.theaterInk,
                            fontSize: dense ? 10.5 : 13,
                          ),
                          decoration: InputDecoration(
                            isDense: true,
                            filled: false,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            hintText: danmaku.enabled ? '发条弹幕吧…' : '弹幕已关闭',
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: dense ? 6 : 14,
                              vertical: dense ? 7 : 9,
                            ),
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: danmaku.enabled
                            ? () => onSendDanmaku(danmakuInput.text)
                            : null,
                        style: TextButton.styleFrom(
                          minimumSize: Size(dense ? 36 : 48, 40),
                          padding: EdgeInsets.symmetric(
                            horizontal: dense ? 4 : 10,
                          ),
                          foregroundColor: AppColors.primary2,
                        ),
                        child: Text(
                          '发送',
                          style: TextStyle(fontSize: dense ? 10 : 14),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );

        final transport = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            action(
              Icons.skip_previous_rounded,
              onPreviousEpisode == null ? '已经是第一集' : '上一集',
              onPreviousEpisode,
            ),
            action(
              playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              playing ? '暂停' : '播放',
              onPlayPause,
              size: 32,
              busy: loadingLine || buffering,
            ),
            action(
              Icons.skip_next_rounded,
              onNextEpisode == null ? '已经是最后一集' : '下一集',
              onNextEpisode,
            ),
            SizedBox(width: dense ? 4 : 8),
            Tooltip(
              message:
                  '${_durationLabel(position)} / ${_durationLabel(duration)}',
              child: SizedBox(
                width: narrow ? 46 : null,
                child: Text(
                  narrow
                      ? '${_durationLabel(position)}\n${_durationLabel(duration)}'
                      : '${_durationLabel(position)} / ${_durationLabel(duration)}',
                  maxLines: narrow ? 2 : 1,
                  textAlign: narrow ? TextAlign.center : TextAlign.start,
                  style: TextStyle(
                    color: AppColors.theaterMuted,
                    fontSize: dense ? 10 : 14,
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
          ],
        );
        final actions = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Tooltip(
              message: '选集',
              child: dense
                  ? TextButton(
                      onPressed: onEpisodePanel,
                      style: TextButton.styleFrom(
                        minimumSize: const Size(40, 40),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        foregroundColor: AppColors.theaterInk,
                      ),
                      child: const Text('选集', style: TextStyle(fontSize: 10)),
                    )
                  : TextButton.icon(
                      onPressed: onEpisodePanel,
                      style: TextButton.styleFrom(
                        minimumSize: const Size(56, 40),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        foregroundColor: AppColors.theaterInk,
                      ),
                      icon: const Icon(Icons.video_library_outlined, size: 18),
                      label: const Text('选集'),
                    ),
            ),
            _SpeedMenuButton(
              current: settings.speed,
              onSelected: onSpeedSelected,
              compact: dense || touch,
              onOpenChanged: onControlMenuChanged,
            ),
            Tooltip(
              message: line == null ? '线路' : playbackLineProviderLabel(line!),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: dense ? 44 : 160),
                child: TextButton(
                  onPressed: onLinePanel,
                  style: TextButton.styleFrom(
                    minimumSize: Size(dense ? 40 : 48, 40),
                    padding: EdgeInsets.symmetric(horizontal: dense ? 2 : 8),
                    foregroundColor: AppColors.theaterInk,
                  ),
                  child: Text(
                    dense || line == null
                        ? '线路'
                        : playbackLineProviderLabel(line!),
                    style: TextStyle(fontSize: dense ? 10 : 14),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
            _VolumeButton(
              volume: volume,
              muted: muted,
              onMute: onMute,
              onVolumeChanged: onVolumeChanged,
              compact: touch,
              iconSize: dense ? 19 : 24,
              onOpenChanged: onControlMenuChanged,
            ),
            action(
              fullscreen
                  ? Icons.fullscreen_exit_rounded
                  : Icons.fullscreen_rounded,
              fullscreen ? '退出全屏' : '全屏',
              onFullscreen,
            ),
          ],
        );
        return SizedBox(
          height: dense ? 44 : 52,
          child: Row(
            children: [
              transport,
              SizedBox(width: dense ? 4 : 18),
              Expanded(child: composer()),
              SizedBox(width: dense ? 4 : 14),
              actions,
            ],
          ),
        );
      },
    );
  }
}

class _SpeedMenuButton extends StatelessWidget {
  const _SpeedMenuButton({
    required this.current,
    required this.onSelected,
    this.compact = false,
    this.onOpenChanged,
  });

  static const _speeds = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];

  final double current;
  final ValueChanged<double> onSelected;
  final bool compact;
  final ValueChanged<bool>? onOpenChanged;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      onOpen: () => onOpenChanged?.call(true),
      onClose: () => onOpenChanged?.call(false),
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
        final badge = SmallBadge(label: _speedLabel(current), compact: compact);
        return Tooltip(
          message: '播放速度',
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: () =>
                controller.isOpen ? controller.close() : controller.open(),
            child: compact
                ? SizedBox(
                    width: 44,
                    height: 40,
                    child: Center(
                      child: Transform.scale(scale: 0.88, child: badge),
                    ),
                  )
                : badge,
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
    this.compact = false,
    this.iconSize = 24,
    this.onOpenChanged,
  });

  final double volume;
  final bool muted;
  final Future<void> Function() onMute;
  final ValueChanged<double> onVolumeChanged;
  final bool compact;
  final double iconSize;
  final ValueChanged<bool>? onOpenChanged;

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
      onOpen: () => widget.onOpenChanged?.call(true),
      onClose: () => widget.onOpenChanged?.call(false),
      controller: _menu,
      alignmentOffset: const Offset(-6, -8),
      menuChildren: [
        MouseRegion(
          onEnter: (_) => _cancelClose(),
          onExit: (_) => _scheduleClose(),
          child: SizedBox(
            height: widget.compact ? 188 : 148,
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
                if (widget.compact)
                  IconButton(
                    tooltip: widget.muted ? '恢复声音' : '静音',
                    onPressed: widget.onMute,
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      widget.muted || widget.volume <= 0
                          ? Icons.volume_off_rounded
                          : Icons.volume_up_rounded,
                      size: 20,
                    ),
                  ),
                const SizedBox(height: 4),
              ],
            ),
          ),
        ),
      ],
      builder: (context, controller, child) {
        final button = Tooltip(
          message: widget.compact
              ? widget.muted
                    ? '已静音，点击调节音量'
                    : '音量 ${widget.volume.round()}%，点击调节'
              : widget.muted
              ? '已静音，点击恢复'
              : '音量 ${widget.volume.round()}%，点击静音',
          child: IconButton(
            onPressed: widget.compact
                ? () =>
                      controller.isOpen ? controller.close() : controller.open()
                : widget.onMute,
            padding: EdgeInsets.zero,
            constraints: widget.compact
                ? const BoxConstraints.tightFor(width: 40, height: 40)
                : null,
            visualDensity: widget.compact ? VisualDensity.compact : null,
            icon: Icon(
              widget.muted || widget.volume <= 0
                  ? Icons.volume_off_rounded
                  : Icons.volume_up_rounded,
              color: AppColors.theaterInk,
              size: widget.iconSize,
            ),
          ),
        );
        if (widget.compact) return button;
        return MouseRegion(
          onEnter: (_) {
            _cancelClose();
            if (!controller.isOpen) controller.open();
          },
          onExit: (_) => _scheduleClose(),
          child: button,
        );
      },
    );
  }
}

class _MobilePlayerControls extends StatelessWidget {
  const _MobilePlayerControls({
    required this.playing,
    required this.buffering,
    required this.loadingLine,
    required this.fullscreen,
    required this.onPlayPause,
    required this.onPreviousEpisode,
    required this.onNextEpisode,
    required this.onFullscreen,
    required this.landscape,
  });

  final bool playing;
  final bool buffering;
  final bool loadingLine;
  final bool fullscreen;
  final Future<void> Function() onPlayPause;
  final Future<void> Function()? onPreviousEpisode;
  final Future<void> Function()? onNextEpisode;
  final Future<void> Function() onFullscreen;
  final bool landscape;

  @override
  Widget build(BuildContext context) {
    final controlSize = landscape ? 36.0 : 32.0;
    final sideIconSize = landscape ? 25.0 : 22.0;
    final primaryIconSize = landscape ? 32.0 : 29.0;
    return SizedBox(
      height: controlSize,
      child: Row(
        children: [
          if (onPreviousEpisode != null) ...[
            _ControlIconButton(
              icon: Icons.skip_previous_rounded,
              tooltip: '上一集',
              onPressed: onPreviousEpisode,
              size: sideIconSize,
              compact: true,
              compactSize: controlSize,
            ),
            const SizedBox(width: 2),
          ],
          _ControlIconButton(
            icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            tooltip: playing ? '暂停' : '播放',
            size: primaryIconSize,
            busy: loadingLine || buffering,
            onPressed: onPlayPause,
            compact: true,
            compactSize: controlSize,
          ),
          if (onNextEpisode != null) ...[
            const SizedBox(width: 2),
            _ControlIconButton(
              icon: Icons.skip_next_rounded,
              tooltip: '下一集',
              onPressed: onNextEpisode,
              size: sideIconSize,
              compact: true,
              compactSize: controlSize,
            ),
          ],
          const Spacer(),
          _ControlIconButton(
            icon: fullscreen
                ? Icons.fullscreen_exit_rounded
                : Icons.fullscreen_rounded,
            tooltip: fullscreen ? '退出全屏' : '全屏',
            onPressed: onFullscreen,
            size: landscape ? 27 : 23,
            compact: true,
            compactSize: controlSize,
          ),
        ],
      ),
    );
  }
}

class _BufferedSeekBar extends StatefulWidget {
  const _BufferedSeekBar({
    required this.progress,
    required this.buffered,
    required this.enabled,
    required this.duration,
    this.height = 28,
    required this.onSeek,
  });

  final double progress;
  final double buffered;
  final bool enabled;
  final Duration duration;
  final double height;
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
              height: widget.height,
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
    this.compactSize,
  });

  final IconData icon;
  final String tooltip;
  final Future<void> Function()? onPressed;
  final double size;
  final bool busy;
  final bool compact;
  final double? compactSize;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        constraints: compact
            ? BoxConstraints.tightFor(
                width: compactSize ?? 40,
                height: compactSize ?? 40,
              )
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
