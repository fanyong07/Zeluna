# kanju1.ai（看剧AI）播放与片源逆向调研

- **调研对象**: https://kanju1.ai/
- **调研日期**: 2026-08-13
- **方法**: 公开前端静态资源拆解 + 带客户端签名的第一方 API 实测 + 与 Zeluna 后端对照
- **性质**: 架构/协议观察笔记，供 Zeluna 对齐「聚合后端 + 直链播放」模式；**不是**接入授权，也**不是**把对方私服当长期源的方案
- **一手来源**: 站点 HTML/JS 包、`/v1/*` JSON 响应、解析后的 HLS 清单；Zeluna 对照见本仓库 `server/server/scrapers/maccms*.py`、`server/server/playback.py`、`server/DEPLOY.md`

---

## 1. 执行摘要

kanju1.ai 对外是「影视搜索 + 在线播放」的 Web/App 产品（前端工程名 **dianyingtiantang**，协议族 **ai-movie / library-v2.playback-v1**）。
它的「几乎无广告」**主要不来自神秘片源**，而来自：

1. **自建目录与播放编排 API**（同域 `/v1/*`），客户端只拿结构化线路；
2. **自研播放器直拉 HLS/MP4**，不嵌带广告的第三方 H5 播放页；
3. 线路分两层：
   - **公开资源站 m3u8（MacCMS 生态）** — 与 Zeluna `MACCMS_SITES` 大量同名同源；
   - **自营/签约 CDN 的延迟解析线路** — `resolve://` ticket → `POST /v1/playback/resolve-line` 后才出带 `verify=` 的短时 m3u8。

对 Zeluna 的启示是：**模式可对齐，私有 API/官方 CDN 不应直接接入**；应继续强化自有 MacCMS 聚合、验线缓存与客户端直连。

---

## 2. 产品与基础设施画像

| 项 | 观察 |
| --- | --- |
| 站点 | `https://kanju1.ai/`，HTML `lang=zh-CN`，主题 `movie-dark` |
| 产品名 | 看剧AI / KANJU.AI；前端常量 `dianyingtiantang-frontend` |
| 前端 | Vite + React SPA，`#root`；分包含 `global-player-host`、`hls`、`native-playback-controller` |
| CSP | `connect-src 'self' https: wss:`；`media-src 'self' blob: https:`；`script-src 'self' https://s1.ewdcma.cn` |
| 健康检查 | `GET /health` → `ok` |
| API 网关痕迹 | 响应头 `Server: openresty`；`x-ai-movie-upstream-node: dyt-api-r3`；`x-ai-movie-upstream-slot: blue`；外层 **CloudFront**（`X-Amz-Cf-Pop` 等） |
| 运营配置 | `GET /v1/announcements/manifest`（**无需签名**）返回 `site_id`、公告 tabs（最新/APP/资源线路/版本更新/指南） |
| 分析 | `app-bootstrap.js` 懒加载 `https://s1.ewdcma.cn/sdk.min.js`，上报 `.../api/v1/ingest/events`（HMAC 签名的第三方分析，与片源无关） |
| 关联域名（播放/资源） | `zy.baipiaozhe.com`、`player.baipiaozhe.com`、`*.wikjdd.cn`、`img.baipiaozhe.com`（海报经百度图床包装）等 |
| 商业层 | 登录会话、词元/quota、邀请、成人内容授权、Midnight Theater 等（播放 resolve 可走 session/consume） |

构建标识（写在请求头默认值中）：

- `x-ai-movie-client-name`: `dianyingtiantang-frontend`（实测用 web 名也可）
- `x-ai-movie-client-version`: `1.0.0`
- `x-ai-movie-build-version`: `dianyingtiantang-v2026.08.11.3-69cf49f44294-fdd5d66f2482`
- `x-ai-movie-protocol-version`: `2026-07-05.library-v2.playback-v1`

---

## 3. 前端架构（静态资源）

入口 HTML 仅挂：

- `/app-bootstrap.js` — 主题 + 分析 SDK
- `/assets/index-*.js` — 路由与壳
- vendor：`react-vendor`、`navigation-runtime`、`movie-card-runtime`、`icons`

