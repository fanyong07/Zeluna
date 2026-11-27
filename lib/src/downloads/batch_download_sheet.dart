import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/anime_controller.dart';
import '../data/media_download_task.dart';
import '../domain/anime_models.dart';
import '../domain/episode_matching.dart';
import 'download_network_guard.dart';

Future<void> showBatchDownloadSheet(
  BuildContext context,
  WidgetRef ref, {
  required AnimeDetailBundle bundle,
  LibraryEntry? historyEntry,
}) async {
  final account = ref
      .read(animeControllerProvider.notifier)
      .accountContextVersion;
  final count = await showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => _BatchSheet(
      bundle: bundle,
      lastWatched: historyEntry?.episode?.number ?? 0,
      account: account,
    ),
  );
  if (count != null && context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已加入 $count 集到下载队列')));
  }
}

class _BatchSheet extends ConsumerStatefulWidget {
  const _BatchSheet({
    required this.bundle,
    required this.lastWatched,
    required this.account,
  });
  final AnimeDetailBundle bundle;
  final int lastWatched;
  final int account;
  @override
  ConsumerState<_BatchSheet> createState() => _BatchSheetState();
}

class _BatchSheetState extends ConsumerState<_BatchSheet> {
  late final episodes = widget.bundle.episodes.where(isMainEpisode).toList();
  final selected = <int>{};
  bool busy = false;

  Map<int, String> blocked(List<MediaDownloadTask> tasks) => {
    for (final task in tasks)
      if (sameSubjectIdentity(task.subject, widget.bundle.subject) &&
          (task.isActive || task.isPlayable))
        task.episode.id: task.isActive ? '下载中' : '已缓存',
  };

  Future<void> submit(List<AnimeEpisode> picked) async {
    final controller = ref.read(animeControllerProvider.notifier);
    setState(() => busy = true);
    var count = 0;
    try {
      if (!await confirmDownloadNetwork(context, ref) || !mounted) return;
      for (final episode in picked) {
        if (!mounted || !controller.isAccountContextCurrent(widget.account)) {
          return;
        }
        final tasks = ref
            .read(animeControllerProvider)
            .requireValue
            .offlineTasks;
        if (blocked(tasks).containsKey(episode.id)) continue;
        await controller.queueOffline(widget.bundle.subject, episode);
        count++;
      }
      if (mounted) Navigator.pop(context, count);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已加入 $count 集，未完成的集数可重试')));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tasks = ref.watch(
      animeControllerProvider.select(
        (state) => state.requireValue.offlineTasks,
      ),
    );
    final labels = blocked(tasks);
    final available = episodes.where((e) => !labels.containsKey(e.id));
    final picked = available.where((e) => selected.contains(e.id)).toList();
    void select(Iterable<AnimeEpisode> items) => setState(() {
      selected
        ..clear()
        ..addAll(items.map((e) => e.id));
    });
    final scheme = Theme.of(context).colorScheme;
    return FractionallySizedBox(
      heightFactor: .82,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '批量缓存',
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                      ),
                      Text(
                        '共 ${episodes.length} 集正片',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    widget.bundle.subject.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      FilledButton.tonal(
                        key: const ValueKey('batchDownloadRemainingUnwatched'),
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                        ),
                        onPressed: busy
                            ? null
                            : () => select(
                                available.where(
                                  (e) => e.number > widget.lastWatched,
                                ),
                              ),
                        child: const Text('缓存剩余未看'),
                      ),
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                        ),
                        onPressed: busy ? null : () => select(available),
                        child: const Text('全选未缓存'),
                      ),
                      TextButton(
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                        ),
                        onPressed: busy ? null : () => select(const []),
                        child: const Text('清空选择'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                itemCount: episodes.length,
                separatorBuilder: (_, _) => const SizedBox(height: 6),
                itemBuilder: (_, index) {
                  final e = episodes[index];
                  final label = labels[e.id];
                  final watched = e.number <= widget.lastWatched;
                  final statusText = label ?? (watched ? '已看' : '未缓存');
                  final isSelected = label == null && selected.contains(e.id);
                  final statusColor = switch (label) {
                    '已缓存' => const Color(0xFF2E9B63),
                    '下载中' => scheme.primary,
                    _ => scheme.onSurfaceVariant,
                  };
                  return Material(
                    color: isSelected
                        ? scheme.primaryContainer.withValues(alpha: 0.42)
                        : scheme.surfaceContainerLow,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                      side: BorderSide(
                        color: isSelected
                            ? scheme.primary.withValues(alpha: 0.55)
                            : scheme.outlineVariant.withValues(alpha: 0.45),
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: CheckboxListTile(
                      dense: true,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(
                        e.displayTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: label != null
                              ? scheme.onSurfaceVariant
                              : scheme.onSurface,
                        ),
                      ),
                      secondary: DecoratedBox(
                        decoration: BoxDecoration(
                          color: statusColor.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          child: Text(
                            statusText,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: statusColor,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                        ),
                      ),
                      value: isSelected,
                      onChanged: busy || label != null
                          ? null
                          : (value) => setState(() {
                              if (value!) {
                                selected.add(e.id);
                              } else {
                                selected.remove(e.id);
                              }
                            }),
                    ),
                  );
                },
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '已选 ${picked.length} 集',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  FilledButton(
                    key: const ValueKey('batchDownloadConfirm'),
                    onPressed: busy || picked.isEmpty
                        ? null
                        : () => submit(picked),
                    child: Text(busy ? '加入中…' : '开始缓存'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
