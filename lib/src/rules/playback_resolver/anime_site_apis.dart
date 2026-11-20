part of '../rule_playback_resolver.dart';

// Site-specific Aikanbot and Sorani search and playback APIs.

extension _AnimeSiteApiResolution on RulePlaybackResolver {
  /// Aikanbot exposes its HLS inventory through a documented page-side JSON
  /// request.  Calling that endpoint avoids loading its ad-funded player while
  /// keeping the same search and episode selection users see in the browser.
  Future<List<PlaybackLine>> _resolveAikanbotApi(
    http.Client client,
    RulePlugin rule,
    AnimeSubject subject,
    AnimeEpisode episode, {
    required bool verifyPlayable,
  }) async {
    final detailUrl = await _findAikanbotDetailUrl(client, rule, subject);
    if (detailUrl == null) {
      return [_unavailableLine(rule, subject, episode, '没有匹配到当前条目。')];
    }
    final detailHtml = await _get(
      client,
      detailUrl,
      _headers(rule: rule, referer: rule.baseUrl),
    );
    final root = _documentRoot(detailHtml);
    final videoId =
        root.querySelector('#current_id')?.attributes['value'] ?? '';
    final encryptedToken =
        root.querySelector('#e_token')?.attributes['value'] ?? '';
    final mediaType = root.querySelector('#mtype')?.attributes['value'] ?? '';
    final token = _aikanbotToken(videoId, encryptedToken);
    if (videoId.isEmpty || mediaType.isEmpty || token.isEmpty) {
      return [_unavailableLine(rule, subject, episode, '播放清单参数无效。')];
    }
    final inventoryUrl = detailUrl.replace(
      path: '/api/getResN',
      queryParameters: {'videoId': videoId, 'mtype': mediaType, 'token': token},
    );
    final decoded = jsonDecode(
      await _get(
        client,
        inventoryUrl,
        _headers(rule: rule, referer: detailUrl.toString()),
      ),
    );
    if (decoded is! Map || decoded['state'] != 1) {
      return [_unavailableLine(rule, subject, episode, '播放清单暂时不可用。')];
    }
    final data = decoded['data'];
    final rawLines = data is Map && data['list'] is List
        ? (data['list'] as List)
        : const <Object?>[];
    final candidates = <String>[];
    for (final rawLine in rawLines) {
      if (rawLine is! Map) continue;
      final url = _aikanbotEpisodeUrl(rawLine['resData'], episode.number);
      if (url != null) candidates.add(url);
      // The quick collector already bounds its first wave. Keep the complete
      // inventory here so expanded lookup can visit every upstream group.
    }
    if (candidates.isEmpty) {
      return [_unavailableLine(rule, subject, episode, '没有找到当前集的 HLS 线路。')];
    }
    final headers = _headers(rule: rule, referer: detailUrl.toString());
    final lines = await _collectPlaybackCandidates(
      [
        for (var index = 0; index < candidates.length; index++)
          () async {
            final url = candidates[index];
            final title = '${episode.displayTitle} · 线路 ${index + 1}';
            try {
              final probe = await _playableCandidateStatus(
                client,
                url,
                headers,
                verifyPlayable: verifyPlayable,
              );
              return probe.available
                  ? _availableLine(
                      rule,
                      episode,
                      url: url,
                      title: title,
                      probe: probe,
                      referer: detailUrl.toString(),
                      headers: headers,
                      routeKey: '$index',
                    )
                  : _deadLine(
                      rule,
                      episode,
                      url: url,
                      title: title,
                      latency: probe.latency,
                      message: probe.message,
                      headers: headers,
                      routeKey: '$index',
                    );
            } catch (error) {
              if (_activeRulePlaybackResolveContext
                      ?.cancellationToken
                      ?.isCancelled ==
                  true) {
                return null;
              }
              return _deadLine(
                rule,
                episode,
                url: url,
                title: title,
                latency: null,
                message: _friendlyError(error),
                headers: headers,
                routeKey: '$index',
              );
            }
          },
      ],
      verifyPlayable: verifyPlayable,
      candidateTimeout: timeout,
      pendingCandidate: (index) => _deadLine(
        rule,
        episode,
        url: candidates[index],
        title: '${episode.displayTitle} · 线路 ${index + 1}',
        latency: null,
        message: '线路验证未完成，仍保留在完整列表中，可重新查找。',
        headers: headers,
        routeKey: '$index',
      ),
    );
    return lines.isEmpty
        ? [_unavailableLine(rule, subject, episode, '播放线路验证失败。')]
        : lines;
  }

