import 'anime_models.dart';

enum SubjectContentType { anime, series, movie }

SubjectContentType subjectContentTypeOf(AnimeSubject subject) {
  final source = subject.source.trim().toLowerCase();
  final platform = subject.platform.trim().toLowerCase();

  // Release format wins over provider identity. In particular, theatrical
  // anime returned by an anime provider belongs to the movie catalogue rather
  // than appearing in both the anime and movie catalogues.
  if (platform.contains('movie') ||
      platform.contains('film') ||
      platform.contains('电影') ||
      platform.contains('剧场版')) {
    return SubjectContentType.movie;
  }

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

  if (source.startsWith('cinemeta:series:') ||
      source.startsWith('tmdb:series:') ||
      source == 'tmdb:tv' ||
      source.startsWith('tmdb:tv:') ||
      source.startsWith('tvmaze')) {
    return SubjectContentType.series;
  }

  if (source.startsWith('cinemeta:movie:') ||
      source.startsWith('tmdb:movie:') ||
      source == 'wikidata' ||
      source.startsWith('archive:') ||
      source.startsWith('peertube:') ||
      source.startsWith('commons:')) {
    return SubjectContentType.movie;
  }

  if (platform.contains('series') ||
      platform.contains('scripted') ||
      platform.contains('show') ||
      platform.contains('reality') ||
      platform.contains('剧集') ||
      platform.contains('连续剧') ||
      platform.contains('电视剧')) {
    return SubjectContentType.series;
  }
  return SubjectContentType.anime;
}

bool subjectMatchesContentType(AnimeSubject subject, SubjectContentType type) {
  return subjectContentTypeOf(subject) == type;
}
