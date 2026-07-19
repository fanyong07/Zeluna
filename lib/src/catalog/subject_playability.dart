import '../domain/anime_models.dart';

bool hasKnownDirectPlayback(AnimeSubject subject) {
  final source = subject.source.toLowerCase();
  return source == 'direct' ||
      source.startsWith('archive:') ||
      source.startsWith('peertube:') ||
      source.startsWith('commons:');
}

String subjectPlaybackLabel(AnimeSubject subject) {
  return hasKnownDirectPlayback(subject) ? '直连播放' : '规则查源';
}
