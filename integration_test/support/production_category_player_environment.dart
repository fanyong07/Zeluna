import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/data/playback_prefetch_cache.dart';
import 'package:anime/src/data/playback_source_repository.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/rules/rule_playback_resolver.dart';

/// Isolates account/storage only. [line] must already come from the live backend
/// and production verifier. The page can neither invent media nor silently
/// substitute another provider: each mounted page owns exactly this live route.
/// No superclass bootstrap, profile, account box or credential provider is read.
class ProductionCategoryPlayerAccount extends AnimeController {
  ProductionCategoryPlayerAccount({
    required this.subject,
    required this.episode,
    required this.line,
    required this.resolver,
    required this.endpoint,
  });

  final AnimeSubject subject;
  final AnimeEpisode episode;
  final PlaybackLine line;
  final RulePlaybackResolver resolver;
  final String endpoint;
  final _clock = Stopwatch()..start();
  int firstFrames = 0;
  int? firstFrameMs;
  Duration latestPosition = Duration.zero;

  @override
  int get accountContextVersion => 0;

  @override
  bool isAccountContextCurrent(int version) => version == 0;

  @override
  Future<AnimeState> build() async => AnimeState(
    homeFeed: AnimeHomeFeed(
      hero: subject,
      recent: const [],
      recommended: const [],
      index: const [],
      categories: const [],
      tags: const [],
    ),
    settings: const PlaybackSettings(
      volumeBoost: -1,
      rememberLine: false,
      autoNext: false,
      autoSwitchLine: false,
    ),
    danmaku: const DanmakuSettings(enabled: false),
    services: ExternalServiceSettings(
      playbackBackendEnabled: true,
      playbackBackendEndpoint: endpoint,
      autoMatchSubtitle: false,
      dandanplayDanmakuEnabled: false,
      bilibiliDanmakuEnabled: false,
    ),
  );

  void _checkEpisode(AnimeSubject requested, AnimeEpisode requestedEpisode) {
    if (requested.identityKey != subject.identityKey ||
        requestedEpisode.id != episode.id) {
      throw StateError('production_category_episode_changed');
    }
  }

  @override
  Future<List<PlaybackLine>> linesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    RulePlaybackCancellationToken? cancellationToken,
  }) async {
    _checkEpisode(subject, episode);
    return cancellationToken?.isCancelled == true ? const [] : [line];
  }

  @override
  Future<List<PlaybackLine>> linesForEpisodeMode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    bool expandAll = false,
    RulePlaybackCancellationToken? cancellationToken,
  }) => linesForEpisode(subject, episode, cancellationToken: cancellationToken);

  @override
  Stream<PlaybackLineLookupUpdate> lineUpdatesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    RulePlaybackCancellationToken? cancellationToken,
  }) async* {
    final lines = await linesForEpisode(
      subject,
      episode,
      cancellationToken: cancellationToken,
    );
    if (cancellationToken?.isCancelled == true) return;
    yield PlaybackLineLookupUpdate(
      lines: lines,
      completedRules: 1,
      totalRules: 1,
      phase: PlaybackLineLookupPhase.complete,
    );
  }

  @override
  Future<PlaybackLine> verifyPlaybackLine(
    PlaybackLine candidate, {
    bool enrichMetadata = true,
    bool forceRefresh = false,
    RulePlaybackCancellationToken? cancellationToken,
  }) {
    if (candidate.id != line.id || candidate.providerId != line.providerId) {
      throw StateError('production_category_provider_changed');
    }
    return resolver.verifyPlaybackLine(
      line: candidate,
      enrichMetadata: enrichMetadata,
      forceRefresh: forceRefresh,
      cancellationToken: cancellationToken,
    );
  }

  @override
  Future<List<PlaybackLine>> prepareSingleBackupForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    required PlaybackLine currentLine,
    RulePlaybackCancellationToken? cancellationToken,
  }) async => const [];

  @override
  String? rememberedPlaybackProvider(AnimeSubject subject) => null;

  @override
  Future<void> rememberPlaybackProvider({
    required AnimeSubject subject,
    required PlaybackLine line,
    required int expectedAccountContextVersion,
  }) async {}

  @override
  PlaybackLine? prefetchedLineForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    String? preferredProviderId,
    Duration minValidity = const Duration(seconds: 60),
  }) => null;

  @override
  NextEpisodeWarmupBundle? prefetchedWarmupBundleForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    Duration minValidity = const Duration(seconds: 60),
  }) => null;

  @override
  Future<void> prefetchPlaybackForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    String? preferredProviderId,
    bool forceRefresh = false,
    RulePlaybackCancellationToken? cancellationToken,
  }) async {}

  @override
  Future<DanmakuTimeline> danmakuTimelineForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    bool forceRefresh = false,
  }) async => const DanmakuTimeline();

  @override
  Future<void> recordRecommendationFirstFrame(
    AnimeSubject subject,
    AnimeEpisode episode, {
    int? expectedAccountContextVersion,
  }) async {
    _checkEpisode(subject, episode);
    firstFrames++;
    firstFrameMs ??= _clock.elapsedMilliseconds;
  }

  @override
  Future<void> recordRecommendationEffectiveWatch(
    AnimeSubject subject,
    AnimeEpisode episode, {
    int? expectedAccountContextVersion,
  }) async {}

  @override
  Future<void> recordRecommendationCompleted(
    AnimeSubject subject,
    AnimeEpisode episode, {
    int? expectedAccountContextVersion,
  }) async {}

  @override
  Future<void> updatePlaybackProgress(
    AnimeSubject subject,
    AnimeEpisode episode, {
    required Duration position,
    required Duration duration,
    int? expectedAccountContextVersion,
  }) async {
    _checkEpisode(subject, episode);
    latestPosition = position;
  }
}
