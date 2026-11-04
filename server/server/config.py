"""Zeluna 后端配置。生产凭据只从环境变量读取。"""

import ipaddress
import os
from pathlib import Path
from typing import Sequence

BASE_DIR = Path(__file__).resolve().parent
DATABASE_URL = os.getenv("DATABASE_URL", f"sqlite+aiosqlite:///{BASE_DIR}/data.db")
SECRET_KEY = os.getenv("SECRET_KEY", "").strip()
JWT_ALGORITHM = "HS256"


def _bounded_seconds(name: str, default: int, minimum: int, maximum: int) -> int:
    return max(minimum, min(maximum, int(os.getenv(name, str(default)))))


# Access tokens are deliberately short-lived. Refresh credentials are opaque
# and rotated by the account session service rather than represented as JWTs.
ACCESS_TOKEN_EXPIRE_SECONDS = _bounded_seconds(
    "ACCESS_TOKEN_EXPIRE_SECONDS", 15 * 60, 60, 60 * 60
)
REFRESH_TOKEN_EXPIRE_SECONDS = _bounded_seconds(
    "REFRESH_TOKEN_EXPIRE_SECONDS", 30 * 24 * 3600, 24 * 3600, 180 * 24 * 3600
)
# Retain the old import name for bounded compatibility with existing callers.
ACCESS_TOKEN_EXPIRE = ACCESS_TOKEN_EXPIRE_SECONDS

# 存储路径
UPLOAD_DIR = BASE_DIR / "uploads"
UPLOAD_DIR.mkdir(exist_ok=True)

# CORS 允许所有来源（客户端可以是任意设备）
_cors_value = os.getenv("CORS_ORIGINS", "").strip()
CORS_ORIGINS = [origin.strip() for origin in _cors_value.split(",") if origin.strip()]


def _env_bool(name: str, default: bool = False) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def _env_csv(name: str) -> frozenset[str]:
    value = os.getenv(name, "")
    return frozenset(item.strip().lower() for item in value.split(",") if item.strip())


def _env_list(name: str, default: Sequence[str] = ()) -> tuple[str, ...]:
    """逗号分隔的多值配置,保留大小写(URL、id 这类值不能小写化)。"""
    value = os.getenv(name)
    if value is None:
        return tuple(default)
    return tuple(item.strip() for item in value.split(",") if item.strip())


def _env_networks(
    name: str,
) -> tuple[ipaddress.IPv4Network | ipaddress.IPv6Network, ...]:
    value = os.getenv(name, "")
    networks: list[ipaddress.IPv4Network | ipaddress.IPv6Network] = []
    for item in value.split(","):
        candidate = item.strip()
        if not candidate:
            continue
        try:
            networks.append(ipaddress.ip_network(candidate, strict=False))
        except ValueError as error:
            raise RuntimeError(f"{name} contains an invalid IP network") from error
    return tuple(networks)


# Production never mutates the schema during ordinary application startup.
# Local throwaway environments may opt in explicitly.
DATABASE_AUTO_CREATE = _env_bool("DATABASE_AUTO_CREATE", False)
SQLITE_BUSY_TIMEOUT_MS = max(1000, int(os.getenv("SQLITE_BUSY_TIMEOUT_MS", "10000")))
SQLITE_CONNECT_TIMEOUT_SECONDS = max(
    1.0, float(os.getenv("SQLITE_CONNECT_TIMEOUT_SECONDS", "30"))
)
PRIVACY_CLEANUP_INTERVAL_HOURS = max(
    1, min(168, int(os.getenv("PRIVACY_CLEANUP_INTERVAL_HOURS", "24")))
)
ACCOUNT_DELETION_GRACE_SECONDS = 7 * 24 * 3600
ACCOUNT_DELETION_BATCH_SIZE = max(
    1, min(1000, int(os.getenv("ACCOUNT_DELETION_BATCH_SIZE", "100")))
)


