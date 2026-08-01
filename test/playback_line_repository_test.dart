import 'dart:async';

import 'package:anime/src/data/playback_source_repository.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/player/lines/playback_line_repository.dart';
import 'package:anime/src/rules/rule_playback_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('quick lookup verifies media before publishing its inventory', () async {
    final candidate = _line('candidate', requiresClientProbe: true);
    final verified = _line('candidate', clientVerified: true);
    var verificationCalls = 0;
    final repository = _repository(
      loadQuickLines: (_, _, _) async => [candidate],
      verifyLine: (_, _) async {
        verificationCalls++;
        return verified;
      },
    );
    addTearDown(repository.dispose);

    final inventory = await repository.lookupQuick(
      subject: _subject,
      episode: _episode,
      progressive: true,
    );

    expect(verificationCalls, 1);
    expect(inventory?.lines.single, same(verified));
    expect(repository.lines.single, same(verified));
    expect(repository.lookupInProgress, isFalse);
    expect(repository.scanComplete, isFalse);
  });

  test(
    'a newer quick lookup prevents a stale result from publishing',
    () async {
      final firstResult = Completer<List<PlaybackLine>>();
      final secondResult = Completer<List<PlaybackLine>>();
      final tokens = <RulePlaybackCancellationToken>[];
      var calls = 0;
      final repository = _repository(
        loadQuickLines: (_, _, token) {
          tokens.add(token);
          return calls++ == 0 ? firstResult.future : secondResult.future;
        },
      );
      addTearDown(repository.dispose);

      final firstLookup = repository.lookupQuick(
        subject: _subject,
        episode: _episode,
        progressive: true,
      );
      final secondLookup = repository.lookupQuick(
        subject: _subject,
        episode: _episode,
        progressive: true,
      );
      final newest = _line('newest', clientVerified: true);
      secondResult.complete([newest]);
      expect((await secondLookup)?.lines.single, same(newest));
      firstResult.complete([_line('stale', clientVerified: true)]);

      expect(await firstLookup, isNull);
      expect(tokens.first.isCancelled, isTrue);
      expect(repository.lines.single, same(newest));
    },
  );

  test(
    'expanded lookup owns scan state and merges progressive updates',
    () async {
      final updates = StreamController<PlaybackLineLookupUpdate>();
      final current = _line('current', clientVerified: true);
      final backup = _line('backup', clientVerified: true);
      final updateReceived = Completer<void>();
      var callbacks = 0;
      final repository = _repository(
        initialLines: [current],
        loadExpandedLines: (_, _, _) => updates.stream,
      );
      addTearDown(() async {
        await repository.dispose();
        await updates.close();
      });

      expect(
        repository.startExpandedLookup(
          subject: _subject,
          episode: _episode,
          hasActivePlayableLine: true,
          preserveLoadedLine: (lines) => lines,
          onUpdate: (_) {
            callbacks++;
            updateReceived.complete();
          },
          onError: (_, _) {},
          onDone: () {},
        ),
        isTrue,
      );
      expect(repository.scanInProgress, isTrue);
      updates.add(
        PlaybackLineLookupUpdate(
          phase: PlaybackLineLookupPhase.discovery,
          lines: [backup],
          completedRules: 1,
          totalRules: 3,
        ),
      );
      await updateReceived.future;

      expect(callbacks, 1);
      expect(repository.lines.map((line) => line.id), ['current', 'backup']);
      expect(repository.scanCompletedRules, 1);
      expect(repository.scanTotalRules, 3);
      expect(repository.scanInProgress, isTrue);
    },
  );

  test(
    'dispose cancels expanded and backup work without late callbacks',
    () async {
      final updates = StreamController<PlaybackLineLookupUpdate>();
      final backupResult = Completer<List<PlaybackLine>>();
      RulePlaybackCancellationToken? lookupToken;
      RulePlaybackCancellationToken? backupToken;
      var callbacks = 0;
      final current = _line('current', clientVerified: true);
      final repository = _repository(
        initialLines: [current],
        loadExpandedLines: (_, _, token) {
          lookupToken = token;
          return updates.stream;
        },
        loadSingleBackup: (_, _, _, token) {
          backupToken = token;
          return backupResult.future;
        },
      );

      repository.startExpandedLookup(
        subject: _subject,
        episode: _episode,
        hasActivePlayableLine: true,
        preserveLoadedLine: (lines) => lines,
        onUpdate: (_) => callbacks++,
        onError: (_, _) {},
        onDone: () {},
      );
      final backupLookup = repository.prepareSingleBackup(
        subject: _subject,
        episode: _episode,
        currentLine: current,
        preserveLoadedLine: (lines) => lines,
      );

      await repository.dispose();
      updates.add(
        PlaybackLineLookupUpdate(
          phase: PlaybackLineLookupPhase.complete,
          lines: [_line('late', clientVerified: true)],
          completedRules: 1,
          totalRules: 1,
        ),
      );
      backupResult.complete([_line('late-backup', clientVerified: true)]);
      await Future<void>.delayed(Duration.zero);

      expect(lookupToken?.isCancelled, isTrue);
      expect(backupToken?.isCancelled, isTrue);
      expect(await backupLookup, isNull);
      expect(repository.hasExpandedLookup, isFalse);
      expect(repository.backupInProgress, isFalse);
      expect(callbacks, 0);
      await updates.close();
    },
  );
}

PlaybackLineRepository _repository({
  QuickPlaybackLineLoader? loadQuickLines,
  PlaybackLineVerifier? verifyLine,
  ExpandedPlaybackLineLoader? loadExpandedLines,
  BackupPlaybackLineLoader? loadSingleBackup,
  Iterable<PlaybackLine> initialLines = const <PlaybackLine>[],
}) {
  return PlaybackLineRepository(
    loadQuickLines: loadQuickLines ?? (_, _, _) async => const [],
    verifyLine: verifyLine ?? (line, _) async => line,
    loadExpandedLines: loadExpandedLines ?? (_, _, _) => const Stream.empty(),
    loadSingleBackup: loadSingleBackup ?? (_, _, _, _) async => const [],
    initialLines: initialLines,
    initialEpisodeId: _episode.id,
  );
}

const _subject = AnimeSubject(
  id: 1,
  title: '测试番剧',
  originalTitle: 'Test Anime',
  summary: '',
  coverUrl: null,
  bannerUrl: null,
  date: null,
  platform: 'TV',
  language: '日语',
  region: '日本',
  status: '',
  categories: [],
  tags: [],
  totalEpisodes: 1,
);

const _episode = AnimeEpisode(
  id: 101,
  subjectId: 1,
  number: 1,
  title: '',
  airdate: null,
  duration: '24:00',
  description: '',
);

PlaybackLine _line(
  String id, {
  bool requiresClientProbe = false,
  bool clientVerified = false,
}) {
  return PlaybackLine(
    id: id,
    episodeId: _episode.id,
    providerId: 'provider-$id',
    providerName: id,
    title: id,
    quality: '1080p',
    format: 'HLS',
    url: 'https://example.invalid/$id.m3u8',
    available: true,
    requiresClientProbe: requiresClientProbe,
    clientVerified: clientVerified,
  );
}
