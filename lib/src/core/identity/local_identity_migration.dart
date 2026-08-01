import 'dart:async';
import 'dart:convert';

import 'package:hive_ce_flutter/hive_flutter.dart';

import 'stable_identity.dart';

typedef LocalIdentityMigrationCheckpoint =
    FutureOr<void> Function(String storageKey);

class LocalIdentityMigrationReport {
  const LocalIdentityMigrationReport({
    required this.examinedKeys,
    required this.changedKeys,
    required this.mergedRecords,
    required this.retainedLegacyRecords,
    required this.failedKeys,
    required this.alreadyCompleted,
  });

  final int examinedKeys;
  final int changedKeys;
  final int mergedRecords;
  final int retainedLegacyRecords;
  final List<String> failedKeys;
  final bool alreadyCompleted;
}

/// Upgrades persisted media and rule identities without clearing any Hive box.
///
/// Each user-data key is replaced by one atomic Hive `put`. A marker is written
/// after every key, so a process interruption can safely replay only the last
/// uncommitted key. Transformations are deterministic and idempotent.
class LocalIdentityMigration {
  LocalIdentityMigration({required this.settings, required this.library});

  static const schemaVersion = 1;
  static const markerKey = 'identity.migration.v1';

  final Box<dynamic> settings;
  final Box<dynamic> library;

  Future<LocalIdentityMigrationReport> run({
    LocalIdentityMigrationCheckpoint? checkpoint,
  }) async {
    final previous = _stringMap(settings.get(markerKey));
    if (previous?['version'] == schemaVersion &&
        previous?['status'] == 'completed') {
      return const LocalIdentityMigrationReport(
        examinedKeys: 0,
        changedKeys: 0,
        mergedRecords: 0,
        retainedLegacyRecords: 0,
        failedKeys: [],
        alreadyCompleted: true,
      );
    }

    final completedKeys = <String>{
      ..._stringValues(previous?['completedKeys']),
    };
    final failedKeys = <String>{..._stringValues(previous?['failedKeys'])};
    final work = _workItems();
    var examined = 0;
    var changed = 0;
    var merged = 0;
    var retainedLegacy = 0;

    await _writeMarker(
      status: 'in_progress',
      completedKeys: completedKeys,
      failedKeys: failedKeys,
    );

    for (final item in work) {
      if (completedKeys.contains(item.storageKey)) continue;
      examined++;
      final original = item.box.get(item.key);
      _TransformResult result;
      try {
        result = item.transform(original);
      } catch (_) {
        // Damaged or unknown records remain untouched. Their key is recorded
        // so one legacy item cannot block the rest of the user's library.
        result = _TransformResult(original, retainedLegacyRecords: 1);
        failedKeys.add(item.storageKey);
      }
      if (!_deepEquivalent(original, result.value)) {
        await item.box.put(item.key, result.value);
        changed++;
      }
      merged += result.mergedRecords;
      retainedLegacy += result.retainedLegacyRecords;
      if (result.retainedLegacyRecords > 0) {
        failedKeys.add(item.storageKey);
      }

      // Tests use this boundary to simulate a crash after the atomic data put
      // but before the checkpoint marker. Replaying the key must be harmless.
      await checkpoint?.call(item.storageKey);
      completedKeys.add(item.storageKey);
      await _writeMarker(
        status: 'in_progress',
        completedKeys: completedKeys,
        failedKeys: failedKeys,
      );
    }

    await _writeMarker(
      status: 'completed',
      completedKeys: completedKeys,
      failedKeys: failedKeys,
    );
    return LocalIdentityMigrationReport(
      examinedKeys: examined,
      changedKeys: changed,
      mergedRecords: merged,
      retainedLegacyRecords: retainedLegacy,
      failedKeys: List.unmodifiable(failedKeys.toList()..sort()),
      alreadyCompleted: false,
    );
  }