与播放强相关的懒加载块（名随 hash 变）：

| 模块角色 | 典型文件名片段 |
| --- | --- |
| 首页 Feed API | `api-*.js` → `/v1/feed/home` |
| 播放页路由 | `PlayerRoute-*.js` → `player-page-*.js` |
| 线路/词元/resolve | `player-token-quota-state-*.js` |
| 全局播放器宿主 | `global-player-host-*.js` |
| 原生/线路状态机 | `native-playback-controller-*.js` |
| HLS | `hls-*.js` |
| 详情缓存 | `resource-detail-client-cache-*.js` |
| 分集分页 | `player-episode-pagination-*.js` |

本地存储/事件前缀大量使用 `movie-search:*`、`aimovie.*`，说明产品线内部仍叫 **AI Movie / movie-search**，看剧AI 是品牌层。

---

## 4. 请求签名协议（第一方 API 门禁）

### 4.1 现象

未签名访问例如 `GET /v1/feed/home`：

```json
{
  "error": {
    "message": "Missing request signature.",
    "type": "invalid_request_error",
    "code": "invalid_request_signature"
  }
}
```

### 4.2 算法（自 `movie-card-runtime` 还原）

对**同源**且 path 以 `/v1/` 开头的请求，在发出前附加：

| Header | 含义 |
| --- | --- |
| `x-ai-movie-timestamp` | `Date.now()` 毫秒字符串 |
| `x-ai-movie-nonce` | 16 字节 CSPRNG → 32 位 hex |
| `x-ai-movie-signature` | HMAC-SHA256(hex) |

**Canonical string**（四段，`\n` 连接）：

```text
{METHOD}
{pathname}{search}
{timestamp}
{nonce}
```

- `METHOD` 大写（默认 GET）
- `pathname + search` 为 URL 的 path 与 query（含 `?`）
- HMAC **key** 以明文常量嵌在前端 bundle（32 字节 hex 字符串）；**会轮换**，本报告不把它当稳定密钥文档化依赖

伪代码：

```text
signature = hex(HMAC_SHA256(key, METHOD + "\n" + path+query + "\n" + ts + "\n" + nonce))
```

### 4.3 其它客户端头

`vr()` 一类函数保证：

- `x-ai-movie-client-name`
- `x-ai-movie-client-version`
- `x-ai-movie-build-version`
- `x-ai-movie-protocol-version`

部分能力还有：

- `x-ai-movie-site-host`（邀请等）
- `x-ai-movie-midnight-access`（午夜剧场访客）
- Session：`auth: "session" | "auto" | "none"`（RTK Query 封装）

### 4.4 安全含义

- 这是 **防普通刷接口 / 约束官方客户端** 的门槛，不是服务端私密持有密钥的 mTLS。
- 密钥在 JS 里 → 任何能跑浏览器的人都能复现签名；真正的硬限制在 **风控、登录、词元、IP、ticket 过期**。
- Zeluna **不应**复制「把 HMAC 密钥打进公开客户端」作为唯一防护；若做类似门禁，密钥应在自有后端。

---

## 5. API 地图（前端字面量 + 实测）

### 5.1 无需签名（抽样）

| 方法 | 路径 | 结果 |
| --- | --- | --- |
| GET | `/health` | `ok` |
| GET | `/v1/announcements/manifest` | 200，站点公告清单 |

### 5.2 需签名的目录/搜索（抽样 2026-08-13）

| 方法 | 路径 | 结果 | object |
| --- | --- | --- | --- |
| GET | `/v1/feed/home` | 200 | `home.feed` |
| GET | `/v1/browse/catalog?limit=3` | 200 | `catalog.browse` |
| GET | `/v1/catalog/{variantId}` | 200 | `catalog.detail` |
| GET | `/v1/catalog/{variantId}/detail` | 200 | `catalog.detail` |
| GET | `/v1/catalog/{variantId}/episodes?limit&offset` | 200 | `catalog.episodes` |
| GET | `/v1/suggest?q=...` | 200 | `movie.suggestions` |
| GET | `/v1/catalog/{id}/variety-episodes/v4|v5` | （前端构造，综艺分页） | — |
| GET | `/v1/catalog/{id}/variety-date-groups` | （前端构造） | — |

