"""Bounded media diagnostics: manifests <=64 KiB, media sample <=1 KiB.

No playback proxy and no segment is buffered in full. Intended for CLI probes.
"""
from __future__ import annotations

from urllib.parse import urljoin
import httpx

MANIFEST_LIMIT = 64 * 1024
SAMPLE_LIMIT = 1024


async def _read(client: httpx.AsyncClient, url: str, headers: dict, limit: int) -> dict:
    request_headers = {**headers, 'Range': f'bytes=0-{limit - 1}'}
    try:
        async with client.stream('GET', url, headers=request_headers, follow_redirects=True) as response:
            status = response.status_code
            result = {'status': status, 'url': str(response.url), 'bytes_read': 0,
                      'content_type': response.headers.get('content-type', ''), 'body': b''}
            if status not in (200, 206):
                return result
            content_type = result['content_type'].split(';', 1)[0].strip().lower()
            if content_type in ('text/html', 'application/json', 'application/problem+json'):
                return result
            sample = bytearray()
            async for chunk in response.aiter_bytes(chunk_size=1024):
                sample.extend(chunk[:limit - len(sample)])
                # Non-HLS media only needs a 1 KiB sample, even when Range is ignored.
                if len(sample) >= SAMPLE_LIMIT and not bytes(sample).lstrip(b'\xef\xbb\xbf \r\n\t').startswith(b'#EXTM3U'):
                    break
                if len(sample) >= limit:
                    break
            result.update(bytes_read=len(sample), body=bytes(sample))
            return result
    except httpx.HTTPError as error:
        return {'status': 0, 'url': url, 'bytes_read': 0, 'content_type': '',
                'body': b'', 'error': type(error).__name__}


def _kind(body: bytes) -> str:
    sample = body.lstrip(b'\xef\xbb\xbf \r\n\t')
    if sample.startswith(b'#EXTM3U'):
        return 'hls'
    if sample.lower().startswith((b'<html', b'<!doctype', b'{"', b'[{')):
        return 'error-page'
    if len(body) >= 8 and body[4:8] in (b'ftyp', b'styp', b'moof'):
        return 'mp4'
    return 'binary' if body else 'empty'


async def probe_media(client: httpx.AsyncClient, url: str, headers: dict | None = None) -> dict:
    """Follow at most three HLS playlists and sample only the first media URI."""
    hops = []
    headers = dict(headers or {})
    for depth in range(4):
        response = await _read(client, url, headers, MANIFEST_LIMIT if depth < 3 else SAMPLE_LIMIT)
        body = response.pop('body', b'')
        kind = _kind(body)
        response['kind'] = kind
        hops.append(response)
        if response['status'] not in (200, 206):
            return {'ok': False, 'stage': 'http', 'hops': hops}
        if kind != 'hls':
            ok = kind in ('mp4', 'binary')
            return {'ok': ok, 'stage': 'media-sample' if ok else 'non-media', 'hops': hops}
        text = body.decode('utf-8-sig', errors='replace')
        lines = [line.strip() for line in text.splitlines()]
        target = next((line for line in lines if line and not line.startswith('#')), '')
        if not target:
            return {'ok': False, 'stage': 'empty-playlist', 'hops': hops}
        url = urljoin(response['url'], target)
    return {'ok': False, 'stage': 'playlist-depth', 'hops': hops}
