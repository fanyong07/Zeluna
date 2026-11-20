part of '../rule_playback_resolver.dart';

// Kazumi and XBPQ page rules and shared HTML/media URL helpers.

extension _PageSourceResolution on RulePlaybackResolver {
  Future<List<PlaybackLine>> _resolveKazumi(
    http.Client client,
    RulePlugin rule,
    AnimeSubject subject,
    AnimeEpisode episode,
    Stopwatch started, {
    required bool verifyPlayable,
  }) async {
    final config = rule.kazumi;
    if (config == null) {
      return [_unavailableLine(rule, subject, episode, '这个来源的解析设置不全，用不了。')];
    }

    final detailUrl = await _findKazumiDetailUrl(client, rule, config, subject);
    if (detailUrl == null) {
      return [_unavailableLine(rule, subject, episode, '没有匹配到当前条目的详情页。')];
    }

    if (config.chapterMode.toLowerCase() == 'api') {
      return _resolveKazumiApiChapters(
        client,
        rule,
        config,
        episode,
        detailUrl.toString(),
        verifyPlayable: verifyPlayable,
      );
    }

    final detailHtml = await _get(
      client,
      detailUrl,
      _headers(rule: rule, referer: rule.baseUrl, userAgent: config.userAgent),
    );
    final detailRoot = _documentRoot(detailHtml);
    final roadNodes = _xpathNodes(detailRoot, config.chapterRoads);
    if (roadNodes.isEmpty) {
      return [_unavailableLine(rule, subject, episode, '详情页没有解析到播放线路。')];
    }
    final verifyQuickCandidates = !verifyPlayable && roadNodes.length > 1;

    final lines = await _collectPlaybackCandidates(
      [
        for (var roadIndex = 0; roadIndex < roadNodes.length; roadIndex++)
          () => _resolveKazumiLine(
            client,
            rule,
            config,
            episode,
            detailUrl,
            roadNodes[roadIndex],
            roadIndex,
            started,
            verifyPlayable: verifyPlayable,
            verifyExplicitMedia: verifyQuickCandidates,
          ),
      ],
      verifyPlayable: verifyPlayable,
      candidateTimeout: timeout,
      preferredQuickCandidate: verifyQuickCandidates
          ? _isHlsPlaybackLine
          : null,
      preferredCandidateGrace: const Duration(milliseconds: 1100),
    );

    if (lines.isEmpty) {
      return [_unavailableLine(rule, subject, episode, '找到详情页，但当前集没有解析到直链。')];
    }
    return lines;
  }

