import 'package:anime/src/core/network/network_security.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/rules/rule_playback_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('media redirects cannot escape to a private address', () async {
    final requested = <Uri>[];
    final inner = MockClient((request) async {
      requested.add(request.url);
      if (request.url.host == 'media.example') {
        return http.Response(
          '',
          302,
          headers: {'location': 'http://192.168.1.20/video.mp4'},
        );
      }
      fail('private redirect reached the transport: ${request.url}');
    });
    final client = PolicyHttpClient(
      inner: inner,
      ownsInner: false,
      policy: _trustedMediaPolicy,
    );
    addTearDown(inner.close);

    final verified = await RulePlaybackResolver(client: client)
        .verifyPlaybackLine(
          line: _line('https://media.example/start'),
          enrichMetadata: false,
        );

    expect(verified.available, isFalse);
    expect(requested, [Uri.parse('https://media.example/start')]);
  });

  test('HLS child resources repeat the public-address policy', () async {
    final requested = <Uri>[];
    final inner = MockClient((request) async {
      requested.add(request.url);
      if (request.url.host == 'media.example') {
        return http.Response(
          '#EXTM3U\n#EXTINF:4,\nhttp://169.254.169.254/latest/meta-data\n',
          200,
          headers: const {'content-type': 'application/vnd.apple.mpegurl'},
        );
      }
      fail('private HLS child reached the transport: ${request.url}');
    });
    final client = PolicyHttpClient(
      inner: inner,
      ownsInner: false,
      policy: _trustedMediaPolicy,
    );
    addTearDown(inner.close);

    final verified = await RulePlaybackResolver(client: client)
        .verifyPlaybackLine(
          line: _line('https://media.example/index.m3u8', format: 'hls'),
          enrichMetadata: false,
        );

    expect(verified.available, isFalse);
    expect(requested, [Uri.parse('https://media.example/index.m3u8')]);
  });
}

const _trustedMediaPolicy = NetworkRequestPolicy(
  service: NetworkServiceKind.mediaResource,
  httpsOnly: false,
  allowPrivateNetwork: false,
  maxResponseBytes: 512 * 1024,
  requestTimeout: Duration(seconds: 5),
  allowSyntheticDns: true,
  allowLiteralBenchmarkAddress: true,
  rejectRedirects: false,
);

PlaybackLine _line(String url, {String format = 'mp4'}) => PlaybackLine(
  id: 'line',
  episodeId: 1,
  providerId: 'backend',
  providerName: 'Backend',
  title: 'Line',
  quality: '1080P',
  format: format,
  url: url,
  serverVerified: true,
  available: true,
);
