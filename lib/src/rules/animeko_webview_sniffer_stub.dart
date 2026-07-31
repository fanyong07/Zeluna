import 'animeko_webview_sniffer_base.dart';

AnimekoWebViewSniffer createAnimekoWebViewSniffer() =>
    const _UnsupportedAnimekoWebViewSniffer();

class _UnsupportedAnimekoWebViewSniffer implements AnimekoWebViewSniffer {
  const _UnsupportedAnimekoWebViewSniffer();

  @override
  bool get supported => false;

  @override
  Future<AnimekoWebViewSniffResult?> sniff(
    AnimekoWebViewSniffRequest request,
  ) async => null;
}
