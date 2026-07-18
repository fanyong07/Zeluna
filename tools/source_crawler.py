#!/usr/bin/env python3
"""
Anime 视频源爬虫 — 从多个仓库发现、验证、导出可用的视频源配置。

使用方式:
  python tools/source_crawler.py              # 完整爬取并验证
  python tools/source_crawler.py --quick       # 仅爬取，不验证
  python tools/source_crawler.py --output sources.json  # 自定义输出路径
"""

import json
import re
import sys
import time
import hashlib
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from urllib.parse import urljoin, urlparse, parse_qs
from dataclasses import dataclass, field
from typing import Optional

# ---------------------------------------------------------------------------
# 最小化依赖：优先使用标准库，可选 httpx 加速
# ---------------------------------------------------------------------------
try:
    import httpx as _http

    _HTTPX = True
except ImportError:
    import urllib.request
    import ssl

    _HTTPX = False


def _http_get(url: str, timeout: int = 12, headers: dict | None = None) -> str | None:
    """GET 请求，失败返回 None."""
    default_headers = {
        "User-Agent": (
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
            "AppleWebKit/537.36 (KHTML, like Gecko) "
            "Chrome/124.0 Safari/537.36"
        ),
        "Accept": "application/json, text/plain, */*",
    }
    if headers:
        default_headers.update(headers)
    try:
        if _HTTPX:
            client = _http.Client(timeout=_http.Timeout(timeout), follow_redirects=True)
            resp = client.get(url, headers=default_headers)
            if resp.status_code < 200 or resp.status_code >= 500:
                return None
            return resp.text
        else:
            req = urllib.request.Request(url, headers=default_headers)
            ctx = ssl.create_default_context()
            resp = urllib.request.urlopen(req, timeout=timeout, context=ctx)
            return resp.read().decode("utf-8", errors="replace")
    except Exception:
        return None


def _json_get(url: str, timeout: int = 10) -> dict | list | None:
    text = _http_get(url, timeout=timeout)
    if text is None:
        return None
    try:
        return json.loads(text)
    except (json.JSONDecodeError, ValueError):
        return None


# ---------------------------------------------------------------------------
# 数据模型
# ---------------------------------------------------------------------------
@dataclass
class VideoSource:
    id: str
    name: str
    kind: str  # kazumiRule | tvBox | appleCms | liveM3u | anichApi | genericJson
    import_url: str | None = None
    base_url: str | None = None
    endpoints: dict = field(default_factory=dict)
    headers: dict = field(default_factory=dict)
    tags: list = field(default_factory=list)
    version: str | None = None
    license_: str | None = None
    author: str | None = None
    supports_danmaku: bool = False
    supports_search: bool = True
    supports_categories: bool = True
    uses_native_player: bool = True
    anti_crawler: bool = False
    executable_unsupported: bool = False
    enabled: bool = True
    health: str = "unknown"
    message: str | None = None
    raw_config: dict = field(default_factory=dict)
    updated_at: int = 0

    def to_app_json(self) -> dict:
        """转换为 anime 应用的 VideoSource.fromJson 格式."""
        return {
            "id": self.id,
            "name": self.name,
            "kind": self.kind,
            "importUrl": self.import_url,
            "baseUrl": self.base_url,
            "endpoints": self.endpoints,
            "headers": self.headers,
            "tags": self.tags,
            "version": self.version,
            "license": self.license_,
            "author": self.author,
            "supportsDanmaku": self.supports_danmaku,
            "supportsSearch": self.supports_search,
            "supportsCategories": self.supports_categories,
            "usesNativePlayer": self.uses_native_player,
            "antiCrawlerEnabled": self.anti_crawler,
            "executableUnsupported": self.executable_unsupported,
            "enabled": self.enabled,
            "health": self.health,
            "message": self.message,
            "rawConfig": self.raw_config,
            "updatedAt": _iso8601(self.updated_at),
        }


