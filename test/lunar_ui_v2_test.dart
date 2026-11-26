import 'package:anime/src/app/anime_app.dart';
import 'package:anime/src/app/app_theme.dart';
import 'package:anime/src/catalog/catalog_page.dart';
import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/profile/profile_page.dart';
import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/rules/rule_plugin_page.dart';
import 'package:anime/src/shared_ui/app_chrome.dart';
import 'package:anime/src/sources/media_library_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'mobile profile exposes private media library, system settings, and extension sources',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            animeControllerProvider.overrideWith(_UiV2Controller.new),
          ],
          child: MaterialApp(
            theme: AnimeTheme.dark(),
            home: const ProfilePage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('片源与媒体库'), findsOneWidget);
      expect(find.text('扩展来源'), findsOneWidget);
      expect(find.text('私有媒体库'), findsOneWidget);
      expect(find.byTooltip('系统设置'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'extension sources page hides internal bundled community subscriptions from users',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            animeControllerProvider.overrideWith(_UiV2Controller.new),
          ],
          child: MaterialApp(
            theme: AnimeTheme.dark(),
            home: const RuleManagementPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('扩展播放来源'), findsOneWidget);
      expect(find.text('开源社区订阅'), findsNothing);
      expect(find.text('LunaTV 影视/剧集/番剧（全年龄）'), findsNothing);
      expect(find.text('Kazumi 官方番剧规则'), findsNothing);
      expect(find.text('Animeko 社区聚合番剧'), findsNothing);
      expect(find.text('Creamycake Animeko 番剧'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('private media library page integrates with AppChrome', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    FlutterSecureStorage.setMockInitialValues({});

    await tester.pumpWidget(
      ProviderScope(
        overrides: [animeControllerProvider.overrideWith(_UiV2Controller.new)],
        child: MaterialApp(
          theme: AnimeTheme.dark(),
          home: const MediaLibraryPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AppChrome), findsOneWidget);
    expect(find.text('私有媒体库'), findsOneWidget);
    expect(find.text('Emby 302 直连'), findsOneWidget);
    expect(find.text('Alist / WebDAV'), findsOneWidget);
    expect(find.text('添加媒体库'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('home displays continue watching strip when history exists', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [animeControllerProvider.overrideWith(_UiV2Controller.new)],
        child: const AnimeApp(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    final list = find.byType(CustomScrollView).first;
    await tester.drag(list, const Offset(0, -420));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(SectionTitle, '继续观看'), findsOneWidget);
    expect(find.byType(CatalogPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _UiV2Controller extends AnimeController {
  @override
  Future<AnimeState> build() async => AnimeState(
    homeFeed: const AnimeHomeFeed(
      hero: _subject,
      recent: [_subject],
      recommended: [_subject],
      index: [_subject],
      categories: [],
      tags: [],
    ),
    history: [
      LibraryEntry(
        subject: _subject,
        updatedAt: DateTime(2026, 11, 21),
        note: '第 1 集 · 12:00',
        positionSeconds: 720,
        durationSeconds: 1440,
      ),
    ],
    rulePlugins: RulePluginState(
      repositories: [
        RuleRepositoryRecord(
          id: 'repo-lunatv',
          name: 'LunaTV',
          url:
              'https://raw.githubusercontent.com/hafrey1/LunaTV-config/main/jin18.json',
          ruleCount: 28,
          importedAt: DateTime(2026, 11, 21),
          autoRefresh: true,
        ),
      ],
    ),
  );
}

const _subject = AnimeSubject(
  id: 400602,
  title: '葬送的芙莉莲',
  originalTitle: '葬送のフリーレン',
  summary: '打倒魔王之后的奇幻旅途。',
  coverUrl: null,
  bannerUrl: null,
  date: '2023-09-29',
  platform: 'TV',
  language: '日语',
  region: '日本',
  status: '已完结',
  categories: [AnimeCategory(name: '奇幻')],
  tags: [],
  totalEpisodes: 28,
  ratingScore: 8.9,
  ratingTotal: 52000,
);
