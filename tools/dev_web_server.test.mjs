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
  isAllowedImageContent,
  isAllowedSourceContent,
  parseAllowedHosts,
  requestPublic,
  rewritePlaylist,
  sanitizeSessionHeaders,
  sessionHeadersFor,
  sourceHeadersForRedirect,
  validateTarget,
} from './dev_web_server.mjs';

function mockUpstreamResponse(
  body,
  contentType,
  { status = 200, headers: extraHeaders = {}, advertiseLength = true } = {},
) {
  const bytes = Buffer.from(body);
  const headers = new Map([
    ['content-type', contentType],
    ...(advertiseLength ? [['content-length', bytes.length.toString()]] : []),
    ...Object.entries(extraHeaders).map(([name, value]) => [
      name.toLowerCase(),
      value.toString(),
    ]),
  ]);
  return {
    status,
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

test('synthetic DNS range is allowed only for hostname lookups with the local option', async () => {
  const strict = createBlockedAddressList({ allowSyntheticDns: false });
  const syntheticDns = createBlockedAddressList({ allowSyntheticDns: true });

  assert.equal(strict.check('198.18.0.1', 'ipv4'), true);
  assert.equal(syntheticDns.check('198.18.0.1', 'ipv4'), false);
  assert.equal(syntheticDns.check('127.0.0.1', 'ipv4'), true);
  assert.equal(syntheticDns.check('192.168.1.1', 'ipv4'), true);
  await assert.rejects(
    ensurePublicAddress(new URL('http://198.18.0.1/poster.jpg'), syntheticDns),
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

test('image proxy content policy accepts only declared image responses', () => {
  assert.equal(isAllowedImageContent('image/jpeg'), true);
  assert.equal(isAllowedImageContent('image/webp; charset=binary'), true);
  assert.equal(isAllowedImageContent('application/octet-stream'), false);
  assert.equal(isAllowedImageContent('text/html'), false);
  assert.equal(isAllowedImageContent('image/'), false);
});

test('image proxy returns cacheable bounded images without forwarding secrets', async () => {
  const upstreamRequests = [];
  const image = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a]);
  const server = createAnimeWebServer({
    fetchUpstream: async (url, options) => {
      upstreamRequests.push({ url: url.toString(), options });
      return {
        response: mockUpstreamResponse(image, 'image/png', {
          headers: {
            'set-cookie': 'upstream=secret',
            'www-authenticate': 'Bearer realm="private"',
            'x-upstream-secret': 'do-not-copy',
          },
        }),
        url,
      };
    },
  });
  const baseUrl = await listenOnLoopback(server);
  try {
    const target = 'https://images.example.com/poster.png';
    const response = await fetch(
      `${baseUrl}/image-proxy?url=${encodeURIComponent(target)}`,
      {
        headers: {
          authorization: 'Bearer browser-secret',
          cookie: 'browser=secret',
          'x-upstream-authorization': 'Bearer bypass',
          'x-upstream-cookie': 'bypass=secret',
        },
      },
    );

    assert.equal(response.status, 200);
    assert.equal(response.headers.get('content-type'), 'image/png');
    assert.equal(
      response.headers.get('cache-control'),
      'private, max-age=86400, stale-while-revalidate=604800',
    );
    assert.equal(response.headers.get('cross-origin-resource-policy'), 'same-origin');
    assert.equal(response.headers.get('x-content-type-options'), 'nosniff');
    assert.equal(response.headers.get('set-cookie'), null);
    assert.equal(response.headers.get('www-authenticate'), null);
    assert.equal(response.headers.get('x-upstream-secret'), null);
    assert.deepEqual(Buffer.from(await response.arrayBuffer()), image);

    assert.equal(upstreamRequests.length, 1);
    const [{ options }] = upstreamRequests;
    assert.equal(options.method, 'GET');
    assert.equal(options.strictRedirectHeaders, true);
    assert.equal(options.headers.authorization, undefined);
    assert.equal(options.headers.cookie, undefined);
    assert.equal(options.headers['x-upstream-authorization'], undefined);
    assert.equal(options.headers['x-upstream-cookie'], undefined);
    assert.equal(options.headers.referer, 'https://images.example.com');
    assert.match(options.headers.accept, /^image\//);
  } finally {
    await closeServer(server);
  }
});

test('image proxy supports HEAD without downloading a response body', async () => {
  let upstreamBody;
  const server = createAnimeWebServer({
    fetchUpstream: async (url) => {
      const response = mockUpstreamResponse('poster-bytes', 'image/jpeg');
      upstreamBody = response.body;
      return { response, url };
    },
  });
  const baseUrl = await listenOnLoopback(server);
  try {
    const target = 'https://images.example.com/poster.jpg';
    const response = await fetch(
      `${baseUrl}/image-proxy?url=${encodeURIComponent(target)}`,
      { method: 'HEAD' },
    );
    assert.equal(response.status, 200);
    assert.equal(response.headers.get('content-length'), '12');
    assert.equal(await response.text(), '');
    assert.equal(upstreamBody.destroyed, true);
  } finally {
    await closeServer(server);
  }
});

test('image proxy rejects non-images and both advertised and streamed oversize bodies', async () => {
  const cases = [
    {
      response: mockUpstreamResponse('<html>not an image</html>', 'text/html'),
      status: 415,
    },
    {
      response: mockUpstreamResponse('12345', 'image/jpeg'),
      status: 413,
    },
    {
      response: mockUpstreamResponse('12345', 'image/jpeg', {
        advertiseLength: false,
      }),
      status: 413,
    },
  ];
  let index = 0;
  const server = createAnimeWebServer({
    imageMaxBytes: 4,
    fetchUpstream: async (url) => ({
      response: cases[index++].response,
      url,
    }),
  });
  const baseUrl = await listenOnLoopback(server);
  try {
    for (const expected of cases) {
      const target = `https://images.example.com/poster-${index}.jpg`;
      const response = await fetch(
        `${baseUrl}/image-proxy?url=${encodeURIComponent(target)}`,
      );
      assert.equal(response.status, expected.status);
      assert.equal(response.headers.get('cache-control'), 'no-store');
    }
  } finally {
    await closeServer(server);
  }
});

test('image proxy enforces a total upstream timeout', async () => {
  const server = createAnimeWebServer({
    imageTimeoutMs: 20,
    fetchUpstream: async () => new Promise(() => {}),
  });
  const baseUrl = await listenOnLoopback(server);
  try {
    const target = 'https://images.example.com/never-responds.jpg';
    const response = await fetch(
      `${baseUrl}/image-proxy?url=${encodeURIComponent(target)}`,
    );
    assert.equal(response.status, 504);
    assert.equal(response.headers.get('cache-control'), 'no-store');
    assert.match(await response.text(), /timed out/i);
  } finally {
    await closeServer(server);
  }
});

test('image proxy timeout also stops a stalled image body', async () => {
  let stalledBody;
  const server = createAnimeWebServer({
    imageTimeoutMs: 20,
    fetchUpstream: async (url) => {
      stalledBody = new Readable({ read() {} });
      return {
        response: {
          status: 200,
          headers: {
            get(name) {
              return name.toLowerCase() === 'content-type' ? 'image/jpeg' : null;
            },
          },
          body: stalledBody,
        },
        url,
      };
    },
  });
  const baseUrl = await listenOnLoopback(server);
  try {
    const target = 'https://images.example.com/stalled.jpg';
    const response = await fetch(
      `${baseUrl}/image-proxy?url=${encodeURIComponent(target)}`,
    );
    assert.equal(response.status, 504);
    assert.equal(stalledBody.destroyed, true);
  } finally {
    await closeServer(server);
  }
});

test('image proxy rejects invalid targets and mutating methods before fetching', async () => {
  let fetchCount = 0;
  const server = createAnimeWebServer({
    fetchUpstream: async () => {
      fetchCount++;
      throw new Error('unexpected fetch');
    },
  });
  const baseUrl = await listenOnLoopback(server);
  try {
    const invalid = await fetch(
      `${baseUrl}/image-proxy?url=${encodeURIComponent('http://127.0.0.1/a.png')}`,
    );
    assert.equal(invalid.status, 400);

    const target = encodeURIComponent('https://images.example.com/a.png');
    const post = await fetch(`${baseUrl}/image-proxy?url=${target}`, {
      method: 'POST',
    });
    assert.equal(post.status, 405);
    assert.equal(post.headers.get('allow'), 'GET, HEAD, OPTIONS');
    assert.equal(fetchCount, 0);
  } finally {
    await closeServer(server);
  }
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
