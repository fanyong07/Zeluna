import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/anime_app.dart';
import '../data/anime_controller.dart';
import '../domain/anime_models.dart';
import '../settings/settings_page.dart';
import '../shared_ui/app_chrome.dart';
import '../shared_ui/poster_card.dart';

class PlayerPage extends ConsumerStatefulWidget {
  const PlayerPage({super.key, required this.request});

  final PlaySessionRequest request;

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage> {
  late AnimeEpisode _episode;
  PlaybackLine? _line;
  bool _episodePanel = false;
  bool _linePanel = false;
  bool _subtitlePanel = false;
  bool _danmakuPanel = false;
  bool _settingsPanel = false;

  @override
  void initState() {
    super.initState();
    _episode = widget.request.episode;
    _line = widget.request.initialLine;
  }

  @override
  Widget build(BuildContext context) {
    return AsyncAnimeGate(
      builder: (context, state) {
        return Scaffold(
          backgroundColor: AppColors.bg,
          body: SafeArea(
            child: Stack(
              fit: StackFit.expand,
              children: [
                _PlayerCanvas(
                  subject: widget.request.subject,
                  episode: _episode,
                  line: _line,
                  settings: state.settings,
                  services: state.services,
                  danmaku: state.danmaku,
                  onBack: () => Navigator.of(context).pop(),
                  onEpisodePanel: _toggleEpisodePanel,
                  onLinePanel: _toggleLinePanel,
                  onSubtitlePanel: _toggleSubtitlePanel,
                  onDanmakuPanel: _toggleDanmakuPanel,
                  onSettingsPanel: _toggleSettingsPanel,
                ),
                if (_episodePanel)
                  _SideSheet(
                    title: '选集',
                    child: _EpisodePanel(
                      subject: widget.request.subject,
                      episodes: widget.request.episodes,
                      selected: _episode,
                      onSelected: (episode) {
                        setState(() {
                          _episode = episode;
                          _line = null;
                          _episodePanel = false;
                        });
                      },
                    ),
                  ),
                if (_linePanel)
                  _SideSheet(
                    title: '切换线路',
                    child: _LinePanel(
                      subject: widget.request.subject,
                      episode: _episode,
                      selected: _line,
                      onSelected: (line) {
                        setState(() {
                          _line = line;
                          _linePanel = false;
                        });
                      },
                    ),
                  ),
                if (_subtitlePanel)
                  _SideSheet(
                    title: '字幕源',
                    child: _SubtitlePanel(
                      subject: widget.request.subject,
                      episode: _episode,
                    ),
                  ),
                if (_danmakuPanel)
                  _SideSheet(
                    title: '弹幕源',
                    child: _DanmakuPanel(
                      subject: widget.request.subject,
                      episode: _episode,
                    ),
                  ),
                if (_settingsPanel)
                  _SideSheet(
                    title: '',
                    child: PlaybackSettingsView(
                      compact: true,
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
        );
      },
    );
  }

  void _toggleEpisodePanel() {
    setState(() {
      _episodePanel = !_episodePanel;
      _linePanel = false;
      _subtitlePanel = false;
      _danmakuPanel = false;
      _settingsPanel = false;
    });
  }

  void _toggleLinePanel() {
    setState(() {
      _linePanel = !_linePanel;
      _episodePanel = false;
      _subtitlePanel = false;
      _danmakuPanel = false;
      _settingsPanel = false;
    });
  }

  void _toggleSubtitlePanel() {
    setState(() {
      _subtitlePanel = !_subtitlePanel;
      _episodePanel = false;
      _linePanel = false;
      _danmakuPanel = false;
      _settingsPanel = false;
    });
  }

  void _toggleDanmakuPanel() {
    setState(() {
      _danmakuPanel = !_danmakuPanel;
      _episodePanel = false;
      _linePanel = false;
      _subtitlePanel = false;
      _settingsPanel = false;
    });
  }

  void _toggleSettingsPanel() {
    setState(() {
      _settingsPanel = !_settingsPanel;
      _episodePanel = false;
      _linePanel = false;
      _subtitlePanel = false;
      _danmakuPanel = false;
    });
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
    required this.subject,
    required this.episode,
    required this.line,
    required this.settings,
    required this.services,
    required this.danmaku,
    required this.onBack,
    required this.onEpisodePanel,
    required this.onLinePanel,
    required this.onSubtitlePanel,
    required this.onDanmakuPanel,
    required this.onSettingsPanel,
  });

  final AnimeSubject subject;
  final AnimeEpisode episode;
  final PlaybackLine? line;
  final PlaybackSettings settings;
  final ExternalServiceSettings services;
  final DanmakuSettings danmaku;
  final VoidCallback onBack;
  final VoidCallback onEpisodePanel;
  final VoidCallback onLinePanel;
  final VoidCallback onSubtitlePanel;
  final VoidCallback onDanmakuPanel;
  final VoidCallback onSettingsPanel;

  @override
  Widget build(BuildContext context) {
    final showSideList = MediaQuery.sizeOf(context).width >= 1120;
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: AppColors.bg),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  children: [
                    _PlayerHeader(
                      subject: subject,
                      episode: episode,
                      line: line,
                      onBack: onBack,
                      onSettings: onSettingsPanel,
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: AppPanel(
                        padding: EdgeInsets.zero,
                        borderColor: AppColors.borderBright,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              PosterArt(
                                coverUrl: subject.bannerUrl ?? subject.coverUrl,
                                title: subject.title,
                              ),
                              const DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Color(0x33060912),
                                      Color(0x11060912),
                                      Color(0xDD060912),
                                    ],
                                  ),
                                ),
                              ),
                              Center(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: AppColors.bg.withValues(alpha: 0.48),
                                    shape: BoxShape.circle,
                                    border: Border.all(color: Colors.white24),
                                  ),
                                  child: const SizedBox(
                                    width: 82,
                                    height: 82,
                                    child: Icon(
                                      Icons.pause_rounded,
                                      color: Colors.white,
                                      size: 48,
                                    ),
                                  ),
                                ),
                              ),
                              Positioned(
                                right: 18,
                                top: 18,
                                child: SmallBadge(
                                  label: line?.quality ?? '原画 4K',
                                ),
                              ),
                              _PlayerBottomBar(
                                line: line,
                                settings: settings,
                                services: services,
                                danmaku: danmaku,
                                onSubtitlePanel: onSubtitlePanel,
                                onDanmakuPanel: onDanmakuPanel,
                                onEpisodePanel: onEpisodePanel,
                                onLinePanel: onLinePanel,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    _PlayerBelowControls(
                      line: line,
                      services: services,
                      onLinePanel: onLinePanel,
                      onSubtitlePanel: onSubtitlePanel,
                    ),
                  ],
                ),
              ),
              if (showSideList) ...[
                const SizedBox(width: 18),
                SizedBox(
                  width: 340,
                  child: _PlayerEpisodeRail(
                    subject: subject,
                    selected: episode,
                    onEpisodePanel: onEpisodePanel,
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

class _PlayerHeader extends StatelessWidget {
  const _PlayerHeader({
    required this.subject,
    required this.episode,
    required this.line,
    required this.onBack,
    required this.onSettings,
  });

  final AnimeSubject subject;
  final AnimeEpisode episode;
  final PlaybackLine? line;
  final VoidCallback onBack;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
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
          const _HeaderIcon(Icons.refresh, tooltip: '刷新'),
          const _HeaderIcon(Icons.camera_alt_outlined, tooltip: '截图'),
          const _HeaderIcon(Icons.crop_landscape, tooltip: '缩小窗口'),
          const _HeaderIcon(Icons.cast, tooltip: '投屏'),
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
    required this.onSubtitlePanel,
    required this.onDanmakuPanel,
    required this.onEpisodePanel,
    required this.onLinePanel,
  });

  final PlaybackLine? line;
  final PlaybackSettings settings;
  final ExternalServiceSettings services;
  final DanmakuSettings danmaku;
  final VoidCallback onSubtitlePanel;
  final VoidCallback onDanmakuPanel;
  final VoidCallback onEpisodePanel;
  final VoidCallback onLinePanel;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 18,
      right: 18,
      bottom: 12,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '14:32 / 23:40',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: AppColors.text,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          LinearProgressIndicator(
            value: 0.62,
            minHeight: 4,
            borderRadius: BorderRadius.circular(4),
            backgroundColor: Colors.white24,
            color: AppColors.primary,
          ),
          SizedBox(
            height: 52,
            child: Row(
              children: [
                const Icon(Icons.skip_previous, color: Colors.white, size: 26),
                const SizedBox(width: 16),
                const Icon(Icons.play_arrow, color: Colors.white, size: 30),
                const SizedBox(width: 16),
                const Icon(Icons.skip_next, color: Colors.white, size: 26),
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
                  message: services.bilibiliDanmakuEnabled
                      ? 'Bilibili 弹幕'
                      : 'Bilibili 弹幕已关闭',
                  child: IconButton(
                    onPressed: onDanmakuPanel,
                    padding: EdgeInsets.zero,
                    icon: Icon(
                      Icons.sports_esports_outlined,
                      color: services.bilibiliDanmakuEnabled
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
                    child: Container(
                      height: 40,
                      alignment: Alignment.centerLeft,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: const Text(
                        '发送弹幕',
                        style: TextStyle(color: Colors.white54),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Tooltip(
                  message: '音量增强 ${(settings.volumeBoost * 100).round()}%',
                  child: const Icon(Icons.volume_up, color: Colors.white),
                ),
                const SizedBox(width: 12),
                TextButton(
                  onPressed: onEpisodePanel,
                  child: const Text(
                    '选集',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: onLinePanel,
                  child: Text(
                    line?.providerName ?? '线路1',
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.fullscreen, color: Colors.white),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PlayerEpisodeRail extends StatelessWidget {
  const _PlayerEpisodeRail({
    required this.subject,
    required this.selected,
    required this.onEpisodePanel,
    required this.onLinePanel,
  });

  final AnimeSubject subject;
  final AnimeEpisode selected;
  final VoidCallback onEpisodePanel;
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
              itemCount: 8,
              separatorBuilder: (context, index) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final number = (selected.number + index - 3).clamp(1, 999);
                final active = number == selected.number;
                return AppPanel(
                  padding: const EdgeInsets.all(8),
                  color: active ? const Color(0xFF171A3A) : AppColors.bg2,
                  borderColor: active ? AppColors.primary : AppColors.border,
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: SizedBox(
                          width: 76,
                          height: 46,
                          child: PosterArt(
                            coverUrl: selected.thumbnailUrl ?? subject.coverUrl,
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
                              '第$number集',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelLarge
                                  ?.copyWith(
                                    color: AppColors.text,
                                    fontWeight: FontWeight.w900,
                                  ),
                            ),
                            Text(
                              active ? '正在播放' : '23:40 · 待播放',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: AppColors.muted),
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

class _PlayerBelowControls extends StatelessWidget {
  const _PlayerBelowControls({
    required this.line,
    required this.services,
    required this.onLinePanel,
    required this.onSubtitlePanel,
  });

  final PlaybackLine? line;
  final ExternalServiceSettings services;
  final VoidCallback onLinePanel;
  final VoidCallback onSubtitlePanel;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: AppPanel(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionTitle(title: '播放源'),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    SmallBadge(
                      label: line?.providerName ?? '线路待接入',
                      active: true,
                    ),
                    SmallBadge(label: line?.quality ?? '1080P'),
                    const SmallBadge(label: '备用源'),
                    InkWell(
                      onTap: onLinePanel,
                      child: const SmallBadge(label: '更多线路'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: AppPanel(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionTitle(title: '字幕设置'),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    SmallBadge(
                      label: services.subtitleLanguage == 'zh-CN'
                          ? '简体中文'
                          : services.subtitleLanguage,
                      active: services.bilibiliSubtitleEnabled,
                    ),
                    const SmallBadge(label: '繁体中文'),
                    const SmallBadge(label: 'English'),
                    InkWell(
                      onTap: onSubtitlePanel,
                      child: const SmallBadge(label: '更多字幕'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
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

class _LinePanel extends ConsumerWidget {
  const _LinePanel({
    required this.subject,
    required this.episode,
    required this.selected,
    required this.onSelected,
  });

  final AnimeSubject subject;
  final AnimeEpisode episode;
  final PlaybackLine? selected;
  final ValueChanged<PlaybackLine> onSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder<List<PlaybackLine>>(
      future: ref
          .read(animeControllerProvider.notifier)
          .linesForEpisode(subject, episode),
      builder: (context, snapshot) {
        final lines = snapshot.data ?? const <PlaybackLine>[];
        return ListView(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 110),
          children: [
            const _LineModeBar(),
            const SizedBox(height: 14),
            if (snapshot.connectionState == ConnectionState.waiting)
              const Center(child: CircularProgressIndicator())
            else
              DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xFF202020),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Column(
                    children: [
                      for (var i = 0; i < lines.length; i++) ...[
                        _LineTile(
                          index: i,
                          line: lines[i],
                          selected: selected?.id == lines[i].id,
                          onTap: () => onSelected(lines[i]),
                        ),
                        if (i != lines.length - 1)
                          const Divider(height: 1, color: Color(0xFF303030)),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _SubtitlePanel extends ConsumerWidget {
  const _SubtitlePanel({required this.subject, required this.episode});

  final AnimeSubject subject;
  final AnimeEpisode episode;

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
        if (items.isEmpty) {
          return const _PanelEmpty(
            title: '没有匹配字幕',
            message: 'B 站公开接口没有返回当前集字幕，可能该条目没有官方字幕或需要登录权限。',
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 110),
          itemCount: items.length,
          separatorBuilder: (context, index) => const SizedBox(height: 10),
          itemBuilder: (context, index) {
            final item = items[index];
            return _PanelRow(
              title: item.title,
              subtitle:
                  '${item.provider} · ${item.language} · 下载 ${item.downloadCount}',
              trailing: item.available ? '可用' : item.message ?? '待配置',
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
  });

  final String title;
  final String subtitle;
  final String trailing;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF202020),
        borderRadius: BorderRadius.circular(8),
      ),
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
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: Colors.white54),
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

class _LineModeBar extends StatelessWidget {
  const _LineModeBar();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF202020),
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
  const _SideSheet({required this.title, required this.child});

  final String title;
  final Widget child;

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
              if (title.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: AppColors.text,
                      fontWeight: FontWeight.w800,
                    ),
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
  const _HeaderIcon(this.icon, {required this.tooltip});

  final IconData icon;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: () {},
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
