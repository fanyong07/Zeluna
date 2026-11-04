# Zeluna：AniCh 地址解析与 Animeko / Kazumi 集成

更新日期：**2026-11-04**。本文描述当前部署的服务端集成、验证证据与已知限制，不把历史源站统计当作当前可播放率。

## 一、当前架构与能力边界

**VPS 分发元数据、播放 URL 和必要请求头，播放器直连媒体 CDN；本次集成不部署媒体代理。** 取地址、验证地址与播放媒体是三个不同阶段。

```text
客户端 ──搜索 / 章节 / 取址 API──> Zeluna
                                  │
                    ┌─────────────┼─────────────────┐
                    │             │                 │
                 AniCh         Animeko           Kazumi
            元数据 / 线路池    规则静态解析       搜索 / 章节
                    │             │                 │
             包装 URL 查映射     播放 URL           无播放 URL
                    │             │
                    └────── URL + headers ──────────> 客户端
                                                       │
                                                       └──直接请求媒体 CDN

AniCh 未命中 / 待复检映射
  └──后台经独立出口请求包装地址，仅取得重定向 Location
       └──部署出口做有界首字节探测
            └──SQLite 持久化 → 当前进程内存映射 → 后续 API 交付
```

- 元数据 relay 是可选的上游 API 传输入口，与媒体转发不是同一件事。
- 包装地址解析只获取重定向，不跟随下载媒体；首字节探测单独执行，并设置读取上限。
- 既有 HLS 广告剪裁属于清单文本重写，分片仍指向源站 CDN，不是分片或完整视频代理。本次 MP4 样本不用于证明 HLS 剪裁效果。
- 历史 `/media/<token>` 代理、媒体回环取流及分片透传方案不属于当前交付架构；不再把这些路径列为部署目标或验收前提。

| Provider | 当前集成能力 | 边界 |
|---|---|---|
| `crawler.anich` | 搜索、详情 / 集数、线路池与包装地址映射 | 返回地址不等于完整播放验证；失效与出口差异需分阶段记录 |
| `crawler.animeko` | 按规则搜索、详情 / 章节、静态取址 | 并非所有规则都有可执行取址路径；不执行任意 JavaScript |
| `crawler.kazumi` | 搜索、详情 / 章节 | 注册能力仅 `search` / `detail`；播放入口有意返回空列表 |

## 二、AniCh 协议与线路处理

### 2.1 已覆盖的协议子集

现有实现使用 `/bangumi/search`、`/bangumi/detail/{id}`、`/bangumi/episodes/{id}` 和 `/vod/{id}/{sort}`。取址前先用章节表把请求集号映射成上游跨季全局 `sort`，不把季内序号直接当全局序号。

传输由 [anich_transport.py](<../server/server/scrapers/anime/anich_transport.py>) 管理：约定 UA、候选域、串行节流与失败冷却；配置 relay 时，元数据请求改发 relay，可附带 `X-Relay-Key`。这只是当前覆盖的协议路径，不称为对上游全部客户端行为的完整逆向。

`/vod` 响应可能是 protobuf 原字节，也可能外包 JSON 字节数组。先解包，再解析 `vod_item_`：

| 字段 | 类型 | 当前用途 |
|---|---|---|
| 1 | string | 去位 Base64 编码的地址 |
| 2 | uint32 | 上游线路 `sort`，不单独作为交付优先级 |
| 4 | string | 线路 / 集号标题 |
| 5 | string | 上游线路标识，用于区分线路身份 |
| 6 | string | 作品标题，可用于匹配校验 |

去位 Base64 的处理要补齐 padding，逻辑等价于：

```python
payload = encoded[:3] + encoded[4:]
url = base64.b64decode(payload + "=" * (-len(payload) % 4)).decode("utf-8")
```

正式解包与解码见 [anich_proto.py](<../server/server/scrapers/anime/anich_proto.py>)；无效编码、明确的播放器页面或脚本入口由适配器过滤。字段 5 与重复标识后的序号用于维持独立线路身份，而非把整池线路折叠为同一名称。

### 2.2 主机分类与排序先验

[anich_hosts.py](<../server/server/scrapers/anime/anich_hosts.py>) 是本地纯函数分类表，不进行网络测量。分类包括包装入口、合作落点、对象存储 / CDN、采集站 HLS、广告素材及未知地址。