  Future<List<PlaybackLine>> _resolveKazumiApiChapters(
    http.Client client,
    RulePlugin rule,
    KazumiParserConfig config,
    AnimeEpisode episode,
    String source, {
    required bool verifyPlayable,
  }) async {
    final api = config.chapterApiConfig;
    final uri = kazumiApiUri(api, {'source': source});
    final decoded = jsonDecode(
      await _get(
        client,
        uri,
        _headers(
          rule: rule,
          referer: rule.baseUrl,
          userAgent: config.userAgent,
        ),
      ),
    );
    final groups = <_TvBoxPlayGroup>[];
    if (api['format'] == 'delimited') {
      final roadSeparator = api['roadSeparator']?.toString() ?? r'$$$';
      final episodeSeparator = api['episodeSeparator']?.toString() ?? '#';
      final fieldSeparator = api['fieldSeparator']?.toString() ?? r'$';
      if ([
        roadSeparator,
        episodeSeparator,
        fieldSeparator,
      ].any((s) => s.isEmpty)) {
        return const [];
      }
      final names = kazumiJsonValue(
        decoded,
        api['roadNamesPath'],
      ).split(roadSeparator);
      final roads = kazumiJsonValue(
        decoded,
        api['roadEpisodesPath'],
      ).split(roadSeparator);
      for (var i = 0; i < roads.length && i < 100; i++) {
        final episodes = <_TvBoxEpisode>[];
        for (final text in roads[i].split(episodeSeparator).take(2000)) {
          final split = text.indexOf(fieldSeparator);
          if (split < 1) continue;
          episodes.add(
            _TvBoxEpisode(
              title: text.substring(0, split),
              url: text.substring(split + fieldSeparator.length),
            ),
          );
        }
        groups.add(
          _TvBoxPlayGroup(
            name: i < names.length ? names[i] : '',
            episodes: episodes,
            index: i,
          ),
        );
      }
    } else if (api['format'] == 'nested') {
      for (final road in kazumiJsonNodes(
        decoded,
        api['roadsPath']?.toString() ?? '',
      ).take(100)) {
        final episodes = <_TvBoxEpisode>[];
        for (final item in kazumiJsonNodes(
          road,
          api['episodesPath']?.toString() ?? '',
        )) {
          final name = kazumiJsonValue(item, api['episodeNamePath']);
          final id = kazumiJsonValue(item, api['episodeUrlPath']);
          if (id.isEmpty) continue;
          final page = api['episodePage'];
          final url = page is Map
              ? kazumiApiTemplate(page['url']?.toString() ?? '', {
                  'source': source,
                  'episodeUrl': id,
                })
              : id;
          if (url.isNotEmpty) {
            episodes.add(_TvBoxEpisode(title: name, url: url));
          }
        }
        groups.add(
          _TvBoxPlayGroup(
            name: kazumiJsonValue(road, api['roadNamePath']),
            episodes: episodes,
            index: groups.length,
          ),
        );
      }
    }
    return _collectPlaybackCandidates(
      [
        for (final group in groups)
          () async {
            // No fallback to the first episode when the requested episode is absent.
            if (episode.number < 1 || episode.number > group.episodes.length) {
              return null;
            }
            final selected = group.episodes[episode.number - 1];
            final target = Uri.parse(_absoluteUrl(selected.url, rule.baseUrl));
            ResolvedRuleMedia? resolved;
            if (_isExplicitPlayableUrl(target.toString())) {
              if (!RuleUrlPolicy(
                rule.effectiveManifest,
              ).allows(target, RuleUrlPurpose.media)) {
                return null;
              }
              resolved = ResolvedRuleMedia(
                target.toString(),
                Uri.parse(rule.baseUrl),
                _headers(
                  rule: rule,
                  referer: rule.baseUrl,
                  userAgent: config.userAgent,
                ),
              );
            } else {
              final body = await _get(
                client,
                target,
                _headers(
                  rule: rule,
                  referer: rule.baseUrl,
                  userAgent: config.userAgent,
                ),
              );
              resolved = await _resolveRuleMedia(
                client,
                rule,
                body,
                target.toString(),
                userAgent: config.userAgent,
              );
            }
            if (resolved == null) return null;
            final probe = await _playableCandidateStatus(
              client,
              resolved.url,
              resolved.headers,
              verifyPlayable: verifyPlayable,
            );
            if (!probe.available) return null;
            return _availableLine(
              rule,
              episode,
              url: resolved.url,
              title: '${episode.displayTitle} · ${group.name}',
              probe: probe,
              referer: resolved.referer.toString(),
              headers: resolved.headers,
              routeKey: '${group.index}',
            );
          },
      ],
      verifyPlayable: verifyPlayable,
      candidateTimeout: timeout,
    );
  }

  Future<ResolvedRuleMedia?> _resolveRuleMedia(
    http.Client client,
    RulePlugin rule,
    String body,
    String page, {
    String userAgent = '',
    String? initialCandidate,
  }) =>
      RuleMediaResolver(
        readPage: (uri, headers) => _get(client, uri, headers),
        extract: (value, base) {
          final raw =
              (value == body ? initialCandidate : null) ??
              _extractPlayableUrl(value, base);
          if (raw != null && _looksPlayable(raw)) {
            return _normalizePlayableUrl(raw, base);
          }
          return _looksPlayable(value)
              ? _normalizePlayableUrl(value, base)
              : null;
        },
        headersFor: (referer) => _headers(
          rule: rule,
          referer: referer.toString(),
          userAgent: userAgent,
        ),
        sniffer: _animekoWebViewSniffer,
      ).resolve(
        page: Uri.parse(page),
        body: body,
        manifest: rule.effectiveManifest,
        allowSniffing: !rule.requiresCaptcha,
        cancellationToken: _activeRulePlaybackResolveContext?.cancellationToken,
        budget: timeout,
      );

