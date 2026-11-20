part of '../rule_playback_resolver.dart';

// Runtime-backed TVBox engines: drpy and Android CSP.

extension _ScriptSourceResolution on RulePlaybackResolver {
  Future<List<PlaybackLine>> _resolveDrpy(
    http.Client client,
    RulePlugin rule,
    AnimeSubject subject,
    AnimeEpisode episode, {
    required bool verifyPlayable,
  }) async {
    final raw = rule.rawConfig;
    final inlineSource = raw['inlineSource']?.toString() ?? '';
    final extUrl = raw['extUrl']?.toString() ?? '';
    final runtimeResult = await _drpyRuntime.resolve(
      DrpyRuntimeRequest(
        ruleId: rule.id,
        keyword: subject.title,
        episodeNumber: episode.number,
        episodeTitle: episode.title,
        ruleSource: inlineSource,
        ruleUrl: extUrl,
        requestHeaders: filterRuleRequestHeaders(
          rule.requestHeaders,
          rule.effectiveManifest,
        ),
        credentialOrigin: rule.baseUrl,
      ),
      client: client,
      cancellationToken: _activeRulePlaybackResolveContext?.cancellationToken,
    );
    if (runtimeResult.error != null || runtimeResult.candidates.isEmpty) {
      return const [];
    }

    final lines = <PlaybackLine>[];
    for (final candidate in runtimeResult.candidates) {
      if (candidate.requiresSniffing) continue;
      if (_activeRulePlaybackResolveContext?.cancellationToken?.isCancelled ??
          false) {
        return const [];
      }
      var referer = '';
      for (final entry in candidate.headers.entries) {
        if (entry.key.toLowerCase() == 'referer' &&
            entry.value.trim().isNotEmpty) {
          referer = entry.value.trim();
          break;
        }
      }
      final playableUrl = _normalizePlayableUrl(candidate.url, referer);
      final target = Uri.tryParse(playableUrl);
      if (target == null ||
          !const {'http', 'https'}.contains(target.scheme.toLowerCase()) ||
          target.host.isEmpty) {
        continue;
      }
      try {
        await _drpyRuntime.ensurePublicUri(target);
      } catch (_) {
        continue;
      }
      final baseHeaders = _headers(rule: rule, referer: referer);
      final credentialOrigin = Uri.tryParse(rule.baseUrl.trim());
      final headers = credentialOrigin == null
          ? withoutRuleCredentials(baseHeaders)
          : ruleChildHeaders(credentialOrigin, target, baseHeaders);
      for (final entry in candidate.headers.entries) {
        final name = entry.key.trim();
        final value = entry.value.trim();
        if (name.isNotEmpty && value.isNotEmpty) headers[name] = value;
      }
      final probe = await runZoned(
        () => _playableCandidateStatus(
          client,
          playableUrl,
          headers,
          verifyPlayable: verifyPlayable,
        ),
        zoneValues: {_drpyPublicMediaProbeKey: true},
      );
      if (!probe.available) continue;
      final lineName = candidate.lineName.trim().isEmpty
          ? rule.name
          : candidate.lineName.trim();
      lines.add(
        _availableLine(
          rule,
          episode,
          url: playableUrl,
          title: '${episode.displayTitle} · $lineName',
          probe: probe,
          referer: referer,
          headers: headers,
          publicHttpOnly: true,
        ),
      );
    }
    return lines;
  }

  Future<List<PlaybackLine>> _resolveAndroidCsp(
    http.Client client,
    RulePlugin rule,
    AnimeSubject subject,
    AnimeEpisode episode, {
    required bool verifyPlayable,
  }) async {
    if (!_cspBridge.isSupported) return const [];
    final raw = rule.rawConfig;
    final spiderMd5 = androidCspSpiderMd5(raw);
    final api = androidCspApi(raw);
    if (spiderMd5 == null ||
        api.isEmpty ||
        !isAuditedAndroidCspConfig(raw, fallbackApi: api)) {
      return const [];
    }

    try {
      final capabilities = await _cspCapabilities();
      final package = capabilities.packageForMd5(spiderMd5);
      if (package == null || !package.allowsApi(api)) return const [];
      await _prepareCspPackage(spiderMd5);
      if (_activeRulePlaybackResolveContext?.cancellationToken?.isCancelled ??
          false) {
        return const [];
      }

      final rawSiteKey = androidCspSiteKey(raw, rule.id);
      final siteKey = rawSiteKey.length <= 150
          ? rawSiteKey
          : '${rawSiteKey.substring(0, 120)}:${stableDigest(rule.id).substring(0, 24)}';
      final site = AndroidCspSite(
        spiderMd5: spiderMd5,
        siteKey: siteKey,
        api: api,
        ext: androidCspEncodedExt(raw),
      );
      await _cspBridge.initialize(site);

      _RankedResult<Map<String, dynamic>>? bestMatch;
      var preference = 0;
      for (final keyword in _searchKeywords(subject)) {
        if (_activeRulePlaybackResolveContext?.cancellationToken?.isCancelled ??
            false) {
          return const [];
        }
        try {
          final decoded = jsonDecode(
            await _cspBridge.searchContent(
              site: site,
              keyword: keyword,
              quick: false,
              page: '1',
            ),
          );
          final ranked = _rankBestTvBoxItem(
            _tvBoxItems(decoded),
            subject,
            preference++,
          );
          if (ranked != null &&
              (bestMatch == null || ranked.score > bestMatch.score)) {
            bestMatch = ranked;
          }
        } catch (_) {
          preference++;
        }
      }
      var item = bestMatch?.value;
      if (item == null) return const [];

      if (_tvBoxPlayUrl(item).isEmpty) {
        final vodId = item['vod_id']?.toString().trim() ?? '';
        if (vodId.isEmpty) return const [];
        final details = _tvBoxItems(
          jsonDecode(await _cspBridge.detailContent(site: site, ids: [vodId])),
        );
        if (details.isEmpty) return const [];
        item = details.first;
      }

      final groups = _tvBoxPlayGroups(item);
      if (groups.isEmpty) return const [];
      return _collectPlaybackCandidates(
        [
          for (var index = 0; index < groups.length; index++)
            () => _resolveAndroidCspLine(
              client,
              rule,
              episode,
              site,
              groups[index],
              androidCspVipFlags(raw),
              verifyPlayable: verifyPlayable,
            ),
        ],
        verifyPlayable: verifyPlayable,
        candidateTimeout: timeout,
      );
    } catch (_) {
      // CSP failures are remembered by the rule-health layer, but are not
      // emitted as dozens of dead playback rows. The imported rule remains.
      return const [];
    }
  }

