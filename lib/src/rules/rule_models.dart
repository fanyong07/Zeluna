enum RuleContentType {
  anime('番剧'),
  series('电视剧'),
  movie('电影');

  const RuleContentType(this.label);

  final String label;
}

enum RuleSourceKind {
  kazumi('KazumiRules'),
  tvbox('TVBox');

  const RuleSourceKind(this.label);

  final String label;
}

class RulePlugin {
  const RulePlugin({
    required this.id,
    required this.name,
    required this.version,
    required this.source,
    required this.contentType,
    required this.engine,
    required this.updatedAt,
    required this.qualityScore,
    required this.tags,
    required this.baseUrl,
    required this.searchUrl,
    required this.searchable,
    required this.quickSearch,
    required this.filterable,
    this.requiresWebView = false,
    this.requiresCaptcha = false,
    this.requiresPrivateAuth = false,
    this.installedByDefault = false,
    this.note = '',
  });

  final String id;
  final String name;
  final String version;
  final RuleSourceKind source;
  final RuleContentType contentType;
  final String engine;
  final DateTime updatedAt;
  final int qualityScore;
  final List<String> tags;
  final String baseUrl;
  final String searchUrl;
  final bool searchable;
  final bool quickSearch;
  final bool filterable;
  final bool requiresWebView;
  final bool requiresCaptcha;
  final bool requiresPrivateAuth;
  final bool installedByDefault;
  final String note;

  String get sourceLabel => source.label;

  String get contentLabel => contentType.label;

  String get updateLabel {
    final month = '${updatedAt.month}'.padLeft(2, '0');
    final day = '${updatedAt.day}'.padLeft(2, '0');
    final hour = '${updatedAt.hour}'.padLeft(2, '0');
    final minute = '${updatedAt.minute}'.padLeft(2, '0');
    final second = '${updatedAt.second}'.padLeft(2, '0');
    return '${updatedAt.year}-$month-$day $hour:$minute:$second';
  }
}

class RulePluginState {
  const RulePluginState({
    this.installedIds = const {},
    this.enabledIds = const {},
  });

  final Set<String> installedIds;
  final Set<String> enabledIds;

  bool isInstalled(String id) => installedIds.contains(id);

  bool isEnabled(String id) => enabledIds.contains(id);

  RulePluginState copyWith({
    Set<String>? installedIds,
    Set<String>? enabledIds,
  }) {
    return RulePluginState(
      installedIds: installedIds ?? this.installedIds,
      enabledIds: enabledIds ?? this.enabledIds,
    );
  }

  Map<String, dynamic> toJson() => {
    'installedIds': installedIds.toList(),
    'enabledIds': enabledIds.toList(),
  };

  factory RulePluginState.fromJson(Map<String, dynamic> json) {
    return RulePluginState(
      installedIds: _stringSet(json['installedIds']),
      enabledIds: _stringSet(json['enabledIds']),
    );
  }
}

Set<String> _stringSet(Object? value) {
  if (value is! List) return const {};
  return value.map((item) => item.toString()).toSet();
}