def _iso8601(ts: int) -> str:
    from datetime import datetime, timezone

    if ts <= 0:
        return "1970-01-01T00:00:00.000Z"
    return datetime.fromtimestamp(ts, tz=timezone.utc).isoformat()


def _stable_id(raw: str) -> str:
    return (
        hashlib.sha256(raw.encode("utf-8"))
        .digest()
        .hex()[:24]
    )


_SENSITIVE_CONFIG_KEYS = {
    "authorization",
    "cookie",
    "cookies",
    "password",
    "passwd",
    "token",
    "access_token",
    "refresh_token",
    "api_key",
    "apikey",
    "secret",
    "client_secret",
}


def _sanitize_raw_config(value):
    """递归清理抓取配置中的账号凭据，避免写入仓库。"""
    if isinstance(value, dict):
        sanitized = {}
        for key, item in value.items():
            normalized = str(key).strip().lower()
            if normalized in _SENSITIVE_CONFIG_KEYS:
                text = item.strip() if isinstance(item, str) else ""
                sanitized[key] = (
                    text
                    if text.startswith(("http://127.0.0.1", "http://localhost"))
                    else ""
                )
            else:
                sanitized[key] = _sanitize_raw_config(item)
        return sanitized
    if isinstance(value, list):
        return [_sanitize_raw_config(item) for item in value]
    return value


# ---------------------------------------------------------------------------
# 仓库发现
# ---------------------------------------------------------------------------

# 已知的高质量 TVBox 仓库
TVBOX_REPOS = [
    "Predidit/KazumiRules",          # 主力 Kazumi 规则库
    "gaotianliuyun/gao",             # FongMi 仓库
    "qist/tvbox",                    # qist 仓库
    "FongMi/Release",                # FongMi 官方发布
    "takagen99/Box",                 # takagen99
    "mlabalabala/TVBox",             # mlabalabala
    "hutool/tvbox",                  # hutool
    "o0HalfLife0o/TVBoxOSC",        # TVBox OSC
    "xlc520/MaoTV",                  # MaoTV
    "2hacc/TVBox",                   # 2hacc
    "whyour/qinglong",               # qinglong
    "ssili126/tv",                   # ssili126
    "JingYiJun/IPTV",               # IPTV
]

# 额外的独立 TVBox JSON API 端点
KNOWN_TVBOX_APIS = [
    # FongMi 系列
    "https://raw.githubusercontent.com/gaotianliuyun/gao/master/0821.json",
    "https://raw.githubusercontent.com/gaotianliuyun/gao/master/0826.json",
    "https://raw.githubusercontent.com/gaotianliuyun/gao/master/XYQ.json",
    # qist 系列
    "https://raw.githubusercontent.com/qist/tvbox/master/0821.json",
    "https://raw.githubusercontent.com/qist/tvbox/master/0826.json",
    "https://raw.githubusercontent.com/qist/tvbox/master/0827.json",
    "https://raw.githubusercontent.com/qist/tvbox/master/dianshi.json",
    # IPTV
    "https://raw.githubusercontent.com/dongyubin/IPTV/main/iptv.m3u",
    "https://raw.githubusercontent.com/YanG-1989/m3u/main/Gather.m3u",
    "https://raw.githubusercontent.com/fanmingming/live/main/tv/m3u/ipv6.m3u",
    # 其他
    "https://raw.githubusercontent.com/Zhou-Li-Bin/Tvbox-QingNing/main/QingNing.json",
    "https://raw.githubusercontent.com/Newtxin/TVBoxSource/main/tvbox.json",
]


def _search_github_code(
    keyword: str, token: str = "", per_page: int = 30
) -> list[dict]:
    """搜索 GitHub 代码."""
    results = []
    for page in range(1, 4):
        url = (
            f"https://api.github.com/search/code"
            f"?q={keyword}+extension:json+repo:Predidit/KazumiRules"
            f"&per_page={per_page}&page={page}"
        )
        headers = {"Accept": "application/vnd.github+json"}
        if token:
            headers["Authorization"] = f"Bearer {token}"
        data = _json_get(url, timeout=15)
        if data is None:
            break
        items = data.get("items", []) if isinstance(data, dict) else []
        if not items:
            break
        results.extend(items)
        time.sleep(1.5)
    return results


