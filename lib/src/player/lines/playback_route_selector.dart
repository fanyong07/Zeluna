import 'dart:async';

import '../../domain/anime_models.dart';
import '../../rules/rule_playback_cancellation.dart';
import '../playback_line_display.dart';

/// Interactive entrypoint: return the first locally qualified request without
/// exposing unchecked candidates or waiting for the slowest source. Expanded
/// inventory discovery remains the repository's independent stream.
Future<List<PlaybackLine>> selectFirstReadyPlaybackRoute(
  List<PlaybackLine> candidates, {
  required Future<PlaybackLine> Function(
    PlaybackLine,
    RulePlaybackCancellationToken,
  )
  verify,
  required RulePlaybackCancellationToken parent,
  Duration budget = const Duration(seconds: 12),
  int concurrency = 3,
}) async {
  final checked = candidates
      .where((l) => !playbackLineNeedsPreDisplayVerification(l))
      .toList();
  bool ready(PlaybackLine l) => l.available && (l.url?.isNotEmpty ?? false);
  if (parent.isCancelled) return const [];
  if (checked.any(ready)) return checked;
  final work = candidates
      .where(playbackLineNeedsPreDisplayVerification)
      .toList();
  final token = RulePlaybackCancellationToken();
  final unlink = parent.register(token.cancel);
  final stopped = Completer<({int index, PlaybackLine? line})>();
  final unregister = token.register(() {
    if (!stopped.isCompleted) stopped.complete((index: -1, line: null));
  });
  final deadline = Timer(budget, token.cancel);
  final pending = <int, Future<({int index, PlaybackLine? line})>>{};
  var next = 0;
  void fill() {
    while (!token.isCancelled &&
        next < work.length &&
        pending.length < concurrency) {
      final index = next++;
      pending[index] = Future.sync(() => verify(work[index], token)).then(
        (line) => (index: index, line: line),
        onError: (Object _, StackTrace _) => (index: index, line: null),
      );
    }
  }

  try {
    fill();
    while (pending.isNotEmpty && !token.isCancelled) {
      final result = await Future.any([...pending.values, stopped.future]);
      if (result.index < 0 || token.isCancelled) break;
      pending.remove(result.index);
      final line = result.line;
      if (line != null) {
        checked.add(line);
        if (ready(line)) break;
      }
      fill();
    }
    return parent.isCancelled ? const [] : checked;
  } finally {
    deadline.cancel();
    unlink();
    unregister();
    token.cancel();
  }
}
