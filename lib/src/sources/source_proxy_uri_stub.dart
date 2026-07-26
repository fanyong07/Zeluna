import 'package:http/http.dart' as http;

Uri platformSourceProxyUri(
  Uri target, {
  Set<String> allowedHosts = const {},
  String? session,
}) {
  return target;
}

Future<String?> platformCreateSourceProxySession({
  required Uri target,
  required Map<String, String> headers,
  required http.Client client,
}) async {
  return null;
}
