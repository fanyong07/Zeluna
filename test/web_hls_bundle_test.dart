import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const hlsAsset = 'vendor/hls-1.5.18.min.js';

  group('Web HLS runtime bundle', () {
    test('preloads the local runtime before Flutter starts', () {
      final index = File('web/index.html').readAsStringSync();
      final hlsScript = '<script src="$hlsAsset" defer';
      final flutterScript = '<script src="flutter_bootstrap.js" async>';

      expect(
        index,
        contains('<link rel="preload" href="$hlsAsset" as="script">'),
      );
      expect(index, contains(hlsScript));
      expect(index, contains(flutterScript));
      expect(index.indexOf(hlsScript), lessThan(index.indexOf(flutterScript)));
      expect(index, isNot(contains('cdn.jsdelivr.net')));
    });

    test('player fallback also loads the bundled runtime', () {
      final player = File(
        'lib/src/player/web_stream_player_web.dart',
      ).readAsStringSync();

      expect(player, contains("_hlsScriptAsset = '$hlsAsset'"));
      expect(player, contains("setProperty('progressive'.toJS, true.toJS)"));
      expect(
        player,
        contains("setProperty('capLevelToPlayerSize'.toJS, true.toJS)"),
      );
      expect(player, isNot(contains('cdn.jsdelivr.net')));
    });

    test('bundled runtime is the pinned official hls.js 1.5.18 file', () {
      final bundle = File('web/$hlsAsset');
      final license = File('web/vendor/hls.LICENSE.txt');

      expect(bundle.existsSync(), isTrue);
      final normalizedBundle = utf8.encode(
        utf8.decode(bundle.readAsBytesSync()).replaceAll('\r\n', '\n'),
      );
      expect(normalizedBundle.length, 414359);
      expect(
        sha256.convert(normalizedBundle).toString(),
        '5ff2d714de30be428fc77b13e01db9a4b4cf015e9b4d6b3e8864b65d3d7d3ed7',
      );
      expect(license.readAsStringSync(), contains('Apache License'));
    });
  });
}
