import 'package:anime/src/catalog/search_ranking.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/domain/subject_content_type.dart';
import 'package:flutter_test/flutter_test.dart';

AnimeSubject _subject(
  int id,
  String title, {
  String original = '',
  String source = 'bangumi',
  String platform = 'TV',
}) {
  return AnimeSubject(
    id: id,
    title: title,
    originalTitle: original,
    summary: '',
    coverUrl: null,
    bannerUrl: null,
    date: '2026-01-01',
    platform: platform,
    language: '日语',
    region: '日本',
    status: '',
    categories: const [],
    tags: const [],
    totalEpisodes: 12,
    source: source,
  );
}

void main() {
  test('精确命中排在前缀与包含之前', () {
    final ranked = rankSearchSubjects('孤独摇滚', [
      _subject(1, '不孤独摇滚的日常'),
      _subject(2, '孤独摇滚 剧场版'),
      _subject(3, '孤独摇滚'),
    ]);
    expect(ranked.map((item) => item.id).toList(), [3, 2, 1]);
  });

  test('原名命中排在标题模糊匹配之前，全角折叠生效', () {
    final ranked = rankSearchSubjects('fate', [
      _subject(1, '命运之夜', original: 'ＦＡＴＥ／ｓｔａｙ　ｎｉｇｈｔ'),
      _subject(2, '发条特工'),
      _subject(3, 'Fate Zero'),
    ]);
    expect(ranked.first.id, 3);
    expect(ranked[1].id, 1);
  });

  test('同分保持来源顺序（稳定排序）', () {
    final ranked = rankSearchSubjects('测试', [
      _subject(1, '测试甲'),
      _subject(2, '测试乙'),
    ]);
    expect(ranked.map((item) => item.id).toList(), [1, 2]);
  });

  test('分区隔离只保留对应内容类型，tmdb:tv 判定为剧集', () {
    final subjects = [
      _subject(1, '相同关键词', source: 'bangumi'),
      _subject(2, '相同关键词', source: 'tmdb:tv', platform: 'TV'),
      _subject(3, '相同关键词', source: 'tmdb:movie', platform: '电影'),
    ];
    expect(
      rankSearchSubjects(
        '相同关键词',
        subjects,
        scope: SubjectContentType.series,
      ).single.id,
      2,
    );
    expect(
      rankSearchSubjects(
        '相同关键词',
        subjects,
        scope: SubjectContentType.anime,
      ).single.id,
      1,
    );
    expect(
      rankSearchSubjects(
        '相同关键词',
        subjects,
        scope: SubjectContentType.movie,
      ).single.id,
      3,
    );
  });

  test('无命中结果保持在底部而不是被丢弃', () {
    final ranked = rankSearchSubjects('莉可丽丝', [
      _subject(1, '后端认为相关的条目'),
      _subject(2, '莉可丽丝'),
    ]);
    expect(ranked.map((item) => item.id).toList(), [2, 1]);
    expect(ranked, hasLength(2));
  });
}
