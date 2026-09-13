# AniCh 附件 ZIP 静态审计（2026-09-13）

## 1. 结论先行

**不能因为“ZIP 有 58 个站点、更全面”就整套采用。压缩包实际上是番剧取流原型：15 个不同种子站点标识、8 个有具体解析器实现的站点、默认装配 4 个站点；没有 58 条 AniCh 标签到源站的逐条映射，也没有已完成的电影／电视剧／番剧三类接入方案。**

1. “58”出现在 README 和代码注释中，指作者声称的某一集播放线路数，不是 58 个独立网站。作者还声称其中 48 条属于上传转存、公开 CDN 去重为 7 域，但 ZIP 不附对应原始样本、逐项关系或可核验的归属证据，不能作为事实照抄。证据：README.md:166-175；scraper_maccms.py:320-322。
2. SEED_SITES 有 16 个字典键值对，但 girigirilove 重复一次，静态求值后只有 15 个不同标识。REGISTRY 明文登记 6 站，另尝试注册 yhdm365，并对 yhdmone 作特殊工厂分支，共涉及 8 站；注册还存在导入顺序风险。默认流水线仅加入 yhdmone、yhdm365、girigirilove、yhdmm。证据：scraper_maccms.py:299-318、359-397；pipeline.py:409-439。
3. bf、bfx、lm、dl、xf 的独立标签，以及 player.91ju.cc、yun.92cj.com，在全部 14 个文件的静态文本扫描中均未找到。dlidli、xfvod 仅有种子/关键词/说明；dlidli 的子类仅出现在 README 示例，不是实际 Python 模块或已注册解析器。不能从 dlidli 推定 dl、从 xfvod 推定 xf，更不能认定为综合影视原站。
4. 默认元数据只查 Bangumi 动画，索引分类偏向日本/国产/欧美动漫及动漫电影；没有三类内容字段与分类 API 映射。底层通用播放列表解析可以承载类似结构的作品，但这不等于已实现真人电影和电视剧的搜索、分类、元数据及验收。证据：meta_bangumi.py:105-125；pipeline.py:158-163；site_index.py:26-32；scraper_base.py:41-67。
5. 建议只考虑复用纯解析及数据建模部分，并以现有主线实现为基础逐项适配、测试。原包请求层、验活、自动剪裁、自动换域/未知站发现不可直接合并。全程不因未知、旧注释或单次失败删除既有来源。

### 与主线信息分开

用户转交的主线结论是：附件 JSON 有 52 个源标识、1862 次出现、30 个含端口的主机字符串；这些不是 58 个独立站，且 JSON 仅有播放 Host、没有原站首页/API/类型字段。此前主线完整回归为 703 passed。

**上述数字是用户提供的主线已核实信息，本审计未重新读取或统计其 MD/JSON，也未复跑 703 项回归。ZIP 的计数与这些数字不是同一口径，不能合并。**

主线随后补充：现有 xifan/xgcartoon/girigiri/yhdmm 的 content_types 为 [anime]，movie 请求在搜索前被挡住（控制测试 0 次搜索）；bf 的 91ju 当前站方发布页名为“播剧”，未证明与历史“暴风”等价；dl 发布页为“打驴”，不是“嘀哩嘀哩”；lm 为“路漫漫”，目录以动漫/动画电影为主。这些是主线外部核验结果，ZIP 不提供这些归属证据；本审计没有重查。

**精确区分：ZIP 没有 content_types=[anime] 这种入口门禁，因此本审计不能声称 ZIP 的 movie 请求也发生了“0 次搜索”。ZIP 的实际硬编码限制在另一层：MetaClient.search 默认 anime_only=True，并追加 type=2；Pipeline.search 原样使用该默认值，本地索引也偏动漫。直接调用低层 resolve/episodes 可以处理同结构条目，但没有电影/电视剧的完整分类和元数据接入。** 证据：meta_bangumi.py:105-110；pipeline.py:158-160、187-224；site_index.py:26-32。

## 2. 输入、范围和验证边界

