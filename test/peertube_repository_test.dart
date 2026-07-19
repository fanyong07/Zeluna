import 'dart:convert';

import 'package:anime/src/data/peertube_repository.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const uuid = '5a97f2c3-1c29-446d-a52b-ace11faf47ce';

  test('search paginates and keeps only explicit open licences', () async {
    late Uri requestedUri;
    final repository = PeerTubeRepository(
      client: MockClient((request) async {
        requestedUri = request.url;
        return http.Response(
          jsonEncode({
            'total': 4,
            'data': [
              _searchVideo(uuid: uuid),
              _searchVideo(
                uuid: '6a97f2c3-1c29-446d-a52b-ace11faf47ce',
                nsfw: true,
              ),
              _searchVideo(
                uuid: '7a97f2c3-1c29-446d-a52b-ace11faf47ce',
                licence: const {'id': 9, 'label': 'All Rights Reserved'},
              ),
              _searchVideo(
                uuid: '8a97f2c3-1c29-446d-a52b-ace11faf47ce',
                licence: null,
              ),
            ],
          }),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final subjects = await repository.search('animation', page: 2, limit: 2);

    expect(requestedUri.path, '/api/v1/search/videos');
    expect(requestedUri.queryParameters['search'], 'animation');
    expect(requestedUri.queryParameters['start'], '6');
    expect(requestedUri.queryParameters['count'], '6');
    expect(requestedUri.queryParameters['nsfw'], 'false');
    expect(subjects, hasLength(1));
    expect(subjects.single.title, 'Open animation');
    expect(subjects.single.source, startsWith('peertube:'));
    expect(subjects.single.source, contains(uuid));
    expect(subjects.single.region, 'tube.example');
    expect(subjects.single.status, contains('Attribution'));
  });

  test('trending and detail resolution prefer HLS before MP4', () async {
    final repository = PeerTubeRepository(
      client: MockClient((request) async {
        if (request.url.host == 'sepiasearch.org') {
          expect(request.url.queryParameters['sort'], '-hot');
          expect(request.url.queryParameters.containsKey('search'), isFalse);
          return http.Response(
            jsonEncode({
              'total': 1,
              'data': [_searchVideo(uuid: uuid)],
            }),
            200,
          );
        }
        expect(request.url.host, 'tube.example');
        expect(request.url.path, '/api/v1/videos/$uuid');
        return http.Response(
          jsonEncode({
            'nsfw': false,
            'licence': {'id': 1, 'label': 'Attribution'},
            'streamingPlaylists': [
              {
                'playlistUrl': 'https://cdn.example/master.m3u8',
                'files': [
                  {
                    'resolution': {'id': 1080, 'label': '1080p'},
                    'playlistUrl': 'https://cdn.example/1080.m3u8',
                    'fileUrl': 'https://cdn.example/1080.mp4',
                    'size': 2147483648,
                  },
                  {
                    'resolution': {'id': 480, 'label': '480p'},
                    'playlistUrl': 'https://cdn.example/480.m3u8',
                    'fileUrl': 'https://cdn.example/480.mp4',
                  },
                ],
              },
            ],
            'files': [
              {
                'resolution': {'id': 720, 'label': '720p'},
                'fileUrl': 'https://cdn.example/direct-720.mp4',
              },
            ],
          }),
          200,
        );
      }),
    );

    final subjects = await repository.trending(limit: 1);
    final episode = AnimeEpisode(
      id: 11,
      subjectId: subjects.single.id,
      number: 1,
      title: '',
      airdate: null,
      duration: '',
      description: '',
    );
    final lines = await repository.linesForEpisode(subjects.single, episode);

    expect(lines, isNotEmpty);
    expect(lines.first.format, 'HLS');
    expect(lines.first.quality, '自动');
    final firstMp4 = lines.indexWhere((line) => line.format == 'MP4');
    expect(firstMp4, greaterThan(0));
    expect(lines.take(firstMp4).every((line) => line.format == 'HLS'), isTrue);
    expect(lines.any((line) => line.quality == '1080p'), isTrue);
    expect(
      lines.any((line) => line.url?.endsWith('direct-720.mp4') ?? false),
      isTrue,
    );
    expect(lines.first.providerName, 'PeerTube · tube.example');
  });
}

Map<String, dynamic> _searchVideo({
  required String uuid,
  bool nsfw = false,
  Object? licence = const {'id': 1, 'label': 'Attribution'},
}) {
  return {
    'uuid': uuid,
    'url': 'https://tube.example/videos/watch/$uuid',
    'name': 'Open animation',
    'description': 'An **open** animation.',
    'publishedAt': '2026-07-01T12:00:00.000Z',
    'category': {'id': 10, 'label': 'Entertainment'},
    'language': {'id': 'en', 'label': 'English'},
    'licence': licence,
    'nsfw': nsfw,
    'thumbnailUrl': 'https://tube.example/thumb.jpg',
    'previewUrl': 'https://tube.example/preview.jpg',
    'tags': ['animation', 'open'],
    'account': {'host': 'tube.example'},
  };
}
