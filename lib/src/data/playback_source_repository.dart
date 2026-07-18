import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../domain/anime_models.dart';
import '../domain/subject_content_type.dart';
import '../rules/rule_models.dart';
import '../rules/rule_playback_resolver.dart';
import '../rules/rule_plugin_repository.dart';

const _maxRulesPerQuickLookup = 12;
const _maxRulesPerGroupPerLookup = 6;
const _quickLookupConcurrency = 4;
const _expandedLookupConcurrency = 6;
const _expandedRuleTimeout = Duration(seconds: 14);
const _expandedLookupTotalBudget = Duration(seconds: 24);
const _deferredRulesAfterFirstHit = 2;
const _quickRuleTimeout = Duration(milliseconds: 4500);
const _quickLookupTotalBudget = Duration(milliseconds: 4800);
const _quickHitGracePeriod = Duration(milliseconds: 180);
const _availableRuleCacheTtl = Duration(minutes: 3);
const _unavailableRuleCacheTtl = Duration(seconds: 20);
const _ruleHealthTtl = Duration(minutes: 30);
const _maxCachedRuleLookups = 256;
const _maxRuleHealthEntries = 128;

abstract class PlaybackSourceRepository {
  Future<List<PlaybackLine>> linesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode,
  );

  Future<List<PlaybackLine>> linesForEpisodeMode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    bool expandAll = false,
  });
}

class InternetArchivePlaybackSourceRepository {
  InternetArchivePlaybackSourceRepository({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;

  Future<List<PlaybackLine>> linesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode,
  ) async {
    if (!subject.source.startsWith('archive:')) return const [];
    final identifier = subject.source.substring('archive:'.length).trim();
    if (identifier.isEmpty) return const [];
    final response = await _client
        .get(
          Uri.parse(
            'https://archive.org/metadata/${Uri.encodeComponent(identifier)}',
          ),
          headers: const {'Accept': 'application/json'},
        )
        .timeout(const Duration(seconds: 18));
    if (response.statusCode != 200) return const [];
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final files = decoded is Map ? decoded['files'] : null;
    if (files is! List) return const [];
    final metadata = decoded is Map && decoded['metadata'] is Map
        ? decoded['metadata'] as Map
        : const {};
    if (!_archiveRightsAllowed(metadata)) return const [];
    final candidates =
        files.whereType<Map>().where((item) {
          final name = item['name']?.toString().toLowerCase() ?? '';
          final format = item['format']?.toString().toLowerCase() ?? '';
          final size = int.tryParse(item['size']?.toString() ?? '') ?? 0;
          final excluded = _containsAny(name, const [
            '_thumb',
            'thumbnail',
            'sample',
            'preview',
            'trailer',
          ]);
          return !excluded &&
              size > 1024 * 1024 &&
              (name.endsWith('.mp4') ||
                  name.endsWith('.webm') ||
                  format.contains('mpeg4') ||
                  format.contains('h.264'));
        }).toList()..sort((a, b) {
          return _archiveFileScore(b).compareTo(_archiveFileScore(a));
        });
    final lines = await Future.wait(
      candidates.take(8).map((item) async {
        final name = item['name']?.toString() ?? '';
        final size = int.tryParse(item['size']?.toString() ?? '');
        final url =
            'https://archive.org/download/${Uri.encodeComponent(identifier)}/${Uri.encodeComponent(name)}';
        if (!await _probeVideo(Uri.parse(url))) return null;
        return PlaybackLine(
          id: 'archive:$identifier:$name',
          episodeId: episode.id,
          providerId: 'internet_archive',
          providerName: 'Internet Archive',
          title: name,
          quality: _archiveQuality(name),
          format: name.toLowerCase().endsWith('.webm') ? 'WebM' : 'MP4',
          url: url,
          sizeLabel: size == null
              ? null
              : '${(size / 1024 / 1024).toStringAsFixed(1)} MB',
          available: true,
          message: 'Internet Archive 已验证公开媒体文件',
        );
      }),
    );
    return lines.whereType<PlaybackLine>().take(6).toList(growable: false);
  }

  Future<bool> _probeVideo(Uri uri) async {
    try {
      final request = http.Request('GET', uri)
        ..headers['Range'] = 'bytes=0-1023';
      final response = await _client
          .send(request)
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200 && response.statusCode != 206) {
        return false;
      }
      final contentType = response.headers['content-type']?.toLowerCase() ?? '';
      final typeLooksPlayable =
          contentType.startsWith('video/') ||
          contentType.contains('octet-stream') ||
          contentType.contains('mp4') ||
          contentType.contains('webm');
      if (!typeLooksPlayable) return false;
      await response.stream.take(1).drain<void>();
      return true;
    } catch (_) {
      return false;
    }
  }
}

