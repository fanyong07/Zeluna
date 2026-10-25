# 真人影视声明式来源研究（2026-10-05）

> 阶段快照：本文保留研究子任务当时的结果。主线程后续接入、公开 HLS 补测、原生失败记录及默认关闭决策，见同目录 live-action-rule-validation-2026-10-06.md。

## 1. 结论与交接

**最小集合只有1个：优质资源库（新增规则/API入口，现有 `tvbox-json-api` 引擎）。电影和电视剧相邻两集已完成有界HTTP链路验证；Windows/Android原生播放未验证。** 收到主线程“1–2个即收尾”的收敛要求后，在该候选通过时停止，未扩大检索或补测站点。[S1][E1]

- 上游规则：`hd9211/Tvbox1`，固定提交 `9766d3045e3345aad84ce73fdbe23102159a059e`，文件 **`zy.json`**，JSON Pointer **`/sites/47`**（第48项），原名“优质资源库”，`type=1`。[S1][E2]
- API：`https://api.yzzy-api.com/inc/api_mac10.php`，直接声明的MacCMS式JSON接口。电影/剧集从 `vod_play_url` 取得直链，不需要HTML播放页、外部解析站、JS、Drpy、JAR或WebView。[S1][L2][E1]
- 推荐本地JSON：**`E:/anime/output/live-action-validation-20261005/research/youzhi.zeluna.json`**，JSON Pointer **`/rules/0`**；单规则声明 `movie` + `series`。[E3]
- 配置仅保存公开API端点和精确域名，不含实际媒体URL；未安装、未默认启用、未修改内置来源；仍是 `untrusted`，须走现有第三方规则权限审批。[E3][L3]
- **不是已证实独立的新媒体供应链。** API入口未在现有规则/后端注册表中出现，但现有MXdm、爱看机器人已声明其他 `yzzy.play-cdn*` 主机。可称“新增规则入口”，不可称“新增完全独立货源”。[L1][E4]

### 1.1 精确权限与适配点

| 项目 | 最小交付值 | 说明 |
| --- | --- | --- |
| engine | `tvbox-json-api` | 已有声明式JSON解析路径，不新增运行时。[L2] |
| baseUrl / searchUrl | `https://api.yzzy-api.com/inc/api_mac10.php` | 由引擎拼接公开 `ac=list&wd=...` 和 `ac=detail&ids=...`。[S1][E1] |
| contentType | `movie` | 主显示分类。[L3][E3] |
| manifest.contentTypes | `["movie", "series"]` | 项目内部电视剧类型为 `series`；探针的 `tv` 仅为研究标签。[L3] |
| pageDomains | `["api.yzzy-api.com"]` | 本轮无需站点主页/HTML解析域。[E1] |
| mediaDomains | `["yzzy.play-cdn17.com", "yzzy.play-cdn9.com"]` | 分别见电影及剧集清单和媒体首段；不允许 `*.play-cdn*`、`*` 或未经测试的同族域。[E1][L4] |
| Referer | 当前API端点 | 探针使用、现有引擎也按endpoint设置；未做去掉Referer对照，不宣称必须。[E1][E7][L2] |
| User-Agent | 固定普通审计UA | 配置与本轮探针保持一致；不做随机轮换或拦截后换头。[E3][E7] |
| JS / WebView / Cookie / cleartext HTTP | `false / false / none / false` | 不设置Authorization，不降级TLS。[E3] |
| 安装/启用 | `installedByDefault=false` | 完成用户审批和主线程原生测试前不自动启用。[E3][L3] |

仅供TVBox格式参照的极简文件另存为 `E:/anime/output/live-action-validation-20261005/research/youzhi.tvbox.reference.json`，对象 `/sites/0`。**它没有Zeluna精确媒体权限manifest，不作为本项目推荐直接导入文件。** 不要整包导入上游 `zy.json`，其中有其他来源和非本轮审查内容。[E3][L2]

## 2. 范围与执行边界

### 背景/目标

上一轮3个Kazumi番剧来源之后，补充真人电影/电视剧公开声明式候选。本研究只负责新增规则发现、排除已注册源和有界HTTP证据；主线程负责DBKU/Nivod/aikanbot等既有来源、业务接入和原生验证。DBKU和PPnix的最新情况来自主线程本轮消息，本研究未重复请求，不把该消息混入本研究现场证据。

