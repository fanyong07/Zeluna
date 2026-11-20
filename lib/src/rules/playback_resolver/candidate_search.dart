part of '../rule_playback_resolver.dart';

// Shared candidate scheduling and title matching.

class _SearchHit {
  const _SearchHit({required this.title, required this.url});

  final String title;
  final String url;
}

class _RankedResult<T> {
  const _RankedResult({
    required this.value,
    required this.score,
    required this.preference,
  });

  final T value;
  final int score;
  final int preference;
}

Future<List<PlaybackLine>> _collectPlaybackCandidates(
  List<Future<PlaybackLine?> Function()> requests, {
  required bool verifyPlayable,
  Duration candidateTimeout = const Duration(seconds: 10),
  bool Function(PlaybackLine line)? preferredQuickCandidate,
  Duration preferredCandidateGrace = Duration.zero,
  PlaybackLine? Function(int index)? pendingCandidate,
}) async {
  if (requests.isEmpty) return const [];
  if (verifyPlayable) {
    final results = List<PlaybackLine?>.filled(requests.length, null);
    var nextIndex = 0;
    var expired = false;
    Future<void> worker() async {
      while (!expired && nextIndex < requests.length) {
        final index = nextIndex++;
        try {
          results[index] = await requests[index]().timeout(candidateTimeout);
        } catch (_) {
          // One slow/broken route must not erase the other returned routes.
        }
      }
    }

    final work = Future.wait(
      List.generate(requests.length < 4 ? requests.length : 4, (_) => worker()),
    );
    if (pendingCandidate == null) {
      await work;
    } else {
      // Direct API inventories are known before probes. Return every known
      // route within the rule budget, keeping pending ones non-playable.
      await work.timeout(
        candidateTimeout,
        onTimeout: () {
          expired = true;
          return <void>[];
        },
      );
    }
    return [
      for (var index = 0; index < results.length; index++)
        ?(results[index] ?? pendingCandidate?.call(index)),
    ];
  }

  // The startup lookup only needs one usable route. Waiting for every road in
  // the same rule made one slow play page hold back faster siblings and often
  // pushed the whole rule beyond the outer quick-lookup budget. Start at most
  // three roads and stop dispatching new ones as soon as a playable line wins.
  const concurrency = 3;
  final completer = Completer<List<PlaybackLine>>();
  PlaybackLine? firstUnavailable;
  PlaybackLine? fallbackAvailable;
  Timer? preferenceTimer;
  var nextIndex = 0;
  var active = 0;
  var completed = 0;

  void completeWith(PlaybackLine line) {
    if (completer.isCompleted) return;
    preferenceTimer?.cancel();
    completer.complete(<PlaybackLine>[line]);
  }

  late void Function() dispatch;

  Future<void> run(Future<PlaybackLine?> Function() start) async {
    try {
      final line = await start();
      if (line != null && line.available && !completer.isCompleted) {
        final prefers = preferredQuickCandidate;
        if (prefers == null || prefers(line)) {
          completeWith(line);
        } else {
          fallbackAvailable ??= line;
          if (preferredCandidateGrace <= Duration.zero) {
            completeWith(line);
          } else {
            preferenceTimer ??= Timer(preferredCandidateGrace, () {
              final fallback = fallbackAvailable;
              if (fallback != null) completeWith(fallback);
            });
          }
        }
      } else if (line != null) {
        firstUnavailable ??= line;
      }
    } catch (_) {
      // A failed road must not delay another road that is already playable.
    } finally {
      active--;
      completed++;
      if (!completer.isCompleted) {
        final fallback = fallbackAvailable;
        if (fallback != null) {
          // Once a usable fallback exists, do not start more roads. Give only
          // the already-running siblings a bounded chance to return the
          // preferred streaming format, then avoid a fixed grace delay when
          // every sibling has already completed.
          if (active == 0) completeWith(fallback);
        } else if (completed == requests.length) {
          final unavailable = firstUnavailable;
          completer.complete(
            unavailable == null
                ? const <PlaybackLine>[]
                : <PlaybackLine>[unavailable],
          );
        } else {
          dispatch();
        }
      }
    }
  }

  dispatch = () {
    while (!completer.isCompleted &&
        fallbackAvailable == null &&
        active < concurrency &&
        nextIndex < requests.length) {
      final start = requests[nextIndex++];
      active++;
      unawaited(run(start));
    }
  };

  dispatch();
  return completer.future;
}