  Future<PlaybackLine?> _resolveKazumiLine(
    http.Client client,
    RulePlugin rule,
    KazumiParserConfig config,
    AnimeEpisode episode,
    Uri detailUrl,
    dom.Node road,
    int roadIndex,
    Stopwatch started, {
    required bool verifyPlayable,
    bool verifyExplicitMedia = false,
  }) async {
    try {
      final episodeNodes = _xpathNodes(road, config.chapterResult);
      final episodeNode = _pickEpisodeNode(episodeNodes, episode);
      if (episodeNode == null) return null;

      final playHref = _nodeHref(episodeNode);
      if (playHref.isEmpty) return null;

      final playPageUrl = _absoluteUrl(playHref, detailUrl.toString());
      final playHtml = await _get(
        client,
        Uri.parse(playPageUrl),
        _headers(rule: rule, referer: detailUrl.toString()),
      );
      final resolved = await _resolveRuleMedia(
        client,
        rule,
        playHtml,
        playPageUrl,
        userAgent: config.userAgent,
      );
      if (resolved == null) return null;
      final playableUrl = resolved.url;
      final headers = resolved.headers;
      final probe = await _playableCandidateStatus(
        client,
        playableUrl,
        headers,
        verifyPlayable: verifyPlayable,
        verifyExplicitMedia: verifyExplicitMedia,
      );
      final title = '${episode.displayTitle} · 线路${roadIndex + 1}';
      return probe.available
          ? _availableLine(
              rule,
              episode,
              url: playableUrl,
              title: title,
              probe: probe,
              referer: resolved.referer.toString(),
              headers: headers,
              routeKey: '$roadIndex',
            )
          : _deadLine(
              rule,
              episode,
              url: playableUrl,
              title: title,
              latency: probe.latency,
              message: probe.message,
              headers: headers,
              routeKey: '$roadIndex',
            );
    } catch (_) {
      return null;
    }
  }

  Future<Uri?> _findKazumiDetailUrl(
    http.Client client,
    RulePlugin rule,
    KazumiParserConfig config,
    AnimeSubject subject,
  ) async {
    final keywords = _searchKeywords(subject);
    final best = await _firstConfidentResult([
      for (var index = 0; index < keywords.length; index++)
        _searchKazumiKeyword(
          client,
          rule,
          config,
          subject,
          keywords[index],
          index,
        ),
    ]);
    return best == null ? null : Uri.tryParse(best.url);
  }

  Future<_RankedResult<_SearchHit>?> _searchKazumiKeyword(
    http.Client client,
    RulePlugin rule,
    KazumiParserConfig config,
    AnimeSubject subject,
    String keyword,
    int preference,
  ) async {
    if (config.searchMode.toLowerCase() == 'api') {
      final api = config.searchApiConfig;
      final uri = kazumiApiUri(api, {'keyword': keyword});
      final decoded = jsonDecode(
        await _get(
          client,
          uri,
          _headers(
            rule: rule,
            referer: rule.baseUrl,
            userAgent: config.userAgent,
          ),
        ),
      );
      final hits = <_SearchHit>[];
      for (final item in kazumiJsonNodes(
        decoded,
        api['listPath']?.toString() ?? '',
      )) {
        final name = kazumiJsonValue(item, api['namePath']);
        final source = kazumiJsonValue(item, api['sourcePath']);
        if (name.isEmpty || source.isEmpty) continue;
        final template = api['sourceTemplate']?.toString().trim() ?? '';
        final detail = template.isEmpty
            ? source
            : kazumiApiTemplate(template, {'source': source});
        hits.add(
          _SearchHit(
            title: name,
            url: config.chapterMode.toLowerCase() == 'api'
                ? source
                : _absoluteUrl(detail, rule.baseUrl),
          ),
        );
      }
      return _rankBestHit(hits, subject, preference);
    }
    final searchUrl = _searchUrl(rule.searchUrl, keyword);
    final searchHtml = await _get(
      client,
      Uri.parse(searchUrl),
      _headers(rule: rule, referer: rule.baseUrl, userAgent: config.userAgent),
    );
    final root = _documentRoot(searchHtml);
    final hits = [
      for (final item in _xpathNodes(root, config.searchList))
        _SearchHit(
          title: _xpathText(item, config.searchName),
          url: _absoluteUrl(
            _xpathHref(item, config.searchResult),
            rule.baseUrl,
          ),
        ),
    ].where((item) => item.title.isNotEmpty && item.url.isNotEmpty).toList();
    return _rankBestHit(hits, subject, preference);
  }

