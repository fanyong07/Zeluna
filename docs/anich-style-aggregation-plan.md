# AniCh 风格聚合播放接入方案

> 项目：Zeluna (`E:\anime`)
> 文档日期：2026-08-26
> 状态：方案与证据整理，待实施

## 0. 落地状态（2026-08-27 更新）

本文档的调研结论仍然有效，但**落地形态已改为服务端 provider**，与本文正文的部分章节不一致。以正文为准的部分与被取代的部分如下：

| 章节 | 现状 |
|---|---|
| §1 目标、§2 客户端架构证据、§8 职责划分、§9 安全边界、§11 验证标准 | **仍有效**，本次实现遵循其精神 |
| §3 「52 个线路标签清单」 | **已被实测取代**：一集 58 条线路实际分布在约 14 个域名上（自建 CDN 官方二压、代取流、对象存储转存、少量采集站原始 m3u8）；tag 是线路标签而非站点数，无需逐个对账为 52 个源站 |
| §4.2 / §4.3 客户端新增 VPS repository 与 UI identity | **已延后**：本轮客户端零改动，线路经服务端既有 `/api/v3/playback` 通路下发，复用现有分组与切线逻辑 |
| §5 电影 / 电视剧 / 多季 | **部分不适用**：实测该上游目录只含动画类条目（《流浪地球》《阿凡达》0 命中），真人影视由既有 MacCMS 管线（`server/server/scrapers/maccms_sites.py`，18 站分层）承担 |
| §6 建议的 VPS 统一 JSON 接口、§7 provider manifest | **未采用**：改为在 Zeluna server 内直接实现适配器，不新增中间接口层 |
| §10 实施顺序 | **已被取代**，实际落地见下 |

实际落地（P1 已完成）：

- `server/server/scrapers/anime/anich_transport.py`：域名白名单唯一模块（主机名 / UA / path 构造 / 串行节流 / 多域容灾）
- `server/server/scrapers/anime/anich_proto.py`：手写 protobuf 解码 + 变体 base64（零 `google.protobuf` 运行时依赖）
- `server/server/scrapers/anime/anich.py`：`AniChScraper(BaseScraper)`，含跨季全局集号两级映射与线路排序截断
- `server/server/aggregator.py`：注册为 `crawler.anich`，并把发现超时 / 别名预算从硬编码改为按 provider 查表
- `server/tests/test_independent_backend.py`：域名纪律由"绝对禁止"改为"集中单点 + 单点完整性校验"（详见 `docs/engineering-goal-progress.md` 的 2026-08-27 勘误）

## 1. 目标

将 AniCh 的“客户端只请求一个聚合接口，服务端返回多条播放线路，客户端统一解析、展示、探活和故障切换”模式接入 Zeluna。

目标同时覆盖：

- 动画/番剧
- 电视剧
- 电影
- 多季内容
- 每集多条线路
- 线路标签、来源名、评分、格式、过期时间和可用性

VPS 后端配置来源为 `D:\下载\VPS\vps_LA.txt`。该文件含敏感凭据；凭据只能作为本地部署工具的输入，不得写入代码、日志、文档或 Git。

## 2. 已确认的 AniCh 客户端架构

AniCh 客户端不是 52 个站点适配器，而是瘦客户端：

```text
客户端
  │ GET /vod/{id}/{episode}
  ▼
聚合后端
  │ 标题匹配、集数映射、线路评分、URL 生成/代理
  ▼
线路数组
  │ URL、线路元数据
  ▼
客户端统一解码
  │ 播放器播放并支持手动切线
```

源码证据：

- API 请求构造：`_work/repo/AniCh-main/lib/src/apis/bangumi.dart:75-81`
- protobuf 解析和默认第一条线路：`_work/repo/AniCh-main/lib/src/pages/bangumi_vod/controller.dart:553-575`
- URL 解码：`_work/repo/AniCh-main/lib/src/pages/bangumi_vod/controller.dart:542-550`
- 播放器接收 URL：`_work/repo/AniCh-main/lib/src/pages/bangumi_vod/controller.dart:577-599`

AniCh 的 URL 包装是“Base64 字符串第 4 位插入垃圾字符”，不是加密，也不能作为安全机制。Zeluna 只为兼容现有 VPS 协议实现该解码，不把它当成认证或签名。