def _raw_url_from_item(item: dict) -> str | None:
    html = item.get("html_url", "")
    p = urlparse(html)
    if p.hostname != "github.com":
        return None
    parts = p.path.strip("/").split("/")
    if len(parts) < 5 or parts[2] != "blob":
        return None
    owner, repo, _, branch = parts[0], parts[1], parts[2], parts[3]
    path = "/".join(parts[4:])
    return f"https://raw.githubusercontent.com/{owner}/{repo}/{branch}/{path}"


# ---------------------------------------------------------------------------
# 解析器：从原始 JSON/文本中提取 VideoSource
# ---------------------------------------------------------------------------
def parse_m3u(text: str, import_url: str | None = None) -> VideoSource | None:
    """解析 M3U 直播源."""
    if not text.startswith("#EXTM3U") and not (
        import_url and import_url.lower().endswith((".m3u", ".m3u8"))
    ):
        return None
    groups: set[str] = set()
    channels = 0
    for line in text.splitlines()[:3000]:
        if line.startswith("#EXTINF"):
            channels += 1
            m = re.search(r'group-title="([^"]+)"', line)
            if m:
                groups.add(m.group(1).strip())
    name = Path(import_url or "live.m3u").stem if import_url else "M3U 直播源"
    tags = ["直播", "IPTV", "M3U"]
    if any("动漫" in g for g in groups):
        tags.append("动漫")
    if any("电影" in g for g in groups):
        tags.append("电影")
    tags.append(f"{channels} 个频道")
    return VideoSource(
        id=f"m3u:{_stable_id(import_url or text[:200])}",
        name=name,
        kind="liveM3u",
        import_url=import_url,
        base_url=import_url,
        tags=tags,
        supports_search=True,
        supports_categories=False,
        enabled=channels > 0,
        health="offline" if channels == 0 else "unknown",
        message=f"M3U 直播源，{channels} 个频道，{len(groups)} 个分组",
        raw_config={
            "format": "m3u",
            "groups": sorted(groups)[:40],
            "channelCount": channels,
        },
        updated_at=int(time.time()),
    )


def parse_kazumi_rule(raw: dict, import_url: str | None = None) -> VideoSource | None:
    """解析单条 Kazumi XPath 规则."""
    name = raw.get("name")
    if not name:
        return None
    has_rule_shape = bool(
        raw.get("searchUrl")
        or raw.get("searchURL")
        or raw.get("searchList")
        or raw.get("episodeList")
        or raw.get("chapterRoads")
    )
    if not has_rule_shape:
        return None
    anti = raw.get("antiCrawlerEnabled", False)
    return VideoSource(
        id=f"kazumi-rule:{_stable_id(f'{name}:{import_url or ""}')}",
        name=str(name),
        kind="kazumiRule",
        import_url=import_url,
        base_url=raw.get("baseUrl") or raw.get("baseURL"),
        endpoints={
            k: raw[k]
            for k in ("baseUrl", "baseURL", "searchUrl", "searchURL")
            if k in raw
        },
        tags=["动漫", "XPath", "KazumiRules"]
        + (["captcha"] if anti else []),
        version=str(raw.get("version", "")),
        author=str(raw.get("author", "")),
        anti_crawler=bool(anti),
        uses_native_player=raw.get("useNativePlayer", True),
        message=(
            "带验证码/反爬标记" if anti else "Kazumi XPath 规则"
        ),
        raw_config=_sanitize_raw_config(raw),
        updated_at=int(time.time()),
    )


