import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/identity/stable_identity.dart';
import '../core/network/network_http_client.dart';
import '../core/network/network_security.dart';
import '../domain/anime_models.dart';
import '../domain/subject_content_type.dart';
import '../rules/rule_playback_resolver.dart';
import '../sources/external_source_adapters.dart' show SourceUriPolicy;

/// Native client protocol adapter, not downloaded code and not a rule install.
/// Only the expressly selected source is queried; no silent VPS fallback.
class LocalMacCmsPlayback {
  LocalMacCmsPlayback({
    http.Client? client,
    RulePlaybackResolver? verifier,
    this.lookupBudget = const Duration(seconds: 30),
  }) : _client =
           client ??
           createNetworkHttpClient(
             const NetworkRequestPolicy(
               service: NetworkServiceKind.rulePage,
               httpsOnly: true,
               allowPrivateNetwork: false,
               maxResponseBytes: 2 * 1024 * 1024,
               requestTimeout: Duration(seconds: 10),
               rejectRedirects: true,
             ),
           ),
       _ownsClient = client == null,
       _verifier = verifier ?? RulePlaybackResolver();

  final Duration lookupBudget;
  final http.Client _client;
  final bool _ownsClient;
  final RulePlaybackResolver _verifier;

  Future<List<PlaybackLine>> lookup({
    required Map<String, dynamic> descriptor,
    required PlaybackLine source,
    required AnimeSubject subject,
    required AnimeEpisode episode,
    RulePlaybackCancellationToken? cancellationToken,
  }) async {
    final endpoint = Uri.tryParse(descriptor['endpoint']?.toString() ?? '');
    if (!source.clientQuerySupported ||
        !RegExp(
          r'^registered:[a-f0-9]{24}$',
        ).hasMatch(source.sourceInventoryId) ||
        descriptor['inventory_source_id'] != source.sourceInventoryId ||
        descriptor['protocol'] != 'maccms-json' ||
        endpoint == null ||
        endpoint.scheme != 'https' ||
        endpoint.hasQuery ||
        endpoint.hasFragment ||
        (endpoint.hasPort && endpoint.port != 443) ||
        !const SourceUriPolicy().isAllowed(endpoint)) {
      throw StateError('本机查询配置不在允许范围内');
    }
    final token = RulePlaybackCancellationToken();
    final unregisterParent = cancellationToken?.register(token.cancel);
    final unregisterClient = token.register(() {
      if (_ownsClient) _client.close();
    });
    try {
      return await _lookup(endpoint, source, subject, episode, token).timeout(
        lookupBudget,
        onTimeout: () {
          final cancelledByUser = cancellationToken?.isCancelled == true;
          token.cancel();
          return cancelledByUser
              ? const <PlaybackLine>[]
              : [
                  _status(
                    source,
                    episode,
                    PlaybackDiscoveryStatus.searchTimeout,
                    '本机查询超时；未改用 VPS',
                  ),
                ];
        },
      );
    } finally {
      unregisterParent?.call();
      unregisterClient();
    }
  }

  Future<List<PlaybackLine>> _lookup(
    Uri endpoint,
    PlaybackLine source,
    AnimeSubject subject,
    AnimeEpisode episode,
    RulePlaybackCancellationToken cancellationToken,
  ) async {
    bool cancelled() => cancellationToken.isCancelled;
    try {
      if (cancelled()) return const [];
      Map<String, dynamic>? matched;
      for (final title in {
        subject.title.trim(),
        subject.originalTitle.trim(),
      }.where((t) => t.isNotEmpty)) {
        final items = await _items(
          endpoint.replace(queryParameters: {'ac': 'detail', 'wd': title}),
        );
        if (cancelled()) return const [];
        for (final item in items) {
          if (!_matches(item, subject)) continue;
          matched = item;
          break;
        }
        if (matched != null) break;
      }
      if (matched == null) {
        return [
          _status(
            source,
            episode,
            PlaybackDiscoveryStatus.searchMiss,
            '本机搜索没有匹配到当前作品',
          ),
        ];
      }
      if ((matched['vod_play_url']?.toString() ?? '').isEmpty) {
        final id = matched['vod_id']?.toString() ?? '';
        if (id.isNotEmpty) {
          final details = await _items(
            endpoint.replace(queryParameters: {'ac': 'detail', 'ids': id}),
          );
          if (cancelled()) return const [];
          matched =
              details.where((i) => _matches(i, subject)).firstOrNull ?? matched;
        }
      }
      final candidates = _candidates(
        matched,
        endpoint,
        source,
        subject,
        episode,
      );
      if (candidates.isEmpty) {
        return [
          _status(
            source,
            episode,
            PlaybackDiscoveryStatus.matchedNoEpisode,
            '本机已匹配作品，但未取得当前集',
          ),
        ];
      }
      final verified = <PlaybackLine>[];
      // Three concurrent probes, each retains its own public-resource policy.
      for (var i = 0; i < candidates.length && !cancelled(); i += 3) {
        verified.addAll(
          await Future.wait(
            candidates
                .skip(i)
                .take(3)
                .map(
                  (line) => _verifier.verifyPlaybackLine(
                    line: line,
                    forceRefresh: true,
                    cancellationToken: cancellationToken,
                  ),
                ),
          ),
        );
      }
      return cancelled() ? const [] : verified;
    } catch (_) {
      if (cancelled()) return const [];
      return [
        _status(
          source,
          episode,
          PlaybackDiscoveryStatus.searchError,
          '本机请求失败；未改用 VPS，也未降低安全校验',
        ),
      ];
    }
  }

