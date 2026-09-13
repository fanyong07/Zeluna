# 综合影视原站候选研究（2026-09-13）

## 0. 主线实施、验证和剩余边界（2026-09-13）

### 结果与范围

- **三类内容一起处理**：电影、电视剧和番剧均走现有原站匹配链路；不新增另一套前端目录，不变更 TMDB/Bangumi 稳定作品 ID。
- 修复电影子分类（科幻片、剧情片、动作片等）此前落入 unknown 的问题；补齐日本剧、韩国剧等剧集分类。裸题材名、纪录片、解说、预告等不强行判为电影，仍保留同名/年份/季数冲突校验。
- 爱奇艺、量子补齐 tv 查询范围；电影天堂补齐 movie 范围。三者原有 enabled/tier/quick/precache 不变，不以某一次失败永久裁剪整个板块。
- 详情合并所有播放组的真实集号，避免第一组不完整导致后续集数被隐藏；获取本集时仍精确按集号匹配，不拿另一集充数。
- 同站后续播放组获得稳定的独立线路身份，保留原站归属；第一组保持旧身份，空/HTML 播放组不会导致后续组重新编号。MacCMS 必需的 Referer/Origin 经现有过滤后透传到播放层。
- **现有正式站表仍是 20 条记录：17 个启用、3 个原隔离，全部保留。AniCh、既有 HTML 直连及稀饭增量改动均未移除。**

### 三个独立综合原站：已验证接入链路，未自动启用

已更新 `server/data/maccms_candidates.json` 中已有的非凡资源、新浪资源、U酷资源三个条目，采用本轮站方发布的当前 API；固定提交的原始发现来源、候选身份及旧域线索保留。**候选库存仍为 80 条，没有删除、用镜像凑数或虚增来源数。**

隔离测试通过真实 `ContentAggregator.discover_source_matches` → 原站详情 → 指定分集 → 播放线路身份这条链路，不经 AniCh。三类模拟端到端测试只允许对应站方 API 主机和精确路径，任何转接请求会失败。

接入过程中完整回归发现：直接把新浪加入正式表会与既有候选重复，且违反 `server/DEPLOY.md` 的来源晋级规则。已撤回这三个候选的自动注册，**保留可复用适配、当前 API 和证据**，不绕过目标出口与人工审核门。启用 `aggregate.maccms` 不会自动启用这三个候选。以下本机媒体样本不等于人工审核通过或生产上线许可。

### 真实样本与证据边界

全部为 2026-09-13 本机 Windows 出口的只读、有限检查。媒体仅在内存中读取/解码，不保存视频、播放 URL、请求头或签名参数。

| 原站 | 样本 | 本机结果 | 限制 |
| --- | --- | --- | --- |
| 非凡 | 庆余年第一季，第 1/10 集 | 46 集详情；两集均有 HLS 与首帧成功样本 | 另一个播放组失败，不是全线路通过 |
| 非凡 | 流浪地球 | 原站匹配和详情成功，至少一条首帧解码成功 | 先行媒体检查超时；不把首帧成功改写为该检查通过 |
| 非凡 | 葬送的芙莉莲，第 1 集 | HLS 与首帧成功 | 第二季另有媒体检查超时记录 |
| 新浪 | 庆余年第一季，第 1/10 集 | 46 集详情；两集均有 HLS 与首帧成功样本 | 其他组失败；存在搜索时好时坏 |
| 新浪 | 葬送的芙莉莲第二季，第 1 集 | 原站匹配成功，至少一条首帧成功 | 先行媒体检查超时；第一季样本未成功解码 |
| 新浪 | 流浪地球、流浪地球2 | 原站公开搜索/分类存在相应电影元数据 | 播放抽查中的部分搜索未命中；本轮不声明电影首帧通过 |
| U酷 | 庆余年，第 1/10 集 | 实际发现链路匹配 2019 年、46 集版本；两集首帧成功 | 第 10 集先行媒体检查超时；不是全部组成功 |
| U酷 | 流浪地球 | 实际发现、详情、HLS 和首帧均成功 | 本机样本，不是全站稳定性保证 |
| U酷 | 鬼灭之刃 锻刀村篇 | 以鬼灭之刃搜索可获得正确番剧元数据 | 当次完整标题发现未匹配，不声明实际番剧播放通过 |
| 既有 PPnix、Nivod | 流浪地球2、庆余年第一季 | 两站各两类真实匹配成功，抽样 HLS 清单/首分片通过 | 这组未验证首帧、完整播放或广告情况 |

