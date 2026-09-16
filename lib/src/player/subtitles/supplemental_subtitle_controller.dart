import 'package:flutter/foundation.dart';

import 'subtitle_document.dart';
import 'subtitle_store.dart';

/// Owns only supplementary text. It must never select/disable native tracks.
class SupplementalSubtitleController extends ChangeNotifier {
  SupplementalSubtitleController(this.store);
  final SubtitleStore store;
  String subjectKey = '';
  String episodeKey = '';
  String lineKey = '';
  String language = 'ja';
  bool enabled = false;
  bool bilingual = false;
  bool top = true;
  double fontSize = 22;
  double verticalInset = .08;
  int delayMs = 0;
  SubtitleDocument? document;
  String? sourceMessage;
  int _generation = 0;
  bool _disposed = false;
  int get generation => _generation;
  bool isCurrent(int value) => !_disposed && value == _generation;
  bool get visible => enabled && !bilingual && document != null;

  void bind({
    required String subject,
    required String episode,
    required String line,
    required String originalLanguage,
  }) {
    if (_disposed) return;
    _generation++;
    sourceMessage = null;
    subjectKey = subject;
    episodeKey = episode;
    lineKey = line;
    final prefs = store.preferences(subject);
    language =
        prefs['language'] as String? ??
        suggestedSubtitleLanguage(originalLanguage);
    enabled = prefs['enabled'] == true;
    top = prefs['top'] != false;
    fontSize = ((prefs['fontSize'] as num?)?.toDouble() ?? 22).clamp(14, 36);
    verticalInset = ((prefs['inset'] as num?)?.toDouble() ?? .08).clamp(0, .35);
    bilingual = store.isBilingual(episode, line);
    document = store.documentFor(episode, language);
    delayMs = document == null
        ? 0
        : store.delayFor(episode, line, document!.hash);
    notifyListeners();
  }

  void invalidate() {
    _generation++;
    sourceMessage = null;
    document = null;
  }

  void reportSource(String message, {required int expectedGeneration}) {
    if (!isCurrent(expectedGeneration)) return;
    sourceMessage = message;
    notifyListeners();
  }

  Future<bool> selectDocument(
    SubtitleDocument value, {
    required int expectedGeneration,
  }) async {
    if (!isCurrent(expectedGeneration)) return false;
    await store.bindDocument(episodeKey, value);
    if (!isCurrent(expectedGeneration)) return false;
    document = value;
    sourceMessage = null;
    language = value.language;
    enabled = true;
    bilingual = false;
    delayMs = store.delayFor(episodeKey, lineKey, value.hash);
    await store.setBilingual(episodeKey, lineKey, false);
    if (!isCurrent(expectedGeneration)) return false;
    await _savePreferences();
    if (!isCurrent(expectedGeneration)) return false;
    notifyListeners();
    return true;
  }

  Future<void> setLanguage(String value) async {
    _generation++;
    sourceMessage = null;
    language = value;
    document = store.documentFor(episodeKey, value);
    delayMs = document == null
        ? 0
        : store.delayFor(episodeKey, lineKey, document!.hash);
    notifyListeners();
    await _savePreferences();
  }

  Future<void> setEnabled(bool value) async {
    _generation++;
    enabled = value;
    if (value) bilingual = false;
    notifyListeners();
    final write = store.setBilingual(episodeKey, lineKey, bilingual);
    final prefs = _savePreferences();
    await Future.wait([write, prefs]);
  }

  Future<void> setBilingual(bool value) async {
    _generation++;
    bilingual = value;
    notifyListeners();
    await store.setBilingual(episodeKey, lineKey, value);
  }

  Future<void> adjustDelay(int value) async {
    delayMs = value.clamp(-600000, 600000);
    notifyListeners();
    if (document != null) {
      await store.setDelay(episodeKey, lineKey, document!.hash, delayMs);
    }
  }

  void previewAppearance({bool? atTop, double? size, double? inset}) {
    top = atTop ?? top;
    fontSize = (size ?? fontSize).clamp(14, 36);
    verticalInset = (inset ?? verticalInset).clamp(0, .35);
    notifyListeners();
  }

  Future<void> persistAppearance() => _savePreferences();

  Future<void> setAppearance({bool? atTop, double? size, double? inset}) async {
    previewAppearance(atTop: atTop, size: size, inset: inset);
    await persistAppearance();
  }

  Future<void> clearCache() async {
    _generation++;
    document = null;
    sourceMessage = null;
    enabled = false;
    bilingual = false;
    delayMs = 0;
    notifyListeners();
    await store.clear();
  }

  String textAt(Duration position) =>
      visible ? document!.textAt(position, delayMs: delayMs) : '';
  Future<void> _savePreferences() => store.setPreferences(subjectKey, {
    ...store.preferences(subjectKey),
    'language': language,
    'enabled': enabled,
    'top': top,
    'fontSize': fontSize,
    'inset': verticalInset,
  });
  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