### 实际范围

- 初始及收尾核对HEAD：`849cbca2735da6a28ae17872c8b054453f138f6f`；仓库存在主线程并行未提交修改，未reset/clean/stash/切分支、未覆盖其文件。
- 写入仅本文档与 `E:/anime/output/live-action-validation-20261005/research/`；已用 `git check-ignore` 确认后者被忽略。未写业务源码、版本、账号、发布、部署配置。[E4]
- 已读仓库AGENTS、CONTRIBUTING、SECURITY、工程进度以及现有rules/models/security/importer/playback resolver/PublicHttpTransport。[L1][L2][L3][L4][L5]
- 读取research skill；本聊天已是用户划分的研究子任务，不另建/联系其他聊天。
- 优先联网使用 `you-chrome-research.you_search`；上游文件与站方声明再以本地有界匿名GET核验。额外 `web.run` 对GitHub返回空内容，未作为事实证据。
- 实际HTTP站点候选5个：新浪、金鹰、闪电、淘片、优质。LibVio只见公开规则检索摘要，不请求其站点、不计已验证来源。总候选范围不超过6。

## 3. 去重基线

这里的“已注册”来自源码，不等于用户当前安装/启用状态；未读取私有用户账号或个人规则数据库。私有额外来源是否重名未知，主线程接入时仍应执行正常去重。[L1][L5]

- 当前内置：饭团动漫、爱看机器人、青空次元、独播库、泥视频，以及本轮先前添加的MXdm/稀饭/月城。
- 为避免伪新增，同时排除legacy定义：韩剧看看、美剧天天、低端影视、电影先生、电影港、新6V、酷吧电影。
- 后端直接来源：Nivod、DBKU、PPnix；既有 `play.xfvod.pro` 路径也不计新增。
- MacCMS20项（包括禁用/隔离项）：iKun、光速、如意、豪华、极速、猫眼、魔都2、速博、魔都、红牛、风车、爱奇艺、量子、电影天堂、暴风、百度、无尽、最大、360、虎牙。
- TVBox后端额外注册：非凡、索尼、海外看（以及已计入的暴风、量子）。[L1][L5]

最后定向检索 `yzzy|play-cdn17|play-cdn9|优质资源|youzhi`：现有注册入口未命中本候选，但出现MXdm的 `yzzy.play-cdn19.com` / `yzzy.play-cdn2.com` 和爱看机器人的 `yzzy.play-cdn19.com`。因此交付严格限于新增规则入口，不把CDN主机名不同当成独立供应证明。[L1][E4]

## 4. HTTP方法、安全和证据等级

### 4.1 请求约束

1. 复用仓库 `PublicHttpTransport`：DNS所有解析结果必须是公网；连接固定到校验IP、保留原始Host/SNI并验证TLS；拒绝私网/本机/带userinfo的URL。不继承环境代理。[L4][E7]
2. 来源并发最多2；同host间隔至少650ms；每次GET包含发送与有界读取的总时限15秒，单来源150秒；每源最多24请求，每请求最多3跳重定向。每一跳和嵌套媒体地址均重新经过公网检查；HTTPS到HTTP跳转被拒绝。[E7]
3. 站点API/详情至多1MiB；清单或直媒体初查至多256KiB；HLS最多3层、至多1条变体；首媒体段使用Range读取至多64KiB。不整片下载。[E7]
4. 不发Cookie/Authorization；遇401/403/429或明确挑战立即停止整个来源及对应host，不换UA/域名/协议重试。本轮闪电403后没有请求该来源API。[E5][E7]
5. 若HLS存在非NONE的 `EXT-X-KEY` / `EXT-X-SESSION-KEY`，本轮保守停止，不取密钥、不解密、不把加密声明直接断言为DRM。字节范围HLS不额外实现。没有绕过登录、验证码、DRM、白名单或TLS。现有播放器源码包含标准公开HLS AES-128密钥验证路径，主线程也确认已支持；本研究对新浪/金鹰的主动止步仅是本轮保守探测边界，不是DRM判定、播放器不支持或站点不可播的结论。主线程后续正常公开播放链测试属于另一份证据。[L2][E7]
6. 搜索词固定《流浪地球》《开端》；只选精确标题，详情确认年份及真人类型；最多2条精确标题候选详情、最多2组线路，只选择直接媒体。电视剧要求集号01、02且线路解析出15集；不扩大为全片库扫描。[E7]
7. 上游JSON/HTML/HLS响应、实际媒体URL及签名仅在进程内存；落盘为安全配置和host/status/timing/category/episode等结构化证据。不存原始响应、媒体片段或密钥。上游聚合JSON未整份落盘。[E2][E7][E8]