  List<_MigrationWorkItem> _workItems() {
    final items = <_MigrationWorkItem>[];
    for (final rawKey in settings.keys) {
      final key = rawKey.toString();
      if (_matchesScopedKey(key, 'rulePlugins')) {
        items.add(
          _MigrationWorkItem(
            box: settings,
            key: rawKey,
            storageKey: 'settings:$key',
            transform: _migrateRuleState,
          ),
        );
      }
    }
    for (final rawKey in library.keys) {
      final key = rawKey.toString();
      _TransformResult Function(Object?)? transform;
      if (_libraryEntryKinds.any((kind) => _matchesScopedKey(key, kind))) {
        transform = (value) => _migrateLibraryEntries(value, key);
      } else if (_matchesScopedKey(key, 'offlineTasks')) {
        transform = _migrateDownloadTasks;
      } else if (_matchesScopedKey(key, 'feedbacks')) {
        transform = _migrateFeedbacks;
      } else if (key.startsWith('metadata.cache.')) {
        transform = _migrateNestedSubjects;
      }
      if (transform != null) {
        items.add(
          _MigrationWorkItem(
            box: library,
            key: rawKey,
            storageKey: 'library:$key',
            transform: transform,
          ),
        );
      }
    }
    items.sort((left, right) => left.storageKey.compareTo(right.storageKey));
    return items;
  }

  Future<void> _writeMarker({
    required String status,
    required Set<String> completedKeys,
    required Set<String> failedKeys,
  }) {
    return settings.put(markerKey, {
      'version': schemaVersion,
      'status': status,
      'completedKeys': completedKeys.toList(growable: false)..sort(),
      'failedKeys': failedKeys.toList(growable: false)..sort(),
    });
  }
}

const _libraryEntryKinds = <String>{
  'favorites',
  'history',
  'following',
  'imageFavorites',
};

bool _matchesScopedKey(String key, String suffix) =>
    key == suffix || key.endsWith('.$suffix');

_TransformResult _migrateLibraryEntries(Object? raw, String storageKey) {
  if (raw is! List) return _TransformResult(raw, retainedLegacyRecords: 1);
  final migrated = <Map<String, dynamic>>[];
  for (final item in raw) {
    final entry = _stringMap(item);
    final subject = _stringMap(entry?['subject']);
    if (entry == null || subject == null) {
      return _TransformResult(raw, retainedLegacyRecords: 1);
    }
    final nextSubject = _migrateSubject(subject);
    final next = <String, dynamic>{...entry, 'subject': nextSubject};
    final episode = _stringMap(entry['episode']);
    if (episode != null) {
      next['episode'] = _migrateEpisode(
        episode,
        nextSubject['stableKey'].toString(),
      );
    }
    migrated.add(next);
  }

  final unique = <String, Map<String, dynamic>>{};
  var merged = 0;
  for (var index = 0; index < migrated.length; index++) {
    final entry = migrated[index];
    final subject = _stringMap(entry['subject']);
    final stableKey = subject?['stableKey']?.toString().trim() ?? '';
    final key = stableKey.isEmpty ? 'legacy:$index' : stableKey;
    final existing = unique[key];
    if (existing == null) {
      unique[key] = entry;
    } else {
      unique[key] = _mergeLibraryEntries(existing, entry);
      merged++;
    }
  }
  final values = unique.values.toList(growable: false)
    ..sort((left, right) => _entryDate(right).compareTo(_entryDate(left)));
  return _TransformResult(values, mergedRecords: merged);
}

Map<String, dynamic> _mergeLibraryEntries(
  Map<String, dynamic> first,
  Map<String, dynamic> second,
) {
  final comparison = _compareEntryRecency(first, second);
  final preferred = comparison >= 0 ? first : second;
  final other = identical(preferred, first) ? second : first;
  final result = <String, dynamic>{...preferred};
  final subject = _stringMap(preferred['subject']);
  final otherSubject = _stringMap(other['subject']);
  if (subject != null && otherSubject != null) {
    result['subject'] = _mergeSubjectAliases(subject, otherSubject);
  }
  return result;
}

int _compareEntryRecency(
  Map<String, dynamic> first,
  Map<String, dynamic> second,
) {
  final byDate = _entryDate(first).compareTo(_entryDate(second));
  if (byDate != 0) return byDate;
  final byPosition = _asInt(
    first['positionSeconds'],
  ).compareTo(_asInt(second['positionSeconds']));
  if (byPosition != 0) return byPosition;
  return _canonicalJson(first).compareTo(_canonicalJson(second));
}