前端还出现但本次未全量实测：`/v1/yj/catalog`、`/v1/yj/trending`（字面量存在；裸 GET 曾 404，可能已迁或需参数）。

### 5.3 播放

| 方法 | 路径 | 作用 |
| --- | --- | --- |
| GET | `/v1/playback/resolve/{episodeToken}` | 返回分集 + **line_options**（候选线路） |
| POST | `/v1/playback/resolve-line` | body: `{"ticket":"rpt1...."}` → **真实 URL** |
| POST | `/v1/playback/adult-access/{variantId}` | 成人内容授权（需 session） |
| POST | `/v1/playback/skip-settings/report` | 片头片尾社区中位数上报 |

`resolve` query（前端组装）：`line`、`provider_id`、`play_from`、`source_vod_id`、`episode_index`、`episode_count`、`content_kind`、`quota_debug`、`consume` 等。

### 5.4 账号 / 库 / 社交 / 投屏（摘要）

- 用户：`/v1/users/anonymous|captcha|password/login|password/register|logout|me|me/quota|me/invite...`
- 书库：`/v1/users/me/library/status`
- 会话：`/v1/threads`、`/v1/threads/archive`
- 评论：`/v1/comments`、reactions
- 投屏：`/v1/tv-cast/devices`、pairings、WebSocket `/v1/tv-cast/ws`
- 午夜剧场：`/v1/midnight-theater/*`
- 反馈：`/v1/reports/batch`
- 弹幕：`/v1/danmuku/episodes/{id}`（native controller 引用）

`GET /v1/users/me/quota` 无 session → `401 User session is required.`

---

## 6. 身份与数据模型

### 6.1 作品 / 变体

- **variant_id / card id**: 形如 `av_` + 长 base64url（示例：`av_mJ6t6rwR...`）
- **work_id**: `work:yj:{hex}` — `yj` 像内部片库命名空间
- **export_id**: 数字导出 ID
- **content_kind**: `series` | `movie` |（另有 adult/short_drama 等分支）
- 元数据：中文标题、年、地区、类型、演职员、海报 URL、remarks（「更新至25集」）、heat、playback_count
- **playback_groups**（目录层展示用，非最终可播 URL）：

  | id | label | type |
  | --- | --- | --- |
  | `yjplayer` | 网页播放器 | player |
  | `yjm3u8` | m3u8 | m3u8 |
  | `yjapi` | YJ API | api |

### 6.2 分集

示例字段（`catalog.detail` / `catalog.episodes`）：

```text
id:     episode:yj:{hex20}
token:  YJ-{hex20}          ← playback resolve 的主钥匙
number / key / title
path:   /yj/{hex20}
urls: {
  yjapi:    https://zy.baipiaozhe.com/v1/playback/yjapi/{token}
  yjm3u8:   https://zy.baipiaozhe.com/v1/playback/yjm3u8/{token}.m3u8
  yjplayer: https://player.baipiaozhe.com/yjplayer.html?v=...&url={token}
}
```

**重要实测**：上述 `zy.baipiaozhe.com` / 直链在无正确上下文时多次 **404**。
它们更像 **站内路由别名或网关路径**，真正稳定播放路径是 **`/v1/playback/resolve` →（可选）`resolve-line`**。

Token 归一：前端会把 20 位 hex 或 `*.m3u8` 收成 `YJ-{hex}`。

### 6.3 线路 line_options

`GET /v1/playback/resolve/{token}` → `object: playback.resolve`：

