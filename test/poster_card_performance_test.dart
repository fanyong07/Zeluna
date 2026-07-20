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
