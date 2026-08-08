import 'dart:collection';

import 'package:hive_ce_flutter/hive_flutter.dart';

import '../accounts/account_controller.dart';
import '../domain/anime_models.dart';

const playbackLineMemorySettingsKey = 'playbackLineMemory.v1';

/// Stores only the last successful provider for a subject.
///
/// Media URLs, headers and expiry information are deliberately excluded. The
/// store is account-scoped and rejects late writes from an old account scope.
final class PlaybackLineMemoryStore {
  PlaybackLineMemoryStore(this._settings, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  static const maxEntries = 200;

  final Box<dynamic> _settings;
  final DateTime Function() _now;
  final LinkedHashMap<String, _PlaybackLineMemoryEntry> _entries =
      LinkedHashMap<String, _PlaybackLineMemoryEntry>();

  String? _accountId;
  var _contextVersion = 0;
  var _loaded = false;
  Future<void> _writeQueue = Future<void>.value();

  void loadForAccount({
    required String? accountId,
    required int contextVersion,
  }) {
    _accountId = accountId;
    _contextVersion = contextVersion;
    _entries
      ..clear()
      ..addAll(_readEntries(_settings.get(_key(accountId))));
    _loaded = true;
  }

  String? preferredProviderFor(AnimeSubject subject) {
    if (!_loaded) return null;
    return _entries[subject.identityKey]?.providerId;
  }

  Future<void> rememberSuccessfulProvider({
    required AnimeSubject subject,
    required PlaybackLine line,
    required int expectedContextVersion,
  }) {
    if (!_isReusableSubject(subject) ||
        !_isReusableProvider(line.providerId) ||
        !_isCurrent(expectedContextVersion)) {
      return Future<void>.value();
    }
    final accountId = _accountId;
    final contextVersion = _contextVersion;
    final subjectKey = subject.identityKey;
    final next = _PlaybackLineMemoryEntry(
      providerId: line.providerId.trim(),
      updatedAt: _now(),
    );
    _entries.remove(subjectKey);
    _entries[subjectKey] = next;
    _trim();
    return _enqueueWrite(accountId, contextVersion);
  }

  Future<void> clearForCurrentAccount({required int expectedContextVersion}) {
    if (!_isCurrent(expectedContextVersion)) return Future<void>.value();
    _entries.clear();
    return _enqueueWrite(_accountId, _contextVersion);
  }

  Future<void> settleWrites() => _writeQueue;

  Map<String, dynamic> debugSnapshot() => <String, dynamic>{
    'version': 1,
    'entries': <Map<String, dynamic>>[
      for (final entry in _entries.entries)
        <String, dynamic>{
          'subjectKey': entry.key,
          'providerId': entry.value.providerId,
          'updatedAt': entry.value.updatedAt.millisecondsSinceEpoch,
        },
    ],
  };

  String _key(String? accountId) => AccountController.settingsKeyFor(
    accountId,
    playbackLineMemorySettingsKey,
  );

  Future<void> _enqueueWrite(String? accountId, int contextVersion) {
    final snapshot = debugSnapshot();
    final write = _writeQueue.then((_) async {
      if (!_isCurrentScope(accountId, contextVersion)) return;
      await _settings.put(_key(accountId), snapshot);
    });
    _writeQueue = write.then<void>((_) {}, onError: (_, _) {});
    return write;
  }

  bool _isCurrent(int expectedContextVersion) =>
      _loaded && expectedContextVersion == _contextVersion;

  bool _isCurrentScope(String? accountId, int contextVersion) =>
      _loaded && accountId == _accountId && contextVersion == _contextVersion;

  void _trim() {
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  static bool _isReusableSubject(AnimeSubject subject) {
    final source = subject.source.trim().toLowerCase();
    return source != 'direct' && source != 'offline';
  }

  static bool _isReusableProvider(String providerId) {
    final value = providerId.trim().toLowerCase();
    return value.isNotEmpty &&
        value != 'direct' &&
        value != 'local' &&
        value != 'network' &&
        value != 'offline' &&
        !value.startsWith('direct:') &&
        !value.startsWith('local:') &&
        !value.startsWith('network:') &&
        !value.startsWith('offline:');
  }

  static Map<String, _PlaybackLineMemoryEntry> _readEntries(Object? raw) {
    final result = <String, _PlaybackLineMemoryEntry>{};
    if (raw is! Map) return result;
    final rawEntries = raw['entries'];
    if (rawEntries is! List) return result;
    final parsed = <MapEntry<String, _PlaybackLineMemoryEntry>>[];
    for (final item in rawEntries) {
      if (item is! Map) continue;
      final subjectKey = item['subjectKey']?.toString().trim() ?? '';
      final providerId = item['providerId']?.toString().trim() ?? '';
      final updatedAt = _dateFrom(item['updatedAt']);
      if (subjectKey.isEmpty || providerId.isEmpty || updatedAt == null) {
        continue;
      }
      parsed.add(
        MapEntry(
          subjectKey,
          _PlaybackLineMemoryEntry(
            providerId: providerId,
            updatedAt: updatedAt,
          ),
        ),
      );
    }
    parsed.sort((a, b) => a.value.updatedAt.compareTo(b.value.updatedAt));
    for (final item in parsed) {
      result.remove(item.key);
      result[item.key] = item.value;
    }
    while (result.length > maxEntries) {
      result.remove(result.keys.first);
    }
    return result;
  }

  static DateTime? _dateFrom(Object? value) {
    if (value is DateTime) return value;
    if (value is num) {
      return DateTime.fromMillisecondsSinceEpoch(value.toInt());
    }
    return DateTime.tryParse(value?.toString() ?? '');
  }
}

final class _PlaybackLineMemoryEntry {
  const _PlaybackLineMemoryEntry({
    required this.providerId,
    required this.updatedAt,
  });

  final String providerId;
  final DateTime updatedAt;
}
