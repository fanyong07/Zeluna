import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../domain/anime_models.dart';
import '../../shared_ui/app_design.dart';
import 'subtitle_document.dart';
import 'subtitle_matching.dart';
import 'subtitle_repository.dart';
import 'supplemental_subtitle_controller.dart';

class SubtitleImportFile {
  const SubtitleImportFile(this.name, this.bytes);
  final String name;
  final Uint8List bytes;
}

class SupplementalSubtitlePanel extends StatefulWidget {
  const SupplementalSubtitlePanel({
    super.key,
    required this.controller,
    required this.subject,
    required this.episode,
    required this.episodes,
    required this.createRepository,
    this.pickFiles,
  });
  final SupplementalSubtitleController controller;
  final AnimeSubject subject;
  final AnimeEpisode episode;
  final List<AnimeEpisode> episodes;
  final SubtitleRepository Function() createRepository;
  final Future<List<SubtitleImportFile>> Function()? pickFiles;
  @override
  State<SupplementalSubtitlePanel> createState() =>
      _SupplementalSubtitlePanelState();
}

class _SupplementalSubtitlePanelState extends State<SupplementalSubtitlePanel> {
  bool _busy = false;
  String? _message;
  List<SupplementalSubtitleCandidate> _candidates = [];
  List<SubtitleDocument> _imports = [];
  Map<int, int?> _bindings = {};
  int? _importGeneration;
  bool _clearConfirmation = false;
  SupplementalSubtitleController get c => widget.controller;
  bool _current(int generation) => mounted && c.isCurrent(generation);

  Future<void> _guard(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } on SubtitleFileException catch (e) {
      if (mounted) setState(() => _message = e.message);
    } catch (_) {
      if (mounted) setState(() => _message = '字幕操作未完成或未保存，请重试；原有字幕不受影响');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _search() => _guard(() async {
    _imports = [];
    _bindings = {};
    _candidates = [];
    await c.setEnabled(true);
    final generation = c.generation;
    final repository = widget.createRepository();
    try {
      final result = await repository.search(
        widget.subject,
        widget.episode,
        c.language,
        confirmedEntryId:
            c.store.preferences(c.subjectKey)['entryId'] as String?,
      );
      if (!_current(generation)) return;
      setState(() {
        _message = result.message;
        _candidates = result.candidates;
      });
      if (result.candidates.length == 1 && result.candidates.single.autoMatch) {
        await _download(result.candidates.single, repository, generation);
      }
    } finally {
      repository.dispose();
    }
  });

  Future<void> _download(
    SupplementalSubtitleCandidate candidate,
    SubtitleRepository repository,
    int generation,
  ) async {
    final document =
        c.store.sourceDocument(
          candidate.provider,
          candidate.entryId,
          candidate.id,
          candidate.language,
        ) ??
        await repository.download(candidate);
    if (!_current(generation)) return;
    if (!await c.selectDocument(document, expectedGeneration: generation)) {
      return;
    }
    if (!_current(generation)) return;
    await c.store.rememberSource(
      candidate.provider,
      candidate.entryId,
      document,
      sourceId: candidate.id,
    );
    if (!_current(generation)) return;
    await c.store.setPreferences(c.subjectKey, {
      ...c.store.preferences(c.subjectKey),
      'entryId': candidate.entryId,
      'provider': candidate.provider,
      'autoLookup': true,
    });
    if (_current(generation)) {
      setState(() => _message = '已加载原文字幕，请检查时间轴；可用提前／延后调整');
    }
  }

  Future<void> _chooseCandidate(SupplementalSubtitleCandidate candidate) =>
      _guard(() async {
        final generation = c.generation;
        final repository = widget.createRepository();
        try {
          await _download(candidate, repository, generation);
        } finally {
          repository.dispose();
        }
      });

  Future<List<SubtitleImportFile>> _pickFiles() async {
    if (widget.pickFiles != null) return widget.pickFiles!();
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: subtitleExtensions,
      allowMultiple: true,
    );
    if (result == null) return [];
    if (result.files.length > 40) {
      throw const SubtitleFileException('一次最多导入 40 个字幕文件');
    }
    var total = 0;
    final files = <SubtitleImportFile>[];
    for (final file in result.files) {
      final length = await file.xFile.length();
      total += length;
      if (length > maxSubtitleBytes || total > 20 * 1024 * 1024) {
        throw const SubtitleFileException('单个字幕不能超过 5 MB，一次导入总量不能超过 20 MB');
      }
      files.add(SubtitleImportFile(file.name, await file.xFile.readAsBytes()));
    }
    return files;
  }