| 字段 | 含义 |
| --- | --- |
| `playback_source_id` | 如 `playback:yj:{hex}` |
| `provider_id` | 逻辑源 ID（`ikun`、`hongniu`、`bytevod-cloudflare`…） |
| `provider_name` | UI 名（`红牛资源`、`高清-官方C`…） |
| `play_from` | 播放源代号（MacCMS 风格 `hnm3u8` / 自营 `cloudflare`） |
| `source_vod_id` | `source:{provider}:{id}` |
| `url` | 直接 m3u8 **或** `resolve://rpt1.{payload}.{sig}` |
| `url_kind` | `m3u8` \| `resolve_ticket` \| … |
| `resolve_mode` | `direct` \| `parse` |
| `resolve_required` | parse 线路为 true |
| `preference_weight` | 排序权重（官方线常 960–1000，资源站约 750–920） |
| `selected` | 默认选中 |
| `expires_at` / `resolved` | 解析生命周期 |

---

## 7. 播放状态机（端到端）

```text
用户打开 /player/{variantId}?episode=&line=&resume=
        │
        ▼
GET /v1/catalog/{variantId}[/detail]     # 元数据 + 分集 token 列表
GET /v1/catalog/.../episodes?offset&limit
        │
        ▼
GET /v1/playback/resolve/{episodeToken}  # 签名；可选 line/provider 选择
        │
        ├─ line.resolve_mode == direct && url_kind == m3u8
        │     → 播放器直接 HLS 拉 url
        │
        └─ resolve_mode == parse && url_kind == resolve_ticket
              url = resolve://rpt1.<base64url>.<sig>
              ticket payload 示例:
                {"episodeId":"episode:yj:...","playbackSourceId":"playback:yj:...","expiresAt":<ms>}
              │
              ▼
        POST /v1/playback/resolve-line
        Content-Type: application/json
        body: {"ticket":"rpt1...."}     # 不要带 resolve:// 前缀
              │
              ▼ 201 playback.line.resolve
        line.url = https://.../index.m3u8?verify=...
        line.url_kind = m3u8, resolved=true, resolve_required=false
              │
              ▼
        hls.js / 原生播放器  分片直连 CDN（站点不中转媒体体）
```

失败与降级（前端逻辑摘要）：

- ticket 过期 / resolve 不完整 → 提示换线
- HTTP 402 + quota → 词元不足，可「prefer_direct」一段时间只走直链资源站
- 403/404/5xx 集合触发换线或重试（native controller 内 attempts: startup/network/media/stall/hardHttp）
- `probe_status`: `unchecked | checking | ok | failed` 影响选线

---

## 8. 实测：一条完整解析

**样本**：剧集《九门》第 1 集
`token = [已从仓库脱敏；短期凭据不得留存]`
`variant_id = av_mJ6t6rwRbvtqAkzoKBZ_ynse2fPNxuuPTgN-avq0Pdk1GNdiGmdS3t8uEC3eQYoHqn7osaQc3kFF_ls`

### 8.1 resolve 线路清单（32 条）

**延迟解析（parse / resolve_ticket）** — 权重最高：

| provider_id | provider_name | play_from | weight | 解析后 CDN 宿主（抽样） |
| --- | --- | --- | --- | --- |
| bytevod-cloudflare | 高清-官方C | cloudflare | 1000 | `lf1.wikjdd.cn` |
| official-r | 1080P-官方R | rrys | 990 | `sign.site.zshtys888.com` |
| bytedance | 高清-官方B | bytedance | 980 | `v6-forum.picovr.com` |
| dong | 1080P-官方D | Dong | 970 | 本次 resolve-line **404** |
| bytevod-lv2 | 1080P-官方Z | lv2 | 960 | `p3-heycan-sign.byteimg.com` |
| official-hot-playback | 优酷 | youku | 870 | 本次 resolve-line **404** |

**直接 m3u8（direct）** — 典型资源站，与 MacCMS `vod_play_from` 同形态：

