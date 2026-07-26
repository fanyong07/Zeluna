import 'package:anime/src/data/media_download_line_selector.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('single-file download candidates prefer direct media and skip HLS', () {
    final lines = singleFileDownloadCandidates(const [
      PlaybackLine(
        id: 'hls',
        episodeId: 1,
        providerId: 'one',
        providerName: 'HLS first',
        title: 'HLS',
        quality: '1080p',
        format: 'HLS',
        url: 'https://cdn.example/master.m3u8',
        available: true,
      ),
      PlaybackLine(
        id: 'unknown',
        episodeId: 1,
        providerId: 'two',
        providerName: 'Unknown API',
        title: 'Unknown',
        quality: '720p',
        format: 'unknown',
        url: 'https://cdn.example/play?id=1',
        available: true,
      ),
      PlaybackLine(
        id: 'mp4',
        episodeId: 1,
        providerId: 'three',
        providerName: 'Direct MP4',
        title: 'MP4',
        quality: '720p',
        format: 'MP4',
        url: 'https://cdn.example/video.mp4?token=1',
        available: true,
      ),
    ]);

    expect(lines.map((item) => item.id), ['mp4', 'unknown']);
    expect(
      hlsDownloadCandidates(const [
        PlaybackLine(
          id: 'hls',
          episodeId: 1,
          providerId: 'one',
          providerName: 'HLS first',
          title: 'HLS',
          quality: '1080p',
          format: 'HLS',
          url: 'https://cdn.example/master.m3u8',
          available: true,
        ),
      ]).single.id,
      'hls',
    );
  });

  test('manifest query parameters are recognized as segmented media', () {
    const line = PlaybackLine(
      id: 'query-hls',
      episodeId: 1,
      providerId: 'one',
      providerName: 'HLS',
      title: 'HLS',
      quality: 'auto',
      format: 'unknown',
      url: 'https://cdn.example/play?type=m3u8&id=1',
      available: true,
    );

    expect(isSegmentedDownloadLine(line), isTrue);
    expect(singleFileDownloadCandidates(const [line]), isEmpty);
  });
}
