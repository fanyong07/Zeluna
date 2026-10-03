import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anime/src/data/local_maccms_playback.dart';
import 'package:anime/src/data/zeluna_backend_playback_repository.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/playback/playback_discovery_controller.dart';
import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/rules/drpy_runtime.dart';
import 'package:anime/src/rules/rule_playback_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _id = 'registered:0123456789abcdef01234567';
const _source = PlaybackLine(
  id: 'source',
  episodeId: 101,
  providerId: 'maccms:test',
  providerName: '测试采集',
  sourceName: '测试采集',
  sourceInventoryId: _id,
  clientQuerySupported: true,
  title: '测试采集',
  quality: '',
  format: '',
);
const _episode = AnimeEpisode(
  id: 101,
  subjectId: 1,
  number: 1,
  title: '第1集',
  airdate: null,
  duration: '',
  description: '',
);
const _descriptor = {
  'inventory_source_id': _id,
  'protocol': 'maccms-json',
  'endpoint': 'https://source.example/api.php',
};
AnimeSubject _subject(String platform) => AnimeSubject(
  id: 1,
  title: '测试作品',
  originalTitle: 'Test Show',
  summary: '',
  coverUrl: null,
  bannerUrl: null,
  date: '2024',
  platform: platform,
  language: '',
  region: '',
  status: '',
  categories: const [],
  tags: const [],
  totalEpisodes: platform == '电影' ? 1 : 12,
  source: platform == '电影'
      ? 'tmdb:movie:1'
      : platform == '电视剧'
      ? 'tmdb:series:1'
      : 'bangumi',
);
Map<String, dynamic> _item(
  String type, {
  String title = '测试作品',
  String year = '2024',
  String? routes,
}) => {
  'vod_id': 1,
  'vod_name': title,
  'vod_year': year,
  'type_name': type,
  'vod_play_from': 'direct',
  'vod_play_url':
      routes ??
      r'第01集$https://cdn.example/one.mp4#第02集$https://cdn.example/two.mp4',
};
http.Response _json(List<Map<String, dynamic>> items) => http.Response(
  jsonEncode({'list': items}),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
RulePlaybackResolver _verifier(List<Uri> requests, {bool valid = true}) =>
    RulePlaybackResolver(
      drpyRuntime: DrpyRuntime(
        addressLookup: (_) async => [InternetAddress('93.184.216.34')],
      ),
      drpyPublicClient: MockClient((request) async {
        requests.add(request.url);
        if (!valid) {
          return http.Response(
            '<html>captcha</html>',
            200,
            headers: {'content-type': 'text/html'},
          );
        }
        final bytes = List<int>.filled(8192, 0)
          ..setRange(0, 12, [
            0,
            0,
            0,
            24,
            102,
            116,
            121,
            112,
            105,
            115,
            111,
            109,
          ]);
        return http.Response.bytes(
          bytes,
          206,
          headers: {
            'content-type': 'video/mp4',
            'content-range': 'bytes 0-8191/8192',
          },
        );
      }),
    );

void main() {
  test(
    'backend routes sharing labels and URLs retain registered identities',
    () async {
      final repository = ZelunaBackendPlaybackRepository(
        baseUrl: 'https://backend.example',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode([
              for (final id in [_id, 'registered:111111111111111111111111'])
                {
                  'inventory_source_id': id,
                  'provider_id': 'shared',
                  'line_id': 'shared-line',
                  'source': 'maccms:shared',
                  'url': 'https://cdn.example/shared.mp4',
                  'available': false,
                  'status': 'client_probe_required',
                },
            ]),
            200,
          ),
        ),
      );
      final result = await repository.linesForEpisodeMode(
        _subject('TV'),
        _episode,
        expandAll: true,
      );
      expect(result, hasLength(2));
      expect(result.map((l) => l.id).toSet(), hasLength(2));
      expect(mergePlaybackLines(result), hasLength(2));
    },
  );

  test('same media in different registered routes is never hidden', () {
    PlaybackLine route(String id, String inventoryId) => PlaybackLine(
      id: id,
      episodeId: 101,
      providerId: 'shared',
      providerName: '共享媒体',
      title: id,
      quality: '',
      format: 'mp4',
      url: 'https://cdn.example/shared.mp4',
      sourceInventoryId: inventoryId,
    );
    final lines = [
      route('a', _id),
      route('b', _id),
      route('c', 'registered:111111111111111111111111'),
    ];
    expect(mergePlaybackLines(lines), hasLength(3));
    expect(mergePlaybackLines([...lines, ...lines]), hasLength(3));
  });
  for (final invalidation in ['account', 'services', 'dispose', 'cancel']) {
    test(
      'late local descriptor cannot escape $invalidation cancellation',
      () async {
        final response = Completer<http.Response>();
        final entered = Completer<void>();
        final repository = ZelunaBackendPlaybackRepository(
          baseUrl: 'https://backend.example',
          client: MockClient((r) {
            entered.complete();
            return response.future;
          }),
        );
        var activeVersion = 1;
        final controller = PlaybackDiscoveryController(
          backendRepository: (_) => repository,
          ruleRepository: (_) => throw StateError('Rules must not be invoked'),
          verifyLine:
              (
                line, {
                enrichMetadata = true,
                forceRefresh = false,
                cancellationToken,
              }) async => line,
          isContextCurrent: (version) => version == activeVersion,
          clearRuleRuntimeCaches: () {},
        );
        controller.loadForAccount(
          accountId: 'a',
          contextVersion: 1,
          services: const ExternalServiceSettings(),
          ruleState: const RulePluginState(),
          history: const [],
        );
        final token = RulePlaybackCancellationToken();
        final pending = controller.lookupSourceOnDevice(
          subject: _subject('TV'),
          episode: _episode,
          source: _source,
          cancellationToken: token,
        );
        await entered.future;
        switch (invalidation) {
          case 'account':
            activeVersion = 2;
            controller.loadForAccount(
              accountId: 'b',
              contextVersion: 2,
              services: const ExternalServiceSettings(),
              ruleState: const RulePluginState(),
              history: const [],
            );
          case 'services':
            controller.applyServices(
              const ExternalServiceSettings(
                playbackBackendEndpoint: 'https://other.example',
              ),
              contextVersion: 1,
            );
          case 'dispose':
            controller.dispose();
          case 'cancel':
            token.cancel();
        }
        response.complete(http.Response(jsonEncode(_descriptor), 200));
        expect(await pending, isEmpty);
        if (invalidation != 'dispose') controller.dispose();
      },
    );
  }

  test('single-source total deadline stops later probing', () async {
    final response = Completer<http.Response>();
    final probes = <Uri>[];
    final adapter = LocalMacCmsPlayback(
      client: MockClient((_) => response.future),
      verifier: _verifier(probes),
      lookupBudget: const Duration(milliseconds: 15),
    );
    final result = await adapter.lookup(
      descriptor: _descriptor,
      source: _source,
      subject: _subject('电视剧'),
      episode: _episode,
    );
    expect(
      result.single.diagnosticStatus,
      PlaybackDiscoveryStatus.searchTimeout,
    );
    response.complete(_json([_item('国产剧')]));
    await Future<void>.delayed(Duration.zero);
    expect(probes, isEmpty);
  });
  for (final pair in [
    ('TV', '日本动漫'),
    ('电视剧', '国产剧'),
    ('电影', '动作片'),
    ('电影', '动画电影'),
  ]) {
    test('device search and real media probe: ${pair.$1}/${pair.$2}', () async {
      final requests = <Uri>[];
      final probes = <Uri>[];
      final adapter = LocalMacCmsPlayback(
        client: MockClient((r) async {
          requests.add(r.url);
          return _json([
            _item(
              pair.$2,
              routes: pair.$1 == '电影'
                  ? r'正片$https://cdn.example/movie.mp4'
                  : null,
            ),
          ]);
        }),
        verifier: _verifier(probes),
      );
      final result = await adapter.lookup(
        descriptor: _descriptor,
        source: _source,
        subject: _subject(pair.$1),
        episode: _episode,
      );
      expect(requests, hasLength(1));
      expect(requests.single.host, 'source.example');
      expect(requests.single.queryParameters['wd'], '测试作品');
      expect(probes, isNotEmpty);
      expect(probes.every((p) => p.host == 'cdn.example'), isTrue);
      expect(result, hasLength(1));
      expect(result.single.available, isTrue);
      expect(result.single.clientVerified, isTrue);
      expect(result.single.requiresClientProbe, isFalse);
      expect(result.single.queryLocation, 'local');
      expect(result.single.sourceInventoryId, _id);
    });
  }
  for (final bad in [
    _item('国产剧', title: '另一部作品'),
    _item('国产剧', year: '2023'),
    _item('动作片'),
    _item('日本动漫'),
  ]) {
    test('no wrong-work/category/year probe: $bad', () async {
      final probes = <Uri>[];
      final adapter = LocalMacCmsPlayback(
        client: MockClient((_) async => _json([bad])),
        verifier: _verifier(probes),
      );
      final result = await adapter.lookup(
        descriptor: _descriptor,
        source: _source,
        subject: _subject('电视剧'),
        episode: _episode,
      );
      expect(
        result.single.diagnosticStatus,
        PlaybackDiscoveryStatus.searchMiss,
      );
      expect(result.single.available, isFalse);
      expect(probes, isEmpty);
    });
  }
  test('candidate and HTML 200 are not playback success', () async {
    final adapter = LocalMacCmsPlayback(
      client: MockClient((_) async => _json([_item('国产剧')])),
      verifier: _verifier([], valid: false),
    );
    final result = await adapter.lookup(
      descriptor: _descriptor,
      source: _source,
      subject: _subject('电视剧'),
      episode: _episode,
    );
    expect(result.single.available, isFalse);
    expect(
      result.single.diagnosticStatus,
      PlaybackDiscoveryStatus.routeUnavailable,
    );
    expect(result.single.queryLocation, 'local');
  });
  for (final status in [200, 302, 403, 429]) {
    test('invalid response $status stays local and unavailable', () async {
      var count = 0;
      final adapter = LocalMacCmsPlayback(
        client: MockClient((_) async {
          count++;
          return http.Response(
            '<html>blocked</html>',
            status,
            headers: {'location': 'https://other.example/api'},
          );
        }),
      );
      final result = await adapter.lookup(
        descriptor: _descriptor,
        source: _source,
        subject: _subject('TV'),
        episode: _episode,
      );
      expect(count, 1);
      expect(result.single.available, isFalse);
      expect(
        result.single.diagnosticStatus,
        PlaybackDiscoveryStatus.searchError,
      );
    });
  }
  for (final endpoint in [
    'http://source.example/api',
    'https://127.0.0.1/api',
    'https://10.0.0.1/api',
    'https://user:fixture@source.example/api',
    'https://source.example:8443/api',
    'https://source.example/api?token=fixture',
    'https://source.example/api#x',
  ]) {
    test('unsafe descriptor rejected before request: $endpoint', () async {
      var count = 0;
      final adapter = LocalMacCmsPlayback(
        client: MockClient((_) async {
          count++;
          return _json([]);
        }),
      );
      await expectLater(
        adapter.lookup(
          descriptor: {..._descriptor, 'endpoint': endpoint},
          source: _source,
          subject: _subject('TV'),
          episode: _episode,
        ),
        throwsStateError,
      );
      expect(count, 0);
    });
  }
  test('private media is not probed', () async {
    final probes = <Uri>[];
    final adapter = LocalMacCmsPlayback(
      client: MockClient(
        (_) async =>
            _json([_item('国产剧', routes: r'第1集$http://127.0.0.1/one.mp4')]),
      ),
      verifier: _verifier(probes),
    );
    final result = await adapter.lookup(
      descriptor: _descriptor,
      source: _source,
      subject: _subject('电视剧'),
      episode: _episode,
    );
    expect(result.single.available, isFalse);
    expect(probes, isEmpty);
  });
  test('detail-only result uses selected endpoint and exact episode', () async {
    final requests = <Uri>[];
    final probes = <Uri>[];
    final adapter = LocalMacCmsPlayback(
      client: MockClient((r) async {
        requests.add(r.url);
        return _json([
          _item(
            '国产剧',
            routes: r.url.queryParameters.containsKey('ids')
                ? r'第02集$https://cdn.example/two.mp4'
                : '',
          ),
        ]);
      }),
      verifier: _verifier(probes),
    );
    final result = await adapter.lookup(
      descriptor: _descriptor,
      source: _source,
      subject: _subject('电视剧'),
      episode: _episode,
    );
    expect(requests, hasLength(2));
    expect(requests.last.queryParameters['ids'], '1');
    expect(
      result.single.diagnosticStatus,
      PlaybackDiscoveryStatus.matchedNoEpisode,
    );
    expect(probes, isEmpty);
  });
  test('cancelled request publishes no result or later probe', () async {
    final response = Completer<http.Response>();
    final token = RulePlaybackCancellationToken();
    final probes = <Uri>[];
    final adapter = LocalMacCmsPlayback(
      client: MockClient((_) => response.future),
      verifier: _verifier(probes),
    );
    final pending = adapter.lookup(
      descriptor: _descriptor,
      source: _source,
      subject: _subject('电视剧'),
      episode: _episode,
      cancellationToken: token,
    );
    token.cancel();
    response.complete(_json([_item('国产剧')]));
    expect(await pending, isEmpty);
    expect(probes, isEmpty);
  });
  test('descriptor request is metadata-only and ID-bound', () async {
    final requests = <Uri>[];
    final repository = ZelunaBackendPlaybackRepository(
      baseUrl: 'https://backend.example',
      client: MockClient((r) async {
        requests.add(r.url);
        return http.Response(jsonEncode(_descriptor), 200);
      }),
    );
    expect(await repository.localSourceDescriptor(_id), _descriptor);
    expect(requests.single.path, '/api/v3/playback-source/$_id');
    expect(requests.single.hasQuery, isFalse);
    await expectLater(
      repository.localSourceDescriptor('bad/id'),
      throwsStateError,
    );
    expect(requests, hasLength(1));
  });
}
