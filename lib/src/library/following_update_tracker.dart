import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../data/anime_controller.dart';
import '../data/bangumi_metadata_repository.dart';
import '../domain/anime_models.dart';

@immutable
class FollowingUpdateStatus {
  const FollowingUpdateStatus({
    required this.latestAiredEpisode,
    required this.watchedEpisode,
    this.watchingEpisode,
  });

  final int latestAiredEpisode;
  final int watchedEpisode;
  final int? watchingEpisode;

  @override
  bool operator ==(Object other) =>
      other is FollowingUpdateStatus &&
      latestAiredEpisode == other.latestAiredEpisode &&
      watchedEpisode == other.watchedEpisode &&
      watchingEpisode == other.watchingEpisode;

  @override
  int get hashCode =>
      Object.hash(latestAiredEpisode, watchedEpisode, watchingEpisode);

  int get unwatchedCount => latestAiredEpisode > watchedEpisode
      ? latestAiredEpisode - watchedEpisode
      : 0;
  bool get hasUpdates => unwatchedCount > 0;

  String get detailLabel {
    if (latestAiredEpisode > 0) {
      return hasUpdates
          ? '更新至第 $latestAiredEpisode 集 · 未看 $unwatchedCount 集'
          : '已追平 · 共 $latestAiredEpisode 集';
    }
    if (watchingEpisode != null) return '看到第 $watchingEpisode 集';
    if (watchedEpisode > 0) return '已看到第 $watchedEpisode 集';
    return '';
  }

  String? get shortBadge => hasUpdates
      ? '未看 $unwatchedCount 集'
      : latestAiredEpisode > 0
      ? '已追平'
      : null;
}

int latestAiredEpisodeNumber(
  List<AnimeEpisode> episodes, {
  DateTime? now,
  int fallbackTotal = 0,
}) {
  final local = (now ?? DateTime.now()).toLocal();
  final tomorrow = DateTime(local.year, local.month, local.day + 1);
  var largest = 0;
  int? aired;
  for (final episode in episodes) {
    if (episode.number <= 0) continue;
    if (episode.number > largest) largest = episode.number;
    final raw = episode.airdate;
    if (raw == null) continue;
    final day = DateTime.tryParse(raw);
    // tryParse normalizes impossible calendar dates, e.g. 2026-02-30.
    if (day == null ||
        (raw.length == 10 && !day.toIso8601String().startsWith('${raw}T'))) {
      continue;
    }
    aired ??= 0;
    if (day.isBefore(tomorrow) && episode.number > aired) {
      aired = episode.number;
    }
  }
  return aired ?? (largest > 0 ? largest : fallbackTotal);
}

FollowingUpdateStatus computeFollowingUpdateStatus({
  required LibraryEntry followingEntry,
  LibraryEntry? historyEntry,
  int? latestAiredEpisodeOverride,
}) {
  final source = historyEntry ?? followingEntry;
  final number = source.episode?.number ?? 0;
  final progress = source.playbackProgress;
  final inProgress = progress != null && progress < episodeWatchedThreshold;
  return FollowingUpdateStatus(
    latestAiredEpisode:
        latestAiredEpisodeOverride ?? followingEntry.subject.totalEpisodes,
    watchedEpisode: inProgress ? (number - 1).clamp(0, 9999) : number,
    watchingEpisode: inProgress ? source.episode?.number : null,
  );
}

final followingUpdateTrackerProvider =
    ChangeNotifierProvider<FollowingUpdateTracker>(
      (ref) =>
          FollowingUpdateTracker(ref.watch(bangumiMetadataRepositoryProvider)),
    );

class FollowingUpdateTracker extends ChangeNotifier {
  FollowingUpdateTracker(this._repository, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final BangumiMetadataRepository _repository;
  final DateTime Function() _clock;
  final _cache = <String, ({int aired, DateTime expires})>{};
  final _pending = <String, Completer<void>>{};
  final _queue = Queue<AnimeSubject>();
  int _workers = 0;
  bool _disposed = false;

  bool get refreshing => _pending.isNotEmpty;
  int? latestAiredFor(String subjectKey) {
    final value = _cache[subjectKey];
    return value != null && _clock().isBefore(value.expires)
        ? value.aired
        : null;
  }

  FollowingUpdateStatus statusFor(
    LibraryEntry entry,
    List<LibraryEntry> history,
  ) => computeFollowingUpdateStatus(
    followingEntry: entry,
    historyEntry: history
        .where((item) => sameSubjectIdentity(item.subject, entry.subject))
        .firstOrNull,
    latestAiredEpisodeOverride: latestAiredFor(entry.subject.identityKey),
  );

  Future<void> refreshForSubjects(
    Iterable<AnimeSubject> subjects, {
    bool force = false,
  }) async {
    final wasRefreshing = refreshing;
    final work = <Future<void>>[];
    for (final subject in subjects) {
      final key = subject.identityKey;
      if (subject.source != 'bangumi' || subject.id <= 0) continue;
      if (!force && latestAiredFor(key) != null && !_pending.containsKey(key)) {
        continue;
      }
      final done = _pending.putIfAbsent(key, () {
        _queue.add(subject);
        return Completer<void>();
      });
      work.add(done.future);
    }
    while (_workers < 3 && _queue.isNotEmpty) {
      unawaited(_drain());
    }
    if (!wasRefreshing && refreshing) notifyListeners();
    await Future.wait(work);
  }

  Future<void> _drain() async {
    _workers++;
    while (_queue.isNotEmpty) {
      final subject = _queue.removeFirst();
      final key = subject.identityKey;
      try {
        if (_disposed) continue;
        final episodes = await _repository.episodesForSubject(subject);
        final aired = latestAiredEpisodeNumber(
          episodes,
          now: _clock(),
          fallbackTotal: subject.totalEpisodes,
        );
        _cache[key] = (
          aired: aired,
          expires: _clock().add(const Duration(minutes: 15)),
        );
      } on Exception {
        // One unavailable subject does not invalidate other results or get a fresh TTL.
        continue;
      } finally {
        _pending.remove(key)!.complete();
        if (!_disposed) notifyListeners();
      }
    }
    _workers--;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
