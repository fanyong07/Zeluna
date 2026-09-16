import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anime/src/player/subtitles/subtitle_document.dart';
import 'package:anime/src/player/subtitles/subtitle_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('identical bytes keep language and file metadata isolated', () async {
    final store = SubtitleStore();
    final bytes = Uint8List.fromList(
      utf8.encode('1\n00:00:01,000 --> 00:00:03,000\nHello / こんにちは'),
    );
    final en = parseSubtitle(bytes, 'show.en.srt', 'en');
    final ja = parseSubtitle(bytes, 'show.ja.srt', 'ja');
    final renamed = parseSubtitle(bytes, 'other.en.srt', 'en');
    await store.bindDocument('ep', en);
    await store.rememberSource('test', 'entry', en);
    await store.bindDocument('ep', ja);
    await store.bindDocument('other', renamed);
    expect(store.documentFor('ep', 'en')?.language, 'en');
    expect(store.documentFor('ep', 'en')?.fileName, 'show.en.srt');
    expect(store.documentFor('ep', 'ja')?.language, 'ja');
    expect(store.documentFor('other', 'en')?.fileName, 'other.en.srt');
    expect(
      store.sourceDocument('test', 'entry', 'show.en.srt', 'en')?.language,
      'en',
    );
    expect(store.sourceDocument('test', 'entry', 'show.en.srt', 'ja'), isNull);
  });
  test(
    'real Hive storage isolates accounts and revoked handles cannot recreate deleted data',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'zeluna-subtitles-store-',
      );
      Hive.init(directory.path);
      addTearDown(() async {
        await Hive.close();
        // Explicitly created isolated test directory only.
        await directory.delete(recursive: true);
      });
      final doc = parseSubtitle(
        Uint8List.fromList(
          utf8.encode('1\n00:00:01,000 --> 00:00:03,000\nhello'),
        ),
        '1.srt',
        'en',
      );
      final a = await SubtitleStore.open('test-a');
      final b = await SubtitleStore.open('test-b');
      await a.bindDocument('ep', doc);
      await b.bindDocument('ep', doc);
      expect(
        (await SubtitleStore.open('test-a')).documentFor('ep', 'en')?.fileName,
        '1.srt',
      );
      await SubtitleStore.clearAccount('test-a');
      await a.bindDocument(
        'other',
        doc,
      ); // A late operation from the old player.
      final deleted = await SubtitleStore.open('test-a');
      expect(deleted.documentFor('ep', 'en'), isNull);
      expect(deleted.documentFor('other', 'en'), isNull);
      expect(
        (await SubtitleStore.open('test-b')).documentFor('ep', 'en'),
        isNotNull,
      );
      expect((await SubtitleStore.open(null)).documentFor('ep', 'en'), isNull);
      await deleted.bindDocument('new', doc);
      expect(
        (await SubtitleStore.open('test-a')).documentFor('new', 'en'),
        isNotNull,
      );
    },
  );
}