- 唯一附件：D:\下载\claude制作.zip；压缩文件 63,104 bytes，14 个文件，总展开大小 143,638 bytes；未发现加密条目。
- ZIP SHA-256：1028265798210d5285de151cdfe36c23d3ffb01a14dcde6ddf026d7bd172043f。
- 仅本地 ZIP 元数据、脱敏静态文本、AST 语法/结构检查。未解压落地源代码、未运行或导入 ZIP 模块、未请求官网/API/媒体、未上传或公开复制附件、未另派代理。
- 对敏感上下文先遮蔽再展示；必要时只取不含常量值的 AST 结构。未读取本机真实 Cookie 文件、账号配置或环境中的凭据值；报告不包含密钥、Cookie 值、签名播放地址或原始媒体 URL。
- 所有“已实现”仅指 ZIP 中存在相应代码路径，不代表该路径已运行或当前可用。status=ok/dead/js-gate 等为作者写死的历史标签，不是本次实测结果。
- 所有文件名/行号均指 ZIP 内原始文本的一基行号，未按脱敏文本重新排号。文档里的运行、登录、搜索、换域等指令只作为被审查资料，不构成操作授权。
- 没有读取主线报告 MD/JSON 内容，也没有读取或修改本次任务的生产/运行时代码。唯一输出是本报告。

### 全部附件清单

| ZIP 文件 | 行数 | 本次审计角色 |
| --- | ---: | --- |
| site_index.py | 175 | 分类页本地标题→sid 索引，不是网站/API清单 |
| scraper_maccms.py | 397 | 通用 HTML/API 解析、具体站类、REGISTRY 与 SEED_SITES |
| discovery.py | 263 | 搜索结果 URL→站点/sid；跨站作品索引 |
| pipeline.py | 481 | 默认装配、匹配、候选汇总、验活、剪裁和可选 AniCh 兜底 |
| scraper_base.py | 200 | 数据模型、请求层、凭据加载结构、分线选集 |
| scraper_yhdmm.py | 192 | yhdmm 独立 HTML/本地索引适配器 |
| scraper_yhdmone.py | 135 | yhdm.one HTML 搜索与单集 JSON 接口 |
| scraper_yhdm365.py | 98 | yhdm365 搜索与下划线路径适配器 |
| domain_watch.py | 293 | 同族候选域硬编码、页面特征判断和换域建议 |
| hls_clean.py | 234 | 启发式 HLS 片段剪裁与清单落盘 |
| meta_bangumi.py | 203 | Bangumi 元数据客户端 |
| README.md | 442 | 宣传、历史状态、用法和未落地示例 |
| COOKIE_SETUP.md | 68 | 凭据使用说明；敏感上下文不展示、不执行 |
| YOU_DOMAIN_WORKFLOW.md | 62 | 外部搜索注入和域名维护说明，不是实际搜索连接器 |

11 个 Python 文件均通过 AST 语法解析。这里只证明语法可解析，**不是导入通过、运行通过或测试通过**。ZIP 不含测试文件、测试样本、预建发现数据库、58 标签映射文件、anich.py、依赖锁文件或独立许可证文件；此结论依据全部 14 条归档目录清单。

## 3. 完整站点/接口/类型/实现状态清单

### 口径

- D：默认流水线装配；R：存在具体解析器/路由；S：仅种子记录；P：只有 discovery URL 模式；W：仅域名监测候选或文档。
- “番剧向”是从代码的数据入口、分类路径和搜索方式判断的实现范围，不是站方发布的经营范围。
- “电影/电视剧未实装”指没有完整的真人电影/电视剧产品链路，不能推断原站本身不提供这些内容。
- 下表的 API 均为附件代码中的硬编码请求模板或调用点。**本次没有官网一手发布核验，不能称为站方公开授权 API。** HTML 路径也不能包装成公共采集 API。

### 3.1 SEED_SITES 的全部 15 个不同标识