爱奇艺、量子的真实目录中均查到庆余年第一季；电影天堂本轮出现 HTTP 403/连接异常，Dbku 也连接失败，均保留原配置。失败仅作为当前出口证据，不据此删除线路。

### 验证、复跑和验收标准

- 定向测试覆盖全部原站保留、候选不能自动启用、电影分类/身份判断、合并集数、同站分组稳定身份和媒体头透传。
- 从 `server/` 运行：`.venv/Scripts/python.exe -m pytest tests/test_general_source_catalog.py tests/test_maccms.py tests/test_probe_maccms.py tests/test_source_migration.py -q`。
- 最终工作区完整后端回归：`python -m pytest -q --tb=short`，**703 passed、151 subtests passed**，耗时 275.79 秒；1 条既有 Starlette/httpx 弃用提醒。初次候选冲突已修复，最终日志为 `full-pytest-final.log`。
- 本轮脱敏临时证据在 `.codex_tmp/general-sources-20260913/`：`new-film-tv-additional.json`、`new-movie-discovery-playback.json`、`uku-discovery-playback.json`、`ppnix-nivod-playback.json`、`existing-cross-category-inventory.json` 等。早期探针只走逐源搜索；带 discovery 的后续探针走实际发现服务。

### 剩余事项与上线要求

- 闪电、天涯三类目录有内容，但公开标题搜索明确不支持，继续保留候选，不绕限制、不全库拉取。华为吧、卧龙仍待可靠原站证据。U酷个别番剧错分类，不覆盖所有国产剧类别来硬凑命中。
- 非凡当前核验的是 HTTP 元数据 API，不传账号凭据；仍有明文被篡改风险，传输方案与内容/条款合规需人工审核。其他站也没有内容授权结论。
- 新来源需先按项目现有 smoke/promotion 流程在获准的目标出口验证，再经人工审核晋级；首次仍不得进入 quick/precache。不得改写整个 provider allowlist 或删除 AniCh 兜底。
- **未部署、未改生产配置、未在 Android 实机/模拟器验证这一轮影视源、未升版本或重新打包、未提交/推送。** 不能声称现有安装包已经具备本轮改动；也不能声称约 58 条 AniCh 线路都已独立化。

## 1. 候选调查阶段结论

确认 3 个站方公开采集 API：非凡、新浪、闪电。非凡、新浪完成电影、电视剧、番剧三类真实标题搜索；闪电完成三类分类目录查询，但搜索返回“暂不支持搜索”。华为吧、卧龙未形成当前官网到公开 API 的有效证据链，保留待验证，不猜 URL。

第一阶段共研究上述 5 个候选。该阶段只读，没有修改运行时来源、请求媒体或验证部署；后续两站补查和主线实施分别见后文与第 0 节。

## 背景、目标与边界

- 背景：Zeluna 正在推进原站独立接入，需要同时覆盖 movie、tv、anime；已有源的电影分类识别、量子／爱奇艺 tv 范围由主线处理。
- 主线代码检查：已有 17 个启用的 MacCMS 站点均直接请求各自 API、不经 AniCh。候选研究不重复这一代码检查，也不推断每个新增候选与 AniCh 内部线路的对应关系。
- 目标：找出当前来源清单之外、由站方明确发布 API 的综合原站候选，为主线提供可复验的分类与作品 ID。
- 2026-09-13 22:14（Asia/Hong_Kong）只读复查来源清单，未发现非凡、闪电、新浪、华为、卧龙条目；没有导入或执行清单模块。
- 只写本文件。不改 html_direct、maccms、测试、部署配置、版本或其他文档；不提交、不推送、不部署。
- 官网指资源站自己的公开发布页，不代表其与同名商业公司有关，也不证明内容授权情况。

## 方法与证据边界

- 按 research skill 采用一手页面与第一方 API；默认使用 You.com MCP 搜索、读取官网。检索中的第三方页面只用于发现域名，不作为 API、分类或可用性的证明。
- 已调用 web.run 搜索及官网读取；工具未返回可用正文，因此结论不依赖其空结果。
- API 核验使用无登录、无 Cookie、无授权头的只读 GET，在内存中仅提取分类和作品元数据；不保存完整响应、播放字段或签名地址。所有测试仅代表本机当次出口。
- 本阶段由有界研究代理收集证据，主线负责代码修改和播放验证；没有创建常驻后台作业。
- 研究从约 22:07 开始；官网/API 核验集中在 22:09–22:13，随后停止联网调查、整理交接。初次电影搜索出现网络异常后仅做一次复查，保留异常说明。
- 证据级别严格分开：官网发布 API ≠ 分类存在 ≠ 搜索命中 ≠ 详情可解析 ≠ 媒体可播 ≠ 生产可用。

