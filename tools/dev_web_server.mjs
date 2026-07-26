import { createServer, request as requestHttp } from 'node:http';
import { request as requestHttps } from 'node:https';
import { createReadStream, existsSync, statSync } from 'node:fs';
import { extname, join, normalize, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { lookup } from 'node:dns/promises';
import { BlockList, isIP } from 'node:net';
import { randomBytes } from 'node:crypto';

const root = resolve(process.cwd(), 'build/web');
const port = Number(process.env.PORT ?? 5174);
const host = process.env.HOST ?? '127.0.0.1';
const allowRemoteProxy = process.env.ALLOW_REMOTE_PROXY === '1';
const allowSyntheticDns = process.env.ALLOW_SYNTHETIC_DNS === '1';

const blockedAddresses = createBlockedAddressList({ allowSyntheticDns });
const mediaSessions = new Map();
const mediaSessionTtlMs = 2 * 60 * 60 * 1000;
const maxMediaSessions = 512;
const upstreamTimeoutMs = 20 * 1000;
const maxPlaylistBytes = 16 * 1024 * 1024;
const maxSourceBytes = 6 * 1024 * 1024;
const maxImageBytes = 8 * 1024 * 1024;
const imageProxyTimeoutMs = 15 * 1000;
const imageCacheControl =
  'private, max-age=86400, stale-while-revalidate=604800';
const maxMediaSessionHeaders = 24;
const maxMediaSessionHeaderNameBytes = 128;
const maxMediaSessionHeaderValueBytes = 8 * 1024;
const maxMediaSessionHeaderBytes = 16 * 1024;

const allowedSessionHeaders = new Map([
  ['user-agent', 'user-agent'],
  ['referer', 'referer'],
  ['origin', 'origin'],
  ['authorization', 'authorization'],
  ['cookie', 'cookie'],
]);

const forbiddenSessionHeaders = new Set([
  'host',
  'content-length',
  'connection',
  'keep-alive',
  'proxy-authenticate',
  'proxy-authorization',
  'proxy-connection',
  'te',
  'trailer',
  'transfer-encoding',
  'upgrade',
  'expect',
]);

const mimeTypes = new Map([
  ['.html', 'text/html; charset=utf-8'],
  ['.js', 'application/javascript; charset=utf-8'],
  ['.css', 'text/css; charset=utf-8'],
  ['.json', 'application/json; charset=utf-8'],
  ['.png', 'image/png'],
  ['.jpg', 'image/jpeg'],
  ['.jpeg', 'image/jpeg'],
  ['.svg', 'image/svg+xml'],
  ['.wasm', 'application/wasm'],
]);

export function createAnimeWebServer({
  fetchUpstream = fetchPublic,
  imageMaxBytes = maxImageBytes,
  imageTimeoutMs = imageProxyTimeoutMs,
} = {}) {
  return createServer(async (request, response) => {
    try {
      const requestUrl = new URL(
        request.url ?? '/',
        `http://${request.headers.host}`,
      );
      if (requestUrl.pathname === '/media-proxy') {
        await proxyMedia(request, response, requestUrl, fetchUpstream);
        return;
      }
      if (requestUrl.pathname === '/media-proxy/session') {
        await createMediaSession(request, response);
        return;
      }
      if (requestUrl.pathname === '/source-proxy') {
        await proxySource(request, response, requestUrl, fetchUpstream);
        return;
      }
      if (requestUrl.pathname === '/image-proxy') {
        await proxyImage(request, response, requestUrl, fetchUpstream, {
          maxBytes: imageMaxBytes,
          timeoutMs: imageTimeoutMs,
        });
        return;
      }
      if (requestUrl.pathname === '/reset-browser-cache') {
        serveCacheReset(response);
        return;
      }
      serveStatic(requestUrl, response);
    } catch (error) {
      if (response.headersSent) {
        response.destroy(error instanceof Error ? error : undefined);
        return;
      }
      const statusCode = error instanceof ProxyError ? error.statusCode : 500;
      response.writeHead(statusCode, {
        'content-type': 'text/plain; charset=utf-8',
        'cache-control': 'no-store',
      });
      response.end(
        error instanceof ProxyError
          ? error.message
          : `anime dev server error: ${error?.message ?? error}`,
      );
    }
  });
}

export function startAnimeWebServer({
  listenPort = port,
  listenHost = host,
} = {}) {
  if (!isLoopbackBind(listenHost) && !allowRemoteProxy) {
    throw new Error(
      'Refusing non-loopback bind. Set ALLOW_REMOTE_PROXY=1 only behind a trusted reverse proxy.',
    );
  }
  const server = createAnimeWebServer();
  server.listen(listenPort, listenHost, () => {
    console.log(`anime web server: http://${listenHost}:${listenPort}/`);
  });
  return server;
}

const entryPoint = process.argv[1]
  ? pathToFileURL(resolve(process.argv[1])).href
  : null;
if (entryPoint === import.meta.url) startAnimeWebServer();

class ProxyError extends Error {
  constructor(statusCode, message) {
    super(message);
    this.name = 'ProxyError';
    this.statusCode = statusCode;
  }
}

function serveStatic(requestUrl, response) {
  let path = decodeURIComponent(requestUrl.pathname);
  if (path === '/') path = '/index.html';
  const file = safePath(path);
  const target = existsSync(file) && statSync(file).isFile()
    ? file
    : join(root, 'index.html');
  const ext = extname(target).toLowerCase();
  response.writeHead(200, {
    'content-type': mimeTypes.get(ext) ?? 'application/octet-stream',
    'cache-control': ext === '.html' || ext === '.js' ? 'no-store' : 'public, max-age=60',
  });
  createReadStream(target).pipe(response);
}

function serveCacheReset(response) {
  response.writeHead(200, {
    'content-type': 'text/html; charset=utf-8',
    'cache-control': 'no-store',
  });
  response.end(`<!doctype html>
<meta charset="utf-8">
<title>anime cache reset</title>
<script>
(async () => {
  try {
    if ('serviceWorker' in navigator) {
      const registrations = await navigator.serviceWorker.getRegistrations();
      await Promise.all(registrations.map((item) => item.unregister()));
    }
    if ('caches' in window) {
      const keys = await caches.keys();
      await Promise.all(keys.map((key) => caches.delete(key)));
    }
  } finally {
    location.replace('/?v=' + Date.now());
  }
})();
</script>`);
}

function safePath(path) {
  const target = normalize(join(root, path));
  if (!target.startsWith(root)) return join(root, 'index.html');
  return target;
}

async function proxyMedia(request, response, requestUrl, fetchUpstream) {
  if (request.method === 'OPTIONS') {
    response.writeHead(204, corsHeaders({ 'cache-control': 'no-store' }));
    response.end();
    return;
  }
  if (!['GET', 'HEAD', 'POST'].includes(request.method ?? '')) {
    response.writeHead(405, {
      'content-type': 'text/plain; charset=utf-8',
      allow: 'GET, HEAD, POST, OPTIONS',
    });
    response.end('Method not allowed');
    return;
  }
  const target = requestUrl.searchParams.get('url');
  const targetUrl = validateTarget(target);
  if (!targetUrl) {
    response.writeHead(400, corsHeaders({ 'content-type': 'text/plain; charset=utf-8' }));
    response.end('Invalid media url');
    return;
  }

  const sessionToken = requestUrl.searchParams.get('session');
  const session = mediaSession(sessionToken);
  if (sessionToken && !session) {
    response.writeHead(401, {
      'content-type': 'text/plain; charset=utf-8',
      'cache-control': 'no-store',
    });
    response.end('Invalid or expired media session');
    return;
  }
  const sessionHeaders = sessionHeadersFor(session, targetUrl);
  const headers = {
    ...sessionHeaders,
    'user-agent':
      sessionHeaders['user-agent'] ||
      request.headers['x-upstream-user-agent'] ||
      request.headers['user-agent'] ||
      'Mozilla/5.0',
    accept: request.headers.accept || '*/*',
    'accept-encoding': 'identity',
    referer:
      safeReferer(requestUrl.searchParams.get('referer')) ||
      sessionHeaders.referer ||
      request.headers['x-upstream-referer'] ||
      targetUrl.origin,
  };
  if (request.headers.range) headers.range = request.headers.range;
  if (request.headers['content-type']) {
    headers['content-type'] = request.headers['content-type'];
  }
  if (request.headers['x-upstream-authorization']) {
    headers.authorization = request.headers['x-upstream-authorization'];
  }
  if (request.headers['x-upstream-cookie']) {
    headers.cookie = request.headers['x-upstream-cookie'];
  }
  if (request.headers['x-upstream-x-appid']) {
    headers['x-appid'] = request.headers['x-upstream-x-appid'];
  }
  if (request.headers['x-upstream-x-timestamp']) {
    headers['x-timestamp'] = request.headers['x-upstream-x-timestamp'];
  }
  if (request.headers['x-upstream-x-signature']) {
    headers['x-signature'] = request.headers['x-upstream-x-signature'];
  }

  const method = request.method === 'POST'
    ? 'POST'
    : request.method === 'HEAD'
      ? 'HEAD'
      : 'GET';
  const body = method === 'POST' ? await readRequestBody(request) : undefined;
  const fetched = await fetchUpstream(targetUrl, {
    method,
    headers,
    body,
  });
  const upstream = fetched.response;
  const finalUrl = fetched.url;
  const contentType = upstream.headers.get('content-type') ?? '';
  const isPlaylist =
    contentType.includes('mpegurl') ||
    contentType.includes('application/x-mpegurl') ||
    finalUrl.pathname.toLowerCase().includes('.m3u8');

  if (isPlaylist) {
    const body = await upstream.text();
    response.writeHead(upstream.status, corsHeaders({
      ...safeProxyContentHeaders(
        'application/vnd.apple.mpegurl; charset=utf-8',
        'application/vnd.apple.mpegurl; charset=utf-8',
      ),
      'cache-control': 'no-store',
    }));
    response.end(
      rewritePlaylist(
        body,
        finalUrl,
        sessionToken ? null : headers.referer,
        sessionToken,
      ),
    );
    return;
  }

  const responseHeaders = corsHeaders({
    ...safeProxyContentHeaders(contentType, 'application/octet-stream'),
    'cache-control': 'no-store',
    'accept-ranges': upstream.headers.get('accept-ranges') ?? 'bytes',
  });
  const contentLength = upstream.headers.get('content-length');
  const contentRange = upstream.headers.get('content-range');
  if (contentLength) responseHeaders['content-length'] = contentLength;
  if (contentRange) responseHeaders['content-range'] = contentRange;

  response.writeHead(upstream.status, responseHeaders);
  if (!upstream.body) {
    response.end();
    return;
  }
  upstream.body.once('error', (error) => response.destroy(error));
  upstream.body.pipe(response);
}

async function proxyImage(
  request,
  response,
  requestUrl,
  fetchUpstream,
  { maxBytes, timeoutMs },
) {
  if (request.method === 'OPTIONS') {
    response.writeHead(204, {
      allow: 'GET, HEAD, OPTIONS',
      'cache-control': 'no-store',
    });
    response.end();
    return;
  }
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    response.writeHead(405, {
      'content-type': 'text/plain; charset=utf-8',
      'cache-control': 'no-store',
      allow: 'GET, HEAD, OPTIONS',
    });
    response.end('Method not allowed');
    return;
  }

  const target = requestUrl.searchParams.get('url');
  const targetUrl = typeof target === 'string' && target.length <= 8192
    ? validateTarget(target)
    : null;
  if (!targetUrl) {
    throw new ProxyError(400, 'Invalid image url');
  }

  const abortController = new AbortController();
  let timeoutId;
  const timeout = new Promise((_, reject) => {
    timeoutId = setTimeout(() => {
      abortController.abort();
      reject(new ProxyError(504, 'Upstream image request timed out'));
    }, timeoutMs);
  });
  let upstream;
  try {
    const fetched = await Promise.race([
      fetchUpstream(targetUrl, {
        method: request.method,
        headers: {
          'user-agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
            + 'AppleWebKit/537.36 Chrome/124 Safari/537.36',
          accept: 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
          'accept-encoding': 'identity',
          referer: targetUrl.origin,
        },
        strictRedirectHeaders: true,
        signal: abortController.signal,
        timeoutMs,
      }),
      timeout,
    ]);
    upstream = fetched.response;
    const contentType = upstream.headers.get('content-type') ?? '';
    if (!isAllowedImageContent(contentType)) {
      upstream.body?.destroy();
      throw new ProxyError(415, 'Upstream response is not an image');
    }

    const advertisedLengthText = upstream.headers.get('content-length');
    const advertisedLength = advertisedLengthText === null
      ? null
      : Number(advertisedLengthText);
    if (advertisedLength !== null &&
        Number.isFinite(advertisedLength) &&
        advertisedLength > maxBytes) {
      upstream.body?.destroy();
      throw new ProxyError(413, 'Upstream image exceeds the allowed size');
    }

    const cacheControl = upstream.status >= 200 && upstream.status < 300
      ? imageCacheControl
      : 'no-store';
    const responseHeaders = {
      ...safeProxyContentHeaders(contentType, 'application/octet-stream'),
      'cache-control': cacheControl,
      'cross-origin-resource-policy': 'same-origin',
    };

    if (request.method === 'HEAD' || !upstream.body) {
      if (advertisedLength !== null &&
          Number.isSafeInteger(advertisedLength) &&
          advertisedLength >= 0) {
        responseHeaders['content-length'] = advertisedLength.toString();
      }
      response.writeHead(upstream.status, responseHeaders);
      response.end();
      upstream.body?.destroy();
      return;
    }

    const body = await Promise.race([
      readStreamBody(upstream.body, maxBytes),
      timeout,
    ]);
    responseHeaders['content-length'] = body.length.toString();
    response.writeHead(upstream.status, responseHeaders);
    response.end(body);
  } catch (error) {
    upstream?.body?.destroy();
    throw error;
  } finally {
    clearTimeout(timeoutId);
  }
}

