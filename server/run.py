"""
启动 AniCh API 服务器

用法:
  cd server
  pip install -r requirements.txt
  python run.py
"""

import uvicorn

if __name__ == "__main__":
    uvicorn.run(
        "server.main:app",
        host="0.0.0.0",
        port=8000,
        reload=True,
        log_level="info",
    )