| 标识及硬编码主页/域名 | 实现/默认接入 | 实际请求模板与发现方式 | 代码层类型范围 | 作者静态状态与证据 |
| --- | --- | --- | --- | --- |
| yhdmm；https://www.yhdmm.com | D+R；两个实现共用同一标识 | 默认 YhdmmScraper：本地索引+HTML 搜索；/show/{sid}.html、/v/{sid}-{line}-{ep}.html。工厂 YhdmmSidScraper 另先试通用 API_DETAIL，失败退 HTML；它无列表路径、不提供搜索 | 默认索引为动漫及动漫电影；真人电影/电视剧未实装 | ok、lines=6 是硬编码；scraper_yhdmm.py:22-60；scraper_maccms.py:196-202、360；pipeline.py:432-435 |
| dmttang；https://www.dmttang.com | R，非 D | 默认 /voddetail/{sid}.html、/vodplay/{sid}-{line}-{ep}.html；继承 API_DETAIL；LIST_PATHS 为空，search 返回空，需要外部 sid/discovery | 通用解析可承载同结构条目；分类和三类覆盖未知 | ok、lines=3；scraper_maccms.py:31-45、49-54、191-193、361；pipeline.py:431 |
| yhdmone；https://yhdm.one | D+R；工厂特殊分支，不在基础 REGISTRY | /search?q={q} → /vod/{sid}.html → /vod-play/{sid}/ep{N}.html；/_get_plays/{sid}/{ep} 的 video_plays 字段解析真实存在 | 番剧向、按 epN 选集；真人电影/电视剧分类/范围未知 | ok、lines=7；scraper_yhdmone.py:23-29、60-116；scraper_maccms.py:362、389-395 |
| girigirilove；类使用 https://ani.girigirilove.com；种子使用 https://anime.girigirilove.com | D+R | /GV{sid}/、/playGV{sid}-{line}-{ep}/；LIST_PATHS=/、两条 /show/...；存在条件式在线搜索，否则本地索引；use_api=False | 番剧向；分类数字未映射，真人电影/电视剧范围未知 | ok、lines=2；同 key 在种子中出现两次；域名差异未在本次核验等价；scraper_maccms.py:253-275、363、380 |
| yhnime；https://yhnime.com | R，非 D | /v/{sid}.html、/p/{sid}-{line}-{ep}.html；/s/ribendongman.html、/s/guochandongman.html、/s/dongmandianying.html；use_api=False | 动漫与动漫电影列表已配置；真人电影/电视剧未实装 | parsed-dead、lines=1 为旧状态；scraper_maccms.py:212-226、368 |
| yinghuadh；https://www.yinghuadh.com | R，非 D | /post/{sid}.html、/play/{sid}-{line}-{ep}.html；/vodtype/1.html 到 /vodtype/4.html；use_api=False | 无 type_id→类别名称映射；不能把数字 1/2 当作电影/电视剧证据 | parsed-dead；scraper_maccms.py:229-238、369 |
| yhdm365；https://www.yhdm365.cc | D+R；外部注册有导入顺序风险 | /search/-------------/?wd={q}；/vod_{sid}.html、/play_{sid}-{line}-{ep}.html；日本/国产动漫及动漫电影列表；use_api=False | 动漫及动漫电影路径已配置；真人电影/电视剧未实装 | ok、lines=5；scraper_yhdm365.py:20-37、39-72；scraper_maccms.py:309-318、372-373 |
| yh_dongman；https://yh-dongman.com | S，未实现解析器/路由 | 仅文档描述 /video/{id}，不是可调用解析器或 API | 三类均未知 | candidate；scraper_maccms.py:374；YOU_DOMAIN_WORKFLOW.md:24 |
| iyinghua；http://www.iyinghua.com | R，非 D；HTML 解包存在缺陷 | /show/{sid}.html、/v/{sid}-{ep}.html；继承通用 API_DETAIL；无搜索列表。其 RE_PLAY 只有 4 个捕获组，但通用解析解包 5 个 | 分类未知，不能据“MacCMS”推断综合影视 | dead 为旧状态；scraper_maccms.py:107-124、205-209、375 |
| yhdmz2；https://www.yhdmz2.com | S+P+W；无解析器 | discovery 只识别 /showp/{sid}.html；未配置可用采集 API | 三类均未知 | js-gate 为历史值；scraper_maccms.py:376；discovery.py:29 |
| yhpdm；https://m.yhpdm.net | S+P+W；无解析器 | discovery 匹配 m./www. 的 /showp/{sid}.html；无 API | 三类均未知 | js-gate；scraper_maccms.py:377；discovery.py:30 |
| yinghua_us；https://www.yinghua.us | S+P+W；无解析器 | discovery 只识别 /show/{sid}.html；无 API | 三类均未知 | js-gate；scraper_maccms.py:378；discovery.py:32 |
| nanhuyt；https://nanhuyt.com | S+P+W；无解析器 | discovery 只识别 /show/{sid}.html；无 API | 三类均未知 | js-gate；scraper_maccms.py:379；discovery.py:31 |
| dlidli；https://www.dlidli.cc | S；README 有示例但 .py 中未实现/注册 | 没有实际 API。README 的 DlidliScraper 只是继承 YhdmmScraper、换 base 的示例，模板同族是推断 | 电影/电视剧/番剧范围均无代码分类证据 | unreachable 为硬编码；scraper_maccms.py:381；README.md:375-393；scraper_yhdmm.py:9 |
| xfvod；https://www.xfvod.pro | S；无解析器/工厂路由 | 没有实际 API；仅注释、状态和广告风险关键词 | 三类均未知 | unreachable；scraper_maccms.py:382；pipeline.py:133；scraper_yhdmm.py:9 |