async function createMediaSession(request, response) {
  if (request.method !== 'POST') {
    response.writeHead(405, {
      'content-type': 'text/plain; charset=utf-8',
      allow: 'POST',
    });
    response.end('Method not allowed');
    return;
  }
  const contentType = request.headers['content-type'] ?? '';
  if (!contentType.toLowerCase().startsWith('application/json')) {
    response.writeHead(415, { 'content-type': 'text/plain; charset=utf-8' });
    response.end('Expected application/json');
    return;
  }
  const body = await readRequestBody(request, 32 * 1024);
  let decoded;
  try {
    decoded = JSON.parse(body?.toString('utf8') ?? '');
  } catch {
    decoded = null;
  }
  const target = validateTarget(decoded?.url);
  if (!target || !decoded?.headers || typeof decoded.headers !== 'object') {
    response.writeHead(400, { 'content-type': 'text/plain; charset=utf-8' });
    response.end('Invalid media session');
    return;
  }
  await ensurePublicAddress(target);
  const headers = sanitizeSessionHeaders(decoded.headers);
  const token = randomBytes(24).toString('base64url');
  cleanupMediaSessions();
  mediaSessions.set(token, {
    targetOrigin: target.origin,
    headers,
    expiresAt: Date.now() + mediaSessionTtlMs,
  });
  while (mediaSessions.size > maxMediaSessions) {
    mediaSessions.delete(mediaSessions.keys().next().value);
  }
  response.writeHead(201, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
  });
  response.end(JSON.stringify({ token }));
}

