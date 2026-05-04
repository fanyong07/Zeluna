import '../domain/anime_models.dart';
import '../rules/rule_models.dart';
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
  }) : _repository = repository,
       _ruleState = ruleState;

  final RulePluginRepository _repository;
  final RulePluginState _ruleState;

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
    return [
      for (final rule in rules)
        PlaybackLine(
          id: 'rule:${rule.id}:${episode.id}',
          episodeId: episode.id,
          providerId: rule.id,
          providerName: rule.name,
          title: _lineTitle(rule, subject, episode),
          quality: rule.tags.contains('4K') ? '4K/HD' : 'HD',
          format: rule.engine,
          available: false,
          message: rule.requiresCaptcha
              ? '规则已安装，但该源需要验证码或 WebView 处理后才能解析播放。'
              : '规则已安装，后续在这里接入 ${rule.engine} 解析器返回真实播放地址。',
        ),
    ];
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

  String _lineTitle(
    RulePlugin rule,
    AnimeSubject subject,
    AnimeEpisode episode,
  ) {
    if (rule.contentType == RuleContentType.movie) {
      return '${subject.title} · 正片';
    }
    return '${subject.title} · 第${episode.number}集';
  }
}

bool _containsAny(String text, List<String> patterns) {
  return patterns.any(text.contains);
}
