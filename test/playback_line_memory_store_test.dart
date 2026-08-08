import 'dart:io';

import 'package:anime/src/accounts/account_controller.dart';
import 'package:anime/src/data/playback_line_memory_store.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

void main() {
  late Directory root;
  late Box<dynamic> settings;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('playback-line-memory-');
    Hive.init(root.path);
    settings = await Hive.openBox<dynamic>('settings');
  });

  tearDown(() async {
    await Hive.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    'persists a provider per account and never crosses account scopes',
    () async {
      final store = PlaybackLineMemoryStore(settings);
      final subject = _subject('show-1');
      store.loadForAccount(accountId: 'account-a', contextVersion: 1);
      await store.rememberSuccessfulProvider(
        subject: subject,
        line: _line('provider-a'),
        expectedContextVersion: 1,
      );

      store.loadForAccount(accountId: 'account-b', contextVersion: 2);
      expect(store.preferredProviderFor(subject), isNull);
      store.loadForAccount(accountId: 'account-a', contextVersion: 3);
      expect(store.preferredProviderFor(subject), 'provider-a');
    },
  );

  test(
    'ignores malformed records and keeps only the newest 200 subjects',
    () async {
      final store = PlaybackLineMemoryStore(settings);
      await settings.put(
        AccountController.settingsKeyFor(
          'account-a',
          playbackLineMemorySettingsKey,
        ),
        <String, dynamic>{
          'entries': <Object?>['bad', <String, dynamic>{}],
        },
      );
      store.loadForAccount(accountId: 'account-a', contextVersion: 1);
      expect(store.preferredProviderFor(_subject('show-1')), isNull);

      for (var index = 0; index < 205; index++) {
        await store.rememberSuccessfulProvider(
          subject: _subject('show-$index'),
          line: _line('provider-$index'),
          expectedContextVersion: 1,
        );
      }
      final snapshot = store.debugSnapshot();
      expect((snapshot['entries'] as List).length, 200);
      expect(store.preferredProviderFor(_subject('show-0')), isNull);
      expect(store.preferredProviderFor(_subject('show-204')), 'provider-204');
    },
  );

  test('a late write from the old account scope is discarded', () async {
    final store = PlaybackLineMemoryStore(settings);
    final pending = () {
      store.loadForAccount(accountId: 'account-a', contextVersion: 1);
      return store.rememberSuccessfulProvider(
        subject: _subject('show-1'),
        line: _line('provider-a'),
        expectedContextVersion: 1,
      );
    }();
    store.loadForAccount(accountId: 'account-b', contextVersion: 2);
    await pending;
    expect(
      settings.get(
        AccountController.settingsKeyFor(
          'account-a',
          playbackLineMemorySettingsKey,
        ),
      ),
      isNull,
    );
  });

  test('clearing the setting removes the current account memory', () async {
    final store = PlaybackLineMemoryStore(settings);
    store.loadForAccount(accountId: 'account-a', contextVersion: 1);
    await store.rememberSuccessfulProvider(
      subject: _subject('show-1'),
      line: _line('provider-a'),
      expectedContextVersion: 1,
    );

    await store.clearForCurrentAccount(expectedContextVersion: 1);
    store.loadForAccount(accountId: 'account-a', contextVersion: 2);

    expect(store.preferredProviderFor(_subject('show-1')), isNull);
    expect((store.debugSnapshot()['entries'] as List<Object?>), isEmpty);
  });

  test(
    'does not remember direct, local, or network playback providers',
    () async {
      final store = PlaybackLineMemoryStore(settings);
      final subject = _subject('show-direct');
      store.loadForAccount(accountId: 'account-a', contextVersion: 1);

      for (final provider in ['direct', 'local', 'network', 'offline']) {
        await store.rememberSuccessfulProvider(
          subject: subject,
          line: _line(provider),
          expectedContextVersion: 1,
        );
      }

      expect(store.preferredProviderFor(subject), isNull);
    },
  );
}

AnimeSubject _subject(String stableKey) => AnimeSubject(
  id: stableKey.hashCode,
  title: stableKey,
  originalTitle: stableKey,
  summary: '',
  coverUrl: null,
  bannerUrl: null,
  date: null,
  platform: 'TV',
  language: 'ja',
  region: 'JP',
  status: '',
  categories: const [],
  tags: const [],
  totalEpisodes: 12,
  source: 'bangumi',
  stableKey: stableKey,
);

PlaybackLine _line(String providerId) => PlaybackLine(
  id: providerId,
  episodeId: 1,
  providerId: providerId,
  providerName: providerId,
  title: providerId,
  quality: '1080p',
  format: 'hls',
  url: 'https://cdn.example/$providerId.m3u8',
  available: true,
  serverVerified: true,
);