## 3. 52 个线路标签清单

以下标签来自已有本地采样分析，最终归属必须以 VPS 上的 provider manifest/代码为准，不凭 CDN 主机名猜源站名称：

```text
yk, yhk, wk, jk, ek, jc, ys, yi, yhs, yhi,
xk, jcy, yhw, yw, age, aw, cc, hb, hc, yhdm-cn,
dx, ck, dl, jok, ji, heibai, ws, xs, xi, cyx,
xgc, lm, xgk, wi, fok, fi, fs, lk, gu, jo, es,
fo, ec, fc, xf, gr, fk, mw, bfx, bf, aniopen
```

标签需要在 VPS manifest 中逐项对账：

| 维度 | 说明 |
|---|---|
| `tag` | 后端内部线路标签，例如 `fc`、`yk` |
| `provider_id` | 逻辑 provider 的稳定 ID |
| `source_name` | UI 展示的来源名 |
| `line_id` | 某一具体交付线路的稳定 ID |
| `score` | 服务端排序分/优先级 |
| `url` | 直连或 VPS 代理后的媒体 URL |
| `format` | MP4、HLS、DASH 等 |
| `headers` | 仅传递播放所需且允许的请求头 |
| `expires_at` | 临时 URL 到期时间 |
| `verified` | 服务端是否验证可播 |

## 4. Zeluna 中的落点

### 4.1 复用的核心模型

Zeluna 已有 `PlaybackLine`，包含：

- `id`
- `episodeId`
- `providerId`
- `providerName`
- `title`
- `quality`
- `format`
- `url`
- `headers`
- `serverVerified`
- `clientVerified`
- `startupProfile`
- `expiresAt`
- `available`

关键文件：

- `lib/src/domain/anime_models.dart`
- `lib/src/data/playback_source_repository.dart`
- `lib/src/data/zeluna_backend_playback_repository.dart`
- `lib/src/playback/playback_discovery_controller.dart`

### 4.2 新增 VPS 聚合 repository

新增一个 VPS backend repository，职责是：

1. 根据 subject、season、episode 请求 VPS 聚合 API；
2. 解析版本化 JSON，或兼容 AniCh 风格的 protobuf/整数数组响应；
3. 将每条线路映射为 `PlaybackLine`；
4. 保留 tag、来源、评分、线路 ID、质量、格式、过期时间和验证状态；
5. 使用稳定的 `line_id` 和 `sourceName`，使同一 provider 的不同线路在 UI 中分别显示；
6. 把临时 URL 过期视为刷新信号，而不是永久缓存；
7. 将取消、超时和空结果交给现有发现控制器处理。

不要新增平行播放器 controller。通过 `PlaybackBackendRepositoryFactory` 注入现有的 `PlaybackDiscoveryController`。

### 4.3 线路显示与故障切换

复用：

- `playback_line_display.dart` 的线路分组与展示
- `playback_line_controller.dart` 的失败线路记录
- `playback_discovery_controller.dart` 的缓存、渐进探测、取消和 fallback
- `stablePlaybackLineKey` 生成稳定线路 ID

一个聚合 provider 返回多条线路时，每条线路必须有独立 `sourceName` 或独立 line identity，否则 UI 可能把多条线路折叠成一张卡片。

## 5. 电影、电视剧与多季内容

### 5.1 电影

电影没有真实集数时统一映射为：

```text
episode = 1
```

线路返回仍是标准 `PlaybackLine`。UI 显示“正片”或“电影”，播放器无需特殊实现。

### 5.2 电视剧

电视剧每一集独立请求线路：

```text
subject/season/episode → 多条 PlaybackLine
```

服务端负责把源站的集数名称、数字、特殊集和分集组映射到规范 episode；客户端不根据 URL 或标题猜集数。

### 5.3 多季内容

subject identity 必须包含 season，例如：

```text
vps:series-123:season:2
```

避免不同季共用缓存、历史记录和播放进度。

### 5.4 能否播放

只要 VPS 返回有效的直接媒体 URL，电影和电视剧可以复用现有播放器：

- MP4
- HLS/M3U8
- DASH/MPD
- 带合法过期时间的临时播放 URL