| provider_id | provider_name | play_from | weight | 示例 URL 形态 |
| --- | --- | --- | --- | --- |
| hongniu | 红牛资源 | hnm3u8 | 920 | `https://hn.bfvvs.com/play/.../index.m3u8` |
| jszy | 极速资源 | jsm3u8 | 880 | （同结构） |
| hhzy | 豪华资源 | hhm3u8 | 870 | |
| dbzy | 豆瓣资源 | dbm3u8 | 860 | |
| mdzy | 魔都资源 | modum3u8 | 850 | |
| ikun | ikun资源 | ikm3u8 | 840 | `https://bfikuncdn.com/.../index.m3u8` |
| ruyi | 如意资源 | rym3u8 | 835 | |
| iqiyi | iqiyi资源 | iqym3u8 | 830 | |
| bfzy | 暴风资源 | bfzym3u8 | 825 | |
| maoyan | 猫眼资源 | mym3u8 | 805 | |
| subo | 速播资源 | subm3u8 | 800 | |
| dytt | 电影天堂资源 | dyttm3u8 | 785 | |
| wujin | 无尽资源 | wjm3u8 | 790 | |
| zuida | 最大资源 | zuidam3u8 | 765 | |
| liangzi | 量子资源 | lzm3u8 | 760 | |
| zy360 | 360资源 | 360zy | 755 | |
| … | 新浪/西瓜/索尼/金鹰/牛牛/非凡/茅台/无水印/1080zyk/U酷… | `*m3u8` | 750–900 | |

### 8.2 resolve-line 成功样例（官方 C）

`POST /v1/playback/resolve-line` → **201**
`object: playback.line.resolve`

- 返回 `line.url` 形如：
  `https://lf1.wikjdd.cn/runtime/{hash}/index.m3u8?verify={exp}-{sig}`
- 拉取 m3u8：**200**，标准 HLS VOD（`#EXT-X-PLAYLIST-TYPE:VOD`）
- 分片宿主：`p3.wikjdd.cn`，路径 `/kj-resources/{id}/segment_XXXXXX.png?verify=...`
  - 扩展名 `.png` + `#EXT-X-BYTERANGE`：媒体伪装/防盗链常见手法，播放器按 byterange 读 TS/fMP4
- `token_scenario`: `series_intro_zero`（与计费/词元场景相关）

### 8.3 direct 线路

`hongniu` / `ikun` 在 resolve 响应里 **已是完整 https m3u8**，`resolve_required=false`，无需 ticket。
这与苹果 CMS 采集站直接吐 `vod_play_url` 的行为一致。

---

## 9. 「无广告」机制拆解

| 层级 | 做法 | 效果 |
| --- | --- | --- |
| 播放容器 | 自研 React 播放器 + hls.js，不 iframe 广告站 | 无网页贴片/暂停广告 DOM |
| 线路过滤 | 优先 m3u8/直链；网页播放器组仅作 group 元数据 | 用户默认不进 H5 广告页 |
| 聚合后端 | 多源绑定后统一 line_options | UI 干净、可一键换线 |
| 官方线 | 自有/签约 CDN + verify 参数 | 相对稳定、少中间页 |
| 资源站线 | 仍是公共采集 m3u8 | 源本身可能水印，但通常不是网页广告 |
| 商业 | 词元/登录而非贴片 | 「无广告」可与「有配额」并存 |

结论：**无广告 ≈ 产品与播放器工程选择**，不是「整站源都无水印无广告」。

---

## 10. 与 Zeluna 对照

### 10.1 架构同构

| 能力 | kanju1 | Zeluna（本仓库） |
| --- | --- | --- |
| 元数据权威 | 自有 `work:yj` / variant | Bangumi + TMDB，`bangumi:` / `tmdb:*` |
| 播放入口 | `/v1/playback/resolve*` | `/api/v3/quick-playback`、`/api/v3/playback` |
| 聚合 | 多 provider line_options | `MacCmsScraper` + 其它 crawler，allowlist `PLAYBACK_PROVIDER_IDS` |
| 验线/缓存 | 服务端编排 + probe + ticket TTL | `playback.py` 正/负缓存、quick 3 线、circuit breaker |
| 客户端 | 直连 CDN | `ZelunaBackendPlaybackRepository` + media_kit，支持 `headers` |
| 不中转存片 | 是 | 是（DEPLOY.md 明确） |

### 10.2 源重叠（资源站名）

