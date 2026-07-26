import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/shared_ui/poster_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('bounded poster decodes near its physical display size', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: SizedBox(
            width: 100,
            height: 150,
            child: PosterArt(
              coverUrl: 'https://example.invalid/poster.jpg',
              title: '测试海报',
            ),
          ),
        ),
      ),
    );

    final image = tester.widget<Image>(find.byType(Image));
    final provider = image.image as ResizeImage;
    expect(provider.width, 200);
    expect(provider.height, 300);
    expect(image.filterQuality, FilterQuality.low);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('poster uses the cover fallback when the banner is absent', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SizedBox(
          width: 120,
          height: 180,
          child: PosterArt(
            coverUrl: null,
            fallbackCoverUrl: 'https://example.invalid/fallback.jpg',
            title: '测试海报',
          ),
        ),
      ),
    );

    final image = tester.widget<Image>(find.byType(Image));
    final provider = image.image as ResizeImage;
    final network = provider.imageProvider as NetworkImage;
    expect(network.url, 'https://example.invalid/fallback.jpg');
  });

  testWidgets('old Bangumi original url uses a display-sized thumbnail', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: SizedBox(
            width: 160,
            height: 240,
            child: PosterArt(
              coverUrl:
                  'https://lain.bgm.tv/pic/cover/l/27/ff/377130_wDU1x.jpg',
              title: 'Witch Hat Atelier',
            ),
          ),
        ),
      ),
    );

    final image = tester.widget<Image>(find.byType(Image));
    final provider = image.image as ResizeImage;
    final network = provider.imageProvider as NetworkImage;
    expect(
      network.url,
      'https://lain.bgm.tv/r/400/pic/cover/l/27/ff/377130_wDU1x.jpg',
    );
  });

  test('poster candidates keep smaller sources first and original fallback', () {
    final bangumi = posterImageCandidates(
      'https://lain.bgm.tv/pic/cover/l/27/ff/377130_wDU1x.jpg',
      targetPixelWidth: 350,
    );
    expect(
      bangumi.first,
      'https://lain.bgm.tv/r/400/pic/cover/l/27/ff/377130_wDU1x.jpg',
    );
    expect(
      bangumi,
      contains('https://lain.bgm.tv/pic/cover/l/27/ff/377130_wDU1x.jpg'),
    );

    final anilist = posterImageCandidates(
      'https://s4.anilist.co/file/anilistcdn/media/anime/cover/large/demo.jpg',
      targetPixelWidth: 320,
    );
    expect(
      anilist.first,
      'https://s4.anilist.co/file/anilistcdn/media/anime/cover/medium/demo.jpg',
    );
    expect(anilist.last, contains('/cover/large/'));
  });

  test('web candidates use same-origin proxy for images without CORS', () {
    final candidates = posterImageCandidates(
      'https://s4.anilist.co/file/anilistcdn/media/anime/cover/large/demo.jpg',
      targetPixelWidth: 320,
      webProxyBase: Uri.parse('https://zeluna.example/app/'),
    );

    expect(candidates.first, startsWith('https://zeluna.example/image-proxy?'));
    expect(
      Uri.parse(candidates.first).queryParameters['url'],
      'https://s4.anilist.co/file/anilistcdn/media/anime/cover/medium/demo.jpg',
    );
    expect(
      candidates,
      contains(
        'https://s4.anilist.co/file/anilistcdn/media/anime/cover/medium/demo.jpg',
      ),
    );
  });

  test('web candidates proxy Bangumi thumbnails before direct fallback', () {
    final candidates = posterImageCandidates(
      'https://lain.bgm.tv/pic/cover/l/27/ff/377130_wDU1x.jpg',
      targetPixelWidth: 350,
      webProxyBase: Uri.parse('http://127.0.0.1:5190/catalog'),
    );

    expect(candidates.first, startsWith('http://127.0.0.1:5190/image-proxy?'));
    expect(
      Uri.parse(candidates.first).queryParameters['url'],
      'https://lain.bgm.tv/r/400/pic/cover/l/27/ff/377130_wDU1x.jpg',
    );
    expect(candidates[1], startsWith('http://127.0.0.1:5190/image-proxy?'));
    expect(
      candidates.last,
      'https://lain.bgm.tv/pic/cover/l/27/ff/377130_wDU1x.jpg',
    );
  });

  test(
    'web candidates try proxied poster before a broken banner direct URL',
    () {
      const banner =
          'https://media.kitsu.app/anime/cover_images/8403/original.png';
      const poster =
          'https://media.kitsu.app/anime/poster_images/8403/large.jpg';
      final candidates = posterImageCandidates(
        banner,
        fallbackValues: const [poster],
        webProxyBase: Uri.parse('http://127.0.0.1:5190/anime'),
      );

      expect(Uri.parse(candidates[0]).queryParameters['url'], banner);
      expect(Uri.parse(candidates[1]).queryParameters['url'], poster);
      expect(candidates[2], banner);
      expect(candidates[3], poster);
    },
  );

  testWidgets('landscape poster card avoids per-card blur filters', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: SizedBox(
            width: 280,
            height: 180,
            child: PosterCard(subject: _subject, landscape: true, onTap: _noop),
          ),
        ),
      ),
    );

    expect(find.byType(ImageFiltered), findsNothing);
    expect(find.byType(BackdropFilter), findsNothing);
  });
  group('shouldShowPosterRating', () {
    test('无评分或占位满分（无投票）不显示', () {
      expect(shouldShowPosterRating(score: null, ratingTotal: null), isFalse);
      expect(shouldShowPosterRating(score: 0, ratingTotal: 10), isFalse);
      expect(shouldShowPosterRating(score: 10.0, ratingTotal: null), isFalse);
      expect(shouldShowPosterRating(score: 10.0, ratingTotal: 0), isFalse);
    });

    test('真实评分显示，包括有投票的满分', () {
      expect(shouldShowPosterRating(score: 8.7, ratingTotal: null), isTrue);
      expect(shouldShowPosterRating(score: 10.0, ratingTotal: 812), isTrue);
    });
  });
}

void _noop() {}

const _subject = AnimeSubject(
  id: 1,
  title: '测试动画',
  originalTitle: 'Test Anime',
  summary: '',
  coverUrl: 'demo:FF334455',
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
