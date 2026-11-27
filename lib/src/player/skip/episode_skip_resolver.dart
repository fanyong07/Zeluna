import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../../core/network/network_http_client.dart';
import '../../core/network/network_security.dart';
import '../../domain/anime_models.dart';
import 'skip_segment.dart';

final _opening = RegExp(
  r'\b(op\d*|opening|intro|theme)\b|片头',
  caseSensitive: false,
);
final _ending = RegExp(
  r'\b(ed\d*|ending|outro|credits)\b|片尾',
  caseSensitive: false,
);
final _recap = RegExp(r'\b(recap|previously)\b|前情', caseSensitive: false);
Duration _seconds(num seconds) =>
    Duration(milliseconds: (seconds * 1000).round());

List<SkipSegment> parseMpvChapterSkipSegments(
  String? chapterListJson, {
  Duration? duration,
}) {
  if (chapterListJson == null || chapterListJson.isEmpty) return const [];
  final Object? decoded;
  try {
    decoded = jsonDecode(chapterListJson);
  } on FormatException {
    return const [];
  }
  if (decoded is! List) return const [];
  final chapters = <({String title, Duration time})>[
    for (final row in decoded)
      if (row case {'time': num t} when t.isFinite && t >= 0)
        (title: row['title'] is String ? row['title'] : '', time: _seconds(t)),
  ];
  final matches = <SkipSegment>[];
  for (var i = 0; i < chapters.length; i++) {
    final (:title, :time) = chapters[i];
    final end = i + 1 < chapters.length ? chapters[i + 1].time : duration;
    if (end == null ||
        end - time < const Duration(seconds: 15) ||
        end - time > const Duration(minutes: 4)) {
      continue;
    }
    final type = _ending.hasMatch(title)
        ? SkipSegmentType.ed
        : _recap.hasMatch(title)
        ? SkipSegmentType.recap
        : _opening.hasMatch(title)
        ? SkipSegmentType.op
        : null;
    if (type != null) {
      matches.add(
        SkipSegment(
          type: type,
          start: time,
          end: end,
          title: title,
          source: SkipSegmentSource.chapter,
        ),
      );
    }
  }
  // Some files label the cold open "Intro" and the actual song "OP".
  final explicitOp = RegExp(r'\b(op\d*|opening)\b|片头', caseSensitive: false);
  if (matches.any(
    (s) => s.type == SkipSegmentType.op && explicitOp.hasMatch(s.title!),
  )) {
    matches.removeWhere(
      (s) => s.type == SkipSegmentType.op && !explicitOp.hasMatch(s.title!),
    );
  }
  return mergeSkipSegments(matches, episodeDuration: duration);
}

final _coordinate = RegExp(
  r'(?:空降|跳(?:过)?\s*(?:片头|op)|正片|op\s*结束)\s*0?(\d{1,2})[:：]([0-5]\d)(?!\d)',
  caseSensitive: false,
);
final _landing = RegExp('空降成功|感谢空降|精准空降');
final _opCue = RegExp(r'\bop\b|片头|空降', caseSensitive: false);
final _edCue = RegExp(r'\bed\b|片尾|卡点|下集预告', caseSensitive: false);
final _postCredits = RegExp(r'彩蛋|正片|c[ -]?part', caseSensitive: false);

Duration? _firstCluster(List<Duration> times, int count) {
  for (var i = count - 1; i < times.length; i++) {
    final first = times[i - count + 1];
    if (times[i] - first <= const Duration(seconds: 12)) return first;
  }
  return null;
}

