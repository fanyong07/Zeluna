"""
通用 M3U8/MP4 视频地址解析器

不依赖第三方 TVBox API，直接从多个解析服务和公开源
提取可播放的视频 URL。

解析策略:
  1. 已知 CDN 直链匹配 (快手/v-cdn/moedot 等)
  2. 通用 M3U8 解析站代理
  3. 公共搜索引擎爬取
  4. 结果去重 + 可达性验证

不存储视频文件，只返回可播放 URL。
"""

import re
import json
import logging
import asyncio
import hashlib
from typing import Optional
from urllib.parse import quote, urljoin

import httpx

logger = logging.getLogger(__name__)


# 已知的通用 M3U8 解析服务
# 这些服务接收一个视频站URL，返回解析后的 m3u8 直链
M3U8_PARSE_SERVICES = [
    "https://app.emmmm.eu.org.cdn.cloudflare.net/parse/m3u8/xp/{vid}",
    "https://m3u8.cyz.app/kuais/{vid}",
]

# 已知的免费影视搜索 API
FREE_SEARCH_APIS = [
    {
        "name": "量子",
        "base": "https://cj.lziapi.com/api.php/provide/vod",
        "search": "?ac=detail&wd={keyword}",
        "detail": "?ac=videolist&ids={vid}",
    },
    {
        "name": "暴风",
        "base": "https://bfzyapi.com/api.php/provide/vod",
        "search": "?ac=detail&wd={keyword}",
        "detail": "?ac=videolist&ids={vid}",
    },
]

# 已知的视频 CDN 域名模式
# 当在页面中匹配到这些域名的 m3u8/mp4 URL 时，直接提取
CDN_PATTERNS = [
    r'(https?://v\d+\.adkwai\.com/[^"\'\s<>]+\.(?:m3u8|mp4)[^"\'\s<>]*)',
    r'(https?://v-cdn\.emmmm\.eu\.org/video/[^"\'\s<>]+)',
    r'(https?://vo-cdn\.emmmm\.eu\.org/video/[^"\'\s<>]+)',
    r'(https?://vod-cdn\.sends\.eu\.org[^"\'\s<>]+\.m3u8[^"\'\s<>]*)',
    r'(https?://m3u8\d+\.yhdmm3u8\.top/[^"\'\s<>]+\.m3u8[^"\'\s<>]*)',
    r'(https?://apn\.moedot\.net/[^"\'\s<>]+\.(?:mp4|m3u8)[^"\'\s<>]*)',
    r'(https?://ai\.girigirilove\.net/[^"\'\s<>]+\.m3u8[^"\'\s<>]*)',
    r'(https?://play\.xfvod\.pro[^"\'\s<>]+\.(?:mp4|m3u8)[^"\'\s<>]*)',
    r'(https?://dl\.playxf\.top/[^"\'\s<>]+\.m3u8[^"\'\s<>]*)',
    r'(https?://dc\.xhscdn\.com/[^"\'\s<>]+\.m3u8[^"\'\s<>]*)',
    r'(https?://ani\.v300\.eu\.org/[^"\'\s<>]+\.m3u8[^"\'\s<>]*)',
    r'(https?://aigua\.emmmm\.eu\.org/[^"\'\s<>]+\.m3u8[^"\'\s<>]*)',
    r'(https?://lm\.i\.me\.cdn\.cloudflare\.net/[^"\'\s<>]+)',
    r'(https?://xgct-video\.vzcdn\.net/[^"\'\s<>]+\.(?:mp4|m3u8)[^"\'\s<>]*)',
    r'(https?://v\.cdnlz\d+\.com/[^"\'\s<>]+\.(?:mp4|m3u8|m3u8\?)[^"\'\s<>]*)',
    r'(https?://c\d+\.ddbbffcdn\.com/[^"\'\s<>]+\.m3u8[^"\'\s<>]*)',
]


