# 前端 UI 文案审查

六轮审查的合并结果。**修改已完成** —— 32 个文件、795 个测试通过、`flutter analyze` 零问题。

下面的表格保留了原始审查记录（现文案 / 问题 / 建议），作为改动依据留档。实际落地时有几处偏离了建议，都在「实际改动纪要」里写明。

## 实际改动纪要

### 用管道替代逐条改写

四十多条解析器消息（`HLS 子清单`、`DASH 媒体分片`、`视频 CDN 返回 HTTP xxx`）没有逐条重写，而是把三个上屏点都接到已有的 `playbackLineFailureLabel`：

- `settings_page.dart` 的播放状态行
- `player_page.dart` 的错误横幅
- `player_panels.dart` 的线路列表

同时给净化层补了关键词：`会员`/`vip` → 需要站点会员、`地区`/`防盗链` → 来源限制访问、`没有匹配`/`没找到` → 未找到匹配。**用户能据此行动的信息不被吞掉**，其余归入通用兜底。

`_friendlyError` 和 `_shortError` 也重写了：不再插值 `error.toString()`。原来会把 Dart 自带的 `Bad state:`、`SocketException:` 前缀和 drpy 抛的英文消息原样送进中文界面。`StateError` 的 message 是写给用户的，直接透出。

### 占位符：改判断而不是改文案

`内容资料正在完善。` 原计划改成「暂无简介。」以落进 `startsWith('暂无')` 过滤。实际发现项目里已有 `isMetadataPlaceholder()`，带标点归一化且这条就在它的集合里 —— 是四处调用点没用它。改成调用它，四处一起修好。新增测试锁住这个修复。

### 假 UI 一律删，不新建功能

- **五星评分分布**：`AnimeSubject` 只有 score/rank/total，没有分布数据，接不了真实值。删掉柱状图，改显示排名
- **`_StaticFilterRail`**（类名自己就写着 static）：两块写死 chip、无 `onTap`、与真排序下拉重复 → 整个类删除
- **`_SearchRightRail`**：热搜是当前关键词 + 5 条写死词，筛选 chip 点不动 → 整个类删除。真实搜索历史有 `searchHistoryStore`，将来重建可用
- **「刚刚」**：改用 `subject.date`，没有就不显示
- **「提醒」**：改显示真实追番进度 `看到第N集`

### 引擎代号：加映射而不是删信息

`xbpq` / `drpy-js` / `animeko-web-selector` 等没有一删了之 —— 规则页是给高级用户的，规则类型有辨识价值。加了 `_ruleEngineLabel` 映射成「XBPQ 规则」「drpy 规则」「网页规则」，两个徽标点都用它。

### 「剧场版」保留并修好

原建议把 `正篇`/`剧场版`/`特别篇` 一起从类型筛选删掉。实际只删了 `正篇`/`特别篇`（Bangumi 章节类型，不可能出现在 categories 里）。`剧场版` 是有意义的类型维度，改成在 `_IndexTab` 里按 `SubjectContentType.movie` 判定，让它真正能用。

### 归类纠错

审查中我把 `csp_rule_support.dart:114` 错并进「执行器」模板组 —— 它其实是哈希审计文案。那组实际 7 处不是 8 处。另外引擎代号上屏有两处（`rule_plugin_page.dart:1038` 和 `:1909`），不是一处。

### 新发现并修掉的 bug

`rule_playback_resolver.dart:420` 用 `路` 当分隔符（`'${episode.displayTitle} 路 $lineName'`），同文件其余三处都是 ` · `。线路标题会显示成「第1集 路 樱花线路」。

### 测试

12 处断言跟着更新（都是断言了被改掉的文案）。新增 2 条占位符测试。全套 795 通过。

## 怎么读这份文件

分两部分，性质不同：

- **第一部分 · 文案问题** — 你要的那份。A 类是「不像人话」，B 类是技术术语泄漏。
- **第二部分 · 不是文案问题** — 审查途中撞见的 bug、假数据、假控件。跟措辞无关，但里面几条比任何文案问题都严重。

每条给位置、现文案、问题、建议。「建议保留」单列一节。不可达文案（写了但永远不上屏的）也单列，改不改都不影响用户。

## 覆盖情况

| 区域 | 方式 | 结果 |
|---|---|---|
| 全库 | 关键词扫描 | A 类基本无效，只抓到 B 类约 20 条 |
| 账号 / 同步 / 个人页 | 逐行，11 文件 ~9600 行 | A 3、B 33 |
| 播放器 | 逐行，19 文件 | A 5、B 19 |
| 设置 / 来源 | 逐行，10 文件 | A 2、B 10 |
| 规则 | 逐行，19 文件 5634 行分段 | A 23、B 58（11 条重叠） |
| 目录 / 首页 / 搜索 / 详情 | 逐行，13 文件 | A 24、B 15 |

方法学结论：**关键词扫描找不出 A 类**。10+ 条 A 类全部来自逐行通读 —— 抒情标语、机翻腔、内部编目用语（「待补」「待配置」）都不在任何词表里。B 类里最该改的也是那些「读着像正常中文、但概念是内部的」词：验线、已隔离、匹配不足、自定义链、按本地目录汇总。

