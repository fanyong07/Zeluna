import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../accounts/local_account_repository.dart';
import '../core/identity/stable_identity.dart';
import '../data/anime_controller.dart';
import '../data/bangumi_metadata_repository.dart';
import '../domain/anime_models.dart';
import 'following_update_tracker.dart';

class BangumiImportResult {
  const BangumiImportResult({
    required this.totalFetched,
    required this.newlyFollowed,
    required this.progressUpdated,
  });

  final int totalFetched;
  final int newlyFollowed;
  final int progressUpdated;
}

final bangumiSyncServiceProvider = Provider<BangumiSyncService>((ref) {
  ref.watch(
    animeControllerProvider.select(
      (state) => state.value?.accountSession.current?.id,
    ),
  );
  return BangumiSyncService(ref, ref.watch(bangumiMetadataRepositoryProvider));
});

class BangumiSyncService {
  BangumiSyncService(this._ref, this._repository);

  final Ref _ref;
  final BangumiMetadataRepository _repository;
  final _syncedEpisodeKeys = <(int, int)>{};
  final _sending = <(int, int)>{};
  Future<BangumiImportResult>? _importing;

  Future<BangumiImportResult> importWatchingToLibrary() =>
      _importing ??= _importWatching().whenComplete(() => _importing = null);

  Future<BangumiImportResult> _importWatching() async {
    final controller = _ref.read(animeControllerProvider.notifier);
    final version = controller.accountContextVersion;
    AnimeState currentLibrary() {
      if (!_ref.mounted || !controller.isAccountContextCurrent(version)) {
        throw const AccountException('账号已变更，已停止导入');
      }
      return _ref.read(animeControllerProvider).requireValue;
    }

    final items = await _repository.fetchWatchingCollection();
    var followed = 0;
    var updated = 0;
    for (final item in items) {
      final subject = item.subject;
      if (!currentLibrary().following.any(
        (entry) => sameSubjectIdentity(entry.subject, subject),
      )) {
        if (await controller.toggleFollowing(subject)) followed++;
      }
      final number = item.watchedEpisodes;
      if (number == 0) continue;
      final history = currentLibrary().history
          .where((entry) => sameSubjectIdentity(entry.subject, subject))
          .firstOrNull;
      if (history != null) {
        final local = computeFollowingUpdateStatus(followingEntry: history);
        if (local.watchedEpisode >= number) continue;
        if (history.episode?.number == number) {
          // Keep the real episode ID and finish the local partial resume point.
          final duration = Duration(seconds: history.durationSeconds);
          await controller.updatePlaybackProgress(
            subject,
            history.episode!,
            position: duration,
            duration: duration,
            expectedAccountContextVersion: version,
          );
          updated++;
          continue;
        }
      }
      // ep_status is a count, not a Bangumi episode ID. A local placeholder
      // must never be sent to the episode collection endpoint.
      final episode = AnimeEpisode(
        id: -number,
        subjectId: subject.id,
        number: number,
        title: '',
        airdate: null,
        duration: '',
        description: '',
      );
      if (await controller.addHistory(
        subject,
        episode,
        expectedAccountContextVersion: version,
      )) {
        updated++;
      }
    }
    return BangumiImportResult(
      totalFetched: items.length,
      newlyFollowed: followed,
      progressUpdated: updated,
    );
  }

  Future<bool> syncEpisodeWatchedIfEnabled({
    required bool enabled,
    required AnimeSubject subject,
    required AnimeEpisode episode,
  }) async {
    if (!enabled ||
        subject.source != 'bangumi' ||
        subject.id <= 0 ||
        episode.id <= 0) {
      return false;
    }
    final key = (subject.id, episode.id);
    return _sendOnce(key, () async {
      final number = episode.number;
      final localKey = stableEpisodeKey(
        subjectKey: 'bangumi:${subject.id}',
        normalizedNumber: number,
      );
      // Server catalogues and offline fallbacks assign local IDs. Resolve those
      // by exact episode number instead of PUTting one into someone else's show.
      if (episode.id == stableInt63(localKey) ||
          episode.id == subject.id * 1000 + number) {
        final controller = _ref.read(animeControllerProvider.notifier);
        final version = controller.accountContextVersion;
        final episodes = await _repository.episodesForSubject(subject);
        final official = episodes.where((e) => e.number == number).firstOrNull;
        if (!_ref.mounted ||
            !controller.isAccountContextCurrent(version) ||
            official == null ||
            official.id <= 0) {
          return false;
        }
        if (official.id != episode.id) {
          return _sendOnce(
            (subject.id, official.id),
            () => _repository.markEpisodeWatched(
              subjectId: subject.id,
              episodeId: official.id,
            ),
          );
        }
      }
      return _repository.markEpisodeWatched(
        subjectId: subject.id,
        episodeId: episode.id,
      );
    });
  }

  Future<bool> _sendOnce((int, int) key, Future<bool> Function() send) async {
    if (_syncedEpisodeKeys.contains(key) || !_sending.add(key)) return false;
    try {
      if (!await send()) return false;
      _syncedEpisodeKeys.add(key);
      return true;
    } on Exception {
      // Public episode lookup may also fail while offline. Leave it retryable.
      return false;
    } finally {
      _sending.remove(key);
    }
  }
}
