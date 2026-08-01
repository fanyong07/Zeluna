import 'package:anime/src/data/playback_prefetch_cache.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late DateTime now;

  setUp(() {
    now = DateTime.utc(2026, 8, 1, 12);
  });

  PlaybackLine line({
    required String id,
    required String url,
    bool available = true,
    bool serverVerified = true,
    bool requiresClientProbe = false,
    DateTime? expiresAt,
  }) {
    return PlaybackLine(
      id: id,
      episodeId: 1,
      providerId: 'zeluna:site:test',
      providerName: '在线服务 · test',
      title: id,
      quality: '1080P',
      format: 'hls',
      url: url,
      available: available,
      serverVerified: serverVerified,
      requiresClientProbe: requiresClientProbe,
      expiresAt: expiresAt,
    );
  }

  test('detail prefetch remains reusable until the short memory TTL', () {
    final cache = PlaybackPrefetchCache(now: () => now);
    final route = line(id: 'ready', url: 'https://cdn.example/ready.m3u8');

    cache.write('episode:1', [route]);

    expect(cache.read('episode:1'), [same(route)]);
    now = now.add(const Duration(seconds: 89));
    expect(cache.read('episode:1'), [same(route)]);
    now = now.add(const Duration(seconds: 2));
    expect(cache.read('episode:1'), isNull);
  });

  test('expired or non-media rows are never handed to the player', () {
    final cache = PlaybackPrefetchCache(now: () => now);
    final candidate = line(
      id: 'candidate',
      url: 'https://other.example/candidate.m3u8',
      available: false,
      serverVerified: false,
      requiresClientProbe: true,
    );
    cache.write('episode:1', [
      line(
        id: 'expired',
        url: 'https://cdn.example/expired.m3u8',
        expiresAt: now.add(const Duration(seconds: 10)),
      ),
      line(id: 'placeholder', url: '', available: false, serverVerified: false),
      candidate,
    ]);

    expect(cache.read('episode:1'), [same(candidate)]);
  });

  test('cache stays bounded and evicts the oldest prefetch', () {
    final cache = PlaybackPrefetchCache(maxEntries: 2, now: () => now);
    cache.write('episode:1', [
      line(id: 'one', url: 'https://one.example/video.m3u8'),
    ]);
    cache.write('episode:2', [
      line(id: 'two', url: 'https://two.example/video.m3u8'),
    ]);
    cache.write('episode:3', [
      line(id: 'three', url: 'https://three.example/video.m3u8'),
    ]);

    expect(cache.length, 2);
    expect(cache.read('episode:1'), isNull);
    expect(cache.read('episode:2'), isNotNull);
    expect(cache.read('episode:3'), isNotNull);
  });
}
