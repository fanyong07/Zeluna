import 'dart:async';

import 'package:anime/src/app/app_theme.dart';
import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/profile/profile_page.dart';
import 'package:anime/src/updates/app_update_card.dart';
import 'package:anime/src/updates/app_update_controller.dart';
import 'package:anime/src/updates/app_update_download.dart';
import 'package:anime/src/updates/app_update_models.dart';
import 'package:anime/src/updates/app_update_platform.dart';
import 'package:anime/src/updates/app_update_repository.dart';
import 'package:anime/src/updates/app_update_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  for (final viewport in const {
    'mobile': Size(390, 844),
    'desktop': Size(1280, 900),
  }.entries) {
    testWidgets(
      '${viewport.key} profile shortcut opens updates and returns to profile',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = viewport.value;
        addTearDown(tester.view.reset);
        PackageInfo.setMockInitialValues(
          appName: 'Zeluna',
          packageName: appUpdatePackageName,
          version: '1.3.1',
          buildNumber: '87',
          buildSignature: '',
        );

        final repository = _UpdateRepository();
        // Both sizes exercise layout with a supported update environment;
        // desktop width does not imply native Windows APK update support.
        final updates = AppUpdateController(
          supported: true,
          repository: repository,
          downloader: _UnexpectedDownloader(),
          platform: _UpdatePlatform(),
          store: _MemoryUpdateStore(),
          now: () => DateTime.utc(2026, 1, 1),
        );
        addTearDown(updates.dispose);
        final router = GoRouter(
          initialLocation: '/profile',
          routes: [
            GoRoute(path: '/profile', builder: (_, _) => const ProfilePage()),
            GoRoute(
              path: '/profile/version',
              builder: (_, _) => const VersionInfoPage(),
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              animeControllerProvider.overrideWith(_ProfileController.new),
              appUpdateControllerProvider.overrideWithValue(updates),
            ],
            child: MaterialApp.router(
              theme: AnimeTheme.dark(),
              routerConfig: router,
            ),
          ),
        );
        await tester.pumpAndSettle();

        final profile = find.byType(ProfilePage);
        expect(profile, findsOneWidget);
        expect(find.text('个人中心'), findsOneWidget);
        expect(find.byType(VersionInfoPage), findsNothing);
        expect(repository.calls, 0);
        expect(router.canPop(), isFalse);
        final originalProfile = tester.element(profile);
        final profileList = find
            .descendant(of: profile, matching: find.byType(ListView))
            .first;
        // Target the page list, not the nested non-scrollable shortcuts grid.
        final profileScrollable = find
            .descendant(of: profileList, matching: find.byType(Scrollable))
            .first;
        final profileScrollState = tester.state<ScrollableState>(
          profileScrollable,
        );
        final shortcut = find.descendant(
          of: profile,
          matching: find.text('版本信息'),
        );
        await tester.drag(profileList, const Offset(0, -180));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          shortcut.hitTestable(),
          120,
          scrollable: profileScrollable,
        );
        await tester.pumpAndSettle();
        expect(shortcut.hitTestable(), findsOneWidget);
        expect(
          find
              .descendant(of: profile, matching: find.text('应用更新'))
              .hitTestable(),
          findsOneWidget,
        );
        final originalScrollOffset = profileScrollState.position.pixels;
        expect(originalScrollOffset, greaterThan(0));
        expect(tester.takeException(), isNull);

        // Enter through the real tile, never by pushing the route in the test.
        await tester.tap(shortcut);
        await tester.pumpAndSettle();
        final versionPage = find.byType(VersionInfoPage);
        expect(versionPage, findsOneWidget);
        expect(profile, findsNothing);
        expect(
          GoRouterState.of(tester.element(versionPage)).uri.path,
          '/profile/version',
        );
        expect(router.canPop(), isTrue);
        expect(find.text('版本信息'), findsOneWidget);
        expect(find.text('v1.3.1'), findsOneWidget);
        final updateCard = find.descendant(
          of: versionPage,
          matching: find.byType(AppUpdateCard),
        );
        expect(updateCard, findsOneWidget);
        expect(repository.calls, 0);
        expect(updates.phase, AppUpdatePhase.idle);

        final checkButton = find.descendant(
          of: updateCard,
          matching: find.widgetWithText(OutlinedButton, '检查更新'),
        );
        await tester.ensureVisible(checkButton);
        await tester.pumpAndSettle();
        expect(checkButton.hitTestable(), findsOneWidget);
        expect(tester.widget<OutlinedButton>(checkButton).onPressed, isNotNull);
        await tester.tap(checkButton);
        await tester.pump();
        expect(repository.calls, 1);
        expect(updates.phase, AppUpdatePhase.checking);
        expect(find.text('正在检查更新…'), findsOneWidget);

        repository.result.complete(_release);
        await tester.pumpAndSettle();
        expect(updates.phase, AppUpdatePhase.available);
        expect(find.text('发现新版本'), findsOneWidget);
        expect(find.textContaining('v1.3.2'), findsOneWidget);
        expect(find.text(_release.notes), findsOneWidget);
        final downloadButton = find.descendant(
          of: updateCard,
          matching: find.widgetWithText(FilledButton, '下载更新'),
        );
        await tester.ensureVisible(downloadButton);
        await tester.pumpAndSettle();
        expect(downloadButton.hitTestable(), findsOneWidget);
        expect(
          tester.widget<FilledButton>(downloadButton).onPressed,
          isNotNull,
        );
        expect(tester.takeException(), isNull);

        // Exercise the actual version-page back action and retained page state.
        await tester.tap(
          find.descendant(
            of: versionPage,
            matching: find.widgetWithIcon(IconButton, Icons.arrow_back),
          ),
        );
        await tester.pumpAndSettle();
        expect(profile, findsOneWidget);
        expect(find.text('个人中心'), findsOneWidget);
        expect(find.byType(VersionInfoPage), findsNothing);
        expect(find.byType(AppUpdateCard), findsNothing);
        expect(GoRouterState.of(tester.element(profile)).uri.path, '/profile');
        expect(router.canPop(), isFalse);
        expect(tester.element(profile), same(originalProfile));
        expect(
          tester.state<ScrollableState>(profileScrollable),
          same(profileScrollState),
        );
        expect(
          profileScrollState.position.pixels,
          closeTo(originalScrollOffset, 0.01),
        );
        expect(shortcut.hitTestable(), findsOneWidget);
        expect(repository.calls, 1);
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }
}

