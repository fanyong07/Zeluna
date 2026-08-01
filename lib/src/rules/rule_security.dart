import 'dart:convert';

import '../core/identity/stable_identity.dart';

enum RuleTrustLevel {
  official('官方'),
  communitySigned('社区签名'),
  untrusted('未信任');

  const RuleTrustLevel(this.label);

  final String label;

  static RuleTrustLevel parse(Object? value) {
    return switch (value?.toString().trim().toLowerCase()) {
      'official' => RuleTrustLevel.official,
      'communitysigned' || 'community_signed' => RuleTrustLevel.communitySigned,
      _ => RuleTrustLevel.untrusted,
    };
  }
}

enum RuleCookiePolicy {
  none('不使用'),
  taskScoped('仅当前任务');

  const RuleCookiePolicy(this.label);

  final String label;

  static RuleCookiePolicy parse(Object? value) {
    return switch (value?.toString().trim().toLowerCase()) {
      'taskscoped' || 'task_scoped' || 'task' => RuleCookiePolicy.taskScoped,
      _ => RuleCookiePolicy.none,
    };
  }
}

enum RuleUrlPurpose { page, media }

const currentRuleCoreVersion = '1.0.0';

String ruleSecurityContentHash(Object? value) =>
    stableDigest('rule-content|v1|${_canonicalJson(value)}');

bool isRuleCoreVersionCompatible(
  String minimumVersion, {
  String currentVersion = currentRuleCoreVersion,
}) {
  List<int> parts(String value) {
    final core = value.trim().split(RegExp(r'[+-]')).first;
    return core
        .split('.')
        .take(3)
        .map((part) => int.tryParse(part) ?? 0)
        .toList(growable: true)
      ..addAll(List<int>.filled(3, 0));
  }

  final current = parts(currentVersion);
  final minimum = parts(minimumVersion);
  for (var index = 0; index < 3; index++) {
    if (current[index] != minimum[index]) {
      return current[index] > minimum[index];
    }
  }
  return true;
}

