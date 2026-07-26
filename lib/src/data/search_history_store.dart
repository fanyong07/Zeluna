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

  /// History is a convenience; storage trouble (uninitialized Hive in tests,
  /// corrupt box, denied disk) silently degrades to an empty list.
  Future<List<String>> load(String accountId) async {
    try {
      final box = await _openBox();
      final raw = box.get(_key(accountId));
      if (raw is! List) return const [];
      return List.unmodifiable(
        raw.map((item) => item.toString()).where((item) => item.isNotEmpty),
      );
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
}

final searchHistoryStoreProvider = Provider<SearchHistoryStore>(
  (ref) => SearchHistoryStore(),
);
