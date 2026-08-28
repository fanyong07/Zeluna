"""动漫直连站点清单(与 maccms_sites.py 并列,记录站点层事实)。

字段说明:
  site        解析器标识,与 ``SiteAnimeScraper.site`` 一致
  family      域名族。这类站换域极勤,同族域名共享一份解析形态
  base        当次实测可用的基址
  status      三值:
                ok           搜索/详情/播放/取流全通,可进运行时
                parsed-dead  解析链路通,但上游 CDN 已无货(解析器保留不删,
                             货源恢复即零改动复活)
                dead         拿不到 sid 或详情页无播放形态,解析器不写
  lines       实测单集可播线路数
  search      site(站内搜索可用) | index(仅列表页索引) | none
  verified_at 最近一次真机验证日期
  notes       关键事实与坑

⚠️ 站点判定必须用**真实作品名**验证。用首页随机 sid 验会把活站误判成死站:
   2026-08-28 首轮用随机 sid 时 yhdmm 全 404,换真实番剧后 4/4 可播。
"""

from __future__ import annotations

from .site_base import (
    SITE_STATUS_DEAD,
    SITE_STATUS_OK,
    SITE_STATUS_PARSED_DEAD,
)

ANIME_SITES: tuple[dict, ...] = (
    {
        "site": "yhdmm",
        "family": "yinghua",
        "base": "https://www.yhdmm.com",
        "status": SITE_STATUS_OK,
        "lines": 8,
        "search": "index",
        "verified_at": "2026-08-28",
        "notes": (
            "单集 8 条线路跨多个 CDN,实测可播(fengbao12 / svip.xgplay20 等),"
            "个别线路 ConnectError 由换线兜住;"
            "站内搜索**部分**可用但被边缘缓存干扰(同一路径下换词曾返回同长页面),"
            "因此以列表页本地索引为准,搜索只作补充"
        ),
    },
    {
        "site": "girigiri",
        "family": "girigirilove",
        "base": "https://anime.girigirilove.com",
        "status": SITE_STATUS_OK,
        "lines": 4,
        "search": "index",
        "verified_at": "2026-08-28",
        "notes": (
            "内容站在 anime./ani. 子域,主域是落地页;encrypt=2 为 "
            "base64(urlencode(明文)) 双层;搜索对程序化请求返回验证码页"
        ),
    },
    # —— 以下解析形态已验证,但当次实测上游无货。解析器保留(若已写),
    #    不进运行时;货源恢复后改 status 即可复活。 ——
    {
        "site": "yhdm365",
        "family": "yinghua",
        "base": "https://www.yhdm365.cc",
        "status": SITE_STATUS_PARSED_DEAD,
        "lines": 0,
        "search": "index",
        "verified_at": "2026-08-28",
        "notes": "详情 /vod_{id}.html;取流 4/4 HTTP 403(带 Referer 仍 403,疑更严防盗链)",
    },
    {
        "site": "dmttang",
        "family": "yinghua",
        "base": "https://www.dmttang.com",
        "status": SITE_STATUS_PARSED_DEAD,
        "lines": 0,
        "search": "site",
        "verified_at": "2026-08-28",
        "notes": "站内搜索可用;取流 4/4 404(s3.fsvod1.com / vip.lz-cdn3.com)",
    },
    {
        "site": "yhdmfan",
        "family": "yinghua",
        "base": "https://www.yhdmfan.cc",
        "status": SITE_STATUS_PARSED_DEAD,
        "lines": 0,
        "search": "index",
        "verified_at": "2026-08-28",
        "notes": "详情 /v/{id}.html;取流 4/4 404(v.lzcdn27.com / v.cdnlz22.com)",
    },
    {
        "site": "yhnime",
        "family": "yinghua",
        "base": "https://yhnime.com",
        "status": SITE_STATUS_PARSED_DEAD,
        "lines": 0,
        "search": "index",
        "verified_at": "2026-08-28",
        "notes": "详情 /v/{id}.html + 播放 /p/{id}-{线}-{集}.html;取流 4/4 404",
    },
    {
        "site": "yinghuadh",
        "family": "yinghua",
        "base": "https://www.yinghuadh.com",
        "status": SITE_STATUS_PARSED_DEAD,
        "lines": 0,
        "search": "site",
        "verified_at": "2026-08-28",
        "notes": "详情 /post/{id}.html;播放页多为 iqiyi/youku 外链,非自有源",
    },
    # —— 拿不到 sid 或详情页无播放形态,不写解析器 ——
    {
        "site": "yhdmone",
        "family": "yinghua",
        "base": "https://yhdm.one",
        "status": SITE_STATUS_DEAD,
        "lines": 0,
        "search": "site",
        "verified_at": "2026-08-28",
        "notes": "搜索可用且详情链接多,但详情页无任何已知播放页形态,需单独适配",
    },
    {
        "site": "yhdminfo",
        "family": "yinghua",
        "base": "https://www.yhdm.info",
        "status": SITE_STATUS_DEAD,
        "lines": 0,
        "search": "none",
        "verified_at": "2026-08-28",
        "notes": "详情 /vod_{id}.html 可达,但无播放页形态",
    },
    {
        "site": "yhdmp",
        "family": "yinghua",
        "base": "https://www.yhdmp.cc",
        "status": SITE_STATUS_DEAD,
        "lines": 0,
        "search": "none",
        "verified_at": "2026-08-28",
        "notes": "js-gate:返回 4733B「Redirecting…」弃用域告别页,解析器已删除",
    },
)

#: 域名族 → 候选域(按优先序;供 DomainWatch 轮换)。
#  同族域名共享解析形态,某域失效时可就地切换而不必改代码。
ANIME_DOMAIN_FAMILIES: dict[str, tuple[str, ...]] = {
    "yinghua": (
        "https://www.yhdmm.com",
        "https://www.yhdm365.cc",
        "https://www.dmttang.com",
        "https://www.yhdmfan.cc",
        "https://yhnime.com",
        "https://www.yinghuadh.com",
        "https://yhdm.one",
        "https://www.yhdm.info",
    ),
    "girigirilove": (
        "https://anime.girigirilove.com",
        "https://ani.girigirilove.com",
        "https://www.girigirilove.com",
    ),
}


def sites_by_status(status: str) -> tuple[dict, ...]:
    return tuple(item for item in ANIME_SITES if item["status"] == status)


def usable_sites() -> tuple[dict, ...]:
    """可进运行时的站点(status == ok)。"""
    return sites_by_status(SITE_STATUS_OK)


def site_entry(site: str) -> dict | None:
    for item in ANIME_SITES:
        if item["site"] == site:
            return item
    return None


def family_of(site: str) -> str:
    entry = site_entry(site)
    return str(entry["family"]) if entry else ""