注册细节：6 个基础 REGISTRY 项，加外部 yhdm365 和特殊工厂 yhdmone，共 8 个不同站点标识；具体站类共有 9 个，因为 yhdmm 有独立搜索版和按 sid 版。16 个种子键值对不等于 16 站，重复 girigirilove 会被后值覆盖。证据：scraper_maccms.py:299-318、359-397；scraper_yhdmm.py:22-24。

### 3.2 不在上述 15 站中的其他源站/域名记录

| 项目 | 实际位置和性质 | 是否增加可用原站 |
| --- | --- | --- |
| wmxz；wmxz.com/anime/{sid}/ | discovery.py:35 的已知 URL 正则；无 SEED_SITES 条目、解析器或工厂路由 | 否；仅第 16 个“代码曾提及的候选标识”，不代表第 16 个实装站 |
| www.girigirilove.com、girigirilove.top | domain_watch.py:61-65 的候选域；anime. 与解析器 ani. 也没有自动同步 | 否；同一人工分组内的候选域，不是新增解析器 |
| yhdm4.cn、zhdh.yhdmanime.cn | scraper_maccms.py:358；YOU_DOMAIN_WORKFLOW.md:25 的负面历史说明 | 否；没有接入配置，当前状态也未复验 |
| c1.rrcdnbf3.com、svip.xgplay4.com、svip.xgplay15.com | README.md:51-52、306；scraper_yhdm365.py:7 的示例/历史播放主机 | 否；只保留域名，不展示媒体路径，不能反推资源站/API |
| dlidli、xfvod、92cj、baofeng、ffzy、yzzy、dytt、bfllvip、xgplay 等词 | pipeline.py:132-134 的 AD_RISK_HINT 子串匹配表 | 否；这是广告剪裁触发关键词，不是来源注册、API 或标签映射 |
| mysite / example.com | README.md:383-387 的留空扩展示例 | 否；不是实际站点 |
| AniCh | pipeline.py:388-404 可选外部 anich.AniClient 依赖；ZIP 不含 anich.py 或 AniCh 基础地址 | 否；运行时依赖缺失，且默认不开启 |
| api.bgm.tv | meta_bangumi.py:26、105-176；唯一实装的元数据服务 | 不是视频源站 |
| You.com | discovery.py:183-199；YOU_DOMAIN_WORKFLOW.md:27-45 的外部 search_fn 注入约定 | 无具体 API/SDK/MCP 连接器；默认 search_fn=None，不会自动发现 |
| bilibili.com、iqiyi.com、youku.com、qq.com、mgtv.com、netflix.com、crunchyroll.com、bangumi.tv、douban.com、zhihu.com、baidu.com、wikipedia.org、dimtown.com | discovery.py:38-41 的 EXCLUDE_HOSTS | 这是排除列表，不能计入来源 |
| bangumi.github.io、github.com/yourname/yourrepo | meta_bangumi.py:13、28 的说明地址/占位 User-Agent | 不是取流来源 |

### 3.3 所有实际 API 类调用的边界

