"""
MacCMS / 苹果CMS provide/vod 采集站清单

每一项就是一路源。这些是公开的资源采集接口,返回标准 MacCMS JSON。
覆盖: 电影 / 国产剧 / 欧美剧 / 韩剧 / 日剧 / 动漫 / 综艺。

字段说明:
  name           展示名
  api            provide/vod 接口地址 (JSON)
  enabled        是否允许进入运行时来源库存
  tier           core / fallback / specialist / client_probe / quarantine / retired
  quick          是否进入前台快速发现第一波
  precache       是否用于后台预爬
  weight         同一调度层内的排序权重
  content_types  允许查询的内容类型 (anime / tv / movie)

注意: 站点会不定期失效或换域名。scheduler 的健康检查会自动
跳过连不上的站,不影响其它源。可随时增删本表。
"""

from collections.abc import Sequence


MACCMS_TIERS = frozenset({
    "core",
    "fallback",
    "specialist",
    "client_probe",
    "quarantine",
    "retired",
})
MACCMS_CONTENT_TYPES = frozenset({"anime", "tv", "movie"})
_TIER_RANK = {
    "core": 0,
    "fallback": 1,
    "specialist": 2,
    "client_probe": 3,
    "quarantine": 4,
    "retired": 5,
}


MACCMS_SITES: list[dict] = [
    # 2026-07-26 在 VPS(洛杉矶出口)逐类实测：搜索 / 详情 / 首集 m3u8 真实可达。
    # 2026-08-24 起按目标出口复测结果分层；失效项保留为禁用的 quarantine 记录，
    # 不进入运行时请求。域名会变，需继续用 tools/probe_maccms.py 在 VPS 复测。
    # —— 第一梯队：VPS 实测番剧 / 剧集 / 电影 三类全可播 ——
    {"name": "iKun", "api": "https://ikunzyapi.com/api.php/provide/vod", "enabled": True, "tier": "core", "quick": True, "precache": True, "weight": 100, "content_types": ["anime", "tv", "movie"]},
    {"name": "光速", "api": "https://api.guangsuapi.com/api.php/provide/vod", "enabled": True, "tier": "core", "quick": True, "precache": True, "weight": 99, "content_types": ["anime", "tv", "movie"]},
    {"name": "如意", "api": "https://cj.rycjapi.com/api.php/provide/vod", "enabled": True, "tier": "core", "quick": True, "precache": True, "weight": 98, "content_types": ["anime", "tv", "movie"]},
    {"name": "豪华", "api": "https://hhzyapi.com/api.php/provide/vod", "enabled": True, "tier": "core", "quick": True, "precache": True, "weight": 96, "content_types": ["anime", "tv", "movie"]},
    # 目标出口复测未达到生产可播门槛，保留记录但完全禁用。
    {"name": "极速", "api": "https://jszyapi.com/api.php/provide/vod", "enabled": False, "tier": "quarantine", "quick": False, "precache": False, "weight": 94, "content_types": ["anime", "tv", "movie"]},
    {"name": "猫眼", "api": "https://api.maoyanapi.top/api.php/provide/vod", "enabled": True, "tier": "core", "quick": True, "precache": True, "weight": 92, "content_types": ["anime", "tv", "movie"]},
    {"name": "魔都2", "api": "https://www.mdzyapi.com/api.php/provide/vod", "enabled": True, "tier": "core", "quick": True, "precache": True, "weight": 90, "content_types": ["anime", "tv", "movie"]},
    {"name": "速博", "api": "https://subocaiji.com/api.php/provide/vod", "enabled": True, "tier": "core", "quick": True, "precache": False, "weight": 88, "content_types": ["anime", "tv", "movie"]},
    {"name": "魔都", "api": "https://caiji.moduapi.cc/api.php/provide/vod", "enabled": True, "tier": "core", "quick": True, "precache": False, "weight": 86, "content_types": ["anime", "tv", "movie"]},
    {"name": "红牛", "api": "https://www.hongniuzy2.com/api.php/provide/vod", "enabled": True, "tier": "core", "quick": True, "precache": False, "weight": 84, "content_types": ["anime", "tv", "movie"]},
    # —— 动漫专门站：来自 Animeko 订阅的 30 站中唯一暴露标准 JSON 接口者，
    #    VPS 实测多部新番可播(斗罗 / 咒术 / 进击 / 转生史莱姆)。 ——
    {"name": "风车", "api": "https://www.dongmandaquan.vip/api.php/provide/vod", "enabled": True, "tier": "specialist", "quick": False, "precache": False, "weight": 80, "content_types": ["anime"]},
    # —— 第二梯队：VPS 实测部分类型可播(注释标注命中类型) ——
    {"name": "爱奇艺", "api": "https://iqiyizyapi.com/api.php/provide/vod", "enabled": True, "tier": "specialist", "quick": False, "precache": False, "weight": 78, "content_types": ["anime", "movie"]},
    {"name": "量子", "api": "https://cj.lziapi.com/api.php/provide/vod", "enabled": True, "tier": "specialist", "quick": False, "precache": False, "weight": 76, "content_types": ["anime", "movie"]},
    {"name": "电影天堂", "api": "http://caiji.dyttzyapi.com/api.php/provide/vod", "enabled": True, "tier": "specialist", "quick": False, "precache": False, "weight": 74, "content_types": ["anime", "tv"]},
    # —— 第三梯队：三类内容均能完成搜索、详情和媒体候选解析；当前本机
    #    Fake-IP 出口无法做服务端首分片定论，因此只作为客户端复验候选，
    #    不参与预爬，且始终排在 VPS 已实播来源之后。 ——
    {"name": "暴风", "api": "https://bfzyapi.com/api.php/provide/vod", "enabled": True, "tier": "client_probe", "quick": False, "precache": False, "weight": 72, "content_types": ["anime", "tv", "movie"]},
    {"name": "百度", "api": "https://api.apibdzy.com/api.php/provide/vod", "enabled": True, "tier": "client_probe", "quick": False, "precache": False, "weight": 70, "content_types": ["anime", "tv", "movie"]},
    {"name": "无尽", "api": "https://api.wujinapi.me/api.php/provide/vod", "enabled": True, "tier": "client_probe", "quick": False, "precache": False, "weight": 68, "content_types": ["anime", "tv", "movie"]},
    {"name": "最大", "api": "https://api.zuidapi.com/api.php/provide/vod", "enabled": True, "tier": "client_probe", "quick": False, "precache": False, "weight": 66, "content_types": ["anime", "tv", "movie"]},
    {"name": "360", "api": "https://360zy.com/api.php/provide/vod", "enabled": True, "tier": "client_probe", "quick": False, "precache": False, "weight": 64, "content_types": ["anime", "tv", "movie"]},
    # 洛杉矶 VPS 三类实播均通过，但国内客户端直连明显较慢；只作末位地区备用。
    {"name": "虎牙", "api": "https://www.huyaapi.com/api.php/provide/vod", "enabled": True, "tier": "fallback", "quick": False, "precache": False, "weight": 62, "content_types": ["anime", "tv", "movie"]},
]


