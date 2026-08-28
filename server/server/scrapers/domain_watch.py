"""采集站域名体检与族内轮换。

这类站换域极勤:同一个"樱花动漫"在用的域名可以有十来个,旧域会变成
落地页、JS 跳转告别页或直接失效。因此"某域名连不上"通常不是站没了,
而是**换域了**——把域名按族管理并定期体检,是这类源能长期可用的前提。

判定五分类(判据来自 2026-08-28 对 23 个候选域的实测):
  content  首页含已知内容形态(详情页/播放器指纹)→ 可接入
  landing  体量够大但无内容形态 → 落地页,内容常在兄弟域/子域
  js-gate  ~4.7KB 且含 redirecting/window.location → 弃用域的告别页
  empty    响应过小或 4xx 短体 → 疑似已迁移
  dead     连接层失败

注意本模块**保留证书校验**。外部参考实现为了迁就"证书不规范的采集站"
关掉了校验,本项目不采纳:降低全局安全基线换取个别站点可达并不值得。
"""

from __future__ import annotations

import asyncio
import re
import time
from dataclasses import dataclass
from urllib.parse import urlparse

import httpx

DOMAIN_KIND_CONTENT = "content"
DOMAIN_KIND_LANDING = "landing"
DOMAIN_KIND_JS_GATE = "js-gate"
DOMAIN_KIND_EMPTY = "empty"
DOMAIN_KIND_DEAD = "dead"

#: 判定用的内容形态特征。命中任一即认为该域"有内容"。
#  ⚠️ 这张表越窄,越容易把**用新 URL 形态的活站**误判成落地页。
#     实测 agedm.io / xgcartoon 就因形态不在表内被判成 landing,
#     所以判定结果只作候选线索,不足以单独作为下线依据。
CONTENT_MARKS: tuple[str, ...] = (
    # MacCMS / 樱花系常见详情与播放路径
    r"/vod/\d+\.html",
    r"/vod-play/\d+/ep\d+",
    r"/show/\d+\.html",
    r"/showp/\d+\.html",
    r"/voddetail/\d+\.html",
    r"/vodplay/\d+-\d+-\d+",
    r"/v/\d+-\d+-\d+\.html",
    r"/vodshow/\d+-",
    r"/vodtype/\d+\.html",
    r"/v/\d+\.html",
    r"/post/\d+\.html",
    r"/video/\d+",
    r"/vod_\d+\.html",
    r"/play_\d+-\d+-\d+\.html",
    r"/GV\d+/",
    r"/playGV\d+-",
    # 现有项目在用站点的形态(补齐后不再误判为 landing)
    r"/detail/\d+",
    r"/watch/\d+",
    r"/comic/\d+",
    # 播放器与接口指纹
    r"player_aaaa",
    r"MacPlayer",
    r"_get_plays",
    r"vod_play_url",
    r"/upload/vod",
    r"stui_",
    r"DPlayer",
    r"artplayer",
)
_CONTENT_RE = tuple((pattern, re.compile(pattern)) for pattern in CONTENT_MARKS)

_JS_GATE_MARKS = ("redirecting", "window.location", "location.replace",
                  "location.href")
_JS_GATE_MAX_BYTES = 6000
_MIN_CONTENT_BYTES = 1500


@dataclass(frozen=True)
class DomainVerdict:
    """一次体检结果(不含页面正文,可安全落库/日志)。"""

    base: str
    kind: str
    size: int = 0
    status: int | None = None
    marks: tuple[str, ...] = ()
    sibling_hosts: tuple[str, ...] = ()
    error: str = ""

    @property
    def alive(self) -> bool:
        return self.kind == DOMAIN_KIND_CONTENT

    def as_public_dict(self) -> dict:
        return {
            "base": self.base,
            "kind": self.kind,
            "size": self.size,
            "status": self.status,
            "mark_count": len(self.marks),
        }


def classify_page(status: int | None, text: str) -> tuple[str, tuple[str, ...]]:
    """纯函数:按状态码与正文判定域名类别。→ (kind, 命中形态)"""
    size = len(text or "")
    if status is None:
        return DOMAIN_KIND_DEAD, ()
    if size < _MIN_CONTENT_BYTES:
        return DOMAIN_KIND_EMPTY, ()
    if status >= 400:
        return DOMAIN_KIND_EMPTY, ()
    lowered = text.lower()
    if size < _JS_GATE_MAX_BYTES and any(
        mark in lowered for mark in _JS_GATE_MARKS
    ):
        return DOMAIN_KIND_JS_GATE, ()
    marks = tuple(
        pattern for pattern, regex in _CONTENT_RE if regex.search(text)
    )
    if marks:
        return DOMAIN_KIND_CONTENT, marks
    return DOMAIN_KIND_LANDING, ()