# Public source quality varies by network location. Keep speculative background
# crawling off by default; on-demand playback still verifies and caches lines.
PRECACHE_ENABLED = _env_bool("PRECACHE_ENABLED", False)
PRECACHE_INTERVAL_HOURS = max(1, int(os.getenv("PRECACHE_INTERVAL_HOURS", "4")))
PRECACHE_MAX_SUBJECTS = max(1, int(os.getenv("PRECACHE_MAX_SUBJECTS", "24")))

# 元数据凭据只从服务端环境读取。不要把个人 Token 写进 Flutter 构建、
# 数据库、仓库或日志。Bangumi 的公开接口可在未配置 Token 时降级使用，
# TMDB 则必须配置 v4 Read Access Token。
BANGUMI_ACCESS_TOKEN = os.getenv("BANGUMI_ACCESS_TOKEN", "").strip()
TMDB_READ_ACCESS_TOKEN = os.getenv("TMDB_READ_ACCESS_TOKEN", "").strip()

# 弹弹play开放平台凭据只能存在于服务端环境。Flutter 客户端只控制是否
# 请求聚合弹幕，不能读取、保存或转发 AppSecret。
DANDANPLAY_ENABLED = _env_bool("DANDANPLAY_ENABLED", False)
DANDANPLAY_APP_ID = os.getenv("DANDANPLAY_APP_ID", "").strip()
DANDANPLAY_APP_SECRET = os.getenv("DANDANPLAY_APP_SECRET", "").strip()
DANDANPLAY_REQUEST_TIMEOUT_SECONDS = max(
    1.0,
    min(30.0, float(os.getenv("DANDANPLAY_REQUEST_TIMEOUT_SECONDS", "8"))),
)
DANDANPLAY_CACHE_SECONDS = _bounded_seconds(
    "DANDANPLAY_CACHE_SECONDS", 7200, 60, 24 * 3600
)
DANDANPLAY_EMPTY_CACHE_SECONDS = _bounded_seconds(
    "DANDANPLAY_EMPTY_CACHE_SECONDS", 120, 10, 3600
)
DANDANPLAY_CACHE_MAX_ENTRIES = max(
    1, min(100_000, int(os.getenv("DANDANPLAY_CACHE_MAX_ENTRIES", "2048")))
)
DANDANPLAY_MAX_RESPONSE_BYTES = max(
    64 * 1024,
    min(
        32 * 1024 * 1024,
        int(os.getenv("DANDANPLAY_MAX_RESPONSE_BYTES", str(8 * 1024 * 1024))),
    ),
)
DANDANPLAY_CLIENT_RATE_LIMIT_PER_MINUTE = max(
    1,
    min(
        600,
        int(os.getenv("DANDANPLAY_CLIENT_RATE_LIMIT_PER_MINUTE", "30")),
    ),
)