  Future<List<PlaybackLine>> _resolveXbpq(
    http.Client client,
    RulePlugin rule,
    AnimeSubject subject,
    AnimeEpisode episode,
    Stopwatch started, {
    required bool verifyPlayable,
  }) async {
    final config = rule.xbpq;
    if (config == null) {
      return [_unavailableLine(rule, subject, episode, '这个来源的解析设置不全，用不了。')];
    }

    final detailUrl = await _findXbpqDetailUrl(client, rule, config, subject);
    if (detailUrl == null) {
      return [_unavailableLine(rule, subject, episode, '没有匹配到当前条目的详情页。')];
    }

    final detailHtml = await _get(
      client,
      detailUrl,
      _headers(rule: rule, referer: rule.baseUrl),
    );
    var playGroups = _segmentsByRule(detailHtml, config.playArray);
    if (playGroups.isEmpty) playGroups = [detailHtml];

    final lines = await _collectPlaybackCandidates(
      [
        for (var groupIndex = 0; groupIndex < playGroups.length; groupIndex++)
          () => _resolveXbpqLine(
            client,
            rule,
            config,
            episode,
            detailUrl,
            playGroups[groupIndex],
            groupIndex,
            started,
            verifyPlayable: verifyPlayable,
          ),
      ],
      verifyPlayable: verifyPlayable,
      candidateTimeout: timeout,
    );

    if (lines.isEmpty) {
      return [_unavailableLine(rule, subject, episode, '找到详情页，但当前集没有解析到直链。')];
    }
    return lines;
  }

  Future<PlaybackLine?> _resolveXbpqLine(
    http.Client client,
    RulePlugin rule,
    XbpqParserConfig config,
    AnimeEpisode episode,
    Uri detailUrl,
    String playGroup,
    int groupIndex,
    Stopwatch started, {
    required bool verifyPlayable,
  }) async {
    try {
      var episodeSegments = _segmentsByRule(playGroup, config.playList);
      if (config.reverseEpisodes) {
        episodeSegments = episodeSegments.reversed.toList(growable: false);
      }
      final episodeSegment = _pickEpisodeSegment(episodeSegments, episode);
      if (episodeSegment == null) return null;

      final playHref = _cutByRule(episodeSegment, config.playLink);
      if (playHref.isEmpty) return null;

      final playPageUrl = _absoluteUrl(playHref, detailUrl.toString());
      final playHtml = await _get(
        client,
        Uri.parse(playPageUrl),
        _headers(rule: rule, referer: detailUrl.toString()),
      );
      final resolved = await _resolveRuleMedia(
        client,
        rule,
        playHtml,
        playPageUrl,
        initialCandidate: _extractByWildcardRule(playHtml, config.jumpPlayLink),
      );
      if (resolved == null) return null;

      final lineTitle = _cleanText(
        _cutByRule(episodeSegment, config.playTitle),
      );
      final normalizedPlayableUrl = resolved.url;
      final headers = resolved.headers;
      final probe = await _playableCandidateStatus(
        client,
        normalizedPlayableUrl,
        headers,
        verifyPlayable: verifyPlayable,
      );
      final title =
          '${lineTitle.isEmpty ? episode.displayTitle : lineTitle} · 线路${groupIndex + 1}';
      return probe.available
          ? _availableLine(
              rule,
              episode,
              url: normalizedPlayableUrl,
              title: title,
              probe: probe,
              referer: resolved.referer.toString(),
              headers: headers,
              routeKey: '$groupIndex',
            )
          : _deadLine(
              rule,
              episode,
              url: normalizedPlayableUrl,
              title: title,
              latency: probe.latency,
              message: probe.message,
              headers: headers,
              routeKey: '$groupIndex',
            );
    } catch (_) {
      return null;
    }
  }

  Future<Uri?> _findXbpqDetailUrl(
    http.Client client,
    RulePlugin rule,
    XbpqParserConfig config,
    AnimeSubject subject,
  ) async {
    final keywords = _searchKeywords(subject);
    final best = await _firstConfidentResult([
      for (var index = 0; index < keywords.length; index++)
        _searchXbpqKeyword(
          client,
          rule,
          config,
          subject,
          keywords[index],
          index,
        ),
    ]);
    return best == null ? null : Uri.tryParse(best.url);
  }

  Future<_RankedResult<_SearchHit>?> _searchXbpqKeyword(
    http.Client client,
    RulePlugin rule,
    XbpqParserConfig config,
    AnimeSubject subject,
    String keyword,
    int preference,
  ) async {
    final searchUri = Uri.parse(_searchUrl(rule.searchUrl, keyword));
    final searchHtml = config.searchPostBody.trim().isEmpty
        ? await _get(
            client,
            searchUri,
            _headers(rule: rule, referer: rule.baseUrl),
          )
        : await _post(
            client,
            searchUri,
            _searchBody(config.searchPostBody, keyword),
            _headers(rule: rule, referer: rule.baseUrl),
          );
    final hits = [
      for (final segment in _segmentsByRule(searchHtml, config.searchArray))
        _SearchHit(
          title: _cleanText(_cutByRule(segment, config.searchTitle)),
          url: _absoluteUrl(
            _cutByRule(segment, config.searchLink),
            rule.baseUrl,
          ),
        ),
    ].where((item) => item.title.isNotEmpty && item.url.isNotEmpty).toList();
    return _rankBestHit(hits, subject, preference);
  }
}

