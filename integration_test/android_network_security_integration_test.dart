import 'dart:io';

import 'package:anime/src/core/network/network_http_client.dart';
import 'package:anime/src/core/network/network_security.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android client rejects cleartext and DNS rebinding', (
    tester,
  ) async {
    expect(Platform.isAndroid, isTrue);

    final accountPolicy = NetworkRequestPolicy.forService(
      NetworkServiceKind.accountBackend,
    );
    expect(
      () => accountPolicy.ensureUriAllowed(
        Uri.parse('http://api.example.test/status'),
      ),
      throwsA(isA<NetworkSecurityException>()),
    );

    final sourceClient = createUntrustedSourceHttpClient(
      timeout: const Duration(seconds: 5),
    );
    addTearDown(sourceClient.close);

    await expectLater(
      sourceClient.get(Uri.parse('http://localtest.me/rebinding-probe')),
      throwsA(isA<NetworkSecurityException>()),
    );
  });
}