  Future<PlaybackLine?> _resolveAndroidCspLine(
    http.Client client,
    RulePlugin rule,
    AnimeEpisode episode,
    AndroidCspSite site,
    _TvBoxPlayGroup group,
    List<String> vipFlags, {
    required bool verifyPlayable,
  }) async {
    final selected = _pickTvBoxEpisode(group.episodes, episode);
    if (selected == null) return null;
    try {
      final decoded = jsonDecode(
        await _cspBridge.playerContent(
          site: site,
          flag: group.name,
          id: selected.url,
          vipFlags: vipFlags,
        ),
      );
      if (decoded is! Map) return null;
      final result = decoded.cast<String, dynamic>();
      final rawUrl = result['url']?.toString().trim() ?? '';
      if (rawUrl.isEmpty) return null;
      final base = androidCspPinnedBase(site.spiderMd5);
      final playableUrl = _normalizePlayableUrl(rawUrl, base);
      if (!_looksPlayable(playableUrl)) return null;

      final parse = int.tryParse(result['parse']?.toString() ?? '') ?? 0;
      if (parse != 0 && !_isExplicitPlayableUrl(playableUrl)) return null;
      final playerHeaders = _cspPlayerHeaders(
        result['header'] ?? result['headers'],
      );
      final referer = _headerValue(playerHeaders, 'referer') ?? base;
      final headers = _headers(rule: rule, referer: referer)
        ..addAll(playerHeaders);
      final probe = await _playableCandidateStatus(
        client,
        playableUrl,
        headers,
        verifyPlayable: verifyPlayable,
      );
      if (!probe.available) return null;
      final lineName = group.name.trim().isEmpty
          ? rule.name
          : group.name.trim();
      return _availableLine(
        rule,
        episode,
        url: playableUrl,
        title: '${selected.title} · $lineName',
        routeKey: '${group.index}:${group.name}',
        probe: probe,
        referer: referer,
        headers: headers,
      );
    } catch (_) {
      return null;
    }
  }

  Future<AndroidCspCapabilities> _cspCapabilities() =>
      _cspCapabilitiesRequest ??= _cspBridge.getCapabilities();

  Future<void> _prepareCspPackage(String spiderMd5) async {
    final existing = _cspPreparationRequests[spiderMd5];
    if (existing != null) return existing;
    late final Future<void> request;
    request = _cspBridge.prepare(spiderMd5).then<void>((prepared) {
      if (prepared.md5 != spiderMd5) {
        throw const AndroidCspException(
          'csp_artifact_hash_mismatch',
          'The prepared CSP package did not match the requested digest.',
        );
      }
    });
    _cspPreparationRequests[spiderMd5] = request;
    try {
      await request;
    } catch (_) {
      if (identical(_cspPreparationRequests[spiderMd5], request)) {
        _cspPreparationRequests.remove(spiderMd5);
      }
      rethrow;
    }
  }

  Map<String, String> _cspPlayerHeaders(Object? value) {
    Object? decoded = value;
    if (decoded is String && decoded.trim().startsWith('{')) {
      try {
        decoded = jsonDecode(decoded);
      } catch (_) {
        return const {};
      }
    }
    if (decoded is! Map) return const {};
    final result = <String, String>{};
    for (final entry in decoded.entries) {
      final name = entry.key.toString().trim();
      final headerValue = entry.value?.toString().trim() ?? '';
      if (name.isNotEmpty && headerValue.isNotEmpty) {
        result[name] = headerValue;
      }
    }
    return result;
  }

  String? _headerValue(Map<String, String> headers, String name) {
    final normalized = name.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == normalized) return entry.value;
    }
    return null;
  }
}