async function proxySource(request, response, requestUrl, fetchUpstream) {
  if (request.method === 'OPTIONS') {
    response.writeHead(204, { 'cache-control': 'no-store' });
    response.end();
    return;
  }
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    response.writeHead(405, {
      'content-type': 'text/plain; charset=utf-8',
      allow: 'GET, HEAD, OPTIONS',
    });
    response.end('Method not allowed');
    return;
  }
  const targetUrl = validateTarget(requestUrl.searchParams.get('url'));
  if (!targetUrl) {
    response.writeHead(400, { 'content-type': 'text/plain; charset=utf-8' });
    response.end('Invalid source url');
    return;
  }
  const allowedHosts = parseAllowedHosts(requestUrl);
  const sessionToken = requestUrl.searchParams.get('session');
  const session = mediaSession(sessionToken);
  if (sessionToken && !session) {
    throw new ProxyError(400, 'Invalid or expired source session');
  }

  const accept = safeRequestHeader(request.headers.accept, 1024) ||
    'text/html,application/json,application/xml,text/plain,*/*';
  const sessionHeaders = sessionHeadersFor(session, targetUrl);
  const fetched = await fetchUpstream(targetUrl, {
    method: request.method,
    headers: {
      'user-agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
        + 'AppleWebKit/537.36 Chrome/124 Safari/537.36',
      accept,
      'accept-language':
        safeRequestHeader(request.headers['accept-language'], 512) ||
        'zh-CN,zh;q=0.9,en;q=0.7',
      'accept-encoding': 'identity',
      referer: targetUrl.origin,
      ...sessionHeaders,
    },
    allowedHosts,
    strictRedirectHeaders: true,
  });
  const upstream = fetched.response;
  const contentType = upstream.headers.get('content-type') ?? '';
  if (!isAllowedSourceContent(contentType, fetched.url)) {
    upstream.body?.destroy();
    throw new ProxyError(415, 'Upstream response is not a supported text source');
  }
  const advertisedLength = Number(
    upstream.headers.get('content-length') ?? '0',
  );
  if (Number.isFinite(advertisedLength) && advertisedLength > maxSourceBytes) {
    upstream.body?.destroy();
    throw new ProxyError(413, 'Upstream response exceeds the allowed size');
  }

  const responseHeaders = {
    ...safeProxyContentHeaders(contentType, 'text/plain; charset=utf-8'),
    'cache-control': 'no-store',
    'x-source-final-url': fetched.url.toString(),
  };
  if (request.method === 'HEAD' || !upstream.body) {
    if (advertisedLength > 0) {
      responseHeaders['content-length'] = advertisedLength.toString();
    }
    response.writeHead(upstream.status, responseHeaders);
    response.end();
    upstream.body?.destroy();
    return;
  }

  const body = await readStreamBody(upstream.body, maxSourceBytes);
  if (looksBinary(body)) {
    throw new ProxyError(415, 'Upstream response is not a text source');
  }
  responseHeaders['content-length'] = body.length.toString();
  response.writeHead(upstream.status, responseHeaders);
  response.end(body);
}

