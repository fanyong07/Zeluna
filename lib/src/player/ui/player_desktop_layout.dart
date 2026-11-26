part of '../player_page.dart';

class _ResponsivePlayerLayout extends StatelessWidget {
  const _ResponsivePlayerLayout({
    required this.portrait,
    this.fullscreen = false,
    this.theaterExpanded = false,
    this.onToggleTheaterMode,
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
  final bool fullscreen;
  final bool theaterExpanded;
  final VoidCallback? onToggleTheaterMode;
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
    if (portrait) {
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

    final desktopSplit = usesDesktopTheaterSplitLayoutForSize(
      MediaQuery.sizeOf(context),
      defaultTargetPlatform,
      fullscreen: fullscreen,
      theaterExpanded: theaterExpanded,
    );
    if (!desktopSplit) return player;

    return _DesktopTheaterLayout(
      key: const ValueKey('desktopTheaterLayout'),
      player: player,
      subject: subject,
      episodes: episodes,
      episode: episode,
      line: line,
      lines: lines,
      failedLineIds: failedLineIds,
      loadingLines: loadingLines,
      onToggleTheaterMode: onToggleTheaterMode,
      onEpisodePanel: onEpisodePanel,
      onEpisodeSelected: onEpisodeSelected,
      onLinePanel: onLinePanel,
      onLineSelected: onLineSelected,
    );
  }
}

/// Bilibili / YouTube / Kazumi inspired desktop 2-column theater layout:
/// left video stage + concise title/action footer, right 344px tabbed sidebar
/// for instant episode & playback line switching.
class _DesktopTheaterLayout extends StatefulWidget {
  const _DesktopTheaterLayout({
    super.key,
    required this.player,
    required this.subject,
    required this.episodes,
    required this.episode,
    required this.line,
    required this.lines,
    required this.failedLineIds,
    required this.loadingLines,
    required this.onToggleTheaterMode,
    required this.onEpisodePanel,
    required this.onEpisodeSelected,
    required this.onLinePanel,
    required this.onLineSelected,
  });

  final Widget player;
  final AnimeSubject subject;
  final List<AnimeEpisode> episodes;
  final AnimeEpisode episode;
  final PlaybackLine? line;
  final List<PlaybackLine> lines;
  final Set<String> failedLineIds;
  final bool loadingLines;
  final VoidCallback? onToggleTheaterMode;
  final VoidCallback onEpisodePanel;
  final ValueChanged<AnimeEpisode> onEpisodeSelected;
  final VoidCallback onLinePanel;
  final ValueChanged<PlaybackLine> onLineSelected;

  @override
  State<_DesktopTheaterLayout> createState() => _DesktopTheaterLayoutState();
}

class _DesktopTheaterLayoutState extends State<_DesktopTheaterLayout> {
  var _sidebarTab = 0; // 0 = 选集, 1 = 播放线路

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final displayLines = allPlaybackLinesForDisplay(widget.lines).toList();
    final selectedLine = widget.line;
    if (selectedLine != null &&
        !displayLines.any((l) => l.id == selectedLine.id)) {
      displayLines.insert(0, selectedLine);
    }
    final playableCount = selectablePlaybackLinesForDisplay(
      displayLines,
      failedLineIds: widget.failedLineIds,
    ).length;

    return ColoredBox(
      color: AppColors.theaterBg,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Left stage: video canvas + concise theater info footer
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: widget.player),
                Container(
                  padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
                  decoration: const BoxDecoration(
                    color: AppColors.theaterPanel,
                    border: Border(
                      top: BorderSide(
                        color: AppColors.theaterBorder,
                        width: 0.75,
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    widget.subject.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(
                                          color: AppColors.theaterInk,
                                          fontWeight: FontWeight.w800,
                                        ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: scheme.primary.withValues(
                                      alpha: 0.16,
                                    ),
                                    borderRadius: BorderRadius.circular(
                                      AppRadius.xs,
                                    ),
                                  ),
                                  child: Text(
                                    widget.episode.displayTitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(
                                          color: scheme.primary,
                                          fontWeight: FontWeight.w700,
                                        ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              [
                                if (widget.line?.providerName.isNotEmpty ??
                                    false)
                                  widget.line!.providerName,
                                if (widget.line?.quality.isNotEmpty ?? false)
                                  widget.line!.quality,
                                if (playableCount > 0) '$playableCount 条可用线路',
                                if (widget.subject.year != '未知')
                                  widget.subject.year,
                              ].join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: AppColors.theaterMuted),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      if (widget.onToggleTheaterMode != null)
                        OutlinedButton.icon(
                          onPressed: widget.onToggleTheaterMode,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.theaterInk,
                            side: const BorderSide(
                              color: AppColors.theaterBorderBright,
                            ),
                            visualDensity: VisualDensity.compact,
                          ),
                          icon: const Icon(Icons.width_wide_rounded, size: 16),
                          label: const Text('宽屏'),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Right 344px tabbed sidebar: Episodes + Playback Lines
          Container(
            width: 344,
            decoration: const BoxDecoration(
              color: AppColors.theaterPanel,
              border: Border(
                left: BorderSide(color: AppColors.theaterBorder, width: 0.75),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  child: Row(
                    children: [
                      _TheaterSidebarTab(
                        label: '选集 (${widget.episodes.length})',
                        selected: _sidebarTab == 0,
                        onTap: () => setState(() => _sidebarTab = 0),
                      ),
                      const SizedBox(width: 8),
                      _TheaterSidebarTab(
                        label: '线路 (${displayLines.length})',
                        selected: _sidebarTab == 1,
                        onTap: () => setState(() => _sidebarTab = 1),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: _sidebarTab == 0 ? '展开全部选集' : '管理线路',
                        visualDensity: VisualDensity.compact,
                        onPressed: _sidebarTab == 0
                            ? widget.onEpisodePanel
                            : widget.onLinePanel,
                        icon: const Icon(
                          Icons.open_in_full_rounded,
                          size: 16,
                          color: AppColors.theaterMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: AppColors.theaterBorder),
                Expanded(
                  child: _sidebarTab == 0
                      ? _DesktopEpisodeGrid(
                          episodes: widget.episodes,
                          selected: widget.episode,
                          onSelected: widget.onEpisodeSelected,
                        )
                      : displayLines.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: Text(
                              widget.loadingLines ? '正在检索可用线路…' : '暂无可切换线路',
                              style: const TextStyle(
                                color: AppColors.theaterMuted,
                              ),
                            ),
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          itemCount: displayLines.length,
                          separatorBuilder: (_, _) => const Divider(
                            height: 1,
                            color: AppColors.theaterBorder,
                          ),
                          itemBuilder: (_, index) {
                            final line = displayLines[index];
                            final selectable =
                                line.available &&
                                (line.url?.isNotEmpty ?? false) &&
                                !widget.failedLineIds.contains(line.id);
                            return PlaybackLineTile(
                              line: line,
                              selected: line.id == widget.line?.id,
                              runtimeFailed: widget.failedLineIds.contains(
                                line.id,
                              ),
                              onTap: selectable
                                  ? () => widget.onLineSelected(line)
                                  : null,
                              compact: true,
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TheaterSidebarTab extends StatelessWidget {
  const _TheaterSidebarTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected ? scheme.primary : AppColors.theaterPanelHigh,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: selected ? scheme.onPrimary : AppColors.theaterMuted,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopEpisodeGrid extends StatelessWidget {
  const _DesktopEpisodeGrid({
    required this.episodes,
    required this.selected,
    required this.onSelected,
  });

  final List<AnimeEpisode> episodes;
  final AnimeEpisode selected;
  final ValueChanged<AnimeEpisode> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (episodes.isEmpty) {
      return const Center(
        child: Text('暂无可选剧集', style: TextStyle(color: AppColors.theaterMuted)),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 1.55,
      ),
      itemCount: episodes.length,
      itemBuilder: (context, index) {
        final ep = episodes[index];
        final isSelected = ep.id == selected.id;
        return Tooltip(
          message: ep.displayTitle,
          child: Material(
            color: isSelected ? scheme.primary : AppColors.theaterPanelHigh,
            borderRadius: BorderRadius.circular(AppRadius.sm),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => onSelected(ep),
              child: Center(
                child: Text(
                  ep.number.toString().padLeft(2, '0'),
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: isSelected ? scheme.onPrimary : AppColors.theaterInk,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

@visibleForTesting
bool usesDesktopTheaterSplitLayoutForSize(
  Size size,
  TargetPlatform platform, {
  required bool fullscreen,
  required bool theaterExpanded,
}) {
  if (fullscreen || theaterExpanded) return false;
  if (usesMobilePlayerLayoutForSize(size, platform)) return false;
  return size.width >= 960 && size.height >= 540;
}

@visibleForTesting
bool usesMobilePlayerLayoutForSize(Size size, TargetPlatform platform) {
  final mobilePlatform =
      platform == TargetPlatform.android || platform == TargetPlatform.iOS;
  // A portrait Android/iOS player is still a mobile surface on large-density
  // emulators and tablets. Using only shortestSide here made MuMu portrait
  // windows fall through to the desktop chrome and cover the video with
  // every desktop control.
  if (mobilePlatform && size.height > size.width) return true;
  return size.width < 640 || (mobilePlatform && size.shortestSide < 600);
}

@visibleForTesting
bool usesCompactPlayerBottomControlsForSize(
  Size size,
  TargetPlatform platform,
) {
  return size.height > size.width &&
      usesMobilePlayerLayoutForSize(size, platform);
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