- 广告专用子域与混合域采用不同判据；混合域还需路径形状支持，避免仅凭同属字节 / 快手域名就把正片归成广告。
- `line_rank` 对疑似广告素材降权；**降权排序不等于已从所有交付路径硬删除**。其他过滤层应独立验证。
- `latency_band` 的 `0.40 / 0.50 / 2.00 / 2.30` 等数值是历史分类先验，不是当次请求的 TTFB、吞吐量或起播耗时。域名分类也不证明画质或内容纯净度。
- 是否重写 HLS 清单还会参考清单广告标记缓存，不简化为“某类 CDN 永远无贴片”。

[anich_line_audit.py](<../server/tools/anich_line_audit.py>) 可查看原始线路池的分类和排序，但其延迟列来自上述固定先验；它不等价于生产 API 交付或逐线可播放测试。

## 三、AniCh 包装地址：解析、持久化与续期

### 3.1 解址与验证分离

[anich_direct.py](<../server/server/anich_direct.py>) 识别已知包装主机族，经 `ANICH_RESOLVE_PROXY` 指定的独立出口获取重定向。默认配置入口为 `http://127.0.0.1:7899`，`direct` / `none` / `off` 等显式值可选择直连。

历史观测曾在特定部署 IP 得到 Cloudflare Error 1006；这只说明当时该出口的响应。换出口是否有效应以实际解析结果为准，不把错误码推导成所有地区或所有机器的结论。

解析后的目标由部署出口发 `GET + Range: bytes=0-1023`，最多读 1 KiB 样本并关闭响应。即使上游忽略 Range，也不整包缓冲；HTML / JSON 错误页及空响应不记为健康。此探测证明的是**该出口、该时刻有首字节响应**，不证明完整播放、拖动、持续吞吐或其他地区可达。

### 3.2 地址与到期字段

[anich_refresh.py](<../server/server/anich_refresh.py>) 把包装 URL 到真实 URL 的映射写入 `anich_resolved_addresses`，保留解析时间、验证时间、健康状态、失败计数、错误与延迟等字段。

当前到期解析识别 `x-expires`：

- 正数作为已解析到的绝对到期时间；已到期签名仍是到期签名，不转换成无到期值。
- `expires_at = 0` 表示**未解析到受支持的明确到期值**，不等于没有其他签名机制，也不等于永久有效。
- 不按主机族保证“带签名 / 不带签名”，不从少量样本推断全族签发时长。

写入使用 SQLite `ON CONFLICT DO UPDATE`，避免查后插入的竞争窗口。历史 UNIQUE 错误本身不足以确定是 autoflush、同批重复还是并发写入，不在文档中把推测写成已复现根因。

### 3.3 扫描、复检与降级

| 项目 | 当前默认值 | 含义 |
|---|---:|---|
| `ANICH_RESOLVE_REFRESH_SECONDS` | 21600 秒（6 小时） | 后台每轮扫描的间隔 |
| `ANICH_RESOLVE_REVERIFY_SECONDS` | 86400 秒（24 小时） | 验证时间超过该值的条目进入复检候选，包含到期值为 0 的映射 |
| 到期安全余量 | 6 小时 | 距签名到期不超过该值的映射停止正常缓存交付 |
| 提前重解窗口 | 12 小时 | 临近签名到期的条目进入刷新候选 |
| 连续失败阈值 | 3 次 | 解析或目标探测连续失败后，健康标记降级 |

刷新选择临期、已不健康或超过复检周期的行；成功更新地址和验证时间，并清零失败计数。失败保留旧地址，不删除历史映射，累计失败后停止作为健康映射加载。成功恢复后可重新参与交付。

**24 小时是复检候选阈值，不是严格到龄删除。** 无明确到期值的行不会仅因年龄自动消失；实际复检还取决于 6 小时扫描、批次和网络结果。旧地址仍有健康标记且未跨到期安全余量时，失败阈值前可能继续使用。

### 3.4 内存进程边界与公开投影

SQLite 是持久层；同步查询使用每个 Web 进程自己的内存映射。启动装载，以及该进程内成功完成解析 / 刷新后的重载，维护本进程缓存。