DateTime _entryDate(Map<String, dynamic> entry) =>
    DateTime.tryParse(entry['updatedAt']?.toString() ?? '')?.toUtc() ??
    DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

_TransformResult _migrateFeedbacks(Object? raw) {
  if (raw is! List) return _TransformResult(raw, retainedLegacyRecords: 1);
  var retainedLegacy = 0;
  final values = <Object?>[];
  for (final item in raw) {
    final feedback = _stringMap(item);
    if (feedback == null) {
      retainedLegacy++;
      values.add(item);
      continue;
    }
    final subject = _stringMap(feedback['subject']);
    values.add(
      subject == null
          ? feedback
          : <String, dynamic>{...feedback, 'subject': _migrateSubject(subject)},
    );
  }
  return _TransformResult(values, retainedLegacyRecords: retainedLegacy);
}

_TransformResult _migrateDownloadTasks(Object? raw) {
  if (raw is! List) return _TransformResult(raw, retainedLegacyRecords: 1);
  final tasks = <Map<String, dynamic>>[];
  for (final item in raw) {
    final task = _stringMap(item);
    if (task == null) {
      return _TransformResult(raw, retainedLegacyRecords: 1);
    }
    final migrated = task.containsKey('status') && task.containsKey('id')
        ? _migrateCurrentDownloadTask(task)
        : _migrateLegacyDownloadEntry(task);
    if (migrated == null) {
      return _TransformResult(raw, retainedLegacyRecords: 1);
    } else {
      tasks.add(migrated);
    }
  }

  final unique = <String, Map<String, dynamic>>{};
  var merged = 0;
  for (var index = 0; index < tasks.length; index++) {
    final task = tasks[index];
    final id = task['id']?.toString().trim() ?? '';
    final key = id.isEmpty ? 'legacy:$index' : id;
    final existing = unique[key];
    if (existing == null) {
      unique[key] = task;
    } else {
      unique[key] = _mergeDownloadTask(existing, task);
      merged++;
    }
  }
  final values = unique.values.toList(growable: false)
    ..sort((left, right) => _taskDate(right).compareTo(_taskDate(left)));
  return _TransformResult(values, mergedRecords: merged);
}

Map<String, dynamic>? _migrateCurrentDownloadTask(Map<String, dynamic> task) {
  final subject = _stringMap(task['subject']);
  final episode = _stringMap(task['episode']);
  if (subject == null || episode == null) return null;
  final nextSubject = _migrateSubject(subject);
  final subjectKey = nextSubject['stableKey'].toString();
  final nextEpisode = _migrateEpisode(episode, subjectKey);
  final episodeKey = nextEpisode['stableKey'].toString();
  final expectedId = stableDownloadTaskKey(
    subjectKey: subjectKey,
    episodeKey: episodeKey,
  );
  final oldId = task['id']?.toString().trim() ?? '';
  final legacyIds = <String>{
    ..._stringValues(task['legacyIds']),
    if ((task['legacyId']?.toString().trim() ?? '').isNotEmpty)
      task['legacyId'].toString().trim(),
    if (oldId.isNotEmpty && oldId != expectedId) oldId,
  };
  final sortedLegacyIds = legacyIds.toList(growable: false)..sort();
  return <String, dynamic>{
    ...task,
    'version': 3,
    'id': expectedId,
    'subject': nextSubject,
    'episode': nextEpisode,
    'url': null,
    'headers': const <String, String>{},
    if (sortedLegacyIds.isNotEmpty) 'legacyId': sortedLegacyIds.first,
    if (sortedLegacyIds.isNotEmpty) 'legacyIds': sortedLegacyIds,
  };
}

