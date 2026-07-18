import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/domain/subject_content_type.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('anime providers stay anime even when platform is Movie', () {
    for (final source in const ['bangumi', 'anilist', 'jikan', 'kitsu']) {
      expect(
        subjectContentTypeOf(_subject(source: source, platform: 'Movie')),
        SubjectContentType.anime,
        reason: source,
      );
    }
  });

  test('series and movie metadata sources are classified strictly', () {
    expect(
      subjectContentTypeOf(_subject(source: 'tvmaze', platform: 'Scripted')),
      SubjectContentType.series,
    );
    expect(
      subjectContentTypeOf(
        _subject(source: 'cinemeta:series:tt123', platform: 'Series'),
      ),
      SubjectContentType.series,
    );
    for (final source in const [
      'cinemeta:movie:tt456',
      'wikidata',
      'archive:public-film',
      'peertube:video',
      'commons:file',
    ]) {
      expect(
        subjectContentTypeOf(_subject(source: source, platform: 'Movie')),
        SubjectContentType.movie,
        reason: source,
      );
    }
  });
}

AnimeSubject _subject({required String source, required String platform}) {
  return AnimeSubject(
    id: source.hashCode,
    title: '测试条目',
    originalTitle: 'Test Subject',
    summary: '',
    coverUrl: null,
    bannerUrl: null,
    date: '2026-01-01',
    platform: platform,
    language: '',
    region: '',
    status: '',
    categories: const [],
    tags: const [],
    totalEpisodes: 1,
    source: source,
  );
}