CATALOG_CACHE_HOURS = max(1, int(os.getenv("CATALOG_CACHE_HOURS", "24")))
PLAYBACK_CACHE_HOURS = max(1, int(os.getenv("PLAYBACK_CACHE_HOURS", "6")))
PLAYBACK_PARTIAL_CACHE_MINUTES = max(
    1, int(os.getenv("PLAYBACK_PARTIAL_CACHE_MINUTES", "10"))
)
PLAYBACK_STABLE_LINE_COUNT = max(1, int(os.getenv("PLAYBACK_STABLE_LINE_COUNT", "4")))
PLAYBACK_NEGATIVE_CACHE_MINUTES = max(
    1, int(os.getenv("PLAYBACK_NEGATIVE_CACHE_MINUTES", "5"))
)
PLAYBACK_STALE_HOURS = max(1, int(os.getenv("PLAYBACK_STALE_HOURS", "24")))
# Keep a full HTTP response below the app's 18-second request budget. The
# shared scan continues after this deadline; partial results are never full cache.
PLAYBACK_FULL_RESPONSE_TIMEOUT_SECONDS = max(
    0.1, min(10.0, float(os.getenv("PLAYBACK_FULL_RESPONSE_TIMEOUT_SECONDS", "10")))
)
PLAYBACK_QUICK_TIMEOUT_SECONDS = max(
    0.5, min(8.0, float(os.getenv("PLAYBACK_QUICK_TIMEOUT_SECONDS", "4.5")))
)
# 首播优先取够这么多条可播线路即可开播;其余来源仍会在完整扫描里查完,
# 列表不会因此缺项(缺项只会短暂出现在 quick 响应里)。
PLAYBACK_QUICK_LINE_COUNT = max(
    1, min(12, int(os.getenv("PLAYBACK_QUICK_LINE_COUNT", "6")))
)
PLAYBACK_QUICK_MAX_IN_FLIGHT_CANDIDATES = max(
    1,
    min(
        12,
        int(os.getenv("PLAYBACK_QUICK_MAX_IN_FLIGHT_CANDIDATES", "6")),
    ),
)
MACCMS_QUICK_ALIAS_LIMIT = max(
    1, min(5, int(os.getenv("MACCMS_QUICK_ALIAS_LIMIT", "3")))
)
MACCMS_QUICK_QUERY_BUDGET = max(
    1, min(500, int(os.getenv("MACCMS_QUICK_QUERY_BUDGET", "32")))
)
MACCMS_FULL_ALIAS_LIMIT = max(1, min(8, int(os.getenv("MACCMS_FULL_ALIAS_LIMIT", "5"))))
MACCMS_FULL_QUERY_BUDGET = max(
    1, min(1000, int(os.getenv("MACCMS_FULL_QUERY_BUDGET", "120")))
)
MACCMS_SEARCH_MAX_CONCURRENCY = max(
    1, min(20, int(os.getenv("MACCMS_SEARCH_MAX_CONCURRENCY", "10")))
)
MACCMS_FALLBACK_WAVE_DELAY_SECONDS = max(
    0.0,
    min(
        2.0,
        float(os.getenv("MACCMS_FALLBACK_WAVE_DELAY_SECONDS", "0.35")),
    ),
)
# AniCh 聚合源(按需代取)。上游有风控:请求间隔必须保底,否则 403/429。
ANICH_MIN_REQUEST_INTERVAL_SECONDS = max(
    0.2, min(10, float(os.getenv("ANICH_MIN_REQUEST_INTERVAL_SECONDS", "1.2")))
)
ANICH_HTTP_TIMEOUT_SECONDS = max(
    3.0, min(60.0, float(os.getenv("ANICH_HTTP_TIMEOUT_SECONDS", "15")))
)
ANICH_BACKOFF_MAX_SECONDS = max(
    1.0, min(120.0, float(os.getenv("ANICH_BACKOFF_MAX_SECONDS", "20")))
)
ANICH_BASE_COOLDOWN_SECONDS = max(
    30.0, min(3600.0, float(os.getenv("ANICH_BASE_COOLDOWN_SECONDS", "300")))
)
# 单集线路截断:上游单集可达 58 条,不截断会让后续并发探测打洪峰。
ANICH_MAX_LINES_PER_EPISODE = max(
    1, min(12, int(os.getenv("ANICH_MAX_LINES_PER_EPISODE", "6")))
)
# crawler.anich 直链无签名参数(逐线 expires_at 恒为 0),但实测天级易腐:
# 在混合来源缓存行上为该源单独盖短 TTL,0/负值关闭盖章行为。
PLAYBACK_ANICH_LINE_TTL_HOURS = float(os.getenv("PLAYBACK_ANICH_LINE_TTL_HOURS", "2"))