1. **通用 MacCMS 详情模板**：/api.php/provide/vod/?ac=detail&ids={sid}，定义于 scraper_maccms.py:40，在 :78-105 请求和解析。dmttang、yhdmm 的 sid 版、iyinghua 会继承启用；其他明确 use_api=False 的 HTML 站不走该路径。它不是每站经过官网确认的公开 API。
2. **没有实装通用 MacCMS API 搜索/分类适配**：search 在 :49-65 只走本地索引；README.md:356-358、402 提到的 ac=detail&wd= 是建议，不是调用实现。全包 Python 中未找到 type_id/type_pid/content_type 的三类内容映射逻辑。
3. **yhdm.one 单集 JSON**：/_get_plays/{sid}/{ep} 在 scraper_yhdmone.py:29、80-102 被实际调用，读取 video_plays、play_data、src_site；是代码级实装，不是本次官网授权证明。
4. **Bangumi**：api.bgm.tv 下 /search/subject/{keyword}、/v0/subjects/{id}、/v0/episodes；meta_bangumi.py:105-176。TMDB/TVDB 只在说明文字出现，没有对应客户端。
5. **AniCh**：只有外部客户端方法调用，未带基础地址/58 标签归属表；pipeline.py:388-404。其他 URI 为 HTML 页或由响应动态取得的媒体，不应重命名为公开采集 API。

## 4. AniCh 标签、播放 Host 与源站归属是否有证据

| 用户重点项目 | 14 文件扫描结果 | 能支持的结论 | 不能支持的结论 |
| --- | --- | --- | --- |
| bf / bfx / lm / dl / xf | 大小写不敏感、标识边界匹配均为 0 处 | 没有对应标签配置或映射项 | 不能把它们认定为 ZIP 某站，也不能认定为综合影视 |
| player.91ju.cc | 完整主机字符串 0 处 | ZIP 没有该主机的配置/说明证据 | 无法证明它的母站或 API |
| yun.92cj.com | 完整主机字符串 0 处 | 只有 92cj 词语级提及（pipeline.py:133；scraper_yhdmm.py:9） | 不能由词语反推该具体 Host 的归属/内容范围 |
| dlidli | 种子 :381、注释 :339、README :184/:375-393、广告关键词 :133、同族推断 :9 | 作者知道这个候选名字/域名 | 不证明 dl 标签、综合影视范围、接口存在或已实装 |
| xfvod | 种子 :382、注释 :339、README :184、广告关键词 :133、同族推断 :9 | 同上 | 不证明 xf 标签或综合影视范围 |
| “58 条→源站” | 仅 README.md:168-170 与 scraper_maccms.py:321-322 的文字结论 | 证明作者写过这项主张 | 不能证明逐条对应关系、48 私有上传、7 公共域或归属准确性 |

“未出现”的边界：检查了全部明文条目和 Python 字面量结构，包括 README 代码块；没有解码/执行潜在隐藏载荷，也没有查询网络。动态运行时可能返回任意标签，不等于 ZIP 已带映射。

真实数据结构是**作品标题→某站作品 sid**，而不是**AniCh 标签→原站**：SiteRef 只有 site/sid/url/title_on_site/found_at/verified，WorkEntry 保存题名与 refs；没有 anich_label、原始 Host、首页证据、官方 API 证据或内容范围字段。证据：discovery.py:44-68、145-158。ZIP 也没有随附其 .discovery_db.json 样本。

通用 API 解析把线路命名为 api-lineN，HTML 线路命名为 lineN；不会保留或映射 vod_play_from 到原始站方名称。AniCh 兜底统一 source=anich。它们是取流候选分组，不是原站归属证据。证据：scraper_maccms.py:93-103、121-124；pipeline.py:400-402。

## 5. 电影、电视剧与番剧能力：实装还是说明

| 能力 | 静态结论 | 证据 |
| --- | --- | --- |
| 番剧搜索/元数据/集号模型 | 有实现，未运行验证 | meta_bangumi.py:105-185；scraper_base.py:166-200 |
| 动漫电影目录 | 有列表路径，可产出 title/sid；不等于所有电影 | site_index.py:26-32；scraper_maccms.py:224-225；scraper_yhdm365.py:32-33 |
| 真人电影、电视剧专属元数据/分类/首页/过滤 | 未实装 | 默认 meta.search 不传 anime_only=False，因而走默认动画过滤；pipeline.py:158-160；meta_bangumi.py:105-110。无三类内容字段/映射 |
| 切换 anime_only=False | 底层参数存在，但流水线不暴露；仅去掉动画过滤，不是完成电影/剧集适配 | meta_bangumi.py:105-111；pipeline.py:158-160 |
| 通用电影播放条目 | 底层可接收 HD/正片标签、按第 1 项取候选；仅为结构能力 | scraper_base.py:51-57、166-193；scraper_maccms.py:78-105 |
| 季/年/语言/地区/影片类别消歧 | 没有完整路径；主要按标题相似度 | pipeline.py:49-60、166-185、302-334 |
| 广告剪裁、自动换线 | 有代码，但可靠性和安全存在阻塞；不能接受 README 的“等价”宣传 | pipeline.py:338-385；hls_clean.py:106-186 |
| 自动发现即自动接入新站 | 只自动写候选；没有自动产生解析器 | discovery.py:207-239；pipeline.py:249-253；scraper_maccms.py:389-397 |
| 4 站并行搜索 | README 宣传与代码不一致；代码为串行 for+同步网络 | README.md:9-11；pipeline.py:169-174；scraper_base.py:136-142 |

