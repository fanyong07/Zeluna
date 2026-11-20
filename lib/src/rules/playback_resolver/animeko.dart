part of '../rule_playback_resolver.dart';

// Animeko selectors, episode extraction, and WebView sniffing.

extension _AnimekoResolution on RulePlaybackResolver {
  Future<List<PlaybackLine>> _resolveAnimekoWebSelector(
    http.Client client,
    RulePlugin rule,
    AnimeSubject subject,
    AnimeEpisode episode,
    Stopwatch started, {
    required bool verifyPlayable,
  }) async {
    final config = rule.animeko;
    if (config == null) {
      return [_unavailableLine(rule, subject, episode, '这个来源的解析设置不全，用不了。')];
    }

    final detailUrl = await _findAnimekoDetailUrl(
      client,
      rule,
      config,
      subject,
    );
    if (detailUrl == null) {
      return [_unavailableLine(rule, subject, episode, '没有匹配到当前条目的详情页。')];
    }

    final detailHtml = await _get(
      client,
      detailUrl,
      _headers(rule: rule, referer: rule.baseUrl),
    );
    final detailRoot = _documentRoot(detailHtml);
    final episodeLinks = _animekoEpisodeLinks(
      detailRoot,
      detailUrl.toString(),
      config,
      episode,
    );
    if (episodeLinks.isEmpty) {
      return [_unavailableLine(rule, subject, episode, '详情页没有解析到当前集的播放入口。')];
    }
    final verifyQuickCandidates = !verifyPlayable && episodeLinks.length > 1;

    final lines = await _collectPlaybackCandidates(
      [
        for (var index = 0; index < episodeLinks.length; index++)
          () => _resolveAnimekoLine(
            client,
            rule,
            config,
            episode,
            detailUrl,
            episodeLinks[index],
            index,
            started,
            verifyPlayable: verifyPlayable,
            verifyExplicitMedia: verifyQuickCandidates,
          ),
      ],
      verifyPlayable: verifyPlayable,
      candidateTimeout: timeout,
    );

    if (lines.isEmpty) {
      return [
        _unavailableLine(rule, subject, episode, '找到了播放页，但没有解析到 mp4/m3u8 直链。'),
      ];
    }
    return lines;
  }

  Future<PlaybackLine?> _resolveAnimekoLine(
    http.Client client,
    RulePlugin rule,
    AnimekoWebSelectorConfig config,
    AnimeEpisode episode,
    Uri detailUrl,
    _AnimekoEpisodeLink link,
    int index,
    Stopwatch started, {
    required bool verifyPlayable,
    bool verifyExplicitMedia = false,
  }) async {
    try {
      final playHtml = await _get(
        client,
        Uri.parse(link.url),
        _headers(rule: rule, referer: detailUrl.toString()),
      );
      var playableUrl = await _extractAnimekoPlayableUrl(
        client,
        rule,
        config,
        playHtml,
        link.url,
        get: (url, headers) => _get(client, url, headers),
      );
      var sniffedCookie = '';
      if ((playableUrl == null || !_looksPlayable(playableUrl)) &&
          _animekoWebViewSniffer.supported) {
        final sniffed = await _sniffAnimekoPlayableUrl(
          client,
          rule,
          config,
          link.url,
          detailUrl.toString(),
        );
        playableUrl = sniffed.url;
        sniffedCookie = sniffed.cookieHeader;
      }
      if (playableUrl == null || !_looksPlayable(playableUrl)) return null;

      final referer = _animekoVideoReferer(config, link.url);
      final headers = _animekoVideoHeaders(rule, config, referer);
      if (sniffedCookie.isNotEmpty) {
        headers['Cookie'] = _mergeCookieHeaders(
          headers['Cookie'] ?? '',
          sniffedCookie,
        );
      }
      final probe = await _playableCandidateStatus(
        client,
        playableUrl,
        headers,
        verifyPlayable: verifyPlayable,
        verifyExplicitMedia: verifyExplicitMedia,
      );
      final title =
          '${link.title.isEmpty ? episode.displayTitle : link.title} · 线路${index + 1}';
      return probe.available
          ? _availableLine(
              rule,
              episode,
              url: playableUrl,
              title: title,
              probe: probe,
              referer: referer,
              quality: config.defaultResolution.trim().isEmpty
                  ? null
                  : config.defaultResolution.trim(),
              headers: headers,
            )
          : _deadLine(
              rule,
              episode,
              url: playableUrl,
              title: title,
              latency: probe.latency,
              message: probe.message,
              headers: headers,
            );
    } catch (_) {
      return null;
    }
  }