三个 data 层大文件（`external_service_repository.dart` 1840 行、`anime_controller.dart` 2544 行、`bangumi_metadata_repository.dart` 1572 行）只做了定向核查，没逐行通读。要覆盖它们自身的文案需要单独一轮。

---

# 第一部分 · 文案问题

## 优先做这三条：改一处，修一片

### 1 · 播放状态绕过了你已有的净化层

`playback_line_display.dart:751-800` 的 `playbackLineFailureLabel` 本来就会把内部失败词映射成友好说法（`分片`→「视频加载失败」，`清单`→「线路无效」）。设计是对的。但 `settings_page.dart:1119` 和 `:1122` 绕过它，直接返回原始 `line.message`，而这个值供给用户可见的「状态」行。

于是解析器原文原样上屏：`HLS 子清单已经失效。`、`HLS 媒体分片验证超时。`、`DASH 清单没有可验证的初始化或媒体分片。`

**接上净化层，一处改动关掉约 15 条。**

### 2 · 四个状态 label 是同一个源

`rule_models.dart:51-54` 的 `需 WebView` / `需授权` / `缺配置` / `缺执行器` —— 既是内部代号又不成句。改这一处，`rule_plugin_page.dart:738`（tooltip）、`:1047`（徽标）、`:1909`（导入预览副标题）三个上屏点同时修好。

### 3 · 引擎代号铺在每张规则卡上

`rule_plugin_page.dart:1038` 的 `SmallBadge(label: rule.engine)` 把 `xbpq` / `drpy-js` / `animeko-web-selector` / `tvbox-json-api` 原样显示。这是全部审查里**出现频率最高的泄漏**。

同源的还有 `rule_playback_resolver.dart:2080` 的 `format: rule.engine` —— 它绕过 `_formatForUrl` 归一化（旁边 `:2010`、`:2056` 两处都做对了），让同一批代号漏到设置页「播放信息 · 格式」栏。两条一起改。

## 目录 / 首页 / 搜索 / 详情

`lib/src/search/`、`home/`、`detail/`、`subject/` 都不存在 —— 这些界面全在 `catalog_page.dart`（5028 行）里。

### A 类

| 位置 | 现文案 | 问题 | 建议 |
|---|---|---|---|
| `catalog_page.dart:219` `:1695` `:2450`<br>`app_chrome.dart:144` | 周期表 | 中文里「周期表」是化学元素周期表 | 新番时间表 |
| `catalog_page.dart:1237` | 弹幕已接入 | 「接入」是集成动作；同行另一分支写「未开启」，两侧不对称 | 弹幕已开启 |
| `catalog_page.dart:2872` | 热门电影与公开原片 | 「公开原片」指公有领域源，用户读不懂 | 热门电影与公版老片 |
| `catalog_page.dart:2887` | 纪录影像与公开馆藏 | 「公开馆藏」是 Internet Archive 的内部概念 | 纪录片与公版影像 |
| `catalog_page.dart:1572` | 开放影片 | 同一内部概念的第三种说法 | 公版影片，与上两条统一 |
| `catalog_page.dart:1567` `:1573` | 中文资料 | 内部编目维度（有无中文 metadata）冒充用户标签 | 删掉，或改「中文标题」 |
| `catalog_page.dart:1568` `:1574` | 免登录 | 工程属性冒充内容标签，与旁边「热门电影」不同维度 | 删掉 |
| `catalog_page.dart:1522` | 正在整理近期热门番剧与中文资料。 | 「正在整理」暗示后台有人在干活，实际是静态兜底 | 还没有可展示的番剧，稍后刷新试试。 |
| `catalog_page.dart:1524` | 正在整理热门电影与开放影片资料。 | 同上，叠加内部用语 | 暂时没有推荐电影。 |
| `catalog_page.dart:1983` | 仅交给外部 BT 客户端处理，不会伪装成内置在线播放 | 「不会伪装成」是开发者为自己实现辩解，用户看不懂在防谁 | 需要用外部 BT 客户端打开，应用内不播放 |
| `catalog_page.dart:2352` | 正在解析线路并开始下载… | 「解析线路」是内部动作叙述 | 正在准备下载… |
| `catalog_page.dart:4691` | 2020s | 中文筛选列表里混入英文年代 token | 2020 年代 |
| `catalog_page.dart:985` `:1007` | 刷新当前频道 | 这里「频道」指三个目录；`:1968` 的「直播频道」才是真频道，一页两义 | 刷新列表 |
| `catalog_page.dart:1473` | 频道（剧集/电影分支标题） | 同上，下挂的是「美剧/韩剧/剧情」分类 | 分类（与 anime 分支统一） |
| `catalog_page.dart:1496` | 特色 | 空洞标题，下挂「热门剧集/中文资料/免登录」凑不成一类 | 标签，并清掉内部维度项 |

### B 类

