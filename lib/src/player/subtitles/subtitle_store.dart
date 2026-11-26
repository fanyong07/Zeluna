import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import 'subtitle_document.dart';

/// Separate from synced settings. Documents and local paths never enter sync.
class SubtitleStore {
  SubtitleStore({
    Map<String, dynamic>? initial,
    Future<void> Function(Map<String, dynamic>)? persist,
  }) : _data = initial ?? <String, dynamic>{},
       _persist = persist;

  static final _accountEpochs = <String, int>{};
  static final _accountWrites = <String, Future<void>>{};
  static const boxName = 'anime.subtitles.v1';

  static String _accountKey(String? accountId) => sha256
      .convert(utf8.encode(accountId == null ? 'guest' : 'account:$accountId'))
      .toString();

  static Future<void> _serializeAccountWrite(
    String key,
    Future<void> Function() action,
  ) {
    final result = (_accountWrites[key] ?? Future<void>.value()).then(
      (_) => action(),
    );
    final settled = result.catchError((Object _) {});
    _accountWrites[key] = settled;
    unawaited(
      settled.then((_) {
        if (identical(_accountWrites[key], settled)) _accountWrites.remove(key);
      }),
    );
    return result;
  }

  static Future<SubtitleStore> open(String? accountId) async {
    final key = _accountKey(accountId);
    final epoch = _accountEpochs[key] ?? 0;
    final box = await Hive.openBox<dynamic>(boxName);
    final raw = box.get(key);
    Map<String, dynamic>? initial;
    try {
      if (raw is Map) {
        initial = (jsonDecode(jsonEncode(raw)) as Map).cast<String, dynamic>();
      }
    } catch (_) {
      /* corrupt cache does not block playback */
    }
    return SubtitleStore(
      initial: initial,
      persist: (value) => _serializeAccountWrite(key, () async {
        if (epoch == (_accountEpochs[key] ?? 0)) await box.put(key, value);
      }),
    );
  }

  /// Account-deletion recovery must await this; revoked stores cannot recreate data.
  static Future<void> clearAccount(String accountId) async {
    final key = _accountKey(accountId);
    _accountEpochs[key] = (_accountEpochs[key] ?? 0) + 1;
    await _serializeAccountWrite(key, () async {
      final box = await Hive.openBox<dynamic>(boxName);
      await box.delete(key);
    });
  }

  final Map<String, dynamic> _data;
  final Future<void> Function(Map<String, dynamic>)? _persist;
  Future<void> _writes = Future.value();
  Map<String, dynamic> _section(String name) =>
      (_data.putIfAbsent(name, () => <String, dynamic>{}) as Map)
          .cast<String, dynamic>();
  String _key(List<String> values) => jsonEncode(values);

  Map<String, dynamic> preferences(String subjectKey) {
    final raw = _section('preferences')[subjectKey];
    return raw is Map ? Map<String, dynamic>.from(raw) : {};
  }

  Future<void> setPreferences(String subjectKey, Map<String, dynamic> value) {
    _section('preferences')[subjectKey] = value;
    return _save();
  }

  SubtitleDocument? documentFor(String episodeKey, String language) {
    final hash = _section('bindings')[_key([episodeKey, language])];
    return SubtitleDocument.fromJson(_section('documents')[hash]);
  }

  String _documentKey(SubtitleDocument document) =>
      _key([document.hash, document.language, document.fileName]);
  SubtitleDocument? sourceDocument(
    String provider,
    String entry,
    String sourceId,
    String language,
  ) {
    final hash = _section(
      'sources',
    )[_key([provider, entry, sourceId, language])];
    return SubtitleDocument.fromJson(_section('documents')[hash]);
  }

  Future<void> rememberSource(
    String provider,
    String entry,
    SubtitleDocument document, {
    String? sourceId,
  }) {
    _section('sources')[_key([
      provider,
      entry,
      sourceId ?? document.fileName,
      document.language,
    ])] = _documentKey(
      document,
    );
    return _save();
  }

  Future<void> bindDocument(String episodeKey, SubtitleDocument document) {
    final documents = _section('documents');
    final key = _documentKey(document);
    documents.remove(key);
    documents[key] = document.toJson();
    _section('bindings')[_key([episodeKey, document.language])] = key;
    // Account-local bounded cache. Eviction also removes dangling bindings.
    while (documents.length > 100 ||
        (documents.length > 1 &&
            utf8.encode(jsonEncode(documents)).length > 20 * 1024 * 1024)) {
      final oldest = documents.keys.first;
      documents.remove(oldest);
      _section('bindings').removeWhere((_, value) => value == oldest);
      _section('sources').removeWhere((_, value) => value == oldest);
    }
    return _save();
  }

  bool isBilingual(String episodeKey, String lineKey) =>
      _section('bilingual')[_key([episodeKey, lineKey])] == true;
  Future<void> setBilingual(String episodeKey, String lineKey, bool value) {
    final key = _key([episodeKey, lineKey]);
    if (value) {
      _section('bilingual')[key] = true;
    } else {
      _section('bilingual').remove(key);
    }
    return _save();
  }

  int delayFor(String episodeKey, String lineKey, String hash) =>
      (_section('delays')[_key([episodeKey, lineKey, hash])] as num?)
          ?.toInt() ??
      0;
  Future<void> setDelay(
    String episodeKey,
    String lineKey,
    String hash,
    int delay,
  ) {
    _section('delays')[_key([episodeKey, lineKey, hash])] = delay;
    return _save();
  }

  Future<void> clear() {
    _data.clear();
    return _save();
  }

  Future<void> _save() {
    for (final name in [
      'preferences',
      'bindings',
      'delays',
      'bilingual',
      'sources',
    ]) {
      final section = _section(name);
      while (section.length > 1000) {
        section.remove(section.keys.first);
      }
    }
    final snapshot = (jsonDecode(jsonEncode(_data)) as Map)
        .cast<String, dynamic>();
    final result = _writes.then((_) async {
      await _persist?.call(snapshot);
    });
    _writes = result.catchError((Object _) {});
    return result;
  }
}