def normalize_content_type(value: object) -> str:
    """Normalize public and internal series labels to the site schema."""
    normalized = str(value or "").strip().lower()
    if normalized in {"tv", "series"}:
        return "tv"
    if normalized in {"anime", "movie"}:
        return normalized
    return ""


def site_content_types(site: dict) -> tuple[str, ...]:
    """Return normalized declared types, defaulting legacy fixtures to all."""
    raw_types = site.get("content_types") or MACCMS_CONTENT_TYPES
    result: list[str] = []
    for raw_type in raw_types:
        normalized = normalize_content_type(raw_type)
        if normalized and normalized not in result:
            result.append(normalized)
    return tuple(result)


def site_supports_content_type(site: dict, content_type: object) -> bool:
    normalized = normalize_content_type(content_type)
    return not normalized or normalized in site_content_types(site)


def site_tier_rank(tier: object) -> int:
    return _TIER_RANK.get(str(tier or "fallback").strip().lower(), 1)


def _inventory(sites: Sequence[dict] | None) -> Sequence[dict]:
    return MACCMS_SITES if sites is None else sites


def _sorted_sites(sites: Sequence[dict]) -> list[dict]:
    return sorted(
        (site for site in sites if str(site.get("name") or "").strip()),
        key=lambda site: int(site.get("weight", 0)),
        reverse=True,
    )


def enabled_sites(sites: Sequence[dict] | None = None) -> list[dict]:
    """Return operational sites only; legacy test fixtures default enabled."""
    return _sorted_sites([
        site for site in _inventory(sites)
        if site.get("enabled", True) is True
    ])


def _tier_sites(tier: str, sites: Sequence[dict] | None = None) -> list[dict]:
    return [
        site for site in enabled_sites(sites)
        if str(site.get("tier") or "fallback").strip().lower() == tier
    ]


def core_sites(sites: Sequence[dict] | None = None) -> list[dict]:
    return _tier_sites("core", sites)


def quick_sites(sites: Sequence[dict] | None = None) -> list[dict]:
    return [site for site in enabled_sites(sites) if site.get("quick") is True]


def fallback_sites(sites: Sequence[dict] | None = None) -> list[dict]:
    return _tier_sites("fallback", sites)


def specialist_sites(
    sites: Sequence[dict] | None = None,
    *,
    content_type: object = "",
) -> list[dict]:
    return [
        site for site in _tier_sites("specialist", sites)
        if site_supports_content_type(site, content_type)
    ]


def client_probe_sites(sites: Sequence[dict] | None = None) -> list[dict]:
    return _tier_sites("client_probe", sites)


def site_priority(name: str) -> int:
    """Return the configured priority for one site."""
    site = next((item for item in MACCMS_SITES if item["name"] == name), None)
    return int(site.get("weight", 0)) if site else 0


def precache_sites(sites: Sequence[dict] | None = None) -> list[dict]:
    """Return only explicitly enabled precache sites in priority order."""
    return [
        site for site in enabled_sites(sites)
        if site.get("precache") is True
    ]
