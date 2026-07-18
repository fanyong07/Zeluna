import 'dart:convert';

import 'package:http/http.dart' as http;

import 'rule_importer.dart';
import 'rule_models.dart';

class KazumiRuleCatalogEntry {
  const KazumiRuleCatalogEntry({
    required this.name,
    required this.version,
    required this.lastUpdateMilliseconds,
    this.useNativePlayer = true,
    this.antiCrawlerEnabled = false,
    this.author = '',
  });

  final String name;
  final String version;
  final int lastUpdateMilliseconds;
  final bool useNativePlayer;
  final bool antiCrawlerEnabled;
  final String author;

  String get id => RuleImporter.kazumiRuleId(name);

  DateTime get updatedAt =>
      DateTime.fromMillisecondsSinceEpoch(lastUpdateMilliseconds);

  String get rawUrl => KazumiRuleRepository.rawRuleUrl(name);

  RulePlugin toPreviewRule() {
    return RulePlugin(
      id: id,
      name: name,
      version: version,
      source: RuleSourceKind.kazumi,
      contentType: RuleContentType.anime,
      engine: 'native',
      updatedAt: updatedAt,
      qualityScore: 72,
      tags: const ['番剧'],
      baseUrl: '',
      searchUrl: '',
      searchable: true,
      quickSearch: true,
      filterable: false,
      installedByDefault: false,
      groupId: KazumiRuleRepository.groupId,
      rawConfig: {
        'useNativePlayer': useNativePlayer,
        'antiCrawlerEnabled': antiCrawlerEnabled,
        if (author.isNotEmpty) 'author': author,
      },
      note: '可直接安装的内置番剧规则。',
    );
  }

  factory KazumiRuleCatalogEntry.fromJson(Map<String, dynamic> json) {
    final name = json['name']?.toString().trim() ?? '';
    if (name.isEmpty) {
      throw const FormatException('KazumiRules 索引中存在缺少名称的规则。');
    }
    return KazumiRuleCatalogEntry(
      name: name,
      version: json['version']?.toString().trim().isNotEmpty == true
          ? json['version'].toString().trim()
          : '1.0',
      lastUpdateMilliseconds: _intValue(json['lastUpdate']),
      useNativePlayer: _boolValue(json['useNativePlayer'], fallback: true),
      antiCrawlerEnabled: _boolValue(json['antiCrawlerEnabled']),
      author: json['author']?.toString().trim() ?? '',
    );
  }
}

class KazumiRuleCatalog {
  const KazumiRuleCatalog({
    required this.entries,
    required this.refreshedAt,
    this.remote = false,
  });

  final List<KazumiRuleCatalogEntry> entries;
  final DateTime refreshedAt;
  final bool remote;
}

class KazumiRuleLoadResult {
  const KazumiRuleLoadResult({
    required this.bundle,
    this.failedNames = const [],
  });

  final RuleImportBundle bundle;
  final List<String> failedNames;
}

class KazumiRuleRepository {
  const KazumiRuleRepository({
    http.Client? client,
    this.timeout = const Duration(seconds: 12),
    this.maxConcurrency = 6,
  }) : _client = client;

  static const homepageUrl = 'https://github.com/Predidit/KazumiRules';
  static const indexUrl =
      'https://raw.githubusercontent.com/Predidit/KazumiRules/main/index.json';
  static const _cdnIndexUrl =
      'https://cdn.jsdelivr.net/gh/Predidit/KazumiRules@main/index.json';
  static const groupId = 'repo:kazumi-rules';

  final http.Client? _client;
  final Duration timeout;
  final int maxConcurrency;

  static KazumiRuleCatalog get bundledCatalog => KazumiRuleCatalog(
    entries: _bundledEntries,
    refreshedAt: DateTime.fromMillisecondsSinceEpoch(1783910492000),
  );

  static String rawRuleUrl(String name) {
    final encodedName = Uri.encodeComponent(name);
    return 'https://raw.githubusercontent.com/Predidit/KazumiRules/main/$encodedName.json';
  }

  static String _cdnRuleUrl(String name) {
    final encodedName = Uri.encodeComponent(name);
    return 'https://cdn.jsdelivr.net/gh/Predidit/KazumiRules@main/$encodedName.json';
  }