  Future<void> _import() => _guard(() async {
    final generation = c.generation;
    final language = c.language;
    final files = await _pickFiles();
    if (!_current(generation) || files.isEmpty) return;
    final documents = files
        .map((f) => parseSubtitle(f.bytes, f.name, language))
        .toList();
    if (documents.length == 1) {
      if (await c.selectDocument(
            documents.single,
            expectedGeneration: generation,
          ) &&
          _current(generation)) {
        setState(() {
          _imports = [];
          _message = '已绑定当前集，原有中文字幕保持不变；请检查时间轴';
        });
      }
      return;
    }
    setState(() {
      _importGeneration = generation;
      _imports = documents;
      _bindings = {
        for (var i = 0; i < documents.length; i++)
          i: matchSubtitleFile(
            documents[i].fileName,
            widget.episodes,
          ).episode?.id,
      };
      _message = '请核对作品、分集和字幕版本。未指定的文件将跳过，不会自动覆盖其他集。';
    });
  });

  Future<void> _confirmImports() => _guard(() async {
    final generation = _importGeneration;
    if (generation == null || !_current(generation)) {
      setState(() {
        _imports = [];
        _message = '播放内容已改变，请重新选择文件';
      });
      return;
    }
    final selected = _bindings.values.whereType<int>().toList();
    if (selected.isEmpty || selected.toSet().length != selected.length) {
      throw const SubtitleFileException('请指定至少一个分集，同一集只能选择一个字幕文件');
    }
    var count = 0;
    for (var i = 0; i < _imports.length; i++) {
      final episode = widget.episodes
          .where((e) => e.id == _bindings[i])
          .firstOrNull;
      if (episode == null) continue;
      if (!_current(generation)) return;
      await c.store.bindDocument(
        episode.identityKey(subjectKey: widget.subject.identityKey),
        _imports[i],
      );
      count++;
    }
    if (!_current(generation)) return;
    final current = c.store.documentFor(c.episodeKey, c.language);
    if (current != null) {
      await c.selectDocument(current, expectedGeneration: generation);
    } else {
      await c.setEnabled(true);
    }
    if (mounted) {
      setState(() {
        _imports = [];
        _bindings = {};
        _message = '已保存 $count 集字幕，仅保存在当前账号本地';
      });
    }
  });

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) => ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        const Text(
          '保留片源字幕，只补原文',
          style: TextStyle(
            color: AppColors.theaterInk,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          '原有中文不会被关闭。烧录字幕无法自动识别；片源已双语时请关闭外挂。',
          style: TextStyle(color: AppColors.theaterMuted, height: 1.5),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          children: [
            for (final language in const {
              'ja': '日语',
              'en': '英语',
              'zh-Hans': '简中',
            }.entries)
              ChoiceChip(
                label: Text(language.value),
                selected: c.language == language.key,
                onSelected: _busy
                    ? null
                    : (_) => _guard(() async {
                        _imports = [];
                        _candidates = [];
                        await c.setLanguage(language.key);
                      }),
              ),
          ],
        ),
        if (c.language == 'zh-Hans')
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              '国语作品默认不补字幕，已有中文时无需重复导入。',
              style: TextStyle(color: AppColors.theaterMuted),
            ),
          ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('显示外挂字幕'),
          subtitle: const Text('关闭后，片源自带字幕仍会保留'),
          value: c.enabled && !c.bilingual,
          onChanged: _busy
              ? null
              : (v) => v && c.document == null
                    ? _search()
                    : _guard(() => c.setEnabled(v)),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('当前片源已有双语'),
          subtitle: const Text('记住当前集与线路，不再重复叠加'),
          value: c.bilingual,
          onChanged: _busy
              ? null
              : (v) => _guard(() => c.setBilingual(v ?? false)),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              onPressed: _busy ? null : _import,
              icon: const Icon(Icons.file_open_outlined),
              label: const Text('导入字幕'),
            ),
            OutlinedButton.icon(
              onPressed: _busy || c.language == 'zh-Hans' ? null : _search,
              icon: const Icon(Icons.search),
              label: Text(c.language == 'en' ? '查找内置英文' : '查找内置日语'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'SRT · ASS/SSA · VTT｜压缩包请先解压\n优先使用服务器内置字幕；未收录时不影响播放，也可手动导入。',
          style: TextStyle(color: AppColors.theaterMuted, height: 1.5),
        ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: LinearProgressIndicator(),
          ),
        if (_message != null || c.sourceMessage != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              _message ?? c.sourceMessage!,
              key: const ValueKey('subtitlePanelMessage'),
              style: const TextStyle(color: AppColors.theaterInk),
            ),
          ),
        for (final candidate in _candidates)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(candidate.fileName),
            subtitle: Text(
              '${candidate.provider} · ${candidate.reasons.join('；')}\n时间轴尚未验证',
            ),
            trailing: TextButton(
              onPressed: _busy ? null : () => _chooseCandidate(candidate),
              child: const Text('使用'),
            ),
          ),
        if (_imports.isNotEmpty) ...[
          const Divider(),
          const Text('确认分集绑定'),
          for (var i = 0; i < _imports.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _imports[i].fileName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    matchSubtitleFile(
                      _imports[i].fileName,
                      widget.episodes,
                    ).reason,
                    style: const TextStyle(color: AppColors.theaterMuted),
                  ),
                  DropdownButton<int>(
                    isExpanded: true,
                    value: _bindings[i] ?? -1,
                    items: [
                      const DropdownMenuItem(
                        value: -1,
                        child: Text('跳过 / 尚未指定'),
                      ),
                      for (final episode in widget.episodes)
                        DropdownMenuItem(
                          value: episode.id,
                          child: Text(
                            episode.displayTitle,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: _busy
                        ? null
                        : (v) =>
                              setState(() => _bindings[i] = v == -1 ? null : v),
                  ),
                ],
              ),
            ),
          FilledButton(
            onPressed: _busy ? null : _confirmImports,
            child: const Text('确认并保存分集字幕'),
          ),
          TextButton(
            onPressed: _busy ? null : () => setState(() => _imports = []),
            child: const Text('取消导入'),
          ),
        ],
        if (c.document != null) ...[
          const Divider(height: 28),
          Text(
            c.document!.fileName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            '时间偏移：${(c.delayMs / 1000).toStringAsFixed(1)} 秒（正数表示延后）',
            style: const TextStyle(color: AppColors.theaterMuted),
          ),
          Wrap(
            spacing: 4,
            children: [
              TextButton(
                onPressed: _busy
                    ? null
                    : () => _guard(() => c.adjustDelay(c.delayMs - 500)),
                child: const Text('提前 0.5 秒'),
              ),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => _guard(() => c.adjustDelay(c.delayMs + 500)),
                child: const Text('延后 0.5 秒'),
              ),
              TextButton(
                onPressed: _busy ? null : () => _guard(() => c.adjustDelay(0)),
                child: const Text('重置'),
              ),
            ],
          ),
        ],
        const Divider(height: 28),
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text('位置'),
            ChoiceChip(
              label: const Text('上方'),
              selected: c.top,
              onSelected: _busy
                  ? null
                  : (_) => _guard(() => c.setAppearance(atTop: true)),
            ),
            ChoiceChip(
              label: const Text('下方'),
              selected: !c.top,
              onSelected: _busy
                  ? null
                  : (_) => _guard(() => c.setAppearance(atTop: false)),
            ),
          ],
        ),
        Text('字号 ${c.fontSize.round()}'),
        Slider(
          value: c.fontSize,
          min: 14,
          max: 36,
          divisions: 22,
          label: '${c.fontSize.round()}',
          onChanged: _busy ? null : (v) => c.previewAppearance(size: v),
          onChangeEnd: _busy ? null : (_) => _guard(c.persistAppearance),
        ),
        const Text('与边缘的距离'),
        Slider(
          value: c.verticalInset,
          min: 0,
          max: .35,
          divisions: 35,
          onChanged: _busy ? null : (v) => c.previewAppearance(inset: v),
          onChangeEnd: _busy ? null : (_) => _guard(c.persistAppearance),
        ),
        const Divider(height: 28),
        if (!_clearConfirmation)
          TextButton.icon(
            icon: const Icon(Icons.delete_outline),
            label: const Text('清除当前账号字幕缓存'),
            onPressed: _busy
                ? null
                : () => setState(() => _clearConfirmation = true),
          )
        else ...[
          const Text('将清除当前账号导入的字幕、绑定及校时设置，其他账号和视频不受影响。'),
          Wrap(
            children: [
              TextButton(
                onPressed: _busy
                    ? null
                    : () => _guard(() async {
                        await c.clearCache();
                        if (mounted) {
                          setState(() {
                            _clearConfirmation = false;
                            _imports = [];
                            _candidates = [];
                            _message = '本地字幕缓存已清除';
                          });
                        }
                      }),
                child: const Text('确认清除'),
              ),
              TextButton(
                onPressed: () => setState(() => _clearConfirmation = false),
                child: const Text('取消'),
              ),
            ],
          ),
        ],
      ],
    ),
  );
}
