import '../domain/anime_models.dart';
import '../domain/subject_content_type.dart';

/// Orders search results by how precisely they match the query and optionally
/// restricts them to one content type. Exact title hits come first, then
/// prefix hits, substring hits (earlier is better), and finally loose
/// in-order character matches; everything else keeps the provider order at
/// the bottom. Sorting is stable so equally-scored rows never shuffle.
List<AnimeSubject> rankSearchSubjects(
  String keyword,
  Iterable<AnimeSubject> subjects, {
  SubjectContentType? scope,
}) {
  final query = _fold(keyword);
  final filtered = scope == null
      ? subjects.toList(growable: false)
      : subjects
            .where((subject) => subjectContentTypeOf(subject) == scope)
            .toList(growable: false);
  if (query.isEmpty) return List.unmodifiable(filtered);

  final indexed = filtered.indexed.toList(growable: false)
    ..sort((left, right) {
      final score = _score(query, right.$2).compareTo(_score(query, left.$2));
      if (score != 0) return score;
      return left.$1.compareTo(right.$1);
    });
  return List.unmodifiable(indexed.map((item) => item.$2));
}

int searchMatchScore(String keyword, AnimeSubject subject) {
  return _score(_fold(keyword), subject);
}

int _score(String query, AnimeSubject subject) {
  if (query.isEmpty) return 0;
  final title = _fold(subject.title);
  final original = _fold(subject.originalTitle);

  if (title == query) return 1000;
  if (title.startsWith(query)) return 850;
  if (original == query) return 800;
  if (original.startsWith(query)) return 700;

  final titleAt = title.indexOf(query);
  if (titleAt >= 0) return 600 - titleAt.clamp(0, 80);
  final originalAt = original.indexOf(query);
  if (originalAt >= 0) return 450 - originalAt.clamp(0, 80);

  if (_containsInOrder(title, query)) return 180;
  if (_containsInOrder(original, query)) return 150;
  return 0;
}

/// Case folding plus full-width to half-width so "ＦＡＴＥ" matches "fate"
/// and spacing differences never break a hit.
String _fold(String value) {
  final buffer = StringBuffer();
  for (final rune in value.trim().toLowerCase().runes) {
    if (rune == 0x3000) {
      continue;
    }
    if (rune >= 0xFF01 && rune <= 0xFF5E) {
      buffer.writeCharCode(rune - 0xFEE0);
      continue;
    }
    if (rune == 0x20 || rune == 0x09) continue;
    buffer.writeCharCode(rune);
  }
  return buffer.toString().toLowerCase();
}

bool _containsInOrder(String haystack, String needle) {
  if (needle.isEmpty || haystack.isEmpty) return false;
  var index = 0;
  final targets = needle.runes.toList(growable: false);
  for (final rune in haystack.runes) {
    if (rune == targets[index]) {
      index += 1;
      if (index == targets.length) return true;
    }
  }
  return false;
}
