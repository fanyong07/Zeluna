import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import 'package:anime/src/core/identity/local_identity_migration.dart';
import 'package:anime/src/core/identity/stable_identity.dart';
import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/rules/rule_plugin_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Box<dynamic> settings;
  late Box<dynamic> library;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('stable-id-migration-');
    Hive.init(root.path);
    settings = await Hive.openBox<dynamic>('anime.settings.v2');
    library = await Hive.openBox<dynamic>('anime.library.v2');
  });

  tearDown(() async {
    await Hive.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    'migrates scoped records, merges duplicates and preserves files',
    () async {
      final older = _entry(
        subjectId: 101,
        episodeId: 1001,
        updatedAt: '2026-01-01T00:00:00Z',
        positionSeconds: 120,
      );
      final newer = _entry(
        subjectId: 202,
        episodeId: 2002,
        updatedAt: '2026-02-01T00:00:00Z',
        positionSeconds: 240,
      );
      await library.put('history', [older, newer]);
      await library.put('favorites', [older, newer]);
      await library.put('account.a.history', [older]);
      await library.put('account.b.history', [newer]);
      final olderTask =
          _task(
              id: 'old-task-a',
              entry: older,
              status: 'paused',
              temporaryPath: r'E:\downloads\episode.part',
            )
            ..['legacyId'] = 'z-alias'
            ..['legacyIds'] = ['z-alias', 'a-alias'];
      await library.put('offlineTasks', [
        olderTask,
        _task(
          id: 'old-task-b',
          entry: newer,
          status: 'completed',
          localPath: r'E:\downloads\episode.mp4',
        ),
      ]);
      await settings.put('rulePlugins', {
        'installedIds': ['manual:123456'],
        'enabledIds': ['manual:123456'],
        'customRules': [
          {
            'id': 'manual:123456',
            'name': '测试规则',
            'version': '1.0',
            'engine': 'native',
            'contentType': 'anime',
            'baseUrl': 'HTTPS://Rules.Example.test:443/',
            'searchUrl': 'https://rules.example.test/search?q={keyword}',
            'updatedAt': '2026-01-02T00:00:00Z',
          },
        ],
        'repositories': [
          {
            'id': 'url:1234abcd',
            'name': '测试仓库',
            'url': 'HTTPS://Rules.Example.test:443/list.json#fragment',
            'importedAt': '2026-01-02T00:00:00Z',
            'ruleCount': 1,
          },
        ],
      });

      final report = await LocalIdentityMigration(
        settings: settings,
        library: library,
      ).run();

      expect(report.changedKeys, greaterThanOrEqualTo(6));
      expect(report.mergedRecords, 3);
      final marker = _map(settings.get(LocalIdentityMigration.markerKey));
      expect(marker['status'], 'completed');
      expect(marker['version'], LocalIdentityMigration.schemaVersion);

      final history = (library.get('history') as List).cast<Map>();
      expect(history, hasLength(1));
      expect(history.single['positionSeconds'], 240);
      final historySubject = _map(history.single['subject']);
      expect(
        historySubject['stableKey'],
        stableSubjectKey(source: 'archive:stable-item', identifier: 202),
      );
      expect((historySubject['legacyIds'] as List).toSet(), {101, 202});

      expect((library.get('favorites') as List), hasLength(1));
      expect((library.get('account.a.history') as List), hasLength(1));
      expect((library.get('account.b.history') as List), hasLength(1));

      final tasks = (library.get('offlineTasks') as List).cast<Map>();
      expect(tasks, hasLength(1));
      final task = _map(tasks.single);
      expect(task['id'], startsWith('download:v1:'));
      expect(task['version'], 3);
      expect(task['status'], 'completed');
      expect(task['localPath'], r'E:\downloads\episode.mp4');
      expect(task['temporaryPath'], r'E:\downloads\episode.part');
      expect(task['legacyId'], 'a-alias');
      expect((task['legacyIds'] as List).toSet(), {
        'a-alias',
        'z-alias',
        'old-task-a',
        'old-task-b',
      });
      expect(task['url'], isNull);
      expect(task['headers'], isEmpty);

      final ruleState = _map(settings.get('rulePlugins'));
      final rules = (ruleState['customRules'] as List).cast<Map>();
      final stableRuleId = rules.single['id'].toString();
      expect(stableRuleId, startsWith('rule:v1:'));
      expect(ruleState['installedIds'], [stableRuleId]);
      expect(ruleState['enabledIds'], [stableRuleId]);
      expect(rules.single['legacyIds'], contains('manual:123456'));
      final restoredRuleState = RulePluginState.fromJson(ruleState);
      final restoredRules = RulePluginRepository(
        extraRules: restoredRuleState.customRules,
      );
      expect(restoredRules.byId('manual:123456')?.id, stableRuleId);
      final repositories = (ruleState['repositories'] as List).cast<Map>();
      expect(repositories.single['id'], matches(RegExp(r'^url:[0-9a-f]{32}$')));
      expect(repositories.single['legacyIds'], contains('url:1234abcd'));

      final snapshot = _boxSnapshot(settings, library);
      final repeated = await LocalIdentityMigration(
        settings: settings,
        library: library,
      ).run();
      expect(repeated.alreadyCompleted, isTrue);
      expect(_boxSnapshot(settings, library), snapshot);
    },
  );

  test(
    'resumes after interruption without clearing or duplicating data',
    () async {
      final entry = _entry(
        subjectId: 303,
        episodeId: 3003,
        updatedAt: '2026-03-01T00:00:00Z',
        positionSeconds: 360,
      );
      await library.put('favorites', [entry]);
      await library.put('history', [entry]);

      var interrupted = false;
      await expectLater(
        LocalIdentityMigration(settings: settings, library: library).run(
          checkpoint: (key) {
            if (!interrupted) {
              interrupted = true;
              throw StateError('simulated interruption at $key');
            }
          },
        ),
        throwsStateError,
      );
      expect(
        _map(settings.get(LocalIdentityMigration.markerKey))['status'],
        'in_progress',
      );
      expect(
        _map(
          ((library.get('favorites') as List).single as Map)['subject'],
        )['stableKey'],
        isNotEmpty,
      );

      final resumed = await LocalIdentityMigration(
        settings: settings,
        library: library,
      ).run();
      expect(resumed.alreadyCompleted, isFalse);
      expect(
        _map(settings.get(LocalIdentityMigration.markerKey))['status'],
        'completed',
      );
      expect((library.get('favorites') as List), hasLength(1));
      expect((library.get('history') as List), hasLength(1));
    },
  );

  test('retains an unconvertible key byte-for-byte', () async {
    final original = [
      _entry(
        subjectId: 404,
        episodeId: 4004,
        updatedAt: '2026-04-01T00:00:00Z',
        positionSeconds: 0,
      ),
      'opaque-legacy-record',
    ];
    await library.put('history', original);

    final report = await LocalIdentityMigration(
      settings: settings,
      library: library,
    ).run();

    expect(report.retainedLegacyRecords, 1);
    expect(report.failedKeys, contains('library:history'));
    expect(jsonEncode(library.get('history')), jsonEncode(original));
  });

  test('migrates position-dependent Animeko rule ids', () async {
    const oldId = 'custom:animeko:0123456789ab';
    await settings.put('rulePlugins', {
      'installedIds': [oldId],
      'enabledIds': [oldId],
      'customRules': [
        {
          'id': oldId,
          'name': '在线源',
          'version': '2',
          'engine': 'animeko-web-selector',
          'contentType': 'anime',
          'baseUrl': 'https://example.test',
          'searchUrl': 'https://example.test/search?q={keyword}',
        },
      ],
      'repositories': <Object?>[],
    });

    await LocalIdentityMigration(settings: settings, library: library).run();

    final state = _map(settings.get('rulePlugins'));
    final rule = _map((state['customRules'] as List).single);
    final expectedId = stableRuleKey(
      ruleId: 'animeko:web-selector:在线源',
      engine: 'animeko-web-selector',
      sourceRepository: 'https://example.test',
      contentHash: stableDigest('2|https://example.test/search?q={keyword}'),
    );
    expect(rule['id'], expectedId);
    expect(rule['legacyIds'], contains(oldId));
    expect(state['installedIds'], [expectedId]);
    expect(state['enabledIds'], [expectedId]);
  });

  test('retains a malformed rule state byte-for-byte', () async {
    final original = {
      'installedIds': ['manual:1'],
      'enabledIds': ['manual:1'],
      'customRules': 'opaque-legacy-rules',
      'repositories': <Object?>[],
    };
    await settings.put('rulePlugins', original);

    final report = await LocalIdentityMigration(
      settings: settings,
      library: library,
    ).run();

    expect(report.retainedLegacyRecords, 1);
    expect(report.failedKeys, contains('settings:rulePlugins'));
    expect(jsonEncode(settings.get('rulePlugins')), jsonEncode(original));
  });
}

