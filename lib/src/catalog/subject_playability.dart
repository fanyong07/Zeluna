import '../domain/anime_models.dart';

bool hasKnownDirectPlayback(AnimeSubject subject) {
  final source = subject.source.toLowerCase();
  return source == 'direct' ||
      source.startsWith('archive:') ||
      source.startsWith('peertube:') ||
      source.startsWith('commons:');
}

/// User-facing playback hint. Rule-based lookup is an implementation detail;
/// cards either promise playback or stay quiet.
String subjectPlaybackLabel(AnimeSubject subject) {
  return hasKnownDirectPlayback(subject) ? '可播放' : '';
}