  Future<Uri?> _findAikanbotDetailUrl(
    http.Client client,
    RulePlugin rule,
    AnimeSubject subject,
  ) async {
    for (final keyword in _searchKeywords(subject)) {
      final searchUrl = Uri.parse(
        '${rule.baseUrl.replaceFirst(RegExp(r'/+$'), '')}/search',
      ).replace(queryParameters: {'q': keyword});
      final root = _documentRoot(
        await _get(
          client,
          searchUrl,
          _headers(rule: rule, referer: rule.baseUrl),
        ),
      );
      final hits = [
        for (final node in root.querySelectorAll('a.title-text'))
          _SearchHit(
            title: _cleanText(node.text),
            url: _absoluteUrl(node.attributes['href'] ?? '', rule.baseUrl),
          ),
      ].where((hit) => hit.title.isNotEmpty && hit.url.isNotEmpty).toList();
      final best = _rankBestHit(hits, subject, 0);
      if (best != null) return Uri.tryParse(best.value.url);
    }
    return null;
  }

  /// 青空次元的网页播放器会在播放时向其公开播放清单接口请求一个
  /// 短时 HLS 地址。这里复用同一套搜索、详情和清单流程，而不保存
  /// 会过期的媒体 URL。
  Future<List<PlaybackLine>> _resolveSoraniApi(
    http.Client client,
    RulePlugin rule,
    AnimeSubject subject,
    AnimeEpisode episode, {
    required bool verifyPlayable,
  }) async {
    final detailUrl = await _findSoraniDetailUrl(client, rule, subject);
    if (detailUrl == null) {
      return [_unavailableLine(rule, subject, episode, '没有匹配到当前条目。')];
    }

    final apiHeaders = _soraniHeaders(rule);
    final decoded = jsonDecode(await _get(client, detailUrl, apiHeaders));
    final detail = _soraniData(decoded);
    final episodes = detail?['episodes'];
    if (episodes is! List) {
      return [_unavailableLine(rule, subject, episode, '详情页没有返回剧集列表。')];
    }
    final selected = _pickSoraniEpisode(episodes, episode.number);
    final episodeId = _soraniInt(selected?['episodeId']);
    if (episodeId == null) {
      return [_unavailableLine(rule, subject, episode, '没有匹配到当前集。')];
    }
    if (selected?['isVip'] == true) {
      return [_unavailableLine(rule, subject, episode, '这一集要站点会员才能看。')];
    }

    final lineCode = rule.rawConfig['lineCode']?.toString().trim();
    final apiRoot = Uri.parse(rule.baseUrl.replaceFirst(RegExp(r'/+$'), ''));
    final playUrl = apiRoot.replace(
      path: '${apiRoot.path}/api/video/episode/$episodeId/play',
      queryParameters: {
        'lineCode': lineCode == null || lineCode.isEmpty
            ? 'anime_jp_m3u8'
            : lineCode,
      },
    );
    final playDecoded = jsonDecode(await _get(client, playUrl, apiHeaders));
    final playback = _soraniData(playDecoded);
    final mediaUrl = playback?['playUrl']?.toString().trim() ?? '';
    if (playback?['canPlay'] != true || !_looksPlayable(mediaUrl)) {
      return [_unavailableLine(rule, subject, episode, '播放清单暂时不可用。')];
    }

    final probe = await _playableCandidateStatus(
      client,
      mediaUrl,
      apiHeaders,
      verifyPlayable: verifyPlayable,
    );
    final title = '${episode.displayTitle} · 青空线路';
    return [
      probe.available
          ? _availableLine(
              rule,
              episode,
              url: mediaUrl,
              title: title,
              probe: probe,
              referer: apiHeaders['Referer'] ?? rule.baseUrl,
              headers: apiHeaders,
            )
          : _deadLine(
              rule,
              episode,
              url: mediaUrl,
              title: title,
              latency: probe.latency,
              message: probe.message,
              headers: apiHeaders,
            ),
    ];
  }