  Future<List<Map<String, dynamic>>> _items(Uri uri) async {
    final response = await _client
        .get(uri, headers: const {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200 ||
        response.bodyBytes.length > 2 * 1024 * 1024) {
      throw StateError('本机请求失败');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final items = decoded is Map ? decoded['list'] : null;
    if (items is! List || items.length > 500) throw StateError('不是支持的采集接口');
    return items
        .whereType<Map>()
        .map((item) => item.cast<String, dynamic>())
        .toList(growable: false);
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}

String _titleKey(String title) => title.toLowerCase().replaceAll(
  RegExp(r'[\s\p{P}\p{S}]', unicode: true),
  '',
);

bool _matches(Map<String, dynamic> item, AnimeSubject subject) {
  final title = _titleKey(item['vod_name']?.toString() ?? '');
  if (title.isEmpty ||
      !{
        _titleKey(subject.title),
        _titleKey(subject.originalTitle),
      }.contains(title)) {
    return false;
  }
  final year = int.tryParse(item['vod_year']?.toString() ?? '');
  final expectedYear = int.tryParse(subject.year);
  if (year != null && expectedYear != null && year != expectedYear) {
    return false;
  }
  final type = (item['type_name']?.toString() ?? '').toLowerCase();
  if (type.isEmpty) {
    return true; // Some APIs omit categories; title/year stay strict.
  }
  final movie =
      type.contains('电影') ||
      type.contains('影片') ||
      type.endsWith('片') ||
      type.contains('movie') ||
      type.contains('film');
  final anime =
      type.contains('动漫') || type.contains('动画') || type.contains('anime');
  final series =
      (type.contains('剧') && !type.contains('剧场')) ||
      type.contains('series') ||
      type.contains('drama');
  return switch (subjectContentTypeOf(subject)) {
    SubjectContentType.anime => anime && !movie,
    SubjectContentType.series => series && !anime && !movie,
    SubjectContentType.movie => movie && !series,
  };
}

List<PlaybackLine> _candidates(
  Map<String, dynamic> item,
  Uri endpoint,
  PlaybackLine source,
  AnimeSubject subject,
  AnimeEpisode episode,
) {
  final text = item['vod_play_url']?.toString() ?? '';
  if (text.length > 1024 * 1024) return const [];
  final groups = text.split(r'$$$');
  final names = (item['vod_play_from']?.toString() ?? '').split(r'$$$');
  final lines = <PlaybackLine>[];
  for (var i = 0; i < groups.length && i < 128; i++) {
    final episodes = groups[i].split('#');
    String? selected;
    String label = '';
    for (final raw in episodes.take(3000)) {
      final separator = raw.indexOf(r'$');
      if (separator < 0) continue;
      final title = raw.substring(0, separator).trim();
      final number = int.tryParse(
        RegExp(r'^(?:第)?0*(\d+)(?:集|话|期)?$').firstMatch(title)?.group(1) ?? '',
      );
      final movie =
          subjectContentTypeOf(subject) == SubjectContentType.movie &&
          episode.number == 1 &&
          episodes.length == 1;
      if (number != episode.number && !movie) continue;
      selected = raw.substring(separator + 1).trim();
      label = title;
      break;
    }
    if (selected == null) continue;
    final uri = Uri.tryParse(selected);
    if (uri == null || !const SourceUriPolicy().isAllowed(uri)) continue;
    final route = i < names.length ? names[i] : '线路${i + 1}';
    lines.add(
      PlaybackLine(
        id: 'local:${stableDigest('${source.sourceInventoryId}|${episode.id}|$i|$uri')}',
        episodeId: episode.id,
        providerId: source.providerId,
        providerName: source.providerName,
        sourceName: source.sourceName,
        sourceInventoryId: source.sourceInventoryId,
        clientQuerySupported: true,
        queryLocation: 'local',
        title: '$label · $route',
        quality: '',
        format: 'auto',
        url: uri.toString(),
        headers: {'Referer': endpoint.toString()},
        publicHttpOnly: true,
        available: false,
        requiresClientProbe: true,
        diagnosticStatus: PlaybackDiscoveryStatus.clientProbeRequired,
        queried: true,
        matched: true,
        episodeFound: true,
        message: '本机已取得候选，仍需实际媒体验证',
      ),
    );
  }
  return lines;
}

PlaybackLine _status(
  PlaybackLine source,
  AnimeEpisode episode,
  String status,
  String message,
) => PlaybackLine(
  id: 'local-status:${source.sourceInventoryId}:${episode.id}',
  episodeId: episode.id,
  providerId: source.providerId,
  providerName: source.providerName,
  sourceName: source.sourceName,
  sourceInventoryId: source.sourceInventoryId,
  clientQuerySupported: true,
  queryLocation: 'local',
  title: source.sourceName,
  quality: '',
  format: '',
  diagnosticStatus: status,
  queried: true,
  message: message,
);
