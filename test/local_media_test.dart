import 'package:anime/src/player/local_media.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'local paths are encoded for the player without losing filename bytes',
    () {
      expect(
        localMediaPlaybackUrl('C:/Videos/episode #1 %.mp4'),
        'file:///C:/Videos/episode%20%231%20%25.mp4',
      );
      expect(
        localMediaPlaybackUrl('/storage/emulated/0/Movies/第 1 集.mp4'),
        'file:///storage/emulated/0/Movies/%E7%AC%AC%201%20%E9%9B%86.mp4',
      );
      expect(
        localMediaPlaybackUrl(r'\\media-server\Videos\episode #1.mp4'),
        'file://media-server/Videos/episode%20%231.mp4',
      );
      expect(
        localMediaPlaybackUrl('/home/user/100%25.mp4'),
        'file:///home/user/100%2525.mp4',
      );
    },
  );

  for (final url in [
    'file:///C:/Videos/episode%20%231.mp4',
    'blob:https://example.com/1234',
    'content://media/external/video/media/1234',
    'https://example.com/episode%201.mp4?token=example',
  ]) {
    test('an existing ${Uri.parse(url).scheme} URI is not double encoded', () {
      expect(localMediaPlaybackUrl(url), url);
    });
  }
}