def extract_sibling_hosts(base: str, text: str, limit: int = 8) -> tuple[str, ...]:
    """从落地页里抽同族兄弟域/子域。

    换域后旧域常变成落地页,而新址往往就写在页面里(实测只喂主域
    www.girigirilove.com 就能捞到内容站 anime. 子域)。
    """
    origin_host = (urlparse(base).hostname or "").lower()
    root = ".".join(origin_host.split(".")[-2:]) if origin_host else ""
    found: list[str] = []
    for raw in re.findall(r'https?://([A-Za-z0-9.\-]+)', text or ""):
        host = raw.lower().rstrip(".")
        if not host or host == origin_host or host in found:
            continue
        host_root = ".".join(host.split(".")[-2:])
        # 同根域的子域,或同品牌另一个 TLD
        brand = root.split(".")[0] if root else ""
        if host_root == root or (brand and len(brand) >= 4 and brand in host):
            found.append(host)
        if len(found) >= limit:
            break
    return tuple(found)


class DomainWatch:
    """域名族解析器。内存态 + 可选外部持久化回调。

    这里刻意不直接依赖数据库:体检本身是纯网络+判定,持久化由调用方
    通过 ``state_loader``/``state_saver`` 注入,便于单测与复用。
    """

    def __init__(
        self,
        families: dict[str, tuple[str, ...]],
        *,
        client: httpx.AsyncClient | None = None,
        transport: httpx.AsyncBaseTransport | None = None,
        ttl_seconds: float = 12 * 3600,
        clock=time.monotonic,
        wall_clock=time.time,
        request_gap_seconds: float = 0.4,
        sleep_func=asyncio.sleep,
    ) -> None:
        self._families = {name: tuple(bases) for name, bases in families.items()}
        self._owns_client = client is None
        self._client = client or httpx.AsyncClient(
            headers={
                "User-Agent": (
                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                    "(KHTML, like Gecko) Chrome/126.0 Safari/537.36"
                ),
                "Accept-Language": "zh-CN,zh;q=0.9",
            },
            timeout=15,
            follow_redirects=True,
            transport=transport,
        )
        self._ttl = ttl_seconds
        self._clock = clock
        self._wall_clock = wall_clock
        self._gap = request_gap_seconds
        self._sleep = sleep_func
        self._resolved: dict[str, tuple[str, float]] = {}

    @property
    def families(self) -> dict[str, tuple[str, ...]]:
        return dict(self._families)

    async def aclose(self) -> None:
        if self._owns_client:
            await self._client.aclose()

    async def check(self, base: str) -> DomainVerdict:
        """对单个域做一次体检。"""
        url = base if base.endswith("/") else base + "/"
        try:
            response = await self._client.get(url)
        except httpx.HTTPError as error:
            return DomainVerdict(
                base=base,
                kind=DOMAIN_KIND_DEAD,
                error=type(error).__name__,
            )
        text = response.text
        kind, marks = classify_page(response.status_code, text)
        siblings: tuple[str, ...] = ()
        if kind in (DOMAIN_KIND_LANDING, DOMAIN_KIND_JS_GATE):
            siblings = extract_sibling_hosts(base, text)
        return DomainVerdict(
            base=base,
            kind=kind,
            size=len(text),
            status=response.status_code,
            marks=marks,
            sibling_hosts=siblings,
        )

    async def resolve(self, family: str, *, force: bool = False) -> str | None:
        """返回该族当前可用的 base(kind == content),带 TTL 缓存。

        族内按优先序逐个体检;遇落地页/JS 门时就地尝试其兄弟域——
        换域后的新址常常就写在旧域页面里。
        """
        cached = self._resolved.get(family)
        if not force and cached and (self._clock() - cached[1]) < self._ttl:
            return cached[0]
        for base in self._families.get(family, ()):
            verdict = await self.check(base)
            if verdict.alive:
                self._resolved[family] = (base, self._clock())
                return base
            for host in verdict.sibling_hosts[:4]:
                candidate = f"https://{host}"
                if candidate in self._families.get(family, ()):
                    continue
                sibling = await self.check(candidate)
                if sibling.alive:
                    self._families[family] = (
                        candidate,
                        *self._families.get(family, ()),
                    )
                    self._resolved[family] = (candidate, self._clock())
                    return candidate
                await self._sleep(self._gap)
            await self._sleep(self._gap)
        self._resolved.pop(family, None)
        return None

    async def audit(
        self, family: str | None = None
    ) -> dict[str, list[DomainVerdict]]:
        """全量体检。适合定期跑,看谁死了/谁换域了。"""
        names = [family] if family else list(self._families)
        report: dict[str, list[DomainVerdict]] = {}
        for name in names:
            rows: list[DomainVerdict] = []
            for base in self._families.get(name, ()):
                rows.append(await self.check(base))
                await self._sleep(self._gap)
            report[name] = rows
        return report