- 单独运行 CLI 写库并装载的是 **CLI 进程**的内存，不会直接更新已运行 Web worker 的字典。
- 多 worker 之间不共享该内存；运维需要分别等待其刷新、明确触发重载，或在受控部署中重启相关进程。数据库行数与某进程内存条目数应分别观测。
- 播放缓存持久化私有 `_resolved_wrap_url`，保留真实地址对应的包装 origin，便于后续签名更新和失效回退；该内部键在公开响应投影中移除。
- 公开交付前会按当前映射替换地址；映射失效时可能回退包装地址、触发后台重解，并要求客户端重新验证，而非继续把旧直链当作已验证可用。
- 内部来源标签公开化与私有字段移除是输出约定，不是隐藏所有 CDN 域名。客户端直连时会看到实际媒体主机。

相关公开投影见 [playback.py](<../server/server/playback.py>)，生命周期见 [main.py](<../server/server/main.py>)。

## 四、Animeko 与 Kazumi 的规则执行范围

### 4.1 Animeko

实现见 [animeko.py](<../server/server/scrapers/anime/animeko.py>)、[animeko_engines.py](<../server/server/scrapers/anime/animeko_engines.py>) 和 [animeko_rules.py](<../server/server/scrapers/anime/animeko_rules.py>)。

- 规则执行器覆盖 `web-selector`、`json-api` 与 `rss` 子集。
- 静态 MacCMS `player_aaaa` / `player_data` JSON 的 `encrypt=0/1/2` 可解析：原文、URL / `%uXXXX` 解码、Base64 后再解码。不执行 JavaScript 表达式、自定义加密或浏览器挑战；只取当前 `url`，避免误把 `url_next` / `url_pre` 当本集地址。
- 规则允许嵌套时，静态 iframe 跟进最多 3 层、6 个后续页面，带访问去重。未配置嵌套正则时只信实际 iframe；显式无效或不匹配规则不扩大为任意链接遍历，已知媒体 URL 不作为嵌套页面下载。
- `RSS` 仅提供 BT / torrent / magnet 资源信息，不把它计为 HTTP 视频直链能力。
- 规则需要的 Referer、Cookie、UA 随取址结果交付给播放器；“取到 URL”与“客户端请求头正确且能持续播放”分别验收。

历史 21 源粗基线为 **13 源搜索、12 源详情、3 源取址有结果**。本次没有重新遍历全部 21 源，不把新 Girigiri 样本推广成全规则库成功率。

### 4.2 Kazumi

实现见 [kazumi.py](<../server/server/scrapers/anime/kazumi.py>) 与 [kazumi_rules.py](<../server/server/scrapers/anime/kazumi_rules.py>)。

- 规则快照含 86 条规则，其中 18 条活跃；HTML XPath 与接口式搜索 / 章节分别执行，逐规则隔离失败。
- 容错仅机械改写明确的简单属性表达式；XPath 1.0 字符串按需生成 `concat()`。合法 child predicate 和含义不明的表达式保持原语义。
- 解码顺序是 BOM、HTTP 显式 charset、meta、UTF-8、原字节解析兜底。UTF-8 是适配器的无声明优先项，不是 HTML 的统一默认；不猜无声明 GBK。
- 客户端显式丢弃站点 Cookie，并在每次请求（含重定向）前移除 Cookie。
- **只交付搜索与章节元数据**；`get_video_urls()` 返回 `[]`，不把章节页 URL 当播放地址，不补 WebView 嗅探链路。

历史报告“18 活跃 / 14 搜索 / 11 章节有结果”只是粗统计。baimao 曾把“排行榜 / 前传 / 文件名”误当章节，故其中的“有结果”不等于章节准确。本次只对下述 akianime 样本记录准确标签与空播放结果，不重新宣称整库章节质量。

## 五、2026-11-04 生产验证

### 5.1 报告与观测点

