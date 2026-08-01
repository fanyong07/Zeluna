import 'dart:convert';

import 'package:anime/src/core/network/network_security.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('network service policies', () {
    test('classifies every external service explicitly', () {
      expect(NetworkServiceKind.values.map((value) => value.name), {
        'accountBackend',
        'officialPlaybackBackend',
        'selfHostedPlaybackBackend',
        'rulePage',
        'mediaResource',
        'metadataApi',
      });
    });

    test('account, official playback and metadata require public HTTPS', () {
      for (final service in const [
        NetworkServiceKind.accountBackend,
        NetworkServiceKind.officialPlaybackBackend,
        NetworkServiceKind.metadataApi,
      ]) {
        final policy = NetworkRequestPolicy.forService(service);
        expect(
          () => policy.ensureUriAllowed(Uri.parse('http://api.example.test')),
          throwsA(isA<NetworkSecurityException>()),
        );
        expect(
          () => policy.ensureUriAllowed(Uri.parse('https://127.0.0.1')),
          throwsA(isA<NetworkSecurityException>()),
        );
        expect(
          () => policy.ensureUriAllowed(Uri.parse('https://api.example.test')),
          returnsNormally,
        );
      }
    });

    test('self-hosted HTTP needs an explicit insecure opt-in', () {
      final safe = NetworkRequestPolicy.forService(
        NetworkServiceKind.selfHostedPlaybackBackend,
      );
      final insecure = NetworkRequestPolicy.forService(
        NetworkServiceKind.selfHostedPlaybackBackend,
        allowInsecureSelfHosted: true,
      );
      final local = Uri.parse('http://192.168.1.20:8080');
      expect(
        () => safe.ensureUriAllowed(local),
        throwsA(isA<NetworkSecurityException>()),
      );
      expect(() => insecure.ensureUriAllowed(local), returnsNormally);
      expect(
        () => insecure.ensureHeadersAllowed(local, {
          'Authorization': 'Bearer redacted',
        }),
        throwsA(isA<NetworkSecurityException>()),
      );
      expect(
        () => insecure.ensureHeadersAllowed(local, {
          'Accept': 'application/json',
        }),
        returnsNormally,
      );
    });

    test('blocks credentials and special address forms', () {
      final policy = NetworkRequestPolicy.forService(
        NetworkServiceKind.mediaResource,
      );
      for (final value in const [
        'https://user:pass@example.test/video',
        'https://localhost/video',
        'https://service.local/video',
        'https://10.0.0.1/video',
        'https://[::1]/video',
        'https://[::ffff:169.254.169.254]/metadata',
      ]) {
        expect(
          () => policy.ensureUriAllowed(Uri.parse(value)),
          throwsA(isA<NetworkSecurityException>()),
          reason: value,
        );
      }
    });

    test('synthetic DNS compatibility never permits arbitrary private IPs', () {
      const trustedMedia = NetworkRequestPolicy(
        service: NetworkServiceKind.mediaResource,
        httpsOnly: false,
        allowPrivateNetwork: false,
        maxResponseBytes: 512 * 1024,
        requestTimeout: Duration(seconds: 5),
        allowSyntheticDns: true,
        allowLiteralBenchmarkAddress: true,
        rejectRedirects: false,
      );
      expect(
        () => trustedMedia.ensureUriAllowed(
          Uri.parse('http://198.18.0.8/video.mp4'),
        ),
        returnsNormally,
      );
      expect(
        () => trustedMedia.ensureUriAllowed(
          Uri.parse('http://192.168.1.20/video.mp4'),
        ),
        throwsA(isA<NetworkSecurityException>()),
      );
    });
  });

  group('policy HTTP client', () {
    test('disables automatic redirects and validates their targets', () async {
      final inner = MockClient((_) async {
        return http.Response('', 302, headers: {'location': 'http://10.0.0.1'});
      });
      final client = PolicyHttpClient(
        inner: inner,
        ownsInner: false,
        policy: NetworkRequestPolicy.forService(NetworkServiceKind.metadataApi),
      );
      addTearDown(inner.close);

      await expectLater(
        client.get(Uri.parse('https://metadata.example.test/item')),
        throwsA(isA<NetworkSecurityException>()),
      );
    });

    test('bounds the decompressed response stream', () async {
      final inner = MockClient((_) async {
        return http.Response.bytes(utf8.encode('0123456789'), 200);
      });
      final client = PolicyHttpClient(
        inner: inner,
        ownsInner: false,
        policy: const NetworkRequestPolicy(
          service: NetworkServiceKind.metadataApi,
          httpsOnly: true,
          allowPrivateNetwork: false,
          maxResponseBytes: 4,
          requestTimeout: Duration(seconds: 1),
        ),
      );
      addTearDown(inner.close);

      await expectLater(
        client.get(Uri.parse('https://metadata.example.test/item')),
        throwsA(isA<NetworkSecurityException>()),
      );
    });

    test('removes sensitive headers on a cross-origin redirect', () {
      final headers = headersForNetworkRedirect(
        Uri.parse('https://api.example.test/start'),
        Uri.parse('https://cdn.example.test/next'),
        const {
          'Authorization': 'Bearer redacted',
          'Cookie': 'session=redacted',
          'Accept': 'application/json',
        },
      );
      expect(headers, {'Accept': 'application/json'});
    });
  });
}
