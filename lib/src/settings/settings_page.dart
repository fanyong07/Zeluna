import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/anime_app.dart';
import '../data/anime_controller.dart';
import '../domain/anime_models.dart';
import '../shared_ui/app_chrome.dart';
import '../shared_ui/app_navigation.dart';

class SettingsHubPage extends ConsumerWidget {
  const SettingsHubPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AsyncAnimeGate(
      builder: (context, state) {
        final compact = MediaQuery.sizeOf(context).width < 760;
        final tiles = [
          _SettingsHubTile(
            icon: Icons.download_done,
            title: '下载管理',
            value: '${state.offlineTasks.length}',
            onTap: () => context.push('/profile/offline'),
          ),
          _SettingsHubTile(
            icon: Icons.extension_outlined,
            title: '规则管理',
            value:
                '${state.rulePlugins.enabledIds.length}/${state.rulePlugins.installedIds.length}',
            onTap: () => context.push('/profile/rules'),
          ),
          _SettingsHubTile(
            icon: Icons.hub_outlined,
            title: '视频源',
            value:
                '${state.sourceCatalog.enabledCount}/${state.sourceCatalog.importedCount}',
            onTap: () => context.push('/profile/sources'),
          ),
          _SettingsHubTile(
            icon: Icons.subtitles,
            title: '弹幕设置',
            value: state.danmaku.enabled ? '开启' : '关闭',
            onTap: () => context.push('/profile/danmaku'),
          ),
          _SettingsHubTile(
            icon: Icons.play_circle_outline,
            title: '播放设置',
            value: '偏好',
            onTap: () => context.push('/settings/playback'),
          ),
        ];
        return AppChrome(
          active: ChromeDestination.settings,
          showSearch: false,
          title: '设置',
          rightRail: _SettingsHubRail(state: state),
          child: ListView(
            padding: EdgeInsets.fromLTRB(
              compact ? 14 : 24,
              compact ? 0 : 6,
              compact ? 14 : 0,
              120,
            ),
            children: [
              if (!compact) ...[
                AppPanel(
                  borderColor: AppColors.borderBright,
                  child: const Row(
                    children: [
                      Icon(Icons.settings_outlined, color: AppColors.primary),
                      SizedBox(width: 10),
                      Expanded(
                        child: SectionTitle(
                          title: '设置',
                          subtitle: '播放、资源、缓存和弹幕统一管理',
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
              LayoutBuilder(
                builder: (context, constraints) {
                  if (compact) {
                    return AppPanel(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      child: Column(
                        children: [
                          for (var i = 0; i < tiles.length; i++) ...[
                            tiles[i],
                            if (i != tiles.length - 1)
                              const SizedBox(height: 8),
                          ],
                        ],
                      ),
                    );
                  }
                  final columns = constraints.maxWidth >= 1080
                      ? 4
                      : constraints.maxWidth >= 760
                      ? 3
                      : 2;
                  return GridView.count(
                    crossAxisCount: columns,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 2.5,
                    children: tiles,
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SettingsHubTile extends StatelessWidget {
  const _SettingsHubTile({
    required this.icon,
    required this.title,
    required this.value,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 760;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: AppPanel(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 12 : 16,
          vertical: compact ? 12 : 16,
        ),
        color: AppColors.panelHigh,
        child: Row(
          children: [
            Icon(icon, color: AppColors.primary, size: compact ? 24 : 30),
            SizedBox(width: compact ? 12 : 14),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        (compact
                                ? Theme.of(context).textTheme.titleSmall
                                : Theme.of(context).textTheme.titleMedium)
                            ?.copyWith(
                              color: AppColors.text,
                              fontWeight: FontWeight.w900,
                            ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: AppColors.muted),
                  ),
                ],
              ),
            ),
            if (compact) ...[
              const SizedBox(width: 8),
              const Icon(
                Icons.chevron_right_rounded,
                color: AppColors.faint,
                size: 22,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SettingsHubRail extends StatelessWidget {
  const _SettingsHubRail({required this.state});

  final AnimeState state;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 6, 20, 24),
      children: [
        AppPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionTitle(title: '当前状态'),
              const SizedBox(height: 14),
              _SettingsHubRailLine(
                label: '视频源',
                value:
                    '${state.sourceCatalog.enabledCount}/${state.sourceCatalog.importedCount}',
              ),
              _SettingsHubRailLine(
                label: '规则',
                value:
                    '${state.rulePlugins.enabledIds.length}/${state.rulePlugins.installedIds.length}',
              ),
              _SettingsHubRailLine(
                label: '缓存任务',
                value: '${state.offlineTasks.length}',
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        const AppPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionTitle(title: '管理范围'),
              SizedBox(height: 12),
              _SettingsHubNote(text: '播放偏好、弹幕过滤和资源开关都在这里进入'),
              _SettingsHubNote(text: '下载、规则和视频源仍沿用原来的管理页面'),
            ],
          ),
        ),
      ],
    );
  }
}

class _SettingsHubRailLine extends StatelessWidget {
  const _SettingsHubRailLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: AppColors.text,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          SmallBadge(label: value, active: true),
        ],
      ),
    );
  }
}

class _SettingsHubNote extends StatelessWidget {
  const _SettingsHubNote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.check_circle_outline,
            size: 16,
            color: AppColors.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
            ),
          ),
        ],
      ),
    );
  }
}

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AsyncAnimeGate(
      builder: (context, state) {
        return PlaybackSettingsView(
          settings: state.settings,
          onChanged: (settings) => ref
              .read(animeControllerProvider.notifier)
              .updateSettings(settings),
          onBack: () => safeNavigateBack(context, fallbackRoute: '/profile'),
        );
      },
    );
  }
}

class PlaybackSettingsView extends StatelessWidget {
  const PlaybackSettingsView({
    super.key,
    required this.settings,
    required this.onChanged,
    required this.onBack,
    this.compact = false,
    this.subject,
    this.episode,
    this.line,
    this.playbackMessage,
  });

