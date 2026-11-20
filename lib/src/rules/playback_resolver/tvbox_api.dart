part of '../rule_playback_resolver.dart';

// TVBox JSON/XML catalog search and episode resolution.

extension _TvBoxApiResolution on RulePlaybackResolver {
  Future<List<PlaybackLine>> _resolveTvBoxJsonApi(
    http.Client client,
    RulePlugin rule,
    AnimeSubject subject,
    AnimeEpisode episode,
    Stopwatch started, {
    required bool verifyPlayable,
  }) async {
    return _resolveTvBoxApi(
      client,
      rule,
      subject,
      episode,
      started,
      apiLabel: 'JSON',
      decodeItems: (text) => _tvBoxItems(jsonDecode(text)),
      verifyPlayable: verifyPlayable,
    );
  }

  Future<List<PlaybackLine>> _resolveTvBoxXmlApi(
    http.Client client,
    RulePlugin rule,
    AnimeSubject subject,
    AnimeEpisode episode,
    Stopwatch started, {
    required bool verifyPlayable,
  }) async {
    return _resolveTvBoxApi(
      client,
      rule,
      subject,
      episode,
      started,
      apiLabel: 'XML',
      decodeItems: _tvBoxXmlItems,
      verifyPlayable: verifyPlayable,
    );
  }

  Future<List<PlaybackLine>> _resolveTvBoxApi(
    http.Client client,
    RulePlugin rule,
    AnimeSubject subject,
    AnimeEpisode episode,
    Stopwatch started, {
    required String apiLabel,
    required List<Map<String, dynamic>> Function(String) decodeItems,
    required bool verifyPlayable,
  }) async {
    final endpoint = Uri.tryParse(rule.baseUrl.trim());
    if (endpoint == null || !endpoint.hasScheme || endpoint.host.isEmpty) {
      return [_unavailableLine(rule, subject, episode, '这个来源的地址不对，用不了。')];
    }

    final searches = <Future<_RankedResult<Map<String, dynamic>>?>>[];
    var preference = 0;
    for (final keyword in _searchKeywords(subject)) {
      for (final searchUri in _tvBoxSearchUris(
        endpoint,
        keyword,
        action: rule.rawConfig['searchAction']?.toString(),
      )) {
        searches.add(
          _searchTvBoxItem(
            client,
            rule,
            subject,
            endpoint,
            searchUri,
            preference++,
            decodeItems,
          ),
        );
      }
    }
    var item = await _firstConfidentResult(searches);
    if (item == null) {
      return [_unavailableLine(rule, subject, episode, '接口没有匹配到当前条目。')];
    }

    if (_tvBoxPlayUrl(item).isEmpty) {
      final vodId = item['vod_id']?.toString().trim() ?? '';
      if (vodId.isNotEmpty) {
        for (final detailUri in _tvBoxDetailUris(endpoint, vodId)) {
          try {
            final details = decodeItems(
              await _get(
                client,
                detailUri,
                _headers(rule: rule, referer: endpoint.toString()),
              ),
            );
            if (details.isEmpty) continue;
            // Some feeds return several records or reveal category/year only
            // on the detail response. Recheck identity before touching media.
            final matched = _rankBestTvBoxItem(
              [
                for (final detail in details)
                  if ((detail['vod_id']?.toString().trim() ?? '').isEmpty ||
                      detail['vod_id'].toString().trim() == vodId)
                    {...item!, ...detail},
              ],
              subject,
              0,
            );
            if (matched == null) continue;
            item = matched.value;
            if (_tvBoxPlayUrl(item).isNotEmpty) {
              break;
            }
          } catch (_) {
            // 聚合接口的 detail/videolist 支持并不一致，逐个尝试。
          }
        }
      }
    }

    final groups = _tvBoxPlayGroups(item);
    final lines = await _collectPlaybackCandidates(
      [
        for (var index = 0; index < groups.length; index++)
          () => _resolveTvBoxLine(
            client,
            rule,
            episode,
            endpoint,
            groups[index],
            started,
            verifyPlayable: verifyPlayable,
          ),
      ],
      verifyPlayable: verifyPlayable,
      candidateTimeout: timeout,
      pendingCandidate: (index) {
        final group = groups[index];
        final selected = _pickTvBoxEpisode(group.episodes, episode);
        if (selected == null) return null;
        final url = _normalizePlayableUrl(selected.url, endpoint.toString());
        if (!_looksPlayable(url)) return null;
        return _deadLine(
          rule,
          episode,
          url: url,
          title: '${selected.title} · ${group.name}',
          latency: null,
          message: '线路验证未完成，仍保留在完整列表中，可重新查找。',
          headers: _headers(rule: rule, referer: endpoint.toString()),
          routeKey: '${group.index}:${group.name}',
        );
      },
    );
    if (lines.isEmpty) {
      return [
        _unavailableLine(rule, subject, episode, '已找到条目，但当前集没有可直接播放的地址。'),
      ];
    }
    return lines;
  }

