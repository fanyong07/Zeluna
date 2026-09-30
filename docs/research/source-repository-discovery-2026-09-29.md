# Zeluna 新播放源与原始规则仓库发现（2026-09-29）

> 性质：独立、只读来源研究；不是安装清单审计、美国/韩国服务器探测或播放验收。
> 基线：E:/anime，Git HEAD d07d3e40306433b239e0d7e2eed91974eb6aab7d。
> 采集时间：2026-09-29T12:09:21.789Z（UTC）。下文提交时间统一为 UTC；用户工作日期为 2026-09-29，香港时区 UTC+8。
> 唯一写入：E:/anime/docs/research/source-repository-discovery-2026-09-29.md。

> 主线补测更新（2026-09-29）：研究交接后，央视公开点播样本的两种 HLS 在 LA/KR 均通过媒体清单和首段检查；Akianime/ezdmw 两地搜索、详情、剧集可读但静态媒体未验证通过。下文“本研究未验证”保留为独立研究阶段边界，最终实测以 `E:/anime/docs/research/playback-source-audit-2026-09-29.md` 及对应 JSON 为准。

## 1. 结论与推荐顺序

1. **先测 1 个可 API 化的新原站协议候选：央视网公开点播。** 原作者 drpy3 示例列出栏目、专辑、视频信息 JSON 路径；央视官方动画页可读出真实视频 GUID。仅建议用公开点播响应中的原始媒体地址做有界验证，不复制其直播解密、代理或清晰度 URL 改写逻辑。当前项目没有可直接导入这些原生 JSON 的适配器，不能称为“已兼容即插即用”。[S3][S4][S5]
2. **番剧增量优先 Akianime、二站动漫 ezdmw。** 两者在本次扫描的代码/研究基线中无名称及原站主机命中，也未列于主线提供的安装摘要。属于“待完整安装清单去重的新原站候选”，不是已经证明新增、可播或拥有独立片库。规则格式可被 Kazumi 导入器表达，但都声明 WebView，服务端播放仍未知。[S1a][S1b][L2]
3. **嘀嗒影视、热播之家退出首批补测队列。** 它们来自用户已订阅且主线确认可解析 18 条规则的 Animeko 订阅，不作为本轮新增推荐；仅保留差异说明，避免与主线重测。[S2a][S2b]
4. **本轮没有核实出同时满足“一手站方出处、未在原有逻辑组中、无需私密认证”三项要求的新增 MacCMS 端点。** 不重复报本地已整理的 80 个候选组，也不根据站点使用 MacCMS 模板就猜测它公开了 provide/vod。[L1][S10]
5. **排除伪新增：** aafun 与 moonci 当前同指 moonci.com；已有 Animeko 订阅/站点、Kazumi 镜像、TVBox 聚合目录、规则私有化工具、Drpy 引擎升级，都不能分别算新增播放站。[S1c][S2][S6][S7][S8][S9]

**最终收敛：8 个核心一手仓库，交接 3 个 P1 补测候选；0 个本研究服务器已验证可播源；0 个本研究已安装/已部署源。** 早期检索中见过的镜像/聚合工具只作排除说明，不扩大后续研究或测试队列。

## 2. 范围、方法与证据等级

### 实际执行

- 首先读取 E:/anime/AGENTS.md 和 research skill；检查 docs、server、lib 下有无更具体 AGENTS.md，本次未发现。
- 静态读取 E:/anime/docs/research 的 Markdown、E:/anime/server/server 的 Python 源码，以及 E:/anime/lib/src/rules 的 Dart 源码。没有读取运行数据库、安装状态、VPS 配置或认证文件。
- 优先调用 you-chrome-research 的 you_search / you_contents 找候选及作者说明；也按要求调用 web.run。**本次 web.run 返回空结果，未将空结果当成证据。**
- 匿名 GitHub REST 请求遇到限额；未寻找或使用令牌。改为读取 GitHub 官方仓库网页的公开嵌入数据、官方 commits 页面、raw.githubusercontent.com 的固定提交文件。归档、fork、许可标记来自官方页面元数据；最近提交采用默认分支提交记录的 committedDate，而非搜索索引时间、README 宣称日期或 pushed_at。
- 读取央视官方栏目页及一张动画详情页的静态 HTML，只取节目名和视频 GUID。没有执行页面脚本、加载播放器或请求播放 API。
- 所有第三方规则只作文本/JSON 数据检查；没有执行、安装、构建或部署第三方代码，没有提交、推送或后台自动化。

### 标签含义

- **已知**：本轮读到的固定提交原始文件、GitHub 官方状态、本地源码或用户明确提供的安装摘要。
- **推断**：由规则字段、调用方式和本地引擎边界推导的兼容性/优先级；不等于运行测试。
- **未验证**：实际安装差集的最终确认、原站及媒体活性、US/KR 地域行为、首帧/长播、独立运营主体、内容版权/分发授权。
- **原始上游仓库**指规则作者/客户端官方链接的源头；并不意味着作者拥有该视频站，也不意味着视频内容获授权。

## 3. 既有基线与新增定义

### 3.1 主线于本次会话提供的真实安装摘要（本任务未重复读取）

