import 'package:anime/src/player/local_media.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  final sharedFiles = {
    r'\\media-server\Videos\episode #1 %.mp4':
        '//media-server/Videos/episode #1 %.mp4',
    r'\\192.0.2.10\Videos\第 1 集.mp4': '//192.0.2.10/Videos/第 1 集.mp4',
    r'\\media-server\Videos\100%25.mp4': '//media-server/Videos/100%25.mp4',
  };
  for (final entry in sharedFiles.entries) {
    test(
      'UNC file retains its server and filename at the native boundary: ${entry.key}',
      () {
        final url = localMediaPlaybackUrl(entry.key);
        final resource = nativeMediaPlaybackResource(url, windows: true);

        expect(Media.normalizeURI(resource), entry.value);
      },
    );
  }

  test(
    'an existing UNC file URI is decoded once for native Windows playback',
    () {
      const url = 'file://media-server/Videos/episode%20%231%20%25.mp4';
      expect(
        Media.normalizeURI(nativeMediaPlaybackResource(url, windows: true)),
        '//media-server/Videos/episode #1 %.mp4',
      );
    },
  );

  test('non-Windows players keep the original file URI', () {
    const url = 'file://media-server/Videos/episode%20%231.mp4';
    expect(nativeMediaPlaybackResource(url, windows: false), url);
  });

  for (final url in [
    'file:///C:/Videos/episode%20%231.mp4',
    'file:///storage/emulated/0/Movies/episode%201.mp4',
    'blob:https://example.com/1234',
    'content://media/external/video/media/1234',
    'https://example.com/episode%201.mp4?token=example',
  ]) {
    test(
      'native adapter does not change a non-UNC ${Uri.parse(url).scheme} URI',
      () {
        expect(nativeMediaPlaybackResource(url, windows: true), url);
      },
    );
  }
}