  Future<_RankedResult<Map<String, dynamic>>?> _searchTvBoxItem(
    http.Client client,
    RulePlugin rule,
    AnimeSubject subject,
    Uri endpoint,
    Uri searchUri,
    int preference,
    List<Map<String, dynamic>> Function(String) decodeItems,
  ) async {
    try {
      final items = decodeItems(
        await _get(
          client,
          searchUri,
          _headers(rule: rule, referer: endpoint.toString()),
        ),
      );
      return _rankBestTvBoxItem(items, subject, preference);
    } catch (_) {
      // TVBox 聚合接口格式并不完全一致，单个查询失败时让其他查询继续。
      return null;
    }
  }

  Future<PlaybackLine?> _resolveTvBoxLine(
    http.Client client,
    RulePlugin rule,
    AnimeEpisode episode,
    Uri endpoint,
    _TvBoxPlayGroup group,
    Stopwatch started, {
    required bool verifyPlayable,
  }) async {
    final selected = _pickTvBoxEpisode(group.episodes, episode);
    if (selected == null) return null;
    final playableUrl = _normalizePlayableUrl(
      selected.url,
      endpoint.toString(),
    );
    if (!_looksPlayable(playableUrl)) return null;
    final headers = _headers(rule: rule, referer: endpoint.toString());
    final title = group.name.trim().isEmpty
        ? selected.title
        : '${selected.title} · ${group.name}';
    final routeKey = '${group.index}:${group.name}';
    try {
      final probe = await _playableCandidateStatus(
        client,
        playableUrl,
        headers,
        verifyPlayable: verifyPlayable,
      );
      return probe.available
          ? _availableLine(
              rule,
              episode,
              url: playableUrl,
              title: title,
              probe: probe,
              referer: endpoint.toString(),
              headers: headers,
              routeKey: routeKey,
            )
          : _deadLine(
              rule,
              episode,
              url: playableUrl,
              title: title,
              latency: probe.latency,
              message: probe.message,
              headers: headers,
              routeKey: routeKey,
            );
    } catch (error) {
      if (_activeRulePlaybackResolveContext?.cancellationToken?.isCancelled ==
          true) {
        return null;
      }
      // Keep the route and explain policy/network failures; never relax its
      // media permissions just to make an inventory entry appear playable.
      return _deadLine(
        rule,
        episode,
        url: playableUrl,
        title: title,
        latency: started.elapsed,
        message: _friendlyError(error),
        headers: headers,
        routeKey: routeKey,
      );
    }
  }
}

List<Uri> _tvBoxSearchUris(Uri endpoint, String keyword, {String? action}) {
  final result = <String, Uri>{};
  // Some public MacCMS APIs accept keyword search only with ac=list.
  // A reviewed declaration avoids probing several redundant actions per title.
  final actions = const {'list', 'detail', 'videolist'}.contains(action)
      ? [action!]
      : const ['detail', 'videolist'];
  for (final action in actions) {
    final query = <String, String>{...endpoint.queryParameters}
      ..remove('ids')
      ..['ac'] = action
      ..['wd'] = keyword;
    final uri = endpoint.replace(queryParameters: query);
    result[uri.toString()] = uri;
  }
  return result.values.toList(growable: false);
}

