"""站点发现与验活工具(开发期用,不进运行时)。

运行时的 server 只读 ``scrapers/anime/anime_sites.py`` 这张静态表,不依赖
任何外部搜索服务。本工具负责**产出**那张表所需的事实:

    域名体检 → 搜索可用性 → 取流全链 → 人工审核 → 写进 anime_sites.py

搜索(找同族新域)由部署者自己的搜索服务提供:本工具不内置任何搜索凭据,
只接收一份候选域 JSON。这样谁的配额谁用,也能随时换搜索源。

从 ``server/`` 运行::

    # 1) 全表体检:谁活着、谁变落地页、谁换域了
    python tools/site_discovery.py audit

    # 2) 喂入外部搜索得到的候选域,逐个体检(只有 content 档才值得接)
    python tools/site_discovery.py check-candidates --input candidates.json

    # 3) 对某站验全链(必须用真实作品名——用随机 sid 会把活站误判成死站)
    python tools/site_discovery.py verify-chain --site yhdmm --title 死神

    # 4) 导出脱敏审计结果
    python tools/site_discovery.py audit --output site_audit.json

candidates.json 形态(与常见搜索 API 对齐)::

    [{"url": "https://example.com/", "title": "..."}, ...]
"""

from __future__ import annotations

import argparse
import asyncio
import json
import re
import sys
from pathlib import Path
from urllib.parse import quote, urljoin, urlparse

import httpx

PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from server.scrapers.anime.anime_sites import (  # noqa: E402
    ANIME_DOMAIN_FAMILIES,
    ANIME_SITES,
    site_entry,
)
from server.scrapers.anime.site_base import (  # noqa: E402
    EpisodeCandidate,
    decode_play_url,
    safe_request_url,
    select_episode_candidates,
)
from server.scrapers.domain_watch import DomainWatch, classify_page  # noqa: E402

_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/126.0 Safari/537.36"
)
_PLAY_PATTERNS = (
    r'href="(/v/\d+-\d+-\d+\.html)"',
    r'href="(/vodplay/\d+-\d+-\d+\.html)"',
    r'href="(/play_\d+-\d+-\d+\.html)"',
    r'href="(/playGV\d+-\d+-\d+/)"',
    r'href="(/p/\d+-\d+-\d+\.html)"',
    r'href="(/play/\d+-\d+-\d+\.html)"',
    r'href="(/vod-play/\d+/ep\d+[^"]*)"',
)
_SEARCH_TEMPLATES = (
    "/search.html?wd={kw}",
    "/search/-------------/?wd={kw}",
    "/vodsearch/{kw}----------1---.html",
    "/index.php/vod/search.html?wd={kw}",
)


def _client() -> httpx.AsyncClient:
    return httpx.AsyncClient(
        headers={"User-Agent": _UA, "Accept-Language": "zh-CN,zh;q=0.9"},
        timeout=15,
        follow_redirects=True,
    )


async def cmd_audit(args: argparse.Namespace) -> int:
    """对所有域名族做体检。"""
    async with _client() as client:
        watch = DomainWatch(ANIME_DOMAIN_FAMILIES, client=client)
        report = await watch.audit(args.family)

    rows: list[dict] = []
    print(f"{'域名':<40}{'判定':<12}{'字节':>10}  形态数")
    print("-" * 76)
    for family, verdicts in report.items():
        print(f"\n[族 {family}]")
        for verdict in verdicts:
            host = urlparse(verdict.base).netloc
            print(
                f"  {host:<38}{verdict.kind:<12}{verdict.size:>10}"
                f"  {len(verdict.marks)}"
            )
            rows.append({"family": family, **verdict.as_public_dict()})

    alive = [row for row in rows if row["kind"] == "content"]
    print(f"\ncontent 档 {len(alive)}/{len(rows)}")
    if args.output:
        Path(args.output).write_text(
            json.dumps(
                {"schema_version": 1, "domains": rows},
                ensure_ascii=False,
                indent=2,
            ),
            encoding="utf-8",
        )
        print(f"已写出 {args.output}")
    return 0