function safeRequestHeader(value, maxLength) {
  if (Array.isArray(value)) value = value.join(', ');
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  if (!trimmed || trimmed.length > maxLength || /[\r\n]/.test(trimmed)) {
    return null;
  }
  return trimmed;
}

export function isAllowedSourceContent(contentType, url) {
  const type = contentType.split(';', 1)[0].trim().toLowerCase();
  if (type.startsWith('text/')) return true;
  if (type.endsWith('+json') || type.endsWith('+xml')) return true;
  if ([
    '',
    'application/json',
    'application/xml',
    'application/xhtml+xml',
    'application/vnd.apple.mpegurl',
    'application/x-mpegurl',
    'audio/mpegurl',
    'audio/x-mpegurl',
  ].includes(type)) return true;
  if (type !== 'application/octet-stream') return false;
  return /\.(?:m3u8?|txt|json|xml)(?:$|[?#])/i.test(url.toString());
}

export function isAllowedImageContent(contentType) {
  const type = contentType.split(';', 1)[0].trim().toLowerCase();
  return type.startsWith('image/') && type.length > 'image/'.length;
}

function looksBinary(value) {
  const sample = value.subarray(0, Math.min(value.length, 4096));
  return sample.includes(0);
}

export function parseAllowedHosts(requestUrl) {
  if (!requestUrl.searchParams.has('hosts')) return null;
  const values = requestUrl.searchParams
    .getAll('hosts')
    .flatMap((value) => value.split(','))
    .map((value) => normalizeAllowedHost(value));
  if (values.length === 0 || values.length > 16 || values.some((value) => !value)) {
    throw new ProxyError(400, 'Invalid source host allowlist');
  }
  return new Set(values);
}

function normalizeAllowedHost(value) {
  const host = stripIpv6Brackets(value.trim().toLowerCase());
  if (!host || host.length > 253) return null;
  if (isIP(host)) return host;
  if (!/^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/i.test(host)) {
    return null;
  }
  return host;
}

export function ensureAllowedSourceHost(url, allowedHosts) {
  if (!allowedHosts) return;
  const host = stripIpv6Brackets(url.hostname).toLowerCase();
  if (!allowedHosts.has(host)) {
    throw new ProxyError(400, 'Source redirect left the allowed host list');
  }
}

export function sanitizeSessionHeaders(value) {
  const result = {};
  let acceptedCount = 0;
  let acceptedBytes = 0;
  for (const [key, rawValue] of Object.entries(value)) {
    const target = sessionHeaderName(key);
    if (!target || typeof rawValue !== 'string') continue;
    const headerValue = rawValue.trim();
    const valueBytes = Buffer.byteLength(headerValue, 'utf8');
    if (!headerValue ||
        valueBytes > maxMediaSessionHeaderValueBytes ||
        /[\u0000-\u001f\u007f]/.test(headerValue) ||
        Object.hasOwn(result, target)) {
      continue;
    }
    const headerBytes = Buffer.byteLength(target, 'utf8') + valueBytes;
    if (acceptedCount >= maxMediaSessionHeaders ||
        acceptedBytes + headerBytes > maxMediaSessionHeaderBytes) {
      continue;
    }
    result[target] = headerValue;
    acceptedCount++;
    acceptedBytes += headerBytes;
  }
  return result;
}

function sessionHeaderName(value) {
  const normalized = value.trim().toLowerCase();
  if (!normalized ||
      Buffer.byteLength(normalized, 'utf8') > maxMediaSessionHeaderNameBytes ||
      !/^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/.test(normalized) ||
      forbiddenSessionHeaders.has(normalized) ||
      normalized.startsWith('x-forwarded-') ||
      normalized === 'x-real-ip' ||
      normalized.startsWith('x-upstream-')) {
    return null;
  }
  const allowed = allowedSessionHeaders.get(normalized);
  if (allowed) return allowed;
  return normalized.startsWith('x-') && normalized.length > 2
    ? normalized
    : null;
}

function isOriginBoundSessionHeader(value) {
  const normalized = value.toLowerCase();
  return normalized === 'authorization' ||
    normalized === 'cookie' ||
    normalized.startsWith('x-');
}

function mediaSession(token) {
  if (!token || !/^[A-Za-z0-9_-]{32}$/.test(token)) return null;
  const session = mediaSessions.get(token);
  if (!session) return null;
  if (session.expiresAt <= Date.now()) {
    mediaSessions.delete(token);
    return null;
  }
  session.expiresAt = Date.now() + mediaSessionTtlMs;
  mediaSessions.delete(token);
  mediaSessions.set(token, session);
  return session;
}

export function sessionHeadersFor(session, targetUrl) {
  if (!session) return {};
  const sameOrigin = session.targetOrigin === targetUrl.origin;
  const result = {};
  for (const [key, value] of Object.entries(session.headers)) {
    const sensitive = isOriginBoundSessionHeader(key);
    if (!sensitive || sameOrigin) result[key] = value;
  }
  return result;
}

function cleanupMediaSessions() {
  const now = Date.now();
  for (const [token, session] of mediaSessions) {
    if (session.expiresAt <= now) mediaSessions.delete(token);
  }
}

async function readRequestBody(request, maxBytes = 1024 * 1024) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > maxBytes) {
      throw new ProxyError(413, 'Proxy request body exceeds the allowed size');
    }
    chunks.push(chunk);
  }
  return chunks.length === 0 ? undefined : Buffer.concat(chunks);
}