| 位置 | 现文案 | 问题 | 建议 |
|---|---|---|---|
| `catalog_page.dart:699` | 当前番剧**元数据**里没有匹配**条目**… | 两个纯代码概念；同 switch 的 `:700` `:701` 用「资料」，三分支口径不一 | 这里还没有匹配的番剧，换个筛选条件或稍后刷新试试。 |
| `catalog_page.dart:1768` | 暂时没有可展示**条目**… | 「条目」是 Bangumi 内部术语 | 暂时没有内容，稍后刷新或换个分类试试。 |
| `catalog_page.dart:2349` | 当前**条目**还没有可下载的集数 | 同上 | 这部作品还没有可下载的集数 |
| `catalog_page.dart:696` | …切回"全部"能看到**完整资料**。 | 指全量 metadata | …能看到所有内容。 |
| `catalog_page.dart:1932` | 这个**分区**里没有匹配结果，可以切到"全部"搜索整个**资料库**。 | 「分区」是 B 站术语（这里其实是内容类型），「资料库」是内部 metadata 库 | 这个分类里没有匹配结果，可以切到"全部"再搜一次。 |
| `catalog_page.dart:4376` `:4408` `:4441` | **资料源**还没有提供这部作品的…信息。 | 暴露上游 provider 概念 | 这部作品暂时没有角色信息。（制作人员、相关推荐同理） |
| `catalog_page.dart:1948` | 部分外部资源**源站**暂时不可用… | 运维术语 | 部分外部资源暂时打不开，已展示其余结果。 |
| `catalog_page.dart:1969` | 来自已启用的 **M3U** 源… | 格式名。设置页确实用 M3U 字样，若要统一可保留 | 来自你添加的直播源，打开后直接播放 |
| `app_chrome.dart:717` | 资料库（侧栏分组标题） | 下挂「我的/下载/历史」，是个人收藏区不是 metadata 库 | 我的内容 |

## 播放器

### 线路状态位 — 用户最常看见的位置

这六条经 `playbackLineFailureLabel` 显示在线路列表每一行右侧。都是从后端治理逻辑直接搬到界面上的机制名。

| 位置 | 现文案 | 问题 | 建议 |
|---|---|---|---|
| `playback_line_display.dart:758` | 匹配不足 | 内部标题匹配打分不够 | 不是这部作品 |
| `playback_line_display.dart:759` | 正在验线 | 「验线」不是通用中文 | 正在测试 |
| `playback_line_display.dart:761` | 暂缓请求 | 熔断器机制 + HTTP 概念 | 暂时跳过 |
| `playback_line_display.dart:763` | 已隔离 | quarantine 内部机制名 | 暂时停用 |
| `playback_line_display.dart:815` | 动态流 | HLS 无 ENDLIST 的内部判定 | 直播 |
| `playback_line_display.dart:753` | 未查询 | 请求视角 | 未检查 |

### 其余播放器条目

| 位置 | 现文案 | 问题 | 建议 |
|---|---|---|---|
| `player_panels.dart:700-703` | N 来源 · N 已查 · N 匹配 · N 可播 | B｜一行内部诊断计数器上屏，像调试面板 | 共 N 个来源，N 个可以播放 |
| `player_page.dart:1948` | **7 秒内**没有出画面，已尝试切换备用线路。 | B｜内部 soft-timeout 常量摊给用户 | 这条线路一直没有出画面，已切换到备用线路。 |
| `player_page.dart:1647` | 播放连续缓冲，正在尝试恢复当前线路。 | A｜不成句，stall 直译 | 画面一直在缓冲，正在尝试恢复这条线路。 |
| `player_page.dart:2854` | …应用内原生投屏仍取决于设备平台能力。 | B｜末句是空洞免责，读完不知道能不能用 | 已复制当前播放地址，可以粘贴到电视或投屏 App（支持 AirPlay、Chromecast 等）里播放。 |
| `player_page.dart:2888` `:2899` | 内容**命中**了**本地**屏蔽词 | B｜「命中」是匹配术语，「本地」是存储位置 | 这条弹幕包含了你设置的屏蔽词 |
| `player_page.dart:2966` | **网页播放器**暂时打不开当前线路… | B｜暴露 web/native 双播放器架构 | 这条线路在浏览器里打不开… |
| `player_page.dart:2817` | 当前**平台**或视频线路不支持截图 | B｜「平台」是 web/native 分支概念 | 这个视频暂时不能截图 |
| `player_panels.dart:342`<br>`player_mobile_layout.dart:440` | 播出日期**待补** | A｜内部编目用语 | 播出日期未知 |
| `player_panels.dart:200` | …检查**相关扩展**是否已开启。 | A｜无指向的填充词 | …或到「扩展来源」确认直播源已开启。 |
| `player_panels.dart:889` | **待配置** | B｜运维用语，出现在弹幕来源状态位 | 未启用 |
| `player_panels.dart:1307` `:1308` | 没有**返回**播放地址 | B｜接口视角 | 没有可播放的地址 |
| `player_panels.dart:453` | 选择设备中的 MP4、MKV、WebM、**HLS** 或 **DASH** 文件… | B｜协议名，且二者不是「文件」 | 选择设备里的视频文件，文件不会上传。 |
| `player_panels.dart:232` | 已查询 N 个在线来源，但没有**返回**可播放地址…可能使用了不同**译名** | B｜接口视角 +「译名」是内部标题匹配用词 | 已经找过 N 个在线来源，都没有找到能播的地址。这部作品可能在这些来源里用了别的名字。 |
| `open_media_page.dart:61` | 例如：**测试视频** / 第 1 集 | A｜开发自测占位口吻 | 例如：第 1 集 |
| `open_media_page.dart:54` | 支持**播放器可识别的** MP4…HLS 和 DASH **地址** | B｜开发者口吻 | 支持 MP4、WebM、MKV 等视频文件，以及 m3u8、mpd 直播地址 |
| `subtitle_controller.dart:43` | **该**字幕暂不可用 | A｜机翻腔（该文件目前未接入界面） | 这条字幕暂时不能用 |

