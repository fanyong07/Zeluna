import 'package:hive_ce_flutter/hive_flutter.dart';

abstract interface class AppUpdateStore {
  Future<Map<String, dynamic>> read();
  Future<void> write(Map<String, dynamic> value);
}

/// Device-level preferences, deliberately separate from account credentials and
/// watched-content state. Only a release manifest and an app-private path persist.
class HiveAppUpdateStore implements AppUpdateStore {
  Future<Box<dynamic>>? _box;

  Future<Box<dynamic>> get _ready async {
    final opening = _box ??= Hive.openBox<dynamic>('zeluna_app_updates');
    try {
      return await opening;
    } catch (_) {
      // A transient storage/open failure must not poison this instance forever.
      // All callers of the same failed opening observe it; the next call retries.
      if (identical(_box, opening)) _box = null;
      rethrow;
    }
  }

  @override
  Future<Map<String, dynamic>> read() async {
    final value = (await _ready).get('state');
    return value is Map ? _normalize(value) as Map<String, dynamic> : {};
  }

  @override
  Future<void> write(Map<String, dynamic> value) async {
    final snapshot = _normalize(value) as Map<String, dynamic>;
    await (await _ready).put('state', snapshot);
  }

  // Hive reads every map as Map<dynamic, dynamic>, including nested APK data.
  // Normalize recursively before strict manifest parsing; never stringify keys
  // or coerce scalar values that would weaken the model's type validation.
  static dynamic _normalize(dynamic value, [int depth = 0]) {
    if (depth > 32) throw const FormatException('Invalid update storage data.');
    if (value is Map) {
      final result = <String, dynamic>{};
      for (final entry in value.entries) {
        if (entry.key is! String) {
          throw const FormatException('Invalid update storage data.');
        }
        result[entry.key as String] = _normalize(entry.value, depth + 1);
      }
      return result;
    }
    if (value is List) {
      return value.map((entry) => _normalize(entry, depth + 1)).toList();
    }
    if (value == null ||
        value is String ||
        value is bool ||
        value is int ||
        (value is double && value.isFinite)) {
      return value;
    }
    throw const FormatException('Invalid update storage data.');
  }
}
