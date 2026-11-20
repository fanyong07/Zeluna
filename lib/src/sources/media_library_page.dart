import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../shared_ui/app_navigation.dart';
import 'media_library_adapter.dart';

class MediaLibraryPage extends ConsumerStatefulWidget {
  const MediaLibraryPage({super.key});

  @override
  ConsumerState<MediaLibraryPage> createState() => _MediaLibraryPageState();
}

class _MediaLibraryPageState extends ConsumerState<MediaLibraryPage> {
  MediaLibraryAdapter get _adapter => ref.read(mediaLibraryAdapterProvider)!;
  late Future<List<MediaLibraryConfig>?> _libraries;
  bool _removing = false;

  @override
  void initState() {
    super.initState();
    _libraries = _adapter.libraries();
  }

  void _refresh() {
    final libraries = _adapter.libraries();
    setState(() {
      _libraries = libraries;
    });
  }

  Future<void> _edit([MediaLibraryConfig? library]) async {
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _LibraryEditor(adapter: _adapter, library: library),
    );
    if (mounted && saved == true) _refresh();
  }

  Future<void> _remove(MediaLibraryConfig library) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移除媒体库？'),
        content: const Text('只删除本机保存的连接信息，不会删除服务器上的文件。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    setState(() => _removing = true);
    final removed = await _adapter.removeLibrary(library.id);
    if (!mounted) return;
    setState(() => _removing = false);
    if (removed) {
      _refresh();
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法更新本机安全存储，请重试。')));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('媒体源'),
      leading: BackButton(
        onPressed: () => safeNavigateBack(context, fallbackRoute: '/settings'),
      ),
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: FutureBuilder<List<MediaLibraryConfig>?>(
          future: _libraries,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final libraries = snapshot.data;
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 48),
              children: [
                const Text('为电影、剧集和番剧查找私有线路。地址和凭据仅保存于本机，不会参与云同步。'),
                const SizedBox(height: 16),
                if (libraries == null) ...[
                  const Text('暂时无法读取本机安全存储。在线播放仍可使用。'),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: _refresh,
                      child: const Text('重试'),
                    ),
                  ),
                ] else ...[
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.icon(
                      onPressed: _removing ? null : () => _edit(),
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('添加媒体库'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (libraries.isEmpty) const Text('还没有添加媒体库'),
                  for (final library in libraries)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.storage_rounded),
                        title: Text(
                          library.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${library.kind.label} · ${library.endpoint}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: _removing ? null : () => _edit(library),
                        trailing: IconButton(
                          tooltip: '移除媒体库',
                          onPressed: _removing ? null : () => _remove(library),
                          icon: const Icon(Icons.remove_circle_outline),
                        ),
                      ),
                    ),
                ],
              ],
            );
          },
        ),
      ),
    ),
  );
}

class _LibraryEditor extends StatefulWidget {
  const _LibraryEditor({required this.adapter, this.library});

  final MediaLibraryAdapter adapter;
  final MediaLibraryConfig? library;

  @override
  State<_LibraryEditor> createState() => _LibraryEditorState();
}

class _LibraryEditorState extends State<_LibraryEditor> {
  late var _kind = widget.library?.kind ?? MediaLibraryKind.emby;
  late final _name = TextEditingController(text: widget.library?.name);
  late final _endpoint = TextEditingController(
    text: widget.library?.endpoint.toString(),
  );
  final _username = TextEditingController();
  final _secret = TextEditingController();
  bool _usePasswordAuth = false;
  String? _error;
  String? _testMessage;
  bool _testing = false;
  bool _saving = false;

  bool get _busy => _saving || _testing;