  Future<KazumiRuleCatalog> refreshCatalog() async {
    final ownedClient = _client == null;
    final client = _client ?? http.Client();
    try {
      final body = await _getTextWithFallback(
        client,
        primaryUrl: indexUrl,
        fallbackUrl: _cdnIndexUrl,
      );
      final decoded = jsonDecode(body);
      if (decoded is! List) {
        throw const FormatException('KazumiRules 索引格式无效。');
      }
      final byId = <String, KazumiRuleCatalogEntry>{};
      for (final value in decoded.whereType<Map>()) {
        final entry = KazumiRuleCatalogEntry.fromJson(
          value.cast<String, dynamic>(),
        );
        byId[entry.id] = entry;
      }
      final entries = byId.values.toList(growable: false)
        ..sort(
          (a, b) =>
              b.lastUpdateMilliseconds.compareTo(a.lastUpdateMilliseconds),
        );
      if (entries.isEmpty) {
        throw const FormatException('KazumiRules 索引没有可用规则。');
      }
      return KazumiRuleCatalog(
        entries: entries,
        refreshedAt: DateTime.now(),
        remote: true,
      );
    } finally {
      if (ownedClient) client.close();
    }
  }

  Future<KazumiRuleLoadResult> loadRules(
    Iterable<KazumiRuleCatalogEntry> selected,
  ) async {
    final entries = selected.toList(growable: false);
    if (entries.isEmpty) {
      return const KazumiRuleLoadResult(
        bundle: RuleImportBundle(name: 'KazumiRules', rules: []),
      );
    }

    final ownedClient = _client == null;
    final client = _client ?? http.Client();
    try {
      final rules = <RulePlugin>[];
      final failedNames = <String>[];
      final concurrency = maxConcurrency < 1 ? 1 : maxConcurrency;
      for (var start = 0; start < entries.length; start += concurrency) {
        final end = (start + concurrency).clamp(0, entries.length);
        final batch = entries.sublist(start, end);
        final results = await Future.wait(
          batch.map((entry) => _loadRule(client, entry)),
        );
        for (var index = 0; index < results.length; index++) {
          final rule = results[index];
          if (rule == null) {
            failedNames.add(batch[index].name);
          } else {
            rules.add(rule);
          }
        }
      }
      if (rules.isEmpty) {
        throw const FormatException('所选 KazumiRules 规则暂时都无法读取。');
      }
      return KazumiRuleLoadResult(
        bundle: RuleImportBundle(
          name: 'KazumiRules',
          rules: List<RulePlugin>.unmodifiable(rules),
          sourceUrl: indexUrl,
        ),
        failedNames: List<String>.unmodifiable(failedNames),
      );
    } finally {
      if (ownedClient) client.close();
    }
  }

  Future<RulePlugin?> _loadRule(
    http.Client client,
    KazumiRuleCatalogEntry entry,
  ) async {
    try {
      final body = await _getTextWithFallback(
        client,
        primaryUrl: entry.rawUrl,
        fallbackUrl: _cdnRuleUrl(entry.name),
      );
      final decoded = jsonDecode(body);
      if (decoded is! Map) return null;
      final rawRule = decoded.cast<String, dynamic>();
      final enriched = <String, dynamic>{
        ...rawRule,
        'id': entry.id,
        'name': rawRule['name'] ?? entry.name,
        'version': rawRule['version'] ?? entry.version,
        'source': 'kazumi',
        'contentType': rawRule['type'] ?? 'anime',
        'updatedAt': entry.lastUpdateMilliseconds,
        'groupId': groupId,
        'rawConfig': rawRule,
      };
      final imported = const RuleImporter().importFromText(
        jsonEncode(enriched),
        sourceUrl: entry.rawUrl,
      );
      return imported.rules.length == 1 ? imported.rules.single : null;
    } catch (_) {
      return null;
    }
  }

  Future<String> _getTextWithFallback(
    http.Client client, {
    required String primaryUrl,
    required String fallbackUrl,
  }) async {
    Object? firstError;
    for (final url in [primaryUrl, fallbackUrl]) {
      try {
        final response = await client
            .get(
              Uri.parse(url),
              headers: const {'Accept': 'application/json, text/plain;q=0.9'},
            )
            .timeout(timeout);
        if (response.statusCode >= 200 && response.statusCode < 300) {
          return utf8.decode(response.bodyBytes, allowMalformed: false);
        }
        firstError ??= FormatException('规则仓库请求失败：HTTP ${response.statusCode}');
      } catch (error) {
        firstError ??= error;
      }
    }
    throw firstError ?? const FormatException('规则仓库暂时无法访问。');
  }
}