- 64 条已安装、27 条启用、59 条自定义；anime/series/movie 别名不代表独立站。
- 仓库订阅：http://xhztv.top/4k.json 与 https://sub.creamycake.org/v1/css1.json；另一个仓库记录 URL 为空。**本任务未重新拉取上述在线订阅端点。**
- Animeko 已有 omofun111/enlienli.link、girigiri、风铃/aafun.cc、叽哔、E-ACG、稀饭、森之屋、风车影视、去看吧、海星、樱花/yhdm6go.top、第一动漫、次元方舟、米粒、萌道、UZVOD、嘀哩、2k、新优酷、YHDMM、yinghua2、wedm 等。
- TVBox 已有茅台、光速、初恋/video.adminqt.cn、量子、索尼；Drpy 已有聚玩盒子4K、360、荐片；额外 builtin 为 aikanbot、dbku、fantuan、nivod、sorani。
- 上述摘要带“等”，不是完整逐条列表。因此本报告用“摘要未列出、待全量去重”，不擅自声称某候选肯定未安装。

### 主线后续更正与两地结果（用户提供，本研究未复测）

| 项目 | 当前主线事实 | 本报告采用的判定 |
|---|---|---|
| xhztv.top/4k.json | HTTP 200；按项目同等 JSON 注释清洗后可解析 53 条 | **订阅可读/可解析，不标失效**；53 条不等于 53 个独立或可播放原站 |
| creamycake css1.json | 可解析 18 条规则 | 旧订阅正常解析；不把仓库更名或已有条目当新源 |
| 已安装 360 Drpy | runtime 和 ext 均 404 | 规则依赖文件失效，不归因为整个 xhztv 订阅失效 |
| 荐片 rihou.vip | LA/KR 两地 DNS 失败 | 原站域名层故障，与规则文件/订阅解析分层记录 |
| omofun111 enlienli.link | LA/KR 两地 DNS 失败 | 原站域名层故障，不外推到整个 Animeko 订阅 |
| 主线整体阶段结果 | LA 153/427、KR 247/409；关键差异正在复测 | **两组分母不同且复测中**，保留原始计数，不擅自计算可比成功率或当独立源数 |
| 其他初轮阶段信息 | 主线跑过 118 项（13 爬虫、20 正式、80 候选、5 兼容）及 64 安装规则；AniCh 阶段 KR 104、LA 68；饭团 acgpost/acgfta 仅 KR 通过 | 用户提供的历史阶段结果，不由本研究独立背书；不据此改生产设置 |
| 关键 8 源第二轮（最新主线补充） | LA 77 条通过 / KR 126 条通过；稳定增益为 AniCh、最大、百度、速博；极速搜索波动；虎牙第二轮 KR 0；xgcartoon 仅 LA 通过；无尽 KR 403 | 这些是通过线路/检查条数，不当独立原站数。虎牙初轮“KR 更佳”的观察已被此轮结果限定，不能再称稳定韩国增益 |

因此本研究只交接 C1–C3，避免重复主线既有 118 项及 64 规则探测。不使用、不读取 VPS 凭据。

### 3.2 本地代码与既有研究

- 已有 Kazumi 官方入口：Predidit/KazumiRules 的 index.json 和单规则文件；它不是新仓库。[L2]
- 既有研究引用 qist/tvbox、gaotianliuyun/gao、anaer/Meow、cluntop/tvbox、hd9211/Tvbox1、heroaku/TVboxo、liu673cn/bug、shidahuilang/shuyuan-bak、xiongjian83/TvBox；这些主要是候选目录/聚合快照，不是各自独立媒体供给方。[L1]
- server/server/scrapers/maccms_sites.py 列出 20 个配置项；TVBox 适配器另列暴风、量子、非凡、索尼、海外看，存在跨适配器重复。配置 enabled 或代码注释“可用”不是生产安装状态及当前可播证据。[L3]
- server 的 HTML 原站实现已有追剧影院、叽哔、影视森林、饭团、樱花、wedm、稀饭；另有 AGE、GiriGiri、Nivod、Dbku、Ppnix 等实现。[L3]
- 2026-08-24 MacCMS 文档已整理 80 个逻辑组及 20 条镜像/迁移线索；2026-09-13 文档已研究非凡、新浪、闪电、华为吧、卧龙、U酷、天涯等。这里不重复测活，也不重算新增。[L1]

**去重键建议**：规范化原站 host + 站点身份/迁移关系 + 内容/媒体供应关系。不要按规则名、内容类型后缀、仓库 URL、JS/JAR 文件数或 API 路径条数计独立源。不同域名只能先称新入口候选；在证明独立供给前，不承诺独立片库数量。

## 4. 当前项目的格式兼容边界（只读代码结论）

