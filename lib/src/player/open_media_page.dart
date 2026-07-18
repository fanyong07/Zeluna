import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../domain/anime_models.dart';
import '../shared_ui/app_chrome.dart';
import '../shared_ui/app_navigation.dart';

class OpenMediaPage extends StatefulWidget {
  const OpenMediaPage({super.key});

  @override
  State<OpenMediaPage> createState() => _OpenMediaPageState();
}

class _OpenMediaPageState extends State<OpenMediaPage> {
  final _title = TextEditingController();
  final _url = TextEditingController();
  final _headers = TextEditingController();
  bool _opening = false;

  @override
  void dispose() {
    _title.dispose();
    _url.dispose();
    _headers.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 760;
    return AppChrome(
      active: ChromeDestination.settings,
      title: '打开媒体',
      showSearch: false,
      onBack: () => safeNavigateBack(context, fallbackRoute: '/settings'),
      child: ListView(
        padding: EdgeInsets.fromLTRB(
          compact ? 14 : 24,
          compact ? 0 : 8,
          compact ? 14 : 24,
          120,
        ),
        children: [
          AppPanel(
            borderColor: AppColors.borderBright,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionTitle(
                  title: '播放本地文件或网络直链',
                  subtitle: '支持播放器可识别的 MP4、WebM、MKV、HLS 和 DASH 地址',
                ),
                const SizedBox(height: 18),
                TextField(
                  controller: _title,
                  decoration: const InputDecoration(
                    labelText: '标题（可选）',
                    hintText: '例如：测试视频 / 第 1 集',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _url,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: '媒体地址',
                    hintText: 'https://example.com/video.m3u8',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _headers,
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: '请求头（可选，每行一个）',
                    hintText: 'Referer: https://example.com/\nUser-Agent: ...',
                  ),
                ),
                const SizedBox(height: 18),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    FilledButton.icon(
                      onPressed: _opening ? null : _openUrl,
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('播放网络地址'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _opening ? null : _pickLocalFile,
                      icon: const Icon(Icons.folder_open_rounded),
                      label: const Text('选择本地文件'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          const AppPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SectionTitle(title: '说明'),
                SizedBox(height: 10),
                Text(
                  '这里不会上传文件，也不会保存账号或 Cookie。带鉴权的视频可以填写必要请求头；请只播放你有权访问的内容。',
                  style: TextStyle(color: AppColors.muted, height: 1.6),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openUrl() async {
    final value = _url.text.trim();
    final uri = Uri.tryParse(value);
    if (uri == null || (!uri.hasScheme && !value.startsWith('blob:'))) {
      _toast('请输入有效的媒体地址');
      return;
    }
    await _open(value, provider: '网络直链');
  }

  Future<void> _pickLocalFile() async {
    setState(() => _opening = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const [
          'mp4',
          'mkv',
          'webm',
          'mov',
          'avi',
          'm3u8',
          'mpd',
        ],
      );
      final file = result?.files.singleOrNull;
      final path = file?.xFile.path.trim() ?? '';
      if (path.isEmpty) return;
      if (_title.text.trim().isEmpty) _title.text = file?.name ?? '本地媒体';
      await _open(path, provider: '本地文件');
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _open(String value, {required String provider}) async {
    final title = _title.text.trim().isEmpty ? '自定义媒体' : _title.text.trim();
    final id = DateTime.now().microsecondsSinceEpoch.remainder(0x3fffffff);
    final subject = AnimeSubject(
      id: -id,
      title: title,
      originalTitle: title,
      summary: '由用户直接打开的本地文件或网络媒体。',
      coverUrl: null,
      bannerUrl: null,
      date: null,
      platform: '自定义',
      language: '',
      region: '本地',
      status: '可播放',
      categories: const [AnimeCategory(name: '自定义媒体')],
      tags: const [],
      totalEpisodes: 1,
      source: 'direct',
    );
    final episode = AnimeEpisode(
      id: -id,
      subjectId: -id,
      number: 1,
      title: title,
      airdate: null,
      duration: '',
      description: '',
    );
    final line = PlaybackLine(
      id: 'direct:$id',
      episodeId: episode.id,
      providerId: 'direct',
      providerName: provider,
      title: title,
      quality: '原始',
      format: _formatOf(value),
      url: value,
      headers: _parseHeaders(_headers.text),
      available: true,
    );
    if (!mounted) return;
    await context.push(
      '/player',
      extra: PlaySessionRequest(
        subject: subject,
        episodes: [episode],
        episode: episode,
        initialLine: line,
      ),
    );
  }

  Map<String, String> _parseHeaders(String text) {
    final result = <String, String>{};
    for (final line in text.split(RegExp(r'[\r\n]+'))) {
      final index = line.indexOf(':');
      if (index <= 0) continue;
      final key = line.substring(0, index).trim();
      final value = line.substring(index + 1).trim();
      if (key.isNotEmpty && value.isNotEmpty) result[key] = value;
    }
    return result;
  }

  String _formatOf(String value) {
    final path = value.toLowerCase().split('?').first;
    if (path.endsWith('.m3u8')) return 'HLS';
    if (path.endsWith('.mpd')) return 'DASH';
    if (path.endsWith('.mkv')) return 'MKV';
    if (path.endsWith('.webm')) return 'WebM';
    return 'MP4/媒体';
  }

  void _toast(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}
