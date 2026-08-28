"""列表页驱动的本地标题索引。

部分采集站的站内搜索不可用,但不是"没有搜索能力":
  * 边缘缓存按路径缓存、忽略 query string —— 换关键词永远返回同一页
    (实测某站两个关键词返回长度恒为 67850B),请求根本到不了搜索逻辑;
  * 或首次搜索即弹验证码,而浏览列表页完全不拦。

绕行办法是抓**列表页**建立 ``title → sid`` 的本地索引,之后搜索变成纯
本地操作:零风控、零网络延迟、不受对方搜索改版影响。代价是覆盖率取决
于抓了多少页,通常只够近期作品,老作品仍需其它途径。

⚠️ 有些站分页同样被缓存(第 2 页起内容重复),``build`` 因此在检测到
重复页时提前停止,避免无谓请求。
"""

from __future__ import annotations

import asyncio
import difflib
import re
import time
from dataclasses import dataclass, field

import httpx

#: 就近文本搜索窗口:详情链接前后各取这么多字符找标题
_TITLE_WINDOW = 260
_TITLE_ATTR_RE = re.compile(r'title="([^"]{2,60})"')
_TITLE_TEXT_RE = re.compile(r">\s*([^<>{}\n]{2,60}?)\s*<")
_WHITESPACE_RE = re.compile(r"\s+")
#: 标题里常见的噪声后缀(更新状态、清晰度标注等)
_NOISE_RE = re.compile(
    r"(更新至?第?\d+[集话話]?|全\d+[集话話]|第\d+[季期]完|"
    r"HD|BD|TC|国语|粤语|中字|完结|连载中?)$"
)


def normalize_title(value: str) -> str:
    """归一化用于匹配:去空白、去噪声后缀、小写化。"""
    text = _WHITESPACE_RE.sub("", (value or "").strip())
    for _ in range(3):
        stripped = _NOISE_RE.sub("", text)
        if stripped == text:
            break
        text = stripped
    return text.casefold()


@dataclass
class SiteIndexEntry:
    sid: str
    title: str
    normalized: str = ""

    def __post_init__(self) -> None:
        if not self.normalized:
            self.normalized = normalize_title(self.title)


@dataclass
class SiteIndex:
    """一个站点的本地标题索引(内存态;持久化由调用方决定)。"""

    site: str
    entries: dict[str, SiteIndexEntry] = field(default_factory=dict)
    built_at: float = 0.0

    @property
    def size(self) -> int:
        return len(self.entries)

    def age_hours(self, *, now: float | None = None) -> float:
        if not self.built_at:
            return float("inf")
        current = time.time() if now is None else now
        return max(0.0, (current - self.built_at) / 3600.0)

    def add(self, sid: str, title: str) -> bool:
        sid = str(sid).strip()
        title = (title or "").strip()
        if not sid or not title or sid in self.entries:
            return False
        self.entries[sid] = SiteIndexEntry(sid=sid, title=title)
        return True

    def search(
        self, keyword: str, *, limit: int = 10, min_score: float = 0.45
    ) -> list[tuple[str, str, float]]:
        """本地模糊搜索。→ [(sid, title, score)],按分数降序。

        评分:完全相等 1.0 > 包含关系(按长度比折算)> 序列相似度。
        """
        target = normalize_title(keyword)
        if not target:
            return []
        scored: list[tuple[str, str, float]] = []
        for entry in self.entries.values():
            name = entry.normalized
            if not name:
                continue
            if name == target:
                score = 1.0
            elif target in name or name in target:
                shorter, longer = sorted((len(target), len(name)))
                score = 0.6 + 0.35 * (shorter / longer if longer else 0)
            else:
                score = difflib.SequenceMatcher(None, target, name).ratio()
            if score >= min_score:
                scored.append((entry.sid, entry.title, round(score, 3)))
        scored.sort(key=lambda item: (-item[2], len(item[1])))
        return scored[:limit]

    def to_dict(self) -> dict:
        return {
            "site": self.site,
            "built_at": self.built_at,
            "entries": [
                {"sid": e.sid, "title": e.title} for e in self.entries.values()
            ],
        }

    @classmethod
    def from_dict(cls, data: dict) -> SiteIndex:
        index = cls(site=str(data.get("site") or ""))
        index.built_at = float(data.get("built_at") or 0.0)
        for row in data.get("entries") or []:
            if isinstance(row, dict):
                index.add(str(row.get("sid") or ""), str(row.get("title") or ""))
        return index


