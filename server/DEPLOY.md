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
- 轻度过期但真实 URL 尚未失效的正缓存会立即返回，并在后台单飞刷新。
- 客户端首播走快速接口，只返回最多 3 个不同媒体域名；完整线路在后台扩展。
- systemd 常驻和崩溃重启，不使用 Docker 和浏览器爬虫。

## 必需的服务端环境变量

凭据只放在 VPS 的 `/etc/zeluna/zeluna.env`，权限设为 `600`。不要写进仓库、APK、EXE、日志或命令历史。

```dotenv
TMDB_READ_ACCESS_TOKEN=
BANGUMI_ACCESS_TOKEN=
ADMIN_TOKEN=
SECRET_KEY=
SMTP_HOST=smtp.example.com
SMTP_PORT=587
SMTP_USERNAME=
SMTP_PASSWORD=
SMTP_FROM_EMAIL=no-reply@example.com
SMTP_FROM_NAME=Zeluna
SMTP_USE_TLS=true
CORS_ORIGINS=https://你的客户端网页域名
LEGACY_ACCOUNT_API_ENABLED=false
LEGACY_CONFIG_API_ENABLED=false
PUBLIC_BASE_URL=https://你的后端域名
PRECACHE_ENABLED=false
SOURCE_MAX_CONCURRENCY=2
PLAYBACK_PROVIDER_IDS=
M3U8_SEARCH_ENABLED=false
SOURCE_CIRCUIT_FAILURE_THRESHOLD=5
SOURCE_CIRCUIT_BASE_COOLDOWN_SECONDS=300
SOURCE_CIRCUIT_MAX_COOLDOWN_SECONDS=3600
DATABASE_AUTO_CREATE=false
SQLITE_BUSY_TIMEOUT_MS=10000
SQLITE_CONNECT_TIMEOUT_SECONDS=30
PLAYBACK_STALE_HOURS=24
PLAYBACK_QUICK_TIMEOUT_SECONDS=4.5
PLAYBACK_QUICK_LINE_COUNT=3
```

- `TMDB_READ_ACCESS_TOKEN`：TMDB v4 Read Access Token，电视剧和电影目录必需。
- `BANGUMI_ACCESS_TOKEN`：可选；未配置时使用 Bangumi 公共接口。
- `ADMIN_TOKEN`：保护手动刷新和管理接口，必须是随机长字符串。
- `SECRET_KEY`：账户令牌和验证码摘要密钥，必须是独立随机值且至少 32 字节；空值、短值、低多样性值和历史占位值会让账号操作 fail-closed 返回 `503`。
- `SMTP_*`：邮箱注册、验证码和找回密码所需的发信服务，只能保存在 VPS 环境文件中。
- `CORS_ORIGINS`：只填写正式 Web 客户端域名；安卓和 Windows 客户端不受此项影响。
- `LEGACY_ACCOUNT_API_ENABLED`：正式环境保持 `false`，避免旧兼容注册接口绕过邮件验证。
- `LEGACY_CONFIG_API_ENABLED`：正式环境保持 `false`；仅迁移旧客户端时临时启用，响应也不会下发第三方线路或代理地址。
- `DATABASE_AUTO_CREATE`：正式环境必须为 `false`；表结构只通过 Alembic 迁移变更。
- `SOURCE_CIRCUIT_*`：连续失败达到阈值后短暂跳过坏源，并以指数冷却自动重试；客户端候选不算硬失败。
- `PLAYBACK_PROVIDER_IDS`：逗号分隔的服务端 provider ID allowlist。默认留空，留空时搜索、详情、播放解析、首页清单和预热都不会调用任何播放 provider；只启用已经完成合规和网络验证的 ID。
- `M3U8_SEARCH_ENABLED`：通用 M3U8 搜索回退，正式环境默认 `false`。只有完成独立安全评审并明确批准时才可启用。
- `PRECACHE_ENABLED`：只有 `PLAYBACK_PROVIDER_IDS` 已显式配置且预热流量已获批准时才可设为 `true`。

## 数据库升级（启动服务前执行）

