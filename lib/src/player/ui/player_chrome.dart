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
    final compact = _isMobilePlayerLayout(context);
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
    final portraitMobile = compact && !mobileLandscape;
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
          SizedBox(
            height: portraitMobile
                ? 36
                : (compact ? (mobileLandscape ? 42 : 88) : 52),
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
                        icon: Icons.skip_previous_rounded,
                        tooltip: onPreviousEpisode == null ? '已经是第一集' : '上一集',
                        onPressed: onPreviousEpisode,
                        size: 26,
                      ),
                      const SizedBox(width: 2),
                      _ControlIconButton(
                        icon: playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        tooltip: playing ? '暂停' : '播放',
                        size: 32,
                        busy: loadingLine || buffering,
                        onPressed: onPlayPause,
                      ),
                      const SizedBox(width: 2),
                      _ControlIconButton(
                        icon: Icons.skip_next_rounded,
                        tooltip: onNextEpisode == null ? '已经是最后一集' : '下一集',
                        onPressed: onNextEpisode,
                        size: 26,
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
                          alignment: fullscreen
                              ? Alignment.center
                              : Alignment.centerLeft,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: fullscreen ? 760 : 520,
                            ),
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
      minimumSize: Size(0, landscape ? 40 : 32),
      padding: EdgeInsets.symmetric(horizontal: landscape ? 6 : 2),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
      textStyle: TextStyle(
        fontSize: landscape ? 14 : 11.5,
        fontWeight: FontWeight.w600,
      ),
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
    return SizedBox(
      height: 34,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _ControlIconButton(
            icon: Icons.skip_previous_rounded,
            tooltip: onPreviousEpisode == null ? '已经是第一集' : '上一集',
            onPressed: onPreviousEpisode,
            size: 22,
            compact: true,
            compactSize: 32,
          ),
          _ControlIconButton(
            icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            tooltip: playing ? '暂停' : '播放',
            size: 29,
            busy: loadingLine || buffering,
            onPressed: onPlayPause,
            compact: true,
            compactSize: 32,
          ),
          _ControlIconButton(
            icon: Icons.skip_next_rounded,
            tooltip: onNextEpisode == null ? '已经是最后一集' : '下一集',
            onPressed: onNextEpisode,
            size: 22,
            compact: true,
            compactSize: 32,
          ),
          const SizedBox(width: 8),
          _ControlIconButton(
            icon: fullscreen
                ? Icons.fullscreen_exit_rounded
                : Icons.fullscreen_rounded,
            tooltip: fullscreen ? '退出全屏' : '全屏',
            onPressed: onFullscreen,
            size: 23,
            compact: true,
            compactSize: 32,
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