# 自建中转(relay):把取数入口指向自己的服务,而不是直连上游。
# 空值 = 直连上游(默认,行为不变)。
# 填了就把**所有**请求打到该地址,由中转负责取数、剔广告素材、中性化线路名。
# 用逗号分隔可给多个中转做容灾轮转。
ANICH_RELAY_BASE = os.getenv("ANICH_RELAY_BASE", "").strip().rstrip("/")
# 中转若开启鉴权,这里配同一个共享密钥(随 X-Relay-Key 头发出)。
ANICH_RELAY_KEY = os.getenv("ANICH_RELAY_KEY", "").strip()
# 走中转时上游的节流由中转侧统一保证,本地间隔可以放宽到几乎不限。
# 未配置中转时保持 1.2s 的保守间隔。
ANICH_RELAY_MIN_INTERVAL_SECONDS = max(
    0.0, min(10.0, float(os.getenv("ANICH_RELAY_MIN_INTERVAL_SECONDS", "0.05")))
)
# 中转交付的播放地址会带它自己的**对外**域名(例如 https://api.example.com:8443)。
# 后端与本机中转在同一台机器上,若照这个域名去取流,出站要绕一圈公网
# DNS + TLS 再回到本机 —— 慢,而且域名一旦解析不了就整条播放失败(已实测
# 过:目标机上的解析器解析不了该域名)。
#
# 所以分两个值:
#   ANICH_RELAY_PUBLIC_BASE —— 中转对外域名,用来**识别**要替换的地址;
#   ANICH_RELAY_FETCH_BASE  —— 中转回环地址,后端取流时替换成它。
# 两者任一为空 = 不改写(中转与后端不同机时保持原样)。
ANICH_RELAY_PUBLIC_BASE = os.getenv(
    "ANICH_RELAY_PUBLIC_BASE", ""
).strip().rstrip("/")
ANICH_RELAY_FETCH_BASE = os.getenv(
    "ANICH_RELAY_FETCH_BASE", ""
).strip().rstrip("/")

# 自建 CDN 包装地址(v-cdn.emmmm.eu.org / vod-cdn.sends.eu.org)只是 302
# 包装层,不是媒体本体。本部署的出口 IP 被它按 IP 封禁(Cloudflare
# Error 1006),直连拿不到重定向,只会得到 403。
#
# 包装地址解址通过独立出口只取 Location;真实地址另走部署机直连首字节
# 探活。解址不跟随媒体,客户端最终直连 CDN;探活样本最多 1 KiB。
#   默认 http://127.0.0.1:7899(本机独立 mihomo)
#   显式空字符串 = 直连,仅在本机出口未被封禁时有效
ANICH_RESOLVE_PROXY = os.getenv(
    "ANICH_RESOLVE_PROXY", "http://127.0.0.1:7899"
).strip()

# 每 6 小时扫描:临期地址提前 12 小时重解;无签名地址也至少每天复检。
ANICH_RESOLVE_REFRESH_SECONDS = max(
    3600.0, float(os.getenv("ANICH_RESOLVE_REFRESH_SECONDS", "21600"))
)
ANICH_RESOLVE_REVERIFY_SECONDS = max(
    3600.0, float(os.getenv("ANICH_RESOLVE_REVERIFY_SECONDS", "86400"))
)

# 部分动漫站的站内搜索被边缘缓存冻结或首访即弹验证码,只能抓列表页建
# 本地 title→sid 索引。没有索引这些源等于没接上,所以由调度器定期重建。
SITE_INDEX_REBUILD_HOURS = max(
    1, min(168, int(os.getenv("SITE_INDEX_REBUILD_HOURS", "12")))
)
SITE_INDEX_PAGES = max(1, min(20, int(os.getenv("SITE_INDEX_PAGES", "4"))))
MANAGED_PLAYBACK_LINES_ENABLED = _env_bool("MANAGED_PLAYBACK_LINES_ENABLED", False)
MANAGED_PLAYBACK_LINES_REQUIRE_APPROVAL = _env_bool(
    "MANAGED_PLAYBACK_LINES_REQUIRE_APPROVAL", True
)
MANAGED_PLAYBACK_LINES_MAX_PER_EPISODE = max(
    1, min(100, int(os.getenv("MANAGED_PLAYBACK_LINES_MAX_PER_EPISODE", "8")))
)
MANAGED_PLAYBACK_LINES_PROBE_TIMEOUT_SECONDS = max(
    1.0,
    min(
        60.0,
        float(os.getenv("MANAGED_PLAYBACK_LINES_PROBE_TIMEOUT_SECONDS", "12")),
    ),
)
SOURCE_BINDING_HOURS = max(1, int(os.getenv("SOURCE_BINDING_HOURS", "24")))