class RulePermissionManifest {
  const RulePermissionManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.engine,
    required this.contentTypes,
    required this.sourceRepository,
    required this.contentHash,
    required this.signature,
    required this.trustLevel,
    required this.pageDomains,
    required this.mediaDomains,
    required this.javascript,
    required this.webViewSniffing,
    required this.cookiePolicy,
    required this.cleartextHttp,
    required this.customReferer,
    required this.customOrigin,
    required this.customUserAgent,
    required this.minimumCoreVersion,
  });

  const RulePermissionManifest.official({
    required this.id,
    required this.name,
    required this.version,
    required this.engine,
    required this.contentTypes,
    required this.pageDomains,
    required this.mediaDomains,
    this.sourceRepository = 'bundled:zeluna/audited-rules',
    this.contentHash = '',
    this.signature = '',
    this.javascript = false,
    this.webViewSniffing = false,
    this.cookiePolicy = RuleCookiePolicy.none,
    this.cleartextHttp = false,
    this.customReferer = false,
    this.customOrigin = false,
    this.customUserAgent = false,
    this.minimumCoreVersion = '1.0.0',
  }) : trustLevel = RuleTrustLevel.official;

  const RulePermissionManifest.untrusted({
    required this.id,
    required this.name,
    required this.version,
    required this.engine,
    required this.contentTypes,
    required this.pageDomains,
    required this.mediaDomains,
    this.sourceRepository = '',
    this.contentHash = '',
    this.signature = '',
    this.javascript = false,
    this.webViewSniffing = false,
    this.cookiePolicy = RuleCookiePolicy.none,
    this.cleartextHttp = false,
    this.customReferer = false,
    this.customOrigin = false,
    this.customUserAgent = false,
    this.minimumCoreVersion = currentRuleCoreVersion,
  }) : trustLevel = RuleTrustLevel.untrusted;

  final String id;
  final String name;
  final String version;
  final String engine;
  final List<String> contentTypes;
  final String sourceRepository;
  final String contentHash;
  final String signature;
  final RuleTrustLevel trustLevel;
  final List<String> pageDomains;
  final List<String> mediaDomains;
  final bool javascript;
  final bool webViewSniffing;
  final RuleCookiePolicy cookiePolicy;
  final bool cleartextHttp;
  final bool customReferer;
  final bool customOrigin;
  final bool customUserAgent;
  final String minimumCoreVersion;

  bool get requiresApproval => trustLevel != RuleTrustLevel.official;

  String get permissionDigest =>
      stableDigest('rule-permissions|v1|${_canonicalJson(toJson())}');

  RulePermissionManifest copyWith({
    String? id,
    String? name,
    String? version,
    String? engine,
    List<String>? contentTypes,
    String? sourceRepository,
    String? contentHash,
    String? signature,
    RuleTrustLevel? trustLevel,
    List<String>? pageDomains,
    List<String>? mediaDomains,
    bool? javascript,
    bool? webViewSniffing,
    RuleCookiePolicy? cookiePolicy,
    bool? cleartextHttp,
    bool? customReferer,
    bool? customOrigin,
    bool? customUserAgent,
    String? minimumCoreVersion,
  }) {
    return RulePermissionManifest(
      id: id ?? this.id,
      name: name ?? this.name,
      version: version ?? this.version,
      engine: engine ?? this.engine,
      contentTypes: contentTypes ?? this.contentTypes,
      sourceRepository: sourceRepository ?? this.sourceRepository,
      contentHash: contentHash ?? this.contentHash,
      signature: signature ?? this.signature,
      trustLevel: trustLevel ?? this.trustLevel,
      pageDomains: pageDomains ?? this.pageDomains,
      mediaDomains: mediaDomains ?? this.mediaDomains,
      javascript: javascript ?? this.javascript,
      webViewSniffing: webViewSniffing ?? this.webViewSniffing,
      cookiePolicy: cookiePolicy ?? this.cookiePolicy,
      cleartextHttp: cleartextHttp ?? this.cleartextHttp,
      customReferer: customReferer ?? this.customReferer,
      customOrigin: customOrigin ?? this.customOrigin,
      customUserAgent: customUserAgent ?? this.customUserAgent,
      minimumCoreVersion: minimumCoreVersion ?? this.minimumCoreVersion,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'version': version,
    'engine': engine,
    'contentTypes': [...contentTypes]..sort(),
    'sourceRepository': sourceRepository,
    'contentHash': contentHash,
    'signature': signature,
    'trustLevel': trustLevel.name,
    'pageDomains': normalizeRuleDomains(pageDomains),
    'mediaDomains': normalizeRuleDomains(mediaDomains),
    'javascript': javascript,
    'webViewSniffing': webViewSniffing,
    'cookiePolicy': cookiePolicy.name,
    'cleartextHttp': cleartextHttp,
    'customReferer': customReferer,
    'customOrigin': customOrigin,
    'customUserAgent': customUserAgent,
    'minimumCoreVersion': minimumCoreVersion,
  };

  factory RulePermissionManifest.fromImportedJson(Map<String, dynamic> json) {
    // Trust claims embedded in an imported JSON document are not proof. A
    // future signed-repository verifier may promote the manifest only after it
    // validates the signature and content hash against a trusted key.
    return RulePermissionManifest(
      id: json['id']?.toString().trim() ?? '',
      name: json['name']?.toString().trim() ?? '',
      version: json['version']?.toString().trim() ?? '1.0',
      engine: json['engine']?.toString().trim() ?? '',
      contentTypes: _stringList(json['contentTypes']),
      sourceRepository: json['sourceRepository']?.toString().trim() ?? '',
      contentHash: json['contentHash']?.toString().trim().toLowerCase() ?? '',
      signature: json['signature']?.toString().trim() ?? '',
      trustLevel: RuleTrustLevel.untrusted,
      pageDomains: normalizeRuleDomains(_stringList(json['pageDomains'])),
      mediaDomains: normalizeRuleDomains(_stringList(json['mediaDomains'])),
      javascript: _bool(json['javascript']),
      webViewSniffing: _bool(json['webViewSniffing']),
      cookiePolicy: RuleCookiePolicy.parse(json['cookiePolicy']),
      cleartextHttp: _bool(json['cleartextHttp']),
      customReferer: _bool(json['customReferer']),
      customOrigin: _bool(json['customOrigin']),
      customUserAgent: _bool(json['customUserAgent']),
      minimumCoreVersion:
          json['minimumCoreVersion']?.toString().trim() ?? '1.0.0',
    );
  }
}

