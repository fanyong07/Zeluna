import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../accounts/account_page.dart';
import '../catalog/catalog_page.dart';
import '../data/anime_controller.dart';
import '../domain/anime_models.dart';
import '../player/player_page.dart';
import '../player/open_media_page.dart';
import '../profile/profile_page.dart';
import '../rules/rule_plugin_page.dart';
import '../settings/settings_page.dart';
import '../shared_ui/app_chrome.dart';
import 'app_theme.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final routes = <RouteBase>[
    GoRoute(path: '/', builder: (context, state) => const CatalogPage()),
    GoRoute(
      path: '/anime',
      builder: (context, state) =>
          const MetadataHubPage(kind: MetadataHubKind.anime),
    ),
    GoRoute(path: '/discover', redirect: (context, state) => '/anime'),
    GoRoute(
      path: '/series',
      builder: (context, state) =>
          const MetadataHubPage(kind: MetadataHubKind.series),
    ),
    GoRoute(
      path: '/movies',
      builder: (context, state) =>
          const MetadataHubPage(kind: MetadataHubKind.movie),
    ),
    GoRoute(
      path: '/schedule',
      builder: (context, state) => const SchedulePage(),
    ),
    GoRoute(path: '/profile', builder: (context, state) => const ProfilePage()),
    GoRoute(path: '/history', builder: (context, state) => const HistoryPage()),
    GoRoute(path: '/profile/history', redirect: (context, state) => '/history'),
    GoRoute(
      path: '/profile/offline',
      builder: (context, state) => const DownloadManagementPage(),
    ),
    GoRoute(
      path: '/profile/following',
      builder: (context, state) => LibraryPage(
        title: '追番列表',
        emptyTitle: '还没有追番',
        emptyMessage: '在详情页点“追番”后会加入这里，也可以从“我的”页进入。',
        entriesOf: (state) => state.following,
        active: ChromeDestination.favorite,
      ),
    ),
    GoRoute(
      path: '/profile/favorites',
      builder: (context, state) => LibraryPage(
        title: '全部收藏',
        emptyTitle: '还没有收藏',
        emptyMessage: '在详情页点击收藏后会显示在这里。',
        entriesOf: (state) => state.favorites,
        active: ChromeDestination.favorite,
      ),
    ),
    GoRoute(
      path: '/profile/images',
      builder: (context, state) => LibraryPage(
        title: '图片收藏',
        emptyTitle: '还没有图片收藏',
        emptyMessage: '收藏封面图后会出现在这里，暂不保留单独画廊入口。',
        entriesOf: (state) => state.imageFavorites,
        clearKey: 'imageFavorites',
      ),
    ),
    GoRoute(
      path: '/profile/account',
      builder: (context, state) => const AccountSettingsPage(),
    ),
    GoRoute(
      path: '/profile/home-settings',
      builder: (context, state) => const HomeSettingsPage(),
    ),
    GoRoute(
      path: '/profile/appearance',
      builder: (context, state) => const AppearanceSettingsPage(),
    ),
    GoRoute(
      path: '/profile/danmaku',
      builder: (context, state) => const DanmakuSettingsPage(),
    ),
    GoRoute(
      path: '/profile/misc',
      builder: (context, state) => const MiscSettingsPage(),
    ),
    GoRoute(
      path: '/profile/version',
      builder: (context, state) => const VersionInfoPage(),
    ),
    GoRoute(
      path: '/profile/feedback',
      builder: (context, state) {
        final subject = state.extra;
        return FeedbackPage(subject: subject is AnimeSubject ? subject : null);
      },
    ),
    GoRoute(
      path: '/profile/rules',
      builder: (context, state) => const RuleManagementPage(),
    ),
    GoRoute(
      path: '/profile/rules/repository',
      builder: (context, state) => const RuleRepositoryPage(),
    ),
    GoRoute(
      path: '/settings',
      builder: (context, state) => const SettingsHubPage(),
    ),
    GoRoute(
      path: '/settings/playback',
      builder: (context, state) => const SettingsPage(),
    ),
    GoRoute(
      path: '/player',
      builder: (context, state) {
        final request = state.extra;
        if (request is PlaySessionRequest) {
          return PlayerPage(request: request);
        }
        return const MissingPlayerPage();
      },
    ),
    GoRoute(
      path: '/player/open',
      builder: (context, state) => const OpenMediaPage(),
    ),
  ];
  routes.add(
    GoRoute(
      path: '/settings/services/:kind',
      redirect: (context, state) {
        final kind = state.pathParameters['kind'];
        return kind == 'media' || kind == 'anime' ? '/settings' : null;
      },
      builder: (context, state) =>
          ServiceSettingsPage(kind: state.pathParameters['kind'] ?? ''),
    ),
  );
  return GoRouter(routes: routes);
});

class AnimeApp extends ConsumerWidget {
  const AnimeApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    final appearance =
        ref.watch(
          animeControllerProvider.select((state) => state.value?.appearance),
        ) ??
        const AppearanceSettings();
    return MaterialApp.router(
      title: 'Zeluna',
      debugShowCheckedModeBanner: false,
      theme: AnimeTheme.light(
        compact: appearance.compactMode,
        reduceMotion: appearance.reduceMotion,
      ),
      darkTheme: AnimeTheme.dark(
        compact: appearance.compactMode,
        reduceMotion: appearance.reduceMotion,
      ),
      themeMode: appearance.followSystem
          ? ThemeMode.system
          : appearance.darkMode
          ? ThemeMode.dark
          : ThemeMode.light,
      routerConfig: router,
    );
  }
}

class AsyncAnimeGate extends ConsumerWidget {
  const AsyncAnimeGate({super.key, required this.builder});

  final Widget Function(BuildContext context, AnimeState state) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(animeControllerProvider);
    return async.when(
      data: (state) => _RestoreStartupSystemUi(child: builder(context, state)),
      loading: () => const ZelunaStartupView(),
      error: (error, stackTrace) => Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: const Text('内容暂时加载失败，请稍后重试。', textAlign: TextAlign.center),
          ),
        ),
      ),
    );
  }
}

bool _startupSystemUiRestored = false;

class _RestoreStartupSystemUi extends StatefulWidget {
  const _RestoreStartupSystemUi({required this.child});

  final Widget child;

  @override
  State<_RestoreStartupSystemUi> createState() =>
      _RestoreStartupSystemUiState();
}

class _RestoreStartupSystemUiState extends State<_RestoreStartupSystemUi> {
  @override
  void initState() {
    super.initState();
    if (_startupSystemUiRestored) return;
    _startupSystemUiRestored = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (kIsWeb ||
          (defaultTargetPlatform != TargetPlatform.android &&
              defaultTargetPlatform != TargetPlatform.iOS)) {
        return;
      }
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class ZelunaStartupView extends StatelessWidget {
  const ZelunaStartupView({super.key});

  static const assetPath = 'assets/brand/splash/zeluna_android_splash.png';

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Color(0xFF14181D),
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: Color(0xFF14181D),
        systemNavigationBarIconBrightness: Brightness.light,
        systemNavigationBarContrastEnforced: false,
      ),
      child: Scaffold(
        backgroundColor: const Color(0xFF14181D),
        body: Semantics(
          label: 'Zeluna 正在启动',
          image: true,
          child: const SizedBox.expand(
            child: Image(
              key: ValueKey<String>('zeluna-startup-image'),
              image: AssetImage(assetPath),
              fit: BoxFit.cover,
              alignment: Alignment.center,
              filterQuality: FilterQuality.high,
              gaplessPlayback: true,
            ),
          ),
        ),
      ),
    );
  }
}