| 报告 | 时间 / 观测点 | 证据范围 |
|---|---|---|
| [production-http-loopback.json](<../server/data/integration_release/production-http-loopback.json>) | 14:36:05 UTC；`http://127.0.0.1:8000` | 本机 HTTP API 与有界媒体样本 |
| [production-http-public.json](<../server/data/integration_release/production-http-public.json>) | 14:39:30 UTC；`https://api.zeluna.top:8443` | 公网 API 与运行该探测器的客户端直连媒体样本 |
| [production-http-stable.json](<../server/data/integration_release/production-http-stable.json>) | 14:47:43 UTC；同一公网 API | 真实 catalog 稳定 ID 的 v3 交付及同批三源检查 |
| [production-http-final.json](<../server/data/integration_release/production-http-final.json>) | 14:55:32 UTC；最终窄补丁重启后公网 API | 三源、媒体有界样本及稳定 ID 的最终复验 |
| [production-runtime.json](<../server/data/integration_release/production-runtime.json>) | 同次部署运行时快照 | 映射、配置、缓存、迁移与数据库检查 |
| [production-refresh.json](<../server/data/integration_release/production-refresh.json>) | 同次部署刷新调用 | 刷新选择、解析 / 探测结果及失败计数变化 |
| [production-renewal.json](<../server/data/integration_release/production-renewal.json>) | 服务用户的独立续期调用 | 指定健康映射的成功解析、验证与入库；非周期选中记录 |
| [production-runtime-final.json](<../server/data/integration_release/production-runtime-final.json>) | 重启后的第二集首次请求 | 非缓存取址、包装地址回退、触发后台补解 |
| [production-runtime-repeat.json](<../server/data/integration_release/production-runtime-repeat.json>) | 第二集重复请求 | 主服务缓存交付中的包装地址已替换、映射增长 |
| [production-attestation.json](<../server/data/integration_release/production-attestation.json>) | 14:58:38 UTC | 112 个文件哈希、服务状态、媒体代理关闭 |

时间均为 2026-11-04；四次 HTTP 报告分别约为香港时间 22:36 / 22:39 / 22:47 / 22:55。报告保存状态、主机和读取字节数，不保存完整签名播放地址。

### 5.2 三源样本

| 样本 | 回环 API | 公网 API | 结论限定 |
|---|---|---|---|
| AniCh `crawler:anich:32564` | 12 集；10 条 URL，10 条命中缓存；重复请求仍为 10 条缓存 URL | 同为 12 集、10 条缓存 URL | 该条目的集数与缓存线路交付通过 |
| Animeko `girigiri-ai-dongman` 的 `GV25524` | 28 集；3 条 URL，首次为未缓存 | 28 集；3 条 URL，均命中缓存 | 该规则 / 条目的静态取址与缓存交付通过 |
| Kazumi `akianime` 的 `dPDDDE-1-1` | 84 条章节，前三标签 `01 / 02 / 03`；VOD 为 0 | 同为 84 条章节、VOD 为 0 | 章节元数据与无播放能力契约通过；84 是条目数，不推为 84 个不同正片集数 |

AniCh 本次媒体样本落在 `lf16-faceu-file-sign.bytecdn.com`，Animeko 样本落在 `ana.girigirilove.com`；回环及公网报告都记录 **HTTP 206、读取 1024 字节、`video/mp4`、MP4 头部识别**。这不是完整视频下载，也没有验证所有返回线路或全片播放。

上述 URL 列表检查记录：包装域 URL、已检查的本机地址、本站 `/media/` 代理 URL、所检查字段中的内部来源标签及 `_resolved_wrap_url` 均为 0。检查覆盖的是工具明确列出的字段 / 主机 / 路径，不外推为所有接口和所有字符串零泄漏。

### 5.3 稳定 ID 的 v3 交付

14:47:43 UTC 的报告补验真实 catalog 条目 `bangumi:400602`（葬送的芙莉莲）：v3 播放接口 **HTTP 200、0.903 秒、37 条 URL，37 条命中缓存**。所检查的包装域、私有地址、`/media/` 代理、内部来源标签与私有缓存键计数均为 0。

其中出现的 `api.zeluna.top` 主机属于既有 HLS 文本清单交付路径，不等同于媒体代理；是否代理媒体应按具体路径与处理行为判断，不按“是否本站域名”一刀切。本次稳定 ID 结果证明该样本的聚合 API 交付，不证明这 37 条线路均已完整播放。

### 5.4 映射与刷新：成功和失败都保留

运行时快照显示：

- 共 **11** 行映射，**10** 行健康，受检进程内存加载 **10** 条。
- 按报告命名，`unsigned=2`、`signed=9`；这里沿用工具的到期字段分组，不把 unsigned 解释为永久无签名。
- 族分组为 cloudflare 10、edgeone 1；不是对每族可播放率的统计。
- 数据库检查为 `ok`，迁移为 `0016_anich_resolved_addresses`。

