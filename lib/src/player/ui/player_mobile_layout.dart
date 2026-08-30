part of '../player_page.dart';

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
              episode.airdate ?? '播出日期未知',
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
