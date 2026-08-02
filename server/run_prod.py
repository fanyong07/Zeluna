"""
生产环境启动入口 (VPS 部署用)

与开发用的 run.py 区别:
  - reload=False   (不监视文件变化, 省内存/CPU)
  - host=127.0.0.1 (只监听本地, 由 nginx 反代对外; 无 nginx 时改 0.0.0.0)
  - log_level=warning

对外地址通过环境变量 PUBLIC_BASE_URL 配置；默认关闭的 /check/api
仅在显式兼容模式下返回该地址，不下发第三方线路或代理配置。
"""

import os
import uvicorn

if __name__ == "__main__":
    long_secrets = {
        "TMDB_READ_ACCESS_TOKEN": os.getenv("TMDB_READ_ACCESS_TOKEN", "").strip(),
        "ADMIN_TOKEN": os.getenv("ADMIN_TOKEN", "").strip(),
        "SECRET_KEY": os.getenv("SECRET_KEY", "").strip(),
    }
    required_values = {
        "SMTP_HOST": os.getenv("SMTP_HOST", "").strip(),
        "SMTP_FROM_EMAIL": os.getenv("SMTP_FROM_EMAIL", "").strip(),
    }
    missing = [name for name, value in long_secrets.items() if len(value) < 32]
    missing.extend(name for name, value in required_values.items() if not value)
    smtp_username = os.getenv("SMTP_USERNAME", "").strip()
    if smtp_username and not os.getenv("SMTP_PASSWORD", ""):
        missing.append("SMTP_PASSWORD")
    if missing:
        raise SystemExit(
            "Production configuration missing or too short: " + ", ".join(missing)
        )
    host = os.getenv("BIND_HOST", "127.0.0.1")
    port = int(os.getenv("BIND_PORT", "8000"))
    uvicorn.run(
        "server.main:app",
        host=host,
        port=port,
        reload=False,
        workers=1,
        log_level=os.getenv("LOG_LEVEL", "warning"),
    )