bool _isHlsPlaybackLine(PlaybackLine line) =>
    line.format.trim().toUpperCase() == 'HLS' ||
    (line.url?.toLowerCase().contains('.m3u8') ?? false);

Future<T?> _firstConfidentResult<T>(List<Future<_RankedResult<T>?>> requests) {
  if (requests.isEmpty) return Future<T?>.value();

  final completer = Completer<T?>();
  _RankedResult<T>? best;
  Object? firstError;
  StackTrace? firstStackTrace;
  var remaining = requests.length;

  for (final request in requests) {
    unawaited(() async {
      try {
        final result = await request;
        if (result != null) {
          final current = best;
          if (current == null ||
              result.score > current.score ||
              (result.score == current.score &&
                  result.preference < current.preference)) {
            best = result;
          }
          if (result.score >= 80 && !completer.isCompleted) {
            completer.complete(result.value);
          }
        }
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      } finally {
        remaining--;
        if (remaining == 0 && !completer.isCompleted) {
          final result = best;
          if (result != null) {
            completer.complete(result.value);
          } else if (firstError != null) {
            completer.completeError(firstError!, firstStackTrace);
          } else {
            completer.complete(null);
          }
        }
      }
    }());
  }
  return completer.future;
}

String _searchUrl(String template, String keyword) {
  final encoded = Uri.encodeQueryComponent(keyword);
  return template
      .replaceAll('@keyword', encoded)
      .replaceAll('{keyword}', encoded)
      .replaceAll('{wd}', encoded)
      .replaceAll('{pg}', '1');
}

String _searchBody(String template, String keyword) {
  return template
      .replaceAll('{wd}', Uri.encodeQueryComponent(keyword))
      .replaceAll('@keyword', Uri.encodeQueryComponent(keyword))
      .replaceAll('{pg}', '1');
}

List<String> _searchKeywords(AnimeSubject subject) {
  final values = <String>[subject.title, subject.originalTitle];
  final seen = <String>{};
  return values
      .where((item) {
        final normalized = _normalizeTitle(item);
        return normalized.isNotEmpty && seen.add(normalized);
      })
      .map((item) => item.trim())
      .toList(growable: false);
}

_RankedResult<_SearchHit>? _rankBestHit(
  List<_SearchHit> hits,
  AnimeSubject subject,
  int preference,
) {
  if (hits.isEmpty) return null;
  var best = hits.first;
  var bestScore = -1;
  for (final hit in hits) {
    final score = _matchScore(hit.title, subject);
    if (score > bestScore) {
      best = hit;
      bestScore = score;
    }
  }
  return bestScore <= 0
      ? null
      : _RankedResult(value: best, score: bestScore, preference: preference);
}

int _matchScore(String title, AnimeSubject subject) {
  final candidate = _normalizeTitle(title);
  final targets = [
    _normalizeTitle(subject.title),
    _normalizeTitle(subject.originalTitle),
  ].where((item) => item.isNotEmpty);
  var score = 0;
  for (final target in targets) {
    if (candidate == target) {
      score = score < 100 ? 100 : score;
    } else if (candidate.contains(target) || target.contains(candidate)) {
      score = score < 80 ? 80 : score;
    } else {
      final overlap = target.runes
          .where((char) => candidate.runes.contains(char))
          .length;
      if (overlap >= 2 && score < 30) score = 30;
    }
  }
  return score;
}

final RegExp _titleSeparatorPattern = RegExp(r'[\s·・:：!！?？,，.。_\-—]+');
final RegExp _whitespacePattern = RegExp(r'\s+');

String _normalizeTitle(String value) {
  return value.toLowerCase().replaceAll(_titleSeparatorPattern, '').trim();
}

String _cleanText(String value) {
  // Only spin up the HTML parser when the string actually contains markup or
  // entities; plain titles/channel names just need whitespace collapsing.
  if (!value.contains('<') && !value.contains('&')) {
    return value.replaceAll(_whitespacePattern, ' ').trim();
  }
  final text = html_parser.parseFragment(value).text;
  return text
          ?.replaceAll(_whitespacePattern, ' ')
          .replaceAll('&nbsp;', ' ')
          .trim() ??
      '';
}
