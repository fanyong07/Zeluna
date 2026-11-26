import 'dart:async';

import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/domain/client_media_resolver.dart';
import 'package:anime/src/player/playback_line_display.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('audio timestamps alone never confirm a native video frame', () {
    expect(
      nativePlaybackHasFirstFrame(
        playing: true,
        position: const Duration(seconds: 4),
        decodedVideo: false,
      ),
      isFalse,
    );
  });

  test(
    'fresh aggregate and crawler backend routes skip duplicate startup probes',
    () async {
      final lines = [
        _line(
          'aggregate-ready',
          providerId: 'aggregate.maccms',
          serverVerified: true,
          cacheState: 'fresh',
        ),
        _line(
          'crawler-ready',
          providerId: 'crawler.xifan',
          serverVerified: true,
          cacheState: 'cold',
        ),
      ];
      var calls = 0;
      final result = await verifyPlaybackLinesBeforeDisplay(
        lines,
        verify: (line) async {
          calls++;
          return line;
        },
      );
      expect(
        calls,
        0,
        reason: 'a verified first route must not wait for all candidate probes',
      );
      expect(result, lines);
      expect(initialPlaybackLinesForDisplay(lines.first), [lines.first]);
    },
  );

  test('stale backend evidence still needs local validation', () {
    final line = _line(
      'stale',
      providerId: 'aggregate.maccms',
      serverVerified: true,
      cacheState: 'stale',
    );
    expect(playbackLineNeedsPreDisplayVerification(line), isTrue);
  });

  test(
    'fresh client verified rule is not probed again before first frame',
    () async {
      final line = _line(
        'ready-rule',
        providerId: 'kazumi:ready',
        clientVerified: true,
      );
      var probes = 0;
      final result = await verifyPlaybackLinesBeforeDisplay(
        [line],
        verify: (line) async {
          probes++;
          return line;
        },
      );
      expect(
        probes,
        0,
        reason: 'duplicate manifest/segment reads delay every episode',
      );
      expect(initialPlaybackLinesForDisplay(line), [line]);
      expect(result, [line]);
    },
  );

  test(
    'diagnostic cards preserve distinct routes from the same named source',
    () {
      final lines = List.generate(
        58,
        (i) => PlaybackLine(
          id: 'route-$i',
          episodeId: 1,
          providerId: 'crawler.anich',
          providerName: '同名来源',
          sourceName: '同名来源',
          title: '线路 $i',
          quality: '1080P',
          format: 'HLS',
          url: 'https://cdn.example/$i.m3u8',
          available: false,
          diagnosticStatus: PlaybackDiscoveryStatus.clientProbeRequired,
        ),
      );
      final groups = groupPlaybackLinesForDiagnostics(lines);
      expect([...groups.primary, ...groups.other], hasLength(58));
    },
  );
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

  test('source diagnostic summary counts sources instead of route rows', () {
    final summary = summarizePlaybackSourceDiagnostics([
      _line(
        'ikun-a',
        providerId: 'aggregate.maccms',
        sourceName: 'iKun',
        diagnosticStatus: PlaybackDiscoveryStatus.serverVerified,
        queried: true,
        matched: true,
      ),
      _line(
        'ikun-b',
        providerId: 'aggregate.maccms',
        sourceName: 'iKun',
        diagnosticStatus: PlaybackDiscoveryStatus.serverVerified,
        queried: true,
        matched: true,
      ),
      _line(
        'timeout',
        providerId: 'aggregate.maccms',
        sourceName: '超时源',
        diagnosticStatus: PlaybackDiscoveryStatus.searchTimeout,
        queried: true,
        matched: false,
        available: false,
      ),
      _line(
        'circuit',
        providerId: 'crawler.circuit',
        sourceName: 'circuit',
        diagnosticStatus: PlaybackDiscoveryStatus.circuitSuppressed,
        queried: true,
        matched: true,
        available: false,
      ),
      _line(
        'not-queried',
        providerId: 'crawler.pending',
        sourceName: 'pending',
        diagnosticStatus: PlaybackDiscoveryStatus.notQueried,
        queried: false,
        matched: false,
        available: false,
      ),
      _line(
        'legacy-playable',
        providerId: 'zeluna:site:legacy',
        sourceName: 'legacy',
      ),
    ]);

    expect(summary.totalSources, 5);
    expect(summary.queriedSources, 4);
    expect(summary.matchedSources, 3);
    expect(summary.playableSources, 2);
  });

  test('diagnostic groups prioritize actionable source states', () {
    final groups = groupPlaybackLinesForDiagnostics([
      _line(
        'miss',
        diagnosticStatus: PlaybackDiscoveryStatus.searchMiss,
        available: false,
      ),
      _line(
        'route',
        diagnosticStatus: PlaybackDiscoveryStatus.routeUnavailable,
        available: false,
      ),
      _line(
        'pending',
        diagnosticStatus: PlaybackDiscoveryStatus.notQueried,
        available: false,
      ),
      _line(
        'verified',
        diagnosticStatus: PlaybackDiscoveryStatus.serverVerified,
      ),
      _line(
        'client',
        diagnosticStatus: PlaybackDiscoveryStatus.clientProbeRequired,
        available: false,
        requiresClientProbe: true,
      ),
      _line(
        'circuit',
        diagnosticStatus: PlaybackDiscoveryStatus.circuitSuppressed,
        available: false,
      ),
    ]);

    expect(groups.primary.map((line) => line.id), [
      'verified',
      'client',
      'route',
    ]);
    expect(groups.other.map((line) => line.id), ['miss', 'pending', 'circuit']);
  });

  test(
    'real routes replace their placeholder without hiding slower alternatives',
    () {
      final groups = groupPlaybackLinesForDiagnostics([
        _line(
          'placeholder',
          providerId: 'aggregate.maccms',
          sourceName: '魔都2',
          diagnosticStatus: PlaybackDiscoveryStatus.searchMiss,
          available: false,
          url: '',
        ),
        _line(
          'verified',
          providerId: 'aggregate.maccms',
          sourceName: '魔都2',
          diagnosticStatus: PlaybackDiscoveryStatus.serverVerified,
          serverVerified: true,
          latencyMs: 320,
        ),
        _line(
          'verified-slower',
          providerId: 'aggregate.maccms',
          sourceName: '魔都2',
          diagnosticStatus: PlaybackDiscoveryStatus.serverVerified,
          serverVerified: true,
          latencyMs: 640,
        ),
      ]);

      expect(groups.primary.map((line) => line.id), [
        'verified',
        'verified-slower',
      ]);
      expect(groups.other, isEmpty);
    },
  );

  test(
    'managed lines keep independent cards even with the same source name',
    () {
      final groups = groupPlaybackLinesForDiagnostics([
        _line(
          'managed-a',
          providerId: 'managed.urls',
          sourceName: 'official',
          diagnosticStatus: PlaybackDiscoveryStatus.serverVerified,
          serverVerified: true,
        ),
        _line(
          'managed-b',
          providerId: 'managed.urls',
          sourceName: 'official',
          diagnosticStatus: PlaybackDiscoveryStatus.serverVerified,
          serverVerified: true,
        ),
      ]);

      expect(groups.primary.map((line) => line.id), ['managed-a', 'managed-b']);
    },
  );

  test(
    'same source keeps pending resolver and failed candidates without media URLs',
    () {
      final groups = groupPlaybackLinesForDiagnostics([
        _line(
          'source-placeholder',
          providerId: 'crawler.kazumi',
          sourceName: '稀饭动漫',
          url: '',
          available: false,
          diagnosticStatus: PlaybackDiscoveryStatus.notQueried,
        ),
        _line(
          'ready-route',
          providerId: 'crawler.kazumi',
          sourceName: '稀饭动漫',
          diagnosticStatus: PlaybackDiscoveryStatus.serverVerified,
        ),
        for (final id in ['resolver-a', 'resolver-b'])
          _line(
            id,
            providerId: 'crawler.kazumi',
            sourceName: '稀饭动漫',
            url: '',
            available: false,
            diagnosticStatus: PlaybackDiscoveryStatus.clientResolverRequired,
          ),
        for (final id in ['failed-a', 'failed-b'])
          _line(
            id,
            providerId: 'crawler.kazumi',
            sourceName: '稀饭动漫',
            url: '',
            available: false,
            diagnosticStatus: PlaybackDiscoveryStatus.routeUnavailable,
          ),
      ]);
      expect(
        [...groups.primary, ...groups.other].map((line) => line.id).toSet(),
        {'ready-route', 'resolver-a', 'resolver-b', 'failed-a', 'failed-b'},
      );
    },
  );

  test('selecting a route keeps every alternative visible', () {
    final groups = groupPlaybackLinesForDiagnostics([
      _line(
        'fast-route',
        providerId: 'aggregate.maccms',
        sourceName: '如意',
        diagnosticStatus: PlaybackDiscoveryStatus.serverVerified,
        serverVerified: true,
        latencyMs: 120,
      ),
      _line(
        'selected-route',
        providerId: 'aggregate.maccms',
        sourceName: '如意',
        diagnosticStatus: PlaybackDiscoveryStatus.serverVerified,
        serverVerified: true,
        latencyMs: 480,
      ),
    ], selectedLineId: 'selected-route');

    expect(groups.primary.map((line) => line.id), [
      'fast-route',
      'selected-route',
    ]);
  });

  test('diagnostic status labels do not collapse into generic unavailable', () {
    expect(
      playbackLineFailureLabel(
        _line(
          'not-queried',
          diagnosticStatus: PlaybackDiscoveryStatus.notQueried,
          available: false,
        ),
      ),
      '未检查',
    );
    expect(
      playbackLineFailureLabel(
        _line(
          'no-episode',
          diagnosticStatus: PlaybackDiscoveryStatus.matchedNoEpisode,
          available: false,
        ),
      ),
      '缺少本集',
    );
    expect(
      playbackLineFailureLabel(
        _line(
          'route',
          diagnosticStatus: PlaybackDiscoveryStatus.routeUnavailable,
          available: false,
        ),
      ),
      '线路失败',
    );
    expect(
      playbackLineFailureLabel(
        _line(
          'circuit',
          diagnosticStatus: PlaybackDiscoveryStatus.circuitSuppressed,
          available: false,
        ),
      ),
      '暂时跳过',
    );
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
    'stale or client-probe-only server evidence cannot skip local checking',
    () {
      for (final line in [
        _line('stale', serverVerified: true, cacheState: 'stale'),
        _line('needs-client', serverVerified: true, requiresClientProbe: true),
      ]) {
        expect(playbackLineCanStartImmediately(line), isFalse);
      }
      expect(
        playbackLineCanStartImmediately(
          _line(
            'checked-on-device',
            serverVerified: true,
            clientVerified: true,
            cacheState: 'stale',
          ),
        ),
        isTrue,
      );
    },
  );

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
        startupProfile: PlaybackStartupProfile.hls,
        cacheState: 'stale',
        sourceErrorCategory: 'server_blocked_client_candidate',
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
      expect(merged.single.startupProfile, PlaybackStartupProfile.hls);
      expect(merged.single.cacheState, 'stale');
      expect(
        merged.single.sourceErrorCategory,
        'server_blocked_client_candidate',
      );
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

  group('background media metadata merge', () {
    test(
      'failed enrichment updates only measured metadata, never active route state',
      () {
        final expires = DateTime.utc(2030, 1, 1);
        final current = PlaybackLine(
          id: 'active-id',
          episodeId: 7,
          providerId: 'active-provider',
          providerName: '真实站点',
          sourceName: '站点来源',
          sourceInventoryId: 'registered:active',
          title: '活动线路',
          quality: '分辨率未知',
          format: 'auto',
          url: 'https://cdn.example/index.m3u8',
          headers: const {'Referer': 'https://site.example/'},
          latency: const Duration(milliseconds: 900),
          available: true,
          serverVerified: true,
          clientVerified: true,
          publicHttpOnly: true,
          startupProfile: PlaybackStartupProfile.hls,
          cacheState: 'fresh',
          sourceErrorCategory: 'retained-category',
          clientQuerySupported: true,
          queryLocation: 'hybrid',
          sourceAddress: 'https://site.example/',
          diagnosticStatus: PlaybackDiscoveryStatus.serverVerified,
          queried: true,
          aliasesAttempted: 3,
          searchHitCount: 7,
          bestMatchScore: 100,
          matched: true,
          episodeFound: true,
          discoveryElapsed: const Duration(seconds: 2),
          expiresAt: expires,
          message: '活动状态',
        );
        const metadata = PlaybackLine(
          id: 'different-metadata-id',
          episodeId: 99,
          providerId: 'different-provider',
          providerName: '不用于展示的探测名',
          title: '不覆盖标题',
          quality: '1080P',
          format: 'HLS',
          url: 'https://cdn.example/index.m3u8',
          headers: {'Referer': 'https://site.example/'},
          latency: Duration(milliseconds: 266),
          sizeBytes: 50 * 1024 * 1024,
          sizeEstimated: true,
          videoWidth: 1920,
          videoHeight: 1080,
          bitrate: 5000000,
          codecs: 'avc1.640028,mp4a.40.2',
          adaptive: true,
          available: false,
          requiresClientProbe: true,
          cacheState: 'stale',
          diagnosticStatus: PlaybackDiscoveryStatus.routeUnavailable,
          message: '后台检查失败也不把在播线路标成失败',
        );
        final merged = mergePlaybackLineMediaMetadata(
          current: current,
          metadata: metadata,
        );
        expect(merged.id, current.id);
        expect(merged.episodeId, current.episodeId);
        expect(merged.providerId, current.providerId);
        expect(merged.providerName, current.providerName);
        expect(merged.sourceName, current.sourceName);
        expect(merged.sourceInventoryId, current.sourceInventoryId);
        expect(merged.title, current.title);
        expect(merged.url, current.url);
        expect(merged.headers, same(current.headers));
        expect(merged.available, isTrue);
        expect(merged.clientVerified, isTrue);
        expect(merged.serverVerified, isTrue);
        expect(merged.requiresClientProbe, isFalse);
        expect(merged.publicHttpOnly, isTrue);
        expect(merged.startupProfile, current.startupProfile);
        expect(merged.cacheState, current.cacheState);
        expect(merged.sourceErrorCategory, current.sourceErrorCategory);
        expect(merged.clientQuerySupported, isTrue);
        expect(merged.queryLocation, current.queryLocation);
        expect(merged.sourceAddress, current.sourceAddress);
        expect(merged.diagnosticStatus, current.diagnosticStatus);
        expect(merged.queried, current.queried);
        expect(merged.aliasesAttempted, current.aliasesAttempted);
        expect(merged.searchHitCount, current.searchHitCount);
        expect(merged.bestMatchScore, current.bestMatchScore);
        expect(merged.matched, current.matched);
        expect(merged.episodeFound, current.episodeFound);
        expect(merged.discoveryElapsed, current.discoveryElapsed);
        expect(merged.expiresAt, same(expires));
        expect(merged.message, current.message);
        expect(merged.latency, metadata.latency);
        expect(merged.sizeBytes, metadata.sizeBytes);
        expect(merged.sizeEstimated, isTrue);
        expect(merged.videoWidth, 1920);
        expect(merged.videoHeight, 1080);
        expect(merged.bitrate, 5000000);
        expect(merged.codecs, metadata.codecs);
        expect(merged.quality, '1080P');
        expect(merged.format, 'HLS');
        expect(merged.adaptive, isTrue);
      },
    );

    test('URL or request header changes discard stale measurements', () {
      final current = _line('current', url: 'https://cdn.example/a.m3u8');
      final differentUrl = _line(
        'stale',
        url: 'https://cdn.example/b.m3u8',
        sizeBytes: 100,
      );
      final differentHeaders = _line(
        'stale',
        url: current.url,
        headers: const {'Referer': 'https://different.example/'},
        sizeBytes: 100,
      );
      expect(
        mergePlaybackLineMediaMetadata(
          current: current,
          metadata: differentUrl,
        ),
        same(current),
      );
      expect(
        mergePlaybackLineMediaMetadata(
          current: current,
          metadata: differentHeaders,
        ),
        same(current),
      );
      final noUrl = _line('empty', url: '');
      expect(
        mergePlaybackLineMediaMetadata(
          current: noUrl,
          metadata: _line('empty', url: ''),
        ),
        same(noUrl),
      );
    });

    test(
      'missing invalid and estimated metadata never erase measured values',
      () {
        final current = _line(
          'current',
          latencyMs: 266,
          sizeBytes: 50 * 1024 * 1024,
          width: 1920,
          height: 1080,
          bitrate: 5000000,
          codecs: 'avc1.640028',
          quality: '1080P',
          format: 'HLS',
          adaptive: true,
        );
        final sparse = _line(
          'current',
          latencyMs: -1,
          sizeBytes: 0,
          width: 0,
          height: -1,
          bitrate: -1,
          codecs: 'unknown',
          quality: 'unknown',
          format: 'auto',
          available: false,
        );
        final merged = mergePlaybackLineMediaMetadata(
          current: current,
          metadata: sparse,
        );
        expect(merged.latency, current.latency);
        expect(merged.sizeBytes, current.sizeBytes);
        expect(merged.videoWidth, current.videoWidth);
        expect(merged.videoHeight, current.videoHeight);
        expect(merged.bitrate, current.bitrate);
        expect(merged.codecs, current.codecs);
        expect(merged.quality, current.quality);
        expect(merged.format, current.format);
        expect(merged.adaptive, isTrue);
        expect(merged.available, isTrue);
        final estimated = mergePlaybackLineMediaMetadata(
          current: current,
          metadata: _line(
            'current',
            sizeBytes: 100 * 1024 * 1024,
            estimated: true,
          ),
        );
        expect(estimated.sizeBytes, current.sizeBytes);
        expect(estimated.sizeEstimated, isFalse);
        final live = mergePlaybackLineMediaMetadata(
          current: current,
          metadata: _line('current', isLive: true),
        );
        expect(live.isLive, isTrue);
        final legacy = mergePlaybackLineMediaMetadata(
          current: _line('current'),
          metadata: _line('current', sizeLabel: '约 20 MB', estimated: true),
        );
        expect(playbackLineSizeLabel(legacy), '约 20 MB');
      },
    );
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
        nativePlaybackHasFirstFrame(
          playing: true,
          position: Duration.zero,
          decodedVideo: false,
        ),
        isFalse,
      );
      expect(
        nativePlaybackHasFirstFrame(
          playing: false,
          position: const Duration(milliseconds: 1),
          decodedVideo: true,
        ),
        isTrue,
      );
    },
  );

  test('native first frame is recognized only on zero-to-progress edge', () {
    expect(
      nativePlaybackReachedFirstFrame(
        previousPosition: Duration.zero,
        decodedVideo: true,
        currentPosition: const Duration(milliseconds: 1),
      ),
      isTrue,
    );
    expect(
      nativePlaybackReachedFirstFrame(
        previousPosition: const Duration(milliseconds: 1),
        decodedVideo: true,
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

  test('web play events need positive media progress before first frame', () {
    expect(webPlaybackHasFirstFrame(position: Duration.zero), isFalse);
    expect(
      webPlaybackHasFirstFrame(position: const Duration(milliseconds: 1)),
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
      '约 50.0 MB · 1920×1080 · HLS · 5.0 Mbps · H.264/AAC',
    );
    expect(playbackLineLatencyLabel(_line('unknown')), '速度未知');
    expect(playbackLineMediaLabel(_line('unknown')), contains('大小未知'));
  });

  group('public playback metric helpers', () {
    test('latency bands include exact 500 and 1500 ms boundaries', () {
      final cases = <int, PlaybackLineLatencyBand>{
        -1: PlaybackLineLatencyBand.unknown,
        0: PlaybackLineLatencyBand.fast,
        500: PlaybackLineLatencyBand.fast,
        501: PlaybackLineLatencyBand.moderate,
        1500: PlaybackLineLatencyBand.moderate,
        1501: PlaybackLineLatencyBand.slow,
      };
      for (final entry in cases.entries) {
        expect(
          playbackLineLatencyBand(_line('delay', latencyMs: entry.key)),
          entry.value,
        );
      }
      expect(
        playbackLineLatencyBand(_line('unknown')),
        PlaybackLineLatencyBand.unknown,
      );
      expect(playbackLineLatencyLabel(_line('invalid', latencyMs: -1)), '速度未知');
    });

    test('positive byte sizes show MB and explicit estimates', () {
      final line = _line('size', sizeBytes: 50 * 1024 * 1024, estimated: true);
      expect(playbackLineSizeLabel(line), '约 50.0 MB');
      expect(playbackLineHasKnownSize(line), isTrue);
      expect(playbackLineSizeLabel(_line('small', sizeBytes: 1)), '<0.1 MB');
    });

    test(
      'zero and invalid bytes never become a fake size or legacy fallback',
      () {
        for (final size in [0, -1]) {
          final line = _line('invalid', sizeBytes: size, sizeLabel: '20 MB');
          expect(playbackLineSizeLabel(line), '大小未知');
          expect(playbackLineHasKnownSize(line), isFalse);
        }
        for (final label in [
          '',
          '--',
          'unknown',
          'NaN MB',
          'Infinity MB',
          '-1 MB',
          '0 MB',
        ]) {
          final line = _line('legacy-invalid', sizeLabel: label);
          expect(playbackLineSizeLabel(line), '大小未知');
          expect(playbackLineHasKnownSize(line), isFalse);
        }
      },
    );

    test('valid legacy sizes retain text and estimate truthfully', () {
      expect(
        playbackLineSizeLabel(_line('legacy', sizeLabel: '1.5 GB')),
        '1.5 GB',
      );
      expect(
        playbackLineHasKnownSize(_line('legacy', sizeLabel: '1.5 GB')),
        isTrue,
      );
      expect(
        playbackLineSizeLabel(
          _line('legacy', sizeLabel: '20 MB', estimated: true),
        ),
        '约 20 MB',
      );
      expect(
        playbackLineSizeLabel(
          _line('legacy', sizeLabel: '约 20 MB', estimated: true),
        ),
        '约 20 MB',
      );
      expect(
        playbackLineSizeLabel(_line('live', isLive: true, sizeBytes: 100)),
        '直播',
      );
      expect(
        playbackLineHasKnownSize(_line('live', isLive: true, sizeBytes: 100)),
        isFalse,
      );
    });

    test(
      'dimensions and legacy quality stay public without inventing missing data',
      () {
        final measured = _line(
          'resolution',
          width: 1920,
          height: 1080,
          adaptive: true,
        );
        expect(playbackLineResolutionLabel(measured), '1920×1080');
        expect(playbackLineHasKnownResolution(measured), isTrue);
        expect(
          playbackLineResolutionLabel(_line('legacy', quality: '720P')),
          '源标 720P',
        );
        expect(
          playbackLineHasKnownResolution(_line('legacy', quality: '720P')),
          isFalse,
          reason: 'source quality text is not a measured pixel resolution',
        );
        for (final quality in [
          '',
          '--',
          'unknown',
          '分辨率未知',
          'auto',
          'NaN',
          '0P',
        ]) {
          final unknown = _line('unknown', quality: quality);
          expect(playbackLineResolutionLabel(unknown), '分辨率未知');
          expect(playbackLineHasKnownResolution(unknown), isFalse);
        }
        expect(playbackLineFormatLabel(_line('format', format: 'HLS')), 'HLS');
        for (final format in ['', '--', 'unknown', 'auto']) {
          expect(
            playbackLineFormatLabel(_line('format', format: format)),
            '格式未知',
          );
        }
      },
    );

    test('pending resolver page never surfaces as a video URL', () {
      final descriptor = ClientMediaResolverDescriptor(
        pageUrl: Uri.parse('https://chapter.example/play/1.html'),
        referer: Uri.parse('https://chapter.example/'),
        ruleId: 'xfdmneo',
        ruleName: '稀饭动漫',
        userAgent: '',
        pageHosts: const ['chapter.example'],
        mediaHosts: const ['cdn.example'],
      );
      final pending = _line(
        'pending',
        url: descriptor.pageUrl.toString(),
        clientResolver: descriptor,
        diagnosticStatus: PlaybackDiscoveryStatus.clientResolverRequired,
      );
      expect(playbackLineMediaUrl(pending), isNull);
      expect(playbackLineLatencyLabel(pending), '本机解析中');
      expect(playbackLineMediaUrl(_line('blank', url: '')), isNull);
      expect(
        playbackLineMediaUrl(
          _line('page', url: 'https://example.com/play.html'),
        ),
        isNull,
      );
      expect(playbackLineMediaUrl(_line('bad', url: 'not-a-url')), isNull);
      expect(
        playbackLineMediaUrl(
          _line(
            'candidate',
            available: false,
            url: 'https://cdn.example/index.m3u8',
          ),
        ),
        'https://cdn.example/index.m3u8',
      );
    });

    test('flat display retains failed and pending candidates', () {
      final failed = _line(
        'failed-candidate',
        available: false,
        diagnosticStatus: PlaybackDiscoveryStatus.routeUnavailable,
      );
      final pending = _line(
        'resolver',
        available: false,
        url: '',
        diagnosticStatus: PlaybackDiscoveryStatus.clientResolverRequired,
      );
      final all = allPlaybackLinesForDisplay([failed, pending, _line('ready')]);
      expect(all.map((line) => line.id).toSet(), {
        'failed-candidate',
        'resolver',
        'ready',
      });
    });
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
    test(
      'upstream numbered route tags stay identifiable instead of aliasing',
      () {
        for (final tag in [
          'hb-10',
          'jk-18',
          'route-57',
          'hb-10-2',
          'yhdm-cn-10',
          'dm-xhs-5',
        ]) {
          expect(
            playbackProviderLabel(providerId: tag, providerName: tag),
            tag,
          );
        }
      },
    );

    test('已知规则 ID 映射为真实站名而不是随机别名', () {
      for (final name in ['xfdmneo', 'kazumi:xfdmneo', 'Kazumi · xfdmneo']) {
        expect(
          playbackProviderLabel(
            providerId: 'kazumi:xfdmneo',
            providerName: name,
          ),
          '稀饭动漫',
        );
      }
      expect(
        playbackProviderLabel(
          providerId: 'animeko:dm-yhdm',
          providerName: 'dm-yhdm',
        ),
        '樱花动漫',
      );
      expect(
        playbackProviderLabel(providerId: 'kazumi:mxdm', providerName: ''),
        'MX动漫',
      );
      expect(
        playbackProviderLabel(
          providerId: 'animeko:xifan-dongman',
          providerName: '',
        ),
        '稀饭动漫',
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

    test('没有源名时使用中性线路名称而非虚构来源', () {
      for (final id in [
        '',
        'custom:abc-1',
        'crawler.animeko',
        'crawler.kazumi',
        'crawler.anich',
      ]) {
        expect(playbackProviderLabel(providerId: id, providerName: ''), '线路');
      }
      expect(
        playbackProviderLabel(
          providerId: 'crawler.anich',
          providerName: 'AniCh',
        ),
        '线路',
      );
    });

    test('剥离多层聚合器前缀并保留真实线路和新规则名', () {
      for (final value in [
        'AniCh · hb-10',
        'anich:hb-10',
        '[AniCh] hb-10',
        '在线服务 · Animeko · AniCh · hb-10',
      ]) {
        expect(
          playbackProviderLabel(
            providerId: 'crawler.anich',
            providerName: value,
          ),
          'hb-10',
        );
      }
      for (final route in ['yhdm-cn-10', 'dm-xhs-5', 'hb-10-2']) {
        expect(
          playbackProviderLabel(
            providerId: route,
            providerName: 'AniCh · $route',
          ),
          route,
        );
      }
      expect(
        playbackProviderLabel(
          providerId: 'crawler.animeko',
          providerName: 'Animeko · other-rule',
        ),
        'other-rule',
      );
      expect(
        playbackProviderLabel(
          providerId: 'crawler.kazumi',
          providerName: 'Kazumi · 独立规则',
        ),
        '独立规则',
      );
    });

    test('线路名称优先保留编号线路否则使用真实 sourceName', () {
      expect(
        playbackLineProviderLabel(
          _line(
            'anich-tag',
            providerId: 'crawler.anich',
            providerName: 'AniCh · hb-10',
            sourceName: '某站点',
          ),
        ),
        'hb-10',
      );
      expect(
        playbackLineProviderLabel(
          _line(
            'source',
            providerId: 'crawler.kazumi',
            providerName: 'Kazumi',
            sourceName: 'xfdmneo',
          ),
        ),
        '稀饭动漫',
      );
      expect(
        playbackLineProviderLabel(
          _line(
            'source',
            providerId: 'crawler.animeko',
            providerName: 'Animeko',
            sourceName: 'dm-yhdm:线路1',
          ),
        ),
        '樱花动漫 · 线路1',
      );
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
  String providerName = '测试线路',
  String? quality,
  ClientMediaResolverDescriptor? clientResolver,
  Map<String, String> headers = const {},
  int? latencyMs,
  bool available = true,
  int? sizeBytes,
  String? sizeLabel,
  bool isLive = false,
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
  String startupProfile = PlaybackStartupProfile.unknown,
  String cacheState = 'unknown',
  String sourceErrorCategory = '',
  String sourceName = '',
  String diagnosticStatus = '',
  bool? queried,
  bool? matched,
  String? message,
}) {
  return PlaybackLine(
    id: id,
    episodeId: 1,
    providerId: providerId,
    providerName: providerName,
    title: id,
    quality:
        quality ?? (width == null || height == null ? '分辨率未知' : '${height}P'),
    format: format,
    url: url ?? 'https://example.com/$id',
    clientResolver: clientResolver,
    headers: headers,
    latency: latencyMs == null ? null : Duration(milliseconds: latencyMs),
    sizeBytes: sizeBytes,
    sizeLabel: sizeLabel,
    isLive: isLive,
    sizeEstimated: estimated,
    videoWidth: width,
    videoHeight: height,
    bitrate: bitrate,
    codecs: codecs,
    adaptive: adaptive,
    serverVerified: serverVerified,
    requiresClientProbe: requiresClientProbe,
    clientVerified: clientVerified,
    startupProfile: startupProfile,
    cacheState: cacheState,
    sourceErrorCategory: sourceErrorCategory,
    sourceName: sourceName,
    diagnosticStatus: diagnosticStatus,
    queried: queried,
    matched: matched,
    available: available,
    message: message,
  );
}
