import 'package:flutter/foundation.dart';

import '../../domain/anime_models.dart';
import 'episode_skip_resolver.dart';
import 'skip_segment.dart';

class EpisodeSkipController extends ChangeNotifier {
  int _generation = 0;
  Duration _duration = Duration.zero;
  List<SkipSegment> _manual = const [],
      _chapters = const [],
      _online = const [],
      _danmaku = const [];
  String? _chapterJson;
  List<DanmakuComment> _comments = const [];
  List<SkipSegment> _segments = const [];
  List<SkipSegment> get segments => _segments;
  SkipSegment? activeSegmentAt(Duration position) =>
      _segments.where((s) => s.contains(position)).firstOrNull;

  void resetForEpisode() {
    _generation++;
    _duration = Duration.zero;
    _manual = _chapters = _online = _danmaku = const [];
    _chapterJson = null;
    _comments = const [];
    _merge();
  }

  void updateDuration(Duration value) {
    if (value == _duration) return;
    _duration = value;
    _chapters = parseMpvChapterSkipSegments(_chapterJson, duration: value);
    _danmaku = analyzeDanmakuSkipSegments(_comments, duration: value);
    _merge();
  }

  void updateManual(List<SkipSegment> segments) {
    _manual = segments;
    _merge();
  }

  void updateChapters(String? json) {
    _chapterJson = json;
    _chapters = parseMpvChapterSkipSegments(json, duration: _duration);
    _merge();
  }

  void updateDanmaku(List<DanmakuComment> comments) {
    if (identical(_comments, comments)) return;
    _comments = comments;
    _danmaku = analyzeDanmakuSkipSegments(comments, duration: _duration);
    _merge();
  }

  Future<void> loadOnline(
    EpisodeSkipRepository repository,
    AnimeSubject subject,
    int episodeNumber,
    ExternalServiceSettings services,
  ) async {
    final generation = _generation;
    final result = await repository.load(
      subject: subject,
      episodeNumber: episodeNumber,
      duration: _duration,
      services: services,
    );
    if (generation != _generation) return;
    _online = result;
    _merge();
  }

  void _merge() {
    final next = mergeSkipSegments([
      ..._manual,
      ..._chapters,
      ..._online,
      ..._danmaku,
    ], episodeDuration: _duration);
    if (listEquals(_segments, next)) return;
    _segments = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }
}
