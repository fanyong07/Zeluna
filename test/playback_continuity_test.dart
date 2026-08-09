import 'package:anime/src/data/playback_prefetch_cache.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/player/playback_continuity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final preparedAt = DateTime.utc(2026, 8, 9, 12);

  PlaybackLine line({
    required String id,
    required DateTime? expiresAt,
    String providerId = 'zeluna:primary',
    bool serverVerified = true,
    bool clientVerified = false,
  }) {
    return PlaybackLine(
      id: id,
      episodeId: 2,
      providerId: providerId,
      providerName: providerId,
      title: id,
      quality: '1080P',
      format: 'hls',
      url: 'https://$id.example/video.m3u8',
      available: true,
      serverVerified: serverVerified,
      clientVerified: clientVerified,
      expiresAt: expiresAt,
    );
  }

  NextEpisodeWarmupBundle bundle({
    required PlaybackLine primary,
    Iterable<PlaybackLine> fallbacks = const <PlaybackLine>[],
  }) {
    final cache = NextEpisodeWarmupCache(now: () => preparedAt);
    return cache.write(
      'episode:2',
      episodeIdentity: 'subject:1|episode:2',
      primary: primary,
      fallbacks: fallbacks,
      preparedAt: preparedAt,
    )!;
  }

  group('required warmup validity', () {
    test('adds the remaining playback time and safety margin', () {
      expect(
        calculateRequiredWarmupValidity(
          duration: const Duration(minutes: 24),
          position: const Duration(minutes: 19, seconds: 30),
          safetyMargin: const Duration(seconds: 45),
        ),
        const Duration(minutes: 5, seconds: 15),
      );
    });

    test('does not guess when duration is unknown or non-positive', () {
      expect(
        calculateRequiredWarmupValidity(
          duration: null,
          position: const Duration(minutes: 3),
          safetyMargin: const Duration(seconds: 30),
        ),
        isNull,
      );
      expect(
        calculateRequiredWarmupValidity(
          duration: Duration.zero,
          position: Duration.zero,
          safetyMargin: const Duration(seconds: 30),
        ),
        isNull,
      );
      expect(
        calculateRequiredWarmupValidity(
          duration: const Duration(seconds: -1),
          position: Duration.zero,
          safetyMargin: const Duration(seconds: 30),
        ),
        isNull,
      );
    });

    test('clamps positions before and after the media range', () {
      expect(
        calculateRequiredWarmupValidity(
          duration: const Duration(minutes: 10),
          position: const Duration(seconds: -15),
          safetyMargin: const Duration(seconds: 30),
        ),
        const Duration(minutes: 10, seconds: 30),
      );
      expect(
        calculateRequiredWarmupValidity(
          duration: const Duration(minutes: 10),
          position: const Duration(minutes: 12),
          safetyMargin: const Duration(seconds: 30),
        ),
        const Duration(seconds: 30),
      );
    });

    test('rejects a negative safety margin', () {
      expect(
        () => calculateRequiredWarmupValidity(
          duration: const Duration(minutes: 10),
          position: Duration.zero,
          safetyMargin: const Duration(seconds: -1),
        ),
        throwsArgumentError,
      );
    });
  });

  group('warmup bundle coverage', () {
    test('accepts a primary valid strictly beyond the threshold', () {
      final candidate = bundle(
        primary: line(
          id: 'primary',
          expiresAt: preparedAt.add(const Duration(minutes: 10, seconds: 1)),
        ),
      );

      expect(
        warmupBundleCoversExpectedTransition(
          candidate,
          expectedEpisodeIdentity: 'subject:1|episode:2',
          now: preparedAt,
          requiredValidity: const Duration(minutes: 10),
        ),
        isTrue,
      );
    });

    test('rejects an expired or exactly-at-threshold primary', () {
      final expired = bundle(
        primary: line(
          id: 'expired',
          expiresAt: preparedAt.add(const Duration(minutes: 1)),
        ),
      );
      final boundary = bundle(
        primary: line(
          id: 'boundary',
          expiresAt: preparedAt.add(const Duration(minutes: 10)),
        ),
      );

      expect(
        warmupBundleCoversExpectedTransition(
          expired,
          expectedEpisodeIdentity: 'subject:1|episode:2',
          now: preparedAt.add(const Duration(minutes: 2)),
          requiredValidity: Duration.zero,
        ),
        isFalse,
      );
      expect(
        warmupBundleCoversExpectedTransition(
          boundary,
          expectedEpisodeIdentity: 'subject:1|episode:2',
          now: preparedAt,
          requiredValidity: const Duration(minutes: 10),
        ),
        isFalse,
      );
    });

    test('only requires a verified fallback when requested', () {
      final primary = line(
        id: 'primary',
        expiresAt: preparedAt.add(const Duration(minutes: 20)),
      );
      final noFallback = bundle(primary: primary);
      final staleFallback = bundle(
        primary: primary,
        fallbacks: <PlaybackLine>[
          line(
            id: 'fallback-boundary',
            providerId: 'zeluna:fallback',
            expiresAt: preparedAt.add(const Duration(minutes: 10)),
          ),
        ],
      );
      final validFallback = bundle(
        primary: primary,
        fallbacks: <PlaybackLine>[
          line(
            id: 'fallback-valid',
            providerId: 'zeluna:fallback',
            expiresAt: preparedAt.add(const Duration(minutes: 10, seconds: 1)),
            serverVerified: false,
            clientVerified: true,
          ),
        ],
      );

      for (final candidate in <NextEpisodeWarmupBundle>[
        noFallback,
        staleFallback,
      ]) {
        expect(
          warmupBundleCoversExpectedTransition(
            candidate,
            expectedEpisodeIdentity: 'subject:1|episode:2',
            now: preparedAt,
            requiredValidity: const Duration(minutes: 10),
          ),
          isTrue,
        );
        expect(
          warmupBundleCoversExpectedTransition(
            candidate,
            expectedEpisodeIdentity: 'subject:1|episode:2',
            now: preparedAt,
            requiredValidity: const Duration(minutes: 10),
            requireVerifiedFallback: true,
          ),
          isFalse,
        );
      }
      expect(
        warmupBundleCoversExpectedTransition(
          validFallback,
          expectedEpisodeIdentity: 'subject:1|episode:2',
          now: preparedAt,
          requiredValidity: const Duration(minutes: 10),
          requireVerifiedFallback: true,
        ),
        isTrue,
      );
    });

    test('rejects a negative required validity', () {
      final candidate = bundle(primary: line(id: 'primary', expiresAt: null));

      expect(
        () => warmupBundleCoversExpectedTransition(
          candidate,
          expectedEpisodeIdentity: 'subject:1|episode:2',
          now: preparedAt,
          requiredValidity: const Duration(seconds: -1),
        ),
        throwsArgumentError,
      );
    });

    test('rejects a bundle for a different episode identity', () {
      final candidate = bundle(primary: line(id: 'primary', expiresAt: null));

      expect(
        warmupBundleCoversExpectedTransition(
          candidate,
          expectedEpisodeIdentity: 'subject:1|episode:3',
          now: preparedAt,
          requiredValidity: Duration.zero,
        ),
        isFalse,
      );
    });
  });

  group('warmup transition inventory', () {
    test('keeps the primary and at most one valid fallback immutable', () {
      final primary = line(
        id: 'primary',
        expiresAt: preparedAt.add(const Duration(minutes: 20)),
      );
      final fallback = line(
        id: 'fallback',
        providerId: 'zeluna:fallback',
        expiresAt: preparedAt.add(const Duration(minutes: 20)),
      );
      final ignored = line(
        id: 'ignored',
        providerId: 'zeluna:ignored',
        expiresAt: preparedAt.add(const Duration(minutes: 20)),
      );
      final candidate = bundle(
        primary: primary,
        fallbacks: <PlaybackLine>[fallback, ignored],
      );

      final inventory = buildWarmupTransitionInventory(
        candidate,
        expectedEpisodeIdentity: 'subject:1|episode:2',
        now: preparedAt,
        minValidity: const Duration(minutes: 10),
      );

      expect(inventory, orderedEquals([same(primary), same(fallback)]));
      expect(() => inventory.add(ignored), throwsUnsupportedError);
    });

    test('drops a fallback that is exactly at the validity boundary', () {
      final primary = line(
        id: 'primary',
        expiresAt: preparedAt.add(const Duration(minutes: 20)),
      );
      final fallback = line(
        id: 'fallback-boundary',
        providerId: 'zeluna:fallback',
        expiresAt: preparedAt.add(const Duration(minutes: 10)),
      );
      final candidate = bundle(primary: primary, fallbacks: [fallback]);

      expect(
        buildWarmupTransitionInventory(
          candidate,
          expectedEpisodeIdentity: 'subject:1|episode:2',
          now: preparedAt,
          minValidity: const Duration(minutes: 10),
        ),
        orderedEquals([same(primary)]),
      );
    });

    test('promotes a valid fallback when the primary is stale', () {
      final primary = line(
        id: 'primary-boundary',
        expiresAt: preparedAt.add(const Duration(minutes: 10)),
      );
      final fallback = line(
        id: 'fallback-valid',
        providerId: 'zeluna:fallback',
        expiresAt: preparedAt.add(const Duration(minutes: 20)),
      );
      final candidate = bundle(primary: primary, fallbacks: [fallback]);

      final inventory = buildWarmupTransitionInventory(
        candidate,
        expectedEpisodeIdentity: 'subject:1|episode:2',
        now: preparedAt,
        minValidity: const Duration(minutes: 10),
      );

      expect(inventory, orderedEquals([same(fallback)]));
      expect(() => inventory.add(primary), throwsUnsupportedError);
    });

    test('accepts a client-verified route without a known expiry', () {
      final primary = line(
        id: 'client-primary',
        expiresAt: null,
        serverVerified: false,
        clientVerified: true,
      );
      final candidate = bundle(primary: primary);

      expect(
        buildWarmupTransitionInventory(
          candidate,
          expectedEpisodeIdentity: 'subject:1|episode:2',
          now: preparedAt,
          minValidity: const Duration(seconds: 30),
        ),
        orderedEquals([same(primary)]),
      );
    });
  });
}