  Future<Uri?> _findSoraniDetailUrl(
    http.Client client,
    RulePlugin rule,
    AnimeSubject subject,
  ) async {
    final root = Uri.parse(rule.baseUrl.replaceFirst(RegExp(r'/+$'), ''));
    for (final keyword in _searchKeywords(subject)) {
      final searchUrl = root.replace(
        path: '${root.path}/api/video',
        queryParameters: {
          'page': '1',
          'size': '20',
          'keyword': keyword,
          'enabled': 'true',
          'sortMode': 'latest',
          'sortDesc': 'true',
        },
      );
      final decoded = jsonDecode(
        await _get(client, searchUrl, _soraniHeaders(rule)),
      );
      final data = _soraniData(decoded);
      final records = data?['records'];
      if (records is! List) continue;
      final hits = <_SearchHit>[
        for (final record in records)
          if (record is Map)
            (() {
              final title = record['title']?.toString().trim() ?? '';
              final alias = record['alias']?.toString().trim() ?? '';
              final id = _soraniInt(record['id']);
              return _SearchHit(
                title: [
                  title,
                  alias,
                ].where((part) => part.isNotEmpty).join(' '),
                url: id == null ? '' : id.toString(),
              );
            })(),
      ].where((hit) => hit.title.isNotEmpty && hit.url.isNotEmpty).toList();
      final best = _rankBestHit(hits, subject, 0);
      if (best == null) continue;
      return root.replace(path: '${root.path}/api/video/${best.value.url}');
    }
    return null;
  }

  Map<String, dynamic>? _soraniData(Object? decoded) {
    if (decoded is! Map) return null;
    final data = decoded['data'];
    return data is Map ? data.cast<String, dynamic>() : null;
  }

  Map<String, dynamic>? _pickSoraniEpisode(List<dynamic> episodes, int number) {
    for (final raw in episodes) {
      if (raw is! Map) continue;
      final order = raw['episodeOrder'];
      if (order is num && order.round() == number) {
        return raw.cast<String, dynamic>();
      }
    }
    final index = number - 1;
    if (index >= 0 && index < episodes.length && episodes[index] is Map) {
      return (episodes[index] as Map).cast<String, dynamic>();
    }
    return null;
  }

  int? _soraniInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  Map<String, String> _soraniHeaders(RulePlugin rule) => {
    ..._headers(rule: rule, referer: 'https://www.sorani.net/'),
    'Origin': 'https://www.sorani.net',
    'Accept': 'application/json, text/plain, */*',
  };
}

String _aikanbotToken(String videoId, String encryptedToken) {
  if (videoId.length < 4 || encryptedToken.isEmpty) return '';
  var remaining = encryptedToken;
  final chunks = <String>[];
  for (final digit in videoId.substring(videoId.length - 4).codeUnits) {
    if (digit < 48 || digit > 57) return '';
    final offset = (digit - 48) % 3 + 1;
    if (remaining.length < offset + 8) return '';
    chunks.add(remaining.substring(offset, offset + 8));
    remaining = remaining.substring(offset + 8);
  }
  return chunks.join();
}

String? _aikanbotEpisodeUrl(Object? raw, int episodeNumber) {
  if (raw is! String || raw.trim().isEmpty || episodeNumber < 1) return null;
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  if (decoded is! List) return null;
  for (final group in decoded) {
    if (group is! Map) continue;
    final entries = group['url']?.toString().split('#') ?? const <String>[];
    if (episodeNumber > entries.length) continue;
    final pair = entries[episodeNumber - 1].split(r'$');
    if (pair.length < 2) continue;
    final url = pair.sublist(1).join(r'$').trim();
    if (_looksPlayable(url)) return url;
  }
  return null;
}