kanju1 `provider_id` 与 Zeluna [`server/server/scrapers/maccms_sites.py`](../../server/server/scrapers/maccms_sites.py) 可对齐的例子：

| kanju1 | Zeluna 表内名称 |
| --- | --- |
| ikun | iKun |
| hongniu | 红牛 |
| jszy | 极速 |
| hhzy | 豪华 |
| ruyi | 如意 |
| mdzy | 魔都 / 魔都2 |
| maoyan | 猫眼 |
| bfzy | 暴风 |
| wujin | 无尽 |
| zuida | 最大 |
| zy360 | 360 |
| liangzi | 量子 |
| dytt | 电影天堂 |
| iqiyi | 爱奇艺 |
| subo | 速博 |

kanju1 另有、Zeluna 表未逐一命名的：新浪/西瓜/索尼/金鹰/牛牛/非凡/茅台/无水印/豆瓣/1080zyk/U酷等——仍属 **同一 MacCMS 公开采集生态**，应用 **VPS 探针** 决定是否加入（`probe_maccms.py --candidates`），而不是从 kanju1 API 倒灌。

反向也成立：Zeluna 表内的 **光速、风车、百度、虎牙** 未出现在本次 kanju1 单集快照里。两边都不是对方的超集，所以「补齐差集」不是目标，**在目标出口实测可播** 才是唯一入表依据。

### 10.3 差异（不要照抄）

| kanju1 | 对 Zeluna 的建议 |
| --- | --- |
| 前端嵌 HMAC 密钥 | 不采用；门禁放自有后端 |
| `resolve://` 私有 ticket | 仅当自有源需要短 TTL 时做 **自有** resolve-line |
| `lf1.wikjdd.cn` 等官方 CDN | **不要**当第三方依赖接入 |
| variant_id / YJ token | 继续稳定 ID；内部绑定表即可 |
| 词元计费 | 产品决策，与片源无关 |

---

## 11. 对 Zeluna 的可执行建议（模式级）

1. **保持**「稳定 ID → 后端验线 → 客户端直连」；与 kanju1 主路径一致。
2. **激活**合规后的 `PLAYBACK_PROVIDER_IDS`（空 allowlist = 无播放 provider）。
3. **扩展 MacCMS 表**只通过 `tools/probe_maccms.py`（或等价）在目标出口实测，不对接 kanju1。
4. **过滤**返回线路：只保留 http(s) 媒体候选，丢弃 `*.html?url=` / `embed` / `iframe` 播放器页；**无扩展直链必须保留**给服务端内容验证，不能预先判成 mp4。
5. **headers**：资源站若需 Referer / Origin，放在线路对象（客户端 repository 已支持）；UA 由服务端统一设置，不交给站表覆盖。
6. **可选**：自有 `resolve-line` 仅服务自有短 TTL 源，协议可参考「ticket 不进日志、短过期、POST 换 URL」，实现完全自控。
7. **明确不做**：把 kanju1 签名 API、ticket、官方 CDN 写进生产依赖。

### 11.1 执行状态（2026-08-20）

| # | 状态 | 落点 |
| --- | --- | --- |
| 1 | 本来就成立，无改动 | 架构既有：稳定 ID → `playback.py` 验线 → 客户端直连 |
| 2 | **已在生产启用** | `/api/v3/status` 新增 `playback_providers.enabled_ids`（[`routers/health.py`](../../server/server/routers/health.py)）；可用 ID 与启用流程写入 [`DEPLOY.md`](../../server/DEPLOY.md)。LA VPS 实测 `PLAYBACK_PROVIDER_IDS=aggregate.maccms`、`PRECACHE_ENABLED=false`、`M3U8_SEARCH_ENABLED=false`，状态接口回读 `enabled_ids:["aggregate.maccms"]` |
| 3 | 完成 | [`tools/probe_maccms.py`](../../server/tools/probe_maccms.py) 改为复用生产验线器，输出去查询串的结构化报告；新增 `--candidates` 以**数据**形式先实测未入表站点，再决定是否写入 `maccms_sites.py` |
| 4 | 完成 | `classify_media_url()`（[`scrapers/base.py`](../../server/server/scrapers/base.py)）统一判定，作用于抓取、聚合验线、缓存读取与客户端四层 |
| 5 | 完成（有意收窄） | `VideoLine.headers` 全链路透传；MacCMS 站表只允许 Referer / Origin，UA 由服务端固定。当前无站点需要 headers，属前置支持 |
| 6 | **未采纳** | 自有 `resolve-line` 只在存在自有短 TTL 源时才有意义；当前全部线路来自公开采集站，现在实现等于凭空加协议面 |
| 7 | 已核对 | 全仓库无 kanju1 / `baipiaozhe` / `wikjdd` / `resolve://` 生产引用 |

