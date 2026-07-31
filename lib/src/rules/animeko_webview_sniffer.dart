import 'animeko_webview_sniffer_base.dart';
import 'animeko_webview_sniffer_stub.dart'
    if (dart.library.io) 'animeko_webview_sniffer_io.dart'
    as platform;

export 'animeko_webview_sniffer_base.dart';

AnimekoWebViewSniffer createAnimekoWebViewSniffer() =>
    platform.createAnimekoWebViewSniffer();