## 账号 / 同步 / 个人页

### 三条性质最不该留的

| 位置 | 现文案 | 问题 |
|---|---|---|
| `profile_page.dart:1665` | 当前 **AniCh** 风格以暗色观影环境为主 | 代号错误。你的应用叫 Zeluna（隔壁 `account_page.dart:1129` 就写着「导出 Zeluna 账号数据」），AniCh 是逆向那个项目时串进来的。两轮审查独立发现同一条 |
| `profile_page.dart:1582` | **推荐模块接入后**可清除已学习的兴趣与展示记录 | 暴露未实现的开发排期 |
| `profile_page.dart:1657` | **后续接浅色主题时**会优先使用系统设置 | 同上 |

建议：第一条改「深色界面更适合长时间观影」，后两条一个改「暂不可用」、一个改「跟随系统的深色/浅色设置」。

### 账号错误消息簇

这批全部经 `account_page.dart:1184`（`_error = error.message`）显示在页面顶部。共同毛病是把 HTTP/JSON 层的失败原因原样译成中文。

| 位置 | 现文案 | 建议 |
|---|---|---|
| `cloud_account_repository.dart:604` | 账号服务器返回了空数据 | 账号服务暂时无法使用，请稍后重试 |
| `cloud_account_repository.dart:611` `:744` | 账号服务器返回了无法识别的数据 | 同上 |
| `cloud_account_repository.dart:713` `:1020` | 账号服务返回的数据过大，已停止读取 | 数据读取失败，请稍后重试 |
| `cloud_account_repository.dart:733` | 账号服务器未通过安全连接检查 | 网络连接不安全，请检查网络后重试 |
| `cloud_account_repository.dart:780` `:786` | 服务器没有返回账号信息 / 返回的账号信息不完整 | 账号信息读取失败，请稍后重试 |
| `cloud_account_repository.dart:556` `:569` | 服务器没有返回登录状态，请重试 | 登录没有完成，请重试 |
| `cloud_account_repository.dart:579` | 服务器没有返回**可续期的**登录状态 | 登录没有完成，请重试 |
| `cloud_account_repository.dart:561` | 无法安全保存登录状态，请检查**系统凭据存储** | **这条最糟** — 让用户去「检查」一个他根本找不到的东西 → 登录信息保存失败，请重启应用后重试 |
| `cloud_account_repository.dart:446` | 服务器返回的账号数据导出格式无效 | 账号数据导出失败，请稍后重试 |
| `cloud_account_repository.dart:468` | 服务器返回的账号删除时间无效 | 删除申请没有提交成功，请稍后重试 |
| `cloud_account_repository.dart:893` | 服务器返回的弹幕格式无效 | 弹幕加载失败，请稍后重试 |
| `cloud_account_repository.dart:542` | **弹幕编号**无效，无法删除 | 界面上不存在编号 → 这条弹幕已经不存在了 |
| `local_account_repository.dart:317` `:327` | **待完成的账号与当前操作不一致** | 内部断言直接抛给用户 → 账号创建没有完成，请重新创建 |
| `local_account_repository.dart:464` | 待清理账号与当前操作不一致 | 清理没有完成，请稍后重试 |
| `local_account_repository.dart:314` | 待完成的账号已不存在 | 账号创建流程已中断，请重新创建 |
| `local_account_repository.dart:201` `:308` `:330` | 账号**初始化**尚未完成 | 账号还没创建完成，请重试 |
| `local_account_repository.dart:213` | 无法保存**非云端账号** | 用户视角不存在这个概念 → 账号保存失败，请重新登录 |
| `local_account_repository.dart:198` | 云端账号信息不完整 | 账号信息读取失败，请重新登录 |
| `account_controller.dart:261` | 账号**初始化**失败 | 账号创建没有完成，请重试 |
| `account_controller.dart:596` | **应用状态尚未准备好** | 内部就绪检查措辞 → 应用还在启动，请稍后再试 |

### 其余