# Kazumi 规则库(社区维护的 flat JSON 规则,apiLevel 9)。规则原本由客户端
# WebView 解释执行,服务端只做机械改写 + 明确降级,因此规则目录允许整体替换:
# 优先读环境变量指定的目录,便于运维跟上游仓库更新而不改代码。
#   空值 = 用仓库内自带快照(server/scrapers/anime/kazumi_rules_data/)
#   _data 目录只存规则数据,加载器位于 kazumi_rules.py。
KAZUMI_RULES_DIR = os.getenv("KAZUMI_RULES_DIR", "").strip()
# 默认**关闭**,与 crawler.animeko 同一处理:一个 provider 背后是十几个外部
# 站点,每轮搜索都会并发打到它们,不适合没人确认就默认开。
# 打开方式:KAZUMI_ENABLED=true 且把 crawler.kazumi 放进 PLAYBACK_PROVIDER_IDS。
KAZUMI_ENABLED = _env_bool("KAZUMI_ENABLED", False)
# 单条规则内的请求间隔下限。规则库指向几十个不同站点,同一轮搜索会并发打到
# 这些站,保底间隔避免被当成扫站。
KAZUMI_MIN_REQUEST_INTERVAL_SECONDS = max(
    0.0, min(10.0, float(os.getenv("KAZUMI_MIN_REQUEST_INTERVAL_SECONDS", "0.5")))
)
KAZUMI_HTTP_TIMEOUT_SECONDS = max(
    3.0, min(60.0, float(os.getenv("KAZUMI_HTTP_TIMEOUT_SECONDS", "12")))
)
# 一条规则的搜索最多保留多少条结果。作为聚合源,单站前 30 条足够覆盖同一部
# 番的不同命名(中文名/日文名/别名)。
KAZUMI_MAX_RESULTS_PER_RULE = max(
    1, min(100, int(os.getenv("KAZUMI_MAX_RESULTS_PER_RULE", "30")))
)
# 每轮全量搜索的总时长上限。规则库里有已知会挂死/TLS 断连的站点,不能让它们
# 把一次搜索拖成分钟级;超时后返回已拿到的部分结果,而不是整轮失败。
KAZUMI_SEARCH_DEADLINE_SECONDS = max(
    1.0, min(60.0, float(os.getenv("KAZUMI_SEARCH_DEADLINE_SECONDS", "15")))
)

SOURCE_MAX_CONCURRENCY = max(1, min(4, int(os.getenv("SOURCE_MAX_CONCURRENCY", "2"))))
PLAYBACK_PROVIDER_IDS = _env_csv("PLAYBACK_PROVIDER_IDS")
M3U8_SEARCH_ENABLED = _env_bool("M3U8_SEARCH_ENABLED", False)
SOURCE_CIRCUIT_FAILURE_THRESHOLD = max(
    2, min(20, int(os.getenv("SOURCE_CIRCUIT_FAILURE_THRESHOLD", "5")))
)
SOURCE_CIRCUIT_BASE_COOLDOWN_SECONDS = max(
    30, int(os.getenv("SOURCE_CIRCUIT_BASE_COOLDOWN_SECONDS", "300"))
)
SOURCE_CIRCUIT_MAX_COOLDOWN_SECONDS = max(
    SOURCE_CIRCUIT_BASE_COOLDOWN_SECONDS,
    int(os.getenv("SOURCE_CIRCUIT_MAX_COOLDOWN_SECONDS", "3600")),
)

# ── animeko-subs 规则库(crawler.animeko)──────────────────────────────
# 一个爬虫背后是一整个订阅规则库(21 个站点)。默认**关闭**:规则库要联网拉,
# 站点数量多、每站还各自有 requestInterval,不适合在没人确认的情况下默认开。
# 打开方式:ANIMEKO_ENABLED=true 且把 crawler.animeko 放进 PLAYBACK_PROVIDER_IDS。
ANIMEKO_ENABLED = _env_bool("ANIMEKO_ENABLED", False)

#: 订阅文件。css1 是 web-selector/json-api 主库,bt1 是两个 RSS(BT)站。
ANIMEKO_SUBSCRIPTION_URLS = _env_list(
    "ANIMEKO_SUBSCRIPTION_URLS",
    (
        "https://sub.creamycake.org/v1/css1.json",
        "https://sub.creamycake.org/v1/bt1.json",
    ),
)

