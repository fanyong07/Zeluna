import 'package:anime/src/player/video/hls_ad_cleaner.dart';
import 'package:flutter_test/flutter_test.dart';

const _head = '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:10\n';

String _seg(double seconds, String name) =>
    '#EXTINF:${seconds.toStringAsFixed(3)},\n$name\n';

void main() {
  test('cuts domestic mid-roll ad island with matching duration but divergent path', () {
    final buf = StringBuffer(_head);
    for (var i = 0; i < 15; i++) {
      buf.write(_seg(6.0, '/202611/ep1/index${i.toString().padLeft(4, '0')}.ts'));
    }
    buf.write('#EXT-X-DISCONTINUITY\n');
    for (var i = 0; i < 3; i++) {
      buf.write(_seg(5.0, '/adjump/casino_$i.ts'));
    }
    buf.write('#EXT-X-DISCONTINUITY\n');
    for (var i = 15; i < 30; i++) {
      buf.write(_seg(6.0, '/202611/ep1/index${i.toString().padLeft(4, '0')}.ts'));
    }
    buf.write('#EXT-X-ENDLIST\n');

    final result = cleanHlsPlaylist(
      buf.toString(),
      baseUri: Uri.parse('https://cdn.example.com/202611/ep1/index.m3u8'),
    );
    expect(result.report.changed, isTrue);
    expect(result.report.segmentsCut, 3);
    expect(result.playlist, isNot(contains('casino_0.ts')));
    expect(result.playlist, contains('https://cdn.example.com/202611/ep1/index0000.ts'));
    expect(result.playlist, contains('https://cdn.example.com/202611/ep1/index0029.ts'));
  });

  test('cuts unencrypted ad island inside an encrypted feature playlist', () {
    final buf = StringBuffer(_head)
      ..write('#EXT-X-KEY:METHOD=AES-128,URI="enc.key"\n');
    for (var i = 0; i < 12; i++) {
      buf.write(_seg(6.0, 'seg${i.toString().padLeft(4, '0')}.ts'));
    }
    buf.write('#EXT-X-DISCONTINUITY\n');
    buf.write('#EXT-X-KEY:METHOD=NONE\n');
    for (var i = 9000; i < 9003; i++) {
      buf.write(_seg(5.0, 'seg$i.ts'));
    }
    buf.write('#EXT-X-DISCONTINUITY\n');
    buf.write('#EXT-X-KEY:METHOD=AES-128,URI="enc.key"\n');
    for (var i = 12; i < 24; i++) {
      buf.write(_seg(6.0, 'seg${i.toString().padLeft(4, '0')}.ts'));
    }
    buf.write('#EXT-X-ENDLIST\n');

    final result = cleanHlsPlaylist(
      buf.toString(),
      baseUri: Uri.parse('https://cdn.example.com/v/index.m3u8'),
    );
    expect(result.report.segmentsCut, 3);
    expect(result.playlist, isNot(contains('seg9000.ts')));
    expect(result.playlist, contains('URI="https://cdn.example.com/v/enc.key"'));
  });

  test('preserves non-ad DISCONTINUITY between normal feature groups', () {
    final buf = StringBuffer(_head);
    for (var i = 0; i < 10; i++) {
      buf.write(_seg(6.0, 'seg${i.toString().padLeft(4, '0')}.ts'));
    }
    buf.write('#EXT-X-DISCONTINUITY\n');
    for (var i = 10; i < 20; i++) {
      buf.write(_seg(6.0, 'seg${i.toString().padLeft(4, '0')}.ts'));
    }
    buf.write('#EXT-X-ENDLIST\n');

    final result = cleanHlsPlaylist(
      buf.toString(),
      baseUri: Uri.parse('https://cdn.example.com/v/index.m3u8'),
    );
    expect(result.report.changed, isFalse);
    expect(result.playlist, contains('#EXT-X-DISCONTINUITY'));
  });

  test('cuts CUE-OUT/CUE-IN breaks deterministically', () {
    final playlist = [
      _head,
      for (var i = 0; i < 6; i++) _seg(6.0, 'main$i.ts'),
      '#EXT-X-CUE-OUT:12\n',
      _seg(6.0, 'sponsor0.ts'),
      _seg(6.0, 'sponsor1.ts'),
      '#EXT-X-CUE-IN\n',
      for (var i = 6; i < 12; i++) _seg(6.0, 'main$i.ts'),
      '#EXT-X-ENDLIST\n',
    ].join();

    final result = cleanHlsPlaylist(
      playlist,
      baseUri: Uri.parse('https://cdn.example.com/v/index.m3u8'),
    );
    expect(result.report.changed, isTrue);
    expect(result.playlist, isNot(contains('sponsor0.ts')));
    expect(result.playlist, contains('main11.ts'));
  });
}