function corsHeaders(extra) {
  return {
    ...extra,
  };
}

function safeProxyContentHeaders(contentType, fallbackContentType) {
  const rawContentType = contentType.trim();
  const type = rawContentType.split(';', 1)[0].trim().toLowerCase();
  const isExecutableHtml = type === 'text/html' ||
    type === 'application/xhtml+xml';
  let safeContentType = rawContentType || fallbackContentType;
  if (isExecutableHtml) {
    const parametersAt = rawContentType.indexOf(';');
    safeContentType = parametersAt >= 0
      ? `text/plain${rawContentType.slice(parametersAt)}`
      : 'text/plain; charset=utf-8';
  }
  const headers = {
    'content-type': safeContentType,
    'x-content-type-options': 'nosniff',
    'content-security-policy':
      "default-src 'none'; base-uri 'none'; form-action 'none'; "
      + "frame-ancestors 'none'; sandbox",
    'referrer-policy': 'no-referrer',
  };
  if (isExecutableHtml) {
    headers['content-disposition'] =
      'attachment; filename="upstream-response.txt"';
  }
  return headers;
}

async function fetchPublic(initialUrl, options) {
  let current = initialUrl;
  let method = options.method;
  let body = options.body;
  let headers = { ...options.headers };
  for (let redirectCount = 0; redirectCount <= 5; redirectCount++) {
    ensureAllowedSourceHost(current, options.allowedHosts);
    const addresses = await ensurePublicAddress(current);
    const upstream = await requestPublic(current, {
      method,
      headers,
      body,
      addresses,
      signal: options.signal,
      timeoutMs: options.timeoutMs,
    });
    if (![301, 302, 303, 307, 308].includes(upstream.status)) {
      return { response: upstream, url: current };
    }
    if (redirectCount === 5) {
      upstream.body?.destroy();
      throw new ProxyError(502, 'Too many upstream redirects');
    }
    const location = upstream.headers.get('location');
    upstream.body?.destroy();
    const next = validateTarget(location ? new URL(location, current).toString() : null);
    if (!next) throw new ProxyError(400, 'Unsafe upstream redirect');
    ensureAllowedSourceHost(next, options.allowedHosts);
    if (upstream.status === 303 ||
        ((upstream.status === 301 || upstream.status === 302) && method === 'POST')) {
      method = 'GET';
      body = undefined;
      headers = { ...headers };
      delete headers['content-type'];
    }
    headers = options.strictRedirectHeaders
      ? sourceHeadersForRedirect(headers, current, next)
      : headersForRedirect(headers, current, next);
    current = next;
  }
  throw new ProxyError(502, 'Too many upstream redirects');
}