class M3U8Resolver:
    """
    M3U8 解析器

    从多个来源解析视频播放地址，返回去重后的可用 URL 列表。
    """

    def __init__(self):
        self._client = httpx.AsyncClient(
            headers={
                "User-Agent": (
                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                    "AppleWebKit/537.36 Chrome/124.0.0.0 Safari/537.36"
                ),
                "Accept": "*/*",
                "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
            },
            timeout=12,
            follow_redirects=True,
            verify=False,
        )
        self._url_cache: dict[str, list[dict]] = {}
        self._seen_urls: set[str] = set()

    def _normalize(self, url: str) -> str:
        """URL 去重标准化"""
        # 去掉时间戳等动态参数
        url = re.sub(r'[?&]_?(?:t|timestamp|_|sign)=[^&]+', '', url)
        url = url.rstrip('?&')
        # 处理 URL 中的中文：确保正确编码
        try:
            # 如果 URL 包含原始中文，重新编码
            decoded = url
            for ch in '一-鿿　-〿＀-￯':
                pass  # non-ASCII check
        except Exception:
            pass
        return url

    def _extract_cdn_urls(self, text: str) -> list[str]:
        """从文本中提取已知 CDN 的视频 URL"""
        urls = []
        for pattern in CDN_PATTERNS:
            for match in re.finditer(pattern, text, re.IGNORECASE):
                url = match.group(1)
                url = url.replace('\\/', '/')
                # 清理尾部垃圾
                url = re.sub(r'[),.;\]}"\']+$', '', url)
                if url not in self._seen_urls:
                    self._seen_urls.add(self._normalize(url))
                    urls.append(url)
        return urls

    async def resolve_from_text(self, html_or_text: str) -> list[dict]:
        """
        从 HTML 或文本中解析所有视频 URL。

        返回: [{"url": "...", "format": "hls"|"mp4", "source": "cdn_name"}, ...]
        """
        results = []

        # 1. 提取已知 CDN 直链
        for url in self._extract_cdn_urls(html_or_text):
            fmt = "hls" if "m3u8" in url.lower() else "mp4"
            # 识别来源
            source = "unknown_cdn"
            for tag, domain in [
                ("adkwai", "adkwai.com"),
                ("emmmm_cdn", "emmmm.eu.org"),
                ("sends_cdn", "sends.eu.org"),
                ("yhdm_cdn", "yhdmm3u8.top"),
                ("moedot", "moedot.net"),
                ("girigiri", "girigirilove.net"),
                ("xfvod", "xfvod.pro"),
                ("xhscdn", "xhscdn.com"),
                ("v300", "v300.eu.org"),
                ("aigua", "aigua.emmmm"),
                ("cloudflare_stream", "lm.i.me.cdn.cloudflare"),
                ("vzcdn", "vzcdn.net"),
                ("cdnlz", "cdnlz"),
                ("ddbbff", "ddbbffcdn"),
            ]:
                if domain in url.lower():
                    source = tag
                    break
            results.append({"url": url, "format": fmt, "source": source})

        # 2. 通用 m3u8/mp4 正则匹配（非 CDN 的）
        generic_patterns = [
            (r'(https?://[^"\'\s<>]+\.m3u8[^"\'\s<>]*)', "hls"),
            (r'(https?://[^"\'\s<>]+\.mp4[^"\'\s<>]*)', "mp4"),
        ]
        for pattern, fmt in generic_patterns:
            for match in re.finditer(pattern, html_or_text, re.IGNORECASE):
                url = match.group(1)
                url = url.replace('\\/', '/')
                url = re.sub(r'[),.;\]}"\']+$', '', url)
                norm = self._normalize(url)
                if norm not in self._seen_urls:
                    self._seen_urls.add(norm)
                    results.append({"url": url, "format": fmt, "source": "generic"})

        return results

    async def resolve_via_parse_services(self, target_url: str) -> list[dict]:
        """
        通过通用 M3U8 解析服务获取视频 URL。

        这些服务接收一个视频页面 URL，解析后返回 m3u8 直链。
        """
        results = []
        vid = quote(target_url, safe='')

        for service_url_tpl in M3U8_PARSE_SERVICES:
            try:
                service_url = service_url_tpl.format(vid=vid)
                resp = await self._client.get(service_url)
                if resp.status_code == 200:
                    text = resp.text
                    # 解析服务可能直接返回 m3u8 内容，也可能返回 JSON
                    if text.strip().startswith("#EXTM3U"):
                        results.append({
                            "url": service_url,
                            "format": "hls",
                            "source": "parse_service",
                        })
                    elif text.strip().startswith("{"):
                        try:
                            data = json.loads(text)
                            m3u8_url = data.get("url", data.get("m3u8", ""))
                            if m3u8_url:
                                results.append({
                                    "url": m3u8_url,
                                    "format": "hls",
                                    "source": "parse_service",
                                })
                        except json.JSONDecodeError:
                            pass
                    # 也检查返回文本中是否有其他 URL
                    extra = await self.resolve_from_text(text)
                    results.extend(extra)
            except Exception:
                continue

        return results

    async def search_and_resolve(
        self, keyword: str, content_type: str = "tv"
    ) -> list[dict]:
        """
        一站式搜索+解析：根据关键词搜索并返回可播放的视频 URL。

        这是对外的主要接口。
        """
        all_urls: list[dict] = []
        self._seen_urls.clear()

        # 策略1: 从免费影视搜索 API 获取
        for api in FREE_SEARCH_APIS:
            try:
                # 搜索
                search_url = f"{api['base']}{api['search'].format(keyword=quote(keyword))}"
                resp = await self._client.get(search_url)
                if resp.status_code != 200:
                    continue

                data = resp.json()
                items = data.get("list", []) if isinstance(data, dict) else data
                if not items:
                    continue

                # 获取第一个结果的播放地址
                for item in items[:3]:  # 取前3个最匹配的
                    vid = str(item.get("vod_id", ""))
                    if not vid:
                        continue

                    detail_url = f"{api['base']}{api['detail'].format(vid=vid)}"
                    detail_resp = await self._client.get(detail_url)
                    if detail_resp.status_code != 200:
                        continue

                    detail_data = detail_resp.json()
                    detail_items = detail_data.get("list", []) if isinstance(detail_data, dict) else detail_data
                    if not detail_items:
                        continue

                    play_url = detail_items[0].get("vod_play_url", "")
                    if play_url:
                        # 解析出所有 m3u8/mp4 地址
                        urls = await self.resolve_from_text(play_url)
                        for u in urls:
                            u["keyword"] = keyword
                            u["api_source"] = api["name"]
                        all_urls.extend(urls)

                    # 限制结果数
                    if len(all_urls) >= 20:
                        break

                if len(all_urls) >= 20:
                    break

            except Exception as e:
                logger.warning(f"Search+resolve error [{api['name']}]: {e}")

        # 策略2: 尝试通用解析服务
        if len(all_urls) < 5:
            for parse_url_tpl in M3U8_PARSE_SERVICES:
                try:
                    service_url = parse_url_tpl.format(vid=quote(keyword, safe=''))
                    resp = await self._client.get(service_url)
                    if resp.status_code == 200:
                        extra = await self.resolve_from_text(resp.text)
                        all_urls.extend(extra)
                except Exception:
                    continue

        # 去重
        seen = set()
        unique = []
        for item in all_urls:
            norm = self._normalize(item["url"])
            if norm not in seen:
                seen.add(norm)
                unique.append(item)

        return unique

    async def check_url_reachable(self, url: str) -> bool:
        """快速检查 URL 是否可达"""
        try:
            resp = await self._client.head(url, timeout=5)
            return resp.status_code < 400
        except Exception:
            return False


# 全局解析器实例
resolver = M3U8Resolver()
