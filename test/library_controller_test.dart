import 'dart:async';

import 'package:anime/src/accounts/account_controller.dart';
import 'package:anime/src/accounts/local_account_repository.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/library/library_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'concurrent mutations serialize and remain isolated by account',
    () async {
      final storage = _MemoryLibraryStorage();
      final controller = _controller(storage);
      addTearDown(controller.dispose);

      await controller.loadForAccount(
        accountId: 'account-a',
        contextVersion: 1,
      );
      final added = controller.toggleFavorite(_subject);
      final removed = controller.toggleFavorite(_subject);
      expect(await added, isTrue);
      expect(await removed, isFalse);
      expect(controller.snapshot.favorites, isEmpty);

      await controller.loadForAccount(
        accountId: 'account-b',
        contextVersion: 2,
      );
      expect(controller.snapshot.favorites, isEmpty);
      expect(await controller.toggleFavorite(_subject), isTrue);
      expect(storage.entriesFor('account-a', 'favorites'), isEmpty);
      expect(storage.entriesFor('account-b', 'favorites'), hasLength(1));
    },
  );

  test(
    'an in-flight write keeps its captured scope during account loading',
    () async {
      final storage = _MemoryLibraryStorage();
      final controller = _controller(storage);
      addTearDown(() {
        storage.releaseWrite();
        controller.dispose();
      });

      await controller.loadForAccount(
        accountId: 'account-a',
        contextVersion: 1,
      );
      storage.blockNextWrite();
      final mutation = controller.toggleFollowing(_subject);
      await _waitUntil(() => storage.blockedKey != null);
      expect(storage.blockedKey, 'account.account-a.following');

      final load = controller.loadForAccount(
        accountId: 'account-b',
        contextVersion: 2,
      );
      await _flushAsync();
      storage.releaseWrite();

      await expectLater(mutation, throwsA(isA<AccountException>()));
      await load;
      expect(storage.entriesFor('account-a', 'following'), hasLength(1));
      expect(storage.entriesFor('account-b', 'following'), isEmpty);
      expect(controller.snapshot.following, isEmpty);
    },
  );

  test(
    'history progress persists and near-complete playback resets to zero',
    () async {
      final storage = _MemoryLibraryStorage();
      final syncContexts = <LibraryMutationContext>[];
      final controller = LibraryController(
        storage: storage,
        publishSnapshot: (_) {},
        syncHistory: (context, _, _) async => syncContexts.add(context),
        now: () => DateTime.utc(2026, 8, 2, 12),
      );
      addTearDown(controller.dispose);

      await controller.loadForAccount(
        accountId: 'account-a',
        contextVersion: 7,
      );
      expect(await controller.addHistory(_subject, _episode), isTrue);
      await controller.updatePlaybackProgress(
        _subject,
        _episode,
        position: const Duration(seconds: 120),
        duration: const Duration(seconds: 600),
      );
      expect(controller.snapshot.history.single.positionSeconds, 120);

      await controller.updatePlaybackProgress(
        _subject,
        _episode,
        position: const Duration(seconds: 590),
        duration: const Duration(seconds: 600),
      );
      expect(controller.snapshot.history.single.positionSeconds, 0);
      expect(syncContexts.single.accountId, 'account-a');
      expect(syncContexts.single.contextVersion, 7);
      expect(
        LibraryEntry.fromJson(
          storage.entriesFor('account-a', 'history').single,
        ).positionSeconds,
        0,
      );
    },
  );

  test(
    'startup skips malformed rows without rewriting persisted data',
    () async {
      final storage = _MemoryLibraryStorage();
      final key = AccountController.libraryKeyFor('account-a', 'favorites');
      final malformed = <String, Object?>{'unexpected': true};
      storage.values[key] = [malformed, _entry.toJson()];
      final controller = _controller(storage);
      addTearDown(controller.dispose);

      final snapshot = await controller.loadForAccount(
        accountId: 'account-a',
        contextVersion: 1,
      );
      expect(snapshot.favorites, hasLength(1));
      expect(snapshot.favorites.single.subject.title, _subject.title);
      expect(storage.writeKeys, isEmpty);
      expect((storage.values[key] as List).first, malformed);
    },
  );
}

LibraryController _controller(_MemoryLibraryStorage storage) =>
    LibraryController(
      storage: storage,
      publishSnapshot: (_) {},
      syncHistory: (_, _, _) async {},
      now: () => DateTime.utc(2026, 8, 2, 12),
    );

final class _MemoryLibraryStorage implements LibraryStorage {
  final Map<String, Object?> values = {};
  final List<String> writeKeys = [];
  Completer<void>? _nextGate;
  Completer<void>? _activeGate;
  String? blockedKey;

  @override
  Object? get(String key) => values[key];

  @override
  Future<void> put(String key, Object? value) async {
    writeKeys.add(key);
    final gate = _nextGate;
    if (gate != null) {
      _nextGate = null;
      _activeGate = gate;
      blockedKey = key;
      await gate.future;
      _activeGate = null;
      blockedKey = null;
    }
    values[key] = value;
  }

  void blockNextWrite() => _nextGate = Completer<void>();

  void releaseWrite() {
    final gate = _activeGate ?? _nextGate;
    if (gate != null && !gate.isCompleted) gate.complete();
    _nextGate = null;
  }

  List<Map<String, dynamic>> entriesFor(String accountId, String kind) {
    final value = values[AccountController.libraryKeyFor(accountId, kind)];
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map((item) => item.cast<String, dynamic>())
        .toList(growable: false);
  }
}

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('condition was not reached');
}

Future<void> _flushAsync() async {
  for (var attempt = 0; attempt < 10; attempt++) {
    await Future<void>.delayed(Duration.zero);
  }
}

const _subject = AnimeSubject(
  id: 1,
  title: '测试动画',
  originalTitle: 'Test Anime',
  summary: 'summary',
  coverUrl: null,
  bannerUrl: null,
  date: '2026-01-01',
  platform: 'TV',
  language: '日语',
  region: '日本',
  status: '连载中',
  categories: [],
  tags: [],
  totalEpisodes: 12,
);

const _episode = AnimeEpisode(
  id: 101,
  subjectId: 1,
  number: 1,
  title: '第一集',
  airdate: '2026-01-01',
  duration: '24:00',
  description: '',
);

final _entry = LibraryEntry(
  subject: _subject,
  updatedAt: DateTime.utc(2026, 8, 1),
);