class EmptyPlaybackSourceRepository implements PlaybackSourceRepository {
  const EmptyPlaybackSourceRepository();

  @override
  Future<List<PlaybackLine>> linesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode,
  ) {
    return linesForEpisodeMode(subject, episode);
  }

  @override
  Future<List<PlaybackLine>> linesForEpisodeMode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    bool expandAll = false,
  }) async {
    return [
      PlaybackLine(
        id: 'placeholder:${subject.id}:${episode.id}',
        episodeId: episode.id,
        providerId: 'custom',
        providerName: '待接入源',
        title: '${subject.title} - 第${episode.number}集',
        quality: '待接入',
        format: 'HLS/MP4',
        available: false,
        message: '这里是播放源接入点。后续只需要按当前 episode 返回线路列表即可。',
      ),
    ];
  }
}

class RulePlaybackSourceRepository implements PlaybackSourceRepository {
  RulePlaybackSourceRepository({
    required RulePluginRepository repository,
    required RulePluginState ruleState,
    RulePlaybackResolver? resolver,
    Duration quickLookupBudget = _quickLookupTotalBudget,
  }) : _repository = repository,
       _ruleState = ruleState,
       _resolver = resolver ?? _sharedResolver,
       _quickLookupBudget = quickLookupBudget;

  final RulePluginRepository _repository;
  final RulePluginState _ruleState;
  final RulePlaybackResolver _resolver;
  final Duration _quickLookupBudget;

  static final RulePlaybackResolver _sharedResolver = RulePlaybackResolver();
  static final LinkedHashMap<String, _CachedRuleLookup> _ruleLookupCache =
      LinkedHashMap<String, _CachedRuleLookup>();
  static final Map<String, Future<List<PlaybackLine>>> _inFlightRuleLookups =
      <String, Future<List<PlaybackLine>>>{};
  static final LinkedHashMap<String, _RuleHealth> _ruleHealth =
      LinkedHashMap<String, _RuleHealth>();

