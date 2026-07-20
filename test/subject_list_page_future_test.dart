import 'dart:async';

import 'package:anime/src/catalog/catalog_page.dart';
import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'subject list reuses its request until page inputs really change',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      var firstLoaderRequests = 0;
      var secondLoaderRequests = 0;
      Future<List<AnimeSubject>> firstLoader(WidgetRef ref) async {
        firstLoaderRequests++;
        return const [_subject];
      }

      Future<List<AnimeSubject>> secondLoader(WidgetRef ref) async {
        secondLoaderRequests++;
        return const [_subject];
      }

      final harnessKey = GlobalKey<_SubjectListHarnessState>();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            animeControllerProvider.overrideWith(_SubjectListController.new),
          ],
          child: MaterialApp(
            home: _SubjectListHarness(
              key: harnessKey,
              title: '科幻',
              subtitle: '分类',
              loader: firstLoader,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(firstLoaderRequests, 1);

      harnessKey.currentState!.show(
        title: '科幻',
        subtitle: '分类',
        loader: firstLoader,
      );
      await tester.pumpAndSettle();
      expect(firstLoaderRequests, 1);

      harnessKey.currentState!.show(
        title: '奇幻',
        subtitle: '分类',
        loader: firstLoader,
      );
      await tester.pumpAndSettle();
      expect(firstLoaderRequests, 2);

      harnessKey.currentState!.show(
        title: '奇幻',
        subtitle: '标签',
        loader: firstLoader,
      );
      await tester.pumpAndSettle();
      expect(firstLoaderRequests, 3);

      harnessKey.currentState!.show(
        title: '奇幻',
        subtitle: '标签',
        loader: secondLoader,
      );
      await tester.pumpAndSettle();
      expect(firstLoaderRequests, 3);
      expect(secondLoaderRequests, 1);
    },
  );

  testWidgets('subject list loading placeholder fits a narrow screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final pending = Completer<List<AnimeSubject>>();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(_SubjectListController.new),
        ],
        child: MaterialApp(
          home: SubjectListPage(
            title: '一个较长但仍需在小屏安全显示的分类标题',
            subtitle: '分类',
            loader: (ref) => pending.future,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('subject-list-loading')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

class _SubjectListHarness extends StatefulWidget {
  const _SubjectListHarness({
    super.key,
    required this.title,
    required this.subtitle,
    required this.loader,
  });

  final String title;
  final String? subtitle;
  final Future<List<AnimeSubject>> Function(WidgetRef ref) loader;

  @override
  State<_SubjectListHarness> createState() => _SubjectListHarnessState();
}

class _SubjectListHarnessState extends State<_SubjectListHarness> {
  late String _title;
  late String? _subtitle;
  late Future<List<AnimeSubject>> Function(WidgetRef ref) _loader;

  @override
  void initState() {
    super.initState();
    _title = widget.title;
    _subtitle = widget.subtitle;
    _loader = widget.loader;
  }

  void show({
    required String title,
    required String? subtitle,
    required Future<List<AnimeSubject>> Function(WidgetRef ref) loader,
  }) {
    setState(() {
      _title = title;
      _subtitle = subtitle;
      _loader = loader;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SubjectListPage(title: _title, subtitle: _subtitle, loader: _loader);
  }
}

class _SubjectListController extends AnimeController {
  @override
  Future<AnimeState> build() async => const AnimeState(homeFeed: _feed);
}

const _feed = AnimeHomeFeed(
  hero: _subject,
  recent: [],
  recommended: [],
  index: [],
  categories: [],
  tags: [],
);

const _subject = AnimeSubject(
  id: 1,
  title: '测试动画',
  originalTitle: 'Test Anime',
  summary: '测试简介',
  coverUrl: null,
  bannerUrl: null,
  date: '2026-07-20',
  platform: 'TV',
  language: '日语',
  region: '日本',
  status: '连载中',
  categories: [],
  tags: [],
  totalEpisodes: 12,
);