def parse_tvbox_config(raw: dict, import_url: str | None = None) -> VideoSource | None:
    """解析 TVBox 多站点配置."""
    sites = raw.get("sites", [])
    if not isinstance(sites, list):
        sites = []
    static_count = sum(
        1
        for s in sites
        if isinstance(s, dict)
        and _is_static_tvbox_site(s.get("api", ""))
    )
    if static_count == 0 and not raw.get("spider"):
        return None
    name = raw.get("name") or (Path(import_url).stem if import_url else "TVBox 配置")
    return VideoSource(
        id=f"tvbox:{_stable_id(import_url or json.dumps(raw, sort_keys=True)[:200])}",
        name=str(name),
        kind="tvBox",
        import_url=import_url,
        base_url=import_url,
        tags=_infer_tvbox_tags(raw, static_count),
        supports_search=static_count > 0,
        supports_categories=False,
        message=f"TVBox 配置，{static_count} 个可解析静态站点",
        raw_config=_sanitize_raw_config(raw),
        updated_at=int(time.time()),
    )


def parse_apple_cms(raw: dict, import_url: str | None = None) -> VideoSource | None:
    """解析 AppleCMS JSON API 配置."""
    api = raw.get("api") or raw.get("url") or raw.get("baseUrl")
    if not api:
        return None
    api = str(api)
    looks_like = (
        "ac=" in api
        or "/api.php" in api
        or "classes" in raw
        or "list" in raw
    )
    if not looks_like:
        return None
    name = raw.get("name") or "AppleCMS 源"
    return VideoSource(
        id=f"applecms:{_stable_id(api)}",
        name=str(name),
        kind="appleCms",
        import_url=import_url,
        base_url=api,
        endpoints={"api": api},
        tags=["影视", "AppleCMS"],
        message="AppleCMS JSON API",
        raw_config=_sanitize_raw_config(raw),
        updated_at=int(time.time()),
    )


def parse_anich(raw: dict, import_url: str | None = None) -> VideoSource | None:
    """解析 AniCh API 配置."""
    if "apis" not in raw or "baseUrl" not in raw:
        return None
    apis = [str(a) for a in (raw.get("apis") or [])]
    base = str(raw["baseUrl"])
    endpoints = {"baseUrl": base}
    for key in ("bilibiliApiUrl", "qqVideoApiUrl", "updateUrl", "githubProxyUrl"):
        if raw.get(key):
            endpoints[key] = str(raw[key])
    return VideoSource(
        id=f"anich:{_stable_id(f'{base}:{import_url or ""}')}",
        name="AniCh API",
        kind="anichApi",
        import_url=import_url,
        base_url=base,
        endpoints=endpoints,
        tags=["动漫", "弹幕", "API"],
        supports_danmaku=True,
        message="AniCh 风格 API",
        raw_config=_sanitize_raw_config(raw),
        updated_at=int(time.time()),
    )


def _is_static_tvbox_site(api: str) -> bool:
    api_l = api.lower()
    return (
        api_l.startswith("http")
        and any(
            kw in api_l
            for kw in (
                "api.php",
                "provide/vod",
                "ac=list",
                "ac=detail",
                "/at/xml",
            )
        )
    )


def _infer_tvbox_tags(raw: dict, static_count: int) -> list[str]:
    text = json.dumps(raw, ensure_ascii=False).lower()
    tags = ["TVBox"]
    if "动漫" in text or "anime" in text or "bangumi" in text:
        tags.append("动漫")
    if "直播" in text or "iptv" in text or "live" in text:
        tags.append("直播")
    if "电影" in text or "movie" in text:
        tags.append("电影")
    if "剧" in text or "drama" in text:
        tags.append("影视剧")
    if not any(t in {"动漫", "直播", "电影", "影视剧"} for t in tags):
        tags.append("影视综合")
    if "gaotianliuyun" in text:
        tags.append("FongMi")
    if "qist" in text:
        tags.append("qist")
    tags.append(f"{static_count} 个站点")
    return tags


