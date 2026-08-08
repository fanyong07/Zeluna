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
