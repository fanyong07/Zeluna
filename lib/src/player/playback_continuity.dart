import '../data/playback_prefetch_cache.dart';
import '../domain/anime_models.dart';

/// Calculates how long a warmed route must remain valid before it can be used
/// for the expected episode transition.
///
/// An unknown or non-positive media duration returns `null` so callers do not
/// accidentally treat an unknown transition time as an immediate transition.
/// Positions outside the media range are clamped before the remaining time is
/// calculated.
Duration? calculateRequiredWarmupValidity({
  required Duration? duration,
  required Duration position,
  required Duration safetyMargin,
}) {
  _requireNonNegative(safetyMargin, 'safetyMargin');
  if (duration == null || duration <= Duration.zero) return null;

  final normalizedPosition = position < Duration.zero
      ? Duration.zero
      : position > duration
      ? duration
      : position;
  return duration - normalizedPosition + safetyMargin;
}

/// Whether [bundle] can safely cover the expected episode transition.
///
/// The primary route must still be available, verified, backed by an HTTP(S)
/// URL and valid strictly beyond the required threshold. When
/// [requireVerifiedFallback] is true, the bundle must also contain a fallback
/// that satisfies the same checks.
bool warmupBundleCoversExpectedTransition(
  NextEpisodeWarmupBundle bundle, {
  required String expectedEpisodeIdentity,
  required DateTime now,
  required Duration requiredValidity,
  bool requireVerifiedFallback = false,
}) {
  _requireNonNegative(requiredValidity, 'requiredValidity');
  if (!_matchesEpisodeIdentity(bundle, expectedEpisodeIdentity)) return false;
  if (!_isVerifiedRouteValidBeyond(bundle.primary, now, requiredValidity)) {
    return false;
  }
  if (!requireVerifiedFallback) return true;
  final fallback = bundle.fallback;
  return fallback != null &&
      _isVerifiedRouteValidBeyond(fallback, now, requiredValidity);
}

/// Builds the bounded route inventory consumed at an episode transition.
///
/// Invalid routes are removed at transition time. If the original primary is
/// stale but its verified fallback remains fresh, that fallback is promoted so
/// the player can recover without starting a cold discovery first. The
/// returned list cannot be mutated by its caller.
List<PlaybackLine> buildWarmupTransitionInventory(
  NextEpisodeWarmupBundle bundle, {
  required String expectedEpisodeIdentity,
  required DateTime now,
  required Duration minValidity,
}) {
  _requireNonNegative(minValidity, 'minValidity');
  if (!_matchesEpisodeIdentity(bundle, expectedEpisodeIdentity)) {
    return const <PlaybackLine>[];
  }
  return List<PlaybackLine>.unmodifiable(
    bundle.allLines
        .where((line) => _isVerifiedRouteValidBeyond(line, now, minValidity))
        .take(2),
  );
}

/// Re-checks the prepared fallback immediately before recovery.
///
/// The expected id prevents a newly discovered line from being mistaken for
/// the bounded warmup fallback, while the route checks prevent an expired or
/// unverified cached line from delaying cold discovery.
bool warmupFallbackReadyForImmediateRecovery(
  PlaybackLine? line, {
  required String? expectedLineId,
  required DateTime now,
  Duration minValidity = Duration.zero,
}) {
  _requireNonNegative(minValidity, 'minValidity');
  final expected = expectedLineId?.trim() ?? '';
  return expected.isNotEmpty &&
      line?.id == expected &&
      _isVerifiedRouteValidBeyond(line!, now, minValidity);
}

bool _matchesEpisodeIdentity(
  NextEpisodeWarmupBundle bundle,
  String expectedEpisodeIdentity,
) {
  final expected = expectedEpisodeIdentity.trim();
  return expected.isNotEmpty && bundle.episodeIdentity == expected;
}

bool _isVerifiedRouteValidBeyond(
  PlaybackLine line,
  DateTime now,
  Duration requiredValidity,
) {
  if (!line.available || (!line.serverVerified && !line.clientVerified)) {
    return false;
  }
  final rawUrl = line.url?.trim() ?? '';
  final uri = Uri.tryParse(rawUrl);
  if (uri == null ||
      !uri.hasAuthority ||
      (uri.scheme != 'http' && uri.scheme != 'https')) {
    return false;
  }
  final expiresAt = line.expiresAt;
  return expiresAt == null || expiresAt.isAfter(now.add(requiredValidity));
}

void _requireNonNegative(Duration value, String name) {
  if (value < Duration.zero) {
    throw ArgumentError.value(value, name, 'must not be negative');
  }
}
