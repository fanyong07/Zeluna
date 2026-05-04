import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../catalog/catalog_page.dart';
import '../data/anime_controller.dart';
import '../domain/anime_models.dart';
import '../player/player_page.dart';
import '../profile/profile_page.dart';
import '../rules/rule_plugin_page.dart';
import '../settings/settings_page.dart';
import 'app_theme.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final routes = <RouteBase>[
    GoRoute(path: '/', builder: (context, state) => const CatalogPage()),
    GoRoute(
      path: '/discover',
      builder: (context, state) =>
          const MetadataHubPage(kind: MetadataHubKind.discover),
    ),
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
    GoRoute(
      path: '/profile/history',
      builder: (context, state) => LibraryPage(
        title: '观看记录',
        emptyTitle: '还没有观看记录',
        emptyMessage: '从详情页播放任意一集后，这里会记录番剧和集数。',
        entriesOf: (state) => state.history,
        clearKey: 'history',
      ),
    ),
    GoRoute(
      path: '/profile/offline',
      builder: (context, state) => LibraryPage(
        title: '离线缓存',
        emptyTitle: '还没有缓存任务',
        emptyMessage: '在详情页点下载后会加入队列，视频源接入后再执行真实缓存。',
        entriesOf: (state) => state.offlineTasks,
        clearKey: 'offlineTasks',
      ),
    ),
    GoRoute(
      path: '/profile/following',
      builder: (context, state) => LibraryPage(
        title: '追番列表',
        emptyTitle: '还没有追番',
        emptyMessage: '后续详情页可加入追番，这里会按本地列表展示。',
        entriesOf: (state) => state.following,
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
  ];
  assert(() {
    routes.add(
      GoRoute(
        path: '/settings/services/:kind',
        builder: (context, state) =>
            ServiceSettingsPage(kind: state.pathParameters['kind'] ?? ''),
      ),
    );
    return true;
  }());
  return GoRouter(routes: routes);
});

class AnimeApp extends ConsumerWidget {
  const AnimeApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'anime',
      debugShowCheckedModeBanner: false,
      theme: AnimeTheme.dark(),
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
      data: (state) => builder(context, state),
      loading: () => const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (error, stackTrace) => Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Text(
              'Bangumi 数据暂时加载失败，稍后可重试。\n$error',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}