export async function requestPublic(
  url,
  {
    method,
    headers,
    body,
    addresses,
    signal,
    timeoutMs = upstreamTimeoutMs,
  },
) {
  const address = [...addresses].sort((a, b) => a.family - b.family)[0];
  const transport = url.protocol === 'https:' ? requestHttps : requestHttp;
  return new Promise((resolveRequest, rejectRequest) => {
    let settled = false;
    const cleanupAbortListener = () => {
      signal?.removeEventListener('abort', abortRequest);
    };
    const abortRequest = () => {
      upstreamRequest.destroy(
        new ProxyError(504, 'Upstream request timed out'),
      );
    };
    const upstreamRequest = transport({
      protocol: url.protocol,
      hostname: stripIpv6Brackets(url.hostname),
      port: url.port || undefined,
      method,
      path: `${url.pathname}${url.search}`,
      headers,
      lookup: (_hostname, options, callback) => {
        if (options?.all) {
          callback(null, [{ address: address.address, family: address.family }]);
          return;
        }
        callback(null, address.address, address.family);
      },
    }, (upstreamResponse) => {
      settled = true;
      upstreamResponse.once('end', cleanupAbortListener);
      upstreamResponse.once('close', cleanupAbortListener);
      resolveRequest(wrapUpstreamResponse(upstreamResponse));
    });
    if (signal?.aborted) {
      abortRequest();
    } else {
      signal?.addEventListener('abort', abortRequest, { once: true });
    }
    upstreamRequest.setTimeout(timeoutMs, () => {
      upstreamRequest.destroy(
        new ProxyError(504, 'Upstream request timed out'),
      );
    });
    upstreamRequest.once('error', (error) => {
      cleanupAbortListener();
      if (settled) return;
      rejectRequest(
        error instanceof ProxyError
          ? error
          : new ProxyError(502, 'Upstream request failed'),
      );
    });
    if (body) upstreamRequest.end(body);
    else upstreamRequest.end();
  });
}