def extract_entries(html: str, detail_pattern: str) -> list[tuple[str, str]]:
    """从列表页 HTML 抽 (sid, title)。

    先在详情链接就近窗口里找 ``title="..."``,没有再取相邻文本节点。
    """
    if not html:
        return []
    try:
        regex = re.compile(detail_pattern)
    except re.error:
        return []
    found: list[tuple[str, str]] = []
    seen: set[str] = set()
    for match in regex.finditer(html):
        if not match.groups():
            continue
        sid = match.group(1)
        if sid in seen:
            continue
        # 先看链接右侧(title 属性通常紧跟在 href 之后),再回看左侧。
        # 只向前扩窗会捞到**上一张卡片**的 title,那是错的。
        title = ""
        after = html[match.end(): match.end() + _TITLE_WINDOW]
        attr = _TITLE_ATTR_RE.search(after)
        if attr:
            title = attr.group(1)
        if not title:
            before_start = max(0, match.start() - _TITLE_WINDOW)
            before = html[before_start: match.start()]
            attrs_before = _TITLE_ATTR_RE.findall(before)
            if attrs_before:
                title = attrs_before[-1]      # 最近的那个
        if not title:
            candidates = [
                text.strip()
                for text in _TITLE_TEXT_RE.findall(after)
                if len(text.strip()) >= 2 and not text.strip().startswith("#")
            ]
            if candidates:
                title = candidates[0]
        if title:
            seen.add(sid)
            found.append((sid, title))
    return found


def paginate(path: str, page: int) -> str | None:
    """把列表路径改写成第 N 页。识别不出分页形态时返回 None。"""
    if page <= 1:
        return path
    patterns = (
        (r"/list/(\d+)\.html$", lambda m: f"/list/{m.group(1)}-{page}.html"),
        (r"/vodshow/(\d+)--------(\d*)---/?$",
         lambda m: f"/vodshow/{m.group(1)}--------{page}---/"),
        (r"/show/([\d-]+?)--------\d*---/?$",
         lambda m: f"/show/{m.group(1)}--------{page}---/"),
        (r"/type_(\d+)\.html$", lambda m: f"/type_{m.group(1)}-{page}.html"),
        (r"/s/([a-z]+)\.html$", lambda m: f"/s/{m.group(1)}-{page}.html"),
        (r"/vodtype/(\d+)\.html$", lambda m: f"/vodtype/{m.group(1)}-{page}.html"),
    )
    for pattern, builder in patterns:
        match = re.search(pattern, path)
        if match:
            return builder(match)
    return None


async def build_index(
    *,
    site: str,
    base_url: str,
    list_paths: tuple[str, ...],
    detail_pattern: str,
    client: httpx.AsyncClient,
    pages: int = 4,
    headers: dict | None = None,
    request_gap_seconds: float = 0.8,
    sleep_func=asyncio.sleep,
    now: float | None = None,
) -> SiteIndex:
    """抓列表页建索引。分页内容重复即提前停止(应对分页被缓存)。"""
    index = SiteIndex(site=site)
    for path in list_paths:
        seen_signatures: set[int] = set()
        for page in range(1, max(1, pages) + 1):
            page_path = paginate(path, page)
            if page_path is None:
                break
            url = base_url.rstrip("/") + page_path
            try:
                response = await client.get(url, headers=headers or {})
            except httpx.HTTPError:
                break
            if response.status_code != 200:
                break
            signature = hash(response.text)
            if signature in seen_signatures:
                break  # 分页被缓存,继续翻无意义
            seen_signatures.add(signature)
            added = 0
            for sid, title in extract_entries(response.text, detail_pattern):
                if index.add(sid, title):
                    added += 1
            if added == 0 and page > 1:
                break
            await sleep_func(request_gap_seconds)
    index.built_at = time.time() if now is None else now
    return index
