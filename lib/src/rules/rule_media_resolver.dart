import 'dart:async';

import 'package:html/parser.dart' as html;

import 'animeko_webview_sniffer_base.dart';
import 'rule_playback_cancellation.dart';
import 'rule_security.dart';

/// A resolved request, not proof of playback. Keep the referring page attached
/// to the media address through probing and native playback.
final class ResolvedRuleMedia {
  const ResolvedRuleMedia(this.url, this.referer, this.headers);
  final String url;
  final Uri referer;
  final Map<String, String> headers;
}

/// One bounded resolution path for static, nested and script-driven players.
/// It cannot broaden a rule's granted permissions or solve a CAPTCHA.
final class RuleMediaResolver {
  const RuleMediaResolver({
    required this.readPage,
    required this.extract,
    required this.headersFor,
    required this.sniffer,
  });

  final Future<String> Function(Uri, Map<String, String>) readPage;
  final String? Function(String, String) extract;
  final Map<String, String> Function(Uri) headersFor;
  final AnimekoWebViewSniffer sniffer;

  Future<ResolvedRuleMedia?> resolve({
    required Uri page,
    required String body,
    required RulePermissionManifest manifest,
    bool allowSniffing = true,
    RulePlaybackCancellationToken? cancellationToken,
    Duration budget = const Duration(seconds: 10),
  }) async {
    final policy = RuleUrlPolicy(manifest);
    final watch = Stopwatch()..start();
    final visited = <Uri>{};
    var sniffed = false;
    bool active() =>
        cancellationToken?.isCancelled != true && watch.elapsed < budget;
    Duration remaining() => budget - watch.elapsed;
    ResolvedRuleMedia? candidate(
      String? raw,
      Uri referer, {
      String cookie = '',
    }) {
      if (!active() || raw == null || raw.trim().isEmpty) return null;
      final uri = referer.resolve(raw.trim());
      if (!policy.allows(uri, RuleUrlPurpose.media)) return null;
      final headers = filterRuleRequestHeaders(headersFor(referer), manifest);
      // Browser session cookies are scoped to the page origin, never an
      // unrelated CDN. Explicit rule request headers retain their permissions.
      if (cookie.isNotEmpty &&
          uri.origin == referer.origin &&
          manifest.cookiePolicy == RuleCookiePolicy.taskScoped) {
        headers['Cookie'] = cookie;
      }
      return ResolvedRuleMedia(
        uri.toString(),
        referer,
        Map.unmodifiable(headers),
      );
    }

    Future<ResolvedRuleMedia?> visit(Uri uri, String content, int depth) async {
      if (!active() ||
          depth > 2 ||
          visited.length >= 4 ||
          !policy.allows(uri, RuleUrlPurpose.page) ||
          !visited.add(uri)) {
        return null;
      }
      final direct = candidate(extract(content, uri.toString()), uri);
      if (direct != null) return direct;
      for (final frame
          in html.parse(content).querySelectorAll('iframe[src], frame[src]')) {
        if (!active() || depth >= 2 || visited.length >= 4) break;
        final target = uri.resolve(frame.attributes['src'] ?? '');
        if (visited.contains(target) ||
            !policy.allows(target, RuleUrlPurpose.page)) {
          continue;
        }
        final headers = filterRuleRequestHeaders(headersFor(uri), manifest);
        if (target.origin != uri.origin) {
          headers.removeWhere(
            (k, _) => const {
              'cookie',
              'authorization',
              'proxy-authorization',
            }.contains(k.toLowerCase()),
          );
        }
        try {
          final nested = await readPage(target, headers).timeout(remaining());
          final found = await visit(target, nested, depth + 1);
          if (found != null) return found;
        } catch (_) {
          // A broken/ad frame must not mask another allowed player frame.
        }
      }
      if (!active() ||
          sniffed ||
          !allowSniffing ||
          !manifest.webViewSniffing ||
          !manifest.javascript ||
          !sniffer.supported) {
        return null;
      }
      sniffed = true;
      final result = await sniffer
          .sniff(
            AnimekoWebViewSniffRequest(
              pageUrl: uri,
              headers: headersFor(uri),
              manifest: manifest,
              timeout: remaining(),
              cancellationToken: cancellationToken,
              matchVideo: (value, base) => extract(value, base),
              matchNested: (_, _) => null,
            ),
          )
          .timeout(remaining(), onTimeout: () => null);
      return candidate(
        result?.videoUrl,
        uri,
        cookie: result?.cookieHeader ?? '',
      );
    }

    return visit(page, body, 0);
  }
}
