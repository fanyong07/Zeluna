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
    String providerId = 'zeluna:site:test',
    bool available = true,
    bool serverVerified = true,
    bool clientVerified = false,
    bool requiresClientProbe = false,
    DateTime? expiresAt,
  }) {
    return PlaybackLine(
      id: id,
      episodeId: 1,
      providerId: providerId,
      providerName: '在线服务 · test',
      title: id,
      quality: '1080P',
      format: 'hls',
      url: url,
      available: available,
      serverVerified: serverVerified,
      clientVerified: clientVerified,
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

  test(
    'a prefetched route with less than the required validity is rejected',
    () {
      final cache = PlaybackPrefetchCache(now: () => now);
      final route = line(
        id: 'short-lived',
        url: 'https://cdn.example/short-lived.m3u8',
        expiresAt: now.add(const Duration(seconds: 59)),
      );

      cache.write('episode:1', [route]);

      expect(
        cache.read('episode:1', minValidity: const Duration(seconds: 60)),
        isNull,
      );
    },
  );

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

  group('next-episode warmup bundles', () {
    test('only accepts available verified HTTP media lines', () {
      final cache = NextEpisodeWarmupCache(now: () => now);
      final probeOnly = line(
        id: 'probe-only',
        url: 'https://probe.example/video.m3u8',
        serverVerified: false,
        requiresClientProbe: true,
      );

      expect(
        cache.write(
          'episode:2',
          episodeIdentity: 'subject:1|episode:2',
          primary: probeOnly,
        ),
        isNull,
      );
      expect(cache.read('episode:2'), isNull);

      final verified = line(
        id: 'verified',
        url: 'https://verified.example/video.m3u8',
        serverVerified: false,
        clientVerified: true,
      );
      final bundle = cache.write(
        'episode:2',
        episodeIdentity: 'subject:1|episode:2',
        primary: verified,
        preferredProviderId: ' provider:remembered ',
      );

      expect(bundle?.primary, same(verified));
      expect(bundle?.preferredProviderId, 'provider:remembered');
      expect(bundle?.preparedAt, now);
      expect(bundle?.allLines, [same(verified)]);
    });

    test(
      'keeps one distinct verified fallback and exposes earliest expiry',
      () {
        final cache = NextEpisodeWarmupCache(now: () => now);
        final primary = line(
          id: 'primary',
          url: 'https://primary.example/video.m3u8',
          expiresAt: now.add(const Duration(minutes: 12)),
        );
        final fallback = line(
          id: 'fallback',
          url: 'https://fallback.example/video.m3u8',
          providerId: 'zeluna:site:fallback',
          expiresAt: now.add(const Duration(minutes: 8)),
        );
        final duplicatePrimary = line(
          id: 'duplicate-primary',
          url: primary.url!,
        );
        final ignored = line(
          id: 'ignored',
          url: 'https://ignored.example/video.m3u8',
        );

        final bundle = cache.write(
          'episode:2',
          episodeIdentity: 'subject:1|episode:2',
          primary: primary,
          fallbacks: [duplicatePrimary, fallback, ignored],
        );

        expect(bundle?.primary, same(primary));
        expect(bundle?.fallbacks, [same(fallback)]);
        expect(bundle?.allLines, [same(primary), same(fallback)]);
        expect(bundle?.earliestExpiry, fallback.expiresAt);
      },
    );

    test('promotes a fresh fallback when the primary becomes stale', () {
      final cache = NextEpisodeWarmupCache(now: () => now);
      final primary = line(
        id: 'primary',
        url: 'https://primary.example/video.m3u8',
        expiresAt: now.add(const Duration(minutes: 2)),
      );
      final fallback = line(
        id: 'fallback',
        url: 'https://fallback.example/video.m3u8',
        expiresAt: now.add(const Duration(minutes: 10)),
      );
      cache.write(
        'episode:2',
        episodeIdentity: 'subject:1|episode:2',
        primary: primary,
        fallbacks: [fallback],
      );

      now = now.add(const Duration(minutes: 1, seconds: 15));
      final promoted = cache.read(
        'episode:2',
        minValidity: const Duration(minutes: 1),
      );

      expect(promoted?.primary, same(fallback));
      expect(promoted?.fallbacks, isEmpty);
      expect(promoted?.allLines, [same(fallback)]);
      expect(promoted?.earliestExpiry, fallback.expiresAt);
    });

    test(
      'a long minimum-validity miss preserves routes for a shorter read',
      () {
        final cache = NextEpisodeWarmupCache(now: () => now);
        cache.write(
          'episode:2',
          episodeIdentity: 'subject:1|episode:2',
          primary: line(
            id: 'primary',
            url: 'https://primary.example/video.m3u8',
            expiresAt: now.add(const Duration(minutes: 4)),
          ),
          fallbacks: [
            line(
              id: 'fallback',
              url: 'https://fallback.example/video.m3u8',
              expiresAt: now.add(const Duration(minutes: 3)),
            ),
          ],
        );

        expect(
          cache.read('episode:2', minValidity: const Duration(minutes: 4)),
          isNull,
        );
        expect(cache.length, 1);

        final shorterRead = cache.read(
          'episode:2',
          minValidity: const Duration(minutes: 2),
        );
        expect(shorterRead?.primary.id, 'primary');
        expect(shorterRead?.fallback?.id, 'fallback');
        expect(cache.length, 1);
      },
    );

    test('TTL expires bundles independently from route expiry', () {
      final cache = NextEpisodeWarmupCache(
        ttl: const Duration(minutes: 5),
        now: () => now,
      );
      cache.write(
        'episode:2',
        episodeIdentity: 'subject:1|episode:2',
        primary: line(id: 'primary', url: 'https://primary.example/video.m3u8'),
      );

      now = now.add(const Duration(minutes: 5));

      expect(cache.read('episode:2'), isNull);
      expect(cache.length, 0);
    });

    test('bounded cache evicts the oldest warmup bundle', () {
      final cache = NextEpisodeWarmupCache(maxEntries: 2, now: () => now);
      for (var episode = 1; episode <= 3; episode++) {
        cache.write(
          'episode:$episode',
          episodeIdentity: 'subject:1|episode:$episode',
          primary: line(
            id: 'line-$episode',
            url: 'https://episode-$episode.example/video.m3u8',
          ),
        );
      }

      expect(cache.length, 2);
      expect(cache.read('episode:1'), isNull);
      expect(cache.read('episode:2'), isNotNull);
      expect(cache.read('episode:3'), isNotNull);
    });
  });
}
