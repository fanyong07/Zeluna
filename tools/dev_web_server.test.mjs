import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { Readable } from 'node:stream';
import test from 'node:test';

import {
  createAnimeWebServer,
  createBlockedAddressList,
  ensureAllowedSourceHost,
  ensurePublicAddress,
  headersForRedirect,
  isAllowedSourceContent,
  parseAllowedHosts,
  requestPublic,
  rewritePlaylist,
  sanitizeSessionHeaders,
  sessionHeadersFor,
  sourceHeadersForRedirect,
  validateTarget,
} from './dev_web_server.mjs';

function mockUpstreamResponse(body, contentType) {
  const bytes = Buffer.from(body);
  const headers = new Map([
    ['content-type', contentType],
    ['content-length', bytes.length.toString()],
  ]);
  return {
    status: 200,
    headers: {
      get(name) {
        return headers.get(name.toLowerCase()) ?? null;
      },
    },
    body: Readable.from([bytes]),
    async text() {
      return body;
    },
  };
}

async function listenOnLoopback(server) {
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const address = server.address();
  assert.equal(typeof address, 'object');
  return `http://127.0.0.1:${address.port}`;
}

async function closeServer(server) {
  await new Promise((resolve, reject) => {
    server.close((error) => error ? reject(error) : resolve());
  });
}

test('target validation rejects local and credentialed urls', () => {
  assert.equal(validateTarget('file:///tmp/video.m3u8'), null);
  assert.equal(validateTarget('https://user:pass@example.com/video'), null);
  assert.equal(validateTarget('http://localhost/video'), null);
  assert.equal(validateTarget('http://127.0.0.1/video'), null);
  assert.equal(validateTarget('https://example.com/video')?.hostname, 'example.com');
});

test('address validation blocks private and mapped IPv4 literals', async () => {
  const blockList = createBlockedAddressList({ allowSyntheticDns: false });
  await assert.rejects(
    ensurePublicAddress(new URL('http://192.168.1.2/file'), blockList),
    (error) => error?.statusCode === 400,
  );
  await assert.rejects(
    ensurePublicAddress(new URL('http://[::ffff:127.0.0.1]/file'), blockList),
    (error) => error?.statusCode === 400,
  );
});

test('pinned upstream request does not perform a second DNS lookup', async () => {
  const upstream = createServer((request, response) => {
    response.writeHead(200, { 'content-type': 'text/plain' });
    response.end(request.headers.host);
  });
  await new Promise((resolve) => upstream.listen(0, '127.0.0.1', resolve));
  try {
    const address = upstream.address();
    assert.equal(typeof address, 'object');
    const response = await requestPublic(
      new URL(`http://dns-must-not-resolve.invalid:${address.port}/probe`),
      {
        method: 'GET',
        headers: { 'accept-encoding': 'identity' },
        addresses: [{ address: '127.0.0.1', family: 4 }],
      },
    );
    assert.equal(response.status, 200);
    assert.equal(
      await response.text(),
      `dns-must-not-resolve.invalid:${address.port}`,
    );
  } finally {
    await new Promise((resolve, reject) => {
      upstream.close((error) => error ? reject(error) : resolve());
    });
  }
});

test('session header sanitizer keeps only bounded single-line values', () => {
  assert.deepEqual(
    sanitizeSessionHeaders({
      Authorization: ' Bearer secret ',
      Cookie: 'sid=secret',
      Referer: 'https://example.com/watch',
      'X-Token': ' source-token ',
      'x-source': 'catalog',
      Accept: 'text/plain',
      Origin: 'https://example.com\r\nX-Injected: yes',
      Host: 'evil.example',
      'Content-Length': '999',
      Connection: 'keep-alive',
      'Transfer-Encoding': 'chunked',
      'X-Forwarded-For': '127.0.0.1',
      'X-Upstream-Authorization': 'Bearer bypass',
    }),
    {
      authorization: 'Bearer secret',
      cookie: 'sid=secret',
      referer: 'https://example.com/watch',
      'x-token': 'source-token',
      'x-source': 'catalog',
    },
  );
});

