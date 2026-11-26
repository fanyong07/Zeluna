import '../core/network/network_security.dart';

/// An explicit chapter-page task, never a media URL or proof of playability.
/// Only the trusted backend repository accepts this schema. Browser execution
/// remains task-scoped to these exact public hosts with no account credentials.
final class ClientMediaResolverDescriptor {
  const ClientMediaResolverDescriptor({
    required this.pageUrl,
    required this.referer,
    required this.ruleId,
    required this.ruleName,
    required this.userAgent,
    required this.pageHosts,
    required this.mediaHosts,
  });

  final Uri pageUrl;
  final Uri referer;
  final String ruleId;
  final String ruleName;
  final String userAgent;
  final List<String> pageHosts;
  final List<String> mediaHosts;

  static ClientMediaResolverDescriptor? fromJson(Object? value) {
    if (value is! Map || value['kind'] != 'kazumi_page_v1') return null;
    const policy = NetworkRequestPolicy(
      service: NetworkServiceKind.rulePage,
      httpsOnly: false,
      allowPrivateNetwork: false,
      maxResponseBytes: 4 * 1024 * 1024,
      requestTimeout: Duration(seconds: 10),
    );
    Uri? publicUri(Object? raw) {
      if (raw is! String ||
          raw.length > 8192 ||
          raw.contains('\\') ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(raw)) {
        return null;
      }
      final text = raw.trim();
      if (text.isEmpty) return null;
      final uri = Uri.tryParse(text);
      if (uri == null) return null;
      try {
        policy.ensureUriAllowed(uri);
        if (uri.fragment.isNotEmpty) return null;
        return uri;
      } on NetworkSecurityException {
        return null;
      }
    }

    List<String>? hosts(Object? raw) {
      if (raw is! List || raw.isEmpty || raw.length > 32) return null;
      final result = <String>{};
      for (final item in raw) {
        if (item is! String) return null;
        final host = item.trim().toLowerCase();
        if (host.length > 253 ||
            !RegExp(r'^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$').hasMatch(host) ||
            !host.contains('.') ||
            host.contains('..') ||
            publicUri('https://$host/') == null) {
          return null;
        }
        result.add(host);
      }
      return List.unmodifiable(result);
    }

    String? text(String key, int maxLength) {
      final valueForKey = value[key] ?? '';
      if (valueForKey is! String ||
          valueForKey.length > maxLength ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(valueForKey)) {
        return null;
      }
      return valueForKey.trim();
    }

    final page = publicUri(value['page_url']);
    final referer = publicUri(value['referer'] ?? value['page_url']);
    final pages = hosts(value['page_hosts']);
    final media = hosts(value['media_hosts']);
    final ruleId = text('rule_id', 128);
    final ruleName = text('rule_name', 256);
    final userAgent = text('user_agent', 512);
    if (page == null ||
        referer == null ||
        pages == null ||
        media == null ||
        !pages.contains(page.host.toLowerCase()) ||
        !pages.contains(referer.host.toLowerCase()) ||
        ruleId == null ||
        ruleId.isEmpty ||
        ruleName == null ||
        userAgent == null) {
      return null;
    }
    return ClientMediaResolverDescriptor(
      pageUrl: page,
      referer: referer,
      ruleId: ruleId,
      ruleName: ruleName.isEmpty ? ruleId : ruleName,
      userAgent: userAgent,
      pageHosts: pages,
      mediaHosts: media,
    );
  }
}