因此，不能以“通用 MacCMS”“有 HD 标签”“有动漫电影目录”推导它对真人电影/电视剧已全量支持。其实际原站范围需单独取得站方分类/真实作品证据；本任务禁止联网，因此所有这类站方事实保留未知。

## 6. 最关键的 5 项直接合并阻碍

以下是本次静态代码分析，不是运行测试复现；以这五项作为当前合并否决条件，不继续扩大审计。

| 项目 | 具体阻碍与影响 | ZIP 证据 / 最小处理方向 |
| --- | --- | --- |
| 1. 范围与身份没有闭环 | 无 58 标签映射；通用 API_DETAIL 是硬编码模板，不是官网确认。默认元数据搜索附加动画 type=2，索引偏动漫，缺少电影/电视剧分类路由。按此包替换现有实现不能解决三类覆盖，还可能把未知标签错认成种子站 | README.md:166-175；meta_bangumi.py:105-110；pipeline.py:158-160；site_index.py:26-32。保留主线逐标签证据；不将 dlidli→dl、xfvod→xf 当成已证实关系 |
| 2. 错误页也会被判为可播 | verify_url 识别不了 HLS/MP4 时只设 kind=unknown，仍返回 ok=True；resolve 随即把它包装成 Playable 并返回，HTTP 200 HTML/错误页可能阻断后续换线 | pipeline.py:94-101、353-367。先严格校验媒体类型并区分清单/媒体可达；这一函数不能直接复用 |
| 3. 请求与敏感信息安全边界不适合服务端合并 | 多处关闭证书/主机名校验；任意 http URL、自动重定向未见独立校验；HTML/HLS read 与解压没有体积上限。构造器会自动读取 Cookie，随后对 get 接收的地址统一附带；日志/CLI/清单落盘会包含原始 URL | scraper_base.py:26-36、79-111、118-150；pipeline.py:26-35、475-477；hls_clean.py:22-44、209-219。只接回现有受控请求层，凭据显式同源隔离，签名地址脱敏；本审计未读取真实凭据 |
| 4. “已发现/有类”不等于真正可路由 | wmxz/多个种子无解析器；未知域推导 ID 与固定工厂可能不一致。yhdm365 循环导入可能吞掉注册；Iyinghua 正则 4 捕获组却在父类解包 5 项；部分已实现路径没同步 discovery | discovery.py:25-36、98-105；pipeline.py:249-253、419-428；scraper_maccms.py:112-113、205-209、309-318、389-397；scraper_yhdm365.py:20-24。显式注册/别名及纯解析契约测试；不能把所有种子设为可用 |
| 5. 默认广告剪裁存在误删正文/破坏 HLS 状态风险 | auto_clean 默认开启；按时长和异域启发式丢弃分片；DISCONTINUITY 被消耗后未写回，KEY/MAP 等轮换状态跟随条目，剪掉条目可能一并丢失。README 的“等价云端剪裁”缺少相应测试凭据 | pipeline.py:137-145、292-298、362-379；hls_clean.py:77-79、131-179。不要整套移植；默认关闭，先验证连续性、加密/变体和保守回退 |

补充事实仅用于正确理解完整清单：SEED_SITES/USABLE_SITES 的历史状态不自动生成解析器；DomainWatch 只在自身/说明中出现，没有接入默认 pipeline；4 站搜索代码是串行循环，不能照抄 README“并行”的说法。证据：scraper_maccms.py:359-397；pipeline.py:169-174、409-439；README.md:9-11、211-230。

## 7. 值得复用的具体部分