  @override
  Future<List<PlaybackLine>> linesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode,
  ) {
    return linesForEpisodeMode(subject, episode);
  }

  @override
  Future<List<PlaybackLine>> linesForEpisodeMode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    bool expandAll = false,
  }) async {
    final type = _contentTypeFor(subject);
    final rules = _selectLookupRules(
      _repository.playbackRulesFor(_ruleState, type),
      expandAll: expandAll,
    );
    if (rules.isEmpty) {
      return const EmptyPlaybackSourceRepository().linesForEpisode(
        subject,
        episode,
      );
    }
    return expandAll
        ? _resolveExpandedRules(rules, subject, episode)
        : _resolveQuickRules(rules, subject, episode);
  }

  Future<List<PlaybackLine>> _resolveQuickRules(
    List<RulePlugin> rules,
    AnimeSubject subject,
    AnimeEpisode episode,
  ) async {
    final pending = <int, Future<_RuleResolution>>{};
    final completed = <int, List<PlaybackLine>>{};
    final budgetStopwatch = Stopwatch()..start();
    var nextRuleIndex = 0;
    var foundAvailableLine = false;
    var completionsAfterFirstHit = 0;
    DateTime? graceDeadline;

    void fillLookupSlots() {
      while (!foundAvailableLine &&
          budgetStopwatch.elapsed < _quickLookupBudget &&
          pending.length < _quickLookupConcurrency &&
          nextRuleIndex < rules.length) {
        final index = nextRuleIndex++;
        pending[index] = _resolveRuleForQuickLookup(
          index,
          rules[index],
          subject,
          episode,
        );
      }
    }

    fillLookupSlots();
    while (pending.isNotEmpty) {
      final budgetRemaining = _quickLookupBudget - budgetStopwatch.elapsed;
      if (budgetRemaining <= Duration.zero) break;
      var waitTimeout = budgetRemaining;
      if (foundAvailableLine) {
        if (completionsAfterFirstHit >= _deferredRulesAfterFirstHit) break;
        final remaining = graceDeadline!.difference(DateTime.now());
        if (remaining <= Duration.zero) break;
        if (remaining < waitTimeout) waitTimeout = remaining;
      }

      final resolution = await _nextResolution(
        pending.values,
        timeout: waitTimeout,
      );
      if (resolution == null) break;
      pending.remove(resolution.index);
      completed[resolution.index] = resolution.lines;

      if (!foundAvailableLine &&
          resolution.lines.any((line) => line.available)) {
        foundAvailableLine = true;
        graceDeadline = DateTime.now().add(_quickHitGracePeriod);
      } else if (foundAvailableLine) {
        completionsAfterFirstHit++;
      }
      fillLookupSlots();
    }

    budgetStopwatch.stop();
    final orderedIndexes = completed.keys.toList()..sort();
    return [for (final index in orderedIndexes) ...completed[index]!];
  }

  Future<_RuleResolution> _resolveRuleForQuickLookup(
    int index,
    RulePlugin rule,
    AnimeSubject subject,
    AnimeEpisode episode,
  ) async {
    try {
      final lines = await _resolveRuleCached(
        rule,
        subject,
        episode,
        verifyPlayable: false,
      ).timeout(_quickRuleTimeout);
      return _RuleResolution(index, lines);
    } on TimeoutException {
      return _RuleResolution(index, const []);
    }
  }

  Future<_RuleResolution?> _nextResolution(
    Iterable<Future<_RuleResolution>> pending, {
    Duration? timeout,
  }) async {
    try {
      final next = Future.any(pending);
      return timeout == null ? await next : await next.timeout(timeout);
    } on TimeoutException {
      return null;
    }
  }

  Future<List<PlaybackLine>> _resolveExpandedRules(
    List<RulePlugin> rules,
    AnimeSubject subject,
    AnimeEpisode episode,
  ) async {
    final resolved = List<List<PlaybackLine>?>.filled(rules.length, null);
    var nextRuleIndex = 0;

    Future<void> worker() async {
      while (true) {
        final index = nextRuleIndex++;
        if (index >= rules.length) return;
        try {
          resolved[index] = await _resolveRuleCached(
            rules[index],
            subject,
            episode,
            verifyPlayable: true,
          ).timeout(_expandedRuleTimeout);
        } on TimeoutException {
          resolved[index] = const <PlaybackLine>[];
        }
      }
    }

    final workerCount = rules.length < _expandedLookupConcurrency
        ? rules.length
        : _expandedLookupConcurrency;
    final workers = Future.wait(List.generate(workerCount, (_) => worker()));
    await Future.any<void>([
      workers,
      Future<void>.delayed(_expandedLookupTotalBudget),
    ]);
    return [for (final lines in resolved) ...?lines];
  }

  Future<List<PlaybackLine>> _resolveRuleCached(
    RulePlugin rule,
    AnimeSubject subject,
    AnimeEpisode episode, {
    required bool verifyPlayable,
  }) {
    final now = DateTime.now();
    final cacheKey = _ruleLookupCacheKey(
      rule,
      subject,
      episode,
      verifyPlayable: verifyPlayable,
    );
    final cached = _ruleLookupCache.remove(cacheKey);
    if (cached != null && cached.expiresAt.isAfter(now)) {
      _ruleLookupCache[cacheKey] = cached;
      return Future.value(cached.lines);
    }

    final inFlight = _inFlightRuleLookups[cacheKey];
    if (inFlight != null) return inFlight;

    final stopwatch = Stopwatch()..start();
    late final Future<List<PlaybackLine>> lookup;
    lookup = _resolver
        .resolveRule(
          rule: rule,
          subject: subject,
          episode: episode,
          verifyPlayable: verifyPlayable,
        )
        .then((lines) {
          stopwatch.stop();
          final immutableLines = List<PlaybackLine>.unmodifiable(lines);
          final available = immutableLines.any((line) => line.available);
          _rememberRuleHealth(rule, available, stopwatch.elapsed);
          _storeCachedRuleLookup(
            cacheKey,
            immutableLines,
            DateTime.now().add(
              available ? _availableRuleCacheTtl : _unavailableRuleCacheTtl,
            ),
          );
          return immutableLines;
        })
        .catchError((Object _) => const <PlaybackLine>[])
        .whenComplete(() {
          if (identical(_inFlightRuleLookups[cacheKey], lookup)) {
            _inFlightRuleLookups.remove(cacheKey);
          }
        });
    _inFlightRuleLookups[cacheKey] = lookup;
    return lookup;
  }

  void _storeCachedRuleLookup(
    String key,
    List<PlaybackLine> lines,
    DateTime expiresAt,
  ) {
    _ruleLookupCache.remove(key);
    _ruleLookupCache[key] = _CachedRuleLookup(lines, expiresAt);
    while (_ruleLookupCache.length > _maxCachedRuleLookups) {
      _ruleLookupCache.remove(_ruleLookupCache.keys.first);
    }
  }

  void _rememberRuleHealth(RulePlugin rule, bool available, Duration latency) {
    final key = _ruleHealthKey(rule);
    final previous = _ruleHealth.remove(key);
    _ruleHealth[key] = available
        ? _RuleHealth(
            lastSuccessAt: DateTime.now(),
            latency: latency,
            consecutiveFailures: 0,
          )
        : _RuleHealth(
            lastSuccessAt: previous?.lastSuccessAt,
            lastFailureAt: DateTime.now(),
            latency: previous?.latency,
            consecutiveFailures: (previous?.consecutiveFailures ?? 0) + 1,
          );
    while (_ruleHealth.length > _maxRuleHealthEntries) {
      _ruleHealth.remove(_ruleHealth.keys.first);
    }
  }

  List<RulePlugin> _selectLookupRules(
    List<RulePlugin> rules, {
    required bool expandAll,
  }) {
    if (rules.isEmpty) return const [];
    final validRules = rules.where(_isValidLookupRule).toList();
    final sorted = [...validRules]
      ..sort((a, b) {
        if (!expandAll) {
          final quickSearch = _quickSearchRank(
            a,
          ).compareTo(_quickSearchRank(b));
          if (quickSearch != 0) return quickSearch;
          final health = _ruleHealthRank(a).compareTo(_ruleHealthRank(b));
          if (health != 0) return health;
          final latency = _knownLatency(a).compareTo(_knownLatency(b));
          if (latency != 0) return latency;
        }
        final priority = a.priority.compareTo(b.priority);
        if (priority != 0) return priority;
        final quality = b.qualityScore.compareTo(a.qualityScore);
        if (quality != 0) return quality;
        return a.name.compareTo(b.name);
      });
    if (expandAll) return sorted;

    final grouped = <String, List<RulePlugin>>{};
    for (final rule in sorted) {
      final groupId = rule.groupId.trim();
      final key = groupId.isEmpty ? 'rule:${rule.id}' : 'group:$groupId';
      grouped.putIfAbsent(key, () => <RulePlugin>[]).add(rule);
    }
    final groupedCount = <String, int>{};
    final selected = <RulePlugin>[];
    var groupOffset = 0;
    var madeProgress = true;
    while (selected.length < _maxRulesPerQuickLookup && madeProgress) {
      madeProgress = false;
      for (final entry in grouped.entries) {
        final groupId = entry.key;
        final groupRules = entry.value;
        if (groupOffset >= groupRules.length) continue;
        final count = groupedCount[groupId] ?? 0;
        if (count >= _maxRulesPerGroupPerLookup) continue;
        selected.add(groupRules[groupOffset]);
        groupedCount[groupId] = count + 1;
        madeProgress = true;
        if (selected.length >= _maxRulesPerQuickLookup) break;
      }
      groupOffset++;
    }
    return selected;
  }

  bool _isValidLookupRule(RulePlugin rule) {
    final endpoint = Uri.tryParse(rule.baseUrl.trim());
    return endpoint != null && endpoint.hasScheme && endpoint.host.isNotEmpty;
  }

  int _quickSearchRank(RulePlugin rule) => rule.quickSearch ? 0 : 1;

  int _ruleHealthRank(RulePlugin rule) {
    final health = _activeRuleHealth(rule);
    if (health == null) return 1;
    if (health.consecutiveFailures >= 2 &&
        health.lastFailureAt != null &&
        (health.lastSuccessAt == null ||
            health.lastFailureAt!.isAfter(health.lastSuccessAt!))) {
      return 2;
    }
    if (health.lastSuccessAt != null) return 0;
    return 1;
  }

  int _knownLatency(RulePlugin rule) {
    return _activeRuleHealth(rule)?.latency?.inMilliseconds ?? 1 << 30;
  }

  _RuleHealth? _activeRuleHealth(RulePlugin rule) {
    final key = _ruleHealthKey(rule);
    final health = _ruleHealth[key];
    if (health == null) return null;
    final successAt = health.lastSuccessAt;
    final failureAt = health.lastFailureAt;
    final latest = successAt == null
        ? failureAt
        : failureAt == null || successAt.isAfter(failureAt)
        ? successAt
        : failureAt;
    if (latest == null || DateTime.now().difference(latest) > _ruleHealthTtl) {
      _ruleHealth.remove(key);
      return null;
    }
    return health;
  }

  String _ruleLookupCacheKey(
    RulePlugin rule,
    AnimeSubject subject,
    AnimeEpisode episode, {
    required bool verifyPlayable,
  }) {
    final verification = verifyPlayable ? 'verified' : 'unverified';
    return '${identityHashCode(_resolver)}|$verification|${rule.id}|${rule.version}|'
        '${rule.updatedAt.microsecondsSinceEpoch}|${rule.engine}|'
        '${rule.baseUrl}|${rule.searchUrl}|${subject.source}|${subject.id}|'
        '${subject.title}|${subject.originalTitle}|${episode.id}|'
        '${episode.number}|${episode.title}';
  }

  String _ruleHealthKey(RulePlugin rule) {
    return '${rule.contentType.name}|${rule.id}|${rule.version}|'
        '${rule.updatedAt.microsecondsSinceEpoch}';
  }

  RuleContentType _contentTypeFor(AnimeSubject subject) {
    return switch (subjectContentTypeOf(subject)) {
      SubjectContentType.anime => RuleContentType.anime,
      SubjectContentType.series => RuleContentType.series,
      SubjectContentType.movie => RuleContentType.movie,
    };
  }
}