  Future<({String? url, String cookieHeader})> _sniffAnimekoPlayableUrl(
    http.Client client,
    RulePlugin rule,
    AnimekoWebSelectorConfig config,
    String playPageUrl,
    String detailUrl,
  ) async {
    String? matchVideo(String value, String baseUrl) {
      final configured = _extractByRegex(
        value,
        config.matchVideoUrl,
        baseUrl: baseUrl,
      );
      if (configured != null && _looksPlayable(configured)) return configured;
      final fallback = _extractPlayableUrl(value, baseUrl);
      if (fallback != null && _looksPlayable(fallback)) return fallback;
      final absolute = _absoluteUrl(value, baseUrl);
      return _looksPlayable(absolute) ? absolute : null;
    }

    String? matchNested(String value, String baseUrl) {
      if (!config.enableNestedUrl || config.matchNestedUrl.trim().isEmpty) {
        return null;
      }
      return _extractByRegex(
        value,
        config.matchNestedUrl,
        baseUrl: baseUrl,
        requirePlayable: false,
      );
    }

    final result = await _animekoWebViewSniffer.sniff(
      AnimekoWebViewSniffRequest(
        pageUrl: Uri.parse(playPageUrl),
        headers: filterRuleRequestHeaders(
          _animekoVideoHeaders(rule, config, detailUrl),
          rule.effectiveManifest,
        ),
        matchVideo: matchVideo,
        matchNested: matchNested,
        manifest: _effectiveScopeManifest(rule),
        timeout: const Duration(seconds: 8),
      ),
    );
    if (result == null) return (url: null, cookieHeader: '');
    var resolved = result.videoUrl;
    final nestedUrl = result.nestedUrl;
    if ((resolved == null || !_looksPlayable(resolved)) &&
        nestedUrl != null &&
        nestedUrl.trim().isNotEmpty) {
      final nestedHeaders = _animekoNestedHeaders(rule, config, playPageUrl);
      if (result.cookieHeader.isNotEmpty) {
        nestedHeaders['Cookie'] = _mergeCookieHeaders(
          nestedHeaders['Cookie'] ?? '',
          result.cookieHeader,
        );
      }
      final nestedHtml = await _get(
        client,
        Uri.parse(nestedUrl),
        nestedHeaders,
      );
      resolved = matchVideo(nestedHtml, nestedUrl);
    }
    return (url: resolved, cookieHeader: result.cookieHeader);
  }