| 输入/引擎 | 已知本地能力 | 不可误判的边界 |
|---|---|---|
| Kazumi JSON | 导入器保存 XPath、apiLevel、usePost、useLegacyParser、searchMode/chapterMode、API 配置及 antiCrawlerConfig；native 解析器可做 HTML/XPath 与直链候选提取 | api=8 是规则协议级别，不是 HTTP REST API；保存字段不代表实现全部 Kazumi 宿主行为。声明 WebView/验证码的规则不可自动当纯服务端源 |
| Animeko web-selector | 识别根 mediaSources[] 或 exportedMediaSourceDataList.mediaSources[]，支持 CSS/索引/部分 JSONPath、嵌套媒体匹配；有 Android/Windows 客户端嗅探实现 | 仓库 subs/web/... 的单条 factoryId/arguments JSON **不能原样当完整订阅导入**，需纯数据包装到 mediaSources[]；客户端嗅探不等于 Linux 服务端可用 |
| Animeko RSS/BT | 导入后明确标记不能当 mp4/m3u8 在线源启用 | 不将 bt1.json/磁力/种子算在线播放增量 |
| Drpy | TVBox type=3 且 api 命中 drpy2(.min).js 的路径进入 drpy-js；本地为受限 JS/helper 实现，平台门限 Android/Windows | 不能保证任意 drpyS async/ESM/WASM、Node 模块或原生 helper 兼容；上游 drpy3 的 load2x 不是 Zeluna 已具备的能力 |
| TVBox | type=1 HTTP JSON、type=0 HTTP XML；XBPQ；部分 Android CSP | CSP 需本地审计的 JAR MD5/API 白名单且仅 Android；不是任意 JAR 都可执行。JSONC 注释/尾逗号已有清理逻辑，不能仅因有注释就说不兼容 |
| MacCMS 服务端 | 已有 provide/vod 搜索/详情及媒体筛选路径 | 内容 API 的 vod_play_url 可能仍是网页、解析器或未知资源。首页/API HTTP 200 不是 HLS/MP4 可播证据 |
| 央视 JSON | 未在扫描范围发现 cntv.cn/cctv.com 专用源 | 非 MacCMS；需小型适配，不能直接把 JSON URL 填进现有 TVBox type=1 就承诺可播 |

本地出处：[L2][L3]。本次没有运行导入测试或 UI 测试；以上为静态实现边界，不是已实测兼容性证明。

## 5. 仓库候选表：最近提交、归档、许可、真实角色

核心仓库收敛到下列 **8 项**（7 项可读、1 项 404）。可读项日期为默认分支 HEAD 的 **committedDate（UTC）**；精确 SHA/官方历史 URL 见第 10 节。许可描述只记录上游声明，不是授权法律结论。