### 4.2 实际规模

- 5个候选站点的HTTP请求合计 **22次**：优质13、金鹰3、新浪API3＋声明页1、淘片1、闪电声明页1。GitHub固定提交发现和raw声明读取另2次，不算站点可用性证据。[E1][E2][E5][E6]
- 候选请求最长 **4914ms**，未超过15秒；1次403（闪电），0次429。候选之间最多2并发，没有无限重试。[E4][E7]
- 本地环境只是当前机器的网络出口；未专门测Windows/Android播放器、其他地区、代理/VPS出口、长播、音视频解码、广告段或DRM播放。[E1]

### 4.3 证据等级

| 等级 | 本研究的定义 | 不能据此宣称 |
| --- | --- | --- |
| D | 公开声明式配置与模型/引擎静态兼容 | HTTP活性或已安装 |
| M | 精确标题/年份/类型的搜索与详情通过 | 实际媒体可达 |
| H | 读到有效HLS，或加密声明处停止 | 媒体前缀或解码成功 |
| P | 三个样本完整通过元数据→HLS→识别出的有界媒体前缀 | Windows/Android实播、全片库稳定、画面确实对应标题 |
| N | 原生播放器解码/时间推进等现场验收 | 本研究没有执行N等级 |

## 5. 候选结果

| 候选 | 精确声明路径（固定提交 `zy.json`） | 实际最高证据 | 结果/停止原因 |
| --- | --- | --- | --- |
| **优质资源库** | **`/sites/47`** | **P：电影＋电视剧第01/02集** | **唯一最小交付候选；13请求**。[E1] |
| 新浪资源 | `/sites/38` | M/H：电影元数据与HLS | 清单非NONE加密声明；未取密钥、未测媒体/电视剧，不纳入可用集合。旧JSON是HTTP，站方帮助页确实声明HTTPS及 `xlm3u8`；本轮用站方HTTPS地址。[S2][E6] |
| 金鹰资源 | `/sites/29` | M/H：电影元数据与HLS | 清单非NONE加密声明；未取密钥、未测媒体/电视剧，不纳入可用集合。API `jyzyapi.com`，观察媒体host `hd.kuktxu.com`。[E6] |
| 闪电资源 | `/sites/36` | 声明页首请求 | `shandianzy.com` 返回403即停，未探API、不换域；不称永久失效。[E5] |
| 淘片资源 | `/sites/17` | API首请求 | `taopianapi.com` 连接/TLS错误；未关闭TLS、未换域或降级；未得HTTP响应，不称站点关停。[E6] |
| LibVio（仅检索参考） | `yw88075/tvbox` 的 `XBPQ/libvio.json` | 检索摘要，不算D/P | 未固定当前提交、未验证规则完整性/站点，不交付。达到1个通过后停止。[S3] |

新浪现场观察媒体host为 `play.xluuss.com`；金鹰为 `hd.kuktxu.com`。这些只属未完成候选的观察值，**不可合并进优质资源库的权限清单**。[E6]

### 5.1 优质：电影与相邻两集证据

观察起点：**2026-10-05 09:59:42（UTC+8）**。搜索和详情均HTTP200；清单与子清单均200；前三个媒体段前缀请求均206。响应的Content-Type为辅助证据，媒体判定还检查了188字节间距的连续MPEG-TS同步字节，而非仅看状态码或扩展名。[E1][E7]

