import 'package:anime/src/sources/proxy_session_headers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('keeps standard and legitimate custom X headers', () {
    expect(
      sanitizeProxySessionHeaders({
        'Authorization': ' Bearer secret ',
        'Cookie': 'sid=secret',
        'Referer': 'https://example.com/watch',
        'X-Token': ' source-token ',
        'x-source': 'catalog',
        'Accept': 'text/plain',
      }),
      {
        'authorization': 'Bearer secret',
        'cookie': 'sid=secret',
        'referer': 'https://example.com/watch',
        'x-token': 'source-token',
        'x-source': 'catalog',
      },
    );
  });

  test('blocks transport and proxy controlled headers', () {
    expect(
      sanitizeProxySessionHeaders({
        'Host': 'evil.example',
        'Content-Length': '999',
        'Connection': 'keep-alive',
        'Keep-Alive': 'timeout=5',
        'Transfer-Encoding': 'chunked',
        'Upgrade': 'websocket',
        'X-Forwarded-For': '127.0.0.1',
        'X-Real-IP': '127.0.0.1',
        'X-Upstream-Authorization': 'Bearer bypass',
        'X-Token': 'safe',
      }),
      {'x-token': 'safe'},
    );
  });

  test('enforces header count, name, value and aggregate limits', () {
    final manyHeaders = {
      for (var index = 0; index < 30; index++) 'X-Custom-$index': 'ok',
    };
    expect(sanitizeProxySessionHeaders(manyHeaders), hasLength(24));

    expect(
      sanitizeProxySessionHeaders({
        'X-${_repeat('a', 130)}': 'too-long-name',
        'X-Too-Large': _repeat('a', 8193),
        'X-Control': 'bad\tvalue',
        'X-First': _repeat('a', 6000),
        'X-Second': _repeat('b', 6000),
        'X-Third': _repeat('c', 6000),
      }),
      {'x-first': _repeat('a', 6000), 'x-second': _repeat('b', 6000)},
    );
  });
}

String _repeat(String value, int count) => List.filled(count, value).join();