class _ProfileController extends AnimeController {
  @override
  Future<AnimeState> build() async => const AnimeState(homeFeed: _feed);
}

// Null artwork keeps the real profile widgets independent of image networking.
const _subject = AnimeSubject(
  id: 1,
  title: '导航回归测试',
  originalTitle: 'Profile navigation fixture',
  summary: '个人中心与版本页导航测试。',
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

final _release = UpdateRelease(
  version: '1.3.2',
  buildNumber: 88,
  apkUri: Uri.parse('https://example.com/zeluna-test.apk'),
  sha256: 'a' * 64,
  bytes: 1024 * 1024,
  notes: '导航回归测试更新说明',
);

class _UpdateRepository implements AppUpdateRepository {
  final result = Completer<UpdateRelease?>();
  int calls = 0;

  @override
  Future<UpdateRelease?> check(UpdateCancellation cancellation) {
    calls++;
    return result.future;
  }
}

class _UnexpectedDownloader implements AppUpdateDownloader {
  @override
  Future<String> download(
    UpdateRelease release, {
    required String directory,
    required UpdateCancellation cancellation,
    required void Function(UpdateProgress) onProgress,
  }) async => throw StateError('Navigation must not download an update');

  @override
  Future<void> discard(String path, {String? directory}) async =>
      throw StateError('Navigation must not discard an update');
}

class _UpdatePlatform implements AppUpdatePlatform {
  @override
  Future<InstalledUpdateEnvironment> environment() async =>
      const InstalledUpdateEnvironment(
        packageName: appUpdatePackageName,
        versionName: '1.3.1',
        versionCode: 87,
        sdkInt: 35,
        supportedAbis: ['arm64-v8a'],
        canRequestInstallPackages: true,
      );

  @override
  Future<UpdateDownloadDirectory> downloadDirectory() async =>
      throw StateError('Navigation must not allocate download storage');

  @override
  Future<void> verify(String path, UpdateRelease release) async =>
      throw StateError('Navigation must not verify an installer');

  @override
  Future<bool> openInstallPermission() async =>
      throw StateError('Navigation must not open install settings');

  @override
  Future<bool> install(String path, UpdateRelease release) async =>
      throw StateError('Navigation must not launch an installer');
}

class _MemoryUpdateStore implements AppUpdateStore {
  Map<String, dynamic> _value = {};

  @override
  Future<Map<String, dynamic>> read() async => Map.of(_value);

  @override
  Future<void> write(Map<String, dynamic> value) async {
    _value = Map.of(value);
  }
}
