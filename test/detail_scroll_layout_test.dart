import 'package:anime/src/catalog/catalog_page.dart';
import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'detail scrolls the hero away before continuing through episodes',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await _pumpDetail(tester);

      final unifiedScroll = find.byKey(const ValueKey('detailUnifiedScroll'));
      final hero = find.byKey(const ValueKey('detailHero'));
      expect(unifiedScroll, findsOneWidget);
      expect(hero, findsOneWidget);

      await tester.tap(find.text('选集'));
      await tester.pumpAndSettle();

      final episodeGrid = find.byKey(const ValueKey('detailEpisodeGrid'));
      final episodeScrollable = find.descendant(
        of: episodeGrid,
        matching: find.byType(Scrollable),
      );
      expect(episodeGrid, findsOneWidget);
      expect(episodeScrollable, findsOneWidget);

      await tester.drag(unifiedScroll, const Offset(0, -500));
      await tester.pumpAndSettle();

      expect(hero, findsNothing, reason: '向下浏览时封面与大横幅应离开并回收');
      expect(find.text('选集').hitTestable(), findsOneWidget);

      final firstInnerOffset = tester
          .state<ScrollableState>(episodeScrollable)
          .position
          .pixels;
      await tester.drag(unifiedScroll, const Offset(0, -320));
      await tester.pumpAndSettle();
      final secondInnerOffset = tester
          .state<ScrollableState>(episodeScrollable)
          .position
          .pixels;

      expect(
        secondInnerOffset,
        greaterThan(firstInnerOffset + 100),
        reason: '头部收起后选集列表仍应继续滚动',
      );
    },
  );

  testWidgets('detail unified scroll stays overflow-free on mobile', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpDetail(tester);

    expect(tester.takeException(), isNull);
    final unifiedScroll = find.byKey(const ValueKey('detailUnifiedScroll'));
    final hero = find.byKey(const ValueKey('detailHero'));
    await tester.drag(unifiedScroll, const Offset(0, -520));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(hero, findsNothing);
  });
}

Future<void> _pumpDetail(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        animeControllerProvider.overrideWith(_DetailAnimeController.new),
      ],
      child: const MaterialApp(home: DetailPage(subject: _subject)),
    ),
  );
  await tester.pumpAndSettle();
}

class _DetailAnimeController extends AnimeController {
  @override
  Future<AnimeState> build() async => const AnimeState(homeFeed: _feed);

  @override
  Future<AnimeDetailBundle> detail(AnimeSubject subject) async {
    return AnimeDetailBundle(
      subject: subject,
      episodes: [
        for (var i = 1; i <= 80; i++)
          AnimeEpisode(
            id: subject.id * 1000 + i,
            subjectId: subject.id,
            number: i,
            title: '',
            airdate: '2022-10-${((i - 1) % 28 + 1).toString().padLeft(2, '0')}',
            duration: '24:00',
            description: '',
            thumbnailUrl: null,
          ),
      ],
      characters: const [],
      staff: const [],
      recommendations: const [],
    );
  }
}

const _subject = AnimeSubject(
  id: 1,
  title: '孤独摇滚！',
  originalTitle: 'ぼっち・ざ・ろっく！',
  summary: '怕生少女加入乐队的故事。',
  coverUrl: null,
  bannerUrl: null,
  date: '2022-10-08',
  platform: 'TV',
  language: '日语',
  region: '日本',
  status: '全12集',
  categories: [AnimeCategory(name: '动画')],
  tags: [AnimeTag(name: '音乐', count: 100)],
  totalEpisodes: 80,
);

const _feed = AnimeHomeFeed(
  hero: _subject,
  recent: [_subject],
  recommended: [_subject],
  index: [_subject],
  categories: [AnimeCategory(name: '动画')],
  tags: [AnimeTag(name: '音乐')],
);