Map<String, dynamic>? _migrateLegacyDownloadEntry(Map<String, dynamic> entry) {
  final subject = _stringMap(entry['subject']);
  if (subject == null) return null;
  final nextSubject = _migrateSubject(subject);
  final subjectKey = nextSubject['stableKey'].toString();
  final rawEpisode = _stringMap(entry['episode']);
  final episode =
      rawEpisode ??
      <String, dynamic>{
        'id': 0,
        'subjectId': _asInt(nextSubject['id']),
        'number': 1,
        'title': '',
        'airdate': null,
        'duration': '',
        'description': '',
        'thumbnailUrl': null,
      };
  final nextEpisode = _migrateEpisode(episode, subjectKey);
  if (_asInt(nextEpisode['id']) == 0) {
    nextEpisode['id'] = stableInt63(nextEpisode['stableKey'].toString());
  }
  final episodeKey = nextEpisode['stableKey'].toString();
  final id = stableDownloadTaskKey(
    subjectKey: subjectKey,
    episodeKey: episodeKey,
  );
  final note = entry['note']?.toString() ?? '';
  final lines = const LineSplitter().convert(note);
  final path = lines.length > 1 ? lines.last.trim() : '';
  final completed = note.startsWith('已下载') && path.isNotEmpty;
  final timestamp =
      entry['updatedAt']?.toString() ??
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true).toIso8601String();
  final legacyId =
      'legacy-${nextSubject['source']}-${nextSubject['id']}-${episode['id']}';
  return <String, dynamic>{
    'version': 3,
    'id': id,
    'legacyId': legacyId,
    'legacyIds': [legacyId],
    'subject': nextSubject,
    'episode': nextEpisode,
    'createdAt': timestamp,
    'updatedAt': timestamp,
    'status': completed ? 'completed' : 'failed',
    'lineId': null,
    'providerName': null,
    'format': null,
    'url': null,
    'headers': const <String, String>{},
    'downloadedBytes': 0,
    'totalBytes': 0,
    'temporaryPath': null,
    'localPath': path.isEmpty ? null : path,
    'etag': null,
    'lastModified': null,
    'completedUnits': completed ? 1 : 0,
    'totalUnits': completed ? 1 : 0,
    'message': completed ? '从旧版下载记录迁移' : '旧下载记录无法继续，请重新下载',
  };
}

Map<String, dynamic> _mergeDownloadTask(
  Map<String, dynamic> first,
  Map<String, dynamic> second,
) {
  final preferred = _compareTask(first, second) >= 0 ? first : second;
  final other = identical(preferred, first) ? second : first;
  final result = <String, dynamic>{...preferred};
  for (final key in ['localPath', 'temporaryPath', 'etag', 'lastModified']) {
    if ((result[key]?.toString().trim() ?? '').isEmpty &&
        (other[key]?.toString().trim() ?? '').isNotEmpty) {
      result[key] = other[key];
    }
  }
  for (final key in [
    'downloadedBytes',
    'totalBytes',
    'completedUnits',
    'totalUnits',
  ]) {
    result[key] = _asInt(result[key]) >= _asInt(other[key])
        ? _asInt(result[key])
        : _asInt(other[key]);
  }
  final legacyIds = <String>{
    ..._stringValues(first['legacyIds']),
    ..._stringValues(second['legacyIds']),
    if ((first['legacyId']?.toString().trim() ?? '').isNotEmpty)
      first['legacyId'].toString().trim(),
    if ((second['legacyId']?.toString().trim() ?? '').isNotEmpty)
      second['legacyId'].toString().trim(),
  };
  if (legacyIds.isNotEmpty) {
    final sorted = legacyIds.toList(growable: false)..sort();
    result['legacyId'] = sorted.first;
    result['legacyIds'] = sorted;
  }
  final paths = <String>{
    for (final task in [first, second])
      if ((task['localPath']?.toString().trim() ?? '').isNotEmpty)
        task['localPath'].toString().trim(),
  };
  if (paths.length > 1) {
    result['legacyLocalPaths'] = paths.toList(growable: false)..sort();
  }
  return result;
}

int _compareTask(Map<String, dynamic> first, Map<String, dynamic> second) {
  final byRank = _taskRank(first).compareTo(_taskRank(second));
  if (byRank != 0) return byRank;
  final byDate = _taskDate(first).compareTo(_taskDate(second));
  if (byDate != 0) return byDate;
  return _canonicalJson(first).compareTo(_canonicalJson(second));
}