最近一次显式调用刷新选择逻辑，实际只选中 **1 条不健康映射**：包装层重定向解析成功（302），但目标探测返回 **HTTP 404**；`requested=1 / resolved=1 / usable=0 / degraded=1`。该行失败计数由 4 增至 **5**，健康行和内存缓存仍为 **10**，数据库 quick check 为 `ok`。

另一次以服务用户在独立诊断进程中，指定已健康的 `lf16-faceu-file-sign.bytecdn.com` 映射调用 `resolve_and_store`：`requested=1 / resolved=1 / usable=1 / refreshed=1 / degraded=0`，无错误，缓存仍为 **10**；`recent_updates=1 / recent_verified=1`，数据库 quick check 为 `ok`。这是**明确指定一条映射的成功续期与入库**，与前述 `refresh_expiring` 自动选择不健康行并维持降级的记录分开计证。

续期报告的 `memory_loaded=10` 属于该诊断进程，不证明当时 Web 主进程已即时载入新映射。随后已完成最后补丁部署并重启，启动流程执行 warm reload；重启后的公网 API 与媒体首字节复验见下节。

这两次观测分别证明成功续期入库与失败降级路径有运行记录，不证明曾遍历全库、全部映射均已当天复检或目标地址普遍可播；也不单凭 404 断言文件被清理或所有出口都失败。

### 5.5 最后补丁、重启与非缓存链路

最终六文件补丁完成并重启后，14:55:32 UTC 的 [公网验收](<../server/data/integration_release/production-http-final.json>) 再次通过严格门禁：AniCh 为 12 集 / 10 条缓存 URL，Animeko 为 28 集 / 3 条缓存 URL，Kazumi 为 84 个章节条目 / 0 播放 URL；两份 MP4 源站样本仍为 HTTP 206 / 1024 字节。稳定条目 `bangumi:400602` 本次为 **40 条 URL、40 条缓存、0.901 秒**，早先 37 条的观测保留为历史，不当作固定线路数。

另外用 AniCh 同一条目的第二集验证首次取址与后续映射替换：

1. [首次请求报告](<../server/data/integration_release/production-runtime-final.json>)：HTTP 200、14.387 秒、6 条 URL、`cached=0`，其中 1 条仍为包装地址；这是未解映射的客户端回退，不记录成全线路直链成功。
2. [重复请求报告](<../server/data/integration_release/production-runtime-repeat.json>)：HTTP 200、回环耗时 **0.038 秒**、6 条 URL、`cached=6`、包装地址 **0**，对应地址已改为 `v16.topbuzzcdn.com`。两次公开响应的私有缓存键和内部 AniCh 标签计数均为 0。该变化发生在主服务请求链路，不是把独立诊断进程的内存误当作 Web 内存。
3. 重复请求时数据库快照增长到 **23 行映射 / 16 行健康**，诊断进程可加载 16 条，`recent_updates=13 / recent_verified=7`。这说明按需后台解析确有落库进展，不把其余不健康记录算成可用地址；数据库 quick check 仍为 `ok`。

14:58:38 UTC 的 [最终部署核验](<../server/data/integration_release/production-attestation.json>) 显示：原清单叠加最终补丁的 **112 个文件全部匹配 SHA256**；`zeluna.service`、`mihomo-outbound.service`、`vod-relay.service` 均为 active、`NRestarts=0`；Zeluna 主进程为 `1079991`，服务账户为 `zeluna`。运行中的 relay 进程 `RELAY_MEDIA_PROXY=0`，未开启媒体代理。

AniCh 上游冷却曾导致非缓存 v2 请求返回 500，最后补丁将该特定异常转换为脱敏的 HTTP 503 与 `Retry-After: 30`；已有缓存仍优先交付，失败不写空缓存。该错误边界有离线 HTTP 回归；上述第二集记录则是上游恢复后的生产成功路径。

## 六、部署范围、启用与回归

### 6.1 本次部署边界

生产备份目录：`/opt/zeluna/backups/integration-20261104T141627Z`。

