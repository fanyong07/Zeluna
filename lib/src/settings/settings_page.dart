import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/anime_app.dart';
import '../data/anime_controller.dart';
import '../domain/anime_models.dart';

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
          onBack: () => Navigator.of(context).pop(),
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
  });

  final PlaybackSettings settings;
  final ValueChanged<PlaybackSettings> onChanged;
  final VoidCallback onBack;
  final bool compact;

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
                if (compact)
                  _SettingsCard(
                    children: const [
                      _ActionRow(title: '播放信息'),
                      _ActionRow(title: '按键说明', subtitle: '快捷键列表'),
                    ],
                  ),
                const SizedBox(height: 12),
                _VolumeCard(settings: settings, onChanged: onChanged),
                const SizedBox(height: 12),
                _SettingsCard(
                  children: [
                    _SwitchRow(
                      title: '超分辨率',
                      subtitle: '对硬件性能有要求，遇到卡顿请关闭',
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
              subtitle: 'Bilibili 公开弹幕 / 自建弹幕库框架',
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
    required this.onChanged,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

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
                      onBack: () => Navigator.of(context).pop(),
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
                    child: _BackPill(onBack: () => Navigator.of(context).pop()),
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
          '当前保留 Bangumi 公开收藏读取和本机播放记录框架，不需要 token。',
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
        title: '弹幕源：Bilibili / 自建弹幕库',
        lines: [
          '通过 B 站公开番剧搜索匹配当前集 cid，再读取公开弹幕 XML。',
          '不需要 AppId 或 AppSecret；没有 B 站条目时可后续接自建接口。',
        ],
      ),
      const SizedBox(height: 12),
      _SettingsCard(
        children: [
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
