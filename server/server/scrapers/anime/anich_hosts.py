"""AniCh 分发主机策略表(由逆向清单固化的**只读数据表**)。

来源:2026-11 对 AniCh 1.5.x 自建源的实测导出(70 部作品 / 1084 条线路),
以及对每条代表性线路做的一次真实首字节探测。本模块只做**纯函数分类**,
不发请求、不缓存、不落盘。

为什么单独成表
--------------
上游 ``/vod`` 返回的是**混装池**,实测家族占比::

    自建 CDN(官方转存)      389 条  35.9%
    广告素材(应识别)        307 条  28.3%   ← 纯贴片,不是正片
    大厂 CDN / 对象存储      300 条  27.7%
    采集站原始 HLS            88 条   8.1%

``anich.py`` 里原先只有两个自建 CDN 子串判据(``vod-cdn``/``v-cdn``),
既漏掉自建 CF 别名与官方转存跳转目标,也无法把"广告素材"与
"大厂对象存储"区分开——两者同属字节/快手系主机,正则到域名就会把
贴片算成最快线路。本表把**主机族**和**路径形状**一起作为判据。

延迟带宽(latency band)按 2026-08-28 客户端实测首字节归档,只用于
"同类内破平",不改变既有的"先快后画质"排序主线。
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from enum import Enum
from urllib.parse import urlparse

# ── 角色 ──────────────────────────────────────────────────────
SELF_HOSTED = "self_hosted"
"""上游自建/官方转存:画质最好但实测最慢(2.0~2.9s TTFB)。"""
PARTNER_EDGE = "partner_edge"
"""官方转存的合作边缘站(自建 CDN 302 的落点),同样偏慢。"""
OBJECT_STORE = "object_store"
"""大厂对象存储/CDN:实测最快(0.4s 级),作为起播主力。"""
SITE_HLS = "site_hls"
"""采集站原始 HLS:次快(0.5s 级)。"""
AD_CREATIVE = "ad_creative"
"""纯贴片/激励素材混入:正片播放时表现为无关视频,必须能与正片区分。"""
UNKNOWN = "unknown"

#: 延迟带(秒,首字节实测中位量级);越小越快。
_LATENCY_BAND: dict[str, float] = {
    OBJECT_STORE: 0.40,
    SITE_HLS: 0.50,
    PARTNER_EDGE: 2.00,
    SELF_HOSTED: 2.30,
    AD_CREATIVE: 0.45,
    UNKNOWN: 1.50,
}


class HostRole(str, Enum):
    SELF_HOSTED = SELF_HOSTED
    PARTNER_EDGE = PARTNER_EDGE
    OBJECT_STORE = OBJECT_STORE
    SITE_HLS = SITE_HLS
    AD_CREATIVE = AD_CREATIVE
    UNKNOWN = UNKNOWN


@dataclass(frozen=True)
class HostFamily:
    """一个主机族。``host`` 用小写子串匹配(自建 CF 别名以子域形式出现)。"""

    host: str
    role: HostRole
    note: str = ""

    @property
    def latency(self) -> float:
        return _LATENCY_BAND[self.role.value]


#: ── 上游自建(官方转存)────────────────────────────────────────
#  ``vod-cdn.*`` 是 HLS 编排目录;``v-cdn.*`` 是不透明 token 直链。
#  两者都是 302 → 合作边缘站/字节 CDN 的入口,不直接给出媒体字节。
SELF_HOSTED_HOSTS: tuple[str, ...] = (
    "vod-cdn.sends.eu.org",
    "v-cdn.emmmm.eu.org",
    "vo-cdn.emmmm.eu.org",          # 历史别名,仍在 CDN_PATTERNS 中
    "vod-cdn.emmmm.eu.org",
    "aigua.emmmm.eu.org",
)

#: ``vod-cdn`` 302 的真实落点(实测:自建域只做编排,取址接口在合作站)。
#  名单克制:只收录**在线实测确认**过的落点,避免把猜测写进代码。
PARTNER_EDGE_HOSTS: tuple[str, ...] = (
    "bkqiuqiu.",                     # .<中文域名>(punycode),/within/playaddr/getaddr.m3u8
)

#: 大厂对象存储 / CDN(实测最快;可作为首播候选)。
#  只收录**能按域名唯一识别**的族:签名直链里的 `tos-alisg` 这类 token 会
#  出现在任意字节系主机上,放进子串名单会误伤(实测夹具里
#  `dl.playxf.top/.../ad…` 曾因此被当成对象存储顶到首位)。
OBJECT_STORE_HOSTS: tuple[str, ...] = (
    "bytecdn.com",                   # lf16-faceu-file-sign.bytecdn.com
    "byteimg.com",                   # p3-/p6-faceu-img-sign.byteimg.com
    # ↑ 自建域 302 的真实落点。不加这一条,解出来的地址会被当成"未知交付"
    #   按代取流低分处理 —— 明明落在字节 CDN 上、实测 0.1s 级,却排在慢线路后面。
    "ibyteimg.com",
    "yximgs.com",
    "kwai.net",
    "adkwai.com",                    # 快手系转存与贴片同域,靠路径形状区分
    "vzcdn.net",                     # xgct-video.vzcdn.net(多码率 HLS,132 条)
    "myqcloud.com",
    "susercontent",
    "xiaohongshu.com",
    "xhscdn.com",
    "akamaized.net",
    "shihuocdn.cn",
    "kechuangai.com",
    # ── 自建域 302 的其他实测落点(字节/TikTok 系)──────────────────
    #  这些主机只在**解出包装地址后**才出现,域名本身不像字节,按子串
    #  单个收录;漏掉任何一个都会让对应线路掉进"未知交付"档。
    "capcutvod.com",
    "xzcs3zlph.com",
    "toutiao50.com",
    "hypstarcdn.com",
    "topbuzzcdn.com",
    "lemon8cdn.com",
    "titok-inc.com",
    "muscdn.com",
)

#: 采集站原始 HLS(域名与 m3u8_resolver / playback 的既有名单保持一致)。
#: 注意 ``playxf.top`` 不在其中:实测它属大厂对象存储族,归错会把它压到
#: 采集站档位,导致"先快后画质"的排序主线整体偏移。
SITE_HLS_HOSTS: tuple[str, ...] = (
    "yhdmm3u8.top",
    "yhdm3u8.top",
    "dlidli.cc",
    "xfvod.pro",
    "moedot.net",
    "92cj.com",
    "girigirilove.net",
    "girigirilove.com",
    "v300.eu.org",
)

#: ── 广告素材:必须按**主机族 + 路径形状**联合判定 ──────────────
#  这些主机同时承载正片(大厂转存)与贴片,只看域名无法区分;
#  实测贴片集中在下列路径形状下。**路径判据只对广告主投放域生效** ——
#  全局套用路径正则会把名字里带 ad/creative 的正常 CDN 目录误伤(实测
#  夹具里 `dl.playxf.top/.../ad…` 就被误判过)。
AD_CREATIVE_HOSTS: tuple[str, ...] = (
    "adkwai.com",                    # 快手广告投放(97 条),同域也有正片转存
    "v1-ad.video.yximgs.com",        # 广告专用子域(36 条)
    "cos.ffnews.cn",                 # feedback/ 语义目录,PNG 素材(85 条)
    "p19-creative-tool-sg.ibyteimg.com",  # 素材工具域(60 条)
    "s1.kwai.net",                   # 快手素材(25 条)
)

_AD_CREATIVE_PATH_RE = re.compile(
    r"/bs2/adVideoLp/"               # 快手广告投放目录
    r"|/adVideo"
    r"|ad_?alliance"
    r"|/feedback/"
    r"|/creative/"
    # 投放系统的 DSP 素材目录。实测两种形态:
    #   /bs2/ad-i18n-dsp/{md5}.mp4                    (明文)
    #   /bs2/photo-dsp-photo-upload/{base64}.mp4      (base64 解码后
    #      为 ``ad_dsp_photo_upload:...:MERCHANT:[B@...:...``,同样带 dsp)
    # ``dsp`` 作为独立词元出现,不会碰到正常目录名。
    r"|dsp[-_/]"
    r"|-dsp(?=[-_.]|$)",
    re.IGNORECASE,
)

#: 判据优先级:先命中"广告专用子域",再对投放域叠加路径形状。
_AD_EXACT_SUFFIXES: tuple[str, ...] = (
    "v1-ad.video.yximgs.com",
    "p19-creative-tool-sg.ibyteimg.com",
    "cos.ffnews.cn",
)

#: 同域既有正片又有投放的"混合域"。这些域**必须叠加路径形状**才能判广告 ——
#  整域判死会把同域的正片转存一起误杀。
#     adkwai.com / kwai.net:正片转存与广告素材共用
#     yximgs.com:广告专用子域 v1-ad 已由 _AD_EXACT_SUFFIXES 整域命中,
#                其余子域仍有正片,所以只在这里按路径兜底
_MIXED_AD_DOMAINS: tuple[str, ...] = ("adkwai.com", "kwai.net", "yximgs.com")

_ALL_FAMILIES: tuple[HostFamily, ...] = (
    *(HostFamily(h, HostRole.SELF_HOSTED, "官方转存入口") for h in SELF_HOSTED_HOSTS),
    *(HostFamily(h, HostRole.PARTNER_EDGE, "自建302落点") for h in PARTNER_EDGE_HOSTS),
    *(HostFamily(h, HostRole.OBJECT_STORE, "大厂CDN") for h in OBJECT_STORE_HOSTS),
    *(HostFamily(h, HostRole.SITE_HLS, "采集站HLS") for h in SITE_HLS_HOSTS),
    *(HostFamily(h, HostRole.AD_CREATIVE, "贴片素材") for h in AD_CREATIVE_HOSTS),
)


def hostname_of(url: str) -> str:
    try:
        return (urlparse(url).hostname or "").lower()
    except ValueError:
        return ""


def classify(url: str) -> HostRole:
    """把一条线路地址归入主机族角色。纯字符串判定,任何输入都不抛异常。"""
    host = hostname_of(url)
    if not host:
        return HostRole.UNKNOWN
    target = (url or "").lower()
    # 1) 广告专用子域:整域都是素材,无需看路径
    if any(suffix in host for suffix in _AD_EXACT_SUFFIXES):
        return HostRole.AD_CREATIVE
    # 2) 混合域(同域既有正片又有投放):必须叠加路径形状
    if any(family in host for family in _MIXED_AD_DOMAINS) and \
            _AD_CREATIVE_PATH_RE.search(target):
        return HostRole.AD_CREATIVE
    for family in _ALL_FAMILIES:
        if family.host in host:
            # 广告族在混合域下不单独命中(已在上面按路径处理)
            if family.role is HostRole.AD_CREATIVE:
                continue
            return family.role
    return HostRole.UNKNOWN


def is_ad_creative(url: str) -> bool:
    """该地址是否**确定**为贴片素材(正片池里应单独成组,不与正片混排)。"""
    return classify(url) is HostRole.AD_CREATIVE


def is_self_hosted(url: str) -> bool:
    """是否上游自建/官方转存(线路纯净度最高,但实测最慢)。"""
    return classify(url) is HostRole.SELF_HOSTED


def is_object_store(url: str) -> bool:
    return classify(url) is HostRole.OBJECT_STORE


def latency_band(url: str) -> float:
    """该线路的实测首字节量级(秒);用于同类内破平,不用于绝对取舍。"""
    return _LATENCY_BAND[classify(url).value]


def identity_tag(url: str) -> str:
    """给 UI 用的主机族短标签(不暴露上游聚合服务名称)。"""
    return {
        HostRole.SELF_HOSTED: "自建",
        HostRole.PARTNER_EDGE: "合作边缘",
        HostRole.OBJECT_STORE: "大厂CDN",
        HostRole.SITE_HLS: "采集站",
        HostRole.AD_CREATIVE: "贴片",
        HostRole.UNKNOWN: "其他",
    }[classify(url)]