第 4 条的实现比原建议**宽**一档：真实 CDN 直链常见无扩展（`/media/{token}`），照字面「只要 m3u8/mp4」会丢掉可播线路。因此无扩展地址保留为 `unknown`，交给服务端内容嗅探定论；只有明确的 HTML/embed 页被无条件丢弃，即使源把它标成 `hls`。

### 11.2 诊断口径修正（2026-08-20）

按 §11.3 复核 LA VPS 上 2026-08-16 那份探针报告时发现：13 个零可播站里，失败分类 193 次是 `parser_mismatch`，但**其中绝大多数不是解析问题**。`aggregator.py` 原先把 `unsafe_target_sentinel`（目标未通过公网 IP 校验）也映射成 `PARSER_MISMATCH`，三处调用点都早于本次改动。后果是报告把「域名被 DNS 黑洞 / 解析到非公网」显示成「解析不匹配」，看报告的人查不到真因。

已拆出独立分类 `NON_PUBLIC_TARGET = "non_public_target"`，与探针站级备注沿用同一词汇；优先级放在 `DNS_FAILURE` 之后（`_ERROR_CATEGORY_PRIORITY` 45、`_SOURCE_ERROR_PENALTIES` 70），并**刻意不**加入 `_DETERMINISTIC_SOURCE_FAILURES`——它和 `DNS_FAILURE` 同属解析层判定，可能随轮询 DNS 变化，当作确定性失败会过度惩罚多 IP 的 CDN。

同时实测确认的事实：

- **极速（`vv.jisuzyv.com`）解析到 `127.0.0.1`**，12/12 次。域名已死或被黑洞，验线器拒绝它是正确行为，不是误杀。
- **红牛可播**：用 8/16 报告里同一条 URL 复现得到 `server_verified`（m3u8 200、`enc.key` 16 字节、首分片 206 `video/mp2t`）。该站在 8/16 报告里却是 34 次全 `parser_mismatch`。
- 结论：那份 8/16 报告对若干站点**已失真**，不能作为调整站表的依据；站表变更必须基于修正口径后的新报告。

### 11.3 修正口径后的复测（2026-08-20，LA VPS）

在隔离副本（`/root/zeluna-probe-20260820`，跑完即删，生产 `app/server` 全程未动）中用修正后的分类重跑，报告归档在 `/opt/zeluna/probe-results/maccms-20260820T140929Z.json`：

**服务端验线通过 11/20**（8/16 是 7/20）。翻转的四个站：如意、红牛、虎牙 `—` → 三类全可播，电影天堂 `—` → 番剧/剧集。

更重要的是「零可播」这个说法本身有误导性。`playable` 字段只统计 `SERVER_VERIFIED`，而 `restricted`（HTTP 401/403/451）返回的是 `CLIENT_PROBE_REQUIRED` 而**非** `UNAVAILABLE`——这些线路照常下发给客户端复验。机房 IP 被 CDN 拒绝，不代表住宅 IP 的真实用户放不出来。

按真实成因分三类：

| 类别 | 站点 | 判据 |
| --- | --- | --- |
| 服务端已验证可播 | iKun、如意、猫眼、魔都2、魔都、红牛、爱奇艺、360、虎牙、量子、电影天堂 | `server_verified` |
| **机房被拒，客户端仍可试** | 光速、豪华、速博、百度、无尽、最大 | `restricted` → `client_probe_required` |
| **确实已死** | 极速、暴风、风车 | 见下 |

