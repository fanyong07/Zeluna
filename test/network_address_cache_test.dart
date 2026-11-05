import 'dart:async';
import 'dart:io';

import 'package:anime/src/core/network/network_address_cache.dart';
import 'package:anime/src/core/network/network_http_client_io.dart'
    show isResolvedNetworkAddressAllowed;
import 'package:anime/src/core/network/network_security.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'twenty concurrent clients share one DNS lookup and immutable answers',
    () async {
      final gate = Completer<List<InternetAddress>>();
      var calls = 0;
      final cache = NetworkAddressCache(
        lookup: (host) {
          calls++;
          expect(host, 'media.example');
          return gate.future;
        },
      );
      final requests = [
        for (var i = 0; i < 20; i++)
          cache.resolve(i.isEven ? 'MEDIA.example.' : 'media.example'),
      ];
      expect(calls, 1);
      expect(cache.pendingHosts, 1);
      gate.complete([
        InternetAddress('8.8.8.8'),
        InternetAddress('2001:4860:4860::8888'),
      ]);
      final answers = await Future.wait(requests);
      expect(
        answers.every((answer) => identical(answer, answers.first)),
        isTrue,
      );
      expect(() => answers.first.clear(), throwsUnsupportedError);
      expect(cache.cachedHosts, 1);
      expect(cache.pendingHosts, 0);
      expect(await cache.resolve('media.example'), same(answers.first));
      expect(calls, 1);
    },
  );

  test(
    'short TTL refreshes at its boundary without extending on cache reads',
    () async {
      var now = DateTime.utc(2026, 11, 6);
      var calls = 0;
      final cache = NetworkAddressCache(
        now: () => now,
        lookup: (_) async {
          calls++;
          return [InternetAddress(calls == 1 ? '8.8.8.8' : '1.1.1.1')];
        },
      );
      await cache.resolve('media.example');
      now = now.add(const Duration(seconds: 29));
      expect((await cache.resolve('media.example')).single.address, '8.8.8.8');
      now = now.add(const Duration(seconds: 1));
      expect((await cache.resolve('media.example')).single.address, '1.1.1.1');
      expect(calls, 2);
    },
  );

  test('capacity uses bounded least recently used eviction', () async {
    final calls = <String>[];
    final cache = NetworkAddressCache(
      maxEntries: 2,
      lookup: (host) async {
        calls.add(host);
        return [InternetAddress('8.8.8.8')];
      },
    );
    await cache.resolve('a.example');
    await cache.resolve('b.example');
    await cache.resolve('a.example');
    await cache.resolve('c.example');
    expect(cache.cachedHosts, 2);
    await cache.resolve('b.example');
    expect(calls, ['a.example', 'b.example', 'c.example', 'b.example']);
    expect(cache.cachedHosts, 2);
  });

  test('failed and empty results are not negatively cached', () async {
    var calls = 0;
    final cache = NetworkAddressCache(
      lookup: (_) async {
        calls++;
        if (calls == 1) throw const SocketException('offline');
        if (calls == 2) return [];
        return [InternetAddress('8.8.8.8')];
      },
    );
    await expectLater(
      cache.resolve('media.example'),
      throwsA(isA<SocketException>()),
    );
    await expectLater(
      cache.resolve('media.example'),
      throwsA(isA<SocketException>()),
    );
    expect(cache.cachedHosts, 0);
    await cache.resolve('media.example');
    expect(calls, 3);
    expect(cache.cachedHosts, 1);
  });

  test(
    'a timed out or cleared old lookup cannot repopulate DNS state',
    () async {
      final old = Completer<List<InternetAddress>>();
      var calls = 0;
      final cache = NetworkAddressCache(
        lookupTimeout: const Duration(milliseconds: 25),
        lookup: (_) {
          calls++;
          return calls == 1
              ? old.future
              : Future.value([InternetAddress('1.1.1.1')]);
        },
      );
      await expectLater(
        cache.resolve('media.example'),
        throwsA(isA<TimeoutException>()),
      );
      expect(cache.pendingHosts, 0);
      await cache.resolve('media.example');
      old.complete([InternetAddress('8.8.8.8')]);
      await Future<void>.delayed(Duration.zero);
      expect((await cache.resolve('media.example')).single.address, '1.1.1.1');
      expect(calls, 2);
    },
  );

  test(
    'clear and eviction reject late cache writes without losing new work',
    () async {
      for (final clear in [true, false]) {
        final old = Completer<List<InternetAddress>>();
        var calls = 0;
        final cache = NetworkAddressCache(
          lookup: (_) {
            calls++;
            return calls == 1
                ? old.future
                : Future.value([InternetAddress('1.1.1.1')]);
          },
        );
        final pending = cache.resolve('media.example');
        if (clear) {
          cache.clear();
        } else {
          cache.evict('MEDIA.example.');
        }
        final current = await cache.resolve('media.example');
        old.complete([InternetAddress('8.8.8.8')]);
        await pending;
        expect(await cache.resolve('media.example'), same(current));
        expect(calls, 2);
      }
    },
  );

  test('IPv4 and IPv6 literals do not call or populate DNS', () async {
    final cache = NetworkAddressCache(
      lookup: (_) => throw StateError('DNS unexpected'),
    );
    expect((await cache.resolve('8.8.8.8')).single.address, '8.8.8.8');
    expect(
      (await cache.resolve('2001:4860:4860::8888')).single.type,
      InternetAddressType.IPv6,
    );
    expect(cache.cachedHosts, 0);
    expect(cache.pendingHosts, 0);
  });

  test(
    'cache stores addresses, not approvals for a different scheme or policy',
    () async {
      final cache = NetworkAddressCache(
        lookup: (_) async => [InternetAddress('198.18.0.1')],
      );
      final answers = await cache.resolve('media.example');
      const policy = NetworkRequestPolicy(
        service: NetworkServiceKind.mediaResource,
        httpsOnly: false,
        allowPrivateNetwork: false,
        maxResponseBytes: 1024,
        requestTimeout: Duration(seconds: 3),
        allowSyntheticDns: true,
      );
      expect(
        isResolvedNetworkAddressAllowed(
          Uri.parse('https://media.example/1'),
          policy,
          answers.single,
        ),
        isTrue,
      );
      final hit = await cache.resolve('media.example');
      expect(hit, same(answers));
      expect(
        isResolvedNetworkAddressAllowed(
          Uri.parse('http://media.example/1'),
          policy,
          hit.single,
        ),
        isFalse,
      );
      expect(
        isResolvedNetworkAddressAllowed(
          Uri.parse('https://198.18.0.1/1'),
          policy,
          hit.single,
        ),
        isFalse,
      );
    },
  );

  test(
    'mixed DNS answers still reject any private destination on every read',
    () async {
      final cache = NetworkAddressCache(
        lookup: (_) async => [
          InternetAddress('8.8.8.8'),
          InternetAddress('127.0.0.1'),
        ],
      );
      final policy = NetworkRequestPolicy.forService(
        NetworkServiceKind.metadataApi,
      );
      final uri = Uri.parse('https://media.example/video');
      for (var i = 0; i < 2; i++) {
        final answers = await cache.resolve(uri.host);
        expect(
          answers.every(
            (ip) => isResolvedNetworkAddressAllowed(uri, policy, ip),
          ),
          isFalse,
        );
      }
      cache.evict(uri.host);
      expect(cache.cachedHosts, 0);
    },
  );
}
