import '../domain/anime_models.dart';

/// Keeps a small, short-lived copy of backend playback results so a detail-page
/// prefetch can be handed directly to the player without another HTTP roundtrip.
class PlaybackPrefetchCache {
  PlaybackPrefetchCache({
    this.ttl = const Duration(seconds: 90),
    this.maxEntries = 64,
    DateTime Function()? now,
  }) : assert(ttl > Duration.zero),
       assert(maxEntries > 0),
       _now = now ?? DateTime.now;

  final Duration ttl;
  final int maxEntries;
  final DateTime Function() _now;
  final Map<String, _PlaybackPrefetchEntry> _entries =
      <String, _PlaybackPrefetchEntry>{};

  List<PlaybackLine>? read(
    String key, {
    Duration minValidity = const Duration(seconds: 15),
  }) {
    final now = _now();
    _removeExpiredEntries(now);
    final entry = _entries[key];
    if (entry == null) return null;
    final lines = entry.lines
        .where((line) => _isReusable(line, now, minValidity))
        .toList(growable: false);
    if (lines.isEmpty) {
      _entries.remove(key);
      return null;
    }
    if (lines.length != entry.lines.length) {
      _entries[key] = _PlaybackPrefetchEntry(
        lines: List<PlaybackLine>.unmodifiable(lines),
        expiresAt: entry.expiresAt,
      );
    }
    return List<PlaybackLine>.unmodifiable(lines);
  }

  void write(String key, Iterable<PlaybackLine> lines, {Duration? ttl}) {
    final now = _now();
    final reusable = lines
        .where((line) => _isReusable(line, now, Duration.zero))
        .toList(growable: false);
    if (reusable.isEmpty) {
      _entries.remove(key);
      return;
    }
    _removeExpiredEntries(now);
    // Reinsert existing keys so eviction follows recent write order.
    _entries.remove(key);
    while (_entries.length >= maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    _entries[key] = _PlaybackPrefetchEntry(
      lines: List<PlaybackLine>.unmodifiable(reusable),
      expiresAt: now.add(ttl ?? this.ttl),
    );
  }

  void clear() => _entries.clear();

  int get length => _entries.length;

  void _removeExpiredEntries(DateTime now) {
    _entries.removeWhere((_, entry) => !entry.expiresAt.isAfter(now));
  }

  static bool _isReusable(
    PlaybackLine line,
    DateTime now,
    Duration minValidity,
  ) {
    final rawUrl = line.url?.trim() ?? '';
    final uri = Uri.tryParse(rawUrl);
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      return false;
    }
    final expiresAt = line.expiresAt;
    if (expiresAt != null && !expiresAt.isAfter(now.add(minValidity))) {
      return false;
    }
    return line.available ||
        line.serverVerified ||
        line.clientVerified ||
        line.requiresClientProbe;
  }
}

class _PlaybackPrefetchEntry {
  const _PlaybackPrefetchEntry({required this.lines, required this.expiresAt});

  final List<PlaybackLine> lines;
  final DateTime expiresAt;
}

/// A short-lived, verified route set prepared for an upcoming episode.
///
/// Unlike persistent provider memory, this bundle may contain ephemeral media
/// URLs and therefore must only live in the bounded runtime cache below.
final class NextEpisodeWarmupBundle {
  NextEpisodeWarmupBundle._({
    required this.episodeIdentity,
    required this.primary,
    required List<PlaybackLine> fallbacks,
    required this.preferredProviderId,
    required this.preparedAt,
    required this.earliestExpiry,
  }) : fallbacks = List<PlaybackLine>.unmodifiable(fallbacks),
       allLines = List<PlaybackLine>.unmodifiable(<PlaybackLine>[
         primary,
         ...fallbacks,
       ]);

  final String episodeIdentity;
  final PlaybackLine primary;
  final List<PlaybackLine> fallbacks;
  final String? preferredProviderId;
  final DateTime preparedAt;
  final DateTime? earliestExpiry;
  final List<PlaybackLine> allLines;

  PlaybackLine? get fallback => fallbacks.isEmpty ? null : fallbacks.first;
}

/// Stores a verified primary and at most one verified fallback per episode.
///
/// Reads apply both the cache TTL and the caller's expected minimum route
/// validity. If the original primary becomes stale while its fallback remains
/// fresh, the fallback is promoted instead of turning the whole entry into a
/// miss.
final class NextEpisodeWarmupCache {
  NextEpisodeWarmupCache({
    this.ttl = const Duration(minutes: 45),
    this.maxEntries = 8,
    DateTime Function()? now,
  }) : assert(ttl > Duration.zero),
       assert(maxEntries > 0),
       _now = now ?? DateTime.now;

  final Duration ttl;
  final int maxEntries;
  final DateTime Function() _now;
  final Map<String, _NextEpisodeWarmupEntry> _entries =
      <String, _NextEpisodeWarmupEntry>{};

