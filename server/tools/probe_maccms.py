"""
MacCMS 采集站实测脚本 —— 三层验证候选源是否真能播。

对每个候选站依次测：
  1. 搜索 (ac=detail&wd=关键词) 是否返回条目
  2. 详情 (ac=detail&ids=vod_id) 是否带 vod_play_url
  3. 首集 m3u8 是否真实可达 (GET 首字节须为 #EXTM3U)

用多个关键词(番剧/剧/电影)覆盖不同内容类型，任一关键词跑通即算通过，
并记录该站命中的内容类型，便于判断它偏动漫还是综合。

用法(在 server/ 目录下)：
    python tools/probe_maccms.py

VPS 才是权威环境(洛杉矶出口)，上线前建议在 VPS 上重跑本脚本再定权重。
"""

import asyncio
import re
import sys
import time
from pathlib import Path
from urllib.parse import urljoin

import httpx

PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

# 默认实测「当前生产清单」里的全部站点——在 VPS 上直接跑，即可看清
# 每个已部署站点从本机出口的真实可播情况(哪个跑不通就从清单删掉)。
# 想额外考察新候选，把 {"name","api"} 追加到 EXTRA_CANDIDATES 即可。
try:
    from server.scrapers.maccms_sites import MACCMS_SITES
    _PRODUCTION = [{"name": s["name"], "api": s["api"]} for s in MACCMS_SITES]
except Exception:  # 允许在 server/ 之外独立运行
    _PRODUCTION = []

EXTRA_CANDIDATES: list[dict] = [
    # {"name": "示例", "api": "https://example.com/api.php/provide/vod"},
]

CANDIDATES: list[dict] = _PRODUCTION + EXTRA_CANDIDATES

# 番剧 / 国产剧 / 电影 各一，覆盖不同内容类型。逐类验证真实可播，不提前退出。
KEYWORDS = [("番剧", "斗罗大陆"), ("剧集", "庆余年"), ("电影", "流浪地球")]

_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/124.0.0.0 Safari/537.36"
)


def parse_first_m3u8(raw: str) -> str:
    """从 vod_play_url 取第一个播放源的第一集 m3u8 地址。"""
    if not raw:
        return ""
    for group in raw.split("$$$"):
        for seg in group.split("#"):
            seg = seg.strip()
            url = seg.partition("$")[2].strip() if "$" in seg else seg.strip()
            if url.lower().startswith(("http://", "https://")) and "m3u8" in url.lower():
                return url
    return ""


async def _m3u8_reachable(client: httpx.AsyncClient, url: str) -> bool:
    try:
        response = await client.get(
            url, headers={"User-Agent": _UA, "Range": "bytes=0-16383"}
        )
        if response.status_code >= 400:
            return False
        text = response.text.lstrip()
        if not text.startswith("#EXTM3U"):
            return False
        references = [
            line.strip()
            for line in text.splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        ]
        if not references:
            return False
        media_url = urljoin(str(response.url), references[0])
        if "#EXT-X-STREAM-INF" in text:
            child = await client.get(
                media_url,
                headers={"User-Agent": _UA, "Range": "bytes=0-16383"},
            )
            child_text = child.text.lstrip()
            if child.status_code >= 400 or not child_text.startswith("#EXTM3U"):
                return False
            references = [
                line.strip()
                for line in child_text.splitlines()
                if line.strip() and not line.lstrip().startswith("#")
            ]
            if not references:
                return False
            media_url = urljoin(str(child.url), references[0])
        segment = await client.get(
            media_url,
            headers={"User-Agent": _UA, "Range": "bytes=0-2047"},
        )
        return segment.status_code < 400 and bool(segment.content)
    except Exception:
        return False


async def probe_site(site: dict) -> dict:
    result = {
        "name": site["name"],
        "api": site["api"],
        "search": False,
        "detail": False,
        "playable": set(),   # 真实可播的内容类别（番剧/剧集/电影）
        "latency": 0.0,
        "note": "",
    }
    started = time.monotonic()
    async with httpx.AsyncClient(
        headers={"User-Agent": _UA, "Accept": "application/json, */*"},
        timeout=httpx.Timeout(20, connect=8),
        follow_redirects=True,
        trust_env=False,  # 直连，模拟 VPS，不走本机代理
    ) as client:
        for label, keyword in KEYWORDS:
            try:
                resp = await client.get(
                    site["api"], params={"ac": "detail", "wd": keyword}
                )
                if resp.status_code != 200:
                    result["note"] = f"HTTP {resp.status_code}"
                    continue
                data = resp.json()
            except Exception as error:
                result["note"] = type(error).__name__
                continue
            items = data.get("list", []) if isinstance(data, dict) else []
            if not items:
                continue
            result["search"] = True
            # 找该关键词下第一个可播的条目
            for it in items[:6]:
                raw = it.get("vod_play_url", "") or ""
                if not raw:
                    vid = str(it.get("vod_id", ""))
                    if not vid:
                        continue
                    try:
                        d = await client.get(
                            site["api"], params={"ac": "detail", "ids": vid}
                        )
                        raw = (d.json().get("list", [{}])[0].get("vod_play_url", "")
                               if d.status_code == 200 else "")
                    except Exception:
                        raw = ""
                if raw:
                    result["detail"] = True
                    m3u8 = parse_first_m3u8(raw)
                    if m3u8 and await _m3u8_reachable(client, m3u8):
                        result["playable"].add(label)
                        break
    result["latency"] = round(time.monotonic() - started, 1)
    return result


async def main() -> None:
    print(f"实测 {len(CANDIDATES)} 个候选站，逐类验证："
          f"{[k for k, _ in KEYWORDS]}\n")
    sem = asyncio.Semaphore(8)

    async def run(site):
        async with sem:
            return await probe_site(site)

    results = await asyncio.gather(*(run(s) for s in CANDIDATES))
    results.sort(key=lambda r: (len(r["playable"]), r["detail"], r["search"]),
                 reverse=True)

    print(f"{'站点':<8} {'搜索':<4} {'详情':<4} {'可播内容类型':<16} {'耗时':<7} 备注")
    print("-" * 74)
    passed = []
    for r in results:
        flag = lambda b: "✓" if b else "·"
        play = "/".join(k for k, _ in KEYWORDS if k in r["playable"]) or "—"
        tail = "" if r["search"] else (r["note"] or "无结果")
        print(f"{r['name']:<8} {flag(r['search']):<4} {flag(r['detail']):<4} "
              f"{play:<16} {str(r['latency'])+'s':<7} {tail}")
        if r["playable"]:
            passed.append(r)

    print(f"\n至少一类真实可播的站点：{len(passed)} 个")
    print("-" * 74)
    for i, r in enumerate(passed):
        weight = max(70, 100 - i * 3)
        cover = len(r["playable"])
        # 覆盖三类且够快的进预爬
        precache = "True" if (cover == 3 and r["latency"] < 15 and i < 8) else "False"
        print(f'    {{"name": "{r["name"]}", "api": "{r["api"]}", '
              f'"weight": {weight}, "precache": {precache}}},  # 可播:'
              f'{"/".join(k for k, _ in KEYWORDS if k in r["playable"])}')


if __name__ == "__main__":
    asyncio.run(main())
