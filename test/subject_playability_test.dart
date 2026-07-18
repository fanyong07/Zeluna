import 'package:anime/src/catalog/subject_playability.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('known open media sources are marked playable', () {
    for (final source in const [
      'archive:public-film',
      'peertube:video-id',
      'commons:12345',
      'direct',
    ]) {
      final subject = _subject(source);
      expect(hasKnownDirectPlayback(subject), isTrue, reason: source);
      expect(subjectPlaybackLabel(subject), '直连播放');
    }
  });

  test('metadata-only sources are not overclaimed', () {
    for (final source in const [
      'bangumi',
      'anilist',
      'cinemeta:movie:tt0111161',
      'cinemeta:series:tt0903747',
      'tvmaze',
      'wikidata',
    ]) {
      final subject = _subject(source);
      expect(hasKnownDirectPlayback(subject), isFalse, reason: source);
      expect(subjectPlaybackLabel(subject), '规则查源');
    }
  });
}

AnimeSubject _subject(String source, {int id = 1}) {
  return AnimeSubject(
    id: id,
    title: '测试内容 $id',
    originalTitle: 'Test $id',
    summary: '测试简介',
    coverUrl: null,
    bannerUrl: null,
    date: '2026-01-01',
    platform: 'Movie',
    language: '英语',
    region: '美国',
    status: '已发布',
    categories: const [],
    tags: const [],
    totalEpisodes: 1,
    source: source,
  );
}
