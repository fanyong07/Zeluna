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
SMTP_HOST=smtp.example.com
SMTP_PORT=587
SMTP_USERNAME=
SMTP_PASSWORD=
SMTP_FROM_EMAIL=no-reply@example.com
SMTP_FROM_NAME=Zeluna
SMTP_USE_TLS=true
CORS_ORIGINS=https://你的客户端网页域名
LEGACY_ACCOUNT_API_ENABLED=false
PUBLIC_BASE_URL=https://你的后端域名
PRECACHE_ENABLED=true
SOURCE_MAX_CONCURRENCY=2
```

- `TMDB_READ_ACCESS_TOKEN`：TMDB v4 Read Access Token，电视剧和电影目录必需。
- `BANGUMI_ACCESS_TOKEN`：可选；未配置时使用 Bangumi 公共接口。
- `ADMIN_TOKEN`：保护手动刷新和管理接口，必须是随机长字符串。
- `SECRET_KEY`：账户令牌签名，必须是独立随机长字符串。
- `SMTP_*`：邮箱注册、验证码和找回密码所需的发信服务，只能保存在 VPS 环境文件中。
- `CORS_ORIGINS`：只填写正式 Web 客户端域名；安卓和 Windows 客户端不受此项影响。
- `LEGACY_ACCOUNT_API_ENABLED`：正式环境保持 `false`，避免旧兼容注册接口绕过邮件验证。

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
curl 'https://你的后端域名/api/v3/playback/bangumi:400602?episode=1&title=葬送的芙莉莲&content_type=anime&year=2023'
curl 'https://你的后端域名/api/v3/playback/tmdb:tv:95842?episode=1&title=庆余年&content_type=tv&year=2019'
curl 'https://你的后端域名/api/v3/playback/tmdb:movie:535167?episode=1&title=流浪地球&content_type=movie&year=2019'
```

验收要求：

- `/api/v3/status` 返回 `version: 3`，TMDB 配置状态为 true。
- 搜索结果只返回稳定作品 ID，不出现采集站内部 ID。
- 第一次播放完成验证并写缓存；第二次请求返回 `cached: true`。
- App 中不存在播放规则、外部源目录或规则导入入口。
- 后端不可用时 App 明确显示无线路，不回退本地爬虫。

## 部署与验证状态（2026-07-28）

- 正式地址为 `https://api.zeluna.top`，`zeluna.service` 已部署并由 systemd 管理。
- 当前生产清单包含 18 个逐站接入的 MacCMS 影视源，以及 AGE、706、GiriGiri、西瓜卡通、叽哔、樱花动漫、wedm 7 个独立动漫适配器。
- 泥视频（影视/动漫）和 PPnix（影视）两个无广告优先适配器已于 2026-07-28 正式上线；它们不调用 AniCh、其镜像或外部通用聚合解析器。
- 番剧、电视剧和电影都已从正式 HTTPS 地址完成 HLS 清单、AES 密钥（如有）与首媒体分片验证；缓存命中时直接返回。
- 云端账号 API 已启用，旧兼容账号接口已关闭。SMTP 未完整配置时，验证码接口会明确返回 `503`，不会在日志或响应中泄露验证码，也不会绕过邮箱验证创建账号。
- 每次替换生产代码前都应保留数据库、上传目录及可恢复的旧版本，部署后重新检查服务状态、三类播放、缓存和资源占用。