  @override
  void dispose() {
    for (final controller in [_name, _endpoint, _username, _secret]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _testConnection() async {
    if (_busy) return;
    setState(() {
      _error = null;
      _testMessage = null;
      _testing = true;
    });
    try {
      final message = await widget.adapter.testConnection(
        kind: _kind,
        endpoint: _endpoint.text,
        username: _username.text,
        secret: _secret.text,
        usePasswordAuth: _kind != MediaLibraryKind.webdav && _usePasswordAuth,
      );
      if (!mounted) return;
      setState(() {
        _testMessage = message;
        _testing = false;
      });
    } on FormatException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _testing = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '连接测试失败，请检查地址和网络。';
        _testing = false;
      });
    }
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() {
      _error = null;
      _testMessage = null;
      _saving = true;
    });
    try {
      var secret = _secret.text;
      var userId = '';
      if (_kind != MediaLibraryKind.webdav && _usePasswordAuth) {
        final auth = await widget.adapter.authenticateApiUser(
          kind: _kind,
          endpoint: _endpoint.text,
          username: _username.text,
          password: _secret.text,
        );
        secret = auth.token;
        userId = auth.userId;
      }
      final saved = await widget.adapter.saveLibrary(
        replaceId: widget.library?.id,
        name: _name.text,
        kind: _kind,
        endpoint: _endpoint.text,
        username: _kind == MediaLibraryKind.webdav ? _username.text : '',
        secret: secret,
        userId: userId,
      );
      if (!mounted) return;
      if (saved) {
        Navigator.pop(context, true);
        return;
      }
      _error = '无法写入本机安全存储，请重试。';
    } on FormatException catch (error) {
      _error = error.message;
    } catch (_) {
      _error = '保存失败，请检查服务器连接与输入内容。';
    }
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final isDav = _kind == MediaLibraryKind.webdav;
    final showUsername = isDav || _usePasswordAuth;
    return AlertDialog(
      scrollable: true,
      title: Text(widget.library == null ? '添加媒体库' : '编辑媒体库'),
      content: SizedBox(
        width: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<MediaLibraryKind>(
              initialValue: _kind,
              decoration: const InputDecoration(labelText: '类型'),
              items: [
                for (final kind in MediaLibraryKind.values)
                  DropdownMenuItem(value: kind, child: Text(kind.label)),
              ],
              onChanged: _busy
                  ? null
                  : (kind) => setState(() {
                      _kind = kind!;
                      _error = null;
                      _testMessage = null;
                      _secret.clear();
                    }),
            ),
            if (!isDav) ...[
              const SizedBox(height: 10),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('API 密钥')),
                  ButtonSegment(value: true, label: Text('账号密码登录')),
                ],
                selected: {_usePasswordAuth},
                onSelectionChanged: _busy
                    ? null
                    : (selection) => setState(() {
                        _usePasswordAuth = selection.first;
                        _error = null;
                        _testMessage = null;
                        _secret.clear();
                      }),
              ),
            ],
            TextField(
              controller: _name,
              enabled: !_busy,
              decoration: const InputDecoration(labelText: '名称'),
            ),
            TextField(
              controller: _endpoint,
              enabled: !_busy,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: isDav ? 'WebDAV 目录地址' : '服务器地址',
                hintText: isDav
                    ? 'http://192.168.1.2:5244/dav/影视/'
                    : 'http://192.168.1.2:8096/',
              ),
            ),
            if (showUsername)
              TextField(
                controller: _username,
                enabled: !_busy,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: isDav ? '用户名（匿名可留空）' : '用户名',
                ),
              ),
            TextField(
              controller: _secret,
              enabled: !_busy,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: isDav
                    ? '密码（匿名可留空）'
                    : (_usePasswordAuth ? '密码' : 'API 密钥'),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              isDav
                  ? '支持局域网 HTTP 或 HTTPS，支持 Alist 网盘 302 直链。支持「剧名/Season 1/01.mkv」、「[字幕组] 剧名 - 01.mkv」、「剧名.S01E01.mkv」等命名。'
                  : '支持局域网 HTTP 或 HTTPS，支持 Emby 302 直链。账号密码登录仅保存服务端签发的令牌，不保存密码。',
            ),
            if (widget.library != null) const Text('编辑时需重新输入凭据。'),
            if (_testMessage case final ok?)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  ok,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            if (_error case final error?)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : _testConnection,
          child: Text(_testing ? '测试中…' : '测试连接'),
        ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: Text(_saving ? '保存中…' : '保存'),
        ),
      ],
    );
  }
}
