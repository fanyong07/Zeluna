import 'package:anime/src/data/playback_source_repository.dart';
import 'package:anime/src/data/external_service_repository.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'playback source framework returns lines for one episode only',
    () async {
      const subject = AnimeSubject(
        id: 1,
        title: '测试番剧',
        originalTitle: 'Test Anime',
        summary: 'summary',
        coverUrl: null,
        bannerUrl: null,
        date: '2026-01-01',
        platform: 'TV',
        language: '日语',
        region: '日本',
        status: '全12集',
        categories: [AnimeCategory(name: '动画')],
        tags: [AnimeTag(name: 'TV')],
        totalEpisodes: 12,
      );
      const episode = AnimeEpisode(
        id: 101,
        subjectId: 1,
        number: 1,
        title: '',
        airdate: '2026-01-01',
        duration: '24:00',
        description: '第一集',
      );

      final lines = await const EmptyPlaybackSourceRepository().linesForEpisode(
        subject,
        episode,
      );

      expect(lines, hasLength(1));
      expect(lines.single.episodeId, episode.id);
      expect(lines.single.available, isFalse);
      expect(lines.single.message, contains('播放源接入点'));
    },
  );

  test(
    'subtitle and danmaku frameworks use public sources without keys',
    () async {
      const subject = AnimeSubject(
        id: 1,
        title: '测试番剧',
        originalTitle: 'Test Anime',
        summary: 'summary',
        coverUrl: null,
        bannerUrl: null,
        date: '2026-01-01',
        platform: 'TV',
        language: '日语',
        region: '日本',
        status: '全12集',
        categories: [AnimeCategory(name: '动画')],
        tags: [AnimeTag(name: 'TV')],
        totalEpisodes: 12,
      );
      const episode = AnimeEpisode(
        id: 101,
        subjectId: 1,
        number: 1,
        title: '',
        airdate: '2026-01-01',
        duration: '24:00',
        description: '第一集',
      );

      final repo = ExternalServiceRepository();
      final subtitles = await repo.searchSubtitles(
        subject,
        episode,
        const ExternalServiceSettings(),
      );
      final danmaku = await repo.matchDanmaku(
        subject,
        episode,
        const ExternalServiceSettings(),
      );

      expect(subtitles.single.provider, 'Bilibili');
      expect(subtitles.single.message, contains('B 站'));
      expect(danmaku.single.provider, 'Bilibili');
      expect(danmaku.single.message, contains('B 站'));
    },
  );

  test('external service settings no longer require third-party keys', () {
    const settings = ExternalServiceSettings();
    final json = settings.toJson();

    expect(settings.mediaMetadataEnabled, isTrue);
    expect(settings.mediaMetadataProvider, 'TVMaze');
    expect(settings.publicCollectionSyncEnabled, isTrue);
    expect(settings.bilibiliSubtitleEnabled, isTrue);
    expect(settings.bilibiliDanmakuEnabled, isTrue);
    expect(json, isNot(contains('tmdbEnabled')));
    expect(json, isNot(contains('tmdbLanguage')));
    expect(json, isNot(contains('traktEnabled')));
    expect(json, isNot(contains('openSubtitlesEnabled')));
    expect(json, isNot(contains('dandanplayEnabled')));
  });
}