int _taskRank(Map<String, dynamic> task) {
  final hasLocalPath = (task['localPath']?.toString().trim() ?? '').isNotEmpty;
  final status = task['status']?.toString() ?? '';
  final statusRank = switch (status) {
    'completed' => 70,
    'paused' => 60,
    'downloading' => 50,
    'resolving' => 40,
    'queued' => 30,
    'failed' => 20,
    'cancelled' => 10,
    _ => 0,
  };
  return (hasLocalPath ? 1000 : 0) + statusRank;
}

DateTime _taskDate(Map<String, dynamic> task) =>
    DateTime.tryParse(task['updatedAt']?.toString() ?? '')?.toUtc() ??
    DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

_TransformResult _migrateRuleState(Object? raw) {
  final state = _stringMap(raw);
  if (state == null) return _TransformResult(raw, retainedLegacyRecords: 1);
  for (final key in [
    'installedIds',
    'enabledIds',
    'customRules',
    'repositories',
  ]) {
    final value = state[key];
    if (value != null && value is! List) {
      return _TransformResult(raw, retainedLegacyRecords: 1);
    }
  }
  final idAliases = <String, String>{};
  final customRules = <Map<String, dynamic>>[];
  final rawRules = state['customRules'];
  if (rawRules is List) {
    for (final item in rawRules) {
      final rule = _stringMap(item);
      if (rule == null) {
        return _TransformResult(raw, retainedLegacyRecords: 1);
      }
      final oldId = rule['id']?.toString().trim() ?? '';
      final newId = _migratedRuleId(rule, oldId);
      if (newId == null || newId == oldId) {
        customRules.add(rule);
        continue;
      }
      idAliases[oldId] = newId;
      final legacyIds = <String>{..._stringValues(rule['legacyIds']), oldId};
      customRules.add({
        ...rule,
        'id': newId,
        'legacyIds': legacyIds.toList(growable: false)..sort(),
      });
    }
  }
  final uniqueRules = <String, Map<String, dynamic>>{};
  var merged = 0;
  for (final rule in customRules) {
    final id = rule['id']?.toString() ?? '';
    final existing = uniqueRules[id];
    if (existing == null) {
      uniqueRules[id] = rule;
    } else {
      uniqueRules[id] = _preferNewerRule(existing, rule);
      merged++;
    }
  }

  final repositories = <Map<String, dynamic>>[];
  final rawRepositories = state['repositories'];
  if (rawRepositories is List) {
    for (final item in rawRepositories) {
      final repository = _stringMap(item);
      if (repository == null) {
        return _TransformResult(raw, retainedLegacyRecords: 1);
      }
      final oldId = repository['id']?.toString().trim() ?? '';
      final url = repository['url']?.toString().trim() ?? '';
      final newId = url.isNotEmpty
          ? 'url:${_stableRuleRepositoryId(url)}'
          : _isCurrentClipboardId(oldId)
          ? oldId
          : 'clipboard:${stableDigest('legacy-rule-repository|$stableIdentityVersion|$oldId|${repository['name'] ?? ''}').substring(0, 32)}';
      final legacyIds = <String>{
        ..._stringValues(repository['legacyIds']),
        if (oldId.isNotEmpty && oldId != newId) oldId,
      };
      repositories.add({
        ...repository,
        'id': newId,
        if (legacyIds.isNotEmpty)
          'legacyIds': legacyIds.toList(growable: false)..sort(),
      });
    }
  }

  return _TransformResult(<String, dynamic>{
    ...state,
    'installedIds': _migrateRuleIds(state['installedIds'], idAliases),
    'enabledIds': _migrateRuleIds(state['enabledIds'], idAliases),
    'customRules': uniqueRules.values.toList(growable: false),
    'repositories': _deduplicateRepositories(repositories),
  }, mergedRecords: merged);
}