List<SkipSegment> analyzeDanmakuSkipSegments(
  List<DanmakuComment> comments, {
  required Duration duration,
}) {
  if (duration <= Duration.zero || comments.isEmpty) return const [];
  final opLimit = _seconds(math.min(480, duration.inSeconds * .4));
  final edFrom = duration * .65;
  final votes = <({Duration time, bool explicit})>[];
  final cues = <Duration>[], endings = <Duration>[], extras = <Duration>[];
  final seen = <(String, String)>{};
  for (final c in comments) {
    final t = c.time;
    if (t < Duration.zero || t > duration || (t > opLimit && t < edFrom)) {
      continue;
    }
    if (!seen.add((c.provider, c.id))) continue;
    if (t <= opLimit) {
      final match = _coordinate.firstMatch(c.text);
      final landed = _landing.hasMatch(c.text);
      final target = match != null
          ? Duration(seconds: int.parse(match[1]!) * 60 + int.parse(match[2]!))
          : landed
          ? t
          : null;
      if (target != null && target >= t && target <= opLimit) {
        votes.add((time: target, explicit: match != null));
      }
      if (!landed && _opCue.hasMatch(c.text)) cues.add(t);
    }
    if (duration >= const Duration(minutes: 10) && t >= edFrom) {
      if (_edCue.hasMatch(c.text)) endings.add(t);
      if (_postCredits.hasMatch(c.text)) extras.add(t);
    }
  }
  final result = <SkipSegment>[];
  // Anchor five-second buckets to observed landings rather than wall-clock
  // multiples: 03:14 and 03:15 corroborate each other, not two separate OPs.
  votes.sort((a, b) => a.time.compareTo(b.time));
  final groups = <List<({Duration time, bool explicit})>>[];
  for (final vote in votes) {
    if (groups.isEmpty ||
        vote.time - groups.last.first.time > const Duration(seconds: 5)) {
      groups.add([]);
    }
    groups.last.add(vote);
  }
  groups.sort((a, b) => b.length.compareTo(a.length));
  if (groups.isNotEmpty &&
      groups.first.length >= 2 &&
      (groups.length == 1 || groups.first.length > groups[1].length)) {
    final group = groups.first;
    final coordinates = group.where((v) => v.explicit).toList();
    final evidence = coordinates.isEmpty ? group : coordinates;
    final end = evidence[(evidence.length - 1) ~/ 2].time;
    final window =
        cues
            .where(
              (t) =>
                  end - t >= const Duration(seconds: 60) &&
                  end - t <= const Duration(seconds: 120),
            )
            .toList()
          ..sort();
    final start =
        _firstCluster(window, 2) ??
        (end >= const Duration(seconds: 75) &&
                end <= const Duration(seconds: 120)
            ? _seconds(math.max(0, end.inSeconds - 90))
            : null);
    if (start != null) {
      result.add(
        SkipSegment(
          type: SkipSegmentType.op,
          start: start,
          end: end,
          source: SkipSegmentSource.danmaku,
        ),
      );
    }
  }
  final start = _firstCluster(endings..sort(), 3);
  if (start != null) {
    final end = [
      duration,
      start + const Duration(seconds: 90),
      ...extras.where((t) => t > start),
    ].reduce((a, b) => a < b ? a : b);
    result.add(
      SkipSegment(
        type: SkipSegmentType.ed,
        start: start,
        end: end,
        source: SkipSegmentSource.danmaku,
      ),
    );
  }
  return mergeSkipSegments(result, episodeDuration: duration);
}

class EpisodeSkipRepository {
  EpisodeSkipRepository({http.Client? client})
    : _client =
          client ??
          createNetworkHttpClient(
            NetworkRequestPolicy.forService(NetworkServiceKind.metadataApi),
          );
  final http.Client _client;
  final _episodes = <(String, int), Future<List<SkipSegment>>>{};
  final _malIds = <String, Future<int?>>{};
  void dispose() => _client.close();

  Future<List<SkipSegment>> load({
    required AnimeSubject subject,
    required int episodeNumber,
    required Duration duration,
    required ExternalServiceSettings services,
  }) => _episodes.putIfAbsent((
    subject.identityKey,
    episodeNumber,
  ), () => _lookup(subject, episodeNumber, duration, services));

  Future<Map<String, dynamic>?> _json(
    Future<http.Response> Function() request,
  ) async {
    try {
      final response = await request().timeout(const Duration(seconds: 6));
      if (response.statusCode != 200) return null;
      final value = jsonDecode(utf8.decode(response.bodyBytes));
      return value is Map<String, dynamic> ? value : null;
    } on Exception {
      // Unavailable metadata is a miss, not a playback failure.
      return null;
    }
  }

