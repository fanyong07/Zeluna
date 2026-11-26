import 'package:anime/src/accounts/account_page.dart';
import 'package:anime/src/accounts/cloud_account_repository.dart';
import 'package:anime/src/accounts/local_account_repository.dart';
import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/sync/sync_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('guest account page offers real login and registration forms', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(_GuestAnimeController.new),
        ],
        child: const MaterialApp(home: AccountSettingsPage()),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('游客模式'), findsOneWidget);
    expect(find.text('尚未登录，当前使用独立的游客空间'), findsOneWidget);
    expect(find.text('登录'), findsWidgets);
    expect(find.text('创建新账号'), findsOneWidget);
    expect(find.text('忘记密码'), findsOneWidget);
    expect(find.textContaining('同一个邮箱可以在安卓和 Windows 上登录'), findsOneWidget);
    expect(find.textContaining('fanyong'), findsNothing);

    await tester.tap(find.text('忘记密码'));
    await tester.pumpAndSettle();
    expect(find.text('重置密码'), findsOneWidget);
    expect(find.text('确认重置'), findsOneWidget);
    expect(find.textContaining('其他设备上的登录状态会全部失效'), findsOneWidget);
  });

  testWidgets('signed-in account page shows profile and security actions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(_SignedInAnimeController.new),
        ],
        child: const MaterialApp(home: AccountSettingsPage()),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('星野'), findsWidgets);
    expect(find.textContaining('user@example.com'), findsWidgets);
    expect(find.text('个人资料'), findsOneWidget);
    expect(find.text('登录与安全'), findsOneWidget);
    expect(find.text('修改密码'), findsOneWidget);
    expect(find.text('切换账号'), findsOneWidget);
    expect(find.text('导出我的账号数据'), findsOneWidget);
    expect(find.text('退出登录'), findsOneWidget);
    expect(find.text('清除此设备的账号数据'), findsOneWidget);
    expect(find.text('永久删除云端账号'), findsOneWidget);
    expect(find.text('离线，3 项待同步'), findsWidgets);

    await tester.ensureVisible(find.text('永久删除云端账号'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('永久删除云端账号'));
    await tester.pumpAndSettle();
    expect(find.text('永久删除云端账号？'), findsOneWidget);
    expect(find.text('进入 7 天冷静期'), findsOneWidget);
    expect(find.textContaining('帖子、评论、弹幕及其图片会匿名保留'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('清除此设备的账号数据'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清除此设备的账号数据'));
    await tester.pumpAndSettle();
    expect(find.text('清除此设备的账号数据？'), findsOneWidget);
    expect(find.text('确认清除'), findsOneWidget);
    expect(find.text('输入当前密码确认'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('清除此设备的账号数据？'), findsNothing);

    await tester.tap(find.text('清除此设备的账号数据'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'wrong-password');
    await tester.tap(find.text('确认清除'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('密码不正确，数据没有清除'), findsOneWidget);
    expect(find.text('密码不正确，数据没有清除').hitTestable(), findsOneWidget);
  });

  testWidgets('pending account cleanup is visible and retryable', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(_CleanupAnimeController.new),
        ],
        child: const MaterialApp(home: AccountSettingsPage()),
      ),
    );
    await tester.pump();

    expect(find.text('有账号文件尚未清理完成'), findsOneWidget);
    expect(find.textContaining('不会阻止你使用或创建其他账号'), findsOneWidget);
    expect(find.text('重新清理'), findsOneWidget);
  });

  testWidgets('frozen login can cancel deletion and restore the account', (
    tester,
  ) async {
    final controller = _PendingDeletionAnimeController();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [animeControllerProvider.overrideWith(() => controller)],
        child: const MaterialApp(home: AccountSettingsPage()),
      ),
    );
    await tester.pump();

    final email = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.labelText == '邮箱',
    );
    final password = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.labelText == '密码',
    );
    await tester.enterText(email, 'user@example.com');
    await tester.enterText(password, 'password-123');
    await tester.tap(find.widgetWithText(FilledButton, '登录'));
    await tester.pumpAndSettle();

    expect(find.text('账号正在删除冷静期'), findsOneWidget);
    expect(find.text('撤销删除并登录'), findsOneWidget);
    await tester.tap(find.text('撤销删除并登录'));
    await tester.pumpAndSettle();

    expect(controller.cancelCalls, 1);
    expect(find.text('账号删除已撤销，登录已恢复'), findsOneWidget);
    expect(find.text('星野'), findsWidgets);
  });

  testWidgets('permanent deletion request enters the seven day grace period', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = _DeletionRequestAnimeController();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [animeControllerProvider.overrideWith(() => controller)],
        child: const MaterialApp(home: AccountSettingsPage()),
      ),
    );
    await tester.pump();

    await tester.ensureVisible(find.text('永久删除云端账号'));
    await tester.tap(find.text('永久删除云端账号'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'password-123');
    await tester.tap(find.text('进入 7 天冷静期'));
    await tester.pumpAndSettle();

    expect(controller.requestCalls, 1);
    expect(find.textContaining('删除申请已提交'), findsOneWidget);
    expect(find.textContaining('截止前可登录撤销'), findsOneWidget);
  });
}

