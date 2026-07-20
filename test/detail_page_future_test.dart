import 'package:anime/src/catalog/catalog_page.dart';
import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/data/bangumi_metadata_repository.dart';
import 'package:anime/src/data/media_download_task.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'detail future survives unrelated state rebuilds and refreshes by identity',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final harnessKey = GlobalKey<_DetailHarnessState>();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            animeControllerProvider.overrideWith(_DetailController.new),
          ],
          child: MaterialApp(home: _DetailHarness(key: harnessKey)),
        ),
      );
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(DetailPage)),
      );
      final controller =
          container.read(animeControllerProvider.notifier) as _DetailController;
      expect(controller.requestedSubjectIds, [1]);

      controller.publishDownloadProgress(25);
      await tester.pump();
      controller.publishDownloadProgress(50);
      await tester.pump();
      expect(controller.requestedSubjectIds, [1]);

      harnessKey.currentState!.show(_sameIdentitySubject);
      await tester.pump();
      expect(controller.requestedSubjectIds, [1]);

      harnessKey.currentState!.show(_subjectB);
      await tester.pumpAndSettle();
      expect(controller.requestedSubjectIds, [1, 2]);
      expect(find.text('第二部动画'), findsWidgets);
    },
  );
}

class _DetailHarness extends StatefulWidget {
  const _DetailHarness({super.key});

  @override
  State<_DetailHarness> createState() => _DetailHarnessState();
}

class _DetailHarnessState extends State<_DetailHarness> {
  AnimeSubject _subject = _subjectA;

  void show(AnimeSubject subject) {
    setState(() => _subject = subject);
  }

  @override
  Widget build(BuildContext context) => DetailPage(subject: _subject);
}

class _DetailController extends AnimeController {
  final requestedSubjectIds = <int>[];

  @override
  Future<AnimeState> build() async =>
      AnimeState(homeFeed: BangumiMetadataRepository().fallbackHomeFeed());

  @override
  Future<AnimeDetailBundle> detail(AnimeSubject subject) async {
    requestedSubjectIds.add(subject.id);
    return AnimeDetailBundle(
      subject: subject,
      episodes: [
        AnimeEpisode(
          id: subject.id * 100 + 1,
          subjectId: subject.id,
          number: 1,
          title: '第一集',
          airdate: '2026-01-01',
          duration: '24:00',
          description: '',
        ),
      ],
      characters: const [],
      staff: const [],
      recommendations: const [],
    );
  }

  void publishDownloadProgress(int downloadedBytes) {
    final current = state.value!;
    final now = DateTime.utc(2026, 7, 20);
    state = AsyncData(
      current.copyWith(
        offlineTasks: [
          MediaDownloadTask(
            id: 'active-download',
            subject: _subjectA,
            episode: _episodeA,
            createdAt: now,
            updatedAt: now,
            status: MediaDownloadTaskStatus.downloading,
            downloadedBytes: downloadedBytes,
            totalBytes: 100,
          ),
        ],
      ),
    );
  }
}

const _episodeA = AnimeEpisode(
  id: 101,
  subjectId: 1,
  number: 1,
  title: '第一集',
  airdate: '2026-01-01',
  duration: '24:00',
  description: '',
);

const _subjectA = AnimeSubject(
  id: 1,
  title: '第一部动画',
  originalTitle: 'First Anime',
  summary: '简介',
  coverUrl: null,
  bannerUrl: null,
  date: '2026-01-01',
  platform: 'TV',
  language: '日语',
  region: '日本',
  status: '连载中',
  categories: [],
  tags: [],
  totalEpisodes: 12,
);

const _sameIdentitySubject = AnimeSubject(
  id: 1,
  title: '第一部动画（资料更新）',
  originalTitle: 'First Anime',
  summary: '更新后的简介',
  coverUrl: null,
  bannerUrl: null,
  date: '2026-01-01',
  platform: 'TV',
  language: '日语',
  region: '日本',
  status: '连载中',
  categories: [],
  tags: [],
  totalEpisodes: 12,
);

const _subjectB = AnimeSubject(
  id: 2,
  title: '第二部动画',
  originalTitle: 'Second Anime',
  summary: '简介',
  coverUrl: null,
  bannerUrl: null,
  date: '2026-04-01',
  platform: 'TV',
  language: '日语',
  region: '日本',
  status: '连载中',
  categories: [],
  tags: [],
  totalEpisodes: 12,
);
