import '../domain/anime_models.dart';
import '../domain/subject_content_type.dart';

enum CatalogSortMode {
  recommended('推荐'),
  popular('热门'),
  topRated('高分'),
  latest('最新');

  const CatalogSortMode(this.label);
  final String label;
}

/// A full-catalogue query, not a predicate over the recommendation cache.
class CatalogQuery {
  const CatalogQuery({
    required this.contentType,
    this.sort = CatalogSortMode.recommended,
    this.genre = '全部',
    this.language = '全部',
    this.year,
  });
  final SubjectContentType contentType;
  final CatalogSortMode sort;
  final String genre;
  final String language;
  final int? year;

  Map<String, String> get parameters => {
    'sort': sort.name,
    if (genre != '全部') 'genre': genre,
    if (language != '全部') 'language': language,
    if (year != null) 'year': '$year',
  };

  bool matches(AnimeSubject subject, {DateTime? now, bool matchGenre = true}) {
    if (!subjectMatchesContentType(subject, contentType)) return false;
    if (year != null && subject.year != '$year') return false;
    if (sort == CatalogSortMode.latest) {
      final date = DateTime.tryParse(subject.date ?? '');
      final today = now ?? DateTime.now();
      if (date == null ||
          date.isAfter(DateTime(today.year, today.month, today.day))) {
        return false;
      }
    }
    if (language != '全部' && !matchesCatalogLanguage(subject, language)) {
      return false;
    }
    if (!matchGenre ||
        genre == '全部' ||
        genre == '动画' && contentType == SubjectContentType.anime ||
        genre == '电影' && contentType == SubjectContentType.movie) {
      return true;
    }
    final region = subject.region.toLowerCase().split(RegExp(r'[/,;\s]+'));
    const countries = {
      '美剧': ['us', '美国', 'united states'],
      '英剧': ['gb', 'uk', '英国', 'united kingdom'],
      '日剧': ['jp', '日本', 'japan'],
      '韩剧': ['kr', '韩国', 'korea'],
    };
    if (countries.containsKey(genre)) {
      return countries[genre]!.any(
        (value) =>
            region.contains(value) ||
            (value.length > 3 && subject.region.toLowerCase().contains(value)),
      );
    }
    final labels = [
      ...subject.categories.map((item) => item.name),
      ...subject.tags.map((item) => item.name),
    ].join(' ').toLowerCase();
    return catalogGenreAliases(
      genre,
    ).any((value) => labels.contains(value.toLowerCase()));
  }
}

class CatalogPageResult {
  const CatalogPageResult({required this.subjects, this.nextCursor});
  final List<AnimeSubject> subjects;
  final String? nextCursor;
  bool get hasMore => nextCursor != null;
}

List<String> catalogGenreAliases(String genre) => switch (genre) {
  '喜剧' => const ['喜剧', '搞笑', 'comedy'],
  '科幻' => const ['科幻', 'science fiction', 'sci-fi'],
  '奇幻' => const ['奇幻', 'fantasy'],
  '动作' => const ['动作', 'action'],
  '冒险' => const ['冒险', 'adventure'],
  '剧情' => const ['剧情', 'drama'],
  '犯罪' => const ['犯罪', 'crime'],
  '校园' => const ['校园', 'school'],
  '音乐' => const ['音乐', 'music'],
  _ => [genre],
};

bool matchesCatalogLanguage(AnimeSubject subject, String language) {
  final raw = subject.language.trim().toLowerCase();
  final tokens = raw.split(RegExp(r'[-_/;,\s]+'));
  const aliases = {
    '日语': ['ja', 'jpn', '日语', '日本語', 'japanese'],
    '国语': [
      'zh',
      'cn',
      'zho',
      'cmn',
      'yue',
      '国语',
      '中文',
      '汉语',
      '普通话',
      '粤语',
      'chinese',
      'mandarin',
      'cantonese',
    ],
    '英语': ['en', 'eng', '英语', 'english'],
    '韩语': ['ko', 'kor', '韩语', '한국어', 'korean'],
  };
  bool matches(String key) => aliases[key]!.any(
    (value) =>
        tokens.contains(value) ||
        (value.length > 3 && raw.contains(value)) ||
        (RegExp(r'[\u4e00-\u9fff]').hasMatch(value) && raw.contains(value)),
  );
  if (language == '其他') {
    return raw.isNotEmpty && raw != '未知' && !aliases.keys.any(matches);
  }
  return aliases.containsKey(language) ? matches(language) : true;
}
