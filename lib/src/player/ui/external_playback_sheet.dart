import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../shared_ui/app_design.dart';
import '../dlna_cast_service.dart';
import '../external_player_launcher.dart';

Future<void> showExternalPlaybackSheet(
  BuildContext context, {
  required String url,
  required String title,
}) => showModalBottomSheet<void>(
  context: context,
  useSafeArea: true,
  isScrollControlled: true,
  backgroundColor: AppColors.theaterBg,
  showDragHandle: true,
  builder: (_) => Theme(
    data: ThemeData.dark(useMaterial3: true).copyWith(
      colorScheme: ThemeData.dark(useMaterial3: true).colorScheme.copyWith(
        primary: AppColors.primary2,
        surface: AppColors.theaterBg,
      ),
    ),
    child: Material(
      type: MaterialType.transparency,
      child: _PlaybackSheet(url: url, title: title),
    ),
  ),
);

class _PlaybackSheet extends StatefulWidget {
  const _PlaybackSheet({required this.url, required this.title});
  final String url, title;
  @override
  State<_PlaybackSheet> createState() => _PlaybackSheetState();
}

class _PlaybackSheetState extends State<_PlaybackSheet> {
  final dlna = const DlnaCastService();
  late Future<List<DlnaDevice>> scan = dlna.discoverDevices();
  late final players = detectWindowsExternalPlayers();
  bool busy = false;
  String feedback = '';

