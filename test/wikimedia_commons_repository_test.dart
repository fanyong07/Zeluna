import 'dart:convert';

import 'package:anime/src/data/wikimedia_commons_repository.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'search keeps only playable files with accepted open licences',
    () async {
      late Uri requestedUri;
      final repository = WikimediaCommonsRepository(
        client: MockClient((request) async {
          requestedUri = request.url;
          return http.Response(
            jsonEncode({
              'query': {
                'pages': [
                  _page(101, license: 'Public domain'),
                  _page(102, license: 'CC BY-NC 4.0'),
                  _page(103, license: 'CC BY-SA 4.0', mime: 'image/jpeg'),
                ],
              },
            }),
            200,
          );
        }),
      );

      final subjects = await repository.search('animation', page: 2, limit: 3);

      expect(requestedUri.host, 'commons.wikimedia.org');
      expect(requestedUri.queryParameters['generator'], 'search');
      expect(requestedUri.queryParameters['prop'], 'videoinfo');
      expect(
        requestedUri.queryParameters['gsrsearch'],
        'filetype:video animation',
      );
      expect(requestedUri.queryParameters['gsroffset'], '3');
      expect(subjects, hasLength(1));
      expect(subjects.single.source, 'commons:101');
      expect(subjects.single.title, startsWith('开放视频'));
      expect(subjects.single.summary, contains('公共领域'));
    },
  );

  test(
    'playback resolves the direct Commons file and verifies licence again',
    () async {
      final repository = WikimediaCommonsRepository(
        client: MockClient((request) async {
          expect(request.url.queryParameters['pageids'], '101');
          return http.Response(
            jsonEncode({
              'query': {
                'pages': [_page(101, license: 'CC BY 4.0')],
              },
            }),
            200,
          );
        }),
      );
      const subject = AnimeSubject(
        id: 101,
        title: '开放动画 · Sample',
        originalTitle: 'Sample',
        summary: '',
        coverUrl: null,
        bannerUrl: null,
        date: null,
        platform: 'Movie',
        language: '未知',
        region: 'Wikimedia Commons',
        status: '开放动画',
        categories: [],
        tags: [],
        totalEpisodes: 1,
        source: 'commons:101',
      );
      const episode = AnimeEpisode(
        id: 1001,
        subjectId: 101,
        number: 1,
        title: '正片',
        airdate: null,
        duration: '',
        description: '',
      );

      final lines = await repository.linesForEpisode(subject, episode);

      expect(lines, hasLength(1));
      expect(lines.single.available, isTrue);
      expect(lines.single.format, 'WebM');
      expect(lines.single.url, 'https://upload.wikimedia.org/sample.webm');
      expect(lines.single.message, contains('CC BY'));
    },
  );

  test('uses Commons WebM derivatives when the original file is Ogg', () async {
    final repository = WikimediaCommonsRepository(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'query': {
              'pages': [
                _page(
                  201,
                  license: 'Public domain',
                  mime: 'application/ogg',
                  url: 'https://upload.wikimedia.org/original.ogg',
                  derivatives: const [
                    {
                      'src':
                          'https://upload.wikimedia.org/transcoded/480p.vp9.webm',
                      'type': 'video/webm; codecs="vp9, opus"',
                      'width': 854,
                      'height': 480,
                    },
                    {
                      'src':
                          'https://upload.wikimedia.org/transcoded/720p.vp9.webm',
                      'type': 'video/webm; codecs="vp9, opus"',
                      'width': 1280,
                      'height': 720,
                    },
                  ],
                ),
              ],
            },
          }),
          200,
        ),
      ),
    );
    const subject = AnimeSubject(
      id: 201,
      title: '开放纪录片 · Sample',
      originalTitle: 'Sample',
      summary: '',
      coverUrl: null,
      bannerUrl: null,
      date: null,
      platform: 'Movie',
      language: '未知',
      region: 'Wikimedia Commons',
      status: '开放纪录片',
      categories: [],
      tags: [],
      totalEpisodes: 1,
      source: 'commons:201',
    );
    const episode = AnimeEpisode(
      id: 2001,
      subjectId: 201,
      number: 1,
      title: '正片',
      airdate: null,
      duration: '',
      description: '',
    );

    final lines = await repository.linesForEpisode(subject, episode);

    expect(lines, hasLength(2));
    expect(lines.first.quality, '720p');
    expect(lines.first.url, contains('720p.vp9.webm'));
    expect(lines.every((line) => line.format == 'WebM'), isTrue);
  });
}

Map<String, dynamic> _page(
  int id, {
  required String license,
  String mime = 'video/webm',
  String url = 'https://upload.wikimedia.org/sample.webm',
  List<Map<String, Object?>> derivatives = const [],
}) {
  return {
    'pageid': id,
    'title': 'File:Sample animation.webm',
    'videoinfo': [
      {
        'url': url,
        'thumburl': 'https://upload.wikimedia.org/sample.jpg',
        'mime': mime,
        'size': 12 * 1024 * 1024,
        'width': 1280,
        'height': 720,
        'duration': 180,
        'derivatives': derivatives,
        'extmetadata': {
          'ObjectName': {'value': 'Sample animation'},
          'Artist': {'value': 'Open creator'},
          'DateTimeOriginal': {'value': '1938-01-01'},
          'LicenseShortName': {'value': license},
        },
      },
    ],
  };
}
