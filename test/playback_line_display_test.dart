import 'dart:async';

import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/player/playback_line_display.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('playback lines sort by latency and keep unknown or failed last', () {
    final lines = [
      _line('slow', latencyMs: 1002),
      _line('unknown'),
      _line('fast', latencyMs: 266),
      _line('tie-a', latencyMs: 998),
      _line('failed', latencyMs: 50, available: false),
      _line('tie-b', latencyMs: 998),
    ];

    expect(sortPlaybackLinesForDisplay(lines).map((line) => line.id), [
      'fast',
      'tie-a',
      'tie-b',
      'slow',
      'unknown',
      'failed',
    ]);
    expect(lines.map((line) => line.id), [
      'slow',
      'unknown',
      'fast',
      'tie-a',
      'failed',
      'tie-b',
    ]);
  });

  test('display latency order does not rewrite source selection priority', () {
    final sourcePriority = [
      _line('provider-first', latencyMs: 1200),
      _line('provider-second', latencyMs: 80),
    ];

    final displayOrder = sortPlaybackLinesForDisplay(sourcePriority);

    expect(displayOrder.map((line) => line.id), [
      'provider-second',
      'provider-first',
    ]);
    expect(
      playablePlaybackLinesInSourceOrder(sourcePriority).first.id,
      'provider-first',
    );
  });

  test(
    'selectable display lines hide unavailable and runtime-failed entries',
    () {
      final inventory = [
        _line('slow-ready', latencyMs: 900),
        _line('probe-rejected', latencyMs: 20, available: false),
        _line('runtime-failed', latencyMs: 40),
        _line('fast-ready', latencyMs: 120),
      ];

      final display = selectablePlaybackLinesForDisplay(
        inventory,
        failedLineIds: const {'runtime-failed'},
      );

      expect(display.map((line) => line.id), ['fast-ready', 'slow-ready']);
      expect(inventory.map((line) => line.id), [
        'slow-ready',
        'probe-rejected',
        'runtime-failed',
        'fast-ready',
      ]);
    },
  );

  test(
    'network initial line stays hidden until media verification finishes',
    () async {
      final candidate = _line('network-initial');
      final verification = Completer<PlaybackLine>();
      var completed = false;

      expect(initialPlaybackLinesForDisplay(candidate), isEmpty);
      final pending = verifyPlaybackLinesBeforeDisplay([
        candidate,
      ], verify: (line) => verification.future)..then((_) => completed = true);
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);

      verification.complete(_line('network-initial', available: false));
      final verified = await pending;
      expect(selectablePlaybackLinesForDisplay(verified), isEmpty);
    },
  );

  test('local initial line is displayable without a network probe', () async {
    final local = _line('local', url: 'file:///C:/videos/episode.mp4');
    var verificationCalls = 0;

    expect(initialPlaybackLinesForDisplay(local), [local]);
    final verified = await verifyPlaybackLinesBeforeDisplay(
      [local],
      verify: (line) async {
        verificationCalls++;
        return line;
      },
    );

    expect(verified, [local]);
    expect(verificationCalls, 0);
  });

  test(
    'verified network line is inserted only after the probe result arrives',
    () {
      final verified = _line('verified-network', latencyMs: 120);

      expect(
        upsertPlaybackLine(
          const <PlaybackLine>[],
          verified,
        ).map((line) => line.id),
        ['verified-network'],
      );
      final updated = upsertPlaybackLine([
        _line('other'),
        _line('verified-network'),
      ], verified);
      expect(updated.map((line) => line.id), ['other', 'verified-network']);
      expect(updated.last, same(verified));
    },
  );

  test('full lookup runs only when quick lookup has no playable line', () {
    expect(
      shouldExpandPlaybackLookupAfterQuickLines([_line('ready')]),
      isFalse,
    );
    expect(
      shouldExpandPlaybackLookupAfterQuickLines([
        _line('dead', available: false),
      ]),
      isTrue,
    );
    expect(shouldExpandPlaybackLookupAfterQuickLines(const []), isTrue);
  });

  test('verified provider snapshot removes stale optimistic lines', () {
    final merged = mergePlaybackLineSnapshot(
      currentLines: [
        _line('old-a', providerId: 'provider-a'),
        _line('keep-b', providerId: 'provider-b'),
      ],
      snapshotLines: [
        _line('keep-b', providerId: 'provider-b'),
        _line('failed-a', providerId: 'provider-a', available: false),
      ],
      replacedProviderId: 'provider-a',
    );

    expect(merged.map((line) => line.id), ['keep-b', 'failed-a']);
    expect(merged.where((line) => line.id == 'old-a'), isEmpty);
  });

  test('complete lookup snapshot is authoritative', () {
    final merged = mergePlaybackLineSnapshot(
      currentLines: [_line('optimistic', providerId: 'provider-a')],
      snapshotLines: const [],
      authoritative: true,
    );

    expect(merged, isEmpty);
  });

  test(
    'native playing state alone does not count as a decoded first frame',
    () {
      expect(
        nativePlaybackHasFirstFrame(playing: true, position: Duration.zero),
        isFalse,
      );
      expect(
        nativePlaybackHasFirstFrame(
          playing: false,
          position: const Duration(milliseconds: 1),
        ),
        isTrue,
      );
    },
  );

  test('native first frame is recognized only on zero-to-progress edge', () {
    expect(
      nativePlaybackReachedFirstFrame(
        previousPosition: Duration.zero,
        currentPosition: const Duration(milliseconds: 1),
      ),
      isTrue,
    );
    expect(
      nativePlaybackReachedFirstFrame(
        previousPosition: const Duration(milliseconds: 1),
        currentPosition: const Duration(milliseconds: 200),
      ),
      isFalse,
    );
  });

  test('native soft timeout switches only when a fallback exists', () {
    expect(
      nativePlaybackShouldSwitchAtSoftTimeout(
        position: Duration.zero,
        hasAlternative: true,
      ),
      isTrue,
    );
    expect(
      nativePlaybackShouldSwitchAtSoftTimeout(
        position: Duration.zero,
        hasAlternative: false,
      ),
      isFalse,
    );
    expect(
      nativePlaybackShouldSwitchAtSoftTimeout(
        position: const Duration(milliseconds: 1),
        hasAlternative: true,
      ),
      isFalse,
    );
  });

  test('web ready state is not a timeout when autoplay is blocked', () {
    expect(webPlaybackStartupTimedOut(waitingForReady: true), isTrue);
    expect(webPlaybackStartupTimedOut(waitingForReady: false), isFalse);
  });

  test('web soft timeout switches only when a fallback exists', () {
    expect(
      webPlaybackShouldSwitchAtSoftTimeout(
        waitingForReady: true,
        hasAlternative: true,
      ),
      isTrue,
    );
    expect(
      webPlaybackShouldSwitchAtSoftTimeout(
        waitingForReady: true,
        hasAlternative: false,
      ),
      isFalse,
    );
    expect(
      webPlaybackShouldSwitchAtSoftTimeout(
        waitingForReady: false,
        hasAlternative: true,
      ),
      isFalse,
    );
  });

  test('web loading pause does not erase autoplay intent', () {
    expect(
      webPlaybackShouldApplyPlayingUpdate(loading: true, playing: false),
      isFalse,
    );
    expect(
      webPlaybackShouldApplyPlayingUpdate(loading: false, playing: false),
      isTrue,
    );
    expect(
      webPlaybackShouldApplyPlayingUpdate(loading: true, playing: true),
      isTrue,
    );
  });

  test('active loaded line survives an unavailable verification snapshot', () {
    const current = PlaybackLine(
      id: 'current',
      episodeId: 1,
      providerId: 'provider',
      providerName: 'Provider',
      title: 'Line',
      quality: '1080p',
      format: 'HLS',
      url: 'https://cdn.example.com/video.m3u8',
      available: true,
    );
    const unavailable = PlaybackLine(
      id: 'current',
      episodeId: 1,
      providerId: 'provider',
      providerName: 'Provider',
      title: 'Line',
      quality: '1080p',
      format: 'HLS',
      available: false,
    );

    expect(
      shouldPreserveLoadedPlaybackLine(
        currentLine: current,
        replacementLine: unavailable,
        loadedUrl: current.url,
        failedLineIds: const {},
        playbackFailed: false,
      ),
      isTrue,
    );
    expect(
      shouldPreserveLoadedPlaybackLine(
        currentLine: current,
        replacementLine: unavailable,
        loadedUrl: current.url,
        failedLineIds: const {'current'},
        playbackFailed: true,
      ),
      isFalse,
    );
  });

  test(
    'background validation opens a replacement in source priority order',
    () {
      final current = _line('current', latencyMs: 20);
      final providerFirst = _line('provider-first', latencyMs: 1200);
      final providerSecond = _line('provider-second', latencyMs: 80);

      final decision = decidePlaybackLineAfterValidation(
        currentLine: current,
        loadedUrl: current.url,
        lines: [providerFirst, providerSecond],
        failedLineIds: const {},
        playbackFailed: false,
        autoplay: false,
      );

      expect(decision.action, PlaybackLineValidationAction.open);
      expect(decision.targetLine?.id, 'provider-first');
      expect(decision.selectedLine?.id, 'current');
    },
  );

  test('background validation stops when the loaded line is removed', () {
    final current = _line('current');

    final decision = decidePlaybackLineAfterValidation(
      currentLine: current,
      loadedUrl: current.url,
      lines: const [],
      failedLineIds: const {},
      playbackFailed: false,
      autoplay: false,
    );

    expect(decision.action, PlaybackLineValidationAction.stop);
    expect(decision.targetLine, isNull);
    expect(decision.selectedLine, isNull);
  });

  test('validated metadata refresh keeps selection on the loaded media', () {
    final current = _line('current', latencyMs: 900);
    final refreshed = _line('current', latencyMs: 100);

    final decision = decidePlaybackLineAfterValidation(
      currentLine: current,
      loadedUrl: current.url,
      lines: [refreshed],
      failedLineIds: const {},
      playbackFailed: false,
      autoplay: false,
    );

    expect(decision.action, PlaybackLineValidationAction.keep);
    expect(decision.selectedLine, same(refreshed));
  });

  test(
    'validated URL update is opened before UI adopts the refreshed line',
    () {
      final current = _line('current', url: 'https://example.com/old');
      final refreshed = _line('current', url: 'https://example.com/new');

      final decision = decidePlaybackLineAfterValidation(
        currentLine: current,
        loadedUrl: current.url,
        lines: [refreshed],
        failedLineIds: const {},
        playbackFailed: false,
        autoplay: false,
      );

      expect(decision.action, PlaybackLineValidationAction.open);
      expect(decision.targetLine, same(refreshed));
      expect(decision.selectedLine, same(current));
    },
  );

  test('playback line labels expose latency size resolution and format', () {
    final line = _line(
      'metadata',
      latencyMs: 266,
      sizeBytes: 50 * 1024 * 1024,
      width: 1920,
      height: 1080,
      bitrate: 5 * 1000 * 1000,
      codecs: 'avc1.640028,mp4a.40.2',
      format: 'HLS',
      adaptive: true,
      estimated: true,
    );

    expect(playbackLineLatencyLabel(line), '266ms');
    expect(
      playbackLineMediaLabel(line),
      '约 50.0 MB · 最高 1920×1080 · HLS · 5.0 Mbps · H.264/AAC',
    );
    expect(playbackLineLatencyLabel(_line('unknown')), '延迟未知');
    expect(playbackLineMediaLabel(_line('unknown')), contains('大小未知'));
  });
}

PlaybackLine _line(
  String id, {
  String providerId = 'test',
  int? latencyMs,
  bool available = true,
  int? sizeBytes,
  int? width,
  int? height,
  int? bitrate,
  String? codecs,
  String format = 'MP4',
  bool adaptive = false,
  bool estimated = false,
  String? url,
}) {
  return PlaybackLine(
    id: id,
    episodeId: 1,
    providerId: providerId,
    providerName: '测试线路',
    title: id,
    quality: width == null || height == null ? '分辨率未知' : '${height}P',
    format: format,
    url: url ?? 'https://example.com/$id',
    latency: latencyMs == null ? null : Duration(milliseconds: latencyMs),
    sizeBytes: sizeBytes,
    sizeEstimated: estimated,
    videoWidth: width,
    videoHeight: height,
    bitrate: bitrate,
    codecs: codecs,
    adaptive: adaptive,
    available: available,
  );
}
