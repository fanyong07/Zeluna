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
MANAGED_PLAYBACK_LINES_ENABLED=false
MANAGED_PLAYBACK_LINES_REQUIRE_APPROVAL=true
MANAGED_PLAYBACK_LINES_MAX_PER_EPISODE=8
MANAGED_PLAYBACK_LINES_PROBE_TIMEOUT_SECONDS=12
ANICH_MIN_REQUEST_INTERVAL_SECONDS=1.2
ANICH_HTTP_TIMEOUT_SECONDS=15
ANICH_BACKOFF_MAX_SECONDS=20
ANICH_BASE_COOLDOWN_SECONDS=300
ANICH_MAX_LINES_PER_EPISODE=6
PLAYBACK_ANICH_LINE_TTL_HOURS=2
```

- `TMDB_READ_ACCESS_TOKEN`：TMDB v4 Read Access Token，电视剧和电影目录必需。
- `BANGUMI_ACCESS_TOKEN`：可选；未配置时使用 Bangumi 公共接口。
- `ADMIN_TOKEN`：保护手动刷新和管理接口，必须是随机长字符串。
- `SECRET_KEY`：账户令牌和验证码摘要密钥，必须是独立随机值且至少 32 字节；空值、短值、低多样性值和历史占位值会让账号操作 fail-closed 返回 `503`。
- `SMTP_*`：邮箱注册、验证码和找回密码所需的发信服务，只能保存在 VPS 环境文件中。
- `CORS_ORIGINS`：只填写正式 Web 客户端域名；安卓和 Windows 客户端不受此项影响。
- `LEGACY_ACCOUNT_API_ENABLED`：正式环境保持 `false`，避免旧兼容注册接口绕过邮件验证。
- `LEGACY_JWT_COMPATIBILITY_ENABLED`：默认 `false`。只有仍处于旧会话迁移期的环境才可显式设为 `true`，并且只兼容签名有效且完全没有 issuer/audience 的旧会话；迁移窗口结束后必须恢复关闭。
- `ACCOUNT_TRUSTED_PROXY_CIDRS`：仅填写会重写 `X-Real-IP` 的直属反向代理 IP/CIDR；默认留空时完全忽略该请求头。不要填写客户端网段或公网通配网段。
- `ACCOUNT_RATE_LIMIT_MAX_KEYS`：进程内账号限流表的硬容量，默认 `10000`；容量耗尽时对新键 fail-closed，而不是淘汰仍有效的限制。多实例部署仍必须在网关配置共享限流。
- `run_prod.py` 显式关闭 Uvicorn 的隐式代理头处理。若改用 Uvicorn CLI，也必须带 `--no-proxy-headers`，由 Zeluna 仅按上面的直属代理配置读取 `X-Real-IP`。
- `LEGACY_CONFIG_API_ENABLED`：正式环境保持 `false`；仅迁移旧客户端时临时启用，响应也不会下发第三方线路或代理地址。
- `DATABASE_AUTO_CREATE`：正式环境必须为 `false`；表结构只通过 Alembic 迁移变更。
- `PRIVACY_CLEANUP_INTERVAL_HOURS`：过期验证码和已知到期会话的清理周期，默认 `24` 小时，限制在 `1`–`168` 小时；统计只记录数量和时间，不记录邮箱或令牌。
- `SOURCE_CIRCUIT_*`：连续失败达到阈值后短暂跳过坏源，并以指数冷却自动重试；客户端候选不算硬失败。
- `PLAYBACK_PROVIDER_IDS`：逗号分隔的服务端 provider ID allowlist。默认留空，留空时搜索、详情、播放解析、首页清单和预热都不会调用任何播放 provider；只启用已经完成合规和网络验证的 ID。
- `M3U8_SEARCH_ENABLED`：通用 M3U8 搜索回退，正式环境默认 `false`。只有完成独立安全评审并明确批准时才可启用。
- `PRECACHE_ENABLED`：只有 `PLAYBACK_PROVIDER_IDS` 已显式配置且预热流量已获批准时才可设为 `true`。
- `MANAGED_PLAYBACK_LINES_ENABLED`：是否把已批准并启用的管理线路动态合并进 quick/full；默认 `false`，可先导入和审核，再显式开启。
- `MANAGED_PLAYBACK_LINES_REQUIRE_APPROVAL`：默认 `true`。保持开启时，验线成功后仍必须由管理员批准；关闭时，验线通过会自动批准，但新建和批量导入仍始终从 draft 开始。
- `MANAGED_PLAYBACK_LINES_MAX_PER_EPISODE`：单集最多参与合并的管理线路数，默认 `8`。
- `MANAGED_PLAYBACK_LINES_PROBE_TIMEOUT_SECONDS`：单条远程 URL 验线总超时，默认 `12` 秒。验线只在内存中有限读取清单、密钥或首段样本，不写入磁盘。
- `ANICH_*`：番剧聚合源 `crawler.anich` 的按需代取参数。该源必须在 `PLAYBACK_PROVIDER_IDS` 中显式点名才会启用（灰度示例：`PLAYBACK_PROVIDER_IDS=aggregate.maccms,crawler.anich`），去掉该 ID 即完成回滚。
  - `ANICH_MIN_REQUEST_INTERVAL_SECONDS`：同进程串行请求的最小间隔，默认 `1.2` 秒。上游有风控，调低会显著提高 `403/429` 概率。
  - `ANICH_HTTP_TIMEOUT_SECONDS` / `ANICH_BACKOFF_MAX_SECONDS`：单请求超时与限流退避上限，默认 `15` / `20` 秒。
  - `ANICH_BASE_COOLDOWN_SECONDS`：某个上游候选域失败后的冷却时长，默认 `300` 秒；冷却期间自动顺延到下一候选。
  - `ANICH_MAX_LINES_PER_EPISODE`：单集参与后续验证的线路上限，默认 `6`（上游单集可返回数十条，不截断会放大并发探测）。
  - `PLAYBACK_ANICH_LINE_TTL_HOURS`：该源直链无签名参数但按天易腐，默认对其单独盖 `2` 小时逐线过期；设为 `0` 关闭盖章，改由整行缓存 TTL 兜底。

## 管理远程播放线路

管理线路使用独立的 `managed_playback_lines` 表，不写入 `PlaybackCache.lines_json`。quick/full 每次响应时动态读取，因此禁用或撤销会立即生效，聚合负缓存也不能遮住管理线路。客户端仍直接连接远程媒体 Host；FastAPI 和反向代理不得转发媒体流。

安全边界：

- 只支持 `static_direct` 公共 HTTP(S) 直链；拒绝本地、私网、环回、`.local`、URL userinfo、HTML、embed、iframe 和 player 页面。
- 无扩展地址必须经过服务端内容嗅探，不能因为路径无后缀直接公开。
- 管理请求头只允许 `Referer` 和 `Origin`；禁止 Cookie、Authorization、API Key 及其他凭据。
- 普通日志不得记录完整 URL 或 query；管理员备注、授权记录和请求头不得出现在公共 `/api/v3/status`。
- 不支持上传、本地媒体、FFmpeg、转码、视频缓存、视频代理、任意脚本或短时 resolver。

管理员接口复用 `X-Zeluna-Admin` 认证：

```text
GET    /admin/managed-lines
POST   /admin/managed-lines
GET    /admin/managed-lines/{line_id}
PATCH  /admin/managed-lines/{line_id}
POST   /admin/managed-lines/{line_id}/verify
POST   /admin/managed-lines/{line_id}/approve
POST   /admin/managed-lines/{line_id}/enable
POST   /admin/managed-lines/{line_id}/disable
POST   /admin/managed-lines/{line_id}/revoke
POST   /admin/managed-lines/import
```

单条创建示例：

```json
{
  "stable_id": "bangumi:400602",
  "episode": 1,
  "provider_key": "managed.main",
  "label": "主线路",
  "canonical_url": "https://media.example/index.m3u8",
  "format_hint": "hls",
  "quality": "1080p",
  "headers": {"Referer": "https://player.example/"},
  "priority": 800,
  "provenance_kind": "licensed",
  "rights_reference": "INTERNAL-2026-001"
}
```

创建和 JSON 批量导入的记录固定为 `draft + pending + disabled`。正确发布顺序是：

1. `POST /verify` 完成安全检查和有限字节验线；
2. `POST /approve` 将记录置为 approved/active；
3. `POST /enable` 开始对新播放请求返回；
4. 需要止损时用 `disable`，永久撤销用幂等的 `revoke`。

替换 URL 不改变 `line_id`，但会自动退回 draft、pending、disabled，并要求重新验线和审核。已撤销记录保留审计信息，不能通过修改或启用恢复；需要新线路时应新建记录。

当前代码接受的播放 provider ID：

- 聚合：`aggregate.maccms`、`aggregate.tvbox`、`aggregate.vod`
- 独立抓取器：`crawler.age`、`crawler.dm706`、`crawler.girigiri`、`crawler.xgcartoon`、`crawler.jibi`、`crawler.yinghua2`、`crawler.wedm`、`crawler.nivod`、`crawler.ppnix`、`crawler.dbku`

“代码支持”不代表“已经合规批准或在当前出口可播”。其中 `aggregate.maccms` 会启用 `maccms_sites.py` 当前表内全部站点的按需查询；`precache` 字段只控制 MacCMS 后台预爬范围，不是站点启用开关。未知 provider ID 会让服务拒绝启动，避免拼写错误被静默忽略。

### 播放 provider 启用流程

1. 在目标 VPS 的 `server/` 目录运行现有站表探针并保留脱敏结果：

   ```bash
   /opt/zeluna/venv/bin/python tools/probe_maccms.py \
     --json-output probe-results/maccms-$(date -u +%Y%m%dT%H%M%SZ).json
   ```

2. 需要评估覆盖率时，运行默认的 100 部作品 / 167 个分集案例（每部 Episode 1，
   剧集再抽取一个中间集）；该命令会走搜索、匹配、详情、分集、清单/文件头、
   密钥和首分片链路，而不是只检查 HTTP 200。生产覆盖率应排除已禁用或隔离的
   配置来源：

   ```bash
   /opt/zeluna/venv/bin/python tools/probe_maccms.py \
     --profile coverage \
     --enabled-only \
     --json-output probe-results/coverage-$(date -u +%Y%m%dT%H%M%SZ).json
   ```

3. 新采集站先进入独立的 `data/maccms_candidates.json`，禁止直接写正式站表。注册表
   必须使用 `zeluna.maccms-candidates.v1` schema，声明镜像排除数量，并为每条记录保留
   `name`、`api`、固定提交来源、`review_status=candidate` 和风险说明。先对注册表运行
   Smoke，再只对有价值的候选运行完整晋级流程：

   ```bash
   /opt/zeluna/venv/bin/python tools/probe_maccms.py \
     --candidates --profile smoke \
     --json-output probe-results/candidates-smoke-$(date -u +%Y%m%dT%H%M%SZ).json

   /opt/zeluna/venv/bin/python tools/probe_maccms.py \
     --candidates --profile promotion \
     --site 候选站名 \
     --json-output probe-results/candidates-review-$(date -u +%Y%m%dT%H%M%SZ).json
   ```

   注册表会拒绝非 http(s)、IP literal、查询凭据、重复名称/主机、正式源主机、未知字段
   和非候选 review 状态。`promotion` 会依次运行 Smoke 与 Coverage，并记录 SSRF/URL
   安全门、人工审核门和建议 tier；它永远不会自动修改 `maccms_sites.py`。只有目标出口
   媒体验证、内容/条款合规人工审核都通过的站才可进入正式表，首次写入保持
   `precache: False`。

4. 审核合规性和目标出口探针结果后，在 `/etc/zeluna/zeluna.env` 中只填写获准 ID。首次启用保持 `PRECACHE_ENABLED=false`，例如：

   ```dotenv
   PLAYBACK_PROVIDER_IDS=aggregate.maccms
   PRECACHE_ENABLED=false
   M3U8_SEARCH_ENABLED=false
   ```

4. 按本文件的备份、迁移和重启流程部署，然后检查 `/api/v3/status` 的 `playback_providers.enabled_ids` 与预期完全一致。
5. 分别完成番剧、剧集、电影的搜索、详情、播放清单、AES key（如有）、首分片和真实客户端播放验证；第二次请求还应验证缓存命中。
6. 只有确认流量和资源预算后，才单独批准并开启 `PRECACHE_ENABLED=true`。

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

本版本迁移 head 为 `0013_managed_playback_lines`。上线前应在备份副本上完成一次 `upgrade head → downgrade -1 → upgrade head` 往返；回退到 `0012` 会删除管理线路表，因此生产回退前必须先保留数据库备份。

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
- `/api/v3/status` 的 `playback_providers.enabled_ids` 与部署审核的 allowlist 一致。
- 搜索结果只返回稳定作品 ID，不出现采集站内部 ID。
- 第一次播放完成验证并写缓存；第二次请求返回 `cached: true`。
- 热缓存快速接口应立即返回主线路，并尽量附带两个不同域名的备用线路；`stale: true` 表示旧线路仍可播且后台正在刷新。
- 开启管理线路后，已批准线路应带稳定 `line_id`、`provider_id: managed.urls`，并优先于健康聚合线路；禁用或撤销后下一次请求立即消失。
- 管理线路 URL 不得出现在 `playback_cache.lines_json`，VPS 磁盘不得生成视频、分片或转码文件，客户端网络请求应直接到远程媒体 Host。
- App 中不存在播放规则、外部源目录或规则导入入口。
- 后端不可用时 App 明确显示无线路，不回退本地爬虫。

## 当前工程 Goal 的部署边界

- 本工程 Goal 没有读取生产环境变量、访问生产数据库、探测生产 provider、重启服务或部署代码，因此不声明任何历史地址、源清单或账号服务仍处于已验证上线状态。
- 新版本默认 `PLAYBACK_PROVIDER_IDS=`、`M3U8_SEARCH_ENABLED=false`、`PRECACHE_ENABLED=false`。未显式配置时，目录元数据可按其独立配置工作，但播放 provider 不会产生出站请求。
- 正式部署前必须备份数据库、上传目录和可恢复旧版本，显式审核 provider allowlist，并重新检查服务状态、账号安全、三类播放、缓存、资源占用和回滚路径；这些属于 G13/G14 且需要单独授权。