  NextEpisodeWarmupBundle? read(
    String key, {
    Duration minValidity = Duration.zero,
  }) {
    assert(minValidity >= Duration.zero);
    final now = _now();
    _removeExpiredEntries(now);
    final entry = _entries[key];
    if (entry == null) return null;
    final actuallyReusable = entry.bundle.allLines
        .where((line) => _isVerifiedReusable(line, now, Duration.zero))
        .take(2)
        .toList(growable: false);
    if (actuallyReusable.isEmpty) {
      _entries.remove(key);
      return null;
    }
    final stored = _bundle(
      episodeIdentity: entry.bundle.episodeIdentity,
      lines: actuallyReusable,
      preferredProviderId: entry.bundle.preferredProviderId,
      preparedAt: entry.bundle.preparedAt,
    );
    _entries[key] = _NextEpisodeWarmupEntry(
      bundle: stored,
      expiresAt: entry.expiresAt,
    );
    final reusable = stored.allLines
        .where((line) => _isVerifiedReusable(line, now, minValidity))
        .take(2)
        .toList(growable: false);
    if (reusable.isEmpty) return null;
    return _bundle(
      episodeIdentity: stored.episodeIdentity,
      lines: reusable,
      preferredProviderId: stored.preferredProviderId,
      preparedAt: stored.preparedAt,
    );
  }

  NextEpisodeWarmupBundle? write(
    String key, {
    required String episodeIdentity,
    required PlaybackLine primary,
    Iterable<PlaybackLine> fallbacks = const <PlaybackLine>[],
    String? preferredProviderId,
    DateTime? preparedAt,
    Duration? ttl,
  }) {
    final now = _now();
    final identity = episodeIdentity.trim();
    final reusable = _verifiedDistinctLines(<PlaybackLine>[
      primary,
      ...fallbacks,
    ], now);
    if (identity.isEmpty || reusable.isEmpty) {
      _entries.remove(key);
      return null;
    }
    final effectivePreparedAt = preparedAt ?? now;
    final expiresAt = effectivePreparedAt.add(ttl ?? this.ttl);
    if (!expiresAt.isAfter(now)) {
      _entries.remove(key);
      return null;
    }
    final bundle = _bundle(
      episodeIdentity: identity,
      lines: reusable,
      preferredProviderId: preferredProviderId,
      preparedAt: effectivePreparedAt,
    );
    _removeExpiredEntries(now);
    _entries.remove(key);
    while (_entries.length >= maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    _entries[key] = _NextEpisodeWarmupEntry(
      bundle: bundle,
      expiresAt: expiresAt,
    );
    return bundle;
  }

  void remove(String key) => _entries.remove(key);

  void clear() => _entries.clear();

  int get length => _entries.length;

  void _removeExpiredEntries(DateTime now) {
    _entries.removeWhere((_, entry) => !entry.expiresAt.isAfter(now));
  }

  static List<PlaybackLine> _verifiedDistinctLines(
    Iterable<PlaybackLine> lines,
    DateTime now,
  ) {
    final result = <PlaybackLine>[];
    final ids = <String>{};
    final urls = <String>{};
    for (final line in lines) {
      if (!_isVerifiedReusable(line, now, Duration.zero)) continue;
      final url = line.url!.trim();
      final id = line.id.trim();
      if ((id.isNotEmpty && ids.contains(id)) || urls.contains(url)) continue;
      if (id.isNotEmpty) ids.add(id);
      urls.add(url);
      result.add(line);
      if (result.length == 2) break;
    }
    return List<PlaybackLine>.unmodifiable(result);
  }

  static bool _isVerifiedReusable(
    PlaybackLine line,
    DateTime now,
    Duration minValidity,
  ) {
    if (!line.available || (!line.serverVerified && !line.clientVerified)) {
      return false;
    }
    final rawUrl = line.url?.trim() ?? '';
    final uri = Uri.tryParse(rawUrl);
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      return false;
    }
    final expiresAt = line.expiresAt;
    return expiresAt == null || expiresAt.isAfter(now.add(minValidity));
  }

  static NextEpisodeWarmupBundle _bundle({
    required String episodeIdentity,
    required List<PlaybackLine> lines,
    required String? preferredProviderId,
    required DateTime preparedAt,
  }) {
    final expiries = lines.map((line) => line.expiresAt).whereType<DateTime>();
    DateTime? earliestExpiry;
    for (final expiry in expiries) {
      if (earliestExpiry == null || expiry.isBefore(earliestExpiry)) {
        earliestExpiry = expiry;
      }
    }
    final preferred = preferredProviderId?.trim();
    return NextEpisodeWarmupBundle._(
      episodeIdentity: episodeIdentity,
      primary: lines.first,
      fallbacks: lines.skip(1).take(1).toList(growable: false),
      preferredProviderId: preferred == null || preferred.isEmpty
          ? null
          : preferred,
      preparedAt: preparedAt,
      earliestExpiry: earliestExpiry,
    );
  }
}

final class _NextEpisodeWarmupEntry {
  const _NextEpisodeWarmupEntry({
    required this.bundle,
    required this.expiresAt,
  });

  final NextEpisodeWarmupBundle bundle;
  final DateTime expiresAt;
}
