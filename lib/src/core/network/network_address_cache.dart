import 'dart:async';
import 'dart:io';

/// A short-lived, bounded cache of system DNS answers shared by HTTP clients.
///
/// This does not replace DNS, change URLs, or skip TLS hostname validation.
/// Callers must validate every answer against their own request policy before
/// connecting, including cache hits. No failed or empty lookup is cached.
final class NetworkAddressCache {
  NetworkAddressCache({
    Future<List<InternetAddress>> Function(String host)? lookup,
    DateTime Function()? now,
    this.ttl = const Duration(seconds: 30),
    this.lookupTimeout = const Duration(seconds: 3),
    this.maxEntries = 128,
  }) : assert(ttl.inMicroseconds > 0),
       assert(lookupTimeout.inMicroseconds > 0),
       assert(maxEntries > 0),
       _lookup = lookup ?? InternetAddress.lookup,
       _now = now ?? DateTime.now;

  final Future<List<InternetAddress>> Function(String host) _lookup;
  final DateTime Function() _now;
  final Duration ttl;
  final Duration lookupTimeout;
  final int maxEntries;
  final Map<String, _AddressCacheEntry> _entries = {};
  final Map<String, Future<List<InternetAddress>>> _inFlight = {};

  int get cachedHosts => _entries.length;
  int get pendingHosts => _inFlight.length;

  Future<List<InternetAddress>> resolve(String host) {
    final literal = InternetAddress.tryParse(host);
    if (literal != null) return Future.value([literal]);
    final key = host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
    final now = _now();
    _entries.removeWhere((_, entry) => !entry.expiresAt.isAfter(now));
    final cached = _entries.remove(key);
    if (cached != null) {
      _entries[key] = cached;
      return Future.value(cached.addresses);
    }
    final existing = _inFlight[key];
    if (existing != null) return existing;

    late final Future<List<InternetAddress>> operation;
    operation = Future<List<InternetAddress>>.sync(() => _lookup(key))
        .timeout(lookupTimeout)
        .then((addresses) {
          if (addresses.isEmpty) {
            throw const SocketException('DNS returned no addresses.');
          }
          final result = List<InternetAddress>.unmodifiable(addresses);
          // An eviction/clear or an untracked lookup must not repopulate the
          // cache after its owner retired it. Also bound tracked in-flight work.
          if (identical(_inFlight[key], operation)) {
            _entries.remove(key);
            while (_entries.length >= maxEntries) {
              _entries.remove(_entries.keys.first);
            }
            _entries[key] = _AddressCacheEntry(result, _now().add(ttl));
          }
          return result;
        })
        .whenComplete(() {
          if (identical(_inFlight[key], operation)) _inFlight.remove(key);
        });
    if (_inFlight.length < maxEntries) _inFlight[key] = operation;
    return operation;
  }

  /// Invalid policy answers are discarded rather than retained as successes.
  void evict(String host) {
    final key = host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
    _entries.remove(key);
    _inFlight.remove(key);
  }

  void clear() {
    _entries.clear();
    _inFlight.clear();
  }
}

final class _AddressCacheEntry {
  const _AddressCacheEntry(this.addresses, this.expiresAt);
  final List<InternetAddress> addresses;
  final DateTime expiresAt;
}