首次使用此版本或以后存在新迁移时，先停止服务，再显式升级数据库：

```bash
sudo systemctl stop zeluna.service
cd /opt/zeluna/app/server
set -a
. /etc/zeluna/zeluna.env
set +a
/opt/zeluna/venv/bin/python tools/migrate.py upgrade
sudo systemctl start zeluna.service
sudo systemctl --no-pager --full status zeluna.service
```

升级工具会在 SQLite 数据库旁的 `backups/` 目录先生成一致性备份，再执行到最新版本。普通服务启动只核对 Alembic 版本；数据库未迁移、版本落后或结构未知时会拒绝启动，不会静默改表。开发用的一次性数据库才可以显式设置 `DATABASE_AUTO_CREATE=true`。

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
WorkingDirectory=/opt/zeluna/app/server
EnvironmentFile=/etc/zeluna/zeluna.env
ExecStart=/opt/zeluna/venv/bin/python /opt/zeluna/app/server/run_prod.py
Restart=always
RestartSec=5
MemoryMax=420M
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/opt/zeluna/app/server/server

[Install]
WantedBy=multi-user.target
```

生产环境只让 Uvicorn 监听 `127.0.0.1:8000`，由 Nginx/Caddy 提供 HTTPS。不要把视频流反向代理到 VPS。

## 客户端构建

正式地址通过构建参数内置，用户无需配置源或规则：

```powershell
flutter build apk --release `
  --dart-define=ZELUNA_BACKEND_ENABLED=true `
  --dart-define=ZELUNA_BACKEND_URL=https://你的后端域名 `
  --dart-define=ZELUNA_ACCOUNT_URL=https://你的后端域名

flutter build windows --release `
  --dart-define=ZELUNA_BACKEND_ENABLED=true `
  --dart-define=ZELUNA_BACKEND_URL=https://你的后端域名 `
  --dart-define=ZELUNA_ACCOUNT_URL=https://你的后端域名
```

## 验收

```bash
curl https://你的后端域名/api/v3/status
curl 'https://你的后端域名/api/v3/catalog/search?query=葬送的芙莉莲'
curl 'https://你的后端域名/api/v3/quick-playback/bangumi:400602?episode=1&title=葬送的芙莉莲&content_type=anime&year=2023'
curl 'https://你的后端域名/api/v3/playback/bangumi:400602?episode=1&title=葬送的芙莉莲&content_type=anime&year=2023'
curl 'https://你的后端域名/api/v3/playback/tmdb:tv:95842?episode=1&title=庆余年&content_type=tv&year=2019'
curl 'https://你的后端域名/api/v3/playback/tmdb:movie:535167?episode=1&title=流浪地球&content_type=movie&year=2019'
```

验收要求：

- `/api/v3/status` 返回 `version: 3`，TMDB 配置状态为 true。
- 搜索结果只返回稳定作品 ID，不出现采集站内部 ID。
- 第一次播放完成验证并写缓存；第二次请求返回 `cached: true`。
- 热缓存快速接口应立即返回主线路，并尽量附带两个不同域名的备用线路；`stale: true` 表示旧线路仍可播且后台正在刷新。
- App 中不存在播放规则、外部源目录或规则导入入口。
- 后端不可用时 App 明确显示无线路，不回退本地爬虫。

## 当前工程 Goal 的部署边界

- 本工程 Goal 没有读取生产环境变量、访问生产数据库、探测生产 provider、重启服务或部署代码，因此不声明任何历史地址、源清单或账号服务仍处于已验证上线状态。
- 新版本默认 `PLAYBACK_PROVIDER_IDS=`、`M3U8_SEARCH_ENABLED=false`、`PRECACHE_ENABLED=false`。未显式配置时，目录元数据可按其独立配置工作，但播放 provider 不会产生出站请求。
- 正式部署前必须备份数据库、上传目录和可恢复旧版本，显式审核 provider allowlist，并重新检查服务状态、账号安全、三类播放、缓存、资源占用和回滚路径；这些属于 G13/G14 且需要单独授权。
