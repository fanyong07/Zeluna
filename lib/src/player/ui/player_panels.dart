part of '../player_page.dart';

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
