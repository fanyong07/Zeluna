import 'dart:convert';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/player/subtitles/subtitle_document.dart';
import 'package:anime/src/player/subtitles/subtitle_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const subject = AnimeSubject(
  id: 100,
  title: 'Test',
  originalTitle: 'Test',
  summary: '',
  coverUrl: null,
  bannerUrl: null,
  date: '2026-01-01',
  platform: 'TV',
  language: '日语',
  region: '日本',
  status: '',
  categories: [],
  tags: [],
  totalEpisodes: 2,
);
const episode = AnimeEpisode(
  id: 1,
  subjectId: 100,
  number: 1,
  title: '',
  airdate: null,
  duration: '',
  description: '',
);
void main() {
  test(
    'old servers, network failures, unavailable and empty results are distinct',
    () async {
      for (final code in [404, 405, 500]) {
        final repo = SubtitleRepository(
          const ExternalServiceSettings(),
          client: MockClient((r) async {
            expect(r.url.path, '/api/v3/subtitles/search');
            final body = jsonDecode(r.body) as Map;
            expect(body['subject_key'], subject.identityKey);
            expect(body.containsKey('video_url'), isFalse);
            expect(r.headers.containsKey('authorization'), isFalse);
            return httpx(code);
          }),
        );
        addTearDown(repo.dispose);
        final result = await repo.search(subject, episode, 'ja');
        expect(
          result.status,
          code == 500 ? 'provider_unavailable' : 'manual_required',
        );
      }
      final repo = SubtitleRepository(
        const ExternalServiceSettings(),
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'status': 'not_found',
              'message': 'none',
              'candidates': [],
            }),
            200,
          ),
        ),
      );
      addTearDown(repo.dispose);
      expect((await repo.search(subject, episode, 'en')).status, 'not_found');
    },
  );
  test('network disabled never makes requests', () async {
    final repo = SubtitleRepository(
      const ExternalServiceSettings(playbackBackendEnabled: false),
      client: MockClient((_) async => throw StateError('must not call')),
    );
    addTearDown(repo.dispose);
    expect(
      (await repo.search(subject, episode, 'ja')).status,
      'manual_required',
    );
  });
  test('download uses opaque ID and rejects arbitrary URLs', () async {
    var calls = 0;
    final repo = SubtitleRepository(
      const ExternalServiceSettings(),
      client: MockClient((r) async {
        calls++;
        expect(
          r.url.path,
          '/api/v3/subtitles/0123456789abcdef0123456789abcdef/content',
        );
        return http.Response('1\n00:00:01,000 --> 00:00:02,000\nHello', 200);
      }),
    );
    addTearDown(repo.dispose);
    SupplementalSubtitleCandidate candidate(String id) =>
        SupplementalSubtitleCandidate(
          id: id,
          provider: 'test',
          entryId: '1',
          fileName: '01.srt',
          language: 'en',
          autoMatch: true,
          reasons: [],
        );
    final result = await repo.download(
      candidate('0123456789abcdef0123456789abcdef'),
    );
    expect(result.cues.single.text, 'Hello');
    expect(calls, 1);
    await expectLater(
      repo.download(candidate('https://127.0.0.1/secret')),
      throwsA(isA<SubtitleFileException>()),
    );
    expect(calls, 1);
  });
}

http.Response httpx(int code) => http.Response('', code);
