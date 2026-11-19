import 'dart:async';

import 'package:http/http.dart' as http;

import '../core/network/media_request_headers.dart';
import '../domain/anime_models.dart';

/// Cleanliness tier for automatic route selection.
///
/// - [clean] (Tier 0): local files, private media libraries, managed lines, and
///   known ad-free direct/community anime sources.
/// - [cleanable] (Tier 1): ordinary HLS/MP4 routes or unknown hosts.
/// - [adHeavy] (Tier 2): hosts/providers reported by the user as carrying ads
///   (7-day TTL) or known uncleaned burned-in ad collection sources.
enum RouteCleanlinessTier { clean, cleanable, adHeavy }

/// Tracks on-device CDN host speed (EMA) and user-reported ad sources, and
/// races top candidates directly from the user's real network.
final class LocalRouteRanker {
  LocalRouteRanker({
    DateTime Function()? now,
    this.emaAlpha = 0.35,
    this.adDemotionTtl = const Duration(days: 7),
    this.maxHosts = 256,
  }) : _now = now ?? DateTime.now;

  static final LocalRouteRanker instance = LocalRouteRanker();

  final DateTime Function() _now;
  final double emaAlpha;
  final Duration adDemotionTtl;
  final int maxHosts;

  final Map<String, double> _hostLatencyMs = <String, double>{};
  final Map<String, DateTime> _adReportedKeys = <String, DateTime>{};

  static const _cleanProviderTokens = <String>[
    'local',
    'offline',
    'managed',
    'emby',
    'jellyfin',
    'webdav',
    'alist',
    'kazumi',
    'animeko',
    'girigiri',
    'nivod',
    'ppnix',
  ];

  static String hostOf(String? rawUrl) {
    final uri = Uri.tryParse((rawUrl ?? '').trim());
    return uri?.host.toLowerCase() ?? '';
  }

  void recordHostLatency(String? rawUrl, Duration latency) {
    final host = hostOf(rawUrl);
    final ms = latency.inMilliseconds.toDouble();
    if (host.isEmpty || ms < 10 || ms > 30000) return;
    final previous = _hostLatencyMs.remove(host);
    _hostLatencyMs[host] = previous == null
        ? ms
        : previous * (1 - emaAlpha) + ms * emaAlpha;
    while (_hostLatencyMs.length > maxHosts) {
      _hostLatencyMs.remove(_hostLatencyMs.keys.first);
    }
  }

  Duration? predictedLatency(String? rawUrl) {
    final host = hostOf(rawUrl);
    if (host.isEmpty) return null;
    final ms = _hostLatencyMs[host];
    return ms == null ? null : Duration(milliseconds: ms.round());
  }

  void markLineAsAd(PlaybackLine line) {
    final expiry = _now().add(adDemotionTtl);
    final host = hostOf(line.url);
    if (host.isNotEmpty) {
      _adReportedKeys['host:$host'] = expiry;
    }
    final provider = line.providerId.trim().toLowerCase();
    if (provider.isNotEmpty) {
      _adReportedKeys['provider:$provider'] = expiry;
    }
  }

  bool isAdDemoted(PlaybackLine line) {
    final current = _now();
    bool active(String key) {
      final expiry = _adReportedKeys[key];
      if (expiry == null) return false;
      if (!expiry.isAfter(current)) {
        _adReportedKeys.remove(key);
        return false;
      }
      return true;
    }

    final host = hostOf(line.url);
    if (host.isNotEmpty && active('host:$host')) return true;
    final provider = line.providerId.trim().toLowerCase();
    if (provider.isNotEmpty && active('provider:$provider')) return true;
    return false;
  }

  void clearAdReports() => _adReportedKeys.clear();

  void resetForTesting() {
    _hostLatencyMs.clear();
    _adReportedKeys.clear();
  }

  RouteCleanlinessTier cleanlinessTierOf(PlaybackLine line) {
    if (isAdDemoted(line)) return RouteCleanlinessTier.adHeavy;
    final rawUrl = (line.url ?? '').trim().toLowerCase();
    if (rawUrl.startsWith('file://')) return RouteCleanlinessTier.clean;
    final idTokens =
        '${line.providerId} ${line.providerName} ${line.sourceName}'
            .toLowerCase();
    if (_cleanProviderTokens.any(idTokens.contains)) {
      return RouteCleanlinessTier.clean;
    }
    return RouteCleanlinessTier.cleanable;
  }