## 1. 非凡——三类标题搜索已确认

- 官方主页：https://ffzy.tv/ 。当前主页显示电影片、连续剧、动漫片，并链接采集教程帮助中心。[F0]
- 站方公开帮助：https://ffzy.tv/help/ 。APPjson 部分原样发布以下 list/detail 接口。[F1]
- JSON list：http://api.ffzyapi.com/api.php/provide/vod/?ac=list
- JSON detail：http://api.ffzyapi.com/api.php/provide/vod/?ac=detail
- XML 综合：http://api.ffzyapi.com/api.php/provide/vod/at/xml/
- 本次实测 list 为 HTTP 200、JSON code=1；虽然 Content-Type 是 text/html;charset=utf-8，响应正文确实可解析为 JSON。详情接口仅确认站方发布，未请求详情。[F2]

| 项目类型 | 分类返回 | 实际标题搜索 | 命中作品及 ID |
| --- | --- | --- | --- |
| movie | 父类 1 电影片；子类 9 科幻片，type_pid=1 | wd=流浪地球；total=4 | 流浪地球，vod_id=1629，科幻片，HD [F3] |
| tv | 父类 2 连续剧；子类 13 国产剧，type_pid=2 | wd=庆余年；total=8 | 庆余年第二季，vod_id=66696，国产剧，已完结 [F4] |
| anime | 父类 4 动漫片；子类 30 日韩动漫，type_pid=4 | wd=鬼灭之刃；total=12 | 鬼灭之刃柱训练篇，vod_id=66596，日韩动漫，已完结 [F5] |

待验证：官网发布的是 HTTP API，本次没有擅自换成 HTTPS 或其他域名；安全传输方案仍待确认。详情结构、集数一致性、媒体可达性、目标出口、限频、内容授权和长期稳定性均未验证。电影搜索首轮网络失败，一次复查后成功，不能据此声称稳定。[F1–F5]

## 2. 新浪——三类标题搜索已确认

- 官方主页：https://xinlangzy.com/ 。主页直接链接以下采集教程。[X0]
- 官网采集教程：https://xinlangzy.com/index.php/help/index.html 。教程原样写作“josn接口”，路径也是 josn，不要自动改成 json。[X1]
- JSON 综合原样地址：https://api.xinlangapi.com/xinlangapi.php/provide/vod/josn
- 本次分类/搜索使用上述地址追加 ?ac=list；wd 参数见下方可复验引用。[X2–X5]
- 另公开 M3U8 线路采集接口：https://api.xinlangapi.com/xinlangapi.php/provide/vod/from/xlm3u8/ 。这是采集接口，不是媒体播放地址，本次未调用。[X1]
- XML 综合：https://api.xinlangapi.com/xinlangapi.php/provide/vod/at/xml/
- 本次 list 为 HTTP 200、JSON code=1；Content-Type 同样是 text/html;charset=utf-8。[X2]

| 项目类型 | 分类返回 | 实际标题搜索 | 命中作品及 ID |
| --- | --- | --- | --- |
| movie | 父类 1 电影；子类 8 科幻片，type_pid=1 | wd=流浪地球；total=5 | 流浪地球，vod_id=43851，科幻片，正片 [X3] |
| tv | 父类 2 电视剧；子类 13 大陆剧，type_pid=2 | wd=庆余年；total=8 | 庆余年 第二季，vod_id=110772，大陆剧，第36集完结 [X4] |
| anime | 父类 3 动漫；子类 39 日本动漫，type_pid=3 | wd=鬼灭之刃；total=8 | 鬼灭之刃 柱训练篇，vod_id=182695，日本动漫，第08集 [X5] |

待验证：保留 josn 原拼写并检查现有适配器能否使用这个路径；详情、线路和媒体均未验证。同一搜索结果混有预告片、纪录片、短剧，不应以搜索关键词命中替代类型匹配；动漫剧场版与连载番剧也不能只靠关键词区分。电影搜索首轮网络失败，一次复查后成功。[X3–X5]