  Future<Uri?> _findAnimekoDetailUrl(
    http.Client client,
    RulePlugin rule,
    AnimekoWebSelectorConfig config,
    AnimeSubject subject,
  ) async {
    final keywords = _animekoSearchKeywords(subject, config);
    final best = await _firstConfidentResult([
      for (var index = 0; index < keywords.length; index++)
        _searchAnimekoKeyword(
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

  Future<_RankedResult<_SearchHit>?> _searchAnimekoKeyword(
    http.Client client,
    RulePlugin rule,
    AnimekoWebSelectorConfig config,
    AnimeSubject subject,
    String keyword,
    int preference,
  ) async {
    final searchUri = Uri.parse(_animekoSearchUrl(config.searchUrl, keyword));
    final searchHtml = await _get(
      client,
      searchUri,
      _headers(rule: rule, referer: rule.baseUrl),
    );
    final hits =
        config.subjectFormatId.trim().toLowerCase() == 'json-path-indexed'
        ? _animekoJsonSearchHits(
            searchHtml,
            config.rawBaseUrl.trim().isNotEmpty
                ? config.rawBaseUrl.trim()
                : rule.baseUrl,
            config,
          )
        : _animekoSearchHits(
            _documentRoot(searchHtml),
            searchUri.toString(),
            config,
          );
    return _rankBestHit(hits, subject, preference);
  }

  Map<String, String> _animekoVideoHeaders(
    RulePlugin rule,
    AnimekoWebSelectorConfig config,
    String referer,
  ) {
    final headers = _headers(
      rule: rule,
      referer: referer,
      userAgent: config.videoUserAgent,
    );
    final cookie = config.cookies.trim();
    if (rule.effectiveManifest.cookiePolicy == RuleCookiePolicy.taskScoped &&
        cookie.isNotEmpty) {
      headers['Cookie'] = cookie;
    }
    return headers;
  }
}

class _AnimekoEpisodeLink {
  const _AnimekoEpisodeLink({required this.title, required this.url});

  final String title;
  final String url;
}

List<_SearchHit> _animekoJsonSearchHits(
  String body,
  String baseUrl,
  AnimekoWebSelectorConfig config,
) {
  Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (_) {
    return const [];
  }
  final names = _jsonPathValues(
    decoded,
    config.subjectJsonPathIndexed.selectNames,
  );
  final links = _jsonPathValues(
    decoded,
    config.subjectJsonPathIndexed.selectLinks,
  );
  final length = names.length < links.length ? names.length : links.length;
  return [
    for (var i = 0; i < length; i++)
      _SearchHit(
        title: _cleanText(names[i]),
        url: _absoluteUrl(links[i], baseUrl),
      ),
  ].where((item) => item.title.isNotEmpty && item.url.isNotEmpty).toList();
}

/// Minimal JSONPath reader that supports the dotted `$.a.b[*].field` shape used
/// by Animeko `json-path-indexed` sources. It intentionally avoids a full
/// JSONPath engine: only child access and the `[*]` wildcard are handled.
List<String> _jsonPathValues(Object? root, String path) {
  final trimmed = path.trim();
  if (trimmed.isEmpty) return const [];
  var expression = trimmed;
  if (expression.startsWith(r'$')) expression = expression.substring(1);
  expression = expression.replaceAll('[*]', '.[*]');
  final segments = expression
      .split('.')
      .map((segment) => segment.trim())
      .where((segment) => segment.isNotEmpty)
      .toList();

  var current = <Object?>[root];
  for (final segment in segments) {
    final next = <Object?>[];
    if (segment == '[*]') {
      for (final node in current) {
        if (node is List) next.addAll(node);
      }
    } else {
      final key = segment.replaceAll(RegExp(r'''^['"]|['"]$'''), '');
      for (final node in current) {
        if (node is Map) next.add(node[key]);
      }
    }
    current = next;
    if (current.isEmpty) return const [];
  }

  return current
      .where((value) => value != null)
      .map((value) => value.toString().trim())
      .where((value) => value.isNotEmpty)
      .toList();
}

List<_SearchHit> _animekoSearchHits(
  dom.Element root,
  String baseUrl,
  AnimekoWebSelectorConfig config,
) {
  final format = config.subjectFormatId.trim().toLowerCase();
  if (format == 'indexed') {
    final names = _querySelectorAll(root, config.subjectIndexed.selectNames);
    final links = _querySelectorAll(root, config.subjectIndexed.selectLinks);
    final length = names.length < links.length ? names.length : links.length;
    return [
      for (var i = 0; i < length; i++)
        _SearchHit(
          title: _cleanText(names[i].text),
          url: _absoluteUrl(_elementHref(links[i]), baseUrl),
        ),
    ].where((item) => item.title.isNotEmpty && item.url.isNotEmpty).toList();
  }

  return [
    for (final item in _querySelectorAll(root, config.subjectA.selectLists))
      _SearchHit(
        title: _cleanText(
          _attrFromElement(item, 'title') ??
              _attrFromElement(item, 'alt') ??
              item.text,
        ),
        url: _absoluteUrl(_elementHref(item), baseUrl),
      ),
  ].where((item) => item.title.isNotEmpty && item.url.isNotEmpty).toList();
}

List<_AnimekoEpisodeLink> _animekoEpisodeLinks(
  dom.Element root,
  String baseUrl,
  AnimekoWebSelectorConfig config,
  AnimeEpisode episode,
) {
  final links = config.channelFormatId.trim().toLowerCase() == 'no-channel'
      ? _animekoNoChannelEpisodeLinks(root, baseUrl, config, episode)
      : _animekoGroupedEpisodeLinks(root, baseUrl, config, episode);
  if (links.isNotEmpty) return links;

  final fallback = [
    for (final anchor in root.querySelectorAll('a'))
      _AnimekoEpisodeLink(
        title: _cleanText(anchor.text),
        url: _absoluteUrl(_elementHref(anchor), baseUrl),
      ),
  ].where((item) => item.url.isNotEmpty).toList();
  return _pickAnimekoEpisodes(
    fallback,
    episode,
    config.channelFlattened.matchEpisodeSortFromName,
  );
}

List<_AnimekoEpisodeLink> _animekoGroupedEpisodeLinks(
  dom.Element root,
  String baseUrl,
  AnimekoWebSelectorConfig config,
  AnimeEpisode episode,
) {
  final channelConfig = config.channelFlattened;
  final episodeLists = _querySelectorAll(
    root,
    channelConfig.selectEpisodeLists,
  );
  if (episodeLists.isEmpty) return const [];

  final channelNames = _querySelectorAll(
    root,
    channelConfig.selectChannelNames,
  );
  final result = <_AnimekoEpisodeLink>[];
  for (var i = 0; i < episodeLists.length; i++) {
    if (i < channelNames.length &&
        !_matchesOptionalPattern(
          _cleanText(channelNames[i].text),
          channelConfig.matchChannelName,
        )) {
      continue;
    }
    final episodeNodes = _querySelectorAll(
      episodeLists[i],
      channelConfig.selectEpisodesFromList,
    );
    final candidates = [
      for (final item in episodeNodes)
        _AnimekoEpisodeLink(
          title: _cleanText(item.text),
          url: _absoluteUrl(
            _animekoEpisodeHref(item, channelConfig.selectEpisodeLinksFromList),
            baseUrl,
          ),
        ),
    ].where((item) => item.url.isNotEmpty).toList();
    result.addAll(
      _pickAnimekoEpisodes(
        candidates,
        episode,
        channelConfig.matchEpisodeSortFromName,
      ),
    );
  }
  return _uniqueEpisodeLinks(result);
}

List<_AnimekoEpisodeLink> _animekoNoChannelEpisodeLinks(
  dom.Element root,
  String baseUrl,
  AnimekoWebSelectorConfig config,
  AnimeEpisode episode,
) {
  final channelConfig = config.channelNoChannel;
  final candidates = [
    for (final item in _querySelectorAll(root, channelConfig.selectEpisodes))
      _AnimekoEpisodeLink(
        title: _cleanText(item.text),
        url: _absoluteUrl(
          _animekoEpisodeHref(item, channelConfig.selectEpisodeLinks),
          baseUrl,
        ),
      ),
  ].where((item) => item.url.isNotEmpty).toList();
  return _pickAnimekoEpisodes(
    candidates,
    episode,
    channelConfig.matchEpisodeSortFromName,
  );
}

List<_AnimekoEpisodeLink> _pickAnimekoEpisodes(
  List<_AnimekoEpisodeLink> candidates,
  AnimeEpisode episode,
  String sortPattern,
) {
  if (candidates.isEmpty) return const [];

  final bySort = candidates.where((item) {
    final sort = _animekoEpisodeSort(item.title, sortPattern);
    return sort != null && sort == episode.number;
  }).toList();
  if (bySort.isNotEmpty) return bySort;

  final numberText = episode.number.toString();
  final byText = candidates.where((item) {
    final title = _cleanText(item.title).toLowerCase();
    return title == numberText ||
        title.contains('第$numberText') ||
        title.contains('ep$numberText') ||
        title.contains('e$numberText');
  }).toList();
  if (byText.isNotEmpty) return byText;

  final index = episode.number - 1;
  if (index >= 0 && index < candidates.length) return [candidates[index]];
  return [candidates.first];
}

List<_AnimekoEpisodeLink> _uniqueEpisodeLinks(List<_AnimekoEpisodeLink> links) {
  final seen = <String>{};
  final result = <_AnimekoEpisodeLink>[];
  for (final link in links) {
    if (seen.add(link.url)) result.add(link);
  }
  return result;
}

Future<String?> _extractAnimekoPlayableUrl(
  http.Client client,
  RulePlugin rule,
  AnimekoWebSelectorConfig config,
  String html,
  String playPageUrl, {
  Future<String> Function(Uri url, Map<String, String> headers)? get,
}) async {
  final direct = _extractByRegex(
    html,
    config.matchVideoUrl,
    baseUrl: playPageUrl,
  );
  if (direct != null && _looksPlayable(direct)) return direct;

  final fallbackDirect = _extractPlayableUrl(html, playPageUrl);
  if (fallbackDirect != null && _looksPlayable(fallbackDirect)) {
    return fallbackDirect;
  }

  if (!config.enableNestedUrl || config.matchNestedUrl.trim().isEmpty) {
    return null;
  }
  final nestedUrl = _extractByRegex(
    html,
    config.matchNestedUrl,
    baseUrl: playPageUrl,
    requirePlayable: false,
  );
  if (nestedUrl == null) return null;

  final nestedUri = Uri.parse(nestedUrl);
  final nestedHeaders = _animekoNestedHeaders(rule, config, playPageUrl);
  final nestedHtml = get != null
      ? await get(nestedUri, nestedHeaders)
      : await client
            .get(nestedUri, headers: nestedHeaders)
            .timeout(const Duration(seconds: 10))
            .then((response) {
              if (response.statusCode < 200 || response.statusCode >= 400) {
                throw HttpException('HTTP ${response.statusCode}');
              }
              return response.body;
            });
  return _extractByRegex(
        nestedHtml,
        config.matchVideoUrl,
        baseUrl: nestedUrl,
      ) ??
      _extractPlayableUrl(nestedHtml, nestedUrl);
}

Map<String, String> _animekoNestedHeaders(
  RulePlugin rule,
  AnimekoWebSelectorConfig config,
  String referer,
) {
  final headers = <String, String>{
    'User-Agent': config.videoUserAgent.trim().isEmpty
        ? RulePlaybackResolver._desktopUserAgent
        : config.videoUserAgent.trim(),
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
    'Referer': referer,
  };
  final cookie = config.cookies.trim();
  if (cookie.isNotEmpty) headers['Cookie'] = cookie;
  if (rule.baseUrl.trim().isNotEmpty && referer.trim().isEmpty) {
    headers['Referer'] = rule.baseUrl;
  }
  return headers;
}

String _mergeCookieHeaders(String configured, String observed) {
  final cookies = <String, String>{};
  for (final header in [configured, observed]) {
    for (final pair in header.split(';')) {
      final separator = pair.indexOf('=');
      if (separator <= 0) continue;
      final name = pair.substring(0, separator).trim();
      final value = pair.substring(separator + 1).trim();
      if (name.isNotEmpty) cookies[name] = value;
    }
  }
  return cookies.entries
      .map((entry) => '${entry.key}=${entry.value}')
      .join('; ');
}

String? _extractByRegex(
  String source,
  String pattern, {
  required String baseUrl,
  bool requirePlayable = true,
}) {
  if (pattern.trim().isEmpty) return null;
  RegExp regex;
  try {
    regex = RegExp(pattern, caseSensitive: false, dotAll: true);
  } catch (_) {
    return null;
  }

  for (final match in regex.allMatches(source)) {
    for (final value in _regexMatchCandidates(match)) {
      final normalized = _normalizePlayableUrl(value, baseUrl);
      if (normalized.isEmpty) continue;
      if (!requirePlayable || _looksPlayable(normalized)) return normalized;
    }
  }
  return null;
}

List<String> _regexMatchCandidates(RegExpMatch match) {
  final values = <String>[];
  for (final name in const ['v', 'url']) {
    try {
      final value = match.namedGroup(name);
      if (value != null && value.trim().isNotEmpty) values.add(value);
    } catch (_) {
      // Older or source-specific regexes may not declare named groups.
    }
  }
  for (var i = 1; i <= match.groupCount; i++) {
    final value = match.group(i);
    if (value != null && value.trim().isNotEmpty) values.add(value);
  }
  final whole = match.group(0);
  if (whole != null && whole.trim().isNotEmpty) values.add(whole);

  return values
      .map(_decodePlayerUrl)
      .map(_stripVideoUrlPrefix)
      .where((item) => item.trim().isNotEmpty)
      .toList(growable: false);
}

String _stripVideoUrlPrefix(String value) {
  final text = value.trim();
  final urlIndex = text.indexOf(RegExp(r'https?://', caseSensitive: false));
  if (urlIndex > 0) return text.substring(urlIndex);
  return text;
}

List<dom.Element> _querySelectorAll(dom.Element root, String selector) {
  final text = selector.trim();
  if (text.isEmpty) return const [];
  try {
    return root.querySelectorAll(text);
  } catch (_) {
    final patched = _quoteUnquotedAttributeValues(text);
    if (patched == text) return const [];
    try {
      return root.querySelectorAll(patched);
    } catch (_) {
      return const [];
    }
  }
}

String _quoteUnquotedAttributeValues(String selector) {
  final buffer = StringBuffer();
  var cursor = 0;
  final pattern = RegExp(r'''=\s*([^\]\"'\s]+)''');
  for (final match in pattern.allMatches(selector)) {
    buffer.write(selector.substring(cursor, match.start));
    buffer.write('="');
    buffer.write(match.group(1));
    buffer.write('"');
    cursor = match.end;
  }
  buffer.write(selector.substring(cursor));
  return buffer.toString();
}

String? _attrFromElement(dom.Element element, String name) {
  final value = element.attributes[name]?.trim();
  if (value == null || value.isEmpty) return null;
  return value;
}

String _elementHref(dom.Element element) {
  final direct = _nodeHref(element);
  if (direct.isNotEmpty) return direct;
  return element.querySelector('a') == null
      ? ''
      : _nodeHref(element.querySelector('a')!);
}

String _animekoEpisodeHref(dom.Element element, String linkSelector) {
  final selector = linkSelector.trim();
  if (selector.isNotEmpty) {
    final selected = _querySelectorAll(element, selector);
    if (selected.isNotEmpty) {
      final selectedHref = _elementHref(selected.first);
      if (selectedHref.isNotEmpty) return selectedHref;
    }
  }
  return _elementHref(element);
}

bool _matchesOptionalPattern(String value, String pattern) {
  if (pattern.trim().isEmpty) return true;
  try {
    return RegExp(pattern, caseSensitive: false).hasMatch(value);
  } catch (_) {
    return true;
  }
}

int? _animekoEpisodeSort(String title, String pattern) {
  final text = _cleanText(title);
  if (text.isEmpty) return null;
  if (pattern.trim().isNotEmpty) {
    try {
      final match = RegExp(pattern, caseSensitive: false).firstMatch(text);
      final named = match?.namedGroup('ep');
      final value = _episodeNumberFromText(named ?? match?.group(1) ?? '');
      if (value != null) return value;
    } catch (_) {
      // Fall through to generic title parsing.
    }
  }
  return _episodeNumberFromText(text);
}

int? _episodeNumberFromText(String value) {
  final text = value.trim();
  if (text.isEmpty) return null;
  final direct = int.tryParse(text);
  if (direct != null) return direct;
  final match = RegExp(r'\d+').firstMatch(text);
  if (match != null) return int.tryParse(match.group(0)!);
  return null;
}

String _animekoSearchUrl(String template, String keyword) {
  return _searchUrl(template, keyword);
}

List<String> _animekoSearchKeywords(
  AnimeSubject subject,
  AnimekoWebSelectorConfig config,
) {
  final seen = <String>{};
  return _searchKeywords(subject)
      .map(
        (item) => config.searchRemoveSpecial
            ? item.replaceAll(RegExp(r'[^\w\u4e00-\u9fffぁ-んァ-ン一-龥]+'), ' ')
            : item,
      )
      .map(
        (item) => config.searchUseOnlyFirstWord
            ? item.split(RegExp(r'\s+')).first
            : item,
      )
      .map((item) => item.trim())
      .where((item) {
        final normalized = _normalizeTitle(item);
        return normalized.isNotEmpty && seen.add(normalized);
      })
      .toList(growable: false);
}

String _animekoVideoReferer(AnimekoWebSelectorConfig config, String fallback) {
  final referer = config.videoReferer.trim();
  return referer.isEmpty ? fallback : referer;
}