test('session header sanitizer enforces name, value, total and count limits', () => {
  const manyHeaders = Object.fromEntries(
    Array.from({ length: 30 }, (_, index) => [`X-Custom-${index}`, 'ok']),
  );
  assert.equal(Object.keys(sanitizeSessionHeaders(manyHeaders)).length, 24);
  assert.deepEqual(
    sanitizeSessionHeaders({
      [`X-${'a'.repeat(130)}`]: 'too-long-name',
      'X-Too-Large': 'a'.repeat(8193),
      'X-Control': 'bad\tvalue',
      'X-First': 'a'.repeat(6000),
      'X-Second': 'b'.repeat(6000),
      'X-Third': 'c'.repeat(6000),
    }),
    {
      'x-first': 'a'.repeat(6000),
      'x-second': 'b'.repeat(6000),
    },
  );
});

test('sensitive session headers stay on the exact initial origin', () => {
  const session = {
    targetOrigin: 'https://media.example.com',
    headers: {
      authorization: 'Bearer secret',
      cookie: 'sid=secret',
      'x-token': 'source-token',
      'x-source': 'catalog',
      referer: 'https://site.example/watch',
      'user-agent': 'Anime test',
    },
  };
  assert.equal(
    sessionHeadersFor(session, new URL('https://media.example.com/a')).authorization,
    'Bearer secret',
  );
  assert.equal(
    sessionHeadersFor(session, new URL('https://media.example.com/a'))['x-token'],
    'source-token',
  );
  const differentPort = sessionHeadersFor(
    session,
    new URL('https://media.example.com:8443/a'),
  );
  assert.equal(differentPort.authorization, undefined);
  assert.equal(differentPort.cookie, undefined);
  assert.equal(differentPort['x-token'], undefined);
  assert.equal(differentPort['x-source'], undefined);
  assert.equal(differentPort.referer, 'https://site.example/watch');
});

test('media session forwards custom X headers only to its matching origin', async () => {
  const upstreamRequests = [];
  const server = createAnimeWebServer({
    fetchUpstream: async (url, options) => {
      upstreamRequests.push({ url: url.toString(), headers: options.headers });
      return {
        response: mockUpstreamResponse('ok', 'application/octet-stream'),
        url,
      };
    },
  });
  const baseUrl = await listenOnLoopback(server);
  try {
    const sessionResponse = await fetch(`${baseUrl}/media-proxy/session`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        url: 'http://8.8.8.8/video.mp4',
        headers: {
          'X-Token': 'source-token',
          'X-Source': 'catalog',
        },
      }),
    });
    assert.equal(sessionResponse.status, 201);
    const { token } = await sessionResponse.json();

    for (const target of [
      'http://8.8.8.8/video.mp4',
      'http://1.1.1.1/video.mp4',
    ]) {
      const response = await fetch(
        `${baseUrl}/media-proxy?url=${encodeURIComponent(target)}&session=${token}`,
      );
      assert.equal(response.status, 200);
      await response.arrayBuffer();
    }

    assert.equal(upstreamRequests[0].headers['x-token'], 'source-token');
    assert.equal(upstreamRequests[0].headers['x-source'], 'catalog');
    assert.equal(upstreamRequests[1].headers['x-token'], undefined);
    assert.equal(upstreamRequests[1].headers['x-source'], undefined);
  } finally {
    await closeServer(server);
  }
});

test('cross-origin redirects strip sensitive upstream credentials', () => {
  const headers = {
    authorization: 'Bearer secret',
    cookie: 'sid=secret',
    'x-appid': 'app',
    'x-token': 'source-token',
    'x-source': 'catalog',
    referer: 'https://site.example/watch',
  };
  const sameOrigin = headersForRedirect(
    headers,
    new URL('https://media.example.com/a'),
    new URL('https://media.example.com/b'),
  );
  assert.equal(sameOrigin.authorization, 'Bearer secret');
  assert.equal(sameOrigin['x-token'], 'source-token');
  assert.equal(sameOrigin['x-source'], 'catalog');

  const crossOrigin = headersForRedirect(
    headers,
    new URL('https://media.example.com/a'),
    new URL('https://cdn.example.net/b'),
  );
  assert.equal(crossOrigin.authorization, undefined);
  assert.equal(crossOrigin.cookie, undefined);
  assert.equal(crossOrigin['x-appid'], undefined);
  assert.equal(crossOrigin['x-token'], undefined);
  assert.equal(crossOrigin['x-source'], undefined);
  assert.equal(crossOrigin.referer, 'https://site.example/watch');
});

