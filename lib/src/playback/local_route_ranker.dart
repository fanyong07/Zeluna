import 'dart:async';

import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;

import '../core/network/media_request_headers.dart';
import '../core/network/network_security.dart';
import '../domain/anime_models.dart';
import '../sources/media_library_adapter.dart';

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
  static const _settingsKey = 'playback.localRouteRanker';

  final DateTime Function() _now;
  final double emaAlpha;
  final Duration adDemotionTtl;
  final int maxHosts;

  final Map<String, double> _hostLatencyMs = <String, double>{};
  final Map<String, DateTime> _adReportedKeys = <String, DateTime>{};
  Box<dynamic>? _settings;

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

  void loadFromSettings(Box<dynamic> settings) {
    _settings = settings;
    _hostLatencyMs.clear();
    _adReportedKeys.clear();
    final saved = settings.get(_settingsKey);
    if (saved is! Map) return;
    if (saved['hostLatencyMs'] case final Map hosts) {
      for (final entry in hosts.entries) {
        final ms = entry.value;
        if (entry.key is String && ms is num && ms >= 10 && ms <= 30000) {
          _hostLatencyMs[entry.key as String] = ms.toDouble();
        }
      }
      _trimHosts();
    }
    if (saved['adExpiryMs'] case final Map reports) {
      final nowMs = _now().millisecondsSinceEpoch;
      for (final entry in reports.entries) {
        final expiry = entry.value;
        if (entry.key is String &&
            expiry is int &&
            expiry > nowMs &&
            expiry <= nowMs + adDemotionTtl.inMilliseconds) {
          _adReportedKeys[entry.key as String] =
              DateTime.fromMillisecondsSinceEpoch(expiry);
        }
      }
    }
  }

  void _persist() {
    final settings = _settings;
    if (settings == null || !settings.isOpen) return;
    final now = _now();
    _adReportedKeys.removeWhere((_, expiry) => !expiry.isAfter(now));
    // Store no full playback URL or request headers, and never block playback.
    unawaited(
      settings
          .put(_settingsKey, {
            'hostLatencyMs': Map<String, double>.of(_hostLatencyMs),
            'adExpiryMs': _adReportedKeys.map(
              (key, expiry) => MapEntry(key, expiry.millisecondsSinceEpoch),
            ),
          })
          .onError((_, _) {}),
    );
  }

  void recordHostLatency(String? rawUrl, Duration latency) {
    final host = hostOf(rawUrl);
    final ms = latency.inMilliseconds.toDouble();
    if (host.isEmpty || ms < 10 || ms > 30000) return;
    final previous = _hostLatencyMs.remove(host);
    _hostLatencyMs[host] = previous == null
        ? ms
        : previous * (1 - emaAlpha) + ms * emaAlpha;
    _trimHosts();
    _persist();
  }

  void _trimHosts() {
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
    final host = line is MediaLibraryPlaybackLine ? '' : hostOf(line.url);
    if (host.isNotEmpty) {
      _adReportedKeys['host:$host'] = expiry;
    }
    final provider = line.providerId.trim().toLowerCase();
    if (provider.isNotEmpty) {
      _adReportedKeys['provider:$provider'] = expiry;
    }
    _persist();
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

    final host = line is MediaLibraryPlaybackLine ? '' : hostOf(line.url);
    if (host.isNotEmpty && active('host:$host')) return true;
    final provider = line.providerId.trim().toLowerCase();
    if (provider.isNotEmpty && active('provider:$provider')) return true;
    return false;
  }

  void clearAdReports() {
    _adReportedKeys.clear();
    _persist();
  }

  void resetForTesting() {
    _settings = null;
    _hostLatencyMs.clear();
    _adReportedKeys.clear();
  }

  RouteCleanlinessTier cleanlinessTierOf(PlaybackLine line) {
    if (isAdDemoted(line)) return RouteCleanlinessTier.adHeavy;
    if (line is MediaLibraryPlaybackLine) return RouteCleanlinessTier.clean;
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

  /// Compares response times of already verified routes on the device.
  /// A successful Range request is a timing sample, not media verification.
  Future<PlaybackLine?> raceFastestPlayable(
    Iterable<PlaybackLine> lines, {
    required http.Client client,
    int maxCandidates = 4,
    Duration timeout = const Duration(milliseconds: 2500),
  }) async {
    final candidates = lines
        .where(canRace)
        .take(maxCandidates)
        .toList(growable: false);
    if (candidates.length < 2) return null;

    final winner = Completer<PlaybackLine?>();
    var remaining = candidates.length;

    Future<void> probe(PlaybackLine candidate) async {
      final watch = Stopwatch()..start();
      try {
        final request = http.Request('GET', Uri.parse(candidate.url!.trim()))
          ..followRedirects = false
          ..headers.addAll(effectiveMediaRequestHeaders(candidate.headers))
          ..headers['Range'] = 'bytes=0-4095';
        final response = await client.send(request);
        watch.stop();
        // Upstreams may ignore Range and send a whole movie. Never drain it.
        final stream = response.stream.listen(null);
        unawaited(stream.cancel().onError((_, _) {}));
        if (winner.isCompleted) return;
        final status = response.statusCode;
        final contentType = (response.headers['content-type'] ?? '')
            .toLowerCase();
        if ((status == 200 || status == 206) &&
            !contentType.contains('html') &&
            !contentType.contains('json')) {
          recordHostLatency(candidate.url, watch.elapsed);
          winner.complete(candidate);
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
    return winner.future.timeout(
      timeout,
      onTimeout: () {
        if (!winner.isCompleted) winner.complete(null);
        return null;
      },
    );
  }

  static bool canRace(PlaybackLine line) {
    if (line is MediaLibraryPlaybackLine) return false;
    final uri = Uri.tryParse(line.url?.trim() ?? '');
    return line.available &&
        (line.clientVerified || line.serverVerified) &&
        !line.requiresClientProbe &&
        !line.isLive &&
        uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        !line.headers.keys.any(isSensitiveNetworkHeader);
  }
}