const _bundledEntries = <KazumiRuleCatalogEntry>[
  KazumiRuleCatalogEntry(
    name: 'sorani',
    version: '1.0',
    lastUpdateMilliseconds: 1783910492000,
  ),
  KazumiRuleCatalogEntry(
    name: 'dalvdm',
    version: '1.0',
    lastUpdateMilliseconds: 1783855961000,
    antiCrawlerEnabled: true,
  ),
  KazumiRuleCatalogEntry(
    name: 'TvTFun',
    version: '1.0',
    lastUpdateMilliseconds: 1783604536000,
  ),
  KazumiRuleCatalogEntry(
    name: 'giriGiriLove',
    version: '2.3',
    lastUpdateMilliseconds: 1783528394000,
    antiCrawlerEnabled: true,
  ),
  KazumiRuleCatalogEntry(
    name: 'aafun',
    version: '1.1',
    lastUpdateMilliseconds: 1782702566000,
  ),
  KazumiRuleCatalogEntry(
    name: 'qifun',
    version: '2.1',
    lastUpdateMilliseconds: 1781413737000,
    antiCrawlerEnabled: true,
  ),
  KazumiRuleCatalogEntry(
    name: 'ciyuancheng',
    version: '2.0',
    lastUpdateMilliseconds: 1781270758000,
    antiCrawlerEnabled: true,
  ),
  KazumiRuleCatalogEntry(
    name: 'fcdm',
    version: '1.0',
    lastUpdateMilliseconds: 1781096923000,
  ),
  KazumiRuleCatalogEntry(
    name: 'mgnacg',
    version: '1.0',
    lastUpdateMilliseconds: 1780897282000,
    antiCrawlerEnabled: true,
  ),
  KazumiRuleCatalogEntry(
    name: 'mutefun',
    version: '1.1',
    lastUpdateMilliseconds: 1780637024000,
    antiCrawlerEnabled: true,
  ),
  KazumiRuleCatalogEntry(
    name: 'gugu3',
    version: '1.3',
    lastUpdateMilliseconds: 1780292876000,
  ),
  KazumiRuleCatalogEntry(
    name: 'xfdm',
    version: '2.1',
    lastUpdateMilliseconds: 1780065540000,
    antiCrawlerEnabled: true,
  ),
  KazumiRuleCatalogEntry(
    name: 'omofun03',
    version: '1.1',
    lastUpdateMilliseconds: 1777179683000,
  ),
  KazumiRuleCatalogEntry(
    name: 'enlie',
    version: '1.0',
    lastUpdateMilliseconds: 1773203174000,
  ),
  KazumiRuleCatalogEntry(
    name: 'xfdmneo',
    version: '1.1',
    lastUpdateMilliseconds: 1772964002000,
  ),
  KazumiRuleCatalogEntry(
    name: 'MXdm',
    version: '2.3',
    lastUpdateMilliseconds: 1771938941000,
  ),
  KazumiRuleCatalogEntry(
    name: 'gpjda',
    version: '1.0',
    lastUpdateMilliseconds: 1771771049000,
  ),
  KazumiRuleCatalogEntry(
    name: 'mwcy',
    version: '1.2',
    lastUpdateMilliseconds: 1771294191000,
  ),
  KazumiRuleCatalogEntry(
    name: '7sefun',
    version: '1.2',
    lastUpdateMilliseconds: 1770510516000,
  ),
  KazumiRuleCatalogEntry(
    name: 'DM84',
    version: '1.4',
    lastUpdateMilliseconds: 1770015775000,
  ),
  KazumiRuleCatalogEntry(
    name: 'baimao',
    version: '1.0',
    lastUpdateMilliseconds: 1769573721000,
  ),
  KazumiRuleCatalogEntry(
    name: 'AGE',
    version: '1.5',
    lastUpdateMilliseconds: 1758092260000,
  ),
];

bool _boolValue(Object? value, {bool fallback = false}) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  final text = value?.toString().trim().toLowerCase();
  if (text == 'true' || text == '1' || text == 'yes') return true;
  if (text == 'false' || text == '0' || text == 'no') return false;
  return fallback;
}

int _intValue(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}