| 样本 | 元数据/集数校验 | 线路 | 清单/媒体host | 媒体前缀 |
| --- | --- | --- | --- | --- |
| 流浪地球 | 精确标题；2019；科幻片；1条正片条目 `HD国语版` | `1080zyk` | `yzzy.play-cdn17.com` | 两层HLS；子清单1898段；206；65536字节；MPEG-TS |
| 开端 第01集 | 精确标题；2022；国产剧；线路共15集；集号1 | `1080zyk` | `yzzy.play-cdn9.com` | 两层HLS；子清单682段；206；65536字节；MPEG-TS |
| 开端 第02集 | 同一详情/线路；集号2，与1相邻 | `1080zyk` | `yzzy.play-cdn9.com` | 两层HLS；子清单645段；206；65536字节；MPEG-TS |

本轮样本未出现加密声明；没有获取密钥。上述标题/年份/类型正确性是对API元数据和集号的校验，未解码画面来核对演员/剧情，也没有验证声轨、字幕、广告或整集时长。媒体前缀可达不等于实播。[E1]

## 6. 交接/验收标准

### 已完成

- [x] 读取项目规则与引擎/权限代码，核对注册表和共享CDN限制。
- [x] 限定来源≤6、来源并发≤2、每请求≤15秒；403停止、TLS失败不降级。
- [x] 1个候选通过真人电影＋真人电视剧相邻两集的元数据/清单/媒体前缀。
- [x] 最小声明式JSON、精确域名、固定提交/JSON Pointer和脱敏证据已保存。
- [x] JSON结构与凭据/媒体URL落盘扫描（见本地审计）；不把静态检查等同于真实导入/播放。[E8]

### 由主线程继续，非本研究已完成项

- [ ] 使用推荐JSON的 `/rules/0`；确认实际用户规则无同端点重复，保留既有审批，不伪造 `official` 信任。
- [ ] 主线程按项目规范实现/接入；无需为该候选新加JS/JAR、额外解析站或特殊加密适配。
- [ ] Windows和Android分别进行原生解码、播放推进、暂停/恢复、相邻集切换、权限/失败提示验证；若媒体域不同，先补证，不扩大通配权限。
- [ ] 必要时补长播、广告/音视频质量、地区可达性与片库覆盖；不能从3个短样本推导全站可用。

### 许可和未知项

- GitHub公开配置是一手“规则声明”证据，不是站方运营者认证。未确认上游仓库许可证及完整再分发授权；本轮没有复制上游源码，也未复制整个聚合配置，只独立编写所需公开端点/本地模型字段。正式捆绑发布前主线程应另核许可与声明。[S1]
- 未核实各站点影片版权、传播许可、品牌使用权、隐私条款或各地区访问资格；HTTP可达不构成这些授权。[S1][S2]
- 本轮没有外部解析服务、公开粘贴凭据、登录或第三方账号行为。

## 7. 分阶段保存记录

1. 本地边界/来源库存阶段：先保存本文档；核对输出目录忽略规则、读取安全实现。
2. 上游/首轮验证阶段（09:58 UTC+8）：固定GitHub提交；新浪/金鹰停在加密清单；闪电403停站；保存各自安全结果及短Markdown。
3. 最后有界验证阶段（09:59起 UTC+8）：淘片连接/TLS失败；优质13请求完成完整P等级；立即在当前聊天汇报候选、规则路径、引擎、页/媒体域与适配点。
4. 收尾阶段：生成最小JSON、汇总和审计；保留“同CDN家族，非独立货源”“未原生播放”的限制；未扩大搜索、未向其他聊天发消息。

逐候选完成时间另见 `E:/anime/output/live-action-validation-20261005/research/phase-log.md`。[E4]

## 8. 完整来源与证据定义

### 外部一手规则/站方声明