| 原始/参考仓库 | 优先级与用途 | 最近提交 UTC | 归档 | 许可核实 | 格式、身份与限制 |
|---|---|---|---|---|---|
| [Predidit/KazumiRules](https://github.com/Predidit/KazumiRules) | P1 / 现有上游增量 | 2026-09-17T03:57:58Z | 否 | MIT | Kazumi JSON / XPath；部分专用 API 配置；原作者规则仓库；现有项目已内置入口，不是新仓库 |
| [creamycake-anime/animeko-subs](https://github.com/creamycake-anime/animeko-subs) | P2 / 旧订阅增量 | 2026-09-07T10:01:50Z | 否 | 未发现仓库级 LICENSE；不得继承客户端 AGPL | Animeko web-selector / RSS JSON；旧 ani-subs URL 跳转到此；用户已订阅，不计新增 |
| [hjdhnx/drpy3](https://github.com/hjdhnx/drpy3) | P1 取点播协议；P3 引擎适配 | 2026-09-28T13:02:07Z | 否 | MIT | ESM / async / HostEnv；load2x 为上游兼容层；原作者新引擎；不是 Zeluna drpy2 子集的即插即用替换 |
| [xyq254245/xyqonlinerule](https://github.com/xyq254245/xyqonlinerule) | P3 / 手工挑规则 | 2026-06-11T02:30:34Z | 否 | 未发现 LICENSE | TVBox JSONC、XYQHiker/CSP、旧 Drpy；原作者在线规则；依赖指定 JAR/WebView，不能当 Linux HTTP API |
| [hjdhnx/drpy-node-house](https://github.com/hjdhnx/drpy-node-house) | P3 / 排除播放源计数 | 2026-04-15T16:27:23Z | 否 | LICENSE=MIT；README=ISC，声明冲突 | Bun/Fastify 文件仓库平台；源文件托管软件，不是随仓公开的独立站全集 |
| [hjdhnx/dr_py](https://github.com/hjdhnx/dr_py) | P4 / 历史协议参考 | 2024-05-30T10:21:03Z | 是 | LGPL-3.0 | Python 服务 + JS 规则；2024-07-08 归档；不能当当前活跃源仓 |
| [magicblack/maccms10](https://github.com/magicblack/maccms10) | 格式依据，不计源 | 2026-09-18T14:28:21Z | 否 | LICENSE 自述 Apache-2.0；GitHub 显示 Other | MacCMS provide/vod JSON/XML；CMS 软件，不附带内容分发权或新增视频源 |
| [hjdhnx/drpy-node](https://github.com/hjdhnx/drpy-node) | P4 / 暂停，原上游不可确认 | 未验证：匿名页面/raw README 404 | 未验证 | 当前许可未验证 | 搜索旧索引不能证明当前状态；不替换为 fork |

### 原 Drpy 上游当前不可确认项

- https://github.com/hjdhnx/drpy-node 及对应 raw README 本轮匿名直读为 **404**。搜索仍能找到历史索引，但不能据此写成当前活跃。
- 404 不能判定是私有化、删除、迁移还是其他可见性原因；**最新提交、归档状态及当前许可均未验证**。不拿同名 fork 的时间补成原作者最新时间，不部署镜像。[S11]
- drpy-node-house 名称含“源仓库”，但实际 README/目录是注册、上传、文件列表、权限管理的仓库服务软件，不是已公开可直接导入的原站清单。LICENSE 是 MIT，而 README 尾部写 ISC，存在需要作者澄清的矛盾。[S6]

## 6. 值得主线实测的原站/规则候选

| ID / 顺序 | 原站与准确规则出处 | 新增判定 | 静态格式与最近规则提交 | 服务端可行性 / 主要风险 |
|---|---|---|---|---|
| C1 / P1 | 央视网 https://tv.cctv.com/；[drpy3 原作者点播示例](https://raw.githubusercontent.com/hjdhnx/drpy3/ecd2e23eacfb290f178f9243f18d025265564a5a/docs/%E5%A4%AE%E8%A7%86%E9%A2%91-dr3.js) | 扫描基线无域名命中，安装摘要未列；独立一手网站已确认 | 示例包含栏目/专辑/播放信息 JSON；drpy3 仓库 HEAD 2026-09-28T13:02:07Z | **推断**点播可单独适配；非现有即插即用格式。API 响应、地域限制、首段、授权未验证。明确排除直播解密/代理/路径猜测 |
| C2 / P1 | Akianime https://www.akianime.cc/；[固定规则](https://raw.githubusercontent.com/Predidit/KazumiRules/0d85fc80ab6c208548d9ee9c9e81271b08ff7f39/akianime.json) | 本地名称/host 无命中；完整安装清单仍需核对；片库独立性未知 | Kazumi API 4、XPath、useWebview=true；单文件最近提交 2026-08-17T05:00:25Z | 可先检查静态搜索/详情/播放页是否已有明确媒体地址；否则 client_probe_required，不强行当 JSON API |
| C3 / P1 | 二站动漫 https://m.ezdmw.org/；[固定规则](https://raw.githubusercontent.com/Predidit/KazumiRules/0d85fc80ab6c208548d9ee9c9e81271b08ff7f39/ezdmw.json) | 本地名称/host 无命中；完整安装清单仍需核对；片库独立性未知 | Kazumi API 8；searchMode=xpath、chapterMode=xpath、useWebview=true；单文件最近提交 2026-08-16T12:30:19Z | **不是“API 8 所以可 REST 播放”**。antiCrawlerConfig.enabled=false 也不证明无挑战；本地状态模型还按该对象非空判 needsWebView |

**上述三项统一状态：candidate / unverified；没有任何一项标记 server_verified。**

订阅补漏观察项（不进首批实测）：嘀嗒 didahd.pro（上游 tier=1）与热播 rebozj.pro（tier=4），均为已有 Animeko 订阅中的 web-selector，文件最后提交 2026-07-31T07:54:00Z 仅说明添加 channel tiers，不能等同解析刚修复。完整安装清单未去重前不将它们列作新增；tier 不等于本项目测试成绩。[S2a][S2b]

### C1：给主线的可复现点播线索

官方样本页：[《动画大放映》20260929 14:05](https://tv.cctv.com/2026/09/29/VIDEGGt5ZfmmHppswh4yavDN260929.shtml)。

- 本轮静态 HTML 实读 GUID：`f12b1c6024c64922bc3a6243cb90211b`。这是视频标识，不是认证凭据；网页路径中的 VIDE... 字符串不能直接替代 GUID。
- 栏目 API 候选（从规则取路径，仅将 n 减小为 20 做有界检查）：`https://api.cntv.cn/lanmu/columnSearch?serviceId=tvcctv&t=json&n=20&p=1`。
- 可直接交给主线验证的播放信息 URL：`https://vdn.apps.cntv.cn/api/getHttpVideoInfo.do?pid=f12b1c6024c64922bc3a6243cb90211b`。
- 原作者示例期望 `hls_url` 和 `manifest.hls_h5e_url`；这些字段来自静态规则，**没有读过此样本 API 响应**。若不返回字段、返回访问限制或需要授权，停在未验证，不补造 URL。
- 栏目/专辑详情另有 `video/videoinfoByGuid`、`NewVideo/getVideoListByColumn`、`NewVideo/getVideoListByAlbumIdNew`；参数需要真实目录 ID，不能混用页面 ID、专辑 ID、GUID。
- 原示例有去掉查询参数、替换清晰度路径、返回代理地址、直播 WASM 处理；这些是上游代码行为，**本项目不应照搬**。只验证服务器原样返回且允许访问的点播媒体地址，不扩展为代理、解密或地域绕过。
- 官方栏目页面可见动画栏目，说明有动画内容线索；并不证明热门日漫覆盖。版权和重新聚合/分发许可未核实。[S3][S4][S5]

### 暂停/排除的 API 外观候选

- 香雅情原仓的“金牌影视”规则指向 `https://m.sunnafh.com`，有 JSON 搜索/详情外观，但源码包含签名、设备标识、加密 helper 和播放解析分支。**不列入无凭据、可直接 API 化队列**；不复制/复用这些认证式常量，不请求它的接口。若后续研究，先明确作者许可、原站使用边界及是否重复媒体供应。[S7a]
- 原作者 drpy3 样例里的直播/受保护平台逻辑不纳入本轮新增公开点播评估；引擎支持 WASM 不等于本项目有权或有必要处理保护内容。[S3]
- Adult/BT、网盘登录、需 Cookie/口令、闭源 JAR、通用收费解析和纯镜像不进入默认候选队列。本轮未读取任何凭据文件或下载 JAR。

## 7. 去重、镜像与聚合壳的具体处理

| 项目 | 本轮直接证据 | 如何计数/处置 |
|---|---|---|
| aafun.json 与 moonci.json | Kazumi 固定 HEAD 中 baseURL 都是 https://www.moonci.com/；前者 2026-08-21 更新，后者 2026-08-29 新增 | 同一当前入口只计一个候选；用户旧 aafun.cc 的迁移关系需核验，不能另报新站 |
| creamycake-anime/ani-subs → animeko-subs | 旧 GitHub URL 跳到新名称，README 仍指同一个 css1.json 订阅 | 更名不是新仓库/新站；用户已安装订阅 |
| ShiroRikka/KazumiRules | isFork=true，未归档；HEAD b39840a，最近提交 2026-09-17T04:35:49Z 为合并上游；活跃 index 与上游完全相同 | 不作为新增清单；索引相同不证明所有文件字节相同，只证明未发现活跃索引增量 |
| qldwj/Kazuminb6Rules | isFork=true，未归档；HEAD 0d85fc8 与上游完全一致，最近提交 2026-09-17T03:57:58Z；index 相同 | 同提交镜像，不增加独立仓/站覆盖；MIT |
| rinnki-L/KazumiRules | isFork=true，未归档；HEAD 5fea5eb，最近提交 2026-08-29T03:54:19Z；活跃索引 16 项、无比上游多的规则 | 落后分叉而非新增上游；MIT |
| Kazumi 当前活跃索引 | 17 条规则，但 aafun/moonci 同域，故规范化 host 只有 16 个 | 根目录有更多废弃 JSON，不能按根文件数量统计可用源；规则数/host 数均不是已播数量 |
| Animeko 当前仓库静态快照 | web 目录 18 条，其中含两条不在本项目默认范围的成人条目；与用户历史安装摘要不完全相同 | 不能据此宣称用户安装异常或覆盖删除；订阅构建产物未拉取，也未证明与 HEAD 同步 |
| qist / gao / 既有 TVBox 目录 | 多种 API/爬虫/解析器混合，往往重复同一 MacCMS 主机 | 只用于寻找差异线索，必须回到原站或规则作者；聚合 URL 活性不代表其下站点可播 |
| fish2018/tvbox | README/目录描述在线配置及 JAR 私有化工具；最近提交 2025-04-15 | 软件工具，不是新增原站；不运行私有化/批量下载流程 |
| drpy-node-house / MacCMS 客户端或服务端框架 | 仓库提供托管/运行/建站软件 | 软件平台、协议、样例和真实媒体供给分别计数，不混在“源数量”里 |

相关证据：[S1][S2][S6][S7][S8][S9]；fork 的精确提交与官方历史见第 10 节。

## 8. 已知 / 推断 / 未验证与风险

### 已知

- 表内可访问仓库的 HEAD、真实 committedDate、归档/fork 状态、许可文件有无及主目录角色；不可访问 drpy-node 的字段保持未知。
- Kazumi/Ani 单站目标域名、解析器字段、镜像索引差异；央视官方样本页 GUID。
- 本地已具备哪些导入器和哪些平台/审计限制；主线给出的安装摘要。

### 推断

- 央视点播最值得先做服务器 JSON 协议检查；Akianime/ezdmw 为较高优先级番剧入口候选。
- XPath/web-selector 可能可提取静态媒体，但浏览器嗅探、验证码、时效签名或 Referer 约束可能阻断服务器路径。
- 不同规则可能最终指向同一 CDN/资源库；没有播放链路证据前，不把不同前台域名当独立片库。

### 未验证 / 必须保留的边界

- 美国/韩国 VPS 的 DNS/TLS/状态码/搜索/详情/实际媒体，以及两出口差异；本任务没有 SSH 或目标出口探测。
- HLS master → variant → 必要 key → 首媒体段，MP4 Range/文件头，播放器首帧、长播/跳转、字幕与广告。
- 站点运营主体、站间迁移/镜像关系、版权/条款及内容重分发许可。MIT 等规则许可**不授予视频内容权利**；无 LICENSE 仓库不自动视为可再分发。
- 上游 README 测试数量、规则 API 等级、tier、提交活跃、页面 HTTP 200 都不能替代本项目结果。
- 单条规则 JS/JAR 具有执行和供应链风险；固定 SHA 只固定内容，不构成安全审计。认证式常量、Cookie、签名令牌不得写进此文档、配置或探测日志。

## 9. 主线后续实施与验收（本任务未执行）

1. **先去重**：用真实 64 条记录去掉跨内容类型别名，核对 C1–C3 的 host、原始 sourceUrl、迁移别名。不重新导入 xhztv/creamycake，不重复测试嘀嗒/热播等旧订阅项。
2. **先证据后适配**：C1 只检查公开点播 JSON 链路；C2/C3 按固定 XPath 规则检查搜索/详情/剧集，不猜采集 API，不执行远程 JS；需要浏览器时记 client_probe_required。
3. **禁止直接 promotion**：分开记录 catalogue_ok、detail_ok、media_candidate、server_verified、client_probe_required、unavailable，携带出口/时间/固定规则 SHA。
4. **媒体有界验证**：保持现有公网地址/重定向检查；仅访问允许的原始媒体，HLS 验证 playlist/variant/必要 key/首段，MP4 检查 Range/文件头。拒绝 HTML 播放器冒充媒体；日志不落带签名完整 URL。
5. **适配范围最小**：本轮结果不是安装/部署授权；即使测试通过，也先提出小适配或单规则导入计划，保留用户现有设置、禁用状态、优先级、审计白名单和 SSRF 边界。
6. **达到可交付标准**：证实真实新增逻辑组、有可复现原站出处、明确引擎/平台、许可风险可交代、至少一个目标出口及媒体首段链路通过，才可进入实现评估。最终客户端首帧/长播仍应单独验收。

## 10. 证据索引（准确 URL；只用一手来源）

### 本地一手实现和既有研究

- [L1] E:/anime/docs/research/maccms-candidate-sources-2026-08-24.md；E:/anime/docs/research/independent-anime-source-mapping.md；E:/anime/docs/research/general-video-origin-candidates-2026-09-13.md；E:/anime/docs/research/anich-origin-crosswalk-2026-09-13.md。
- [L2] E:/anime/lib/src/rules/rule_importer.dart；E:/anime/lib/src/rules/rule_models.dart；E:/anime/lib/src/rules/rule_playback_resolver.dart；E:/anime/lib/src/rules/kazumi_rule_repository.dart；E:/anime/lib/src/rules/rule_plugin_repository.dart；E:/anime/lib/src/rules/animeko_webview_sniffer_io.dart；E:/anime/lib/src/rules/csp_rule_support.dart；E:/anime/lib/src/rules/drpy_runtime_io.dart。
- [L3] E:/anime/server/server/scrapers/maccms_sites.py；E:/anime/server/server/scrapers/maccms.py；E:/anime/server/server/scrapers/tvbox_adapter.py；E:/anime/server/server/scrapers/anime/html_direct.py；E:/anime/server/server/scrapers/direct_stream.py。

### 固定提交文件、原作者文档、原站

- [S1] [Kazumi 固定 index](https://raw.githubusercontent.com/Predidit/KazumiRules/0d85fc80ab6c208548d9ee9c9e81271b08ff7f39/index.json)；[MIT LICENSE](https://raw.githubusercontent.com/Predidit/KazumiRules/0d85fc80ab6c208548d9ee9c9e81271b08ff7f39/LICENSE)。
- [S1a] [akianime.json](https://raw.githubusercontent.com/Predidit/KazumiRules/0d85fc80ab6c208548d9ee9c9e81271b08ff7f39/akianime.json)；[单文件历史](https://github.com/Predidit/KazumiRules/commits/main/akianime.json)。
- [S1b] [ezdmw.json](https://raw.githubusercontent.com/Predidit/KazumiRules/0d85fc80ab6c208548d9ee9c9e81271b08ff7f39/ezdmw.json)；[单文件历史](https://github.com/Predidit/KazumiRules/commits/main/ezdmw.json)。
- [S1c] [aafun.json](https://raw.githubusercontent.com/Predidit/KazumiRules/0d85fc80ab6c208548d9ee9c9e81271b08ff7f39/aafun.json)；[moonci.json](https://raw.githubusercontent.com/Predidit/KazumiRules/0d85fc80ab6c208548d9ee9c9e81271b08ff7f39/moonci.json)。
- [S2] [Animeko 推荐来源的客户端 README](https://raw.githubusercontent.com/open-ani/animeko/d4856f7cdd682a8a1aa900cb4dddaa2f042cdd2e/README.md)；[订阅作者 README](https://raw.githubusercontent.com/creamycake-anime/animeko-subs/99498ad2dce04bf621f58ede63d73ed5ce08a108/README.md)；[固定 web 源目录](https://github.com/creamycake-anime/animeko-subs/tree/99498ad2dce04bf621f58ede63d73ed5ce08a108/subs/web)；[旧仓库地址](https://github.com/creamycake-anime/ani-subs)。
- [S2a] [嘀嗒影视单规则](https://raw.githubusercontent.com/creamycake-anime/animeko-subs/99498ad2dce04bf621f58ede63d73ed5ce08a108/subs/web/t1/%E5%98%80%E5%97%92%E5%BD%B1%E8%A7%86.json)。
- [S2b] [热播之家单规则](https://raw.githubusercontent.com/creamycake-anime/animeko-subs/99498ad2dce04bf621f58ede63d73ed5ce08a108/subs/web/t4/%E7%83%AD%E6%92%AD%E4%B9%8B%E5%AE%B6.json)。
- [S3] [drpy3 README](https://raw.githubusercontent.com/hjdhnx/drpy3/ecd2e23eacfb290f178f9243f18d025265564a5a/README.md)；[央视规则](https://raw.githubusercontent.com/hjdhnx/drpy3/ecd2e23eacfb290f178f9243f18d025265564a5a/docs/%E5%A4%AE%E8%A7%86%E9%A2%91-dr3.js)；[许可](https://github.com/hjdhnx/drpy3/blob/ecd2e23eacfb290f178f9243f18d025265564a5a/LICENSE)。
- [S4] [央视官方栏目页](https://tv.cctv.com/lm/)。
- [S5] [央视官方动画样本页](https://tv.cctv.com/2026/09/29/VIDEGGt5ZfmmHppswh4yavDN260929.shtml)。本轮仅实读该页 HTML 元数据，未跟进视频请求。
- [S6] [drpy-node-house README](https://raw.githubusercontent.com/hjdhnx/drpy-node-house/f72f6632002647cb18f060dda4a92791ce4f4122/README.md)；[其 MIT LICENSE](https://raw.githubusercontent.com/hjdhnx/drpy-node-house/f72f6632002647cb18f060dda4a92791ce4f4122/LICENSE)。
- [S7] [香雅情 README](https://raw.githubusercontent.com/xyq254245/xyqonlinerule/e72edb16454dbecc32af5f6bdd7a315a63d8792b/README.md)；[TVBox 原始配置](https://raw.githubusercontent.com/xyq254245/xyqonlinerule/e72edb16454dbecc32af5f6bdd7a315a63d8792b/XYQTVBox.json)。仅作为静态参考，不建议整仓导入/JAR 执行。
- [S7a] [金牌影视规则](https://github.com/xyq254245/xyqonlinerule/blob/e72edb16454dbecc32af5f6bdd7a315a63d8792b/dr_py/js/%E9%87%91%E7%89%8C%E5%BD%B1%E8%A7%86.js)。含认证式参数，报告不转载、不使用。
- [S8] [qist/tvbox](https://github.com/qist/tvbox)；[gaotianliuyun/gao](https://github.com/gaotianliuyun/gao)。它们只能证明目录自己的内容与维护状态，不证明目录下原站当前活性。
- [S9] [fish2018 工具仓](https://github.com/fish2018/tvbox)。
- [S10] [MacCMS 官方 API 格式说明](https://github.com/magicblack/maccms10/blob/a468b6236c1e028b1aca3f91f463345cf72f16c7/%E8%AF%B4%E6%98%8E%E6%96%87%E6%A1%A3/API%E6%8E%A5%E5%8F%A3%E8%AF%B4%E6%98%8E.txt)；[官方入库接口 Wiki](https://github.com/magicblack/maccms10/wiki/%E5%85%A5%E5%BA%93%E6%8E%A5%E5%8F%A3%E8%AF%B4%E6%98%8E)；[LICENSE](https://raw.githubusercontent.com/magicblack/maccms10/a468b6236c1e028b1aca3f91f463345cf72f16c7/LICENSE)。
- [S11] [原作者 drpy-node 地址](https://github.com/hjdhnx/drpy-node)；[原 raw README](https://raw.githubusercontent.com/hjdhnx/drpy-node/main/README.md)。本轮两者返回 404，保留失败证据而非替换为镜像。

### 仓库状态与最近提交的官方证据

- **Predidit/KazumiRules**：HEAD `0d85fc80ab6c208548d9ee9c9e81271b08ff7f39`；[精确提交](https://github.com/Predidit/KazumiRules/commit/0d85fc80ab6c208548d9ee9c9e81271b08ff7f39)；[默认分支历史](https://github.com/Predidit/KazumiRules/commits/main/)；分支 `main`，`isArchived=false`，`isFork=false`。
- **creamycake-anime/animeko-subs**：HEAD `99498ad2dce04bf621f58ede63d73ed5ce08a108`；[精确提交](https://github.com/creamycake-anime/animeko-subs/commit/99498ad2dce04bf621f58ede63d73ed5ce08a108)；[默认分支历史](https://github.com/creamycake-anime/animeko-subs/commits/main/)；分支 `main`，`isArchived=false`，`isFork=false`。
- **hjdhnx/drpy3**：HEAD `ecd2e23eacfb290f178f9243f18d025265564a5a`；[精确提交](https://github.com/hjdhnx/drpy3/commit/ecd2e23eacfb290f178f9243f18d025265564a5a)；[默认分支历史](https://github.com/hjdhnx/drpy3/commits/main/)；分支 `main`，`isArchived=false`，`isFork=false`。
- **xyq254245/xyqonlinerule**：HEAD `e72edb16454dbecc32af5f6bdd7a315a63d8792b`；[精确提交](https://github.com/xyq254245/xyqonlinerule/commit/e72edb16454dbecc32af5f6bdd7a315a63d8792b)；[默认分支历史](https://github.com/xyq254245/xyqonlinerule/commits/main/)；分支 `main`，`isArchived=false`，`isFork=false`。
- **hjdhnx/drpy-node-house**：HEAD `f72f6632002647cb18f060dda4a92791ce4f4122`；[精确提交](https://github.com/hjdhnx/drpy-node-house/commit/f72f6632002647cb18f060dda4a92791ce4f4122)；[默认分支历史](https://github.com/hjdhnx/drpy-node-house/commits/main/)；分支 `main`，`isArchived=false`，`isFork=false`。
- **hjdhnx/dr_py**：HEAD `ca23ffdbf5e429c5893ac60158668fc5af7af192`；[精确提交](https://github.com/hjdhnx/dr_py/commit/ca23ffdbf5e429c5893ac60158668fc5af7af192)；[默认分支历史](https://github.com/hjdhnx/dr_py/commits/main/)；分支 `main`，`isArchived=true`，`isFork=false`。
- **magicblack/maccms10**：HEAD `a468b6236c1e028b1aca3f91f463345cf72f16c7`；[精确提交](https://github.com/magicblack/maccms10/commit/a468b6236c1e028b1aca3f91f463345cf72f16c7)；[默认分支历史](https://github.com/magicblack/maccms10/commits/master/)；分支 `master`，`isArchived=false`，`isFork=false`。
- **hjdhnx/drpy-node**：页面及 raw README 404，HEAD、日期、归档、许可未知。[S11]

## 11. 结构化交接清单（只供主线评估，不是自动执行任务）

下面的 rule_url 是已静态读取的固定提交文件；catalog_url / play_info_url 尚未请求。JSON 仅是文档数据，不是导入配置或运行脚本。

```json
{
  "as_of": "2026-09-29",
  "scope": "8 primary repositories; 3 first-batch candidates",
  "probe_performed": false,
  "server_verified_count": 0,
  "installed_inventory_source": "user-provided summary and corrections; no local credential/state reads",
  "main_agent_results": {
    "source": "user report, not independently verified here",
    "xhztv_subscription": {
      "http_status": 200,
      "parsed_entries": 53,
      "status": "parseable_not_failed"
    },
    "creamycake_subscription": {
      "parsed_entries": 18,
      "status": "parseable"
    },
    "dependency_failures": [
      "installed 360 drpy runtime HTTP404",
      "installed 360 drpy ext HTTP404"
    ],
    "origin_failures": [
      "rihou.vip DNS failure on LA and KR",
      "enlienli.link DNS failure on LA and KR"
    ],
    "stage_counts": {
      "LA": "153/427",
      "KR": "247/409",
      "comparability": "different denominators; retests ongoing"
    },
    "key_8_sources_retest": {
      "source": "latest user report; not probed by this research",
      "LA_passed": 77,
      "KR_passed": 126,
      "stable_gain": [
        "AniCh",
        "最大",
        "百度",
        "速博"
      ],
      "unstable_search": [
        "极速"
      ],
      "KR_zero_passed": [
        "虎牙"
      ],
      "LA_only": [
        "xgcartoon"
      ],
      "KR_http_403": [
        "无尽"
      ],
      "count_semantics": "passed checks/routes as reported; not unique sites"
    }
  },
  "candidates": [
    {
      "id": "cctv-vod",
      "priority": "P1",
      "classification": "new_origin_protocol_candidate",
      "origin": "https://tv.cctv.com/",
      "format": "cntv-json-requires-adapter",
      "rule_url": "https://raw.githubusercontent.com/hjdhnx/drpy3/ecd2e23eacfb290f178f9243f18d025265564a5a/docs/%E5%A4%AE%E8%A7%86%E9%A2%91-dr3.js",
      "sample_page": "https://tv.cctv.com/2026/09/29/VIDEGGt5ZfmmHppswh4yavDN260929.shtml",
      "sample_video_guid": "f12b1c6024c64922bc3a6243cb90211b",
      "catalog_url": "https://api.cntv.cn/lanmu/columnSearch?serviceId=tvcctv&t=json&n=20&p=1",
      "play_info_url": "https://vdn.apps.cntv.cn/api/getHttpVideoInfo.do?pid=f12b1c6024c64922bc3a6243cb90211b",
      "expected_media_fields": [
        "hls_url",
        "manifest.hls_h5e_url"
      ],
      "expected_fields_basis": "upstream source only; endpoint response not fetched",
      "server_feasibility": "inferred_vod_only",
      "playback_status": "unverified",
      "constraints": [
        "public_vod_only",
        "no_live_drm_or_wasm",
        "no_proxy",
        "preserve_original_query_and_renditions",
        "respect_geo_or_access_denials"
      ]
    },
    {
      "id": "akianime",
      "priority": "P1",
      "classification": "candidate_not_in_scanned_baseline_or_user_summary",
      "origin": "https://www.akianime.cc/",
      "format": "kazumi-xpath-api4",
      "rule_url": "https://raw.githubusercontent.com/Predidit/KazumiRules/0d85fc80ab6c208548d9ee9c9e81271b08ff7f39/akianime.json",
      "search_url_template": "https://www.akianime.cc/bgmsearch/-------------.html?wd=@keyword",
      "declares_webview": true,
      "server_feasibility": "static_html_first_then_client_probe_required",
      "playback_status": "unverified",
      "installed_full_inventory_dedup": "required"
    },
    {
      "id": "ezdmw",
      "priority": "P1",
      "classification": "candidate_not_in_scanned_baseline_or_user_summary",
      "origin": "https://m.ezdmw.org/",
      "format": "kazumi-xpath-api8-not-rest-api",
      "rule_url": "https://raw.githubusercontent.com/Predidit/KazumiRules/0d85fc80ab6c208548d9ee9c9e81271b08ff7f39/ezdmw.json",
      "search_url_template": "https://m.ezdmw.org/Index/search.html?searchText=@keyword",
      "declares_webview": true,
      "server_feasibility": "static_html_first_then_client_probe_required",
      "playback_status": "unverified",
      "installed_full_inventory_dedup": "required"
    }
  ]
}
```

## 12. 本次交付检查

- 已落地本单一 Markdown 文件；没有修改源码、规则配置、安装状态或发布版本。
- 已用官方提交页面核对日期/归档，按固定 SHA 静态读取优先候选，检查结构化清单的 JSON 语法与必需字段。
- 没有远程服务器探测、没有播放测试、没有导入运行测试；本报告不沿用历史“可播”结论。
- 待主线完成：完整安装表最终去重、美国/韩国出口与媒体链路验证、内容/许可判断、是否实施适配。
