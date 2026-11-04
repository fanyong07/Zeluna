"""AniCh 线路池审计:线上抓一集,按 ``anich_hosts`` 判据复算排序,打印家族分布。

用途:每次上游改动后跑一次,确认
  1) 各主机族占比是否漂移(新家族出现 → 需要补进 ``anich_hosts``);
  2) 贴片素材(``/bs2/adVideoLp/`` 一类)是否仍沉在正片之后;
  3) 自建 CDN 是否仍能解出直链。

用法(在 ``server/`` 下):
    uv run python tools/anich_line_audit.py "进击的巨人" "第1集"
    uv run python tools/anich_line_audit.py --json > audit.json

注意:本工具走 ``AniChTransport`` 的串行节流,单次只发 2~3 个请求,
不会触发上游风控。
"""
from __future__ import annotations

import argparse
import asyncio
import json
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from server.scrapers.anime import anich_hosts, anich_proto          # noqa: E402
from server.scrapers.anime.anich import caption_quality, line_rank  # noqa: E402
from server.scrapers.anime.anich_transport import (                 # noqa: E402
    AniChTransport,
)


async def audit(title: str, episode: str) -> dict:
    transport = AniChTransport()
    try:
        eps_raw = await transport.request(f"/vod/episode?title={title}")
        names = json.loads(eps_raw.decode("utf-8"))
        if episode not in names:
            return {"error": f"剧集 {episode!r} 不在 {names[:8]}…"}
        vod_raw = await transport.request(
            f"/vod/get?title={title}&episode={episode}"
        )
        body = bytes(json.loads(vod_raw.decode("utf-8")))
        items = anich_proto.decode_vod(body)
    finally:
        await transport.aclose()

    rows = []
    for item in items:
        try:
            url = anich_proto.decode_variant_base64(item.get("url_raw") or "")
        except ValueError:
            continue
        rows.append({
            "url": url,
            "role": anich_hosts.classify(url).value,
            "tag": anich_hosts.identity_tag(url),
            "latency_band": anich_hosts.latency_band(url),
            "rank": line_rank(url, item.get("caption") or ""),
            "quality": caption_quality(item.get("caption") or ""),
            "caption": item.get("caption") or "",
            "upstream_tag": item.get("source") or "",
        })
    rows.sort(key=lambda r: -r["rank"])
    return {
        "title": title,
        "episode": episode,
        "total": len(rows),
        "families": dict(Counter(r["role"] for r in rows).most_common()),
        "lines": rows,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("title", nargs="?", default="进击的巨人")
    ap.add_argument("episode", nargs="?", default="第1集")
    ap.add_argument("--json", action="store_true", help="输出原始 JSON")
    args = ap.parse_args()

    result = asyncio.run(audit(args.title, args.episode))
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    if "error" in result:
        print(f"失败: {result['error']}")
        return 1

    print(f"\n{result['title']} {result['episode']} —— {result['total']} 条线路")
    print("\n家族分布:")
    for role, count in result["families"].items():
        pct = count / result["total"] * 100
        print(f"   {role:14s} {count:>4}  {pct:5.1f}%")

    print("\n排序后前 10 条(分数高 → 先播):")
    print(f"   {'角色':10s} {'分':>6s} {'带宽':>5s}  {'上游标识':10s} 地址")
    for row in result["lines"][:10]:
        print(f"   {row['role']:10s} {row['rank']:6.1f} {row['latency_band']:5.2f}  "
              f"{row['upstream_tag']:10s} {row['url'][:66]}")

    ads = [r for r in result["lines"] if r["role"] == "ad_creative"]
    reals = [r for r in result["lines"] if r["role"] != "ad_creative"]
    if ads and reals:
        worst_real = min(r["rank"] for r in reals)
        best_ad = max(r["rank"] for r in ads)
        verdict = "通过" if best_ad < worst_real else "!!! 贴片排到了正片前面"
        print(f"\n贴片隔离检查: 贴片最高分 {best_ad:.1f} vs 正片最低分 "
              f"{worst_real:.1f} → {verdict}")
    elif ads:
        print("\n注意: 本次全部线路都是贴片素材(上游数据异常)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())