- **极速**：API 主机正常（`jszyapi.com` 200），但媒体主机 `vv.jisuzyv.com` 解析到 `127.0.0.1`。搜索详情能出、媒体全废，且该站 `precache: True` 属纯浪费。
- **暴风**：媒体链接整体过期，`c1.rrcdnbf6.com` / `s2.bfllvip.com` 等一律 404/410（`stale_route` 18/18）。
- **风车**：API 直接 `http_444`（nginx 主动断连），搜索都不通，一个候选都产不出。

`parser_mismatch` 剩下的 51 次是**真的**解析不匹配：光速/豪华/速博 的 MacCMS 数据里每集同时给出无扩展播放页和真 `.m3u8` 两条，前者按 §11.4 保留为 `unknown` 进入验线后被 HTML 检测正确拒绝。这正是第 4 条放宽策略应有的行为。

站表是否删站属内容与合规决定，未擅自改动；`maccms_sites.py` 注释也说明运行时会自动淘汰失效站。

---

## 12. 风险与合规

- 公共 MacCMS 与自建聚合均涉及 **版权与服务条款**；本笔记只描述技术结构。
- 对方 API 含 **配额、登录、风控**；未授权自动化调用可能触发封禁。
- 前端 HMAC 密钥与分析 SDK secret 会出现在公开 JS 中——**报告不鼓励传播密钥或用于生产集成**；若需复现实验，应从当前 bundle 自行提取并假设随时失效。
- 官方线分片使用 `.png` + byterange，属于防盗链/混淆，不代表图片业务。

---

## 13. 附录

### 13.1 关键响应 object 类型

- `home.feed`
- `catalog.detail` / `catalog.episodes` / `catalog.browse`
- `movie.suggestions`
- `playback.resolve` / `playback.line.resolve`
- `site.announcement_manifest`

### 13.2 resolve-line 请求注意

- JSON body **文件/原始字节**提交；错误的 PowerShell 管道编码会导致 `Body is not valid JSON`。
- ticket 使用 `rpt1.` 前缀字符串，**去掉** `resolve://`。
- 成功码实测为 **201 Created**。

### 13.3 上游节点头（运维指纹）

```text
x-ai-movie-upstream-node: dyt-api-r3
x-ai-movie-upstream-slot: blue
Server: openresty
Via: CloudFront
```

### 13.4 前端签名逻辑位置

- 打包文件：`/assets/movie-card-runtime-*.js`
- 符号线索：`x-ai-movie-signature`、`HMAC` + `SHA-256`、`crypto.subtle.sign`

### 13.5 本仓库对照路径

- [`server/server/scrapers/maccms.py`](../../server/server/scrapers/maccms.py) — provide/vod 解析
- [`server/server/scrapers/maccms_sites.py`](../../server/server/scrapers/maccms_sites.py) — 站清单
- [`server/server/playback.py`](../../server/server/playback.py) — 验线与缓存
- [`server/server/routers/playback.py`](../../server/server/routers/playback.py) — `/api/v3/playback`
- [`lib/src/data/zeluna_backend_playback_repository.dart`](../../lib/src/data/zeluna_backend_playback_repository.dart) — 客户端拉线
- [`server/DEPLOY.md`](../../server/DEPLOY.md) — provider allowlist 与运维约束

### 13.6 调研边界

- 未对 kanju1 服务端私有代码做未授权访问。
- 未建立持续爬取或绕过付费/词元的方案。
- 线路可用性随时间变化；表格是 **2026-08-13 单集快照**。
- 本文件为 **短时效研究笔记**；接入决策请再验证并写成独立 ADR。

---

## 14. 一句话结论

**kanju1 = 带签名的自有目录/播放 API + 自研无网页广告播放器 +（MacCMS 直链资源站 ∪ 短时 ticket 官方 CDN）**；
Zeluna 已具备同构骨架，应 **吃透公开采集与验线**，而不是寄生其私有 resolve 体系。