class RuleUrlPolicy {
  const RuleUrlPolicy(this.manifest);

  final RulePermissionManifest manifest;

  bool allows(Uri uri, RuleUrlPurpose purpose) {
    if (purpose == RuleUrlPurpose.page && uri.toString() == 'about:blank') {
      return true;
    }
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'https' && scheme != 'http') return false;
    if (scheme == 'http' && !manifest.cleartextHttp) return false;
    if (uri.userInfo.isNotEmpty || uri.host.trim().isEmpty) return false;

    final host = uri.host.toLowerCase().trim().replaceFirst(RegExp(r'\.$'), '');
    if (_isForbiddenHost(host)) return false;
    final domains = purpose == RuleUrlPurpose.page
        ? manifest.pageDomains
        : manifest.mediaDomains;
    return normalizeRuleDomains(
      domains,
    ).any((domain) => _matchesDomain(host, domain));
  }
}

Map<String, String> filterRuleRequestHeaders(
  Map<String, String> headers,
  RulePermissionManifest manifest,
) {
  final filtered = <String, String>{};
  for (final entry in headers.entries) {
    final name = entry.key.trim();
    final value = entry.value.trim();
    final normalized = name.toLowerCase();
    if (name.isEmpty || value.isEmpty || _isForbiddenHeader(normalized)) {
      continue;
    }
    final allowed = switch (normalized) {
      'referer' => manifest.customReferer,
      'origin' => manifest.customOrigin,
      'user-agent' => manifest.customUserAgent,
      'cookie' ||
      'cookie2' => manifest.cookiePolicy == RuleCookiePolicy.taskScoped,
      _ => true,
    };
    if (allowed) filtered[name] = value;
  }
  return filtered;
}

Map<String, String> ruleHeadersForPersistence(Map<String, String> headers) {
  return <String, String>{
    for (final entry in headers.entries)
      if (!_isPersistenceSecretKey(entry.key)) entry.key: entry.value,
  };
}

Object? ruleConfigForPersistence(Object? value) {
  if (value is Map) {
    return <String, Object?>{
      for (final entry in value.entries)
        if (!_isPersistenceSecretKey(entry.key.toString()))
          entry.key.toString(): ruleConfigForPersistence(entry.value),
    };
  }
  if (value is Iterable) {
    return value.map(ruleConfigForPersistence).toList(growable: false);
  }
  return value;
}

List<String> normalizeRuleDomains(Iterable<String> values) {
  final domains = <String>{};
  for (final value in values) {
    var domain = value.trim().toLowerCase();
    final parsed = Uri.tryParse(domain);
    if (parsed != null && parsed.host.isNotEmpty) domain = parsed.host;
    domain = domain.replaceFirst(RegExp(r'^\*\.'), '');
    domain = domain.replaceFirst(RegExp(r'\.$'), '');
    if (domain.isEmpty || domain == '*' || domain.contains('/')) continue;
    if (_isForbiddenHost(domain)) continue;
    domains.add(domain);
  }
  return domains.toList(growable: false)..sort();
}