此前采样中已经出现电影、电视剧和国创长内容，说明线路数据层并不天然限制为番剧。真正需要扩展的是内容模型、季/集映射和聚合 API，而不是播放器内核。

## 6. VPS 端统一接口建议

建议提供版本化 JSON 接口：

```http
GET /api/v1/playback/{content_type}/{subject_id}/{season}/{episode}
```

电影可使用 `season=0&episode=1`。

响应示例：

```json
{
  "schema_version": 1,
  "content_type": "movie",
  "subject_id": "vps:movie:123",
  "season": 0,
  "episode": 1,
  "lines": [
    {
      "line_id": "fc-5-123-1",
      "provider_id": "fc",
      "source_name": "线路 A",
      "tag": "fc",
      "score": 5,
      "title": "正片",
      "quality": "1080p",
      "format": "hls",
      "url": "https://controlled.example.invalid/video.m3u8",
      "headers": {},
      "expires_at": null,
      "verified": true
    }
  ]
}
```

如果必须兼容 AniCh 的响应，建议把 decoder 放在独立文件中，不让 protobuf 私有字段污染 Zeluna 的领域模型。

## 7. VPS provider manifest

VPS 应提供一份不含凭据的 manifest，至少列出 52 个 tag 的：

```json
{
  "schema_version": 1,
  "providers": [
    {
      "tag": "fc",
      "provider_id": "fc",
      "source_name": "来源名称",
      "lines": [
        {
          "line_id": "fc-main",
          "delivery": "direct",
          "format": "hls",
          "requires_headers": false,
          "expires": false,
          "enabled": true
        }
      ]
    }
  ]
}
```

密码、SSH 私钥、Cookie、token、签名密钥和数据库连接串不允许出现在 manifest 中。

## 8. 后端职责划分

### VPS 后端负责

- 源站/provider 适配
- 标题匹配
- 电视剧季/集映射
- 电影单集映射
- 多线路聚合
- 线路 score
- 临时 URL 刷新
- 由 VPS 控制的代理/直连决策
- 服务端可播放性验证

### Zeluna 客户端负责

- 调用聚合 API
- 解析线路
- 线路展示
- 本地可播放性探测
- 播放器启动
- 用户切线
- 失败线路回退
- 播放历史与进度

客户端不解析各源站页面，也不把 52 个源站做成 52 个 Flutter 插件。

## 9. 安全与隐私边界

- 不启用或伪造“bypass 模式”；没有必要绕过项目安全策略。
- 不在客户端生成、伪造或绕过第三方签名。
- 不在 Zeluna 客户端缓存、转存或代理媒体字节。
- 不把 VPS 密码写入项目、文档或命令输出。
- 播放请求头只允许必要字段，并经过现有网络策略过滤。
- 临时 URL 只短期缓存，过期后重新向 VPS 请求。
- 不提交真实播放 URL、Cookie、token、数据库或私钥。

## 10. 实施顺序

1. 读取 VPS 配置并确认服务端 API 基址/部署目录，不回显秘密。
2. 在 VPS 上生成 52-tag manifest，与本地清单逐项对账。
3. 确认聚合 endpoint 的真实响应 schema。
4. 在 Zeluna 增加 decoder 和 VPS repository。
5. 接入 `PlaybackDiscoveryController`。
6. 为同一 provider 的多线路补充独立 UI identity。
7. 增加动画、电视剧、电影、多季和多线路 fixture。
8. 用本地 mock API 验证解析与回退。
9. 对 VPS 每个 tag 做单线路 smoke test。
10. 使用 feature flag 灰度启用，并保留回滚配置。

## 11. 验证标准

- 52 个 tag 都有 manifest 对账结果；缺失项明确列出。
- 一个动画 episode 可返回多条线路。
- 一部电影按 episode 1 返回多条线路。
- 一部电视剧每集可返回多条线路。
- 多季作品不会共用错误缓存。
- 线路标签、来源名和 score 正确保留。
- 第一线路失败后自动选择下一条可用线路。
- 临时 URL 过期后能刷新。
- Internet Archive、规则插件和空 repository 现有测试不回归。
- Flutter analyze/tests、server pytest 和安全检查通过。
