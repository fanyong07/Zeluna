import '../domain/anime_models.dart';
import '../rules/rule_models.dart';
import '../rules/rule_playback_resolver.dart';
import '../rules/rule_plugin_repository.dart';

abstract class PlaybackSourceRepository {
  Future<List<PlaybackLine>> linesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode,
  );
}

class EmptyPlaybackSourceRepository implements PlaybackSourceRepository {
  const EmptyPlaybackSourceRepository();

  @override
  Future<List<PlaybackLine>> linesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode,
  ) async {
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
  ) async {
    final type = _contentTypeFor(subject);
    final rules = _repository.enabledRulesFor(_ruleState, type);
    if (rules.isEmpty) {
      return const EmptyPlaybackSourceRepository().linesForEpisode(
        subject,
        episode,
      );
    }
    final groups = await Future.wait(
      rules.map(
        (rule) => _resolver.resolveRule(
          rule: rule,
          subject: subject,
          episode: episode,
        ),
      ),
    );
    return groups.expand((items) => items).toList(growable: false);
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