List<String> ruleDomainsFromUrls(Iterable<String> values) {
  return normalizeRuleDomains([
    for (final value in values)
      if (Uri.tryParse(value.trim()) case final uri?
          when uri.hasScheme && uri.host.isNotEmpty)
        uri.host,
  ]);
}

bool _matchesDomain(String host, String domain) {
  return host == domain || host.endsWith('.$domain');
}

bool _isForbiddenHeader(String name) {
  if (const {
    'authorization',
    'proxy-authorization',
    'host',
    'connection',
    'content-length',
    'transfer-encoding',
  }.contains(name)) {
    return true;
  }
  return name.contains('token') ||
      name.contains('secret') ||
      name.contains('api-key') ||
      name.contains('apikey') ||
      name.startsWith('x-zeluna-') ||
      name.startsWith('x-admin-') ||
      name.startsWith('x-internal-');
}

bool _isPersistenceSecretKey(String name) {
  final normalized = name.trim().toLowerCase().replaceAll(
    RegExp(r'[^a-z0-9]'),
    '',
  );
  return normalized.contains('authorization') ||
      normalized.contains('cookie') ||
      normalized.contains('credential') ||
      normalized.contains('password') ||
      normalized.contains('passwd') ||
      normalized.contains('token') ||
      normalized.contains('secret') ||
      normalized.contains('apikey');
}

bool _isForbiddenHost(String host) {
  if (host == 'localhost' ||
      host.endsWith('.localhost') ||
      host.endsWith('.local')) {
    return true;
  }
  if (const {
    '169.254.169.254',
    '100.100.100.200',
    '168.63.129.16',
  }.contains(host)) {
    return true;
  }
  final ipv4 = _parseIpv4(host);
  if (ipv4 != null) {
    final a = ipv4[0];
    final b = ipv4[1];
    return a == 0 ||
        a == 10 ||
        a == 127 ||
        (a == 100 && b >= 64 && b <= 127) ||
        (a == 169 && b == 254) ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168) ||
        a >= 224;
  }
  if (!host.contains(':')) return false;
  final ipv6 = host.toLowerCase();
  if (ipv6 == '::' || ipv6 == '::1') return true;
  if (ipv6.startsWith('fc') ||
      ipv6.startsWith('fd') ||
      ipv6.startsWith('fe8') ||
      ipv6.startsWith('fe9') ||
      ipv6.startsWith('fea') ||
      ipv6.startsWith('feb') ||
      ipv6.startsWith('ff')) {
    return true;
  }
  if (ipv6.startsWith('::ffff:')) {
    return _isForbiddenHost(ipv6.substring('::ffff:'.length));
  }
  return false;
}

bool isForbiddenRuleHost(String host) => _isForbiddenHost(host.toLowerCase());

List<int>? _parseIpv4(String host) {
  final parts = host.split('.');
  if (parts.length != 4) return null;
  final values = <int>[];
  for (final part in parts) {
    if (part.isEmpty || (part.length > 1 && part.startsWith('0'))) return null;
    final value = int.tryParse(part);
    if (value == null || value < 0 || value > 255) return null;
    values.add(value);
  }
  return values;
}

bool _bool(Object? value) => value == true || value?.toString() == 'true';

List<String> _stringList(Object? value) {
  if (value is! List) return const [];
  return value
      .map((item) => item.toString().trim())
      .where((item) => item.isNotEmpty)
      .toList(growable: false);
}

String _canonicalJson(Object? value) {
  Object? normalize(Object? current) {
    if (current is Map) {
      final entries = current.entries.toList(growable: false)
        ..sort(
          (left, right) => left.key.toString().compareTo(right.key.toString()),
        );
      return <String, Object?>{
        for (final entry in entries)
          entry.key.toString(): normalize(entry.value),
      };
    }
    if (current is Iterable) return current.map(normalize).toList();
    return current;
  }

  return jsonEncode(normalize(value));
}