初次部署按 [manifest.json](<../server/data/integration_release/manifest.json>) 的 **112 个明确路径**交付；最终又按 [patch-manifest.json](<../server/data/integration_release/patch-manifest.json>) 覆盖其中 **6 个已有路径**，未扩大部署范围。两层均记录逐文件 SHA256，最终覆盖记录见 [patch-installed.json](<../server/data/integration_release/patch-installed.json>)。最终补丁前代码备份为 `/opt/zeluna/releases/integration-20261104/before-final-patch`。包内不包含数据库、WAL / journal、环境密钥文件或临时调试工具；数据库结构由迁移管理，不拿本地数据库覆盖生产。生产启用配置单独落实，不把环境文件打进部署包；最后六文件补丁不修改数据库和环境文件。

运行状态已报告 **14 个 enabled provider IDs**，其中新启用的两个为 `crawler.animeko`、`crawler.kazumi`：

```text
aggregate.maccms
crawler.age
crawler.girigiri
crawler.anich
crawler.xgcartoon
crawler.yhdmm
crawler.jibi
crawler.yinghua2
crawler.wedm
crawler.xifan
crawler.nivod
crawler.ppnix
crawler.animeko
crawler.kazumi
```

仓库默认 gate 与生产显式启用是两个层次：新规则源默认关闭，部署需分别启用对应配置并加入 provider allowlist。聚合搜索给 Animeko 30 秒、Kazumi 18 秒的独立预算，避免被通用的短超时提前取消；预算增加不等于所有源都能及时完成。

### 6.2 本地回归记录

本次已记录的检查：

- 三源组合回归 **224 项通过**，配套 `ruff` 检查通过。
- Animeko 独立回归 **55 项通过**。
- Kazumi 独立回归 **112 项通过**；最终单独运行记录为 `112 passed in 13.44s`。
- 全量回归：**1222 passed、309 subtests passed，479.16 秒，exit 0**；有 1 条 `StarletteDeprecationWarning`。
- 全量收集之后新增的兼容 API 边界用例，另行运行记录为 **6 passed、2 subtests passed，18.16 秒**。它是独立补验，不把新增用例追溯计入上述全量数字。
- 最后六文件补丁的相关回归另行记录为 **70 passed、4 subtests passed，26.43 秒**，包括无 URL 占位缓存、解析后目的媒体格式、AniCh 上游冷却的 503 / `Retry-After: 30`、恢复后 fresh→cached，以及有界探测与严格验收门禁；Ruff 检查通过。

在服务端工作目录使用本地解释器复验 Kazumi：

```powershell
$env:PYTHONIOENCODING = 'utf-8'
.\.venv\Scripts\python.exe -m pytest tests/test_kazumi.py -q
```

测试覆盖和生产样本是独立证据：离线回归不证明源站可达，公网样本也不替代协议、缓存隔离和错误降级的离线测试。

### 6.3 维护操作与观测原则

以服务用户从部署目录运行现有 [resolve_anich_addresses.py](<../server/tools/resolve_anich_addresses.py>)：

```bash
# 配置检查与当前 CLI 进程缓存装载
runuser -u zeluna -- /opt/zeluna/venv/bin/python tools/resolve_anich_addresses.py --selftest

# 调用当前复检选择逻辑（会写库，非只读检查）
runuser -u zeluna -- /opt/zeluna/venv/bin/python tools/resolve_anich_addresses.py
```

不要把 CLI 自检中的内存计数当成 Web worker 已同步的证据。服务账户写库可避免由其他账户创建不同属主的 SQLite 辅助文件；修改前保留生产备份，不清理用户数据库来规避故障。

HTTP 验收使用 [verify_integrations_http.py](<../server/tools/verify_integrations_http.py>)，有界媒体诊断使用 [media_sample.py](<../server/tools/media_sample.py>)：非 HLS 媒体样本至多 1 KiB，清单读取上限 64 KiB，嵌套清单跟进有界，不下载完整分片或视频。此验收 GET 可能触发缓存 / 后台解析，不把它描述成完全不改变状态的操作。

后续故障按“元数据请求 → 包装层解析 → 目标首字节探测 → 缓存投影 → 客户端实际播放”分别记录时间、出口和错误。不要把某一阶段的成功推广成全库可播，也不要把某一阶段的失败直接归因给全部上游。
