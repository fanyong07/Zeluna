import 'dart:async';

import 'package:anime/src/data/anime_controller.dart';
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

  test('full inventory display keeps unavailable site status visible', () {
    final inventory = [
      _line('ready', latencyMs: 120),
      _line('not-found', available: false),
    ];

    expect(allPlaybackLinesForDisplay(inventory).map((line) => line.id), [
      'ready',
      'not-found',
    ]);
  });

  test('one runtime failure retries before the line is quarantined', () {
    final first = nextPlaybackLineFailureCount(0);
    final second = nextPlaybackLineFailureCount(first);

    expect(shouldRetryPlaybackLineAfterFailure(first), isTrue);
    expect(shouldRetryPlaybackLineAfterFailure(second), isFalse);
    expect(
      nextPlaybackLineFailureCount(0, definitive: true),
      playbackLineFailureThreshold,
    );
  });

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
    'trusted Zeluna backend line skips duplicate client verification',
    () async {
      final line = _line('backend', providerId: 'zeluna:site:iKun');
      var verificationCalls = 0;

      final verified = await verifyPlaybackLinesBeforeDisplay(
        [line],
        verify: (candidate) async {
          verificationCalls++;
          return candidate;
        },
      );

      expect(verified, [line]);
      expect(verificationCalls, 0);
    },
  );

  test('server verified line can start before background latency probe', () {
    final trusted = _line('trusted', serverVerified: true);
    final pendingCandidate = _line(
      'pending',
      available: false,
      requiresClientProbe: true,
    );

    expect(playbackLineCanStartImmediately(trusted), isTrue);
    expect(playbackLineCanStartImmediately(pendingCandidate), isFalse);
    expect(playbackLineLatencyLabel(trusted), '测速中');
    expect(playbackLineLatencyLabel(pendingCandidate), '检查中');
  });

  test(
    'progressive probing checks every line with bounded concurrency',
    () async {
      final candidates = List.generate(
        7,
        (index) => _line('candidate-$index', available: false),
      );
      var active = 0;
      var maxActive = 0;
      final verifiedIds = <String>[];

      final results = await probePlaybackLinesProgressively(
        candidates,
        maxConcurrent: 3,
        verify: (line) async {
          active++;
          if (active > maxActive) maxActive = active;
          await Future<void>.delayed(
            Duration(milliseconds: 8 + (line.id.hashCode.abs() % 4)),
          );
          verifiedIds.add(line.id);
          active--;
          return _line(line.id, latencyMs: 25);
        },
      ).toList();

      expect(results, hasLength(7));
      expect(verifiedIds.toSet(), candidates.map((line) => line.id).toSet());
      expect(maxActive, 3);
    },
  );

  test(
    'backup probing is sequential and stops at the first playable line',
    () async {
      final candidates = List.generate(
        5,
        (index) => _line('backup-$index', available: false),
      );
      var active = 0;
      var maxActive = 0;
      final calls = <String>[];

      final checked = await probeSinglePlaybackBackupSequentially(
        candidates,
        verify: (line) async {
          active++;
          if (active > maxActive) maxActive = active;
          calls.add(line.id);
          await Future<void>.delayed(const Duration(milliseconds: 5));
          active--;
          return _line(line.id, available: line.id == 'backup-1');
        },
      );

      expect(maxActive, 1);
      expect(calls, ['backup-0', 'backup-1']);
      expect(checked.map((line) => line.id), ['backup-0', 'backup-1']);
      expect(checked.last.available, isTrue);
    },
  );

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

  test(
    'authoritative refresh keeps measured metadata for the same media URL',
    () {
      final measured = _line(
        'backend-line',
        latencyMs: 186,
        clientVerified: true,
        sizeBytes: 32 * 1024 * 1024,
        width: 1920,
        height: 1080,
        bitrate: 4 * 1000 * 1000,
        codecs: 'avc1.640028',
        format: 'HLS',
        adaptive: true,
      );
      final refreshed = _line(
        'backend-line',
        format: 'hls',
        serverVerified: true,
      );

      final merged = mergePlaybackLineSnapshot(
        currentLines: [measured],
        snapshotLines: [refreshed],
        authoritative: true,
      );

      expect(merged.single.latency, const Duration(milliseconds: 186));
      expect(merged.single.sizeBytes, 32 * 1024 * 1024);
      expect(merged.single.videoWidth, 1920);
      expect(merged.single.videoHeight, 1080);
      expect(merged.single.bitrate, 4 * 1000 * 1000);
      expect(merged.single.codecs, 'avc1.640028');
      expect(merged.single.adaptive, isTrue);
      expect(merged.single.serverVerified, isTrue);
      expect(merged.single.clientVerified, isTrue);
      expect(merged.single.requiresClientProbe, isFalse);
    },
  );

  test('metadata from an expired URL is not copied to its replacement', () {
    final measured = _line(
      'backend-line',
      latencyMs: 186,
      url: 'https://old.example.com/index.m3u8',
    );
    final refreshed = _line(
      'backend-line',
      url: 'https://new.example.com/index.m3u8',
    );

    final merged = mergePlaybackLineSnapshot(
      currentLines: [measured],
      snapshotLines: [refreshed],
      authoritative: true,
    );

    expect(merged.single.latency, isNull);
  });

  test(
    'mid-play interruption switches lines and preserves useful progress',
    () {
      const position = Duration(minutes: 18, seconds: 24);

      expect(playbackRecoveryPosition(position), position);
      expect(
        shouldSwitchAfterPlaybackInterruption(
          position: position,
          hasAlternative: true,
        ),
        isTrue,
      );
      expect(
        shouldSwitchAfterPlaybackInterruption(
          position: position,
          hasAlternative: false,
        ),
        isFalse,
      );
    },
  );

  test('startup failures do not seek or quarantine a line immediately', () {
    const position = Duration(seconds: 1);

    expect(playbackRecoveryPosition(position), Duration.zero);
    expect(
      shouldSwitchAfterPlaybackInterruption(
        position: position,
        hasAlternative: true,
      ),
      isFalse,
    );
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

  test(
    'stall recovery requires sustained foreground playback without buffer',
    () {
      expect(
        playbackShouldRecoverFromStall(
          appInForeground: true,
          playing: true,
          buffering: true,
          loading: false,
          playbackFailed: false,
          position: const Duration(minutes: 3),
          duration: const Duration(minutes: 24),
          buffer: const Duration(minutes: 3),
          stalledFor: playbackStallDetectionWindow,
          sinceLastRecovery: playbackStallRecoveryCooldown,
        ),
        isTrue,
      );
      expect(
        playbackShouldRecoverFromStall(
          appInForeground: true,
          playing: true,
          buffering: false,
          loading: false,
          playbackFailed: false,
          position: const Duration(minutes: 3),
          duration: const Duration(minutes: 24),
          buffer: const Duration(minutes: 3, seconds: 10),
          stalledFor: playbackStallDetectionWindow,
          sinceLastRecovery: playbackStallRecoveryCooldown,
        ),
        isFalse,
      );
      expect(
        playbackShouldRecoverFromStall(
          appInForeground: false,
          playing: true,
          buffering: true,
          loading: false,
          playbackFailed: false,
          position: const Duration(minutes: 3),
          duration: const Duration(minutes: 24),
          buffer: const Duration(minutes: 3),
          stalledFor: playbackStallDetectionWindow,
          sinceLastRecovery: playbackStallRecoveryCooldown,
        ),
        isFalse,
      );
      expect(
        playbackShouldRecoverFromStall(
          appInForeground: true,
          playing: true,
          buffering: true,
          loading: false,
          playbackFailed: false,
          position: const Duration(minutes: 23, seconds: 59),
          duration: const Duration(minutes: 24),
          buffer: const Duration(minutes: 24),
          stalledFor: playbackStallDetectionWindow,
          sinceLastRecovery: playbackStallRecoveryCooldown,
        ),
        isFalse,
      );
    },
  );

  test(
    'single backup probe waits for stable playback and never duplicates',
    () {
      expect(
        playbackShouldPrepareSingleBackup(
          appInForeground: true,
          playing: true,
          buffering: false,
          loading: false,
          playbackFailed: false,
          hasAlternative: false,
          position: playbackBackupProbeMinimumPosition,
          buffer:
              playbackBackupProbeMinimumPosition +
              playbackBackupProbeMinimumBuffer,
        ),
        isTrue,
      );
      expect(
        playbackShouldPrepareSingleBackup(
          appInForeground: true,
          playing: true,
          buffering: true,
          loading: false,
          playbackFailed: false,
          hasAlternative: false,
          position: const Duration(seconds: 20),
          buffer: const Duration(seconds: 40),
        ),
        isFalse,
      );
      expect(
        playbackShouldPrepareSingleBackup(
          appInForeground: true,
          playing: true,
          buffering: false,
          loading: false,
          playbackFailed: false,
          hasAlternative: true,
          position: const Duration(seconds: 20),
          buffer: const Duration(seconds: 40),
        ),
        isFalse,
      );
    },
  );

  test('native soft timeout switches only when a fallback exists', () {
    expect(
      nativePlaybackShouldSwitchAtSoftTimeout(
        position: Duration.zero,
        buffer: Duration.zero,
        buffering: false,
        hasAlternative: true,
      ),
      isTrue,
    );
    expect(
      nativePlaybackShouldSwitchAtSoftTimeout(
        position: Duration.zero,
        buffer: Duration.zero,
        buffering: false,
        hasAlternative: false,
      ),
      isFalse,
    );
    expect(
      nativePlaybackShouldSwitchAtSoftTimeout(
        position: const Duration(milliseconds: 1),
        buffer: Duration.zero,
        buffering: false,
        hasAlternative: true,
      ),
      isFalse,
    );
    expect(
      nativePlaybackShouldSwitchAtSoftTimeout(
        position: Duration.zero,
        buffer: const Duration(milliseconds: 1),
        buffering: false,
        hasAlternative: true,
      ),
      isFalse,
    );
    expect(
      nativePlaybackShouldSwitchAtSoftTimeout(
        position: Duration.zero,
        buffer: Duration.zero,
        buffering: true,
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
    expect(playbackLineLatencyLabel(_line('unknown')), '速度未知');
    expect(playbackLineMediaLabel(_line('unknown')), contains('大小未知'));
  });

  test('failed playback labels retain the exact reason and measured delay', () {
    expect(
      playbackLineFailureLabel(
        _line(
          'forbidden',
          available: false,
          latencyMs: 218,
          message: '视频 CDN 拒绝访问，可能有防盗链或地区限制。',
        ),
      ),
      '访问被拒绝 · 218ms',
    );
    expect(
      playbackLineFailureLabel(
        _line('segment', available: false, message: '首个媒体分片无法访问'),
      ),
      '视频加载失败',
    );
  });
  group('playbackProviderLabel', () {
    test('内部规则 ID 不会出现在界面，映射为稳定别名', () {
      final label = playbackProviderLabel(
        providerId: 'xfdmneo',
        providerName: 'xfdmneo',
      );
      expect(label, isNot(contains('xfdmneo')));
      expect(label, endsWith('线路'));
      expect(
        playbackProviderLabel(providerId: 'xfdmneo', providerName: 'xfdmneo'),
        label,
      );
    });

    test('人类可读名称原样保留', () {
      expect(
        playbackProviderLabel(providerId: 'a1', providerName: '低端影视'),
        '低端影视',
      );
      expect(
        playbackProviderLabel(
          providerId: 'archive',
          providerName: 'Internet Archive',
        ),
        'Internet Archive',
      );
    });

    test('不同 ID 映射保持确定性且来自别名池', () {
      final label = playbackProviderLabel(
        providerId: 'custom:abc-1',
        providerName: '',
      );
      final alias = label.replaceAll('线路', '');
      expect(playbackProviderAliasPool, contains(alias));
    });
  });

  group('playbackQualityChipLabel', () {
    test('未知分辨率不显示 chip', () {
      expect(playbackQualityChipLabel(null), isNull);
      expect(playbackQualityChipLabel(_line('a')), isNull);
    });

    test('真实分辨率正常显示', () {
      expect(
        playbackQualityChipLabel(_line('b', width: 1920, height: 1080)),
        '1080P',
      );
    });
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
  bool serverVerified = false,
  bool requiresClientProbe = false,
  bool clientVerified = false,
  String? message,
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
    serverVerified: serverVerified,
    requiresClientProbe: requiresClientProbe,
    clientVerified: clientVerified,
    available: available,
    message: message,
  );
}
