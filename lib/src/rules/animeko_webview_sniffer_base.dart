typedef AnimekoSniffMatcher = String? Function(String value, String baseUrl);

class AnimekoWebViewSniffRequest {
  const AnimekoWebViewSniffRequest({
    required this.pageUrl,
    required this.headers,
    required this.matchVideo,
    required this.matchNested,
    this.timeout = const Duration(seconds: 8),
  });

  final Uri pageUrl;
  final Map<String, String> headers;
  final AnimekoSniffMatcher matchVideo;
  final AnimekoSniffMatcher matchNested;
  final Duration timeout;
}

class AnimekoWebViewSniffResult {
  const AnimekoWebViewSniffResult({
    this.videoUrl,
    this.nestedUrl,
    this.cookieHeader = '',
  });

  final String? videoUrl;
  final String? nestedUrl;
  final String cookieHeader;
}

abstract class AnimekoWebViewSniffer {
  bool get supported;

  Future<AnimekoWebViewSniffResult?> sniff(AnimekoWebViewSniffRequest request);
}
