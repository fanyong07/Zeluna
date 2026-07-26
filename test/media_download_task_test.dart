import 'package:anime/src/data/media_download_task.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('download task persists progress without sensitive headers', () {
    final task = MediaDownloadTask(
      id: 'task-1',
      subject: _subject,
      episode: _episode,
      createdAt: DateTime.utc(2026, 7, 18, 1),
      updatedAt: DateTime.utc(2026, 7, 18, 2),
      status: MediaDownloadTaskStatus.paused,
      url: 'https://cdn.example/video.mp4?X-Amz-Signature=signed-secret',
      headers: const {
        'Referer': 'https://example.test/',
        'Cookie': 'session=secret',
        'Authorization': 'Bearer secret',
        'X-API-Key': 'api-secret',
        'X-Access-Token': 'access-secret',
        'Client-Secret': 'client-secret',
        'X-Auth': 'auth-secret',
        'X-Session': 'session-secret',
        'X-Signature': 'signature-secret',
      },
      downloadedBytes: 512,
      totalBytes: 1024,
      temporaryPath: r'C:\downloads\task-1.part',
      localPath: r'C:\downloads\episode.mp4',
      etag: '"v1"',
      completedUnits: 2,
      totalUnits: 4,
      message: '下载已暂停',
    );

    final json = task.toJson();
    final restored = MediaDownloadTask.fromJson(json);

    expect(json['headers'], isEmpty);
    expect(json['url'], isNull);
    expect(restored.status, MediaDownloadTaskStatus.paused);
    expect(restored.downloadedBytes, 512);
    expect(restored.totalBytes, 1024);
    expect(restored.progress, 0.5);
    expect(restored.completedUnits, 2);
    expect(restored.totalUnits, 4);
    expect(restored.headers, isEmpty);
    expect(restored.url, isNull);
  });

  test('legacy persisted credentials are removed while reading', () {
    final json =
        MediaDownloadTask(
            id: 'legacy-sensitive',
            subject: _subject,
            episode: _episode,
            createdAt: DateTime.utc(2026, 7, 18),
            updatedAt: DateTime.utc(2026, 7, 18),
            status: MediaDownloadTaskStatus.paused,
          ).toJson()
          ..['url'] = 'https://cdn.example/video.mp4?token=legacy-secret'
          ..['headers'] = {
            'Referer': 'https://example.test/',
            'X-Session': 'legacy-session',
            'X-Signature': 'legacy-signature',
          }
          ..['message'] =
              'ClientException: failed https://cdn.example/video.mp4?token=legacy-secret';

    final restored = MediaDownloadTask.fromJson(json);

    expect(restored.url, isNull);
    expect(restored.headers, isEmpty);
    expect(restored.message, '下载已暂停');
    expect(restored.message, isNot(contains('http')));
    expect(restored.message, isNot(contains('legacy-secret')));
  });

  test('completed task creates a local playback line', () {
    final task = MediaDownloadTask(
      id: 'task-2',
      subject: _subject,
      episode: _episode,
      createdAt: DateTime.utc(2026, 7, 18),
      updatedAt: DateTime.utc(2026, 7, 18),
      status: MediaDownloadTaskStatus.completed,
      format: 'MP4',
      downloadedBytes: 2048,
      totalBytes: 2048,
      localPath: r'C:\downloads\episode.mp4',
    );

    final line = task.localPlaybackLine;

    expect(line, isNotNull);
    expect(line!.providerId, 'offline');
    expect(line.available, isTrue);
    expect(line.url, startsWith('file:///C:/downloads/episode.mp4'));
  });
}

const _subject = AnimeSubject(
  id: 1,
  title: '测试动画',
  originalTitle: 'Test Anime',
  summary: 'summary',
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

const _episode = AnimeEpisode(
  id: 101,
  subjectId: 1,
  number: 1,
  title: '第一集',
  airdate: '2026-01-01',
  duration: '24:00',
  description: '',
);
