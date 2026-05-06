import '../domain/anime_models.dart';
import '../rules/rule_models.dart';
import '../rules/rule_playback_resolver.dart';
import '../rules/rule_plugin_repository.dart';

const _maxRulesPerQuickLookup = 12;
const _maxRulesPerFullLookup = 48;
const _maxRulesPerGroupPerLookup = 6;
const _deferredRulesAfterFirstHit = 2;

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
  const RulePlaybackSourceRepository({
    required RulePluginRepository repository,
    required RulePluginState ruleState,
    RulePlaybackResolver resolver = const RulePlaybackResolver(),
  }) : _repository = repository,
       _ruleState = ruleState,
       _resolver = resolver;

  final RulePluginRepository _repository;
  final RulePluginState _ruleState;
  final RulePlaybackResolver _resolver;

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
      _repository.enabledRulesFor(_ruleState, type),
      expandAll: expandAll,
    );
    if (rules.isEmpty) {
      return const EmptyPlaybackSourceRepository().linesForEpisode(
        subject,
        episode,
      );
    }
    final lines = <PlaybackLine>[];
    for (var index = 0; index < rules.length; index++) {
      final rule = rules[index];
      final group = await _resolver.resolveRule(
        rule: rule,
        subject: subject,
        episode: episode,
      );
      lines.addAll(group);
      if (!expandAll && group.any((line) => line.available)) {
        for (final rule
            in rules.skip(index + 1).take(_deferredRulesAfterFirstHit)) {
          final extraGroup = await _resolver.resolveRule(
            rule: rule,
            subject: subject,
            episode: episode,
          );
          lines.addAll(extraGroup);
        }
        break;
      }
    }
    return lines;
  }

  List<RulePlugin> _selectLookupRules(
    List<RulePlugin> rules, {
    required bool expandAll,
  }) {
    if (rules.isEmpty) return const [];
    final sorted = [...rules]
      ..sort((a, b) {
        final priority = a.priority.compareTo(b.priority);
        if (priority != 0) return priority;
        final quality = b.qualityScore.compareTo(a.qualityScore);
        if (quality != 0) return quality;
        return a.name.compareTo(b.name);
      });
    final groupedCount = <String, int>{};
    final selected = <RulePlugin>[];
    final maxRules = expandAll
        ? _maxRulesPerFullLookup
        : _maxRulesPerQuickLookup;
    final maxRulesPerGroup = expandAll
        ? _maxRulesPerFullLookup
        : _maxRulesPerGroupPerLookup;
    for (final rule in sorted) {
      final groupId = rule.groupId.trim();
      if (groupId.isNotEmpty) {
        final count = groupedCount[groupId] ?? 0;
        if (count >= maxRulesPerGroup) continue;
        groupedCount[groupId] = count + 1;
      }
      selected.add(rule);
      if (selected.length >= maxRules) break;
    }
    return selected;
  }

  RuleContentType _contentTypeFor(AnimeSubject subject) {
    final source = subject.source.toLowerCase();
    final platform = subject.platform.toLowerCase();
    final text = [
      subject.title,
      subject.originalTitle,
      subject.platform,
      subject.region,
      ...subject.categories.map((item) => item.name),
      ...subject.tags.map((item) => item.name),
    ].join(' ').toLowerCase();
    if (source == 'wikidata' ||
        platform == 'movie' ||
        platform.contains('movie') ||
        _containsAny(text, const ['电影', '正片'])) {
      return RuleContentType.movie;
    }
    if (source == 'tvmaze' ||
        _containsAny(platform, const ['scripted', 'series', 'show', 'drama']) ||
        _containsAny(text, const [
          'drama',
          'series',
          '电视剧',
          '剧集',
          '连续剧',
          '韩剧',
          '美剧',
          '英剧',
          '日剧',
          '国产剧',
          '港剧',
          '台剧',
          '泰剧',
        ])) {
      return RuleContentType.series;
    }
    return RuleContentType.anime;
  }
}

bool _containsAny(String text, List<String> patterns) {
  return patterns.any(text.contains);
}
