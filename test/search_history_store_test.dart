import 'dart:io';

import 'package:anime/src/data/search_history_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'guest migration is retry-safe and account cleanup is isolated',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'search-history-account-lifecycle-',
      );
      Hive.init(root.path);
      addTearDown(() async {
        await Hive.close();
        if (await root.exists()) await root.delete(recursive: true);
      });

      final store = SearchHistoryStore();
      await store.add('', '科幻');
      await store.add('', '冒险');
      await store.add('account-a', '已有关键词');

      await store.migrateGuestToAccount('account-a');
      expect(await store.load(''), isEmpty);
      expect(await store.load('account-a'), ['已有关键词', '冒险', '科幻']);

      await store.migrateGuestToAccount('account-a');
      expect(await store.load('account-a'), ['已有关键词', '冒险', '科幻']);

      await store.add('account-b', '另一个账号');
      await store.clearAccount('account-a');
      expect(await store.load('account-a'), isEmpty);
      expect(await store.load('account-b'), ['另一个账号']);
    },
  );

  test('account lifecycle APIs reject the guest slot', () async {
    final root = await Directory.systemTemp.createTemp(
      'search-history-invalid-account-',
    );
    Hive.init(root.path);
    addTearDown(() async {
      await Hive.close();
      if (await root.exists()) await root.delete(recursive: true);
    });

    final store = SearchHistoryStore();
    await store.add('', 'guest term');
    await store.clear('');
    expect(await store.load(''), isEmpty);
    await expectLater(store.migrateGuestToAccount('  '), throwsArgumentError);
    await expectLater(store.clearAccount(''), throwsArgumentError);
  });
}
