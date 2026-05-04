"""
AniCh API 复刻 — FastAPI 后端

协议兼容：
  - 大部分接口返回 protobuf 二进制（ResponseType.bytes）
  - 部分接口使用 JSON（/bangumi/detail/:id, /bangumi/character/:id 等）
  - 认证：Token 通过 _ header 传递
"""

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
CORS_ORIGINS = ["*"]
