import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/domain/subject_content_type.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('movie format wins over anime provider identity', () {
    for (final source in const ['bangumi', 'anilist', 'jikan', 'kitsu']) {
      for (final platform in const ['Movie', 'Film', '电影', '剧场版']) {
        expect(
          subjectContentTypeOf(_subject(source: source, platform: platform)),
          SubjectContentType.movie,
          reason: '$source / $platform',
        );
      }
    }
  });

  test('non-movie items from anime providers stay in the anime catalogue', () {
    for (final source in const ['bangumi', 'anilist', 'jikan', 'kitsu']) {
      expect(
        subjectContentTypeOf(_subject(source: source, platform: 'TV')),
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

  test('localized legacy platform labels retain their content type', () {
    expect(
      subjectContentTypeOf(_subject(source: 'custom', platform: '电影')),
      SubjectContentType.movie,
    );
    expect(
      subjectContentTypeOf(_subject(source: 'custom', platform: '电视剧')),
      SubjectContentType.series,
    );
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
