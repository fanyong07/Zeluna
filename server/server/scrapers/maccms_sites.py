"""
MacCMS / 苹果CMS provide/vod 采集站清单

每一项就是一路源。这些是公开的资源采集接口,返回标准 MacCMS JSON。
覆盖: 电影 / 国产剧 / 欧美剧 / 韩剧 / 日剧 / 动漫 / 综艺。

字段说明:
  name      展示名
  api       provide/vod 接口地址 (JSON)
  weight    排序权重, 越大越优先 (线路质量/稳定性经验值)
  precache  是否用于后台预爬。只启用实测相对稳定的站点。

注意: 站点会不定期失效或换域名。scheduler 的健康检查会自动
跳过连不上的站,不影响其它源。可随时增删本表。
"""

MACCMS_SITES: list[dict] = [
    # 2026-07-26 从目标洛杉矶 VPS 实测：搜索、详情和首集 M3U8
    # 三层均可用。接口能返回数据但样本视频全失效的站点不进入生产清单。
    {"name": "iKun", "api": "https://ikunzyapi.com/api.php/provide/vod", "weight": 100, "precache": True},
    {"name": "魔都", "api": "https://caiji.moduapi.cc/api.php/provide/vod", "weight": 96, "precache": True},
    {"name": "红牛", "api": "https://www.hongniuzy2.com/api.php/provide/vod", "weight": 92, "precache": True},
    {"name": "光速", "api": "https://api.guangsuapi.com/api.php/provide/vod", "weight": 88, "precache": True},
]


def site_priority(name: str) -> int:
    """Return the configured priority for one site."""
    site = next((item for item in MACCMS_SITES if item["name"] == name), None)
    return int(site.get("weight", 0)) if site else 0


def precache_sites() -> list[dict]:
    """Return only explicitly enabled precache sites in priority order."""
    return sorted(
        (site for site in MACCMS_SITES if site.get("precache") is True),
        key=lambda site: int(site.get("weight", 0)),
        reverse=True,
    )
