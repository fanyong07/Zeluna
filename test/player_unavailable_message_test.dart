import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/player/player_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'registered but unqueried sources are not reported as failed lookups',
    () {
      final lines = [
        for (var i = 0; i < 122; i++)
          PlaybackLine(
            id: 'registered-$i',
            episodeId: 1,
            providerId: 'aggregate.maccms',
            providerName: 'Source $i',
            sourceInventoryId: 'registered:$i',
            title: 'Source $i',
            quality: '',
            format: '',
            queried: i < 16,
            diagnosticStatus: i < 16
                ? PlaybackDiscoveryStatus.searchMiss
                : PlaybackDiscoveryStatus.candidateUnadmitted,
          ),
      ];
      final message = playbackUnavailableMessage(lines);
      expect(message, contains('实际查询 16'));
      expect(message, contains('106'));
      expect(message, isNot(contains('找到 122 条线路')));
      expect(message, isNot(contains('已经找过 122')));
    },
  );

  test('aggregate backend media failures retain network guidance', () {
    const lines = [
      PlaybackLine(
        id: 'aggregate-route',
        episodeId: 1,
        providerId: 'aggregate.maccms',
        providerName: 'Source',
        sourceInventoryId: 'registered:route',
        title: 'Episode',
        quality: '',
        format: 'hls',
        url: 'https://cdn.example/video.m3u8',
        queried: true,
        diagnosticStatus: PlaybackDiscoveryStatus.routeUnavailable,
        message: '连接超时',
      ),
    ];
    final message = playbackUnavailableMessage(lines);
    expect(message, contains('1 条视频线路'));
    expect(message, contains('网络或代理'));
  });

  test(
    'empty backend placeholders are not described as candidate media lines',
    () {
      final lines = List.generate(
        20,
        (index) => PlaybackLine(
          id: 'placeholder-$index',
          episodeId: 1,
          providerId: 'zeluna:maccms:source-$index',
          providerName: 'Source $index',
          title: 'Source $index',
          quality: '',
          format: '',
          message: '当前站点没有匹配到这部作品',
        ),
      );

      final message = playbackUnavailableMessage(lines);

      expect(message, contains('已经找过 20 个在线来源'));
      expect(message, contains('都没有找到能播的地址'));
      expect(message, isNot(contains('20 条候选线路')));
      expect(message, isNot(contains('请检查网络或代理')));
    },
  );

  test('real media URLs that fail locally retain the network guidance', () {
    const lines = [
      PlaybackLine(
        id: 'candidate',
        episodeId: 1,
        providerId: 'zeluna:maccms:test',
        providerName: 'Test',
        title: 'Test',
        quality: '1080p',
        format: 'hls',
        url: 'https://cdn.example/video.m3u8',
        message: '连接超时',
      ),
    ];

    final message = playbackUnavailableMessage(lines);

    expect(message, contains('1 条视频线路'));
    expect(message, contains('网络或代理'));
  });
}
