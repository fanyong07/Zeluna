import 'dart:collection';

class DrpyRuntimeLimits {
  const DrpyRuntimeLimits({
    this.javascriptTimeout = const Duration(seconds: 8),
    this.networkTimeout = const Duration(seconds: 8),
    this.overallTimeout = const Duration(seconds: 35),
    this.maxScriptBytes = 1024 * 1024,
    this.maxResponseBytes = 2 * 1024 * 1024,
    this.maxRedirects = 3,
    this.maxStorageEntries = 64,
    this.maxStorageValueBytes = 64 * 1024,
  });

  final Duration javascriptTimeout;
  final Duration networkTimeout;
  final Duration overallTimeout;
  final int maxScriptBytes;
  final int maxResponseBytes;
  final int maxRedirects;
  final int maxStorageEntries;
  final int maxStorageValueBytes;
}

class DrpyRuntimeRequest {
  const DrpyRuntimeRequest({
    required this.ruleId,
    required this.keyword,
    required this.episodeNumber,
    required this.episodeTitle,
    this.ruleSource = '',
    this.ruleUrl = '',
    this.requestHeaders = const {},
    this.credentialOrigin = '',
  });

  final String ruleId;
  final String keyword;
  final int episodeNumber;
  final String episodeTitle;
  final String ruleSource;
  final String ruleUrl;
  final Map<String, String> requestHeaders;

  /// The trusted content origin that may receive credential-like entries from
  /// [requestHeaders]. An empty or invalid value keeps those headers disabled.
  final String credentialOrigin;
}

class DrpyPlaybackCandidate {
  const DrpyPlaybackCandidate({
    required this.lineName,
    required this.episodeName,
    required this.url,
    this.headers = const {},
    this.requiresSniffing = false,
  });

  final String lineName;
  final String episodeName;
  final String url;
  final Map<String, String> headers;
  final bool requiresSniffing;

  factory DrpyPlaybackCandidate.fromJson(Map<String, dynamic> json) {
    final rawHeaders = json['headers'];
    return DrpyPlaybackCandidate(
      lineName: json['lineName']?.toString() ?? '',
      episodeName: json['episodeName']?.toString() ?? '',
      url: json['url']?.toString() ?? '',
      headers: rawHeaders is Map
          ? rawHeaders.map(
              (key, value) => MapEntry(key.toString(), value?.toString() ?? ''),
            )
          : const {},
      requiresSniffing: json['requiresSniffing'] == true,
    );
  }
}

class DrpyRuntimeResult {
  const DrpyRuntimeResult({
    required this.candidates,
    this.error,
    this.logs = const [],
    this.proceduralSubset = true,
  });

  final List<DrpyPlaybackCandidate> candidates;
  final String? error;
  final List<String> logs;
  final bool proceduralSubset;

  bool get succeeded => error == null && candidates.isNotEmpty;
}

class DrpyLocalStorage {
  final Map<String, Map<String, Object?>> _namespaces = {};

  Map<String, Object?> snapshot(String namespace) =>
      Map.unmodifiable(_namespaces[namespace] ?? const <String, Object?>{});

  void replace(String namespace, Map<String, Object?> values) {
    _namespaces[namespace] = Map<String, Object?>.from(values);
  }

  UnmodifiableMapView<String, Map<String, Object?>> get debugSnapshot =>
      UnmodifiableMapView(_namespaces);
}