class _GuestAnimeController extends AnimeController {
  @override
  Future<AnimeState> build() async => const AnimeState(homeFeed: _feed);
}

class _SignedInAnimeController extends AnimeController {
  @override
  Future<AnimeState> build() async => AnimeState(
    homeFeed: _feed,
    profile: const UserProfileSettings(nickname: '星野', uid: 'ACCOUNT123'),
    accountSession: LocalAccountSession(
      current: _account,
      available: [_account],
    ),
    syncStatus: const SyncStatus(phase: SyncPhase.offline, pendingMutations: 3),
  );

  @override
  Future<void> deleteCurrentAccount({required String password}) async {
    throw const AccountException('密码不正确，数据没有清除');
  }
}

class _CleanupAnimeController extends AnimeController {
  @override
  Future<AnimeState> build() async => const AnimeState(
    homeFeed: _feed,
    accountSession: LocalAccountSession(hasPendingCleanup: true),
  );
}

class _PendingDeletionAnimeController extends AnimeController {
  int cancelCalls = 0;

  @override
  Future<AnimeState> build() async => const AnimeState(homeFeed: _feed);

  @override
  Future<void> loginAccount({
    required String email,
    required String password,
  }) async {
    throw AccountDeletionPendingException(
      message: '账号处于删除冷静期，可在截止前撤销',
      dueAt: DateTime.utc(2026, 8, 9, 12),
      canCancel: true,
    );
  }

  @override
  Future<void> cancelCloudAccountDeletionAndLogin({
    required String email,
    required String password,
  }) async {
    cancelCalls++;
    state = AsyncData(
      AnimeState(
        homeFeed: _feed,
        profile: const UserProfileSettings(nickname: '星野', uid: 'ACCOUNT123'),
        accountSession: LocalAccountSession(
          current: _account,
          available: [_account],
        ),
      ),
    );
  }
}

class _DeletionRequestAnimeController extends _SignedInAnimeController {
  int requestCalls = 0;

  @override
  Future<AccountDeletionSchedule> requestCloudAccountDeletion({
    required String password,
  }) async {
    requestCalls++;
    state = AsyncData(
      AnimeState(
        homeFeed: _feed,
        accountSession: LocalAccountSession(available: [_account]),
      ),
    );
    final requestedAt = DateTime.utc(2026, 8, 2, 12);
    return AccountDeletionSchedule(
      requestedAt: requestedAt,
      dueAt: requestedAt.add(const Duration(days: 7)),
    );
  }
}

final _now = DateTime.utc(2026, 7, 19);
final _account = LocalAccount(
  id: 'account1234567890',
  email: 'user@example.com',
  nickname: '星野',
  createdAt: _now,
  lastLoginAt: _now,
  cloudAuthenticated: true,
);

const _subject = AnimeSubject(
  id: 1,
  title: '测试番剧',
  originalTitle: 'Test Anime',
  summary: '测试账号页面所需的首页数据。',
  coverUrl: null,
  bannerUrl: null,
  date: '2026-01-01',
  platform: 'TV',
  language: '中文',
  region: '中国',
  status: '连载',
  categories: [],
  tags: [],
  totalEpisodes: 12,
);

const _feed = AnimeHomeFeed(
  hero: _subject,
  recent: [_subject],
  recommended: [_subject],
  index: [_subject],
  categories: [],
  tags: [],
);
