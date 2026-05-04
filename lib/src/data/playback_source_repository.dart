import '../domain/anime_models.dart';

abstract class PlaybackSourceRepository {
  Future<List<PlaybackLine>> linesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode,
  );
}

class EmptyPlaybackSourceRepository implements PlaybackSourceRepository {
  const EmptyPlaybackSourceRepository();

  @override
  Future<List<PlaybackLine>> linesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode,
  ) async {
    return [
      PlaybackLine(
        id: 'placeholder:${subject.id}:${episode.id}',
        episodeId: episode.id,
        providerId: 'custom',
        providerName: '待接入源',
        title: '${subject.title} - 第${episode.number}集',
        quality: '待接入',
        format: 'HLS/MP4',
        available: false,
        message: '这里是播放源接入点。后续只需要按当前 episode 返回线路列表即可。',
      ),
    ];
  }
}
