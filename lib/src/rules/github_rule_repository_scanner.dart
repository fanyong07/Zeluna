import 'dart:convert';

import 'package:http/http.dart' as http;

class GitHubRuleRepositoryScanner {
  const GitHubRuleRepositoryScanner({
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
    this.maxFileBytes = 5 * 1024 * 1024,
    this.maxCandidates = 80,
  }) : _client = client;

  final http.Client? _client;
  final Duration timeout;
  final int maxFileBytes;
  final int maxCandidates;

  static bool isRepositoryUrl(String value) =>
      _repositoryParts(Uri.tryParse(value.trim())) != null;

  Future<GitHubRepositoryScan> scan(String repositoryUrl) async {
    final parts = _repositoryParts(Uri.tryParse(repositoryUrl.trim()));
    if (parts == null) {
      throw const FormatException(
        '请输入 GitHub 仓库首页地址，例如 https://github.com/owner/repo。',
      );
    }

    final ownedClient = _client == null;
    final client = _client ?? http.Client();
    final headers = const {'Accept': 'application/vnd.github+json'};
    try {
      final metadataUri = Uri.https(
        'api.github.com',
        '/repos/${parts.owner}/${parts.repository}',
      );
      final metadataResponse = await client
          .get(metadataUri, headers: headers)
          .timeout(timeout);
      _ensureGitHubSuccess(metadataResponse, '读取 GitHub 仓库信息');
      final metadata = jsonDecode(metadataResponse.body);
      if (metadata is! Map) {
        throw const FormatException('GitHub 仓库信息格式无效。');
      }
      final branch = metadata['default_branch']?.toString().trim() ?? '';
      if (branch.isEmpty) {
        throw const FormatException('GitHub 仓库没有可扫描的默认分支。');
      }

      final treeUri = Uri.https(
        'api.github.com',
        '/repos/${parts.owner}/${parts.repository}/git/trees/$branch',
        const {'recursive': '1'},
      );
      final treeResponse = await client
          .get(treeUri, headers: headers)
          .timeout(timeout);
      _ensureGitHubSuccess(treeResponse, '扫描 GitHub 仓库文件');
      final treeData = jsonDecode(treeResponse.body);
      if (treeData is! Map || treeData['tree'] is! List) {
        throw const FormatException('GitHub 仓库文件列表格式无效。');
      }

      final candidates = <GitHubRuleCandidate>[];
      for (final item in (treeData['tree'] as List).whereType<Map>()) {
        if (item['type']?.toString() != 'blob') continue;
        final path = item['path']?.toString().trim() ?? '';
        final lowerPath = path.toLowerCase();
        if (!lowerPath.endsWith('.json') && !lowerPath.endsWith('.txt')) {
          continue;
        }
        final size = _intValue(item['size']);
        final reason = _blockedReason(size, maxFileBytes);
        candidates.add(
          GitHubRuleCandidate(
            path: path,
            size: size,
            rawUrl: Uri.https(
              'raw.githubusercontent.com',
              '/${parts.owner}/${parts.repository}/$branch/$path',
            ).toString(),
            blockedReason: reason,
          ),
        );
        if (candidates.length >= maxCandidates) break;
      }

      candidates.sort((a, b) {
        final safety = (a.canImport ? 0 : 1).compareTo(b.canImport ? 0 : 1);
        return safety != 0 ? safety : a.path.compareTo(b.path);
      });
      return GitHubRepositoryScan(
        name:
            metadata['full_name']?.toString() ??
            '${parts.owner}/${parts.repository}',
        defaultBranch: branch,
        candidates: candidates,
        truncated: treeData['truncated'] == true,
      );
    } finally {
      if (ownedClient) client.close();
    }
  }
}

class GitHubRepositoryScan {
  const GitHubRepositoryScan({
    required this.name,
    required this.defaultBranch,
    required this.candidates,
    required this.truncated,
  });

  final String name;
  final String defaultBranch;
  final List<GitHubRuleCandidate> candidates;
  final bool truncated;
}

class GitHubRuleCandidate {
  const GitHubRuleCandidate({
    required this.path,
    required this.size,
    required this.rawUrl,
    this.blockedReason,
  });

  final String path;
  final int size;
  final String rawUrl;
  final String? blockedReason;

  bool get canImport => blockedReason == null;

  String get sizeLabel {
    if (size < 1024) return '$size B';
    return '${(size / 1024).toStringAsFixed(1)} KB';
  }
}

class _GitHubRepositoryParts {
  const _GitHubRepositoryParts(this.owner, this.repository);

  final String owner;
  final String repository;
}

_GitHubRepositoryParts? _repositoryParts(Uri? uri) {
  if (uri == null || uri.scheme != 'https') return null;
  final host = uri.host.toLowerCase();
  if (host != 'github.com' && host != 'www.github.com') return null;
  final segments = uri.pathSegments.where((item) => item.isNotEmpty).toList();
  if (segments.length != 2) return null;
  final repository = segments[1].replaceFirst(RegExp(r'\.git$'), '');
  if (segments[0].isEmpty || repository.isEmpty) return null;
  return _GitHubRepositoryParts(segments[0], repository);
}

String? _blockedReason(int size, int maxFileBytes) {
  if (size <= 0) return '空文件，无法导入';
  if (size > maxFileBytes) {
    return '文件超过 ${_byteSizeLabel(maxFileBytes)} 读取上限';
  }
  return null;
}

void _ensureGitHubSuccess(http.Response response, String action) {
  if (response.statusCode >= 200 && response.statusCode < 300) return;
  if (response.statusCode == 403 || response.statusCode == 429) {
    throw const FormatException('GitHub 公共 API 请求过于频繁，请稍后再试。');
  }
  if (response.statusCode == 404) {
    throw const FormatException('没有找到该 GitHub 仓库，或仓库不是公开仓库。');
  }
  throw FormatException('$action失败：HTTP ${response.statusCode}');
}

int _intValue(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

String _byteSizeLabel(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes >= 1024 * 1024 && bytes % (1024 * 1024) == 0) {
    return '${bytes ~/ (1024 * 1024)} MB';
  }
  if (bytes % 1024 == 0) return '${bytes ~/ 1024} KB';
  return '${(bytes / 1024).toStringAsFixed(1)} KB';
}