- **[S1] 固定提交规则文件**：https://github.com/hd9211/Tvbox1/blob/9766d3045e3345aad84ce73fdbe23102159a059e/zy.json ；原始JSON：https://raw.githubusercontent.com/hd9211/Tvbox1/9766d3045e3345aad84ce73fdbe23102159a059e/zy.json 。2026-10-05现场从GitHub公开页读取 `currentOid`，再读固定提交raw。本文不声称该提交当日产生，未以观察日期冒充commit日期。支持JSON Pointer、type和API声明；不证明原生可播/版权/许可证。[E2]
- **[S2] 新浪站方帮助页**：https://xinlangzy.cc/index.php/help/index.html 。现场200，明确列出HTTPS `api.xinlangapi.com` 及 `from/xlm3u8/` 接口；用于选择公开声明的HTTPS入口，不是根据旧HTTP端点猜测。
- **[S3] LibVio静态发现记录**：https://github.com/yw88075/tvbox/blob/main/XBPQ/libvio.json 。仅You.com MCP索引摘要，未现场固定提交/测站；不支撑可用性结论。
- **[S4] 闪电站方入口**：https://shandianzy.com/ 。本地首GET403；这次失败才是本轮结论，不依赖搜索索引里的可访问描述。[E5]

### 本地实现（只读）

- **[L1] 规则清单及共享CDN**：`E:/anime/lib/src/rules/rule_plugin_repository.dart`、`E:/anime/lib/src/rules/bundled_kazumi_rules.dart`。
- **[L2] 导入/解析路径**：`E:/anime/lib/src/rules/rule_importer.dart`、`E:/anime/lib/src/rules/rule_playback_resolver.dart`、`E:/anime/lib/src/rules/tvbox_xbpq_hydrator.dart`（入口结构核对）。
- **[L3] 模型/信任/类别**：`E:/anime/lib/src/rules/rule_models.dart`、`E:/anime/lib/src/rules/rule_security.dart`。
- **[L4] 公网网络/权限**：`E:/anime/server/server/public_http.py`、`E:/anime/lib/src/rules/rule_http_policy.dart`、`E:/anime/lib/src/rules/rule_security.dart`。
- **[L5] 后端注册与边界**：`E:/anime/server/server/scrapers/maccms_sites.py`、`E:/anime/server/server/scrapers/tvbox_adapter.py`、`E:/anime/server/server/scrapers/direct_stream.py`、`E:/anime/server/server/scrapers/series/vod_common.py`、`E:/anime/server/server/aggregator.py`；仓库AGENTS/CONTRIBUTING/SECURITY及 `E:/anime/docs/engineering-goal-progress.md`。

### 本次ignored脱敏证据（均不含实际媒体URL/响应体）

- **[E1] 优质完整HTTP证据**：`E:/anime/output/live-action-validation-20261005/research/result-youzhi.json`。
- **[E2] 上游固定提交与所选安全字段**：`E:/anime/output/live-action-validation-20261005/research/upstream-selected.json`。
- **[E3] 最小配置**：`E:/anime/output/live-action-validation-20261005/research/youzhi.zeluna.json`；TVBox格式参照 `E:/anime/output/live-action-validation-20261005/research/youzhi.tvbox.reference.json`。
- **[E4] 汇总/阶段记录**：`E:/anime/output/live-action-validation-20261005/research/summary.json`、`E:/anime/output/live-action-validation-20261005/research/phase-log.md`。
- **[E5] 声明页现场结果**：`E:/anime/output/live-action-validation-20261005/research/declaration-shandian.json`、`E:/anime/output/live-action-validation-20261005/research/declaration-sina.json`。
- **[E6] 其余候选安全结果**：`E:/anime/output/live-action-validation-20261005/research/result-sina.json`、`E:/anime/output/live-action-validation-20261005/research/result-jinying.json`、`E:/anime/output/live-action-validation-20261005/research/result-taopian.json`。
- **[E7] 本轮独立编写的有界脚本（未执行下载代码）**：`E:/anime/output/live-action-validation-20261005/research/bounded_http.py`、`E:/anime/output/live-action-validation-20261005/research/discover.py`、`E:/anime/output/live-action-validation-20261005/research/inspect_declarations.py`、`E:/anime/output/live-action-validation-20261005/research/validate_maccms.py`、`E:/anime/output/live-action-validation-20261005/research/finalize_config.py`。
- **[E8] 收尾静态/隐私审计**：`E:/anime/output/live-action-validation-20261005/research/artifact-audit.json` 及 `E:/anime/output/live-action-validation-20261005/research/audit_artifacts.py`。

本次明确区分：**规则声明存在 → HTTP样本通过 → 实际导入/原生播放 → 发布授权**。仅前两项有本研究证据。