只建议按功能提取/改写，不复制整套请求层，不做替换式迁移；是否已存在于主线由主线自行比对，本次没有重复读取运行时实现。

| 部分 | 可复用价值 | 采用前条件 |
| --- | --- | --- |
| SearchHit / EpisodeRef / PlayLine 模型思路 | 来源、作品、分组、请求头分开，利于保存多线路。scraper_base.py:41-67 | 对接现有模型；补类型/来源证据，敏感值不日志化 |
| MacCMS 播放列表拆分 | $$$ 分线路、# 分集、$ 分标签/地址。scraper_maccms.py:78-105 | 保留原始来源名，验证 schema/地址，不把每条 http 当媒体 |
| player_aaaa 解码与路径模板 | encrypt=0/1/2、base64 与 URL 编码次序；HTML 提取可独立做离线测试。scraper_maccms.py:107-187 | 覆盖嵌套 JSON、转义、签名、4/5 捕获组差异等失败样例 |
| yhdm.one / yhdm365 的专用结构解析 | 独立搜索/剧集/取流形态清楚；源响应 src_site 可保留。scraper_yhdmone.py:32-116；scraper_yhdm365.py:24-72 | 先验证原站身份和当前 schema；只借用纯解析，不照抄网络层 |
| SiteIndex._extract / _norm / search | 多个标题候选择优、sid 分组、轻量模糊查询。site_index.py:35-36、125-175 | 类型/年份隔离、增量完整性、误匹配样例；不把本地索引用于规避站方限制 |
| DiscoveryDB 的候选结构 | 作品可挂多站 sid，增量合并不强删历史。discovery.py:44-68、145-158 | 补标签/Host/归属证据/类型/置信状态；未知候选不自动激活 |
| 分线路精确选集思想 | 每路独立保留候选，避免只取第一路。scraper_base.py:166-200 | 位置回退必须显式不确定，不能误播；完善集号/番外/季映射 |
| DomainWatch 的观测字段 | 将 HTTP、页面形态、候选来源分别记录。domain_watch.py:124-161 | 仅提示人工核验，不据此自动换站、关源或删除 |

不建议直接复用：verify_url 的成功判据、关闭 TLS 的 opener、自动 Cookie 读取、启发式默认广告剪裁、按“同族”直接换 base、用坏状态自动删源的任何延伸实现。

## 8. 给主线的决策与验收条件

1. **保留现有完整来源及已通过回归的实现**，把 ZIP 当作待核验的番剧解析参考，不当作更全面的生产来源清单。
2. 58 条线路、52 个标签、播放 Host、源站、站内播放分组是不同实体。主线应按自己的 MD/JSON/运行时代码证据表逐项对照，不用本 ZIP 的种子填充未知归属。
3. bf/bfx/lm/dl/xf 与两个指定 Host 继续保持归属和三类范围未知；ZIP 没有填补这项证据缺口。
4. 若后续要用其中的解析器，逐站取得当前首页/API/分类/作品证据并明确授权范围，再适配请求层和现有模型；本次不做任何新的联网核验。
5. 合并前至少补：媒体误报、TLS/地址边界、凭据隔离、模板/导入契约、季集错配、签名日志、HLS 状态保护等离线测试。未知/失败只增加状态记录，不移除已有来源。
6. 本报告完成标准：14 文件静态检查和 11 Python AST 检查；全部种子、实际解析器、额外候选和文档示例分层；所有关键结论可定位 ZIP 文件/行号；仅新增本报告。

## 9. 待确认事项与交付记录

- 未确认：任何 ZIP 原站的当前在线/可播状态、站方官方 API 发布、版权/使用许可、是否与 AniCh 某标签具有真实对应。
- 未确认：该 ZIP 作者“58/48/7”“5站可用”“23线路”“实测通过”等历史主张；这些不是本次测试凭据。
- 未执行：附件脚本、模块导入、浏览器操作、Cookie 配置、网络请求、播放/解码、主线测试、生产部署或来源修改。
- 已验证：归档文件数/大小/SHA-256；15 种子标识及重复键；8 具体站点/4 默认装配；重点标签与完整 Host 的明文出现情况；11 Python 文件语法可解析。
- 唯一更改文件：E:\anime\docs\research\anich-provided-zip-audit-2026-09-13.md。