Map<String, dynamic> _entry({
  required int subjectId,
  required int episodeId,
  required String updatedAt,
  required int positionSeconds,
}) {
  return {
    'subject': {
      'id': subjectId,
      'title': '同一作品',
      'originalTitle': 'Same Subject',
      'summary': '',
      'coverUrl': null,
      'bannerUrl': null,
      'date': '2026-01-01',
      'platform': 'TV',
      'language': '日语',
      'region': '日本',
      'status': '',
      'categories': <Object?>[],
      'tags': <Object?>[],
      'totalEpisodes': 12,
      'source': 'archive:stable-item',
    },
    'episode': {
      'id': episodeId,
      'subjectId': subjectId,
      'number': 1,
      'title': '第一集',
      'airdate': null,
      'duration': '',
      'description': '',
      'thumbnailUrl': null,
    },
    'updatedAt': updatedAt,
    'note': '播放到第一集',
    'positionSeconds': positionSeconds,
    'durationSeconds': 1200,
  };
}

Map<String, dynamic> _task({
  required String id,
  required Map<String, dynamic> entry,
  required String status,
  String? temporaryPath,
  String? localPath,
}) {
  return {
    'version': 2,
    'id': id,
    'subject': entry['subject'],
    'episode': entry['episode'],
    'createdAt': entry['updatedAt'],
    'updatedAt': entry['updatedAt'],
    'status': status,
    'lineId': 'legacy-line',
    'providerName': '旧线路',
    'format': 'MP4',
    'url': 'https://media.example.test/video.mp4?sample=value',
    'headers': {'X-Sample': 'value'},
    'downloadedBytes': status == 'completed' ? 100 : 50,
    'totalBytes': 100,
    'temporaryPath': temporaryPath,
    'localPath': localPath,
    'etag': null,
    'lastModified': null,
    'completedUnits': status == 'completed' ? 1 : 0,
    'totalUnits': 1,
    'message': status,
  };
}

Map<String, dynamic> _map(Object? value) =>
    (value as Map).cast<String, dynamic>();

String _boxSnapshot(Box<dynamic> settings, Box<dynamic> library) {
  Object? boxValue(Box<dynamic> box) => {
    for (final key in box.keys) key.toString(): box.get(key),
  };
  return jsonEncode({
    'settings': boxValue(settings),
    'library': boxValue(library),
  });
}
