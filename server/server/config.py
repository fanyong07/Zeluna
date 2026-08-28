"""Zeluna 后端配置。生产凭据只从环境变量读取。"""

import ipaddress
import os
from pathlib import Path

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
CORS_ORIGINS = [
    origin.strip()
    for origin in _cors_value.split(",")
    if origin.strip()
]


def _env_bool(name: str, default: bool = False) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def _env_csv(name: str) -> frozenset[str]:
    value = os.getenv(name, "")
    return frozenset(
        item.strip().lower()
        for item in value.split(",")
        if item.strip()
    )


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
MACCMS_FULL_ALIAS_LIMIT = max(
    1, min(8, int(os.getenv("MACCMS_FULL_ALIAS_LIMIT", "5")))
)
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
PLAYBACK_ANICH_LINE_TTL_HOURS = float(
    os.getenv("PLAYBACK_ANICH_LINE_TTL_HOURS", "2")
)

# 部分动漫站的站内搜索被边缘缓存冻结或首访即弹验证码,只能抓列表页建
# 本地 title→sid 索引。没有索引这些源等于没接上,所以由调度器定期重建。
SITE_INDEX_REBUILD_HOURS = max(
    1, min(168, int(os.getenv("SITE_INDEX_REBUILD_HOURS", "12")))
)
SITE_INDEX_PAGES = max(1, min(20, int(os.getenv("SITE_INDEX_PAGES", "4"))))
MANAGED_PLAYBACK_LINES_ENABLED = _env_bool(
    "MANAGED_PLAYBACK_LINES_ENABLED", False
)
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
LEGACY_JWT_COMPATIBILITY_ENABLED = _env_bool(
    "LEGACY_JWT_COMPATIBILITY_ENABLED", False
)
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