| 位置 | 现文案 | 问题 | 建议 |
|---|---|---|---|
| `profile_page.dart:170` | 在浩瀚的星海之中，总有一束光是为你而亮。 | A｜抒情标语，横幅上零信息 | 删掉，或换「已追 N 部 · 最近看到「X」」 |
| `account_page.dart:1237` | 已**安全**同步 | A｜「安全」是安抚性填充 | 已同步 |
| `account_page.dart:444` | 会**安全迁移**进新账号 | A｜「安全」填充 +「迁移」开发用语 | 创建账号后，你现在的收藏、追番、历史和下载会转入新账号 |
| `account_page.dart:1424` | …不会上传 **Cookie**、**私密 Header**、**API Key** 和**临时播放地址** | B｜六处术语堆叠 + 「安全同步」空心修饰 | 下载的视频和你自己填写的来源账号信息只留在本机，不会上传。 |
| `account_page.dart:178` | 登录状态保存在**系统安全凭据**中 | B｜OS keychain 直译 | …保存在系统的加密存储里 |
| `profile_page.dart:869` `:877` `:892` `:893` | **未关联** / 清理未关联 / **本地缓存项** / **旧版迁移文件** | B｜orphaned path 直译 + 实现术语 | 可清理 N 个残留文件 / 清理残留文件 / 将删除 N 个不属于任何下载任务的视频文件 |
| `profile_page.dart:684` | 暂无**离线缓存**任务 | B｜同页标题是「下载管理」，术语不一致 | 还没有下载任务 |
| `profile_page.dart:1141` | …会先**写入本机**…**私密来源配置**始终留在本机 | B｜存储层说法 | …会先保存在这台设备…自建来源的账号信息只留在本机 |
| `profile_page.dart:1782` | 已**连接系统唤醒锁** | B｜wake lock API 名 + 实现状态 | 播放期间屏幕不会自动息屏 |
| `profile_page.dart:1790` | 支持常见视频文件与**未加密点播流** | B｜DRM/VOD 实现细节 | 支持常见格式的视频下载 |
| `profile_page.dart:1834` | 在线播放 / **网络直链** / 本地文件 | B｜直链是内部说法 | 在线播放 / 网络视频 / 本地文件 |
| `profile_page.dart:2424` | N/N **分片** | B｜HLS segment；下载列表里用户只关心进度 | 改百分比或只显示体积 |
| `local_identity_migration.dart:414` | 从旧版下载记录**迁移** | B｜开发用语，会显示在下载列表 | 旧版本的下载 |

## 设置 / 来源

