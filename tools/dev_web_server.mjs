import { createServer } from 'node:http';
import { createReadStream, existsSync, statSync } from 'node:fs';
import { extname, join, normalize, resolve } from 'node:path';
import { Readable } from 'node:stream';

const root = resolve(process.cwd(), 'build/web');
const port = Number(process.env.PORT ?? 5174);

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

createServer(async (request, response) => {
  try {
    const requestUrl = new URL(request.url ?? '/', `http://${request.headers.host}`);
    if (requestUrl.pathname === '/media-proxy') {
      await proxyMedia(request, response, requestUrl);
      return;
    }
    if (requestUrl.pathname === '/reset-browser-cache') {
      serveCacheReset(response);
      return;
    }
    serveStatic(requestUrl, response);
  } catch (error) {
    response.writeHead(500, {
      'content-type': 'text/plain; charset=utf-8',
      'cache-control': 'no-store',
    });
    response.end(`anime dev server error: ${error?.message ?? error}`);
  }
}).listen(port, '127.0.0.1', () => {
  console.log(`anime dev web server: http://127.0.0.1:${port}/`);
});

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

async function proxyMedia(request, response, requestUrl) {
  const target = requestUrl.searchParams.get('url');
  const targetUrl = validateTarget(target);
  if (!targetUrl) {
    response.writeHead(400, corsHeaders({ 'content-type': 'text/plain; charset=utf-8' }));
    response.end('Invalid media url');
    return;
  }

  const headers = {
    'user-agent': request.headers['user-agent'] || 'Mozilla/5.0',
    accept: request.headers.accept || '*/*',
    referer: targetUrl.origin,
  };
  if (request.headers.range) headers.range = request.headers.range;

  const upstream = await fetch(targetUrl, {
    headers,
    redirect: 'follow',
  });
  const contentType = upstream.headers.get('content-type') ?? '';
  const isPlaylist =
    contentType.includes('mpegurl') ||
    contentType.includes('application/x-mpegurl') ||
    targetUrl.pathname.toLowerCase().includes('.m3u8');

  if (isPlaylist) {
    const body = await upstream.text();
    response.writeHead(upstream.status, corsHeaders({
      'content-type': 'application/vnd.apple.mpegurl; charset=utf-8',
      'cache-control': 'no-store',
    }));
    response.end(rewritePlaylist(body, targetUrl));
    return;
  }

  const responseHeaders = corsHeaders({
    'content-type': contentType || 'application/octet-stream',
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
  Readable.fromWeb(upstream.body).pipe(response);
}

function corsHeaders(extra) {
  return {
    'access-control-allow-origin': '*',
    'access-control-allow-methods': 'GET,HEAD,OPTIONS',
    'access-control-allow-headers': 'range,content-type,accept,origin',
    ...extra,
  };
}

function validateTarget(value) {
  if (!value) return null;
  try {
    const url = new URL(value);
    if (url.protocol !== 'http:' && url.protocol !== 'https:') return null;
    return url;
  } catch {
    return null;
  }
}

function rewritePlaylist(body, playlistUrl) {
  return body
    .split(/\r?\n/)
    .map((line) => {
      const trimmed = line.trim();
      if (!trimmed) return line;
      if (trimmed.startsWith('#')) {
        return line.replace(/URI="([^"]+)"/g, (_, uri) => {
          const absolute = new URL(uri, playlistUrl).toString();
          return `URI="${proxyUrl(absolute)}"`;
        });
      }
      return proxyUrl(new URL(trimmed, playlistUrl).toString());
    })
    .join('\n');
}

function proxyUrl(url) {
  return `/media-proxy?url=${encodeURIComponent(url)}`;
}
