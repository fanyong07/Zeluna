import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../shared_ui/settings_ui.dart';
import 'app_update_controller.dart';

class AppUpdateCard extends ConsumerStatefulWidget {
  const AppUpdateCard({super.key});
  @override
  ConsumerState<AppUpdateCard> createState() => _AppUpdateCardState();
}

class _AppUpdateCardState extends ConsumerState<AppUpdateCard> {
  @override
  void initState() {
    super.initState();
    unawaited(ref.read(appUpdateControllerProvider).initialize());
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(appUpdateControllerProvider);
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        if (!controller.supported) {
          return const SettingsCard(
            children: [
              SettingsReadonlyRow(title: '应用内更新', value: '当前提供 Android 安装包更新'),
            ],
          );
        }
        final release = controller.release;
        final progress = controller.progress;
        final downloading = controller.phase == AppUpdatePhase.downloading;
        final permission =
            controller.phase == AppUpdatePhase.permissionRequired;
        final ready = controller.hasInstaller;
        return SettingsCard(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('应用更新', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Semantics(liveRegion: true, child: Text(_status(controller))),
                  if (controller.lastChecked != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      '上次检查：${_date(controller.lastChecked!)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                  if (release != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      '${release.displayVersion} · ${_size(release.bytes)}',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    if (release.notes.trim().isNotEmpty) ...[
                      const SizedBox(height: 8),
                      // Release text is data, never interpreted as HTML or actions.
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 220),
                        child: SingleChildScrollView(
                          child: SelectableText(release.notes),
                        ),
                      ),
                    ],
                    if (release.releasePage != null)
                      TextButton.icon(
                        onPressed: () async {
                          var opened = false;
                          try {
                            opened = await launchUrl(
                              release.releasePage!,
                              mode: LaunchMode.externalApplication,
                            );
                          } catch (_) {}
                          if (!opened && context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('发布说明暂时打不开，请稍后重试')),
                            );
                          }
                        },
                        icon: const Icon(Icons.open_in_new, size: 16),
                        label: const Text('查看完整发布说明'),
                      ),
                  ],
                  if (controller.busy) ...[
                    const SizedBox(height: 16),
                    LinearProgressIndicator(
                      value:
                          downloading && progress != null && progress.total > 0
                          ? (progress.received / progress.total).clamp(0.0, 1.0)
                          : null,
                    ),
                    if (downloading && progress != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        '${_size(progress.received)} / ${_size(progress.total)}',
                      ),
                    ],
                  ],
                  if (controller.errorMessage != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      controller.errorMessage!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (controller.canCancel)
                        OutlinedButton(
                          onPressed: controller.cancel,
                          child: const Text('取消'),
                        ),
                      if (!controller.busy && !ready)
                        OutlinedButton.icon(
                          onPressed: controller.check,
                          icon: const Icon(Icons.refresh),
                          label: const Text('检查更新'),
                        ),
                      if (!controller.busy && release != null && !ready)
                        FilledButton.icon(
                          onPressed: controller.download,
                          icon: const Icon(Icons.download_outlined),
                          label: Text(
                            controller.phase == AppUpdatePhase.failed
                                ? '重新下载'
                                : '下载更新',
                          ),
                        ),
                      if (!controller.busy && ready && permission) ...[
                        FilledButton(
                          onPressed: controller.openPermissionSettings,
                          child: const Text('允许安装应用'),
                        ),
                        OutlinedButton(
                          onPressed: controller.onResumed,
                          child: const Text('我已开启，继续'),
                        ),
                      ],
                      if (!controller.busy && ready && !permission)
                        FilledButton.icon(
                          onPressed: controller.install,
                          icon: const Icon(Icons.system_update_alt),
                          label: Text(
                            controller.phase == AppUpdatePhase.installerOpened
                                ? '再次打开安装'
                                : '立即安装',
                          ),
                        ),
                      if (!controller.busy && ready)
                        TextButton(
                          onPressed: controller.discardDownload,
                          child: const Text('删除安装包'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    permission
                        ? '在系统设置中开启“允许来自此来源的应用”，返回后再点击“立即安装”。'
                        : '仅下载同包名、同签名的新版本。安装由 Android 确认；无需卸载旧版，现有数据会保留。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (downloading) ...[
                    const SizedBox(height: 6),
                    Text(
                      '下载期间请保持应用运行；离开此页面会继续下载，取消或进程退出后可重新下载。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
            SettingsSwitchRow(
              title: '启动时检查更新',
              subtitle: '每天最多检查一次，仅提示，不自动下载或安装；播放时不打扰',
              value: controller.automaticChecks,
              onChanged: (value) =>
                  unawaited(controller.setAutomaticChecks(value)),
            ),
          ],
        );
      },
    );
  }

  String _status(AppUpdateController value) => switch (value.phase) {
    AppUpdatePhase.idle => '点击下方按钮检查新版本',
    AppUpdatePhase.checking => '正在检查更新…',
    AppUpdatePhase.upToDate => '当前已是最新可用版本',
    AppUpdatePhase.available => '发现新版本',
    AppUpdatePhase.downloading => '正在下载安装包…',
    AppUpdatePhase.verifying => '正在验证安装包完整性、版本和签名…',
    AppUpdatePhase.ready => '安装包已验证，可以安装',
    AppUpdatePhase.permissionRequired => '需要开启本应用的安装来源权限',
    AppUpdatePhase.openingInstaller => '正在验证并打开系统安装界面…',
    AppUpdatePhase.installerOpened => '已打开系统安装界面，请完成安装；取消后可再次打开',
    AppUpdatePhase.failed => '更新操作未完成',
    AppUpdatePhase.unsupported => '当前提供 Android 安装包更新',
  };
}

String _size(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
String _date(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
}