  final PlaybackSettings settings;
  final ValueChanged<PlaybackSettings> onChanged;
  final VoidCallback onBack;
  final bool compact;
  final AnimeSubject? subject;
  final AnimeEpisode? episode;
  final PlaybackLine? line;
  final String? playbackMessage;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            ListView(
              padding: EdgeInsets.fromLTRB(8, 0, compact ? 8 : 12, 120),
              children: [
                _SettingsTitle(onBack: onBack, compact: compact),
                if (compact) ...[
                  _SettingsDisclosure(
                    icon: Icons.info_outline_rounded,
                    title: '播放信息',
                    subtitle:
                        '${_textOrFallback(line?.providerName)} · ${_playbackStatusText(line, playbackMessage)}',
                    child: _PlaybackInfoContent(
                      subject: subject,
                      episode: episode,
                      line: line,
                      playbackMessage: playbackMessage,
                      showTitle: false,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _SettingsDisclosure(
                    icon: Icons.keyboard_alt_outlined,
                    title: '按键说明',
                    subtitle: settings.keyboardShortcutsEnabled
                        ? '已启用 · Space / K / F / M'
                        : '已关闭',
                    child: _ShortcutHelpContent(
                      settings: settings,
                      showTitle: false,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                _VolumeCard(settings: settings, onChanged: onChanged),
                const SizedBox(height: 12),
                _SettingsCard(
                  children: [
                    _SwitchRow(
                      title: 'Windows 快捷键',
                      subtitle: '开启后播放器响应键盘控制，移动端不受影响',
                      value: settings.keyboardShortcutsEnabled,
                      onChanged: (value) => onChanged(
                        settings.copyWith(keyboardShortcutsEnabled: value),
                      ),
                    ),
                    _SwitchRow(
                      title: '播放 / 暂停',
                      subtitle: 'Space、K',
                      value: settings.shortcutPlayPause,
                      onChanged: settings.keyboardShortcutsEnabled
                          ? (value) => onChanged(
                              settings.copyWith(shortcutPlayPause: value),
                            )
                          : null,
                    ),
                    _SwitchRow(
                      title: '快进 / 快退',
                      subtitle:
                          '方向键 ← / →，使用上面的 ${settings.rewindSeconds}/${settings.forwardSeconds} 秒设置',
                      value: settings.shortcutSeek,
                      onChanged: settings.keyboardShortcutsEnabled
                          ? (value) => onChanged(
                              settings.copyWith(shortcutSeek: value),
                            )
                          : null,
                    ),
                    _SwitchRow(
                      title: '音量调节',
                      subtitle: '方向键 ↑ / ↓',
                      value: settings.shortcutVolume,
                      onChanged: settings.keyboardShortcutsEnabled
                          ? (value) => onChanged(
                              settings.copyWith(shortcutVolume: value),
                            )
                          : null,
                    ),
                    _SwitchRow(
                      title: '全屏切换',
                      subtitle: 'F',
                      value: settings.shortcutFullscreen,
                      onChanged: settings.keyboardShortcutsEnabled
                          ? (value) => onChanged(
                              settings.copyWith(shortcutFullscreen: value),
                            )
                          : null,
                    ),
                    _SwitchRow(
                      title: '静音',
                      subtitle: 'M',
                      value: settings.shortcutMute,
                      onChanged: settings.keyboardShortcutsEnabled
                          ? (value) => onChanged(
                              settings.copyWith(shortcutMute: value),
                            )
                          : null,
                    ),
                    _SwitchRow(
                      title: '重载当前线路',
                      subtitle: 'R',
                      value: settings.shortcutReload,
                      onChanged: settings.keyboardShortcutsEnabled
                          ? (value) => onChanged(
                              settings.copyWith(shortcutReload: value),
                            )
                          : null,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _SettingsCard(
                  children: [
                    _SwitchRow(
                      title: '超分辨率',
                      subtitle: 'Anime4K 实时超分，对硬件性能有要求',
                      value: settings.superResolution,
                      onChanged: (value) =>
                          onChanged(settings.copyWith(superResolution: value)),
                    ),
                    _ChoiceRow<String>(
                      title: '画面尺寸',
                      value: settings.videoScale,
                      options: const ['适应', '铺满', '拉伸', '16:9', '4:3', '原始'],
                      labelOf: (value) => value,
                      onChanged: (value) =>
                          onChanged(settings.copyWith(videoScale: value)),
                    ),
                    _ChoiceRow<double>(
                      title: '播放速度',
                      value: settings.speed,
                      options: const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0],
                      labelOf: _speedLabel,
                      onChanged: (value) =>
                          onChanged(settings.copyWith(speed: value)),
                    ),
                    _ChoiceRow<double>(
                      title: '默认倍速',
                      value: settings.defaultSpeed,
                      options: const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0],
                      labelOf: _speedLabel,
                      onChanged: (value) =>
                          onChanged(settings.copyWith(defaultSpeed: value)),
                    ),
                    _ChoiceRow<double>(
                      title: '长按倍速',
                      value: settings.holdSpeed,
                      options: const [1.25, 1.5, 2.0, 2.5, 3.0],
                      labelOf: _speedLabel,
                      onChanged: (value) =>
                          onChanged(settings.copyWith(holdSpeed: value)),
                    ),
                    _SwitchRow(
                      title: '边缘双击',
                      subtitle: '双击快进、双击快退功能开关',
                      value: settings.edgeDoubleTap,
                      onChanged: (value) =>
                          onChanged(settings.copyWith(edgeDoubleTap: value)),
                    ),
                    _ChoiceRow<int>(
                      title: '快退时间',
                      subtitle: '自定义双击左侧/方向←跳过的时间',
                      value: settings.rewindSeconds,
                      options: const [5, 10, 15, 30, 60, 90],
                      labelOf: (value) => '$value 秒',
                      onChanged: (value) =>
                          onChanged(settings.copyWith(rewindSeconds: value)),
                    ),
                    _ChoiceRow<int>(
                      title: '快进时间',
                      subtitle: '自定义双击右侧/方向→跳过的时间',
                      value: settings.forwardSeconds,
                      options: const [5, 10, 15, 30, 60, 90],
                      labelOf: (value) => '$value 秒',
                      onChanged: (value) =>
                          onChanged(settings.copyWith(forwardSeconds: value)),
                    ),
                  ],
                ),
                if (!compact && !kReleaseMode) ...[
                  const SizedBox(height: 12),
                  _SettingsCard(
                    children: [
                      _SwitchRow(
                        title: '兼容模式',
                        subtitle: '以默认配置播放视频',
                        value: settings.compatibilityMode,
                        onChanged: (value) => onChanged(
                          settings.copyWith(compatibilityMode: value),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                _SettingsCard(
                  children: [
                    _SwitchRow(
                      title: '自动续播',
                      subtitle: '自动播放下一集',
                      value: settings.autoNext,
                      onChanged: (value) =>
                          onChanged(settings.copyWith(autoNext: value)),
                    ),
                    _SwitchRow(
                      title: '自动换线',
                      subtitle: '播放失败自动切换线路',
                      value: settings.autoSwitchLine,
                      onChanged: (value) =>
                          onChanged(settings.copyWith(autoSwitchLine: value)),
                    ),
                    _SwitchRow(
                      title: '自动全屏',
                      subtitle: '首次进入播放页面时自动全屏',
                      value: settings.autoFullscreen,
                      onChanged: (value) =>
                          onChanged(settings.copyWith(autoFullscreen: value)),
                    ),
                    _SwitchRow(
                      title: '线路记忆',
                      subtitle: '换集自动切换到当前线路(如果存在)',
                      value: settings.rememberLine,
                      onChanged: (value) =>
                          onChanged(settings.copyWith(rememberLine: value)),
                    ),
                  ],
                ),
                ..._debugServiceEntries(context, compact),
              ],
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 24,
              child: Center(child: _BackPill(onBack: onBack)),
            ),
          ],
        ),
      ),
    );
  }
}

List<Widget> _debugServiceEntries(BuildContext context, bool compact) {
  var widgets = const <Widget>[];
  assert(() {
    if (!compact) {
      widgets = [
        const SizedBox(height: 12),
        _SettingsCard(
          children: [
            _ActionRow(
              title: '影视资料源',
              subtitle: 'TVMaze：免 Key 影视剧资料框架',
              onTap: () => context.push('/settings/services/media'),
            ),
            _ActionRow(
              title: '番剧资料源',
              subtitle: 'AniList + Bangumi：新番/放送/中文标题框架',
              onTap: () => context.push('/settings/services/anime'),
            ),
            _ActionRow(
              title: '观看同步',
              subtitle: 'Bangumi 公开收藏读取 / 本机记录框架',
              onTap: () => context.push('/settings/services/sync'),
            ),
            _ActionRow(
              title: '字幕源',
              subtitle: 'Bilibili 公开字幕匹配框架',
              onTap: () => context.push('/settings/services/subtitles'),
            ),
            _ActionRow(
              title: '弹幕源',
              subtitle: '弹弹play / Bilibili / 自建弹幕库',
              onTap: () => context.push('/settings/services/danmaku'),
            ),
          ],
        ),
      ];
    }
    return true;
  }());
  return widgets;
}

class _SettingsTitle extends StatelessWidget {
  const _SettingsTitle({required this.onBack, required this.compact});

  final VoidCallback onBack;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: compact ? 44 : 42,
      child: Row(
        children: [
          Text(
            '播放设置',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w500,
            ),
          ),
          const Spacer(),
          IconButton(onPressed: onBack, icon: const Icon(Icons.close)),
        ],
      ),
    );
  }
}

class _PlaybackInfoContent extends StatelessWidget {
  const _PlaybackInfoContent({
    required this.subject,
    required this.episode,
    required this.line,
    required this.playbackMessage,
    this.showTitle = true,
  });

  final AnimeSubject? subject;
  final AnimeEpisode? episode;
  final PlaybackLine? line;
  final String? playbackMessage;
  final bool showTitle;

  String get _contentTitle {
    final title = subject?.title.trim();
    final episodeText = episode == null ? '' : ' · 第${episode!.number}集';
    if (title == null || title.isEmpty) return '未选择内容$episodeText';
    return '$title$episodeText';
  }

  @override
  Widget build(BuildContext context) {
    final rows = <_InfoPair>[
      _InfoPair('内容', _contentTitle),
      _InfoPair('当前源', _textOrFallback(line?.providerName)),
      _InfoPair('线路', _textOrFallback(line?.title)),
      _InfoPair('清晰度', _textOrFallback(line?.quality)),
      _InfoPair('格式', _textOrFallback(line?.format)),
      _InfoPair('状态', _playbackStatusText(line, playbackMessage)),
      _InfoPair('延迟', _latencyText(line?.latency)),
      _InfoPair('大小', _textOrFallback(line?.sizeLabel)),
      _InfoPair('地址', _hostText(line?.url)),
    ];
    return Padding(
      padding: EdgeInsets.fromLTRB(18, showTitle ? 16 : 14, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showTitle) ...[
            Text(
              '播放信息',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 12),
          ],
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 64,
                    child: Text(
                      row.label,
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: Colors.white38),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      row.value,
                      maxLines: row.label == '地址' ? 2 : 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
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

class _ShortcutHelpContent extends StatelessWidget {
  const _ShortcutHelpContent({required this.settings, this.showTitle = true});

  final PlaybackSettings settings;
  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    final enabled = settings.keyboardShortcutsEnabled;
    final items = [
      if (settings.shortcutPlayPause)
        const _ShortcutPair('Space / K', '播放 / 暂停'),
      if (settings.shortcutSeek)
        _ShortcutPair(
          '← / →',
          '快退 ${settings.rewindSeconds} 秒 / 快进 ${settings.forwardSeconds} 秒',
        ),
      if (settings.shortcutVolume) const _ShortcutPair('↑ / ↓', '调高 / 调低音量'),
      if (settings.shortcutFullscreen) const _ShortcutPair('F', '全屏 / 退出全屏'),
      if (settings.shortcutMute) const _ShortcutPair('M', '静音 / 恢复'),
      if (settings.shortcutReload) const _ShortcutPair('R', '重载当前线路'),
      const _ShortcutPair('Esc', '关闭侧栏或退出全屏'),
    ];
    return Padding(
      padding: EdgeInsets.fromLTRB(18, showTitle ? 16 : 14, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showTitle) ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    '按键说明',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                Text(
                  enabled ? '已启用' : '已关闭',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: enabled ? Colors.white70 : Colors.white38,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
          if (!enabled)
            Text(
              '开启 Windows 快捷键后生效。',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.white54),
            )
          else
            for (final item in items)
              Padding(
                padding: const EdgeInsets.only(bottom: 9),
                child: Row(
                  children: [
                    SizedBox(
                      width: 92,
                      child: Text(
                        item.keys,
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        item.description,
                        style: Theme.of(
                          context,
                        ).textTheme.bodyMedium?.copyWith(color: Colors.white60),
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

class _InfoPair {
  const _InfoPair(this.label, this.value);

  final String label;
  final String value;
}

class _ShortcutPair {
  const _ShortcutPair(this.keys, this.description);

  final String keys;
  final String description;
}

String _textOrFallback(String? value) {
  final text = value?.trim();
  if (text == null || text.isEmpty) return '未知';
  return text;
}

String _playbackStatusText(PlaybackLine? line, String? playbackMessage) {
  final message = playbackMessage?.trim();
  if (line == null) return message?.isNotEmpty == true ? message! : '等待选线';
  final lineMessage = line.message?.trim();
  if (!line.available) {
    return lineMessage?.isNotEmpty == true ? lineMessage! : '不可用';
  }
  if ((line.url ?? '').trim().isEmpty) {
    return lineMessage?.isNotEmpty == true ? lineMessage! : '未返回播放地址';
  }
  return message?.isNotEmpty == true ? message! : '可播放';
}

String _latencyText(Duration? value) {
  if (value == null) return '未知';
  return '${value.inMilliseconds} ms';
}

String _hostText(String? url) {
  final text = url?.trim();
  if (text == null || text.isEmpty) return '未返回';
  final uri = Uri.tryParse(text);
  if (uri == null || uri.host.isEmpty) return text;
  return uri.host;
}

class _VolumeCard extends StatelessWidget {
  const _VolumeCard({required this.settings, required this.onChanged});

  final PlaybackSettings settings;
  final ValueChanged<PlaybackSettings> onChanged;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF202020),
        borderRadius: BorderRadius.circular(7),
      ),
      child: SizedBox(
        height: 70,
        child: Row(
          children: [
            const SizedBox(width: 20),
            SizedBox(
              width: 112,
              child: Text(
                '音量增强',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Expanded(
              child: Slider(
                value: settings.volumeBoost,
                min: 0,
                max: 1,
                onChanged: (value) =>
                    onChanged(settings.copyWith(volumeBoost: value)),
              ),
            ),
            SizedBox(
              width: 52,
              child: Text(
                '${(settings.volumeBoost * 100).round()}%',
                textAlign: TextAlign.end,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(color: Colors.white70),
              ),
            ),
            IconButton(
              onPressed: () => onChanged(settings.copyWith(volumeBoost: 0.26)),
              icon: const Icon(Icons.refresh),
            ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF202020),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              children[i],
              if (i != children.length - 1)
                const Divider(height: 1, color: Color(0xFF303030)),
            ],
          ],
        ),
      ),
    );
  }
}

class _SettingsDisclosure extends StatefulWidget {
  const _SettingsDisclosure({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget child;

  @override
  State<_SettingsDisclosure> createState() => _SettingsDisclosureState();
}

class _SettingsDisclosureState extends State<_SettingsDisclosure> {
  var _expanded = false;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF202020),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Material(
        color: Colors.transparent,
        child: Column(
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(7),
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 13, 14, 13),
                child: Row(
                  children: [
                    Icon(widget.icon, color: Colors.white70, size: 22),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.title,
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w500,
                                ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            widget.subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: Colors.white54),
                          ),
                        ],
                      ),
                    ),
                    AnimatedRotation(
                      turns: _expanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOutCubic,
                      child: const Icon(
                        Icons.keyboard_arrow_down_rounded,
                        color: Colors.white54,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            AnimatedCrossFade(
              firstChild: const SizedBox.shrink(),
              secondChild: Column(
                children: [
                  const Divider(height: 1, color: Color(0xFF303030)),
                  widget.child,
                ],
              ),
              crossFadeState: _expanded
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              duration: const Duration(milliseconds: 180),
              firstCurve: Curves.easeOutCubic,
              secondCurve: Curves.easeOutCubic,
              sizeCurve: Curves.easeOutCubic,
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.title, this.subtitle, this.onTap});

  final String title;
  final String? subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: subtitle == null ? 62 : 78,
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.copyWith(color: Colors.white54),
                    ),
                  ],
                ],
              ),
            ),
            if (onTap != null)
              const Icon(Icons.chevron_right, color: Colors.white54),
          ],
        ),
      ),
    );
  }
}

class _ChoiceRow<T> extends StatelessWidget {
  const _ChoiceRow({
    required this.title,
    required this.value,
    required this.options,
    required this.labelOf,
    required this.onChanged,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final T value;
  final List<T> options;
  final String Function(T value) labelOf;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => _showChoiceSheet(context),
      child: SizedBox(
        height: subtitle == null ? 62 : 78,
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.copyWith(color: Colors.white54),
                    ),
                  ],
                ],
              ),
            ),
            Text(
              labelOf(value),
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(color: Colors.white70),
            ),
            const SizedBox(width: 10),
            const Icon(Icons.chevron_right, color: Colors.white54),
          ],
        ),
      ),
    );
  }

  void _showChoiceSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF151515),
      builder: (context) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              for (final option in options)
                ListTile(
                  title: Text(labelOf(option)),
                  trailing: option == value
                      ? Icon(
                          Icons.check,
                          color: Theme.of(context).colorScheme.primary,
                        )
                      : null,
                  onTap: () {
                    Navigator.of(context).pop();
                    onChanged(option);
                  },
                ),
            ],
          ),
        );
      },
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.title,
    required this.value,
    this.onChanged,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: subtitle == null ? 68 : 82,
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle!,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: Colors.white54),
                  ),
                ],
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _BackPill extends StatelessWidget {
  const _BackPill({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(30),
      onTap: onBack,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xE6252525),
          borderRadius: BorderRadius.circular(30),
          boxShadow: const [
            BoxShadow(color: Colors.black54, blurRadius: 26, spreadRadius: 5),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.arrow_back, color: Colors.white70, size: 28),
              Text(
                '返回',
                style: Theme.of(
                  context,
                ).textTheme.labelMedium?.copyWith(color: Colors.white70),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ServiceSettingsPage extends ConsumerWidget {
  const ServiceSettingsPage({super.key, required this.kind});

  final String kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AsyncAnimeGate(
      builder: (context, state) {
        final settings = state.services;
        final controller = ref.read(animeControllerProvider.notifier);
        return Scaffold(
          backgroundColor: Colors.black,
          body: SafeArea(
            child: Stack(
              children: [
                ListView(
                  padding: const EdgeInsets.fromLTRB(8, 0, 12, 120),
                  children: [
                    _SettingsTitle(
                      onBack: () => safeNavigateBack(
                        context,
                        fallbackRoute: '/settings/playback',
                      ),
                      compact: false,
                    ),
                    const SizedBox(height: 12),
                    ...switch (kind) {
                      'media' => _mediaSourceCards(settings, controller),
                      'anime' => _animeSourceCards(settings, controller),
                      'sync' => _syncSourceCards(settings, controller),
                      'subtitles' => _subtitleSourceCards(settings, controller),
                      'danmaku' => _danmakuSourceCards(
                        settings,
                        controller,
                        context,
                      ),
                      _ => [
                        const _InfoCard(
                          title: '未知设置',
                          lines: ['这个入口暂时没有对应配置。'],
                        ),
                      ],
                    },
                  ],
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 24,
                  child: Center(
                    child: _BackPill(
                      onBack: () => safeNavigateBack(
                        context,
                        fallbackRoute: '/settings/playback',
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  List<Widget> _mediaSourceCards(
    ExternalServiceSettings settings,
    AnimeController controller,
  ) {
    return [
      const _InfoCard(
        title: '影视资料源：TVMaze',
        lines: [
          '用于电视剧、演员、剧照、海报、简介、评分、分类和播出日期。',
          'TVMaze 官方公开 API 不需要 Key；豆瓣没有稳定官方公开影视 API，后续可接自建适配。',
        ],
      ),
      const SizedBox(height: 12),
      _SettingsCard(
        children: [
          _SwitchRow(
            title: '启用影视资料源',
            subtitle: settings.mediaMetadataProvider,
            value: settings.mediaMetadataEnabled,
            onChanged: (value) => controller.updateServices(
              settings.copyWith(mediaMetadataEnabled: value),
            ),
          ),
          const _ActionRow(title: '豆瓣适配', subtitle: '保留自建接口扩展口，暂不内置非官方抓取'),
        ],
      ),
    ];
  }

  List<Widget> _animeSourceCards(
    ExternalServiceSettings settings,
    AnimeController controller,
  ) {
    return [
      const _InfoCard(
        title: '番剧资料源：AniList + Bangumi',
        lines: [
          'AniList 负责国际化动漫资料、角色、制作人员和 airing data。',
          'Bangumi 负责中文标题、收藏、评分和更贴近中文用户的放送信息。',
        ],
      ),
      const SizedBox(height: 12),
      _SettingsCard(
        children: [
          _SwitchRow(
            title: '启用 AniList',
            value: settings.anilistEnabled,
            onChanged: (value) => controller.updateServices(
              settings.copyWith(anilistEnabled: value),
            ),
          ),
          _SwitchRow(
            title: '启用 Bangumi',
            value: settings.bangumiEnabled,
            onChanged: (value) => controller.updateServices(
              settings.copyWith(bangumiEnabled: value),
            ),
          ),
          _SwitchRow(
            title: '优先中文标题',
            subtitle: 'Bangumi 有中文标题时优先展示中文',
            value: settings.preferBangumiChinese,
            onChanged: (value) => controller.updateServices(
              settings.copyWith(preferBangumiChinese: value),
            ),
          ),
        ],
      ),
    ];
  }

  List<Widget> _syncSourceCards(
    ExternalServiceSettings settings,
    AnimeController controller,
  ) {
    return [
      const _InfoCard(
        title: '观看记录 / 片单 / 评分',
        lines: [
          '免登录只能读取公开数据；写入云端历史一定需要账号授权。',
          '当前保留 Bangumi 公开收藏读取和本机播放记录框架，不需要授权配置。',
        ],
      ),
      const SizedBox(height: 12),
      _SettingsCard(
        children: [
          _SwitchRow(
            title: '启用公开收藏同步',
            value: settings.publicCollectionSyncEnabled,
            onChanged: (value) => controller.updateServices(
              settings.copyWith(publicCollectionSyncEnabled: value),
            ),
          ),
          _SwitchRow(
            title: '自动记录播放历史',
            value: settings.publicCollectionSyncEnabled,
            onChanged: (value) => controller.updateServices(
              settings.copyWith(publicCollectionSyncEnabled: value),
            ),
          ),
        ],
      ),
    ];
  }

  List<Widget> _subtitleSourceCards(
    ExternalServiceSettings settings,
    AnimeController controller,
  ) {
    return [
      const _InfoCard(
        title: '字幕源：Bilibili 公开字幕',
        lines: [
          '通过 B 站公开番剧搜索匹配 season/episode，再读取播放器公开字幕列表。',
          '不需要 API Key；没有官方字幕或需要登录权限时会显示未匹配。',
        ],
      ),
      const SizedBox(height: 12),
      _SettingsCard(
        children: [
          _SwitchRow(
            title: '启用 Bilibili 字幕',
            value: settings.bilibiliSubtitleEnabled,
            onChanged: (value) => controller.updateServices(
              settings.copyWith(bilibiliSubtitleEnabled: value),
            ),
          ),
          _SwitchRow(
            title: '自动匹配字幕',
            value: settings.autoMatchSubtitle,
            onChanged: (value) => controller.updateServices(
              settings.copyWith(autoMatchSubtitle: value),
            ),
          ),
          _ChoiceRow<String>(
            title: '默认字幕语言',
            value: settings.subtitleLanguage,
            options: const ['zh-CN', 'zh-TW', 'ja-JP', 'en-US'],
            labelOf: (value) => value,
            onChanged: (value) => controller.updateServices(
              settings.copyWith(subtitleLanguage: value),
            ),
          ),
        ],
      ),
    ];
  }

  List<Widget> _danmakuSourceCards(
    ExternalServiceSettings settings,
    AnimeController controller,
    BuildContext context,
  ) {
    return [
      const _InfoCard(
        title: '弹幕源：弹弹play / Bilibili / 自建弹幕库',
        lines: [
          '弹弹play 使用官方开放平台按番名和集数匹配弹幕库，需要填写 AppId 和 AppSecret。',
          '通过 B 站公开番剧搜索匹配当前集 cid，再读取公开弹幕 XML。',
          '自建弹幕库仍保留为用户自己的接口补充。',
        ],
      ),
      const SizedBox(height: 12),
      _SettingsCard(
        children: [
          _SwitchRow(
            title: '启用弹弹play弹幕',
            subtitle: settings.dandanplayAppId.trim().isEmpty
                ? '需要填写开放平台 AppId / AppSecret'
                : '已配置开放平台凭证',
            value: settings.dandanplayDanmakuEnabled,
            onChanged: (value) => controller.updateServices(
              settings.copyWith(dandanplayDanmakuEnabled: value),
            ),
          ),
          _ActionRow(
            title: '弹弹play开放平台',
            subtitle: settings.dandanplayAppId.trim().isEmpty
                ? '未填写'
                : settings.dandanplayAppId,
            onTap: () => _showDandanplayEditor(context, settings, controller),
          ),
          _SwitchRow(
            title: '启用 Bilibili 弹幕',
            value: settings.bilibiliDanmakuEnabled,
            onChanged: (value) => controller.updateServices(
              settings.copyWith(bilibiliDanmakuEnabled: value),
            ),
          ),
          _SwitchRow(
            title: '启用自建弹幕库',
            value: settings.customDanmakuEnabled,
            onChanged: (value) => controller.updateServices(
              settings.copyWith(customDanmakuEnabled: value),
            ),
          ),
          _ActionRow(
            title: '自建接口地址',
            subtitle: settings.customDanmakuEndpoint.isEmpty
                ? '未填写'
                : settings.customDanmakuEndpoint,
            onTap: () => _showEndpointEditor(context, settings, controller),
          ),
          _SwitchRow(
            title: '弹幕时间轴同步',
            value: settings.danmakuTimelineSync,
            onChanged: (value) => controller.updateServices(
              settings.copyWith(danmakuTimelineSync: value),
            ),
          ),
        ],
      ),
    ];
  }

  void _showDandanplayEditor(
    BuildContext context,
    ExternalServiceSettings settings,
    AnimeController controller,
  ) {
    final appId = TextEditingController(text: settings.dandanplayAppId);
    final appSecret = TextEditingController(text: settings.dandanplayAppSecret);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF151515),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              18,
              20,
              MediaQuery.viewInsetsOf(context).bottom + 20,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: appId,
                  decoration: const InputDecoration(labelText: 'AppId'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: appSecret,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'AppSecret'),
                ),
                const SizedBox(height: 14),
                FilledButton(
                  onPressed: () {
                    controller.updateServices(
                      settings.copyWith(
                        dandanplayAppId: appId.text.trim(),
                        dandanplayAppSecret: appSecret.text.trim(),
                      ),
                    );
                    Navigator.of(context).pop();
                  },
                  child: const Text('保存'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showEndpointEditor(
    BuildContext context,
    ExternalServiceSettings settings,
    AnimeController controller,
  ) {
    final text = TextEditingController(text: settings.customDanmakuEndpoint);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF151515),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              18,
              20,
              MediaQuery.viewInsetsOf(context).bottom + 20,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: text,
                  decoration: const InputDecoration(labelText: '自建弹幕接口地址'),
                ),
                const SizedBox(height: 14),
                FilledButton(
                  onPressed: () {
                    controller.updateServices(
                      settings.copyWith(
                        customDanmakuEndpoint: text.text.trim(),
                      ),
                    );
                    Navigator.of(context).pop();
                  },
                  child: const Text('保存'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.title, required this.lines});

  final String title;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF202020),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 10),
            for (final line in lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  line,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.white70,
                    height: 1.35,
                  ),
                ),
              ),
          ],
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