  /// Races up to [maxCandidates] playable candidates directly from the user's
  /// device network (small byte-range GET) and returns the fastest valid route.
  Future<PlaybackLine?> raceFastestPlayable(
    Iterable<PlaybackLine> lines, {
    required http.Client client,
    int maxCandidates = 4,
    Duration timeout = const Duration(milliseconds: 2500),
  }) async {
    final candidates = [
      for (final line in lines)
        if ((line.url?.trim().isNotEmpty ?? false) &&
            (line.url!.trim().startsWith('http://') ||
                line.url!.trim().startsWith('https://')))
          line,
    ].take(maxCandidates).toList(growable: false);
    if (candidates.isEmpty) return null;
    if (candidates.length == 1) return candidates.first;

    final winner = Completer<PlaybackLine?>();
    var remaining = candidates.length;

    Future<void> probe(PlaybackLine candidate) async {
      final uri = Uri.tryParse(candidate.url!.trim());
      if (uri == null) return;
      final watch = Stopwatch()..start();
      try {
        final request = http.Request('GET', uri)
          ..headers.addAll(effectiveMediaRequestHeaders(candidate.headers))
          ..headers['Range'] = 'bytes=0-4095';
        final response = await client.send(request).timeout(timeout);
        final status = response.statusCode;
        final contentType = (response.headers['content-type'] ?? '')
            .toLowerCase();
        unawaited(response.stream.drain<void>().catchError((_) {}));
        watch.stop();
        if ((status == 200 || status == 206) &&
            !contentType.contains('text/html')) {
          recordHostLatency(candidate.url, watch.elapsed);
          if (!winner.isCompleted) {
            winner.complete(
              PlaybackLine(
                id: candidate.id,
                episodeId: candidate.episodeId,
                providerId: candidate.providerId,
                providerName: candidate.providerName,
                title: candidate.title,
                quality: candidate.quality,
                format: candidate.format,
                url: candidate.url,
                headers: candidate.headers,
                latency: watch.elapsed,
                sizeLabel: candidate.sizeLabel,
                sizeBytes: candidate.sizeBytes,
                sizeEstimated: candidate.sizeEstimated,
                videoWidth: candidate.videoWidth,
                videoHeight: candidate.videoHeight,
                bitrate: candidate.bitrate,
                codecs: candidate.codecs,
                isLive: candidate.isLive,
                adaptive: candidate.adaptive,
                publicHttpOnly: candidate.publicHttpOnly,
                serverVerified: candidate.serverVerified,
                requiresClientProbe: false,
                clientVerified: true,
                startupProfile: candidate.startupProfile,
                cacheState: candidate.cacheState,
                sourceErrorCategory: candidate.sourceErrorCategory,
                sourceName: candidate.sourceName,
                sourceInventoryId: candidate.sourceInventoryId,
                clientQuerySupported: candidate.clientQuerySupported,
                queryLocation: candidate.queryLocation,
                sourceAddress: candidate.sourceAddress,
                diagnosticStatus: candidate.diagnosticStatus,
                queried: candidate.queried,
                aliasesAttempted: candidate.aliasesAttempted,
                searchHitCount: candidate.searchHitCount,
                bestMatchScore: candidate.bestMatchScore,
                matched: candidate.matched,
                episodeFound: candidate.episodeFound,
                discoveryElapsed: candidate.discoveryElapsed,
                expiresAt: candidate.expiresAt,
                available: true,
                message: candidate.message,
              ),
            );
          }
        }
      } catch (_) {
        // Ignore individual probe failure; fastest valid peer wins.
      } finally {
        remaining--;
        if (remaining == 0 && !winner.isCompleted) {
          winner.complete(null);
        }
      }
    }

    for (final candidate in candidates) {
      unawaited(probe(candidate));
    }
    return winner.future.timeout(timeout, onTimeout: () => null);
  }
}
