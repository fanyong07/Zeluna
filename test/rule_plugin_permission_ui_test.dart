import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/rules/rule_plugin_page.dart';
import 'package:anime/src/rules/rule_security.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('untrusted rule shows its complete permissions before enabling', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(
            _PermissionUiAnimeController.new,
          ),
        ],
        child: const MaterialApp(home: RuleManagementPage()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('展开番剧规则'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('ruleToggle:custom:permission-ui')),
    );
    await tester.pumpAndSettle();

    expect(find.text('确认规则权限'), findsOneWidget);
    expect(find.text('批准并启用'), findsOneWidget);
    expect(find.text('未信任'), findsWidgets);
    expect(find.text('page.example.com'), findsOneWidget);
    expect(find.text('media.example.net'), findsOneWidget);
    expect(find.text('仅当前任务'), findsOneWidget);
    expect(find.text('Referer、User-Agent'), findsOneWidget);
    expect(find.textContaining('规则更新后会再问你一次'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('确认规则权限'), findsNothing);
  });
}

class _PermissionUiAnimeController extends AnimeController {
  @override
  Future<AnimeState> build() async => AnimeState(
    homeFeed: const AnimeHomeFeed(
      hero: _subject,
      recent: [],
      recommended: [],
      index: [],
      categories: [],
      tags: [],
    ),
    rulePlugins: RulePluginState(
      installedIds: {_rule.id},
      customRules: [_rule],
    ),
  );
}

final _rule = RulePlugin(
  id: 'custom:permission-ui',
  name: '权限测试规则',
  version: '2.0',
  source: RuleSourceKind.custom,
  contentType: RuleContentType.anime,
  engine: 'native',
  updatedAt: DateTime.utc(2026, 8, 1),
  qualityScore: 80,
  tags: ['test'],
  baseUrl: 'https://page.example.com/',
  searchUrl: 'https://page.example.com/search?wd=@keyword',
  searchable: true,
  quickSearch: true,
  filterable: false,
  kazumi: KazumiParserConfig(
    searchList: '//article',
    searchName: '//h2',
    searchResult: '//a',
    chapterRoads: '//ul',
    chapterResult: '//li/a',
  ),
  permissionManifest: const RulePermissionManifest(
    id: 'custom:permission-ui',
    name: '权限测试规则',
    version: '2.0',
    engine: 'native',
    contentTypes: ['anime'],
    sourceRepository: 'https://rules.example.org/index.json',
    contentHash: '',
    signature: '',
    trustLevel: RuleTrustLevel.untrusted,
    pageDomains: ['page.example.com'],
    mediaDomains: ['media.example.net'],
    javascript: true,
    webViewSniffing: true,
    cookiePolicy: RuleCookiePolicy.taskScoped,
    cleartextHttp: false,
    customReferer: true,
    customOrigin: false,
    customUserAgent: true,
    minimumCoreVersion: '1.0.0',
  ),
);

const _subject = AnimeSubject(
  id: 1,
  title: '测试',
  originalTitle: 'Test',
  summary: '',
  coverUrl: null,
  bannerUrl: null,
  date: null,
  platform: '',
  language: '',
  region: '',
  status: '',
  categories: [],
  tags: [],
  totalEpisodes: 1,
);
