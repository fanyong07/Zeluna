import 'dart:io';

import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/data/playback_source_repository.dart';
import 'package:anime/src/data/playback_prefetch_cache.dart';
import 'package:anime/src/rules/rule_playback_cancellation.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const playerTestSubject = AnimeSubject(
  id: -9001,
  title: 'Fullscreen integration fixture',
  originalTitle: '',
  summary: '',
  coverUrl: null,
  bannerUrl: null,
  date: null,
  platform: 'local',
  language: '',
  region: '',
  status: '',
  categories: [],
  tags: [],
  totalEpisodes: 2,
  source: 'direct',
);
const playerTestEpisode = AnimeEpisode(
  id: -9002,
  subjectId: -9001,
  number: 1,
  title: 'Local video',
  airdate: null,
  duration: '180',
  description: '',
);

const playerTestSecondEpisode = AnimeEpisode(
  id: -9003,
  subjectId: -9001,
  number: 2,
  title: 'Second generated video',
  airdate: null,
  duration: '180',
  description: '',
);

class IsolatedPlayerTestAccount extends AnimeController {
  IsolatedPlayerTestAccount({this.mediaBase});
  final Uri? mediaBase;

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

  PlaybackLine lineFor(AnimeEpisode episode, {bool backup = false}) {
    final provider = backup ? 'backup' : 'primary';
    return PlaybackLine(
      id: 'integration:${episode.id}:$provider',
      episodeId: episode.id,
      providerId: 'integration:$provider',
      providerName: 'Loopback $provider',
      title: 'Generated episode ${episode.number}',
      quality: 'Original',
      format: 'avi',
      url: mediaBase!
          .resolve('/episode-${episode.number}-$provider.avi')
          .toString(),
      available: true,
      clientVerified: true,
    );
  }

  @override
  Future<List<PlaybackLine>> linesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    RulePlaybackCancellationToken? cancellationToken,
  }) async => [lineFor(episode), lineFor(episode, backup: true)];

  @override
  Stream<PlaybackLineLookupUpdate> lineUpdatesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    RulePlaybackCancellationToken? cancellationToken,
  }) async* {
    yield PlaybackLineLookupUpdate(
      lines: await linesForEpisode(
        subject,
        episode,
        cancellationToken: cancellationToken,
      ),
      completedRules: 1,
      totalRules: 1,
      phase: PlaybackLineLookupPhase.complete,
    );
  }

  @override
  Future<PlaybackLine> verifyPlaybackLine(
    PlaybackLine line, {
    bool enrichMetadata = true,
    bool forceRefresh = false,
    RulePlaybackCancellationToken? cancellationToken,
  }) async => line;

  @override
  Future<List<PlaybackLine>> prepareSingleBackupForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    required PlaybackLine currentLine,
    RulePlaybackCancellationToken? cancellationToken,
  }) async => [lineFor(episode, backup: true)];

  final danmakuRequests = <int>[];
  void enableDanmaku() {
    state = AsyncData(
      state.requireValue.copyWith(
        danmaku: const DanmakuSettings(enabled: true),
      ),
    );
  }

  var firstFrames = 0;
  Duration latestPosition = Duration.zero;

  @override
  Future<AnimeState> build() async => const AnimeState(
    homeFeed: AnimeHomeFeed(
      hero: playerTestSubject,
      recent: [],
      recommended: [],
      index: [],
      categories: [],
      tags: [],
    ),
    settings: PlaybackSettings(
      rememberLine: false,
      autoNext: false,
      autoSwitchLine: false,
    ),
    danmaku: DanmakuSettings(enabled: false),
  );

  @override
  String? rememberedPlaybackProvider(AnimeSubject subject) => null;

  @override
  Future<DanmakuTimeline> danmakuTimelineForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    bool forceRefresh = false,
  }) async {
    danmakuRequests.add(episode.id);
    return DanmakuTimeline(
      comments: [
        for (var second = 0; second < 90; second++)
          DanmakuComment(
            id: '${episode.id}:$second',
            provider: 'test-fixture',
            time: Duration(seconds: second),
            mode: DanmakuMode.scroll,
            color: 0xFFFFFFFF,
            text: '自动弹幕第${episode.number}集',
          ),
      ],
    );
  }

  @override
  Future<void> recordRecommendationFirstFrame(
    AnimeSubject subject,
    AnimeEpisode episode, {
    int? expectedAccountContextVersion,
  }) async {
    firstFrames++;
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
    latestPosition = position;
  }
}

// Exposes only the generated clip on loopback, never a directory or user data.
// Range requests and media decoding are real; catalogue discovery is isolated.
class LoopbackPlayerVideo {
  LoopbackPlayerVideo(this.server);
  final HttpServer server;
  final requests = <Map<String, Object?>>[];
  Uri get baseUri => Uri.parse('http://127.0.0.1:${server.port}');

  static Future<LoopbackPlayerVideo> start(File clip) async {
    final fixture = LoopbackPlayerVideo(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    final size = await clip.length();
    fixture.server.listen((request) async {
      final response = request.response;
      try {
        if (!RegExp(
              r'^/episode-[12]-(primary|backup)\.avi$',
            ).hasMatch(request.uri.path) ||
            !['GET', 'HEAD'].contains(request.method)) {
          response.statusCode = HttpStatus.notFound;
          await response.close();
          return;
        }
        var start = 0;
        var end = size - 1;
        final range = request.headers.value(HttpHeaders.rangeHeader);
        if (range != null) {
          final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
          if (match == null) {
            throw const FormatException('Unsupported fixture range');
          }
          start = int.parse(match[1]!);
          if (match[2]!.isNotEmpty) end = int.parse(match[2]!);
          if (end >= size) end = size - 1;
          if (start > end || start >= size) {
            throw const FormatException('Invalid fixture range');
          }
          response.statusCode = HttpStatus.partialContent;
          response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-$end/$size',
          );
        }
        response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        response.headers.contentType = ContentType('video', 'x-msvideo');
        response.contentLength = end - start + 1;
        fixture.requests.add({
          'path': request.uri.path,
          'range': range,
          'status': response.statusCode,
        });
        if (request.method == 'GET') {
          await response.addStream(clip.openRead(start, end + 1));
        }
        await response.close();
      } on FormatException {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$size');
        await response.close();
      } on HttpException {
        // Switching media cancels an in-flight response, as a normal player does.
      } on SocketException {
        // Decoder stop/dispose can close the connection before the clip finishes.
      }
    });
    return fixture;
  }

  Future<void> close() => server.close(force: true);
}