| 位置 | 现文案 | 问题 | 建议 |
|---|---|---|---|
| `anime4k_shader_manager.dart:251` | `${tier.label}·自定义**链**` | B｜shader chain 直译；且这里 `·` 无空格，另一分支用 ` · ` 有空格 | `${tier.label} · 自定义组合` |
| `settings_page.dart:1122` | **未返回**播放地址 | B｜服务端响应视角 | 这条线路没有可播放的地址 |
| `settings_page.dart:1430` | 不会发送云账号 **Token**、**Cookie** 或 **Authorization** | B｜末句变成 HTTP 请求头清单 | 不会向它发送你的云账号登录凭据。（前两句准确，保留） |
| `settings_page.dart:1459` | 匹配当前集 **cid**，再读取公开弹幕 **XML** | B｜B 站内部字段名 + 传输格式 | 匹配到对应分集，再读取该集的公开弹幕。 |
| `settings_page.dart:414` | 调整播放器的额外音量**增益** | B｜音频工程术语；同卡片标题写「音量增强」 | 放大播放器的最大音量 |
| `settings_page.dart:1263` | 这个**入口**暂时没有对应配置。 | A｜内部路由词 | 这个页面暂时没有可调整的设置。 |
| `settings_page.dart:1460` | 自建弹幕库**仍保留**为**用户自己的**接口补充。 | A｜开发者视角对用户称第三人称 | 你也可以填自己的弹幕接口，作为补充来源。 |
| `source_management_page.dart:434` | TVBox **JSON**/**XBPQ** **可解析项**会自动加入播放**查源** | B｜一句叠三层实现细节 | 能识别的 TVBox 站点会自动用于查找播放地址 |
| `source_management_page.dart:563` | 生成 **sources_catalog.json** 后… | B｜打包资产文件名，用户无从「生成」 | 导入外部源之后，这里会列出可管理的资源。 |
| `source_management_page.dart:396` | 按本地**目录**汇总 | B｜这里 catalog 指源清单，中文会被读成文件系统目录 | 按已导入的源统计 |
| `source_management_page.dart:314` | **接入** N 条规则 | B｜集成动作 | 已启用 N 条规则 |
| `source_rule_bridge.dart:172` | 由自动**规则包**"…"**接入播放查源** | B｜会显示在规则备注里 | 来自"…"，可用于查找播放地址 |
| `csp_rule_support.dart:114` | …未通过当前版本的**固定哈希审计**。 | B｜全库最重一条，高级用户都读不懂 | 规则已保留，但它依赖的组件未通过安全校验。 |
| `csp_rule_support.dart:118` | 固定 CSP 包中没有可安全加载的 `$api` 类。 | B｜裸类名插值进 UI | 规则已保留，但缺少可用的解析组件。 |
| `rule_models.dart:51` | 需 **WebView** | B｜位于高级规则页，见「优先三条」第 2 项 | 需手动验证 |

## 下载

这批经 `MediaDownloadResult.message` → `task.message` → `profile_page.dart:982` 显示为下载列表副标题。

| 位置 | 现文案 | 建议 |
|---|---|---|
| `media_download_hls_io.dart:692` | 暂不支持 **AES-128** 加密 **HLS** 离线缓存 | 该线路已加密，暂不支持离线下载 |
| `media_download_hls_io.dart:695` | 暂不支持 **SAMPLE-AES/DRM HLS** 离线缓存 | 该线路受版权保护，无法离线下载 |
| `media_download_hls_io.dart:814` | 分片服务器不支持 **EXT-X-BYTERANGE** 范围请求 | 该线路不支持断点续传 |
| `media_download_hls_io.dart:681` | 检测到直播或未结束的 **HLS 清单**… | 直播内容无法离线下载 |
| `media_download_hls_io.dart:683` | **HLS 清单**没有可下载**分片** | 该线路无法离线下载 |
| `media_download_hls_io.dart:519` | **HLS 清单超过 2 MB**，已停止处理 | 内部阈值上屏 → 该线路数据异常，已停止下载 |
| `media_download_hls_io.dart:502` | 清单请求返回 **HTTP {code}** | 裸状态码 → 无法连接该线路，可稍后重试 |
| `media_download_hls_io.dart` 7 处 | `HLS 分片…` 七条近似文案 | 用户既区分不了也处置不了 → 合并成一到两条，如「下载中断，可稍后继续」 |
| `media_download_service_io.dart:261` `:47`<br>`download_controller.dart:646` | 该线路返回了 **HLS/DASH 清单** / **DASH 分片**线路 | 统一为「该线路不支持离线下载」 |

## 元数据占位

| 位置 | 现文案 | 问题 | 建议 |
|---|---|---|---|
| `bangumi_metadata_repository.dart:1492` | ${title} 第 N 集资料，播放线路**后续从你自己的源接口接入**。 | A+B｜开发者口吻 + 暴露内部接线。经 `player_panels.dart:348-350` 和 `player_mobile_layout.dart:536` 上屏 | 暂无本集简介。 |
| `bangumi_metadata_repository.dart:1504` `:1511` | 角色资料待 **Bangumi** 返回。 | B｜点名上游数据源。**但已确认不可达** — `_PersonTile` 只渲染 name/relation/cv | 不改也行；若将来渲染 summary 则改「角色资料加载中」 |

## 建议保留

这些词虽然专业，但在其上下文里必要且准确。多轮审查独立给出同样判断。

| 位置 | 文案 | 理由 |
|---|---|---|
| `settings_page.dart:429` | 使用 **Anime4K** 实时增强画面清晰度 | Anime4K 是动画超分领域的公认名称，用户往往主动按名寻找。写明比含糊的「超分算法」更诚实 |
| `settings_page.dart:1791`<br>`anime4k_shader_manager.dart:19`<br>`anime4k_controller.dart:201` | 高级**着色器** / 手动组合 Anime4K 着色器 / 高级超分至少需要选择一个着色器 | 只在「画质档位＝高级」时出现，此时用户正在手动挑选具体着色器文件，术语与操作对象一致 |
| `account_page.dart:1424` 前半 | 提到 Cookie / 私密 Header / API Key 的安全披露 | 说清「什么会上传、什么不会」比可读性更重要 |
| `account_page.dart:218` | 保存为 **JSON** | 导出文件是给用户带走自行处理的，格式名有实际用处 |
| `catalog_page.dart:1982` `:2138` `:2167` | BT / 磁力资源 / 磁力链接已复制 | 中文用户的通行说法，比任何改写都准确 |
| `catalog_page.dart:2140` | BT 下载会向**对等网络**暴露你的**公网 IP**… | 安全提示需要精确，此处是必要信息 |
| `catalog_page.dart:3858` | 立即播放 / 查找**线路** | 「线路」是国内视频应用长期沿用的用户词汇，且与项目已统一的术语一致 |
| `catalog_page.dart:1583` | 电影**索引** / 索引（Tab） | 「番剧索引」是 B 站等站点既有用法 |
| `player_panels.dart:229` | 请检查网络或**代理**后重试。 | 「代理」对本应用用户是有效可执行的提示 |
| `playback_line_display.dart:668-687` | 晨风 / 疏影 等别名池 | **反向的好做法** — 刻意用友好名替换 `xfdmneo` 这类内部规则 id。其余地方该学这个模式 |
| 通用 | 线路 / 倍速 / 硬件解码 / 弹幕源 / 请求头 | 准确且必要 |

## 不可达文案

写了但永远不上屏。改不改都不影响用户，但如果将来把这些字段接进界面，需要整体重写。

| 位置 | 判定依据 |
|---|---|
| `external_source_adapters.dart` 整批（`M3U 中没有可用的 HTTP/HTTPS 频道` 等） | `SourceAdapterFailure.message` 全程未被渲染；`catalog_page.dart:1942` 只读 `hasFailures` 布尔值并显示固定文案 |
| `catalog_page.dart:4646-4655` | `_fallbackHeroSubject` 的唯一消费点是 `:3369` 的 `subjects.isEmpty` 分支，而 `_heroSubjects` 恒以 `feed.hero` 打头，永不为空 |
| `catalog_controller.dart:944` `:950` | `AccountException` 抛出后，`catalog_page.dart` 全文无 `catch`/`error.message` 渲染 |
| `bangumi_metadata_repository.dart:1504` `:1511` | `_PersonTile` 只渲染 name/relation/cv，`summary` 无渲染点 |
| `bangumi_credential_store.dart:121` | `saveToken` 在 `lib/` 下无生产调用方 |
| 规则页约 30 条 | kazumi 全文 7、hydrator 约 20、桥接 note 2、tags 若干 |

### 两处「离上屏只差一步」

现在不可达，但离显形只差一个条件：

- `tvbox_xbpq_hydrator.dart:274` 和 `source_rule_bridge.dart:172` 写进 catalog 桥接规则 `note` 的两句，含「规则包、XBPQ、JSON、查源」。当前 `_ruleDisplayNote` 只读 `installedRules` + `customRules`，catalog 规则只贡献计数 —— 一旦 catalog 规则进入已安装列表就会显形。
- `rule.tags` 里的 `'CSS'` / `'drpy-js'` / `'XBPQ'` / `'暂不支持'`，全仓只被 resolver 用于 `contains('4K')` 判定，规则页从不渲染 tags。

---

# 第二部分 · 不是文案问题

审查途中撞见的。跟措辞无关，但有几条比任何文案问题都严重 —— 它们向用户展示了错误信息或不存在的功能。

## 假数据

| 位置 | 问题 |
|---|---|
| `catalog_page.dart:4043-4067` | 五星分布进度条用**写死比例**伪造评分分布：`i == 5 ? 0.76 : (6 - i) * 0.05`。而 `:4035` 在 `ratingTotal` 为空时显示「0人评分」却仍把条形画满 |
| `catalog_page.dart:2523` | 「最近更新」每一行的时间**写死「刚刚」**，不管条目实际时间 |
| `catalog_page.dart:4736` | 标题写「热门搜索」，内容是当前关键词 + 5 条写死词（`:4743-4747`） |

## 假控件

| 位置 | 问题 |
|---|---|
| `catalog_page.dart:4679` `:4702` `:4758` | 右栏「类型筛选」「排序」两块面板的 chip 全是 `SmallBadge`（无 `onTap`），**点不动**。而 `综合/评分/更新/热度` 与 `:1017` 的真排序控件重复 |
| `catalog_page.dart:4936` | 「我的追番」每行右侧的「提醒」是静态文字，不可点、无提醒能力 |
| `catalog_page.dart:3675` | 类型筛选里的「正篇」「特别篇」是 Bangumi 的**章节类型**不是内容类型，而 `_IndexTab` 用 `categories.name` 精确比对 —— 这两项**永远筛不出东西** |

## 显示错误

| 位置 | 问题 |
|---|---|
| `catalog_page.dart:4079` | 「已连到第 N 集」取 `episodes.first.number`（**第一集**）而非最新集，**数字本身是错的**。应取 `episodes.last.number` |
| `catalog_page.dart:3836` | 「在线可播」的 `backendManaged` 条件是 `source == 'bangumi'` 或 `tmdb:` 前缀 —— 那恰恰是纯元数据源、**不能播**。把不可播标成了可播 |
| `catalog_page.dart:3236` | `_SubjectGrid` 用 `_publicMetadataValue(subject.status)` 绕过 `:152` 的 `_publicStatusLabel` 归一化。后端 `zeluna_backend_catalog_repository.dart:210` 直接透传上游 `status`，于是海报角标印出 `releasing` / `Returning Series` 等**英文原值**，而 hero 与详情页同一字段是中文。改为 `_publicSubjectMetadata(context, subject).status` |
| `catalog_page.dart:3553` `:3845` | platform badge 的英文 token 原样上屏（`Scripted` / `Movie` / `TV`）。`anime_controller.dart:2191` 等 14 处兜底剧集写死 `platform: 'Scripted'`，`external_service_repository.dart:1076/1418/1476/1588` 产出 `Series`/`Movie`。结果 hero 徽标显示 `Movie`，同一行 metadata（`:3513`）却写「电影」。需在 `_publicMetadataValue` 前加 platform 白名单映射 |
| `app_chrome.dart:1276` | 搜索框写「搜索番剧、剧集、电影、**演员**」，但后端 `zeluna_backend_catalog_repository.dart:33-41` 只传 `content_type: 'anime,tv,movie'`，客户端 `search_ranking.dart:37-43` 只打 `title`/`originalTitle` 分，搜索页也没有人物结果区 —— **搜演员必然空结果**。承诺了不存在的功能 |
| `catalog_page.dart:3062` | 快捷入口标签写「追番」，`onTap` 跳 `/schedule`（时间表），标签与去向不符 |

## 永久性的假状态

| 位置 | 问题 |
|---|---|
| `catalog_page.dart:1523` | 「正在整理电视剧、连续剧和网剧资料。」—— 剧集/电影的 `_railSubjects` 恒返回 `const []`（`:1604-1605`），所以这条**永久显示**，「正在整理」是长期假状态 |

## 占位符绕过过滤

| 位置 | 问题 |
|---|---|
| `catalog_page.dart:62` `:77` | 「内容资料正在完善。」—— `:3525`/`:3828`/`:4229` 三处占位符过滤只判断 `startsWith('暂无')`，这条正好绕过，于是首页 hero、详情 hero、简介 Tab 都把它当**真简介**正文展示。改成「暂无简介。」就自动落进既有过滤，走空状态 |

## 数据流缺陷（规则层）

| 位置 | 问题 |
|---|---|
| `rule_playback_resolver.dart:2080` | `format: rule.engine` 绕过 `_formatForUrl` 归一化，而旁边 `:2010`、`:2056` 两处都做对了。引擎代号因此上屏 |
| `rule_playback_resolver.dart:5506` `:5508` | `_friendlyError` 兜底 `'规则源请求失败：$text'` 和 `'解析失败：$text'`，原始异常文本上屏 |
| `rule_playback_resolver.dart:5592` | `_shortError` 兜底把原始异常截 60 字后上屏 |
| `drpy_runtime_io.dart:37` `:59` `:68` `:90` | 抛的是**英文**（`drpy HTTP proxies are disabled.`、`drpy public host has no usable address.`），走到上面两个兜底就以英文原样显示给中文用户 |

---

# 规则页

明细在单独的文件：**[ui-copy-audit-rules.md](ui-copy-audit-rules.md)** —— 109 条上屏条目（A 类 21、B 类 88，16 条兼具），按 6 个文件分组，另有「建议保留」8 条、「不可达」约 75 条。19 个文件全部读完，`rule_playback_resolver.dart` 分 8 段读完。

前两次审查的明细都没能传回来（第一次 API 中断，第二次只回统计尾部）。第三次改成让它把表格写进文件、返回只给一句统计，才拿到。

不可达那 75 条里有几块值得单独记：`legacyCuratedRuleDefinitions` 整块死代码约 30 条、`tvbox_xbpq_hydrator.dart` 27 条 message 无消费方、`kazumi_rule_repository.dart` 7 条仅测试可达。

## 我先前归类错的两处（已核实）

- **`csp_rule_support.dart:114` 不属于「执行器」模板** —— 它是哈希审计文案，跟「需要接入 XX 执行器」是两回事。那组实际是 7 处：`rule_importer.dart:279`、`rule_playback_resolver.dart:319`、`rule_plugin_page.dart:1248`、`rule_plugin_repository.dart` 四处（827/846/914/933，其中三条文字完全相同）
- **引擎代号上屏还有一处** `rule_plugin_page.dart:1909`，独立于已收录的 `:1038`

## 已到手并写入上文的条目：

- 「优先三条」的第 2、3 项（`rule_models.dart:51-54` 四个状态 label、`rule_plugin_page.dart:1038` 引擎代号徽标）
- 「需要接入 XX 执行器后才能解析」7 处（见上，我先前误记为 8 处并错并了一条哈希审计文案）。这组一句话犯三样 —— 插值引擎代号、用「执行器」暴露内部机制、直接告诉用户功能没做完。建议统一收敛成「这类来源暂时不支持。」，具体原因留日志
- 第二部分的 4 条数据流缺陷（已逐条核实）
- 两处「离上屏只差一步」的隐患

## 补充报告里另外发现的一个 bug

`rule_playback_resolver.dart:420` 的线路标题用了 `路` 当分隔符：

```dart
title: '${episode.displayTitle} 路 $lineName',
```

同文件其余四处（`:793`、`:906`、`:1313`）都是 `·`。看着像 `·` 被误替换成了「路」字，线路标题会显示成「第1集 路 樱花线路」。已核实。

## 关于那次「伪造指令」

第一轮那个 agent 报告说读 `rule_playback_resolver.dart` 时遇到「文件里嵌着伪造指令，要求报告零发现」。我核实过：真实文件里没有那段文字，`git diff` 对该文件为空，没有 `<!--`，没有那些指令词。是它单侧的读取结果损坏。

它拒绝执行那段伪指令是对的（文件内容属不可信数据），但它据此描述的文件内容不可采信。第二、三轮分段重读，均确认内容自洽、无异常。

---

# 汇总

| | A 类 | B 类 | 建议保留 | 不可达 |
|---|---:|---:|---:|---:|
| 账号 / 同步 / 个人页 | 3 | 33 | 2 | 2 |
| 播放器 | 5 | 19 | 5 | — |
| 设置 / 来源 | 2 | 10 | 4 | — |
| 规则（明细见 [ui-copy-audit-rules.md](ui-copy-audit-rules.md)） | 21 | 88 | 8 | ~75 |
| 目录 / 首页 / 搜索 / 详情 | 24 | 15 | 4 | 4 |
| **合计** | **55** | **165** | **23** | **~81** |

规则页 109 条里有 16 条兼具 A/B，所以该行两列相加大于条目数。

第二部分另有 **18 条** bug / 假数据 / 数据流缺陷（含规则页那条 `路` 分隔符）。

## 建议的动手顺序

1. **播放状态接净化层** — 一处改动关掉约 15 条
2. **第二部分的显示错误** — 「第一集」当最新集、不可播标成可播、英文状态值和 platform token 上屏、搜索框承诺不存在的演员搜索。这些是**错误信息**，比措辞严重
3. **规则页三条「改一处修一片」** — 四个状态 label、引擎代号徽标（`:1038` 和 `:1909` 两处）、「执行器」同模板 7 处
4. **线路状态位 6 条** — 用户最常看见的位置
5. **AniCh 代号 + 两处开发计划外泄**
6. **假数据 / 假控件** — 写死的评分分布、写死的「刚刚」、点不动的筛选排序、永远筛不出东西的「正篇」。要么接真实数据，要么删掉
7. 账号错误消息簇（约 20 条）→ 下载 HLS 簇（约 25 个字符串）→ 其余 A 类和术语统一

