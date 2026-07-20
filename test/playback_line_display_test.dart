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
    providerId: 'test',
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
