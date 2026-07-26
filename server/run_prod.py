"""
生产环境启动入口 (VPS 部署用)

与开发用的 run.py 区别:
  - reload=False   (不监视文件变化, 省内存/CPU)
  - host=127.0.0.1 (只监听本地, 由 nginx 反代对外; 无 nginx 时改 0.0.0.0)
  - log_level=warning

对外地址通过环境变量 PUBLIC_BASE_URL 配置, /check/api 会返回它。
"""

import os
import uvicorn

if __name__ == "__main__":
    required = {
        "TMDB_READ_ACCESS_TOKEN": os.getenv("TMDB_READ_ACCESS_TOKEN", "").strip(),
        "ADMIN_TOKEN": os.getenv("ADMIN_TOKEN", "").strip(),
        "SECRET_KEY": os.getenv("SECRET_KEY", "").strip(),
    }
    missing = [name for name, value in required.items() if len(value) < 32]
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
