import 'dart:async';

import 'package:anime/src/updates/app_update_card.dart';
import 'package:anime/src/updates/app_update_controller.dart';
import 'package:anime/src/updates/app_update_download.dart';
import 'package:anime/src/updates/app_update_host.dart';
import 'package:anime/src/updates/app_update_models.dart';
import 'package:anime/src/updates/app_update_platform.dart';
import 'package:anime/src/updates/app_update_repository.dart';
import 'package:anime/src/updates/app_update_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  testWidgets('mobile card checks downloads and opens installer only on tap', (
    tester,
  ) async {
    final f = _UiFixture();
    addTearDown(f.controller.dispose);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appUpdateControllerProvider.overrideWithValue(f.controller),
        ],
        child: const MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: AppUpdateCard())),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    expect(find.textContaining('v1.3.2'), findsOneWidget);
    expect(find.text('测试更新说明'), findsOneWidget);
    await tester.tap(find.text('下载更新'));
    await tester.pumpAndSettle();
    expect(find.text('立即安装'), findsOneWidget);
    expect(f.platform.installs, 0);
    await tester.tap(find.text('立即安装'));
    await tester.pumpAndSettle();
    expect(f.platform.installs, 1);
    expect(find.text('再次打开安装'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'permission panel returns to explicit install, not auto install',
    (tester) async {
      final f = _UiFixture();
      addTearDown(f.controller.dispose);
      f.platform.allowed = false;
      await f.controller.check();
      await f.controller.download();
      await f.controller.install();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appUpdateControllerProvider.overrideWithValue(f.controller),
          ],
          child: const MaterialApp(
            home: Scaffold(body: SingleChildScrollView(child: AppUpdateCard())),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('允许安装应用'));
      await tester.pumpAndSettle();
      expect(f.platform.permissions, 1);
      f.platform.allowed = true;
      await tester.tap(find.text('我已开启，继续'));
      await tester.pumpAndSettle();
      expect(find.text('立即安装'), findsOneWidget);
      expect(f.platform.installs, 1);
    },
  );

  testWidgets('host suppresses automatic notice throughout player route', (
    tester,
  ) async {
    final f = _UiFixture();
    addTearDown(f.controller.dispose);
    await f.controller.check();
    final router = GoRouter(
      initialLocation: '/player',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('home')),
        ),
        GoRoute(
          path: '/player',
          builder: (_, _) => const Scaffold(body: Text('playback')),
        ),
        GoRoute(
          path: '/profile/version',
          builder: (_, _) => const Scaffold(body: Text('version')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appUpdateControllerProvider.overrideWithValue(f.controller),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          builder: (_, child) => AppUpdateHost(router: router, child: child!),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('查看更新'), findsNothing);
    router.go('/');
    await tester.pumpAndSettle();
    expect(find.text('查看更新'), findsOneWidget);
    unawaited(router.push('/player'));
    await tester.pumpAndSettle();
    expect(find.text('查看更新'), findsNothing);
    router.pop();
    await tester.pumpAndSettle();
    expect(find.text('查看更新'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('dismiss_app_update')));
    await tester.pump();
    expect(find.text('查看更新'), findsNothing);
    expect(f.repository.calls, 1);
  });
}

final _release = UpdateRelease(
  version: '1.3.2',
  buildNumber: 88,
  apkUri: Uri.parse('https://example.com/app.apk'),
  sha256: 'a' * 64,
  bytes: 1024,
  notes: '测试更新说明',
);

class _UiFixture {
  _UiFixture() {
    controller = AppUpdateController(
      supported: true,
      repository: repository,
      downloader: _Downloader(),
      platform: platform,
      store: _Store(),
    );
  }
  final platform = _Platform();
  final repository = _Repository();
  late AppUpdateController controller;
}

class _Repository implements AppUpdateRepository {
  int calls = 0;
  @override
  Future<UpdateRelease?> check(UpdateCancellation cancellation) async {
    calls++;
    return _release;
  }
}

class _Downloader implements AppUpdateDownloader {
  @override
  Future<String> download(
    UpdateRelease release, {
    required String directory,
    required UpdateCancellation cancellation,
    required void Function(UpdateProgress) onProgress,
  }) async => '$directory/app.apk';
  @override
  Future<void> discard(String path, {String? directory}) async {}
}

class _Platform implements AppUpdatePlatform {
  bool allowed = true;
  int installs = 0, permissions = 0;
  @override
  Future<InstalledUpdateEnvironment> environment() async =>
      InstalledUpdateEnvironment(
        packageName: 'app.anime.anime',
        versionName: '1.3.1',
        versionCode: 87,
        sdkInt: 35,
        supportedAbis: const ['arm64-v8a'],
        canRequestInstallPackages: allowed,
      );
  @override
  Future<UpdateDownloadDirectory> downloadDirectory() async =>
      const UpdateDownloadDirectory('/private/app_updates', 1024 * 1024 * 1024);
  @override
  Future<void> verify(String path, UpdateRelease release) async {}
  @override
  Future<bool> openInstallPermission() async {
    permissions++;
    return true;
  }

  @override
  Future<bool> install(String path, UpdateRelease release) async {
    installs++;
    return allowed;
  }
}

class _Store implements AppUpdateStore {
  @override
  Future<Map<String, dynamic>> read() async => {};
  @override
  Future<void> write(Map<String, dynamic> value) async {}
}