## 3. 闪电——三类目录已确认，标题搜索未通过

- 站方帮助页明确标示官网 shandianzy.com；本次 https://shandianzy.com/ 返回 HTTP 403 / Cloudflare blocked，停止访问该入口，没有绕过防护。[S0–S1]
- 已读站方帮助：https://shandianzy.cc/help/ 。其 APP json 部分公开 list/detail；教程同时提示无法采集时需要联系管理员加白名单。本次没有联系管理员、申请白名单或进行授权操作。[S1]
- JSON list：https://xsd.sdzyapi.com/api.php/provide/vod/?ac=list
- JSON detail：https://xsd.sdzyapi.com/api.php/provide/vod/?ac=detail
- XML 综合：https://xsd.sdzyapi.com/api.php/provide/vod/at/xml/
- 无 wd 的 list 返回 HTTP 200、JSON code=1，分类含 1 电影、2 电视剧、4 动漫；class 项没有 type_pid，不可伪造父子关系。详情仅确认发布，未请求。[S2]

| 项目类型 | 实际分类查询 | 目录作品证据（不是标题搜索成功） |
| --- | --- | --- |
| movie | ac=list&t=9；科幻片；total=1135 | 都市江湖之异能者，vod_id=135856，type_id=9，更新HD [S3] |
| tv | ac=list&t=13；国产剧；total=8498 | 生逢其时，vod_id=136221，type_id=13，更新第15集 [S4] |
| anime | ac=list&t=30；日韩动漫；total=4500 | 相反的你和我 第二季，vod_id=134513，type_id=30，更新第11集 [S5] |

搜索结果：wd=庆余年 与 wd=鬼灭之刃 返回 HTTP 200，但不是 JSON；对庆余年响应作文字核验，正文明确为“暂不支持搜索”。wd=流浪地球首轮请求网络失败，没有继续扩大重试。因此只能交接为目录候选，不能声称三类标题搜索可用，也不能把该响应当作正常空列表。[S6–S7]

待验证：站方是否提供允许使用的搜索方式、搜索不支持的范围、现有接入是否依赖 wd；目录只能作为低频研究证据，不建议为了绕过不支持搜索而全量爬取。主线可自选上述作品 ID 做详情／媒体复验，结果只影响新候选状态，不能触发现有源删除。

## 4. 华为吧——当前原站与公开 API 未确认

- 当前可确认的官方主页：未确认。检索发现的历史主页线索为 https://huaweiba.live/ 与 https://huawei8.live/ ，未把第三方收录文字当成当前归属证明。
- 对 huaweiba.live 的 MCP 读取报域名解析失败；对 huawei8.live 的直接读取为 HTTP 200，但页面内容为域名停放／可能出售，不是资源站。[H1–H2]
- 站方公开 API：未确认，未构造或探测猜测路径。
- 电影／电视剧／番剧分类与真实搜索：全部未验证。
- 待验证：需要当前仍有效的站方主页及其直接发布的 API/迁移公告。域名停车或解析失败不证明整个来源永久关停，更不是删除任何旧线路的理由。

## 5. 卧龙——旧站方索引可见，当前 API 未确认

- 当前可确认的在线官方主页：未确认。You.com 命中的站方页面 wolongzy.tv / wolongzyw.com 曾显示卧龙名称及自列备用域名；这些是搜索索引证据，不是本次实时在线证明。
- 当前直接读取 https://wolongzy.tv/ 与 https://wolongzy.cc/ 均 fetch failed；https://wlzyw6.com/ 在 12 秒上限内超时。没有升级重试、关闭证书校验或绕过防护。[W1–W3]
- https://wolongzyw.com/ 的 MCP 实际页面为域名出售页，不能把旧搜索摘要当当前内容。[W4]
- 站方公开 API：未确认，未使用第三方配置中的 API 代替官网发布证据。
- 电影／电视剧／番剧公开分类及真实搜索：本次全部未验证。
- 待验证：可访问的当前原站、由站方页面发布的 API，以及三类分类和真实作品搜索。保留未知记录，不认定站方整体关停。

## 主线后续规则与验收建议