List<Uri> _tvBoxDetailUris(Uri endpoint, String vodId) {
  final result = <String, Uri>{};
  for (final action in const ['detail', 'videolist']) {
    final query = <String, String>{...endpoint.queryParameters}
      ..remove('wd')
      ..['ac'] = action
      ..['ids'] = vodId;
    final uri = endpoint.replace(queryParameters: query);
    result[uri.toString()] = uri;
  }
  return result.values.toList(growable: false);
}

List<Map<String, dynamic>> _tvBoxItems(Object? decoded) {
  Object? value = decoded;
  if (value is Map) {
    value = value['list'] ?? value['data'] ?? value['items'];
    if (value is Map) value = value['list'] ?? value['items'];
  }
  if (value is! List) return const [];
  return value
      .whereType<Map>()
      .map((item) => item.cast<String, dynamic>())
      .toList(growable: false);
}

List<Map<String, dynamic>> _tvBoxXmlItems(String source) {
  final document = XmlDocument.parse(source);
  final videos = document.descendants.whereType<XmlElement>().where(
    (element) => element.name.local.toLowerCase() == 'video',
  );
  return videos
      .map((video) {
        final playSources = <String>[];
        final playGroups = <String>[];
        final downloads = video.descendants.whereType<XmlElement>().where(
          (element) => element.name.local.toLowerCase() == 'dd',
        );
        for (final download in downloads) {
          final playText = download.innerText.trim();
          if (playText.isEmpty) continue;
          playGroups.add(playText);
          final flag = download.getAttribute('flag')?.trim() ?? '';
          playSources.add(flag.isEmpty ? '线路${playSources.length + 1}' : flag);
        }
        return <String, dynamic>{
          'vod_id': _xmlChildText(video, const ['id', 'vod_id']),
          'vod_name': _xmlChildText(video, const ['name', 'vod_name', 'title']),
          'vod_play_from': playSources.join(r'$$$'),
          'vod_play_url': playGroups.join(r'$$$'),
        };
      })
      .toList(growable: false);
}

String _xmlChildText(XmlElement parent, List<String> names) {
  final normalized = names.map((name) => name.toLowerCase()).toSet();
  for (final child in parent.childElements) {
    if (normalized.contains(child.name.local.toLowerCase())) {
      return child.innerText.trim();
    }
  }
  return '';
}

_RankedResult<Map<String, dynamic>>? _rankBestTvBoxItem(
  List<Map<String, dynamic>> items,
  AnimeSubject subject,
  int preference,
) {
  if (items.isEmpty) return null;
  var best = items.first;
  var bestScore = -1;
  for (final item in items) {
    final title =
        item['vod_name']?.toString() ??
        item['name']?.toString() ??
        item['title']?.toString() ??
        '';
    final score = _tvBoxMatchScore(item, title, subject);
    if (score > bestScore) {
      best = item;
      bestScore = score;
    }
  }
  return bestScore <= 0
      ? null
      : _RankedResult(value: best, score: bestScore, preference: preference);
}

// General film/TV catalogues contain remakes, adaptations and commentary with
// the same title. Reject explicit conflicts, but keep legacy metadata-poor
// feeds usable. Anime ranking is unchanged by this live-action adaptation.
int _tvBoxMatchScore(
  Map<String, dynamic> item,
  String title,
  AnimeSubject subject,
) {
  final score = _matchScore(title, subject);
  final targetType = subjectContentTypeOf(subject);
  if (targetType == SubjectContentType.anime) return score;
  if (score < 80) return 0;
  final category = (item['type_name'] ?? item['type'] ?? '').toString();
  if (RegExp(r'解说|预告|花絮|短视频').hasMatch(category)) return 0;
  final candidateType = _tvBoxCategory(category);
  if (candidateType != null && candidateType != targetType) return 0;
  final expectedYear = _tvBoxYear(subject.date);
  final candidateYear = _tvBoxYear(item['vod_year'] ?? item['year']);
  if (expectedYear != null &&
      candidateYear != null &&
      expectedYear != candidateYear) {
    return 0;
  }
  return score +
      (candidateType == targetType ? 8 : 0) +
      (expectedYear != null && expectedYear == candidateYear ? 10 : 0);
}