String? _migratedRuleId(Map<String, dynamic> rule, String oldId) {
  final name = rule['name']?.toString().trim() ?? '';
  final engine = rule['engine']?.toString().trim() ?? 'native';
  final baseUrl = rule['baseUrl']?.toString().trim() ?? '';
  final searchUrl = rule['searchUrl']?.toString().trim() ?? '';
  if (RegExp(r'^manual:\d+$').hasMatch(oldId)) {
    final contentType = rule['contentType']?.toString().trim() ?? 'anime';
    return stableRuleKey(
      ruleId: 'manual:${name.toLowerCase()}',
      engine: engine,
      sourceRepository: baseUrl,
      contentHash: stableDigest('$contentType|$searchUrl'),
    );
  }
  if (oldId.startsWith('custom:animeko') && engine.startsWith('animeko-')) {
    final factoryId = engine.substring('animeko-'.length);
    final version = rule['version']?.toString() ?? '1.0';
    return stableRuleKey(
      ruleId: 'animeko:$factoryId:${name.toLowerCase()}',
      engine: engine,
      sourceRepository: baseUrl,
      contentHash: stableDigest('$version|$searchUrl'),
    );
  }
  return null;
}

Map<String, dynamic> _preferNewerRule(
  Map<String, dynamic> first,
  Map<String, dynamic> second,
) {
  final firstDate =
      DateTime.tryParse(first['updatedAt']?.toString() ?? '') ??
      DateTime.fromMillisecondsSinceEpoch(0);
  final secondDate =
      DateTime.tryParse(second['updatedAt']?.toString() ?? '') ??
      DateTime.fromMillisecondsSinceEpoch(0);
  final preferred = secondDate.isAfter(firstDate) ? second : first;
  final legacyIds = <String>{
    ..._stringValues(first['legacyIds']),
    ..._stringValues(second['legacyIds']),
  };
  return {
    ...preferred,
    if (legacyIds.isNotEmpty)
      'legacyIds': legacyIds.toList(growable: false)..sort(),
  };
}

List<String> _migrateRuleIds(Object? raw, Map<String, String> aliases) {
  final values = <String>{};
  for (final id in _stringValues(raw)) {
    values.add(aliases[id] ?? id);
  }
  return values.toList(growable: false)..sort();
}

List<Map<String, dynamic>> _deduplicateRepositories(
  List<Map<String, dynamic>> repositories,
) {
  final unique = <String, Map<String, dynamic>>{};
  for (final repository in repositories) {
    final id = repository['id']?.toString() ?? '';
    final existing = unique[id];
    if (existing == null ||
        _repositoryDate(repository).isAfter(_repositoryDate(existing))) {
      unique[id] = repository;
    }
  }
  return unique.values.toList(growable: false);
}

DateTime _repositoryDate(Map<String, dynamic> repository) =>
    DateTime.tryParse(repository['importedAt']?.toString() ?? '')?.toUtc() ??
    DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

bool _isCurrentClipboardId(String id) =>
    RegExp(r'^clipboard:[0-9a-f]{32}$').hasMatch(id);

String _stableRuleRepositoryId(String value) {
  final normalized = value.trim();
  String canonical;
  try {
    canonical = canonicalIdentityUri(normalized);
  } on FormatException {
    canonical = normalized;
  }
  return stableDigest(
    'rule-repository|$stableIdentityVersion|$canonical',
  ).substring(0, 32);
}

_TransformResult _migrateNestedSubjects(Object? raw) {
  var retainedLegacy = 0;

  Object? visit(Object? value) {
    if (value is List) return value.map(visit).toList(growable: false);
    final map = _stringMap(value);
    if (map == null) return value;
    if (_looksLikeSubject(map)) return _migrateSubject(map);
    return <String, dynamic>{
      for (final entry in map.entries) entry.key: visit(entry.value),
    };
  }

  try {
    return _TransformResult(visit(raw));
  } catch (_) {
    retainedLegacy++;
    return _TransformResult(raw, retainedLegacyRecords: retainedLegacy);
  }
}

bool _looksLikeSubject(Map<String, dynamic> map) =>
    map.containsKey('id') &&
    map.containsKey('title') &&
    map.containsKey('source') &&
    (map.containsKey('totalEpisodes') || map.containsKey('categories'));