async def cmd_check_candidates(args: argparse.Namespace) -> int:
    """对外部搜索给出的候选域逐个体检。

    搜索结果只是**线索**:可能是旧快照、镜像、停放页或 SEO 垃圾页,
    必须实时体检后才可进候选池。
    """
    try:
        payload = json.loads(Path(args.input).read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        print(f"读取候选失败: {error}")
        return 2
    if isinstance(payload, dict):
        payload = payload.get("results") or payload.get("data") or []
    hosts: list[str] = []
    for item in payload if isinstance(payload, list) else []:
        url = (item or {}).get("url") if isinstance(item, dict) else str(item)
        host = urlparse(str(url or "")).netloc
        if host and host not in hosts:
            hosts.append(host)
    if not hosts:
        print("候选文件里没有可用 URL")
        return 2

    known = {
        urlparse(base).netloc
        for bases in ANIME_DOMAIN_FAMILIES.values()
        for base in bases
    }
    print(f"候选 {len(hosts)} 个(其中 {len(set(hosts) & known)} 个已在表内)\n")
    accepted: list[dict] = []
    async with _client() as client:
        watch = DomainWatch(ANIME_DOMAIN_FAMILIES, client=client)
        for host in hosts[: args.limit]:
            verdict = await watch.check(f"https://{host}")
            flag = "OK " if verdict.alive else "   "
            tag = "(已知)" if host in known else ""
            print(
                f"  {flag}{host:<38}{verdict.kind:<12}{verdict.size:>9}B {tag}"
            )
            if verdict.alive and host not in known:
                accepted.append(verdict.as_public_dict())
            await asyncio.sleep(0.4)

    print(f"\n新的 content 档候选 {len(accepted)} 个")
    for row in accepted:
        print(f"  - {row['base']}  ({row['size']}B, {row['mark_count']} 形态)")
    if accepted:
        print(
            "\n下一步:对这些候选跑 verify-chain 确认能真正取到流,"
            "通过后再人工写进 anime_sites.py"
        )
    if args.output:
        Path(args.output).write_text(
            json.dumps(
                {"schema_version": 1, "accepted": accepted},
                ensure_ascii=False,
                indent=2,
            ),
            encoding="utf-8",
        )
    return 0


async def _fetch(client: httpx.AsyncClient, url: str, referer: str = "") -> str:
    headers = {"Referer": referer} if referer else {}
    try:
        response = await client.get(safe_request_url(url), headers=headers)
    except httpx.HTTPError:
        return ""
    return response.text if response.status_code == 200 else ""


async def cmd_verify_chain(args: argparse.Namespace) -> int:
    """对一个站验证 搜索/索引 → 详情 → 播放页 → 解码 → Range 全链。"""
    entry = site_entry(args.site)
    if entry is None:
        print(f"未知站点 {args.site};已登记:"
              f"{', '.join(row['site'] for row in ANIME_SITES)}")
        return 2
    base = (args.base or entry["base"]).rstrip("/")
    detail_pattern = args.detail_pattern or r"/show/(\d+)\.html"
    print(f"站点 {args.site}  base={base}  status={entry['status']}")

    async with _client() as client:
        # 1) 找 sid:先站内搜索,不行再翻首页
        sid = ""
        for template in _SEARCH_TEMPLATES:
            html = await _fetch(
                client, base + template.format(kw=quote(args.title))
            )
            if not html:
                continue
            found = re.findall(detail_pattern, html)
            if found:
                sid, via = found[0], f"搜索 {template.split('?')[0]}"
                break
        if not sid:
            html = await _fetch(client, base + "/")
            found = re.findall(detail_pattern, html or "")
            if not found:
                print("  ✗ 拿不到 sid(搜索与首页都无详情链接)")
                return 1
            sid, via = found[0], "首页(未按关键词命中)"
        print(f"  sid={sid}  来源={via}")

        # 2) 详情页 → 播放页
        detail_url = base + re.sub(r"\(\\d\+\)", sid, detail_pattern).replace("\\", "")
        detail_html = await _fetch(client, detail_url)
        if not detail_html:
            print("  ✗ 详情页不可达")
            return 1
        links: list[str] = []
        for pattern in _PLAY_PATTERNS:
            found = re.findall(pattern, detail_html)
            if found:
                links = list(dict.fromkeys(found))
                break
        if not links:
            print("  ✗ 详情页无已知播放页形态(需为该站单独适配)")
            return 1
        print(f"  播放页 {len(links)} 个")

        # 3) 冗余选集:每条线路各出一个候选
        candidates: list[EpisodeCandidate] = []
        per_line: dict[str, int] = {}
        for path in links:
            parts = re.findall(r"(\d+)", path)
            line_key = parts[1] if len(parts) >= 3 else "1"
            index = per_line.get(line_key, 0)
            per_line[line_key] = index + 1
            candidates.append(
                EpisodeCandidate(
                    line_key=line_key,
                    label=f"第{index + 1}集",
                    page_path=path,
                    index=index,
                )
            )
        selected = select_episode_candidates(candidates, args.episode)
        print(f"  第{args.episode}集候选 {len(selected)} 条(跨 {len(per_line)} 条线路)")

        # 4) 解码 + Range 探测
        playable = 0
        for candidate in selected[: args.max_lines]:
            play_url = urljoin(base + "/", candidate.page_path.lstrip("/"))
            play_html = await _fetch(client, play_url, referer=detail_url)
            config = {}
            for pattern in (
                r"player_aaaa\s*=\s*(\{.*?\})\s*</script>",
                r"player_aaaa\s*=\s*(\{.*?\});",
            ):
                match = re.search(pattern, play_html or "", re.S)
                if match:
                    try:
                        config = json.loads(match.group(1))
                    except ValueError:
                        config = {}
                    break
            media = decode_play_url(
                str(config.get("url") or ""), config.get("encrypt", 0)
            )
            if not media.lower().startswith(("http://", "https://")):
                print(f"    ✗ 线路{candidate.line_key}: 播放页无可用地址")
                continue
            host = urlparse(media).hostname or ""
            try:
                probe = await client.get(
                    safe_request_url(media),
                    headers={"Range": "bytes=0-2047", "Referer": play_url},
                )
                head = probe.content[:2048]
                if head.lstrip().startswith(b"#EXTM3U"):
                    kind = "hls"
                elif b"ftyp" in head[:64]:
                    kind = "mp4"
                elif head.lstrip()[:1] == b"<":
                    kind = "html(非媒体)"
                else:
                    kind = "bin:" + head[:4].hex()
                ok = probe.status_code in (200, 206) and not kind.startswith("html")
                playable += 1 if ok else 0
                print(
                    f"    {'✅' if ok else '❌'} 线路{candidate.line_key}: "
                    f"{kind:<14}HTTP {probe.status_code}  {host}"
                )
            except httpx.HTTPError as error:
                print(f"    ❌ 线路{candidate.line_key}: {type(error).__name__}  {host}")
            await asyncio.sleep(0.6)

    verdict = (
        "ok" if playable else ("parsed-dead" if selected else "dead")
    )
    print(f"\n判定:{verdict}(可播 {playable}/{len(selected[: args.max_lines])})")
    if verdict == "parsed-dead":
        print("  解析链路通但货源不可达 —— 保留解析器,等货源恢复即可复活")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    audit = sub.add_parser("audit", help="域名族体检")
    audit.add_argument("--family", help="只查某个族")
    audit.add_argument("--output", help="写出脱敏 JSON")
    audit.set_defaults(handler=cmd_audit)

    cand = sub.add_parser("check-candidates", help="体检外部搜索给出的候选域")
    cand.add_argument("--input", required=True, help="候选 JSON 文件")
    cand.add_argument("--limit", type=int, default=12)
    cand.add_argument("--output", help="写出通过体检的候选")
    cand.set_defaults(handler=cmd_check_candidates)

    chain = sub.add_parser("verify-chain", help="对某站验全链")
    chain.add_argument("--site", required=True)
    chain.add_argument("--title", required=True, help="真实作品名(勿用随机 sid)")
    chain.add_argument("--episode", type=int, default=1)
    chain.add_argument("--base", help="覆盖基址")
    chain.add_argument("--detail-pattern", help=r"详情链接正则,如 /vod_(\d+)\.html")
    chain.add_argument("--max-lines", type=int, default=4)
    chain.set_defaults(handler=cmd_verify_chain)

    args = parser.parse_args()
    try:
        return asyncio.run(args.handler(args))
    except KeyboardInterrupt:  # pragma: no cover
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
