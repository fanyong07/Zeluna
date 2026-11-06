import 'dart:io';

import 'package:anime/src/updates/app_update_models.dart';
import 'package:anime/src/updates/app_update_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('zeluna-update-store-test-');
    Hive.init(root.path);
  });

  tearDown(() async {
    await Hive.close();
    // This fixture exclusively owns the temporary directory returned above.
    await root.delete(recursive: true);
  });

  test('real Hive reopen restores strict nested release metadata', () async {
    final release = _release();
    final original = HiveAppUpdateStore();
    await original.write({
      'automaticChecks': true,
      'lastChecked': '2026-11-07T00:00:00.000Z',
      'pending': {
        'path': '/private/cache/app_updates/app-88-${release.sha256}.apk',
        'release': release.toJson(),
      },
    });
    await Hive.close();
    Hive.init(root.path);

    // Confirm this test crossed Hive serialization, rather than reading its
    // original in-memory generic maps as the controller's fake store does.
    final diskBox = await Hive.openBox<dynamic>('zeluna_app_updates');
    final raw = diskBox.get('state') as Map;
    final rawApk = ((raw['pending'] as Map)['release'] as Map)['apk'];
    expect(rawApk, isA<Map<dynamic, dynamic>>());
    expect(rawApk is Map<String, dynamic>, isFalse);

    final restored = await HiveAppUpdateStore().read();
    expect(restored['automaticChecks'], isTrue);
    expect(restored['lastChecked'], '2026-11-07T00:00:00.000Z');
    final pending = restored['pending'] as Map<String, dynamic>;
    final releaseMap = pending['release'] as Map<String, dynamic>;
    expect(releaseMap['apk'], isA<Map<String, dynamic>>());
    final parsed = UpdateRelease.fromJson(releaseMap);
    expect(parsed.toJson(), release.toJson());
    expect(parsed.buildNumber, 88);
    expect(parsed.abis, ['arm64-v8a', 'armeabi-v7a']);
    expect(parsed.minSdk, 24);
    expect(pending['path'], contains('app-88-'));
  });

  test(
    'normalizes map elements in lists without coercing scalar types',
    () async {
      final box = await Hive.openBox<dynamic>('zeluna_app_updates');
      await box.put('state', <dynamic, dynamic>{
        'extra': [
          <dynamic, dynamic>{
            'nested': <dynamic, dynamic>{
              'integer': 88,
              'string': '88',
              'double': 1.5,
              'boolean': true,
              'null': null,
            },
          },
        ],
      });
      await Hive.close();
      Hive.init(root.path);
      final restored = await HiveAppUpdateStore().read();
      final extra = restored['extra'] as List;
      expect(extra.single, isA<Map<String, dynamic>>());
      final nested = (extra.single as Map<String, dynamic>)['nested'];
      expect(nested, isA<Map<String, dynamic>>());
      expect(nested['integer'], isA<int>());
      expect(nested['string'], isA<String>());
      expect(nested['double'], isA<double>());
      expect(nested['boolean'], isTrue);
      expect(nested['null'], isNull);
    },
  );

  test(
    'non-string nested keys fail instead of becoming valid manifest keys',
    () async {
      final box = await Hive.openBox<dynamic>('zeluna_app_updates');
      await box.put('state', {
        'pending': <dynamic, dynamic>{42: 'not a string key'},
      });
      final store = HiveAppUpdateStore();
      await expectLater(store.read(), throwsFormatException);
      await expectLater(
        store.write({
          'pending': <dynamic, dynamic>{42: 'not a string key'},
        }),
        throwsFormatException,
      );
    },
  );

  test('missing or non-map state returns an empty map', () async {
    final store = HiveAppUpdateStore();
    expect(await store.read(), isEmpty);
    final box = Hive.box<dynamic>('zeluna_app_updates');
    await box.put('state', 'malformed');
    expect(await store.read(), isEmpty);
  });

  test('same store retries after a real failed Hive open', () async {
    // A regular file cannot be used as Hive's storage directory.
    final blocked = File(
      '${root.path}${Platform.pathSeparator}not-a-directory',
    );
    await blocked.writeAsString('fixture');
    Hive.init(blocked.path);
    final store = HiveAppUpdateStore();
    await expectLater(store.read(), throwsA(isA<FileSystemException>()));
    Hive.init(root.path);
    await store.write({'automaticChecks': true});
    expect((await store.read())['automaticChecks'], isTrue);
  });

  test('write snapshot is independent of later caller mutations', () async {
    final pending = <String, dynamic>{'path': '/private/original.apk'};
    final data = <String, dynamic>{'pending': pending};
    final store = HiveAppUpdateStore();
    final write = store.write(data);
    pending['path'] = '/private/mutated.apk';
    await write;
    expect((await store.read())['pending']['path'], '/private/original.apk');
  });

  test('over-deep storage trees fail with bounded recursion', () async {
    dynamic nested = 'end';
    for (var i = 0; i < 40; i++) {
      nested = <String, dynamic>{'next': nested};
    }
    await expectLater(
      HiveAppUpdateStore().write({'nested': nested}),
      throwsFormatException,
    );
  });
}

UpdateRelease _release() => UpdateRelease(
  version: '1.3.2',
  buildNumber: 88,
  apkUri: Uri.parse('https://example.com/app.apk'),
  sha256: 'a' * 64,
  bytes: 1234,
  notes: 'Persistent update metadata',
  abis: const ['arm64-v8a', 'armeabi-v7a'],
  minSdk: 24,
);
