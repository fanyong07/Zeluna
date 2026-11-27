import 'anime_models.dart';

// Only an episode label (not a URL, resolution or arbitrary substring) can
// identify an entry in an unordered list. Explicit numbers outrank position.
final _episodeLabel = RegExp(
  r'(?:第\s*(\d+)\s*[集话話回期]|(?:^|[^a-z])(?:episode|ep|e)\s*(\d+)(?![\d.])|^(?:备用\s*)?(\d+)(?:\s*[集话話回期])?$)',
  caseSensitive: false,
);
final _promoLabel = RegExp(
  r'预告|預告|花絮|(?:^|[^a-z])(?:pv|trailer)(?![a-z])',
  caseSensitive: false,
);
final _specialLabel = RegExp(
  r'番外|特典|特别篇|特別篇|(?:^|[^a-z])(?:sp|ova|oad|special)(?![a-z])',
  caseSensitive: false,
);
final _specialNumberLabel = RegExp(
  r'(?:番外|特典|特别篇|特別篇|(?:^|[^a-z])(?:sp|ova|oad|special))\s*(?:第\s*)?0*(\d+)',
  caseSensitive: false,
);
final _collectionLabel = RegExp('全集|合集|合辑|合輯');
final _seasonAsciiLabel = RegExp(
  r'(?:^|[^a-z])(?:season\s*0*(\d+)|s0*(\d+)(?=\s*e\s*\d|\b))',
  caseSensitive: false,
);
final _seasonChineseLabel = RegExp(r'第\s*([0-9一二三四五六七八九十两兩]+)\s*季');

bool isMainEpisode(AnimeEpisode episode) =>
    episode.number > 0 &&
    !_promoLabel.hasMatch(episode.title) &&
    !_specialLabel.hasMatch(episode.title) &&
    !_collectionLabel.hasMatch(episode.title);

List<T> matchingEpisodes<T>(
  List<T> items,
  AnimeEpisode episode,
  String Function(T) label, {
  int? Function(String)? ruleNumber,
  bool ordered = true,
  bool movie = false,
}) {
  if (items.isEmpty || episode.number < 1) return [];
  final titles = items.map((item) => label(item).trim()).toList();
  final targetIsSpecial = _specialLabel.hasMatch(episode.title);
  final numbers = [
    for (final title in titles)
      _numberInEpisodeLabel(title) ??
          (targetIsSpecial ? _specialNumberInLabel(title) : null) ??
          ruleNumber?.call(title),
  ];
  final seasons = [for (final title in titles) _seasonInEpisodeLabel(title)];
  final targetSeason = (episode.seasonNumber ?? 0) > 0
      ? episode.seasonNumber
      : null;

  bool seasonConflict(int index) =>
      targetSeason != null &&
      seasons[index] != null &&
      seasons[index] != targetSeason;

  bool excludedKind(String title) {
    if (_promoLabel.hasMatch(title) || _collectionLabel.hasMatch(title)) {
      return true;
    }
    if (!targetIsSpecial && _specialLabel.hasMatch(title)) {
      return true;
    }
    return false;
  }

  bool anyExtraOrConflict(int index) =>
      excludedKind(titles[index]) || seasonConflict(index);

  final targets = {
    episode.number,
    if ((episode.seasonEpisodeNumber ?? 0) > 0) episode.seasonEpisodeNumber!,
  };
  for (final target in targets) {
    final hits = [
      for (var i = 0; i < items.length; i++)
        if (!anyExtraOrConflict(i) && numbers[i] == target) items[i],
    ];
    if (hits.isNotEmpty) return hits;
  }
  if (movie &&
      items.length == 1 &&
      episode.number == 1 &&
      numbers.single == null &&
      !_promoLabel.hasMatch(titles.single) &&
      (!_specialLabel.hasMatch(titles.single) || targetIsSpecial) &&
      !seasonConflict(0)) {
    return [items.single];
  }
  // Do not assign positions in a list containing specials, conflicting seasons
  // or labels, or a lone unnumbered entry. Page-wide anchor scans are never
  // ordered lists.
  if (!ordered || items.length < 2) return [];
  for (var i = 0; i < items.length; i++) {
    if (anyExtraOrConflict(i)) return [];
    if (numbers[i] != null && numbers[i] != i + 1) return [];
  }
  for (final target in targets) {
    if (target <= items.length) return [items[target - 1]];
  }
  return [];
}

int? _numberInEpisodeLabel(String title) {
  final match = _episodeLabel.firstMatch(title);
  return match == null ? null : int.tryParse(match[1] ?? match[2] ?? match[3]!);
}

int? _specialNumberInLabel(String title) {
  final match = _specialNumberLabel.firstMatch(title);
  return match == null ? null : int.tryParse(match[1] ?? '');
}

int? _seasonInEpisodeLabel(String title) {
  final ascii = _seasonAsciiLabel.firstMatch(title);
  if (ascii != null) {
    final parsed = int.tryParse(ascii[1] ?? ascii[2] ?? '');
    if (parsed != null && parsed > 0) return parsed;
  }
  final chinese = _seasonChineseLabel.firstMatch(title);
  if (chinese != null) {
    return _parseSeasonOrdinal(chinese[1] ?? '');
  }
  return null;
}

int? _parseSeasonOrdinal(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final digits = int.tryParse(trimmed);
  if (digits != null && digits > 0) return digits;
  const map = <String, int>{
    '一': 1,
    '二': 2,
    '两': 2,
    '兩': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
    '十': 10,
  };
  if (map.containsKey(trimmed)) return map[trimmed];
  if (trimmed.startsWith('十') && trimmed.length == 2) {
    final ones = map[trimmed[1]];
    if (ones != null && ones < 10) return 10 + ones;
  }
  return null;
}