def smart_parse(raw: dict | list | str, import_url: str | None = None) -> list[VideoSource]:
    """智能解析任意格式为 VideoSource 列表."""
    results: list[VideoSource] = []

    if isinstance(raw, str):
        m3u = parse_m3u(raw, import_url)
        if m3u:
            return [m3u]
        try:
            raw = json.loads(raw)
        except (json.JSONDecodeError, ValueError):
            return []

    if isinstance(raw, list):
        for item in raw:
            if isinstance(item, dict):
                results.extend(smart_parse(item, import_url))
        return results

    if not isinstance(raw, dict):
        return []

    # KazumiRules 索引: {"value": [...]}
    value = raw.get("value")
    if isinstance(value, list):
        for entry in value:
            if isinstance(entry, dict) and entry.get("name"):
                rule_url = None
                if import_url:
                    base = urljoin(import_url, ".")
                    rule_url = urljoin(base, f"{entry['name']}.json")
                rule = parse_kazumi_rule(entry, rule_url)
                if rule:
                    results.append(rule)
        if results:
            return results

    # 按优先级尝试解析
    for parser in (parse_anich, parse_tvbox_config, parse_apple_cms, parse_kazumi_rule):
        source = parser(raw, import_url)
        if source:
            return [source]

    # 兜底：通用 JSON 源
    if raw.get("name") or raw.get("baseUrl") or raw.get("url"):
        name = str(raw.get("name") or raw.get("title") or raw.get("baseUrl") or raw.get("url") or "未知")
        return [
            VideoSource(
                id=f"generic:{_stable_id(f'{name}:{import_url or ""}')}",
                name=name,
                kind="genericJson",
                import_url=import_url,
                base_url=raw.get("baseUrl") or raw.get("url"),
                tags=["自定义"],
                message="通用 JSON 源，需扩展适配",
                raw_config=_sanitize_raw_config(raw),
                updated_at=int(time.time()),
            )
        ]

    return []


# ---------------------------------------------------------------------------
# 健康检查
# ---------------------------------------------------------------------------
def _is_api_reachable(url: str, timeout: int = 8) -> bool:
    """简单检查 API 是否可达."""
    text = _http_get(url, timeout=timeout)
    return text is not None and len(text) > 10


def health_check(source: VideoSource) -> VideoSource:
    """对单个源执行健康检查，返回更新后的源."""
    urls_to_check: list[str] = []
    if source.base_url:
        urls_to_check.append(source.base_url)
    if source.import_url:
        urls_to_check.append(source.import_url)
    for ep in source.endpoints.values():
        if ep.startswith("http"):
            urls_to_check.append(ep)

    for url in urls_to_check[:3]:
        if _is_api_reachable(url):
            source.health = "available"
            source.message = (source.message or "") + " [可达]"
            return source

    source.health = "unavailable"
    source.message = (source.message or "") + " [不可达]"
    return source


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
def crawl_kazumi_rules(token: str = "") -> list[VideoSource]:
    """从 GitHub KazumiRules 仓库爬取规则."""
    print("[crawl] 搜索 KazumiRules...")
    sources: list[VideoSource] = []
    items = _search_github_code("repo:Predidit/KazumiRules extension:json", token)
    for item in items:
        raw_url = _raw_url_from_item(item)
        if not raw_url:
            continue
        data = _json_get(raw_url, timeout=10)
        if isinstance(data, dict):
            parsed = smart_parse(data, raw_url)
            sources.extend(parsed)
            if parsed:
                print(f"  -> {raw_url.split('/')[-1]}: {len(parsed)} 个源")
        time.sleep(0.3)
    return sources


def crawl_known_apis() -> list[VideoSource]:
    """爬取已知的 TVBox/M3U/AppleCMS API."""
    print(f"[crawl] 爬取 {len(KNOWN_TVBOX_APIS)} 个已知 API...")
    sources: list[VideoSource] = []

    def _fetch_one(url: str) -> list[VideoSource]:
        data = _json_get(url, timeout=15)
        if data is None:
            # 尝试当作文本读取（M3U）
            text = _http_get(url, timeout=15)
            if text:
                return smart_parse(text, url)
            return []
        return smart_parse(data, url)

    with ThreadPoolExecutor(max_workers=8) as pool:
        futures = {pool.submit(_fetch_one, url): url for url in KNOWN_TVBOX_APIS}
        for future in as_completed(futures):
            url = futures[future]
            try:
                result = future.result()
                if result:
                    print(f"  -> {Path(urlparse(url).path).name}: {len(result)} 个源")
                    sources.extend(result)
            except Exception as exc:
                print(f"  [warn] {url}: {exc}")

    return sources