function wrapUpstreamResponse(response) {
  return {
    status: response.statusCode ?? 502,
    headers: {
      get(name) {
        const value = response.headers[name.toLowerCase()];
        if (Array.isArray(value)) return value.join(', ');
        return value?.toString() ?? null;
      },
    },
    body: response,
    async text() {
      const value = await readStreamBody(response, maxPlaylistBytes);
      return value.toString('utf8');
    },
  };
}

async function readStreamBody(stream, maxBytes) {
  const chunks = [];
  let size = 0;
  for await (const chunk of stream) {
    size += chunk.length;
    if (size > maxBytes) {
      stream.destroy();
      throw new ProxyError(413, 'Upstream response exceeds the allowed size');
    }
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
}

export function headersForRedirect(headers, current, next) {
  if (current.origin === next.origin) return { ...headers };
  return Object.fromEntries(
    Object.entries(headers).filter(([name]) =>
      !isOriginBoundSessionHeader(name)
    ),
  );
}

export function sourceHeadersForRedirect(headers, current, next) {
  if (current.origin === next.origin) return { ...headers };
  const safeNames = new Set([
    'accept',
    'accept-language',
    'accept-encoding',
    'user-agent',
  ]);
  return Object.fromEntries(
    Object.entries(headers).filter(([name]) =>
      safeNames.has(name.toLowerCase())
    ),
  );
}

export async function ensurePublicAddress(
  url,
  addressList = blockedAddresses,
) {
  const host = stripIpv6Brackets(url.hostname);
  const family = isIP(host);
  // Clash fake-IP addresses are meaningful only as DNS answers for a hostname.
  // Never let a caller target the synthetic address range as a literal IP.
  if (family === 4 && isSyntheticDnsIpv4(host)) {
    throw new ProxyError(400, 'Upstream host uses a reserved synthetic address');
  }
  let addresses;
  try {
    addresses = family
      ? [{ address: host, family }]
      : await lookup(host, { all: true, verbatim: true });
  } catch {
    throw new ProxyError(502, 'Upstream DNS lookup failed');
  }
  if (addresses.length === 0) {
    throw new ProxyError(502, 'Upstream host did not resolve');
  }
  for (const item of addresses) {
    const addressFamily = item.family === 6 ? 'ipv6' : 'ipv4';
    if (
      (item.family === 6 && isIpv4MappedAddress(item.address)) ||
      addressList.check(item.address, addressFamily)
    ) {
      throw new ProxyError(400, 'Upstream host resolves to a blocked address');
    }
  }
  return addresses;
}

export function createBlockedAddressList({ allowSyntheticDns }) {
  const list = new BlockList();
  for (const [network, prefix] of [
    ['0.0.0.0', 8],
    ['10.0.0.0', 8],
    ['100.64.0.0', 10],
    ['127.0.0.0', 8],
    ['169.254.0.0', 16],
    ['172.16.0.0', 12],
    ['192.0.0.0', 24],
    ['192.0.2.0', 24],
    ['192.168.0.0', 16],
    ['198.51.100.0', 24],
    ['203.0.113.0', 24],
    ['224.0.0.0', 4],
    ['240.0.0.0', 4],
  ]) {
    list.addSubnet(network, prefix, 'ipv4');
  }
  if (!allowSyntheticDns) {
    list.addSubnet('198.18.0.0', 15, 'ipv4');
  }
  for (const [network, prefix] of [
    ['::', 128],
    ['::1', 128],
    ['64:ff9b::', 96],
    ['64:ff9b:1::', 48],
    ['100::', 64],
    ['fc00::', 7],
    ['fe80::', 10],
    ['ff00::', 8],
    ['2001::', 23],
    ['2001:db8::', 32],
    ['2002::', 16],
  ]) {
    list.addSubnet(network, prefix, 'ipv6');
  }
  return list;
}

function isIpv4MappedAddress(value) {
  return stripIpv6Brackets(value).toLowerCase().startsWith('::ffff:');
}

function isSyntheticDnsIpv4(value) {
  const parts = value.split('.').map((part) => Number(part));
  return parts.length === 4 &&
    parts[0] === 198 &&
    (parts[1] === 18 || parts[1] === 19) &&
    parts.slice(2).every((part) => Number.isInteger(part) && part >= 0 && part <= 255);
}

function stripIpv6Brackets(value) {
  return value.startsWith('[') && value.endsWith(']')
    ? value.slice(1, -1)
    : value;
}

function isLoopbackBind(value) {
  const normalized = value.trim().toLowerCase();
  return normalized === '127.0.0.1' ||
    normalized === 'localhost' ||
    normalized === '::1' ||
    normalized === '[::1]';
}

export function validateTarget(value) {
  if (!value) return null;
  try {
    const url = new URL(value);
    if (url.protocol !== 'http:' && url.protocol !== 'https:') return null;
    if (url.username || url.password) return null;
    const host = url.hostname.toLowerCase();
    if (
      host === 'localhost' ||
      host === '::1' ||
      host === '0.0.0.0' ||
      host.endsWith('.local') ||
      host.endsWith('.internal')
    ) return null;
    const ipv4 = host.split('.').map((part) => Number(part));
    if (ipv4.length === 4 && ipv4.every((part) => Number.isInteger(part))) {
      const [first, second] = ipv4;
      if (
        first === 0 ||
        first === 10 ||
        first === 127 ||
        first >= 224 ||
        (first === 169 && second === 254) ||
        (first === 172 && second >= 16 && second <= 31) ||
        (first === 192 && second === 168)
      ) return null;
    }
    return url;
  } catch {
    return null;
  }
}

function safeReferer(value) {
  if (!value) return null;
  const url = validateTarget(value);
  return url?.toString() ?? null;
}

export function rewritePlaylist(body, playlistUrl, referer, session) {
  return body
    .split(/\r?\n/)
    .map((line) => {
      const trimmed = line.trim();
      if (!trimmed) return line;
      if (trimmed.startsWith('#')) {
        return line.replace(/URI="([^"]+)"/g, (_, uri) => {
          const absolute = new URL(uri, playlistUrl).toString();
          return `URI="${proxyUrl(absolute, referer, session)}"`;
        });
      }
      return proxyUrl(
        new URL(trimmed, playlistUrl).toString(),
        referer,
        session,
      );
    })
    .join('\n');
}

function proxyUrl(url, referer, session) {
  const query = new URLSearchParams({ url });
  if (referer) query.set('referer', referer);
  if (session) query.set('session', session);
  return `/media-proxy?${query.toString()}`;
}