Map<String, dynamic> _migrateSubject(Map<String, dynamic> subject) {
  final source = subject['source']?.toString() ?? 'bangumi';
  final id = subject['id'] ?? 0;
  final explicit = subject['stableKey']?.toString().trim() ?? '';
  final stableKey = explicit.isNotEmpty
      ? explicit
      : stableSubjectKey(source: source, identifier: id);
  final legacyIds = <int>{
    ..._intValues(subject['legacyIds']),
    if (subject['legacyId'] != null) _asInt(subject['legacyId']),
    _asInt(id),
  }..removeWhere((value) => value == 0);
  final sortedLegacyIds = legacyIds.toList(growable: false)..sort();
  return <String, dynamic>{
    ...subject,
    'stableKey': stableKey,
    if (sortedLegacyIds.isNotEmpty) 'legacyId': sortedLegacyIds.first,
    if (sortedLegacyIds.isNotEmpty) 'legacyIds': sortedLegacyIds,
  };
}

Map<String, dynamic> _mergeSubjectAliases(
  Map<String, dynamic> first,
  Map<String, dynamic> second,
) {
  final legacyIds = <int>{
    ..._intValues(first['legacyIds']),
    ..._intValues(second['legacyIds']),
    _asInt(first['id']),
    _asInt(second['id']),
  }..removeWhere((value) => value == 0);
  final sorted = legacyIds.toList(growable: false)..sort();
  return <String, dynamic>{
    ...first,
    if (sorted.isNotEmpty) 'legacyId': sorted.first,
    if (sorted.isNotEmpty) 'legacyIds': sorted,
  };
}

Map<String, dynamic> _migrateEpisode(
  Map<String, dynamic> episode,
  String subjectKey,
) {
  final explicit = episode['stableKey']?.toString().trim() ?? '';
  final stableKey = explicit.isNotEmpty
      ? explicit
      : stableEpisodeKey(
          subjectKey: subjectKey,
          normalizedNumber: episode['number'] ?? 0,
        );
  return <String, dynamic>{
    ...episode,
    'stableKey': stableKey,
    if (episode['legacyId'] == null) 'legacyId': _asInt(episode['id']),
  };
}

Map<String, dynamic>? _stringMap(Object? raw) {
  if (raw is! Map) return null;
  return <String, dynamic>{
    for (final entry in raw.entries) entry.key.toString(): entry.value,
  };
}

Iterable<String> _stringValues(Object? raw) sync* {
  if (raw is! Iterable) return;
  for (final value in raw) {
    final text = value.toString().trim();
    if (text.isNotEmpty) yield text;
  }
}

Iterable<int> _intValues(Object? raw) sync* {
  if (raw is! Iterable) return;
  for (final value in raw) {
    final parsed = value is num
        ? value.toInt()
        : int.tryParse(value.toString());
    if (parsed != null) yield parsed;
  }
}

int _asInt(Object? value) => switch (value) {
  final int number => number,
  final num number => number.toInt(),
  _ => int.tryParse(value?.toString() ?? '') ?? 0,
};

bool _deepEquivalent(Object? first, Object? second) =>
    _canonicalJson(first) == _canonicalJson(second);

String _canonicalJson(Object? value) => jsonEncode(_canonicalValue(value));

Object? _canonicalValue(Object? value) {
  if (value is Map) {
    final entries =
        value.entries
            .map((entry) => MapEntry(entry.key.toString(), entry.value))
            .toList(growable: false)
          ..sort((left, right) => left.key.compareTo(right.key));
    return <String, Object?>{
      for (final entry in entries) entry.key: _canonicalValue(entry.value),
    };
  }
  if (value is Iterable) {
    return value.map(_canonicalValue).toList(growable: false);
  }
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  return value.toString();
}

class _MigrationWorkItem {
  const _MigrationWorkItem({
    required this.box,
    required this.key,
    required this.storageKey,
    required this.transform,
  });

  final Box<dynamic> box;
  final Object key;
  final String storageKey;
  final _TransformResult Function(Object?) transform;
}

class _TransformResult {
  const _TransformResult(
    this.value, {
    this.mergedRecords = 0,
    this.retainedLegacyRecords = 0,
  });

  final Object? value;
  final int mergedRecords;
  final int retainedLegacyRecords;
}
