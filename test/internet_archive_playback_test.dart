import 'dart:convert';

import 'package:anime/src/data/playback_source_repository.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('Internet Archive returns only verified playable video files', () async {
    final repository = InternetArchivePlaybackSourceRepository(
      client: MockClient((request) async {
        if (request.url.path == '/metadata/open_movie') {
          return http.Response(
            jsonEncode({
              'metadata': {
                'collection': ['feature_films'],
                'licenseurl':
                    'https://creativecommons.org/publicdomain/mark/1.0/',
              },
              'files': [
                {
                  'name': 'open_movie_1080p.mp4',
                  'format': 'h.264',
                  'size': '${12 * 1024 * 1024}',
                  'source': 'derivative',
                },
                {
                  'name': 'open_movie_thumb.mp4',
                  'format': 'MPEG4',
                  'size': '${2 * 1024 * 1024}',
                },
              ],
            }),
            200,
          );
        }
        if (request.url.path.endsWith('/open_movie_1080p.mp4')) {
          expect(request.headers['range'], 'bytes=0-1023');
          return http.Response.bytes(
            const [0, 0, 0, 24],
            206,
            headers: const {'content-type': 'video/mp4'},
          );
        }
        return http.Response('not found', 404);
      }),
    );
    const subject = AnimeSubject(
      id: 1,
      title: 'Open Movie',
      originalTitle: 'Open Movie',
      summary: '',
      coverUrl: null,
      bannerUrl: null,
      date: '2024-01-01',
      platform: 'Movie',
      language: 'en',
      region: 'Internet Archive',
      status: '公开媒体',
      categories: [],
      tags: [],
      totalEpisodes: 1,
      source: 'archive:open_movie',
    );
    const episode = AnimeEpisode(
      id: 10,
      subjectId: 1,
      number: 1,
      title: '正片',
      airdate: null,
      duration: '待补',
      description: '',
    );

    final lines = await repository.linesForEpisode(subject, episode);

    expect(lines, hasLength(1));
    expect(lines.single.available, isTrue);
    expect(lines.single.format, 'MP4');
    expect(lines.single.title, contains('1080p'));
  });
}
