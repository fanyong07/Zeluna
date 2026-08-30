import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/player/player_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
