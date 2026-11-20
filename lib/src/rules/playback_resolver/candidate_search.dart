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
const Map<String, String> _tradToSimpTitleChars = {
  '進': '进', '擊': '击', '撃': '击', '滅': '灭', '奧': '奥', '無': '无',
  '間': '间', '風': '风', '龍': '龙', '戰': '战', '劍': '剑', '愛': '爱',
  '國': '国', '電': '电', '劇': '剧', '傳': '传', '說': '说', '記': '记',
  '錄': '录', '語': '语', '東': '东', '學': '学', '園': '园', '術': '术',
  '師': '师', '異': '异', '轉': '转', '聖': '圣', '靈': '灵', '復': '复',
  '聯': '联', '銀': '银', '護': '护', '衛': '卫', '隊': '队', '時': '时',
  '戀': '恋', '與': '与', '殺': '杀', '紅': '红', '藍': '蓝', '雙': '双',
  '夢': '梦', '終': '终', '極': '极', '決': '决', '勝': '胜', '開': '开',
  '關': '关', '門': '门', '鐵': '铁', '變': '变', '飛': '飞', '長': '长',
  '萬': '万', '歸': '归', '來': '来', '慶': '庆', '餘': '余', '權': '权',
  '遊': '游', '戲': '戏', '絕': '绝', '屍': '尸', '際': '际', '盜': '盗',
  '彈': '弹', '瘋': '疯', '麥': '麦', '導': '导', '動': '动', '漫': '漫',
  '網': '网', '俠': '侠', '義': '义', '總': '总', '蒼': '苍', '華': '华',
  '蓮': '莲', '獨': '独', '櫻': '樱', '話': '话', '號': '号', '頭': '头',
  '體': '体', '會': '会', '機': '机', '氣': '气', '見': '见', '觀': '观',
  '視': '视', '聽': '听', '聲': '声', '書': '书', '問': '问', '題': '题',
  '發': '发', '現': '现', '經': '经', '過': '过', '還': '还', '這': '这',
  '個': '个', '們': '们', '為': '为', '對': '对', '將': '将', '島': '岛',
  '雲': '云', '霧': '雾', '鳥': '鸟', '魚': '鱼', '馬': '马', '貓': '猫',
  '獸': '兽', '惡': '恶', '魔': '魔', '鬼': '鬼', '神': '神', '王': '王',
};

String _toSimplifiedTitle(String value) {
  final buffer = StringBuffer();
  for (final rune in value.runes) {
    final ch = String.fromCharCode(rune);
    buffer.write(_tradToSimpTitleChars[ch] ?? ch);
  }
  return buffer.toString();
}

String _normalizeTitle(String value) {
  return _toSimplifiedTitle(
    value,
  ).toLowerCase().replaceAll(_titleSeparatorPattern, '').trim();
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
