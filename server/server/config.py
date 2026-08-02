"""Zeluna 后端配置。生产凭据只从环境变量读取。"""

import os
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
DATABASE_URL = os.getenv("DATABASE_URL", f"sqlite+aiosqlite:///{BASE_DIR}/data.db")
SECRET_KEY = os.getenv("SECRET_KEY", "anich-secret-key-change-in-production")
JWT_ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE = 30 * 24 * 3600  # 30 days

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


# Production never mutates the schema during ordinary application startup.
# Local throwaway environments may opt in explicitly.
DATABASE_AUTO_CREATE = _env_bool("DATABASE_AUTO_CREATE", False)
SQLITE_BUSY_TIMEOUT_MS = max(
    1000, int(os.getenv("SQLITE_BUSY_TIMEOUT_MS", "10000"))
)
SQLITE_CONNECT_TIMEOUT_SECONDS = max(
    1.0, float(os.getenv("SQLITE_CONNECT_TIMEOUT_SECONDS", "30"))
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
PLAYBACK_STABLE_LINE_COUNT = max(
    1, int(os.getenv("PLAYBACK_STABLE_LINE_COUNT", "4"))
)
PLAYBACK_NEGATIVE_CACHE_MINUTES = max(
    1, int(os.getenv("PLAYBACK_NEGATIVE_CACHE_MINUTES", "5"))
)
PLAYBACK_STALE_HOURS = max(1, int(os.getenv("PLAYBACK_STALE_HOURS", "24")))
PLAYBACK_QUICK_TIMEOUT_SECONDS = max(
    0.5, min(8.0, float(os.getenv("PLAYBACK_QUICK_TIMEOUT_SECONDS", "4.5")))
)
PLAYBACK_QUICK_LINE_COUNT = max(
    1, min(5, int(os.getenv("PLAYBACK_QUICK_LINE_COUNT", "3")))
)
SOURCE_BINDING_HOURS = max(1, int(os.getenv("SOURCE_BINDING_HOURS", "24")))
SOURCE_MAX_CONCURRENCY = max(1, min(4, int(os.getenv("SOURCE_MAX_CONCURRENCY", "2"))))
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
LEGACY_ACCOUNT_API_ENABLED = _env_bool("LEGACY_ACCOUNT_API_ENABLED", False)
LEGACY_CONFIG_API_ENABLED = _env_bool("LEGACY_CONFIG_API_ENABLED", False)
PUBLIC_BASE_URL = (
    os.getenv("PUBLIC_BASE_URL", "http://127.0.0.1:8000").strip().rstrip("/")
)
