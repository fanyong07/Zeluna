import '../accounts/cloud_account_repository.dart';
import '../accounts/local_account_repository.dart';
import '../domain/anime_models.dart';
import 'danmaku_repository.dart';

/// Keeps authenticated danmaku mutations and account-switch safety outside
/// the application-wide orchestration controller.
final class DanmakuCloudController {
  const DanmakuCloudController({
    required CloudDanmakuService service,
    required DanmakuRepository repository,
    required LocalAccount? Function() activeAccount,
    required int Function() contextVersion,
    required void Function(int version) ensureContext,
  }) : _service = service,
       _repository = repository,
       _activeAccount = activeAccount,
       _contextVersion = contextVersion,
       _ensureContext = ensureContext;

  final CloudDanmakuService _service;
  final DanmakuRepository _repository;
  final LocalAccount? Function() _activeAccount;
  final int Function() _contextVersion;
  final void Function(int version) _ensureContext;

  Future<DanmakuComment> publish({
    required AnimeSubject subject,
    required AnimeEpisode episode,
    required Duration position,
    required String text,
  }) async {
    final account = _activeAccount();
    if (account == null || !account.cloudAuthenticated) {
      throw const AccountException('登录后才能发送弹幕');
    }
    final version = _contextVersion();
    final comment = await _service.createDanmaku(
      subjectKey: subject.identityKey,
      episodeKey: episode.identityKey(subjectKey: subject.identityKey),
      time: position,
      mode: DanmakuMode.scroll,
      color: 0xFFFFFF,
      text: text,
    );
    _ensureContext(version);
    _repository.invalidate();
    return comment;
  }

  Future<void> delete(DanmakuComment comment) async {
    if (!comment.isMine || comment.provider != 'Zeluna') {
      throw const AccountException('只能删除自己发送的弹幕');
    }
    final account = _activeAccount();
    if (account == null || !account.cloudAuthenticated) {
      throw const AccountException('登录状态已失效，请重新登录');
    }
    final version = _contextVersion();
    await _service.deleteDanmaku(comment.id);
    _ensureContext(version);
    _repository.invalidate();
  }
}