  Future<List<SkipSegment>> _lookup(
    AnimeSubject subject,
    int episode,
    Duration duration,
    ExternalServiceSettings services,
  ) async {
    final official = Uri.https('api.zeluna.top', '');
    final endpoint = Uri.tryParse(services.playbackBackendEndpoint.trim());
    if (services.playbackBackendEnabled &&
        (endpoint == official || endpoint == official.replace(path: '/'))) {
      final parsedYear = int.tryParse(subject.year);
      final uri = official.replace(
        path: '/api/v3/skip-times',
        queryParameters: {
          if (subject.source == 'bangumi') 'bangumi_id': '${subject.id}',
          'title': subject.title,
          'original_title': subject.originalTitle,
          if (parsedYear != null) 'year': '$parsedYear',
          if (subject.totalEpisodes > 0)
            'total_episodes': '${subject.totalEpisodes}',
          'episode_number': '$episode',
          'episode_length': '${duration.inSeconds}',
        },
      );
      final data = await _json(() => _client.get(uri));
      if (data case {'found': true, 'segments': List rows}) {
        final segments = mergeSkipSegments(
          _decodeSegments(rows, official: true),
          episodeDuration: duration,
        );
        if (segments.isNotEmpty) return segments;
      }
    }
    final mal = await _malIds.putIfAbsent(
      subject.identityKey,
      () => _findMal(subject),
    );
    if (mal == null) return const [];
    final uri = Uri.https('api.aniskip.com', '/v2/skip-times/$mal/$episode', {
      'types': ['op', 'ed', 'mixed-op', 'mixed-ed', 'recap'],
      'episodeLength': '${duration.inSeconds}',
    });
    final data = await _json(() => _client.get(uri));
    if (data case {'results': List rows} when data['found'] != false) {
      return mergeSkipSegments(
        _decodeSegments(rows, official: false),
        episodeDuration: duration,
      );
    }
    return const [];
  }

  Future<int?> _findMal(AnimeSubject subject) async {
    const query =
        r'query ($search: String!) { Page(page: 1, perPage: 10) { media(search: $search, type: ANIME) { idMal title { native romaji english } startDate { year } episodes } } }';
    final names = {subject.originalTitle.trim(), subject.title.trim()}
      ..remove('');
    String normalize(String text) =>
        text.toLowerCase().replaceAll(RegExp(r'[\s\p{P}]+', unicode: true), '');
    final titles = names.map(normalize).toSet();
    final year = int.tryParse(subject.year);
    for (final name in names) {
      final data = await _json(
        () => _client.post(
          Uri.https('graphql.anilist.co', ''),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'query': query,
            'variables': {'search': name},
          }),
        ),
      );
      if (data case {'data': {'Page': {'media': List rows}}}) {
        final scores = <int, int>{};
        for (final row in rows) {
          if (row case {'idMal': int id, 'title': Map aliases} when id > 0) {
            if (!aliases.values
                .whereType<String>()
                .map(normalize)
                .any(titles.contains)) {
              continue;
            }
            final candidateYear = switch (row['startDate']) {
              {'year': int y} => y,
              _ => null,
            };
            if (year != null &&
                candidateYear != null &&
                candidateYear != year) {
              continue;
            }
            scores[id] =
                (year != null && candidateYear == year ? 2 : 0) +
                (subject.totalEpisodes > 0 &&
                        row['episodes'] == subject.totalEpisodes
                    ? 1
                    : 0);
          }
        }
        if (scores.isNotEmpty) {
          final best = scores.values.reduce(math.max);
          final ids = scores.keys.where((id) => scores[id] == best);
          if (ids.length == 1) return ids.single;
        }
      } else {
        return null;
      }
    }
    return null;
  }
}

Iterable<SkipSegment> _decodeSegments(
  List<dynamic> rows, {
  required bool official,
}) sync* {
  for (final row in rows.whereType<Map>()) {
    final type = switch (row[official ? 'type' : 'skipType']) {
      'op' || 'mixed-op' => SkipSegmentType.op,
      'ed' || 'mixed-ed' => SkipSegmentType.ed,
      'recap' => SkipSegmentType.recap,
      _ => null,
    };
    final interval = official ? row : row['interval'];
    if (type == null || interval is! Map) continue;
    final start = interval[official ? 'start' : 'startTime'],
        end = interval[official ? 'end' : 'endTime'];
    if (start is num && end is num && start.isFinite && end.isFinite) {
      yield SkipSegment(
        type: type,
        start: _seconds(start),
        end: _seconds(end),
        source: SkipSegmentSource.aniskip,
      );
    }
  }
}
