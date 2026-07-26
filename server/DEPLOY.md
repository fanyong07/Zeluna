# Zeluna 统一后端部署说明

## 目标

后端是客户端唯一的在线内容和播放入口：

- Bangumi 提供番剧元数据。
- TMDB 提供国内外电视剧和电影元数据。
- 客户端只传稳定作品 ID：`bangumi:{id}`、`tmdb:tv:{id}`、`tmdb:movie:{id}`。
- 后端在多个已验证采集站中绑定同一作品，检查真实播放地址并缓存。
- 后台持续刷新热门目录和用户访问过的线路；不代理、转发或存储视频流。

## VPS 资源策略

目标机器是 1 核、2GB 内存、约 30GB 磁盘，因此采用：

- 单 Uvicorn worker。
- SQLite。
- 全局最多 2 个查源刷新任务。
- 首次未命中按需抓取，命中后直接返回缓存。
- 正缓存 6 小时，负缓存 5 分钟，避免失效作品反复拖慢服务器。
- systemd 常驻和崩溃重启，不使用 Docker 和浏览器爬虫。

## 必需的服务端环境变量

凭据只放在 VPS 的 `/etc/zeluna/zeluna.env`，权限设为 `600`。不要写进仓库、APK、EXE、日志或命令历史。

```dotenv
TMDB_READ_ACCESS_TOKEN=
BANGUMI_ACCESS_TOKEN=
ADMIN_TOKEN=
SECRET_KEY=
PUBLIC_BASE_URL=https://你的后端域名
PRECACHE_ENABLED=true
SOURCE_MAX_CONCURRENCY=2
```

- `TMDB_READ_ACCESS_TOKEN`：TMDB v4 Read Access Token，电视剧和电影目录必需。
- `BANGUMI_ACCESS_TOKEN`：可选；未配置时使用 Bangumi 公共接口。
- `ADMIN_TOKEN`：保护手动刷新和管理接口，必须是随机长字符串。
- `SECRET_KEY`：账户令牌签名，必须是独立随机长字符串。

## systemd

```ini
[Unit]
Description=Zeluna Backend
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=zeluna
Group=zeluna
WorkingDirectory=/opt/zeluna/server
EnvironmentFile=/etc/zeluna/zeluna.env
ExecStart=/opt/zeluna/venv/bin/python /opt/zeluna/server/run_prod.py
Restart=always
RestartSec=5
MemoryMax=420M
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/opt/zeluna/server/server

[Install]
WantedBy=multi-user.target
```

生产环境只让 Uvicorn 监听 `127.0.0.1:8000`，由 Nginx/Caddy 提供 HTTPS。不要把视频流反向代理到 VPS。

## 客户端构建

正式地址通过构建参数内置，用户无需配置源或规则：

```powershell
flutter build apk --release `
  --dart-define=ZELUNA_BACKEND_ENABLED=true `
  --dart-define=ZELUNA_BACKEND_URL=https://你的后端域名

flutter build windows --release `
  --dart-define=ZELUNA_BACKEND_ENABLED=true `
  --dart-define=ZELUNA_BACKEND_URL=https://你的后端域名
```

## 验收

```bash
curl https://你的后端域名/api/v3/status
curl 'https://你的后端域名/api/v3/catalog/search?query=葬送的芙莉莲'
curl 'https://你的后端域名/api/v3/playback/bangumi:400602?episode=1&title=葬送的芙莉莲&content_type=anime&year=2023'
```

验收要求：

- `/api/v3/status` 返回 `version: 3`，TMDB 配置状态为 true。
- 搜索结果只返回稳定作品 ID，不出现采集站内部 ID。
- 第一次播放完成验证并写缓存；第二次请求返回 `cached: true`。
- App 中不存在播放规则、外部源目录或规则导入入口。
- 后端不可用时 App 明确显示无线路，不回退本地爬虫。

## 当前上线边界

代码和部署方案可以在本地完成；上传 VPS、安装系统包、创建 systemd 服务、开放端口或域名上线属于外部部署操作，执行前必须再次确认。
