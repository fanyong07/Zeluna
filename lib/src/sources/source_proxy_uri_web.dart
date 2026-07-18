import 'dart:convert';

import 'package:http/http.dart' as http;

import 'proxy_session_headers.dart';

Uri platformSourceProxyUri(
  Uri target, {
  Set<String> allowedHosts = const {},
  String? session,
}) {
  final query = <String, String>{'url': target.toString()};
  if (allowedHosts.isNotEmpty) {
    final hosts = allowedHosts.map((item) => item.trim().toLowerCase()).toList()
      ..removeWhere((item) => item.isEmpty)
      ..sort();
    if (hosts.isNotEmpty) query['hosts'] = hosts.join(',');
  }
  if (session != null && session.trim().isNotEmpty) {
    query['session'] = session.trim();
  }
  return Uri.base.resolve('/source-proxy').replace(queryParameters: query);
}

Future<String?> platformCreateSourceProxySession({
  required Uri target,
  required Map<String, String> headers,
  required http.Client client,
}) async {
  if (headers.isEmpty) return null;
  try {
    final sessionHeaders = sanitizeProxySessionHeaders(headers);
    final response = await client
        .post(
          Uri.base.resolve('/media-proxy/session'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'url': target.toString(),
            'headers': sessionHeaders,
          }),
        )
        .timeout(const Duration(seconds: 8));
    if (response.statusCode < 200 || response.statusCode >= 300) return null;
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) return null;
    final token = decoded['token']?.toString().trim() ?? '';
    return token.isEmpty ? null : token;
  } catch (_) {
    return null;
  }
}
