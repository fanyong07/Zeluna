/// Public, declarative Kazumi API requests. No scripts, credentials or eval.
/// The caller still enforces the rule's approved domains and redirect policy.
bool supportsKazumiApi(Map<String, dynamic> config) {
  final request = config['request'];
  if (request is! Map) return false;
  final method = (request['method'] ?? 'GET').toString().toUpperCase();
  final uri = Uri.tryParse(request['url']?.toString() ?? '');
  if (method != 'GET' ||
      uri == null ||
      !const {'https', 'http'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      request['body'] != null) {
    return false;
  }
  final headers = request['headers'];
  // Do not silently drop an authentication requirement and call it supported.
  return headers == null || (headers is Map && headers.isEmpty);
}

Uri kazumiApiUri(Map<String, dynamic> config, Map<String, String> variables) {
  if (!supportsKazumiApi(config)) {
    throw const FormatException('仅支持不含授权信息的公开 GET 规则接口。');
  }
  final request = config['request'] as Map;
  final uri = Uri.parse(
    kazumiApiTemplate(request['url'].toString(), variables),
  );
  final query = request['query'];
  return query is! Map
      ? uri
      : uri.replace(
          queryParameters: {
            ...uri.queryParameters,
            for (final entry in query.entries)
              entry.key.toString(): kazumiApiTemplate(
                entry.value.toString(),
                variables,
                encode: false,
              ),
          },
        );
}

String kazumiApiTemplate(
  String template,
  Map<String, String> variables, {
  bool encode = true,
}) {
  var result = template;
  for (final entry in variables.entries) {
    result = result.replaceAll(
      '@${entry.key}',
      encode ? Uri.encodeComponent(entry.value) : entry.value,
    );
  }
  return result;
}

/// Only child access, indexes and array wildcards. No predicates or scripting.
List<Object?> kazumiJsonNodes(Object? root, String path) {
  final expression = path.trim();
  if (expression.length > 256 ||
      !RegExp(
        r'^\$(?:\.[A-Za-z_][A-Za-z_0-9-]*|\[(?:\*|[0-9]+)\])*$',
      ).hasMatch(expression)) {
    return const [];
  }
  final steps = RegExp(
    r'\.([A-Za-z_][A-Za-z_0-9-]*)|\[(\*|[0-9]+)\]',
  ).allMatches(expression).toList();
  if (steps.length > 16) return const [];
  var nodes = <Object?>[root];
  for (final step in steps) {
    final next = <Object?>[];
    for (final node in nodes) {
      final key = step.group(1);
      if (key != null && node is Map && node.containsKey(key)) {
        next.add(node[key]);
      } else if (key == null && node is List) {
        if (step.group(2) == '*') {
          next.addAll(node.take(1000));
        } else {
          final index = int.tryParse(step.group(2)!);
          if (index != null && index < node.length) next.add(node[index]);
        }
      }
      if (next.length >= 1000) break;
    }
    nodes = next.take(1000).toList();
  }
  return nodes;
}

String kazumiJsonValue(Object? root, Object? path) {
  final nodes = kazumiJsonNodes(root, path?.toString() ?? '');
  if (nodes.isEmpty) return '';
  final value = nodes.first;
  return value is String || value is num ? value.toString().trim() : '';
}