#: 拉订阅走的代理。留空 = 直连(订阅站在公网,生产机通常不需要代理)。
ANIMEKO_SUBSCRIPTION_PROXY = os.getenv("ANIMEKO_SUBSCRIPTION_PROXY", "").strip()

#: 规则快照目录。拉不到订阅时用它兜底;写不进去只记日志。
ANIMEKO_RULES_CACHE_DIR = os.getenv(
    "ANIMEKO_RULES_CACHE_DIR", str(BASE_DIR.parent / "data" / "animeko")
).strip()
ANIMEKO_RULES_CACHE_SECONDS = max(
    600, int(os.getenv("ANIMEKO_RULES_CACHE_SECONDS", str(6 * 3600)))
)

#: 单次 HTTP 请求超时;与 provider 的整轮预算分别设置。
ANIMEKO_REQUEST_TIMEOUT_SECONDS = max(
    3.0, min(60.0, float(os.getenv("ANIMEKO_REQUEST_TIMEOUT_SECONDS", "15")))
)
ANIMEKO_REQUEST_RETRIES = max(0, min(5, int(os.getenv("ANIMEKO_REQUEST_RETRIES", "2"))))
#: 单源搜索预算与单个播放页取流预算,分开是因为后者还要跟进嵌套播放器页。
ANIMEKO_SOURCE_TIMEOUT_SECONDS = max(
    5.0, min(120.0, float(os.getenv("ANIMEKO_SOURCE_TIMEOUT_SECONDS", "25")))
)
ANIMEKO_PLAY_TIMEOUT_SECONDS = max(
    5.0, min(120.0, float(os.getenv("ANIMEKO_PLAY_TIMEOUT_SECONDS", "20")))
)

#: 详情页缓存时长。搜索→详情→取流是一次连续动作,不缓存就会把同一页抓两遍。
ANIMEKO_DETAIL_CACHE_SECONDS = max(
    0.0, min(3600.0, float(os.getenv("ANIMEKO_DETAIL_CACHE_SECONDS", "300")))
)
ANIMEKO_MAX_SUBJECTS_PER_SOURCE = max(
    1, min(60, int(os.getenv("ANIMEKO_MAX_SUBJECTS_PER_SOURCE", "20")))
)
#: 单集一次最多探几条线路(每条线路 = 一个额外播放页请求)。
ANIMEKO_PLAY_MAX_CHANNELS = max(
    1, min(10, int(os.getenv("ANIMEKO_PLAY_MAX_CHANNELS", "3")))
)

#: 允许被启用的规则 id 子集(留空 = 全部)。排查单个源时很好用。
ANIMEKO_SOURCE_IDS = _env_list("ANIMEKO_SOURCE_IDS", ())
#: 该 provider 声明的内容类型。规则库以番剧站为主,默认只接 anime。
ANIMEKO_CONTENT_TYPES = _env_list("ANIMEKO_CONTENT_TYPES", ("anime",))
ANIMEKO_USER_AGENT = os.getenv(
    "ANIMEKO_USER_AGENT",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
).strip()

# 生产环境必须设置。管理端点在未配置时直接不可用，而不是公开暴露。
ADMIN_TOKEN = os.getenv("ADMIN_TOKEN", "").strip()