dom.Element _documentRoot(String html) {
  final root = html_parser.parse(html).documentElement;
  if (root == null) throw const FormatException('空 HTML');
  return root;
}

List<dom.Node> _xpathNodes(dom.Node root, String xpath) {
  if (xpath.trim().isEmpty) return const [];
  try {
    return HtmlXPath.node(
      root,
    ).query(xpath).nodes.map((item) => item.node).toList();
  } catch (_) {
    return const [];
  }
}

String _xpathText(dom.Node root, String xpath) {
  final nodes = _xpathNodes(root, xpath);
  if (nodes.isEmpty) return '';
  return _cleanText(nodes.first.text ?? '');
}

String _xpathHref(dom.Node root, String xpath) {
  final attr = _xpathAttr(root, '$xpath/@href');
  if (attr.isNotEmpty) return attr;
  final nodes = _xpathNodes(root, xpath);
  if (nodes.isEmpty) return '';
  return _nodeHref(nodes.first);
}

String _xpathAttr(dom.Node root, String xpath) {
  if (xpath.trim().isEmpty) return '';
  try {
    final result = HtmlXPath.node(root).query(xpath).attr;
    return result?.trim() ?? '';
  } catch (_) {
    return '';
  }
}

String _nodeHref(dom.Node node) {
  if (node is! dom.Element) return '';
  return (node.attributes['href'] ??
          node.attributes['data-href'] ??
          node.attributes['data-url'] ??
          '')
      .trim();
}

dom.Node? _pickEpisodeNode(List<dom.Node> nodes, AnimeEpisode episode) {
  if (nodes.isEmpty) return null;
  final index = episode.number - 1;
  if (index >= 0 && index < nodes.length) return nodes[index];
  final normalizedNumber = episode.number.toString();
  for (final node in nodes) {
    final text = _cleanText(node.text ?? '');
    if (text == normalizedNumber ||
        text.contains('第$normalizedNumber') ||
        text.toLowerCase().contains('ep$normalizedNumber')) {
      return node;
    }
  }
  return nodes.first;
}

String? _pickEpisodeSegment(List<String> segments, AnimeEpisode episode) {
  if (segments.isEmpty) return null;
  final index = episode.number - 1;
  if (index >= 0 && index < segments.length) return segments[index];
  final normalizedNumber = episode.number.toString();
  for (final segment in segments) {
    final text = _cleanText(segment);
    if (text == normalizedNumber ||
        text.contains('第$normalizedNumber') ||
        text.toLowerCase().contains('ep$normalizedNumber')) {
      return segment;
    }
  }
  return segments.first;
}

List<String> _segmentsByRule(String source, String rule) {
  final parts = rule.split('&&');
  if (parts.length != 2) return const [];
  final start = parts.first;
  final end = parts.last;
  if (start.isEmpty || end.isEmpty) return const [];

  final result = <String>[];
  var offset = 0;
  while (offset < source.length) {
    final startIndex = source.indexOf(start, offset);
    if (startIndex < 0) break;
    final endIndex = source.indexOf(end, startIndex + start.length);
    if (endIndex < 0) break;
    result.add(source.substring(startIndex, endIndex + end.length));
    offset = endIndex + end.length;
  }
  return result;
}

String _cutByRule(String source, String rule) {
  if (rule.trim().isEmpty) return '';
  final parts = rule.split('&&');
  if (parts.length != 2) return '';
  final start = parts.first;
  final end = parts.last;
  final startIndex = start.isEmpty ? 0 : source.indexOf(start);
  if (startIndex < 0) return '';
  final valueStart = startIndex + start.length;
  final endIndex = end.isEmpty
      ? source.length
      : source.indexOf(end, valueStart);
  if (endIndex < 0) return '';
  return source.substring(valueStart, endIndex).trim();
}