1. 非凡与新浪优先进入人工/测试候选，不因本报告直接设为生产 core、开启预爬或部署。
2. 本报告不实现类型识别修复，不重复调查已有 17 站，不调整量子／爱奇艺范围；这些由主线负责。
3. ID 必须按原站隔离，不能把不同站的同名作品或不同 ID 混用。三类类型映射应参考当站分类名称、父子关系及作品形态，不假设各站分类数字相同。
4. 未知、空搜索、网络失败、鉴权限制和媒体失败是不同状态。任何一次失败均不得删除现有来源；不得用新增候选替换整个原有来源清单。
5. 主线真实媒体验收至少分别记录 movie/tv/anime 的详情、集数、媒体与目标出口结果；本研究没有这些结果。后续日志也不能保存签名播放地址或敏感请求头。
6. 遇到验证码、认证、403 或白名单要求停止并记录；任何账号、授权、付费或部署另行确认。
7. 完成本次研究的标准是：官网发布链与元数据样本可复验、失败边界明确、只写本文件。不是要求全部候选成功，也不是生产可用凭据。

## 一手证据索引

以下均为站方页面或直连接口。失败入口仅用于标识本次尝试的对象，不提供当前官方归属或全网下线证明。分类数量与结果数量是当次快照。

- [F0] [官网主页；MCP实时读取](https://ffzy.tv/)
- [F1] [官网帮助；MCP及直接HTML核验](https://ffzy.tv/help/)
- [F2] [分类JSON](http://api.ffzyapi.com/api.php/provide/vod/?ac=list)
- [F3] [电影真实搜索](http://api.ffzyapi.com/api.php/provide/vod/?ac=list&wd=%E6%B5%81%E6%B5%AA%E5%9C%B0%E7%90%83)
- [F4] [电视剧真实搜索](http://api.ffzyapi.com/api.php/provide/vod/?ac=list&wd=%E5%BA%86%E4%BD%99%E5%B9%B4)
- [F5] [番剧真实搜索](http://api.ffzyapi.com/api.php/provide/vod/?ac=list&wd=%E9%AC%BC%E7%81%AD%E4%B9%8B%E5%88%83)
- [X0] [官网主页与帮助链接](https://xinlangzy.com/)
- [X1] [官网采集教程](https://xinlangzy.com/index.php/help/index.html)
- [X2] [分类JSON](https://api.xinlangapi.com/xinlangapi.php/provide/vod/josn?ac=list)
- [X3] [电影真实搜索](https://api.xinlangapi.com/xinlangapi.php/provide/vod/josn?ac=list&wd=%E6%B5%81%E6%B5%AA%E5%9C%B0%E7%90%83)
- [X4] [电视剧真实搜索](https://api.xinlangapi.com/xinlangapi.php/provide/vod/josn?ac=list&wd=%E5%BA%86%E4%BD%99%E5%B9%B4)
- [X5] [番剧真实搜索](https://api.xinlangapi.com/xinlangapi.php/provide/vod/josn?ac=list&wd=%E9%AC%BC%E7%81%AD%E4%B9%8B%E5%88%83)
- [S0] [HTTP 403，停止访问](https://shandianzy.com/)
- [S1] [站方帮助与API发布](https://shandianzy.cc/help/)
- [S2] [分类JSON](https://xsd.sdzyapi.com/api.php/provide/vod/?ac=list)
- [S3] [电影分类目录](https://xsd.sdzyapi.com/api.php/provide/vod/?ac=list&t=9)
- [S4] [剧集分类目录](https://xsd.sdzyapi.com/api.php/provide/vod/?ac=list&t=13)
- [S5] [番剧分类目录](https://xsd.sdzyapi.com/api.php/provide/vod/?ac=list&t=30)
- [S6] [搜索非JSON，正文暂不支持搜索](https://xsd.sdzyapi.com/api.php/provide/vod/?ac=list&wd=%E5%BA%86%E4%BD%99%E5%B9%B4)
- [S7] [搜索非JSON](https://xsd.sdzyapi.com/api.php/provide/vod/?ac=list&wd=%E9%AC%BC%E7%81%AD%E4%B9%8B%E5%88%83)
- [H1] [MCP域名解析失败](https://huaweiba.live/)
- [H2] [HTTP 200，域名停放页](https://huawei8.live/)
- [W1] [直接请求失败；搜索索引不是实时证据](https://wolongzy.tv/)
- [W2] [直接请求失败](https://wolongzy.cc/)
- [W3] [12秒超时](https://wlzyw6.com/)
- [W4] [MCP实时读取为域名出售页](https://wolongzyw.com/)


---

## 补查：U酷与天涯（2026-09-13，主线追加的有界调查）

### 范围与结论

本节是主代理追加的两站有界补查；上文“5 个候选”仅描述第一轮，本节不改写第一轮证据。补查开始于 22:21:51，联网取证结束于约 22:24:36（Asia/Hong_Kong）。只核验 U酷、天涯公开主页、站方明确发布的 API、分类和作品元数据；没有访问视频媒体、请求详情、保存播放字段或签名地址。闪电继续保留目录候选，本轮没有再次请求其 API，也没有绕搜索接口。

**U酷：当前官网公布新域 api.ukuapi88.com，三类标题搜索均成功，可交主线进一步复验。天涯：官网与公开 API 已确认，三类目录有作品，但搜索明确不支持，只保留目录候选，不按完整搜索源交付。** 两站均没有生产可用、播放成功或已部署结论。

### 6. U酷——当前官网公开 API 与三类搜索均确认

- 官方主页：https://ukuzy8.com/ 。本次 HTTP 200，标题为“u酷资源站”，主页直接链接“U酷资源帮助中心”。[U0]
- 站方帮助：https://ukuzy8.com/help/ 。MCP 实时页面及直接 HTML 均发布下列接口。[U1]
- JSON list：https://api.ukuapi88.com/api.php/provide/vod/?ac=list
- JSON detail：https://api.ukuapi88.com/api.php/provide/vod/?ac=detail
- XML 综合：https://api.ukuapi88.com/api.php/provide/vod/at/xml/
- **域名时效差异：搜索引擎中的同一帮助页摘要还显示 api.ukuapi.com；当前页面明确为 api.ukuapi88.com。采用实时站方页面的后者，未试探旧 API，也不把两者当两条独立来源。**[U1]
- 无 wd 的 list 返回 HTTP 200、JSON code=1；分类包含 1 电影、2 电视剧、4 动漫。9 科幻片的 type_pid=1，13 国产剧的 type_pid=2，4 动漫为顶层分类。[U2]

| 项目类型 | 实际搜索及当次 total | 已验证作品元数据 | 分类证据 |
| --- | --- | --- | --- |
| movie | wd=流浪地球；5 | 流浪地球；vod_id=46777；正片 | type_id=9，科幻片，归父类 1 电影 [U3] |
| tv | wd=庆余年；3 | 庆余年 第二季；vod_id=51271；全36集 | type_id=13，国产剧，归父类 2 电视剧 [U4] |
| anime | wd=鬼灭之刃；5 | 鬼灭之刃 锻刀村篇；vod_id=46693；全11集 | type_id=4，动漫 [U5] |

上述三次搜索均为 HTTP 200、JSON code=1，ID 仅在 U酷内有效。详情地址只确认公开发布，未实际请求。

重要数据质量边界：同一次番剧搜索返回的“鬼灭之刃 柱训练篇”（vod_id=51302）被站方标成 type_id=13、国产剧；“鬼灭之刃 剧场版 无限城篇 第一部”则标成 type_id=20、动漫电影。因此三类复验建议用表中锻刀村篇；不要因为这条站方错分类而把所有国产剧强制识别成番剧，也不能仅凭作品标题就忽略电影／剧集差异。[U5]

待验证：详情结构与集数、实际媒体、目标出口、稳定性与限频、公开接口的生产使用条件及内容授权均未验证。现有电影类型识别修复仍由主线负责，本次不更改分类代码。

### 7. 天涯——官网 API 和三类目录确认；标题搜索不支持

- 官方主页：https://tyyszy.com/ 。本次 HTTP 200，标题“天涯影视资源 | 海量资源永久免费”；主页本身直接公布 JSON/XML 采集地址，并链接当前帮助页。[T0]
- 当前站方帮助：https://tyyszy.com/index.php/label/help.html 。本次 HTTP 200，标题“帮助中心 - 天涯影视资源 | 永久免费”，再次明确发布下列 API。[T1]
- JSON list：https://tyyszyapi.com/api.php/provide/vod/?ac=list
- XML list：https://tyyszyapi.com/api.php/provide/vod/at/xml/?ac=list
- **旧路径陷阱：搜索索引命中 http://tyyszy2.com/help/ 时摘要仍是天涯说明，但本次 MCP 与直接 HTML 均读到“闪电资源网帮助中心”和闪电接口。未把那页当作天涯 API 证据，也未因此追加探测闪电。** 从天涯当前主页的实际帮助链接取得上述 T1 才形成正确发布链。[T0–T1、T7]
- 无 wd 的 list 为 HTTP 200、JSON code=1；class 含 1 电影、2 电视剧、4 动漫、9 科幻片、13 国产剧、30 日韩动漫，但没有 type_pid。父子关系不得伪造。[T2]

| 项目类型 | 实际分类查询及当次 total | 返回作品元数据（仅目录证据） |
| --- | --- | --- |
| movie | ac=list&t=9；1223 | 都市江湖之异能者；vod_id=69468；type_id=9，科幻片；更新HD [T3] |
| tv | ac=list&t=13；4837 | 生逢其时；vod_id=69772；type_id=13，国产剧；更新第15集 [T4] |
| anime | ac=list&t=30；859 | 相反的你和我 第二季；vod_id=68161；type_id=30，日韩动漫；更新第11集 [T5] |

三类目录请求均为 HTTP 200、JSON code=1。真实搜索尝试 wd=流浪地球、wd=庆余年、wd=鬼灭之刃 均返回 HTTP 200、非 JSON；对庆余年响应作一次文字复查，正文是“暂不支持搜索”。没有猜测新搜索路径、换域规避、全库抓取、验证码处理或鉴权操作。[T6、T8–T9]

待验证：站方是否正式提供允许使用的标题搜索方式；当前 list/detail 行为差异、媒体、使用条件、限频、稳定性与内容授权均未验证。表中 ID 可供主线按需作独立验证，但不构成完整搜索接入可用的结论。天涯与闪电显示相同错误文本不证明两者同源或可互相替代。

### 补查验收与主线交接

- 优先复验 U酷：movie=46777、tv=51271、anime=46693，全部是已搜索命中的原站 ID。
- 天涯目录样本：movie=69468、tv=69772、anime=68161；明确标记 search_unsupported，不把正文错误吞成空结果。
- 本节结果只影响新增候选的证据状态，不删除、禁用或覆盖任何现有线路，不改正在进行的非凡／新浪媒体实测或其他主线文件。
- 本次只追加同一研究文档；原文保留。所有成功均仅指当次元数据返回，不是媒体或生产凭据。

### 补查一手证据

- [U0] [U酷官网及帮助链接](https://ukuzy8.com/)
- [U1] [U酷实时官网公开 API](https://ukuzy8.com/help/)
- [U2] [U酷分类返回](https://api.ukuapi88.com/api.php/provide/vod/?ac=list)
- [U3] [U酷电影真实搜索](https://api.ukuapi88.com/api.php/provide/vod/?ac=list&wd=%E6%B5%81%E6%B5%AA%E5%9C%B0%E7%90%83)
- [U4] [U酷电视剧真实搜索](https://api.ukuapi88.com/api.php/provide/vod/?ac=list&wd=%E5%BA%86%E4%BD%99%E5%B9%B4)
- [U5] [U酷番剧真实搜索及错分类样本](https://api.ukuapi88.com/api.php/provide/vod/?ac=list&wd=%E9%AC%BC%E7%81%AD%E4%B9%8B%E5%88%83)
- [T0] [天涯主页直接发布 API](https://tyyszy.com/)
- [T1] [天涯当前采集帮助](https://tyyszy.com/index.php/label/help.html)
- [T2] [天涯分类返回](https://tyyszyapi.com/api.php/provide/vod/?ac=list)
- [T3] [天涯电影目录](https://tyyszyapi.com/api.php/provide/vod/?ac=list&t=9)
- [T4] [天涯电视剧目录](https://tyyszyapi.com/api.php/provide/vod/?ac=list&t=13)
- [T5] [天涯番剧目录](https://tyyszyapi.com/api.php/provide/vod/?ac=list&t=30)
- [T6] [天涯搜索不支持](https://tyyszyapi.com/api.php/provide/vod/?ac=list&wd=%E5%BA%86%E4%BD%99%E5%B9%B4)
- [T7] [旧帮助路径当前内容不属于天涯说明](http://tyyszy2.com/help/)
- [T8] [电影搜索非 JSON](https://tyyszyapi.com/api.php/provide/vod/?ac=list&wd=%E6%B5%81%E6%B5%AA%E5%9C%B0%E7%90%83)
- [T9] [番剧搜索非 JSON](https://tyyszyapi.com/api.php/provide/vod/?ac=list&wd=%E9%AC%BC%E7%81%AD%E4%B9%8B%E5%88%83)