# Email account delivery. Credentials belong only in the server environment.
SMTP_HOST = os.getenv("SMTP_HOST", "").strip()
SMTP_PORT = max(1, int(os.getenv("SMTP_PORT", "587")))
SMTP_USERNAME = os.getenv("SMTP_USERNAME", "").strip()
SMTP_PASSWORD = os.getenv("SMTP_PASSWORD", "")
SMTP_FROM_EMAIL = os.getenv("SMTP_FROM_EMAIL", "").strip()
SMTP_FROM_NAME = os.getenv("SMTP_FROM_NAME", "Zeluna").strip() or "Zeluna"
SMTP_USE_TLS = _env_bool("SMTP_USE_TLS", True)
SMTP_USE_SSL = _env_bool("SMTP_USE_SSL", False)
EMAIL_DELIVERY_ENABLED = bool(SMTP_HOST and SMTP_FROM_EMAIL)
EMAIL_OUTBOX_ENCRYPTION_KEY = os.getenv("EMAIL_OUTBOX_ENCRYPTION_KEY", "").strip()
EMAIL_OUTBOX_MAX_ATTEMPTS = max(
    1, min(12, int(os.getenv("EMAIL_OUTBOX_MAX_ATTEMPTS", "5")))
)
EMAIL_OUTBOX_BATCH_SIZE = max(
    1, min(100, int(os.getenv("EMAIL_OUTBOX_BATCH_SIZE", "20")))
)
EMAIL_OUTBOX_PROCESSING_TIMEOUT_SECONDS = max(
    60, min(24 * 3600, int(os.getenv("EMAIL_OUTBOX_PROCESSING_TIMEOUT_SECONDS", "900")))
)
EMAIL_OUTBOX_RETRY_BASE_SECONDS = max(
    5, min(3600, int(os.getenv("EMAIL_OUTBOX_RETRY_BASE_SECONDS", "30")))
)
EMAIL_OUTBOX_WORKER_INTERVAL_SECONDS = max(
    5, min(3600, int(os.getenv("EMAIL_OUTBOX_WORKER_INTERVAL_SECONDS", "15")))
)
LEGACY_ACCOUNT_API_ENABLED = _env_bool("LEGACY_ACCOUNT_API_ENABLED", False)
LEGACY_CONFIG_API_ENABLED = _env_bool("LEGACY_CONFIG_API_ENABLED", False)
LEGACY_JWT_COMPATIBILITY_ENABLED = _env_bool("LEGACY_JWT_COMPATIBILITY_ENABLED", False)
ACCOUNT_TRUSTED_PROXY_NETWORKS = _env_networks("ACCOUNT_TRUSTED_PROXY_CIDRS")
ACCOUNT_RATE_LIMIT_MAX_KEYS = max(
    100, min(100_000, int(os.getenv("ACCOUNT_RATE_LIMIT_MAX_KEYS", "10000")))
)
ACCOUNT_RATE_LIMIT_BACKEND = (
    os.getenv("ACCOUNT_RATE_LIMIT_BACKEND", "memory").strip().lower()
)
ACCOUNT_RATE_LIMIT_NAMESPACE = (
    os.getenv("ACCOUNT_RATE_LIMIT_NAMESPACE", "zeluna:rate:v1").strip()
    or "zeluna:rate:v1"
)
PUBLIC_BASE_URL = (
    os.getenv("PUBLIC_BASE_URL", "http://127.0.0.1:8000").strip().rstrip("/")
)

# Private persistent subtitle library; API reads never create the index.
# Point this at a persistent volume, never a public/static upload directory.
SUBTITLE_LIBRARY_DIR = Path(
    os.getenv("SUBTITLE_LIBRARY_DIR", "").strip() or BASE_DIR.parent / "data" / "subtitles"
).expanduser()

SUBTITLE_BLOB_STORAGE = os.getenv("SUBTITLE_BLOB_STORAGE", "local").strip().lower()
if SUBTITLE_BLOB_STORAGE not in {"local", "google_drive"}:
    raise RuntimeError("SUBTITLE_BLOB_STORAGE must be local or google_drive")
_subtitle_google_credentials = os.getenv("SUBTITLE_GOOGLE_CREDENTIALS_FILE", "").strip()
SUBTITLE_GOOGLE_CREDENTIALS_FILE = Path(_subtitle_google_credentials).expanduser() if _subtitle_google_credentials else None
SUBTITLE_GOOGLE_FOLDER_ID = os.getenv("SUBTITLE_GOOGLE_FOLDER_ID", "").strip()
SUBTITLE_CACHE_MAX_BYTES = max(0, min(1024, int(os.getenv("SUBTITLE_CACHE_MAX_MB", "256")))) * 1024 * 1024
