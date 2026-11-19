import 'dart:async';

import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/playback/local_route_ranker.dart';
import 'package:anime/src/playback/playback_discovery_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

PlaybackLine _line({
  required String id,
  required String url,
  String providerId = 'maccms:test',
  String providerName = '测试源',
  bool available = true,
  Duration? latency,
}) {
  return PlaybackLine(
    id: id,
    episodeId: 1,
    providerId: providerId,
    providerName: providerName,
    title: id,
    quality: '1080P',
    url: url,
    available: available,
    clientVerified: available,
    latency: latency,
    format: 'HLS',
  );
}

void main() {
  tearDown(() => LocalRouteRanker.instance.resetForTesting());

  test('cleanliness tiers prioritize clean sources and demote ad-reported lines', () {
    final ranker = LocalRouteRanker();
    final adLine = _line(
      id: 'ad',
      url: 'https://ad.cdn.test/1.m3u8',
      providerId: 'maccms:bad',
      latency: const Duration(milliseconds: 50),
    );
    final normalLine = _line(
      id: 'normal',
      url: 'https://ok.cdn.test/1.m3u8',
      providerId: 'maccms:ok',
      latency: const Duration(milliseconds: 200),
    );
    final cleanLine = _line(
      id: 'clean',
      url: 'https://direct.cdn.test/1.m3u8',
      providerId: 'kazumi:mxdm',
      latency: const Duration(milliseconds: 250),
    );

    ranker.markLineAsAd(adLine);
    expect(ranker.cleanlinessTierOf(cleanLine), RouteCleanlinessTier.clean);
    expect(ranker.cleanlinessTierOf(normalLine), RouteCleanlinessTier.cleanable);
    expect(ranker.cleanlinessTierOf(adLine), RouteCleanlinessTier.adHeavy);

    LocalRouteRanker.instance.markLineAsAd(adLine);
    final ranked = rankPlaybackLinesForStartup([adLine, normalLine, cleanLine]);
    expect(ranked.map((l) => l.id).toList(), ['clean', 'normal', 'ad']);
  });

  test('local host EMA latency breaks ties in favor of faster on-device CDN', () {
    final slowLocal = _line(
      id: 'slow',
      url: 'https://slow.cdn.test/ep1.m3u8',
      providerId: 'maccms:a',
      latency: const Duration(milliseconds: 100), // VPS thought it was fast
    );
    final fastLocal = _line(
      id: 'fast',
      url: 'https://fast.cdn.test/ep1.m3u8',
      providerId: 'maccms:b',
      latency: const Duration(milliseconds: 900), // VPS thought it was slow
    );
    LocalRouteRanker.instance.recordHostLatency(
      slowLocal.url,
      const Duration(milliseconds: 1800),
    );
    LocalRouteRanker.instance.recordHostLatency(
      fastLocal.url,
      const Duration(milliseconds: 120),
    );

    final ranked = rankPlaybackLinesForStartup([slowLocal, fastLocal]);
    expect(ranked.first.id, 'fast');
  });

  test('raceFastestPlayable returns the fastest valid non-HTML candidate', () async {
    final ranker = LocalRouteRanker();
    final slow = _line(id: 'slow', url: 'https://slow.test/a.m3u8');
    final htmlTrap = _line(id: 'html', url: 'https://trap.test/a.m3u8');
    final fast = _line(id: 'fast', url: 'https://fast.test/a.m3u8');

    final client = MockClient.streaming((request, _) async {
      if (request.url.host == 'trap.test') {
        return http.StreamedResponse(
          Stream.value('<html>blocked</html>'.codeUnits),
          200,
          headers: {'content-type': 'text/html'},
        );
      }
      if (request.url.host == 'slow.test') {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      } else {
        await Future<void>.delayed(const Duration(milliseconds: 15));
      }
      return http.StreamedResponse(
        Stream.value('#EXTM3U\n'.codeUnits),
        206,
        headers: {'content-type': 'application/vnd.apple.mpegurl'},
      );
    });

    final winner = await ranker.raceFastestPlayable(
      [slow, htmlTrap, fast],
      client: client,
      timeout: const Duration(seconds: 2),
    );
    expect(winner, isNotNull);
    expect(winner!.id, 'fast');
    expect(ranker.predictedLatency(fast.url), isNotNull);
  });
}
