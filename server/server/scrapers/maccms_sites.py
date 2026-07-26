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
    # 2026-07-26 在 VPS(洛杉矶出口)逐类实测：搜索 / 详情 / 首集 m3u8 真实可达，
    # 记录番剧 / 剧集 / 电影 各自可播情况。仅保留实测确有可播线路的站；域名会变，
    # 随时用 tools/probe_maccms.py 在 VPS 复测，运行时每条线路仍会实测并淘汰失效站。
    # —— 第一梯队：VPS 实测番剧 / 剧集 / 电影 三类全可播 ——
    {"name": "iKun", "api": "https://ikunzyapi.com/api.php/provide/vod", "weight": 100, "precache": True},
    {"name": "如意", "api": "https://cj.rycjapi.com/api.php/provide/vod", "weight": 98, "precache": True},
    {"name": "豪华", "api": "https://hhzyapi.com/api.php/provide/vod", "weight": 96, "precache": True},
    {"name": "极速", "api": "https://jszyapi.com/api.php/provide/vod", "weight": 94, "precache": True},
    {"name": "猫眼", "api": "https://api.maoyanapi.top/api.php/provide/vod", "weight": 92, "precache": True},
    {"name": "魔都2", "api": "https://www.mdzyapi.com/api.php/provide/vod", "weight": 90, "precache": True},
    {"name": "速博", "api": "https://subocaiji.com/api.php/provide/vod", "weight": 88, "precache": False},
    {"name": "魔都", "api": "https://caiji.moduapi.cc/api.php/provide/vod", "weight": 86, "precache": False},
    {"name": "红牛", "api": "https://www.hongniuzy2.com/api.php/provide/vod", "weight": 84, "precache": False},
    # —— 动漫专门站：来自 Animeko 订阅的 30 站中唯一暴露标准 JSON 接口者，
    #    VPS 实测多部新番可播(斗罗 / 咒术 / 进击 / 转生史莱姆)。 ——
    {"name": "风车", "api": "https://www.dongmandaquan.vip/api.php/provide/vod", "weight": 80, "precache": False},  # 番剧为主
    # —— 第二梯队：VPS 实测部分类型可播(注释标注命中类型) ——
    {"name": "爱奇艺", "api": "https://iqiyizyapi.com/api.php/provide/vod", "weight": 78, "precache": False},  # 番剧/电影
    {"name": "量子", "api": "https://cj.lziapi.com/api.php/provide/vod", "weight": 76, "precache": False},  # 番剧/电影
    {"name": "电影天堂", "api": "http://caiji.dyttzyapi.com/api.php/provide/vod", "weight": 74, "precache": False},  # 番剧/剧集
    {"name": "金鹰", "api": "https://jyzyapi.com/api.php/provide/vod", "weight": 72, "precache": False},  # 剧集
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
