import 'dart:convert';

import 'package:anime/src/rules/github_rule_repository_scanner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'GitHub scanner allows credential-named configs and blocks only unreadable files',
    () async {
      final scanner = GitHubRuleRepositoryScanner(
        client: MockClient((request) async {
          expect(request.headers.containsKey('Authorization'), isFalse);
          if (request.url.path == '/repos/example/rules') {
            return http.Response(
              jsonEncode({
                'full_name': 'example/rules',
                'default_branch': 'main',
              }),
              200,
            );
          }
          if (request.url.path == '/repos/example/rules/git/trees/main') {
            expect(request.url.queryParameters['recursive'], '1');
            return http.Response(
              jsonEncode({
                'truncated': false,
                'tree': [
                  {'type': 'blob', 'path': 'rules/safe.json', 'size': 2048},
                  {'type': 'blob', 'path': 'private/token.json', 'size': 128},
                  {'type': 'blob', 'path': 'lists/all.txt', 'size': 6000000},
                  {'type': 'blob', 'path': 'scripts/remote.py', 'size': 100},
                ],
              }),
              200,
            );
          }
          return http.Response('not found', 404);
        }),
      );

      final result = await scanner.scan('https://github.com/example/rules');

      expect(result.name, 'example/rules');
      expect(result.defaultBranch, 'main');
      expect(result.candidates, hasLength(3));
      final safe = result.candidates.firstWhere(
        (item) => item.path == 'rules/safe.json',
      );
      expect(safe.canImport, isTrue);
      expect(
        safe.rawUrl,
        'https://raw.githubusercontent.com/example/rules/main/rules/safe.json',
      );
      final token = result.candidates.firstWhere(
        (item) => item.path.endsWith('token.json'),
      );
      expect(token.canImport, isTrue);
      expect(token.blockedReason, isNull);
      expect(
        result.candidates
            .firstWhere((item) => item.path.endsWith('all.txt'))
            .blockedReason,
        contains('5 MB'),
      );
    },
  );

  test('GitHub scanner only accepts a repository homepage', () {
    expect(
      GitHubRuleRepositoryScanner.isRepositoryUrl(
        'https://github.com/example/rules',
      ),
      isTrue,
    );
    expect(
      GitHubRuleRepositoryScanner.isRepositoryUrl(
        'https://github.com/example/rules/blob/main/rules.json',
      ),
      isFalse,
    );
    expect(
      GitHubRuleRepositoryScanner.isRepositoryUrl(
        'https://raw.githubusercontent.com/example/rules/main/rules.json',
      ),
      isFalse,
    );
  });
}
