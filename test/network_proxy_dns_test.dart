import 'dart:io';
import 'package:anime/src/core/network/network_http_client_io.dart'
    show isResolvedNetworkAddressAllowed;
import 'package:anime/src/core/network/network_http_client.dart';
import 'package:anime/src/core/network/network_security.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('DNS validation permits only TLS hostname synthetic answers', () {
    final client = createUntrustedSourceHttpClient() as PolicyHttpClient;
    addTearDown(client.close);
    bool allowed(String url, String ip) => isResolvedNetworkAddressAllowed(
      Uri.parse(url),
      client.policy,
      InternetAddress(ip),
    );
    expect(allowed('https://source.example/video', '198.18.0.1'), isTrue);
    expect(
      allowed('https://source.example/video', '::ffff:198.19.0.1'),
      isTrue,
    );
    expect(allowed('http://source.example/video', '198.18.0.1'), isFalse);
    expect(allowed('https://198.18.0.1/video', '198.18.0.1'), isFalse);
    for (final ip in [
      '10.0.0.1',
      '192.168.1.1',
      '127.0.0.1',
      '::1',
      'fd00::1',
    ]) {
      expect(allowed('https://source.example/video', ip), isFalse);
    }
  });

  test(
    'rule HTTPS transport supports proxy DNS without allowing literal private destinations',
    () {
      final client = createUntrustedSourceHttpClient() as PolicyHttpClient;
      addTearDown(client.close);
      expect(
        client.policy.allowSyntheticDns,
        isTrue,
        reason:
            'VPN synthetic DNS for certificate-checked hostnames is not an IP URL',
      );
      expect(client.policy.allowLiteralBenchmarkAddress, isFalse);
      for (final host in ['198.18.0.1', '192.168.1.1', '127.0.0.1']) {
        expect(
          () => client.policy.ensureUriAllowed(Uri.parse('https://$host/a')),
          throwsA(isA<NetworkSecurityException>()),
        );
      }
    },
  );
}