test('source redirects retain only generic negotiation headers', () => {
  const headers = {
    authorization: 'Bearer secret',
    cookie: 'sid=secret',
    origin: 'https://site.example',
    referer: 'https://site.example/watch',
    'x-source': 'private',
    accept: 'text/plain',
    'user-agent': 'Anime test',
  };
  const sameOrigin = sourceHeadersForRedirect(
    headers,
    new URL('https://feeds.example/a'),
    new URL('https://feeds.example/b'),
  );
  assert.equal(sameOrigin.authorization, 'Bearer secret');

  const crossOrigin = sourceHeadersForRedirect(
    headers,
    new URL('https://feeds.example/a'),
    new URL('https://cdn.example/b'),
  );
  assert.deepEqual(crossOrigin, {
    accept: 'text/plain',
    'user-agent': 'Anime test',
  });
});

test('HLS rewriting inherits only the opaque session token', () => {
  const rewritten = rewritePlaylist(
    '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\nsegment.ts',
    new URL('https://media.example.com/path/master.m3u8'),
    null,
    '0123456789abcdefghijklmnopqrstuv',
  );
  assert.match(rewritten, /url=https%3A%2F%2Fmedia\.example\.com%2Fpath%2Fkey\.bin/);
  assert.match(rewritten, /url=https%3A%2F%2Fmedia\.example\.com%2Fpath%2Fsegment\.ts/);
  assert.match(rewritten, /session=0123456789abcdefghijklmnopqrstuv/);
  assert.doesNotMatch(rewritten, /authorization|cookie|referer|secret/i);
});

test('source proxy content policy allows text catalogs but rejects media', () => {
  assert.equal(
    isAllowedSourceContent('text/html; charset=utf-8', new URL('https://dmhy.org/')),
    true,
  );
  assert.equal(
    isAllowedSourceContent(
      'application/octet-stream',
      new URL('https://example.com/live.m3u'),
    ),
    true,
  );
  assert.equal(
    isAllowedSourceContent('video/mp4', new URL('https://example.com/a.mp4')),
    false,
  );
});

test('proxy endpoints make upstream HTML inert while preserving its text', async () => {
  const maliciousHtml = '<!doctype html><script>globalThis.pwned = true</script>';
  const server = createAnimeWebServer({
    fetchUpstream: async (url) => ({
      response: mockUpstreamResponse(
        maliciousHtml,
        url.pathname.endsWith('.xhtml')
          ? 'application/xhtml+xml; charset=utf-8'
          : 'text/html; charset=utf-8',
      ),
      url,
    }),
  });
  const baseUrl = await listenOnLoopback(server);
  try {
    for (const [proxyPath, upstreamPath] of [
      ['/source-proxy', '/payload.html'],
      ['/media-proxy', '/payload.xhtml'],
    ]) {
      const target = `https://example.com${upstreamPath}`;
      const response = await fetch(
        `${baseUrl}${proxyPath}?url=${encodeURIComponent(target)}`,
      );
      assert.equal(response.status, 200);
      assert.equal(response.headers.get('content-type'), 'text/plain; charset=utf-8');
      assert.equal(response.headers.get('x-content-type-options'), 'nosniff');
      assert.match(
        response.headers.get('content-security-policy') ?? '',
        /default-src 'none'.*sandbox/,
      );
      assert.match(
        response.headers.get('content-disposition') ?? '',
        /^attachment;/,
      );
      assert.equal(await response.text(), maliciousHtml);
    }
  } finally {
    await closeServer(server);
  }
});

test('source host allowlist is exact and redirect-safe', () => {
  const requestUrl = new URL(
    'http://127.0.0.1/source-proxy?hosts=dmhy.org,www.dmhy.org',
  );
  const hosts = parseAllowedHosts(requestUrl);
  assert.deepEqual([...hosts], ['dmhy.org', 'www.dmhy.org']);
  assert.doesNotThrow(() => {
    ensureAllowedSourceHost(new URL('https://www.dmhy.org/topics/list'), hosts);
  });
  assert.throws(
    () => ensureAllowedSourceHost(new URL('https://evil.example/'), hosts),
    (error) => error?.statusCode === 400,
  );
  assert.throws(
    () => parseAllowedHosts(
      new URL('http://127.0.0.1/source-proxy?hosts=dmhy.org/evil'),
    ),
    (error) => error?.statusCode === 400,
  );
});
