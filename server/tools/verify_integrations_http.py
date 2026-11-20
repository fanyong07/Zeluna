"""Production GET verification, plus bounded client-to-origin samples.

Run on the VPS as the service user or locally with --base URL. Signed playback
URLs are used in memory only; reports keep hosts/status/byte counts, not secrets.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote, urlparse

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import httpx
from tools.media_sample import probe_media


async def get_json(client, base, path, *, params=None):
    start = time.monotonic()
    response = await client.get(base.rstrip('/') + path, params=params)
    response.raise_for_status()
    return response.json(), {'status': response.status_code, 'seconds': round(time.monotonic() - start, 3)}


def summarize_lines(lines):
    values = [item for item in lines if isinstance(item, dict) and item.get('url')]
    hosts = sorted({urlparse(item['url']).hostname for item in values})
    wrappers = [item for item in values if any(token in (urlparse(item['url']).hostname or '') for token in ('emmmm.eu.org', 'sends.eu.org'))]
    private = [item for item in values if urlparse(item['url']).hostname in ('127.0.0.1', 'localhost', '::1')]
    proxy = [item for item in values if '/media/' in urlparse(item['url']).path and urlparse(item['url']).hostname in ('api.zeluna.top', '127.0.0.1')]
    leaks = [item for item in values if any('anich' in str(item.get(key, '')).lower() for key in ('source', 'provider_name', 'provider_id', 'tag'))]
    return {'lines': len(values), 'cached': sum(bool(item.get('cached')) for item in values),
            'hosts': hosts, 'wrappers': len(wrappers), 'private_urls': len(private),
            'media_proxy_urls': len(proxy), 'internal_label_leaks': len(leaks),
            'private_cache_keys': sum('_resolved_wrap_url' in item for item in lines)}


def redact_probe(probe):
    return {**probe, 'hops': [{key: value for key, value in hop.items() if key != 'url'} |
        {'host': urlparse(hop.get('url', '')).hostname} for hop in probe.get('hops', [])]}


def acceptance_checks(checks, *, no_animeko_vod=False, stable_requested=False):
    """Require nonempty metadata/routes and explicit no-proxy/no-leak evidence."""
    problems = []
    if not checks.get('providers_enabled', {}).get('ok'):
        problems.append('providers-disabled')
    for name in ('anich_episodes', 'animeko_episodes', 'kazumi_episodes'):
        if not checks.get(name, {}).get('count', 0):
            problems.append(name + '-empty')
    names = ['anich_vod', 'anich_cached_vod']
    if not no_animeko_vod:
        names.append('animeko_vod')
    if stable_requested:
        names.append('stable_v3')
    for name in names:
        value = checks.get(name, {})
        if value.get('lines', 0) <= 0:
            problems.append(name + '-empty')
        for field in ('wrappers', 'private_urls', 'media_proxy_urls', 'internal_label_leaks', 'private_cache_keys'):
            if field not in value or value[field] != 0:
                problems.append(name + '-' + field)
    if not checks.get('anich_cached_vod', {}).get('cached', 0):
        problems.append('anich-cache-not-hit')
    if not checks.get('kazumi_no_playback', {}).get('ok'):
        problems.append('kazumi-returned-media')
    if not checks.get('anich_media_sample', {}).get('ok'):
        problems.append('anich-media-sample')
    if not no_animeko_vod and not checks.get('animeko_media_sample', {}).get('ok'):
        problems.append('animeko-media-sample')
    return problems


async def main(args):
    report = {'generated_at': datetime.now(timezone.utc).isoformat(), 'base': args.base, 'checks': {}}
    async with httpx.AsyncClient(timeout=httpx.Timeout(75, connect=12), trust_env=False, follow_redirects=True) as client:
        status, meta = await get_json(client, args.base, '/api/v3/status')
        report['checks']['status'] = {**meta, 'enabled_ids': status.get('playback_providers', {}).get('enabled_ids', [])}
        enabled = set(report['checks']['status']['enabled_ids'])
        report['checks']['providers_enabled'] = {'ok': {'crawler.anich', 'crawler.animeko', 'crawler.kazumi'} <= enabled}
        episodes, meta = await get_json(client, args.base, '/api/v2/episodes/crawler:anich:32564')
        report['checks']['anich_episodes'] = {**meta, 'count': len(episodes)}
        lines, meta = await get_json(client, args.base, '/api/v2/vod/crawler:anich:32564', params={'episode': 1})
        report['checks']['anich_vod'] = {**meta, **summarize_lines(lines)}
        again, meta = await get_json(client, args.base, '/api/v2/vod/crawler:anich:32564', params={'episode': 1})
        report['checks']['anich_cached_vod'] = {**meta, **summarize_lines(again)}
        subject = 'crawler:animeko:girigiri-ai-dongman|https://bg.girigirilove.com/GV25524/'
        episodes, meta = await get_json(client, args.base, '/api/v2/episodes/' + quote(subject, safe=':|/'))
        report['checks']['animeko_episodes'] = {**meta, 'count': len(episodes)}
        if not args.no_animeko_vod:
            media, meta = await get_json(client, args.base, '/api/v2/vod/' + quote(subject, safe=':|/'), params={'episode': 1})
            report['checks']['animeko_vod'] = {**meta, **summarize_lines(media)}
            if media:
                sample = await probe_media(client, media[0]['url'], media[0].get('headers', {}))
                report['checks']['animeko_media_sample'] = redact_probe(sample)
        subject = 'crawler:kazumi:akianime::https://www.akianime.cc/bgmplay/dPDDDE-1-1.html'
        episodes, meta = await get_json(client, args.base, '/api/v2/episodes/' + quote(subject, safe=':/'))
        report['checks']['kazumi_episodes'] = {**meta, 'count': len(episodes), 'first_titles': [item.get('title', '') for item in episodes[:3]]}
        media, meta = await get_json(client, args.base, '/api/v2/vod/' + quote(subject, safe=':/'), params={'episode': 1})
        report['checks']['kazumi_no_playback'] = {**meta, 'lines': len(media), 'ok': len(media) == 0}
        # Prefer a resolver-produced byte CDN destination instead of an arbitrary source.
        samples = [item for item in again if item.get('url') and any(token in (urlparse(item['url']).hostname or '') for token in ('bytecdn.com', 'byteimg.com'))]
        if samples:
            sample = await probe_media(client, samples[0]['url'], samples[0].get('headers', {}))
            report['checks']['anich_media_sample'] = redact_probe(sample)
        if args.stable_id:
            data, meta = await get_json(client, args.base, '/api/v3/playback/' + quote(args.stable_id, safe=':'), params={'episode': 1, 'title': args.title, 'content_type': 'anime'})
            report['checks']['stable_v3'] = {**meta, **summarize_lines(data)}
    failures = acceptance_checks(report['checks'], no_animeko_vod=args.no_animeko_vod, stable_requested=bool(args.stable_id))
    report['acceptance'] = {'ok': not failures, 'failures': failures}
    text = json.dumps(report, ensure_ascii=False, indent=2)
    if args.output:
        Path(args.output).write_text(text, encoding='utf-8')
    print(text)
    return 0 if not failures else 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', default='http://127.0.0.1:8000')
    parser.add_argument('--output', default='')
    parser.add_argument('--stable-id', default='')
    parser.add_argument('--title', default='')
    parser.add_argument('--no-animeko-vod', action='store_true')
    raise SystemExit(asyncio.run(main(parser.parse_args())))