String? _extractByWildcardRule(String source, String rule) {
  if (rule.trim().isEmpty) return null;
  final parts = rule.split('&&');
  if (parts.length != 2) return null;
  final startRule = parts.first;
  final end = parts.last;
  var cursor = 0;
  for (final marker in startRule.split('*')) {
    if (marker.isEmpty) continue;
    final index = source.indexOf(marker, cursor);
    if (index < 0) return null;
    cursor = index + marker.length;
  }
  final endIndex = end.isEmpty ? source.length : source.indexOf(end, cursor);
  if (endIndex < 0) return null;
  final value = _decodePlayerUrl(source.substring(cursor, endIndex));
  return value.isEmpty ? null : value;
}

String? _extractPlayableUrl(String html, String baseUrl) {
  for (final match in RegExp(
    r'var\s+player_\w+\s*=\s*(\{.*?\})\s*(?:;|</script)',
    dotAll: true,
  ).allMatches(html)) {
    final object = match.group(1);
    if (object == null) continue;
    final url = _playerJsonUrl(object);
    if (url != null && url.isNotEmpty) {
      final normalized = _normalizePlayableUrl(url, baseUrl);
      if (_looksPlayable(normalized)) return normalized;
    }
  }

  for (final match in RegExp(
    r'"url"\s*:\s*"([^"]+)"',
    dotAll: true,
  ).allMatches(html)) {
    final url = _decodePlayerUrl(match.group(1) ?? '');
    final normalized = _normalizePlayableUrl(url, baseUrl);
    if (_looksPlayable(normalized)) return normalized;
  }

  final directMatch = RegExp(
    r'https?:\\?/\\?/[^\s"<>]+?\.(?:m3u8|mpd|mp4|webm|mkv|flv|m4v)(?:\?[^\s"<>]*)?',
    caseSensitive: false,
  ).firstMatch(html);
  if (directMatch == null) return null;
  return _normalizePlayableUrl(
    _decodePlayerUrl(directMatch.group(0) ?? ''),
    baseUrl,
  );
}

String? _playerJsonUrl(String source) {
  try {
    final decoded = jsonDecode(source);
    if (decoded is Map) {
      return _decodePlayerUrl(decoded['url'], decoded['encrypt']);
    }
  } catch (_) {
    final match = RegExp(
      r'''['"]url['"]\s*:\s*['"]([^'"]+)['"]''',
    ).firstMatch(source);
    if (match != null) return _decodePlayerUrl(match.group(1));
  }
  return null;
}

String _decodePlayerUrl(Object? raw, [Object? encrypt]) {
  var text = raw?.toString().trim() ?? '';
  if (text.isEmpty) return '';
  text = text.replaceAll(r'\/', '/').replaceAll(r'\\/', '/');
  text = text.replaceAll(r'\u002F', '/').replaceAll(r'\u002f', '/');

  final encryptValue = encrypt?.toString();
  if (encryptValue == '2') {
    try {
      text = utf8.decode(base64Decode(text));
    } catch (_) {
      return text;
    }
  }
  if (encryptValue == '1' ||
      text.startsWith('http%3A') ||
      text.startsWith('https%3A')) {
    try {
      text = Uri.decodeFull(text);
    } catch (_) {
      return text;
    }
  }
  return text;
}

String _normalizePlayableUrl(String url, String baseUrl) {
  final decoded = _decodePlayerUrl(url);
  if (decoded.isEmpty) return decoded;
  return _absoluteUrl(decoded, baseUrl);
}

bool _looksPlayable(String url) {
  final lower = url.toLowerCase();
  if (lower.startsWith('magnet:') || lower.contains('ed2k://')) return false;
  if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
    return false;
  }
  if (_isExplicitPlayableUrl(lower)) return true;
  return !lower.endsWith('.html') && !lower.contains('/vodplay/');
}

bool _isExplicitPlayableUrl(String url) {
  final lower = url.toLowerCase();
  return RegExp(
        r'\.(?:m3u8|mpd|mp4|webm|mkv|flv|m4v)(?:$|[?#])',
        caseSensitive: false,
      ).hasMatch(lower) ||
      lower.contains('/m3u8') ||
      lower.contains('type=m3u8');
}

String _absoluteUrl(String value, String baseUrl) {
  final text = _decodePlayerUrl(value).trim();
  if (text.isEmpty) return '';
  if (text.startsWith('//')) return 'https:$text';
  final uri = Uri.tryParse(text);
  if (uri != null && uri.hasScheme) return text;
  final base = Uri.tryParse(baseUrl);
  if (base == null) return text;
  return base.resolve(text).toString();
}