class _RuleResolution {
  const _RuleResolution(this.index, this.lines);

  final int index;
  final List<PlaybackLine> lines;
}

class _CachedRuleLookup {
  const _CachedRuleLookup(this.lines, this.expiresAt);

  final List<PlaybackLine> lines;
  final DateTime expiresAt;
}

class _RuleHealth {
  const _RuleHealth({
    this.lastSuccessAt,
    this.lastFailureAt,
    this.latency,
    required this.consecutiveFailures,
  });

  final DateTime? lastSuccessAt;
  final DateTime? lastFailureAt;
  final Duration? latency;
  final int consecutiveFailures;
}

bool _containsAny(String text, List<String> patterns) {
  return patterns.any(text.contains);
}

String _archiveQuality(String name) {
  final lower = name.toLowerCase();
  final match = RegExp(r'(2160|1440|1080|720|480)p').firstMatch(lower);
  return match?.group(0)?.toUpperCase() ?? '公开原片';
}

bool _archiveRightsAllowed(Map metadata) {
  final license = [
    metadata['licenseurl'],
    metadata['rights'],
    metadata['usage'],
  ].whereType<Object>().map((item) => item.toString()).join(' ').toLowerCase();
  if (_containsAny(license, const [
    'creativecommons.org',
    'public domain',
    'cc0',
    'cc by',
  ])) {
    return true;
  }
  final collection = metadata['collection'];
  final collections = collection is List
      ? collection.map((item) => item.toString().toLowerCase())
      : [collection?.toString().toLowerCase() ?? ''];
  return collections.any(
    (item) => _containsAny(item, const [
      'feature_films',
      'prelinger',
      'classic_tv',
      'animationandcartoons',
    ]),
  );
}

int _archiveFileScore(Map item) {
  final name = item['name']?.toString().toLowerCase() ?? '';
  final format = item['format']?.toString().toLowerCase() ?? '';
  var score = 0;
  if (name.endsWith('.mp4')) score += 20;
  if (format.contains('h.264') || format.contains('mpeg4')) score += 12;
  if (RegExp(r'(2160|1440|1080|720)p').hasMatch(name)) score += 8;
  if (item['source']?.toString() == 'derivative') score += 2;
  return score;
}
