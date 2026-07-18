import 'anime_models.dart';

enum SubjectContentType { anime, series, movie }

SubjectContentType subjectContentTypeOf(AnimeSubject subject) {
  final source = subject.source.trim().toLowerCase();
  final platform = subject.platform.trim().toLowerCase();

  // Anime providers may legitimately label theatrical anime as "Movie".
  // Source identity is therefore more reliable than platform for these items.
  if (source == 'bangumi' ||
      source.startsWith('bangumi:') ||
      source == 'anilist' ||
      source.startsWith('anilist:') ||
      source == 'jikan' ||
      source.startsWith('jikan:') ||
      source == 'kitsu' ||
      source.startsWith('kitsu:')) {
    return SubjectContentType.anime;
  }

  if (source.startsWith('cinemeta:series:') || source.startsWith('tvmaze')) {
    return SubjectContentType.series;
  }

  if (source.startsWith('cinemeta:movie:') ||
      source == 'wikidata' ||
      source.startsWith('archive:') ||
      source.startsWith('peertube:') ||
      source.startsWith('commons:')) {
    return SubjectContentType.movie;
  }

  if (platform.contains('series') ||
      platform.contains('scripted') ||
      platform.contains('show') ||
      platform.contains('reality')) {
    return SubjectContentType.series;
  }
  if (platform.contains('movie') || platform.contains('film')) {
    return SubjectContentType.movie;
  }
  return SubjectContentType.anime;
}

bool subjectMatchesContentType(AnimeSubject subject, SubjectContentType type) {
  return subjectContentTypeOf(subject) == type;
}