int? _tvBoxYear(Object? value) => int.tryParse(
  RegExp(r'(?:19|20)\d{2}').firstMatch(value?.toString() ?? '')?.group(0) ?? '',
);

SubjectContentType? _tvBoxCategory(String value) {
  if (RegExp(r'电影|片|movie|film', caseSensitive: false).hasMatch(value)) {
    return SubjectContentType.movie;
  }
  if (RegExp(r'动漫|动画|anime', caseSensitive: false).hasMatch(value)) {
    return SubjectContentType.anime;
  }
  if (RegExp(
    r'电视剧|连续剧|国产剧|内地剧|大陆剧|欧美剧|香港剧|台湾剧|韩国剧|日本剧|海外剧|泰剧|陆剧|港剧|台剧|韩剧|日剧|美剧|综艺|series',
    caseSensitive: false,
  ).hasMatch(value)) {
    return SubjectContentType.series;
  }
  return null;
}

String _tvBoxPlayUrl(Map<String, dynamic>? item) {
  if (item == null) return '';
  return item['vod_play_url']?.toString() ??
      item['play_url']?.toString() ??
      item['url']?.toString() ??
      '';
}

List<_TvBoxPlayGroup> _tvBoxPlayGroups(Map<String, dynamic>? item) {
  final playText = _tvBoxPlayUrl(item).trim();
  if (playText.isEmpty) return const [];
  final sourceNames = (item?['vod_play_from']?.toString() ?? '').split(r'$$$');
  final groups = playText.split(r'$$$');
  final result = <_TvBoxPlayGroup>[];
  for (var groupIndex = 0; groupIndex < groups.length; groupIndex++) {
    final episodes = <_TvBoxEpisode>[];
    final rawEpisodes = groups[groupIndex].split('#');
    for (
      var episodeIndex = 0;
      episodeIndex < rawEpisodes.length;
      episodeIndex++
    ) {
      final raw = rawEpisodes[episodeIndex].trim();
      if (raw.isEmpty) continue;
      final separator = raw.indexOf(r'$');
      final title = separator < 0
          ? '第${episodeIndex + 1}集'
          : raw.substring(0, separator).trim();
      final url = separator < 0 ? raw : raw.substring(separator + 1).trim();
      if (url.isEmpty) continue;
      episodes.add(
        _TvBoxEpisode(
          title: title.isEmpty ? '第${episodeIndex + 1}集' : title,
          url: url,
        ),
      );
    }
    if (episodes.isEmpty) continue;
    result.add(
      _TvBoxPlayGroup(
        name: groupIndex < sourceNames.length
            ? sourceNames[groupIndex].trim()
            : '线路${groupIndex + 1}',
        episodes: episodes,
        index: groupIndex,
      ),
    );
  }
  return result;
}

_TvBoxEpisode? _pickTvBoxEpisode(
  List<_TvBoxEpisode> candidates,
  AnimeEpisode episode,
) {
  if (candidates.isEmpty) return null;
  final number = episode.number.toString();
  for (final candidate in candidates) {
    final title = _cleanText(candidate.title).toLowerCase();
    if (title == number ||
        title.contains('第$number') ||
        title.contains('ep$number') ||
        title.contains('e$number')) {
      return candidate;
    }
  }
  final index = episode.number - 1;
  if (index >= 0 && index < candidates.length) return candidates[index];
  return candidates.first;
}

class _TvBoxPlayGroup {
  const _TvBoxPlayGroup({
    required this.name,
    required this.episodes,
    required this.index,
  });

  final String name;
  final List<_TvBoxEpisode> episodes;
  final int index;
}

class _TvBoxEpisode {
  const _TvBoxEpisode({required this.title, required this.url});

  final String title;
  final String url;
}
