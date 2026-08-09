import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

/// Recent search terms, isolated per local account (guests share one slot).
class SearchHistoryStore {
  static const boxName = 'anime.search.v1';
  static const maxEntries = 10;

  Future<Box<dynamic>> _openBox() async {
    if (Hive.isBoxOpen(boxName)) return Hive.box<dynamic>(boxName);
    return Hive.openBox<dynamic>(boxName);
  }

  String _key(String accountId) {
    final id = accountId.trim();
    return id.isEmpty ? 'guest' : 'account.$id';
  }

  List<String> _terms(Object? raw) {
    if (raw is! List) return const [];
    final seen = <String>{};
    return raw
        .map((item) => item.toString().trim())
        .where((item) => item.isNotEmpty && seen.add(item))
        .take(maxEntries)
        .toList(growable: false);
  }

  /// History is a convenience; storage trouble (uninitialized Hive in tests,
  /// corrupt box, denied disk) silently degrades to an empty list.
  Future<List<String>> load(String accountId) async {
    try {
      final box = await _openBox();
      return List.unmodifiable(_terms(box.get(_key(accountId))));
    } catch (_) {
      return const [];
    }
  }

  Future<List<String>> add(String accountId, String term) async {
    final normalized = term.trim();
    if (normalized.isEmpty) return load(accountId);
    try {
      final box = await _openBox();
      final current = await load(accountId);
      final next = <String>[
        normalized,
        ...current.where((item) => item != normalized),
      ].take(maxEntries).toList(growable: false);
      await box.put(_key(accountId), next);
      return List.unmodifiable(next);
    } catch (_) {
      return const [];
    }
  }

  Future<List<String>> remove(String accountId, String term) async {
    try {
      final box = await _openBox();
      final next = (await load(
        accountId,
      )).where((item) => item != term).toList(growable: false);
      await box.put(_key(accountId), next);
      return List.unmodifiable(next);
    } catch (_) {
      return const [];
    }
  }

  Future<void> clear(String accountId) async {
    try {
      final box = await _openBox();
      await box.delete(_key(accountId));
    } catch (_) {}
  }

  /// Moves the guest search terms into the first registered account.
  ///
  /// The target write happens before deleting the guest key, making the
  /// operation safe to retry after an interrupted registration.
  Future<void> migrateGuestToAccount(String accountId) async {
    final normalizedAccountId = accountId.trim();
    if (normalizedAccountId.isEmpty) {
      throw ArgumentError.value(accountId, 'accountId', 'must not be empty');
    }
    final box = await _openBox();
    final guestTerms = _terms(box.get(_key('')));
    if (guestTerms.isEmpty) {
      await box.delete(_key(''));
      return;
    }
    final accountKey = _key(normalizedAccountId);
    final accountTerms = _terms(box.get(accountKey));
    final seen = <String>{};
    final merged = <String>[
      ...accountTerms,
      ...guestTerms,
    ].where((item) => seen.add(item)).take(maxEntries).toList(growable: false);
    await box.put(accountKey, merged);
    await box.delete(_key(''));
  }

  /// Removes search history owned by a deleted account.
  ///
  /// Unlike the UI convenience [clear], failures are allowed to propagate so
  /// account-deletion recovery can retry the cleanup on the next startup.
  Future<void> clearAccount(String accountId) async {
    final normalizedAccountId = accountId.trim();
    if (normalizedAccountId.isEmpty) {
      throw ArgumentError.value(accountId, 'accountId', 'must not be empty');
    }
    final box = await _openBox();
    await box.delete(_key(normalizedAccountId));
  }
}

final searchHistoryStoreProvider = Provider<SearchHistoryStore>(
  (ref) => SearchHistoryStore(),
);
