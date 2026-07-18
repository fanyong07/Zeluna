import 'source_proxy_uri_stub.dart'
    if (dart.library.js_interop) 'source_proxy_uri_web.dart';

import 'package:http/http.dart' as http;

Uri sourceProxyUri(
  Uri target, {
  Set<String> allowedHosts = const {},
  String? session,
}) {
  return platformSourceProxyUri(
    target,
    allowedHosts: allowedHosts,
    session: session,
  );
}

Future<String?> createSourceProxySession({
  required Uri target,
  required Map<String, String> headers,
  required http.Client client,
}) {
  return platformCreateSourceProxySession(
    target: target,
    headers: headers,
    client: client,
  );
}
