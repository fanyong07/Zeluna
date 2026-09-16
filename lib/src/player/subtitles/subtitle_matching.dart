import '../../domain/anime_models.dart';

class SubtitleImportMatch {
  const SubtitleImportMatch(this.episode, this.reason);
  final AnimeEpisode? episode;
  final String reason;
}

/// Suggests a row in the confirmation screen, never commits a binding.
SubtitleImportMatch matchSubtitleFile(
  String fileName,
  List<AnimeEpisode> episodes,
) {
  final stem = fileName.replaceFirst(RegExp(r'\.[^.]+$'), '');
  if (RegExp(
    r'(?:^|[\W_])(sp|ova|oad|special|ncop|nced|op|ed)(?:\d|[\W_]|$)|特别篇|特別篇',
    caseSensitive: false,
  ).hasMatch(stem)) {
    return const SubtitleImportMatch(null, '特别篇或片头片尾，请手动指定分集');
  }
  final season = RegExp(
    r'S(\d{1,2})[ ._-]*E(\d{1,3})(?!\d)',
    caseSensitive: false,
  ).firstMatch(stem);
  if (season != null) {
    final s = int.parse(season[1]!);
    final e = int.parse(season[2]!);
    final hits = episodes
        .where(
          (item) => item.seasonNumber == s && item.seasonEpisodeNumber == e,
        )
        .toList();
    return hits.length == 1
        ? SubtitleImportMatch(hits.single, '季号与季内集号一致，仍需确认作品')
        : const SubtitleImportMatch(null, '作品季号不明确或不一致，请手动指定，不能默认第一季');
  }
  final patterns = [
    RegExp(r'第\s*(\d{1,3})\s*[集话話]'),
    RegExp(r'(?:^|[\W_])EP?\s*(\d{1,3})(?!\d)', caseSensitive: false),
    RegExp(
      r'(?:^|[\[\s_.-])(\d{1,3})(?:v\d)?(?=$|[\]\s_.-])',
      caseSensitive: false,
    ),
  ];
  final numbers = <int>{};
  for (final pattern in patterns) {
    numbers.addAll(pattern.allMatches(stem).map((m) => int.parse(m[1]!)));
    if (numbers.isNotEmpty) break;
  }
  final hits = episodes.where((ep) => numbers.contains(ep.number)).toList();
  if (hits.length != 1 || numbers.length != 1) {
    return const SubtitleImportMatch(null, '无法唯一识别集号，请手动指定');
  }
  return SubtitleImportMatch(
    hits.single,
    '文件名第 ${hits.single.number} 集；请确认作品和版本',
  );
}