  Future<void> perform(
    Future<bool> Function() action,
    String success,
    String failure,
  ) async {
    setState(() {
      busy = true;
      feedback = '';
    });
    String message;
    try {
      message = await action() ? success : failure;
    } on Exception {
      message = failure;
    }
    if (mounted) {
      setState(() {
        busy = false;
        feedback = message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget sectionCard({
      required IconData icon,
      required String title,
      Widget? trailing,
      required List<Widget> children,
    }) => DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.theaterPanelHigh.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.theaterBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, size: 17, color: AppColors.primary2),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      color: AppColors.theaterInk,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .78,
        ),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 20),
          children: [
            Text(
              '投屏与外部播放',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: AppColors.theaterInk,
                fontWeight: FontWeight.w800,
              ),
            ),
            if (widget.title.trim().isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.theaterMuted,
                  fontSize: 12,
                ),
              ),
            ],
            if (feedback.isNotEmpty) ...[
              const SizedBox(height: 12),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: AppColors.primary2.withValues(alpha: 0.34),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 9,
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.info_outline_rounded,
                        size: 16,
                        color: AppColors.primary2,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Semantics(
                          liveRegion: true,
                          child: Text(
                            feedback,
                            style: const TextStyle(
                              color: AppColors.theaterInk,
                              fontSize: 12,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (!kIsWeb) ...[
              const SizedBox(height: 14),
              FutureBuilder(
                future: scan,
                builder: (context, snapshot) {
                  final scanning =
                      snapshot.connectionState != ConnectionState.done;
                  return sectionCard(
                    icon: Icons.cast_connected_rounded,
                    title: '局域网 DLNA 投屏',
                    trailing: TextButton.icon(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      onPressed: scanning || busy
                          ? null
                          : () => setState(() => scan = dlna.discoverDevices()),
                      icon: const Icon(Icons.refresh_rounded, size: 15),
                      label: const Text('重新扫描', style: TextStyle(fontSize: 12)),
                    ),
                    children: [
                      if (scanning)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: LinearProgressIndicator(minHeight: 3),
                        )
                      else if (snapshot.hasError)
                        const Text(
                          '扫描失败，请检查本机局域网连接后重试。',
                          style: TextStyle(
                            color: AppColors.theaterMuted,
                            fontSize: 12,
                          ),
                        )
                      else if (snapshot.requireData.isEmpty)
                        const Text(
                          '未发现设备，请确认电视与本机在同一局域网，并已开启 DLNA。',
                          style: TextStyle(
                            color: AppColors.theaterMuted,
                            fontSize: 12,
                            height: 1.45,
                          ),
                        )
                      else
                        for (final device in snapshot.requireData)
                          ListTile(
                            dense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 4,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                            leading: const Icon(
                              Icons.tv_rounded,
                              color: AppColors.theaterInk,
                            ),
                            title: Text(
                              device.name,
                              style: const TextStyle(
                                color: AppColors.theaterInk,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            subtitle: Text(
                              device.host,
                              style: const TextStyle(
                                color: AppColors.theaterMuted,
                                fontSize: 11,
                              ),
                            ),
                            trailing: const Icon(
                              Icons.chevron_right_rounded,
                              color: AppColors.theaterMuted,
                            ),
                            onTap: busy
                                ? null
                                : () => perform(
                                    () async {
                                      await dlna.castMedia(
                                        device,
                                        mediaUrl: widget.url,
                                        title: widget.title,
                                      );
                                      return true;
                                    },
                                    '已向 ${device.name} 发送播放请求',
                                    '投屏失败，请确认设备在线并支持当前播放地址。',
                                  ),
                          ),
                    ],
                  );
                },
              ),
            ],
            const SizedBox(height: 12),
            sectionCard(
              icon: Icons.open_in_new_rounded,
              title: '使用外部播放器打开',
              children: [
                if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
                  ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    leading: const Icon(
                      Icons.play_circle_outline_rounded,
                      color: AppColors.theaterInk,
                    ),
                    title: const Text(
                      '选择本机视频播放器',
                      style: TextStyle(
                        color: AppColors.theaterInk,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    trailing: const Icon(
                      Icons.chevron_right_rounded,
                      color: AppColors.theaterMuted,
                    ),
                    onTap: busy
                        ? null
                        : () => perform(
                            () => launchAndroidExternalPlayer(
                              url: widget.url,
                              title: widget.title,
                            ),
                            '已打开播放器选择器',
                            '无法打开播放器，请确认已安装视频播放器。',
                          ),
                  )
                else if (!kIsWeb &&
                    defaultTargetPlatform == TargetPlatform.windows)
                  FutureBuilder(
                    future: players,
                    builder: (context, snapshot) {
                      if (snapshot.connectionState != ConnectionState.done) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: LinearProgressIndicator(minHeight: 3),
                        );
                      }
                      if (snapshot.hasError) {
                        return const Text(
                          '无法读取本机播放器列表。',
                          style: TextStyle(
                            color: AppColors.theaterMuted,
                            fontSize: 12,
                          ),
                        );
                      }
                      if (snapshot.requireData.isEmpty) {
                        return const Text(
                          '未检测到 mpv、PotPlayer 或 VLC，可复制直链播放。',
                          style: TextStyle(
                            color: AppColors.theaterMuted,
                            fontSize: 12,
                            height: 1.45,
                          ),
                        );
                      }
                      return Column(
                        children: [
                          for (final app in snapshot.requireData)
                            ListTile(
                              dense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 4,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                              leading: const Icon(
                                Icons.play_circle_outline_rounded,
                                color: AppColors.theaterInk,
                              ),
                              title: Text(
                                app.name,
                                style: const TextStyle(
                                  color: AppColors.theaterInk,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              trailing: const Icon(
                                Icons.chevron_right_rounded,
                                color: AppColors.theaterMuted,
                              ),
                              onTap: busy
                                  ? null
                                  : () => perform(
                                      () => launchWindowsExternalPlayer(
                                        app,
                                        url: widget.url,
                                      ),
                                      '已打开 ${app.name}',
                                      '无法启动 ${app.name}，请确认仍已安装。',
                                    ),
                            ),
                        ],
                      );
                    },
                  )
                else
                  const Text(
                    '当前平台可复制播放地址后在播放器中打开。',
                    style: TextStyle(
                      color: AppColors.theaterMuted,
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            sectionCard(
              icon: Icons.link_rounded,
              title: '播放直链',
              children: [
                ListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  leading: const Icon(
                    Icons.copy_rounded,
                    color: AppColors.theaterInk,
                  ),
                  title: const Text(
                    '复制播放直链',
                    style: TextStyle(
                      color: AppColors.theaterInk,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    widget.url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.theaterMuted,
                      fontSize: 11,
                    ),
                  ),
                  onTap: busy
                      ? null
                      : () => perform(
                          () async {
                            await Clipboard.setData(
                              ClipboardData(text: widget.url),
                            );
                            return true;
                          },
                          '已复制播放直链',
                          '复制失败，请重试。',
                        ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