def crawl_github_repos(token: str = "") -> list[VideoSource]:
    """从多个 GitHub 仓库搜索 JSON/TVBox 配置."""
    print(f"[crawl] 搜索 {len(TVBOX_REPOS)} 个仓库...")
    sources: list[VideoSource] = []
    for repo in TVBOX_REPOS:
        print(f"  -> {repo}...")
        # 搜索该仓库中的 JSON 文件
        for ext in ("json", "m3u"):
            url = (
                f"https://api.github.com/search/code"
                f"?q=extension:{ext}+repo:{repo}"
                f"&per_page=15"
            )
            headers = {"Accept": "application/vnd.github+json"}
            if token:
                headers["Authorization"] = f"Bearer {token}"
            data = _json_get(url, timeout=15)
            if not isinstance(data, dict):
                continue
            items = data.get("items", [])
            for item in items[:5]:
                raw_url = _raw_url_from_item(item)
                if not raw_url:
                    continue
                raw = _json_get(raw_url, timeout=10)
                if raw is not None:
                    parsed = smart_parse(raw, raw_url)
                    sources.extend(parsed)
            time.sleep(1.0)
    return sources


def dedupe_sources(sources: list[VideoSource]) -> list[VideoSource]:
    """按 id 去重，保留先出现的."""
    seen: set[str] = set()
    result: list[VideoSource] = []
    for s in sources:
        if s.id not in seen:
            seen.add(s.id)
            result.append(s)
    return result


def main():
    import argparse

    parser = argparse.ArgumentParser(description="Anime 视频源爬虫")
    parser.add_argument("--quick", action="store_true", help="仅爬取，跳过健康检查")
    parser.add_argument(
        "--output",
        default="assets/data/sources_catalog.json",
        help="输出 JSON 路径",
    )
    parser.add_argument("--token", default="", help="GitHub token (可选，解决限流)")
    args = parser.parse_args()

    all_sources: list[VideoSource] = []

    # Phase 1: KazumiRules
    all_sources.extend(crawl_kazumi_rules(args.token))

    # Phase 2: 已知 API
    all_sources.extend(crawl_known_apis())

    # Phase 3: 多仓库搜索
    all_sources.extend(crawl_github_repos(args.token))

    # 去重
    all_sources = dedupe_sources(all_sources)
    print(f"\n[total] 去重后共 {len(all_sources)} 个源")

    # Phase 4: 健康检查
    if not args.quick:
        print("[health] 并发检查可达性...")
        healthy = 0

        def _check(s: VideoSource) -> VideoSource:
            return health_check(s)

        with ThreadPoolExecutor(max_workers=12) as pool:
            futures = [pool.submit(_check, s) for s in all_sources]
            checked = []
            for future in as_completed(futures):
                try:
                    s = future.result()
                    if s.health == "available":
                        healthy += 1
                    checked.append(s)
                except Exception:
                    pass
            all_sources = checked

        print(f"  -> {healthy}/{len(all_sources)} 可达")

    # Phase 5: 导出
    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    export_data = {
        "version": 1,
        "generatedAt": int(time.time()),
        "totalSources": len(all_sources),
        "sources": [s.to_app_json() for s in all_sources],
    }
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(export_data, f, ensure_ascii=False, indent=2)
    print(f"[done] 已导出 {len(all_sources)} 个源到 {output_path}")

    # 按类型统计
    kinds: dict[str, int] = {}
    for s in all_sources:
        kinds[s.kind] = kinds.get(s.kind, 0) + 1
    print("[stats] 类型分布:")
    for k, v in sorted(kinds.items(), key=lambda x: -x[1]):
        print(f"  {k}: {v}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
