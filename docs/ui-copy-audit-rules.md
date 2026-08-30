# 规则页面向用户中文文案审查（`lib/src/rules/`）

本文是主报告 `docs/ui-copy-audit.md` 的规则页补充：逐行通读了 `lib/src/rules/` 下全部 19 个 Dart 文件，只收录**确认会显示给用户**的中文文案，并已剔除主报告中已核实收录的条目（`rule_models.dart:51-54` 四个状态 label、`rule_plugin_page.dart:1038` 引擎徽标、「需要接入 XX 执行器」同模板各处、`rule_playback_resolver.dart:2080` / `5506` / `5508` / `5592`、`csp_rule_support.dart:118`、`tvbox_xbpq_hydrator.dart:274`、`source_rule_bridge.dart:172`）。

分类口径：**A 类**＝不像人话（机翻腔、开发者视角、内部编目用语、暴露未实现计划、不成句）；**B 类**＝术语泄漏（协议格式名、内部机制名、代码概念、插值类名、中文里混英文异常文本）。规则页是高级用户页面，标准已放宽，确实该保留的专业词单列「建议保留」。

## 1. `lib/src/rules/rule_plugin_page.dart`

规则管理页与来源合集页的全部上屏文案。这里的每一条都经 `Text`/`SectionTitle`/`Tooltip`/`_showSnack`/`AlertDialog` 直接渲染。

| 位置 | 现文案 | 问题 | 建议 |
| --- | --- | --- | --- |
| `rule_plugin_page.dart:331` | `· 自动接入 $catalogPlaybackCount 条` | B：「接入」是内部机制词，「条」无量词对象，用户不知道接入了什么 | `· 已自动启用 N 个来源` |
| `rule_plugin_page.dart:120` | `已启用官方及已授权来源` | A：内部编目口径（「已授权」是权限批准状态的内部叫法），且与刚按下的「全部启用」不对应 | `已启用全部扩展来源` |
| `rule_plugin_page.dart:433` | `自动来源包` / `已并入扩展来源，无需单独管理` | B：「来源包」是内部打包概念；A：「已并入」是开发者视角 | 标题 `自动来源`，副标题 `跟着在线服务自动更新，不用单独管理` |
| `rule_plugin_page.dart:482` | `提供 ${group.candidateRuleCount} 条可执行播放规则` | B：「可执行」「播放规则」都是内部执行层术语 | `可以提供 N 条播放线路` |
| `rule_plugin_page.dart:483-484` | `合并 N 个同名规则包 · N 条候选规则，查源时自动去重` | B：「规则包」「候选规则」「查源」「去重」四个内部词叠在一句里 | `合并了 N 个同名来源，共 N 条线路，找线路时会自动去掉重复的` |
| `rule_plugin_page.dart:636-637` | `N 个已安装 · N/N 个可执行规则已开启` | B：「可执行规则」是执行状态内部词 | `N 个已安装 · N/N 个可用的已开启` |
| `rule_plugin_page.dart:738` | `切换规则启用状态` | A：机翻腔的动宾结构，tooltip 不像人说的话 | `开启或关闭这个规则` |
| `rule_plugin_page.dart:801` | `从当前规则仓库检查这个规则的最新版本` | A：暴露未实现的开发计划——点下去并不联网检查，`onTap` 只弹一句固定文案 | 要么实现检查，要么改成 `当前使用内置版本，暂时没有更新` |
| `rule_plugin_page.dart:804` | `${rule.name} 已是当前仓库版本` | A：不论实际情况都回这一句（假更新），且「当前仓库版本」是内部说法 | `${rule.name} 用的是内置版本，暂时没有更新` |
| `rule_plugin_page.dart:810` | `从已安装列表移除，之后可在规则仓库重新安装` | B：「已安装列表」「规则仓库」是内部数据结构名 | `删掉之后还能从来源合集里重新装回来` |
| `rule_plugin_page.dart:910` | `粘贴仓库地址，扫描候选文件，再逐条选择规则` | B：「候选文件」是扫描器内部概念 | `粘贴地址，先看清楚里面有哪些规则，再挑要装的` |
| `rule_plugin_page.dart:932` | `使用方法：① 粘贴 GitHub 仓库首页或 raw JSON；② 从扫描结果中选择一个配置文件；③ 勾选需要的规则。导入后默认关闭，由你自己逐条启用。` | B：`raw JSON`、「配置文件」是格式与文件层术语 | `用法：① 粘贴 GitHub 仓库地址，或直接粘贴规则文件地址；② 从列出的文件里选一个；③ 勾选要装的规则。装好后默认都是关着的，你自己逐个打开。` |
| `rule_plugin_page.dart:1045` | `SmallBadge(label: 'captcha')` | B：中文界面里的裸英文常量上屏 | `需验证码` |
| `rule_plugin_page.dart:1128-1130` | `内容哈希` + `manifest.contentHash`（等宽字体全量摘要） | B：哈希是纯代码概念，普通用户无从判断 | 折叠或删掉；若要留，改成 `版本指纹` 并只显示前 8 位 |
| `rule_plugin_page.dart:1154` | `明文 HTTP` | B：协议名 + 传输层概念 | `不加密的连接（HTTP）` |
| `rule_plugin_page.dart:1158` | `自定义 Header` | B：中文标签里夹 HTTP 字段英文名 | `自定义请求头` |
| `rule_plugin_page.dart:1163` | `仅批准当前内容和权限。规则更新后需要重新确认。` | A：机翻腔（「批准当前内容」不成句，用户不知道「内容」指什么） | `这次只授权当前这个版本；规则更新后会再问你一次。` |
| `rule_plugin_page.dart:1242` | `规则字段完整，可参与播放查源。` | B：「字段完整」「参与」「查源」三个内部词；A：开发者视角 | `这个来源可以直接用来找线路。` |
| `rule_plugin_page.dart:1245` | `需要在 WebView 中完成人机验证或页面交互。` | B：`WebView`、「页面交互」是实现细节 | `需要你在网页里手动过一次验证。` |
| `rule_plugin_page.dart:1247` | `规则缺少当前解析器必需的搜索或播放字段。` | B：「解析器」「字段」是代码概念 | `这条规则信息不全，暂时用不了。` |
| `rule_plugin_page.dart:1315` | `按内容类型隔离` | B：「隔离」是熔断/沙箱层的内部机制词 | `番剧、电视剧、电影分开管理` |
| `rule_plugin_page.dart:1339` | `保留字段完整、可搜索、分类明确的规则` | B/A：「字段完整」是开发者筛选口径，读者是用户不是维护者 | `只收信息齐全、能搜索、分类清楚的来源` |
| `rule_plugin_page.dart:1340` | `过滤直播、教育、网盘授权源和本地代理源` | B：「网盘授权源」「本地代理源」是内部来源分类 | `不收直播、教育，以及要登录网盘或走本地代理的来源` |
| `rule_plugin_page.dart:1572` | `填写名称、搜索地址和解析字段，保存到本地规则库` | B：「解析字段」「本地规则库」是内部概念 | `填名称和搜索地址，存在这台设备上` |
| `rule_plugin_page.dart:1605` | `粘贴 GitHub 仓库或 raw JSON` | B：`raw JSON` 作为按钮标题上屏 | `粘贴 GitHub 仓库或规则文件地址` |
| `rule_plugin_page.dart:1606` | `先扫描并预览候选文件，只导入你明确勾选的规则` | B：「候选文件」内部概念 | `先列出里面的文件给你看，只装你勾选的那些` |
| `rule_plugin_page.dart:1757` | `默认分支：${scan.defaultBranch}。请选择一个候选文件预览，系统不会自动导入整仓。` | A：「系统」是第三人称开发者视角、「整仓」是缩写行话；B：「默认分支」「候选文件」 | `这个仓库用的是 ${scan.defaultBranch} 分支。挑一个文件看看内容，不会一次性全导进来。` |
| `rule_plugin_page.dart:1765` | `GitHub 返回的文件树已截断，当前仅展示可见候选。` | A/B：直接照抄 API 语义（「文件树」「截断」「可见候选」），像是给开发者看的日志 | `仓库文件太多，这里只列出了一部分。` |
| `rule_plugin_page.dart:1772` | `没有找到 JSON/TXT 候选文件` | B：格式名 + 内部概念 | `这个仓库里没有能导入的规则文件` |
| `rule_plugin_page.dart:1793` | `${candidate.sizeLabel} · 只读预览后再选择规则` | A：「只读预览」不成句，读起来像开关名 | `${candidate.sizeLabel} · 先看内容，再决定装哪些` |
| `rule_plugin_page.dart:1884` | `默认不勾选。导入后可在播放规则中自行启用执行。` | A：机翻腔（「自行启用执行」三个动词连排）；B：「播放规则」 | `默认一个都不勾。装好之后到扩展来源里自己打开。` |
| `rule_plugin_page.dart:1909-1910` | `'${rule.contentLabel} · ${rule.engine} · ${rule.executionStatus.label}'` | B：`rule.engine` 引擎代号（xbpq / drpy-js / animeko-web-selector）在选规则对话框副标题上屏——与已收录的 `1038` 徽标是两处不同代码路径 | 去掉引擎段，只留 `内容类型 · 状态` |
| `rule_plugin_page.dart:1998` | `粘贴 GitHub 仓库首页时，会列出 JSON/TXT 文件；粘贴 raw JSON 时，会直接进入规则预览。` | B：`JSON/TXT`、`raw JSON` 两处格式名 | `粘贴仓库地址会先列出里面的文件；直接粘贴规则文件地址就会跳到规则预览。` |
| `rule_plugin_page.dart:2010` | `labelText: 'GitHub 仓库或 raw JSON 地址'` | B：输入框标签里的 `raw JSON` | `GitHub 仓库或规则文件地址` |
| `rule_plugin_page.dart:2016` | `配置字段会按原样保留，导入后可在播放规则中自行启用。` | B：「配置字段」「按原样保留」是开发者叙述 | `导入的内容不会被改动；装好后到扩展来源里自己打开。` |
| `rule_plugin_page.dart:2157` | `手动新建规则还缺少播放页 XPath 字段，请继续补全后再启用播放。` | B：`XPath`、「字段」；A：暴露未实现的编辑流程（界面里没有补全 XPath 的地方） | `还差播放页的解析设置，暂时不能播放。` |
| `rule_plugin_page.dart:2158` | `用户手动新建规则。` | A：内部编目口径，第三人称称呼用户，且它会作为规则卡片说明上屏 | `你自己新建的来源。` |
| `rule_plugin_page.dart:2183` | `return text;`（`_friendlyImportError` 兜底） | B：任何未匹配的异常原文直接进 SnackBar，会把英文异常字符串上屏 | 兜底改成 `这个地址读不出规则，请确认是规则文件地址` |
| `rule_plugin_page.dart:2199` | `$prefix已同步到当前内置版本` | B：「内置版本」是打包内部概念 | `$prefix已经是最新的了` |

## 2. `lib/src/rules/rule_models.dart` · `rule_security.dart`

枚举 label，经 `SmallBadge` 与权限对话框 `_PermissionLine` 上屏。

| 位置 | 现文案 | 问题 | 建议 |
| --- | --- | --- | --- |
| `rule_models.dart:50` | `executable('可执行')` | B：「可执行」是执行层内部词，与已收录的另外四个状态 label 同源但主报告未列它 | `可用` |
| `rule_models.dart:31-32` | `kazumi('KazumiRules')` / `tvbox('TVBox')` | B：生态项目代号作为来源徽标上屏（`rule_plugin_page.dart:1039`） | 归并成 `社区规则` / `TVBox 配置`，或至少中文化为 `Kazumi 规则库` |
| `rule_models.dart:33` | `custom('用户仓库')` | A：内部编目用语，用户不会把自己粘的地址叫「用户仓库」 | `你添加的` |
| `rule_security.dart:25` | `taskScoped('仅当前任务')` | B：「任务」是运行时作用域概念 | `只在这次播放时使用` |

## 3. `lib/src/rules/rule_importer.dart`

全部 `FormatException` 消息都会经 `rule_plugin_page.dart:_friendlyImportError` 剥掉前缀后进 SnackBar，属确认上屏。

| 位置 | 现文案 | 问题 | 建议 |
| --- | --- | --- | --- |
| `rule_importer.dart:38` | `请输入完整的 http/https JSON 文件地址。` | B：`http/https`、`JSON` 三个格式/协议名 | `请填一个完整的规则文件网址。` |
| `rule_importer.dart:42` | `GitHub 仓库首页或代码页面不是规则文件。请使用 raw JSON 地址，或下载 JSON 后从本地/剪贴板导入。` | B：`raw JSON`、`JSON`；A：一句话塞三种操作路径 | `这是仓库网页，不是规则文件。可以粘贴仓库地址让我扫描，或者把文件内容复制过来。` |
| `rule_importer.dart:66` | `规则导入地址发生重定向，已停止访问。` | B：「重定向」是 HTTP 层概念 | `这个地址会跳转到别处，为安全起见没有继续打开。` |
| `rule_importer.dart:69` | `仓库请求失败：HTTP ${response.statusCode}` | B：「请求」+ 裸 HTTP 状态码上屏 | `这个地址打不开（错误码 ${response.statusCode}）` |
| `rule_importer.dart:77`、`893` | `规则文件超过 ${_byteSizeLabel(maxFileBytes)} 读取上限，已停止下载。` | B：「读取上限」是实现约束的内部说法 | `规则文件太大（超过 X），没有继续下载。` |
| `rule_importer.dart:94` | `导入内容为空。` | A：不成句的直译，缺少主语和下一步 | `没有内容可以导入。` |
| `rule_importer.dart:118` | `用户规则仓库`（导入包兜底名，进对话框标题 `选择规则 · $name`） | A：内部编目用语 | `你添加的来源` |
| `rule_importer.dart:177` | `'Animeko 源 ${index + 1}'`（规则名兜底，卡片标题上屏） | B：`Animeko` 内部生态代号 + 序号编目 | `未命名来源 ${index + 1}` |
| `rule_importer.dart:227` | `从 Animeko web-selector 源导入，可直接尝试解析在线播放地址。` | B：`web-selector` 引擎代号、「解析」 | `从社区来源导入，可以直接用来找线路。` |
| `rule_importer.dart:253` | `这是 BT/RSS 资源订阅，不是 mp4/m3u8 在线播放源；当前播放器没有下载或 BT 边下边播能力，所以不能直接启用播放。` | B：`BT`/`RSS`/`mp4`/`m3u8` 四个格式名；A：后半句在讲播放器实现缺口 | `这是下载类资源（BT/磁力），不能直接在线播放。` |
| `rule_importer.dart:255` | `从 Animeko RSS/BT 源导入，仅作为资源信息保留。` | B：格式名 + 「保留」是编目动作 | `从下载类来源导入，只留个记录。` |
| `rule_importer.dart:280` | `从 Animeko 源导入。` | A：内部编目短句 | `从社区来源导入。` |
| `rule_importer.dart:441`、`485` | `'TVBox 规则'` / `'TVBox 仓库配置'`（规则名兜底） | B：`TVBox` 生态代号 + 「仓库配置」 | `未命名 TVBox 来源` / `TVBox 配置` |
| `rule_importer.dart:472`、`495` | `从 TVBox 配置导入。` / `从 $sourceUrl 导入。` | A：内部编目短句，作为卡片说明上屏时几乎没有信息量 | `来自 TVBox 配置，可以用来找线路。` |
| `rule_importer.dart:532` | `'仓库入口 ${index + 1}'` | A/B：「仓库入口」是内部结构名 + 序号编目 | `子来源 ${index + 1}` |
| `rule_importer.dart:544` | `从聚合仓库配置导入。` | B：「聚合仓库配置」三个内部词连排 | `从合集地址导入。` |
| `rule_importer.dart:579` | `'用户规则'`（规则名兜底） | A：内部编目用语 | `未命名来源` |
| `rule_importer.dart:661` | `从用户规则仓库导入。` | A：内部编目用语 | `你自己添加的来源。` |
| `rule_importer.dart:880` | `服务器返回的内容类型“$mime”不是可解析的 JSON/TXT 规则。` | B：「内容类型」+ 裸 MIME 插值 + `JSON/TXT` | `这个地址返回的不是规则文件。` |
| `rule_importer.dart:907` | `服务器返回了二进制内容，不是可导入的 JSON/TXT 规则。` | B：「二进制内容」`JSON/TXT` | `这个地址返回的不是文本规则文件。` |
| `rule_importer.dart:912` | `规则文件不是有效的 UTF-8 文本，无法解析。` | B：`UTF-8`、「解析」 | `这个规则文件的编码读不出来。` |

## 4. `lib/src/rules/rule_plugin_repository.dart`

只有 `_verifiedBuiltInRules`（395-591 行）在用。这四条 `note` 会经 `_ruleDisplayNote` 走到规则卡片说明行（这四条规则 `canResolveNatively` 均为 true，note 确认上屏）。

| 位置 | 现文案 | 问题 | 建议 |
| --- | --- | --- | --- |
| `rule_plugin_repository.dart:483` | `通过站点公开的页面播放清单接口获取 HLS，客户端不加载广告播放器。` | B：`HLS`、「播放清单接口」、「客户端」三层实现细节 | `直接取站点的播放地址，不加载它的广告播放器。` |
| `rule_plugin_repository.dart:513` | `播放时从公开接口获取短时 HLS 清单，并在客户端验证媒体分片。` | B：`HLS 清单`、「媒体分片」、「客户端」 | `播放时临时取地址，播前会先确认能不能播。` |
| `rule_plugin_repository.dart:551` | `播放页提供经页面编码的 HLS 地址，客户端会先解码并验证清单与分片。` | B：`HLS`、「编码/解码」、「清单与分片」全是实现流程 | `播放地址在网页里是加密的，播前会先还原并确认能不能播。` |
| `rule_plugin_repository.dart:589` | `播放页提供 HLS 清单地址，客户端会验证清单与首个媒体分片。` | B：同上 | `播前会先确认这条线路能不能播。` |

## 5. `lib/src/rules/rule_playback_resolver.dart`

全部 `_unavailableLine` / `_deadLine` / `_PlayableProbeResult` 的 message 都会经 `PlaybackLine.message` 进播放器 UI（`player_page.dart:1834`、`player_panels.dart:1307-1308`、`playback_line_display.dart:773`、`settings_page.dart:1117`），确认上屏。

| 位置 | 现文案 | 问题 | 建议 |
| --- | --- | --- | --- |
| `rule_playback_resolver.dart:228` | `该规则需要验证码或 WebView 手动处理，解析器不会绕过验证。` | B：`WebView`、「解析器」；A：「解析器不会绕过」是开发者立场声明 | `这个来源要先在网页里手动过验证。` |
| `rule_playback_resolver.dart:420` | `'${episode.displayTitle} 路 $lineName'` | A：「路」是残留字符，不成句（同文件其余处都用 `·` 或 `线路N`） | `'${episode.displayTitle} · $lineName'` |
| `rule_playback_resolver.dart:663` | `该 Animeko 源缺少 CSS 解析配置。` | B：`Animeko` 引擎代号、`CSS`、「解析配置」 | `这个来源的解析设置不全，用不了。` |
| `rule_playback_resolver.dart:674`、`1232`、`1402` | `没有匹配到当前条目的详情页。` | B：「匹配」「条目」「详情页」是抓取层内部词 | `在这个来源里没找到这部片。` |
| `rule_playback_resolver.dart:690` | `详情页没有解析到当前集的播放入口。` | B：「详情页」「解析」「播放入口」 | `这个来源里没有这一集。` |
| `rule_playback_resolver.dart:716` | `找到了播放页，但没有解析到 mp4/m3u8 直链。` | B：`mp4/m3u8`、「直链」、「解析」 | `找到播放页了，但没取到能播的地址。` |
| `rule_playback_resolver.dart:734`、`864` | `没有匹配到当前条目。` | B：「匹配」「条目」 | `在这个来源里没找到这部片。` |
| `rule_playback_resolver.dart:749` | `播放清单参数无效。` | B：「播放清单」「参数」是接口层概念 | `这个来源返回的信息不完整。` |
| `rule_playback_resolver.dart:763`、`897` | `播放清单暂时不可用。` | B：「播放清单」 | `这条线路暂时用不了。` |
| `rule_playback_resolver.dart:779` | `没有找到当前集的 HLS 线路。` | B：`HLS` | `没找到这一集的线路。` |
| `rule_playback_resolver.dart:793` | `'${episode.displayTitle} · 镜像线路 ${index + 1}'` | B：「镜像线路」是 CDN 层说法 | `'${episode.displayTitle} · 线路 ${index + 1}'` |
| `rule_playback_resolver.dart:819` | `播放线路验证失败。` | B：「验证」是探测流程内部词 | `这些线路都没连上。` |
| `rule_playback_resolver.dart:872` | `详情页没有返回剧集列表。` | B：「详情页」「返回」 | `这个来源没给出分集。` |
| `rule_playback_resolver.dart:877` | `没有匹配到当前集。` | B：「匹配」 | `这个来源里没有这一集。` |
| `rule_playback_resolver.dart:880` | `当前集需要站点会员，未加入播放线路。` | A：「未加入播放线路」是内部集合操作视角 | `这一集要站点会员才能看。` |
| `rule_playback_resolver.dart:906` | `'${episode.displayTitle} · 青空线路'` | 建议保留（站点名，用户可辨识），但与 `1067`/`1313`/`1486` 的 `线路N` 命名不统一 | 统一成 `· 线路1` 或统一带站点名 |
| `rule_playback_resolver.dart:1226` | `该 Kazumi 规则缺少 XPath 解析配置。` | B：`Kazumi` 引擎代号、`XPath`、「解析配置」 | `这个来源的解析设置不全，用不了。` |
| `rule_playback_resolver.dart:1243` | `详情页没有解析到播放线路。` | B：「详情页」「解析」 | `这个来源里没有可用线路。` |
| `rule_playback_resolver.dart:1272`、`1433` | `找到详情页，但当前集没有解析到直链。` | B：「详情页」「直链」「解析」 | `找到这部片了，但这一集取不到能播的地址。` |
| `rule_playback_resolver.dart:1397` | `该 XBPQ 规则缺少解析配置。` | B：`XBPQ` 引擎代号 + 「解析配置」 | `这个来源的解析设置不全，用不了。` |
| `rule_playback_resolver.dart:1623` | `该 TVBox $apiLabel 源缺少有效接口地址。` | B：`TVBox`、插值 `JSON`/`XML`、「接口地址」 | `这个来源的地址不对，用不了。` |
| `rule_playback_resolver.dart:1647` | `接口没有匹配到当前条目。` | B：「接口」「匹配」「条目」 | `在这个来源里没找到这部片。` |
| `rule_playback_resolver.dart:1693` | `已找到条目，但当前集没有可直接播放的地址。` | B：「条目」 | `找到这部片了，但这一集没有能直接播的地址。` |
| `rule_playback_resolver.dart:1820` | `规则请求超出已批准的${…}域名范围。`（`StateError`） | B：「规则请求」「已批准…域名范围」是沙箱策略内部语；且它经 `_friendlyError` 变成 `解析失败：Bad state: 规则请求超出…`，中文里混进英文 `Bad state:` | 改为在 `_friendlyError` 里识别该 `StateError` 并输出 `这个来源想访问未授权的网站，已拦下。` |
| `rule_playback_resolver.dart:1920` | `规则页面重定向次数过多。`（`StateError`） | B：「重定向」；同上会带 `Bad state:` 前缀上屏 | `这个来源的网页一直在跳转，已停下。` |
| `rule_playback_resolver.dart:2027` | `已解析到当前集的播放地址。` | B/A：「解析」是内部动作，成功态没必要向用户描述过程 | `可以播放。` |
| `rule_playback_resolver.dart:2295` | `媒体清单格式无效，无法确认真实播放分片。` | B：「媒体清单」「播放分片」 | `这条线路返回的内容不完整。` |
| `rule_playback_resolver.dart:2351` | `视频 CDN 拒绝访问，可能有防盗链或地区限制。` | B：`CDN`、「防盗链」 | `视频服务器拒绝了访问，可能限制了地区或来源。` |
| `rule_playback_resolver.dart:2358` | `视频 CDN 返回 404，这条播放地址已经失效。` | B：`CDN` + 裸状态码 | `这条播放地址已经失效了。` |
| `rule_playback_resolver.dart:2364` | `视频 CDN 返回 HTTP ${response.statusCode}。` | B：`CDN` + `HTTP` + 裸状态码 | `视频服务器出错了（错误码 ${response.statusCode}）。` |
| `rule_playback_resolver.dart:2370` | `视频 CDN 连接超时。` | B：`CDN` | `视频服务器连接超时。` |
| `rule_playback_resolver.dart:2376` | `视频 CDN 无法访问：${_shortError(error)}` | B：`CDN`（后半段截断已在主报告收录） | `视频服务器连不上：…` |
| `rule_playback_resolver.dart:2531` | `HLS 子清单已经失效。` | B：`HLS`、「子清单」 | `这条线路的播放列表已失效。` |
| `rule_playback_resolver.dart:2547` | `HLS 子清单或媒体分片验证超时。` | B：`HLS`、「子清单」「媒体分片」「验证」 | `检查这条线路时超时了。` |
| `rule_playback_resolver.dart:2549` | `HLS 子清单无法解析或访问。` | B：同上 | `这条线路的播放列表读不出来。` |
| `rule_playback_resolver.dart:2552` | `HLS 主清单内没有可播放的子清单。` | B：「主清单」「子清单」 | `这条线路里没有能播的画质。` |
| `rule_playback_resolver.dart:2572` | `HLS 清单没有返回可验证的媒体分片。` | B：`HLS 清单`、「媒体分片」 | `这条线路没有实际的视频内容。` |
| `rule_playback_resolver.dart:2618` | `HLS 媒体分片验证超时。` / `HLS 清单存在，但媒体分片无法读取。` | B：同上 | `检查视频内容时超时了。` / `这条线路的视频内容读不出来。` |
| `rule_playback_resolver.dart:2650` | `DASH 清单没有可验证的初始化或媒体分片。` | B：`DASH`、「初始化分片」「媒体分片」 | `这条线路没有实际的视频内容。` |
| `rule_playback_resolver.dart:2668` | `DASH ${resource.label}无法读取。` | B：`DASH` + 插值标签（值为「初始化分片」/「媒体分片」/「媒体文件」，见 `3440`/`3443`/`3475`） | `这条线路的视频内容读不出来。` |
| `rule_playback_resolver.dart:2671` | `DASH ${resource.label}验证超时。` | B：同上 | `检查这条线路时超时了。` |
| `rule_playback_resolver.dart:2673` | `DASH ${resource.label}无法访问。` | B：同上 | `这条线路的视频内容连不上。` |
| `rule_playback_resolver.dart:3440`、`3456` | `'初始化分片'`（`_DashProbeResource` label） | B：内部常量经上面三条插值上屏 | 与调用方一起改写，不再单独插值 |
| `rule_playback_resolver.dart:3443`、`3466` | `'媒体分片'` | B：同上 | 同上 |
| `rule_playback_resolver.dart:3475` | `'媒体文件'` | B：同上（相对温和，但仍是探测资源分类名） | 同上 |
| `rule_playback_resolver.dart:4033` | `视频地址返回了空内容。` | A：「视频地址返回」是开发者视角主语 | `这条线路没有内容。` |
| `rule_playback_resolver.dart:4043`、`4117` | `视频地址返回的是网页或错误信息，不是媒体内容。` | A/B：同上 + 「媒体内容」 | `这条线路指向的是一个网页，不是视频。` |
| `rule_playback_resolver.dart:4060` | `视频地址返回的 HLS 清单无效或没有媒体分片。` | B：`HLS 清单`、「媒体分片」 | `这条线路的内容不完整，没法播。` |
| `rule_playback_resolver.dart:4068`、`4071` | `视频地址返回的 DASH 清单无效。` | B：`DASH 清单` | `这条线路的内容不完整，没法播。` |
| `rule_playback_resolver.dart:4094` | `视频地址没有返回有效的 MP4 数据。` | B：`MP4`、「数据」 | `这条线路的视频文件不完整。` |
| `rule_playback_resolver.dart:4099` | `视频地址没有返回有效的视频容器数据。` | B：「视频容器」是封装格式术语 | `这条线路的视频文件不完整。` |
| `rule_playback_resolver.dart:4104` | `视频地址没有返回有效的 FLV 数据。` | B：`FLV` | `这条线路的视频文件不完整。` |
| `rule_playback_resolver.dart:4119` | `视频地址没有返回可识别的媒体内容。` | A/B：开发者视角 + 「媒体内容」 | `这条线路里没有能播的视频。` |
| `rule_playback_resolver.dart:5505` | `解析超时，当前规则源响应太慢。` | B：「解析」「规则源」 | `这个来源响应太慢，超时了。` |
| `rule_playback_resolver.dart:5507` | `网络不可用或规则源无法访问。` | B：「规则源」 | `网络不通，或这个来源打不开。` |
| `rule_playback_resolver.dart:5589` | `网络不可用或源站无法访问` | B：「源站」是 CDN/回源层术语 | `网络不通，或这个网站打不开` |
| `rule_playback_resolver.dart:5590` | `证书或 TLS 握手失败` | B：`TLS`、「握手」、「证书」 | `安全连接建立失败` |
| `rule_playback_resolver.dart:5591` | `连接被中断` | 建议保留（已是自然中文），仅在与上两条并列时略显技术 | 保留 |

## 6. `lib/src/rules/github_rule_repository_scanner.dart`

`FormatException` 与 `_blockedReason` 都会上屏：前者经 `_friendlyImportError` 进 SnackBar，后者经 `rule_plugin_page.dart:1792` 的 `candidate.blockedReason` 进候选列表副标题。

| 位置 | 现文案 | 问题 | 建议 |
| --- | --- | --- | --- |
| `github_rule_repository_scanner.dart:28` | `请输入 GitHub 仓库首页地址，例如 https://github.com/owner/repo。` | 建议保留（示例清晰、面向操作） | 保留 |
| `github_rule_repository_scanner.dart:50` | `GitHub 仓库信息格式无效。` | B：「仓库信息格式」是 API 响应层说法 | `读不出这个仓库的信息。` |
| `github_rule_repository_scanner.dart:54` | `GitHub 仓库没有可扫描的默认分支。` | B：「默认分支」是 Git 概念（这里是异常兜底，普通用户看不懂） | `这个仓库里没有可扫描的内容。` |
| `github_rule_repository_scanner.dart:68` | `GitHub 仓库文件列表格式无效。` | B：同 50 | `读不出这个仓库的文件列表。` |
| `github_rule_repository_scanner.dart:167` | `空文件，无法导入` | A：不成句的短语拼接 | `这个文件是空的` |
| `github_rule_repository_scanner.dart:169` | `文件超过 ${_byteSizeLabel(maxFileBytes)} 读取上限` | B：「读取上限」 | `文件太大（超过 X）` |
| `github_rule_repository_scanner.dart:177` | `GitHub 公共 API 请求过于频繁，请稍后再试。` | B：`API`、「请求过于频繁」 | `GitHub 暂时限制了访问，过一会儿再试。` |
| `github_rule_repository_scanner.dart:182` | `$action失败：HTTP ${response.statusCode}`（`$action` 为 `读取 GitHub 仓库信息` / `扫描 GitHub 仓库文件`） | B：`HTTP` + 裸状态码；A：动词短语插值拼句，读起来像日志 | `连接 GitHub 失败（错误码 ${response.statusCode}）` |

## 7. 建议保留

规则页是给高级用户的，这些专业词去掉反而会让用户无法判断该怎么操作。

| 位置 | 现文案 | 保留理由 |
| --- | --- | --- |
| `rule_plugin_page.dart:1142-1143` | `JavaScript` / `允许`·`不允许` | 权限授权面板必须精确说明授予了什么；`JavaScript` 是用户在浏览器里见过的词，替换成中文会失真。 |
| `rule_plugin_page.dart:1147` | `Cookie` | 同上，用户对 Cookie 有直觉，且这是安全决策的关键信息。 |
| `rule_plugin_page.dart:1150-1151` | `WebView` | 权限面板里代表「会打开内嵌浏览器」，这是授权范围的一部分；但同一个词出现在 `1245` 的说明文案里就该改（见上表）。 |
| `rule_plugin_page.dart:1134`、`1138` | `页面域名` / `媒体域名` | 域名白名单是本页权限模型的核心，用户需要看到具体范围。 |
| `rule_plugin_page.dart:1596` | `读取剪贴板里的规则 JSON 或 TVBox 配置并导入` | 用户是从别处复制来的，必须知道支持哪种格式才知道自己复制得对不对。`JSON`/`TVBox` 在这里是操作依据而非泄漏。 |
| `rule_plugin_page.dart:2115` | `hintText: 'https://example.com/search?wd=@keyword'` | 新建规则对话框，`@keyword` 占位符是填写规范本身。 |
| `rule_security.dart:6-8` | `官方` / `社区签名` / `未信任` | 信任等级三档必须能区分；「社区签名」虽含签名概念，但换成「社区来源」会丢掉「有签名校验」这层含义。 |
| `rule_plugin_page.dart:1132` | `信任等级` | 与上一条配套，是本页的既有概念。 |

## 8. 不可达（不计入 A/B 统计）

以下中文文案在当前代码里走不到界面。**逐条注明依据**，供后续改动时留意——其中若干条只差一步就会上屏。

| 位置 | 现文案 | 不可达依据 |
| --- | --- | --- |
| `rule_plugin_repository.dart:594-935` | `legacyCuratedRuleDefinitions` 整块（约 30 条 note / unsupportedReason / tags，含 `619`/`644`/`669`/`696`/`697`/`725`/`726`/`753`/`754`/`779`/`809`/`828`/`847`/`877`/`895`/`896`/`915`/`934`） | 全仓（含 test/）搜索 `legacyCuratedRuleDefinitions` 只命中定义处本身，无任何引用；且已标 `@Deprecated`。主报告收录的 `827`/`846`/`914`/`933` 四条「需要接入 XX 执行器」也在这一块内。 |
| `kazumi_rule_repository.dart:57`、`64`、`149`、`164`、`212`、`278`、`283` | `可直接安装的内置番剧规则。`、`KazumiRules 索引中存在缺少名称的规则。`、`KazumiRules 索引格式无效。`、`KazumiRules 索引没有可用规则。`、`所选 KazumiRules 规则暂时都无法读取。`、`规则仓库请求失败：HTTP …`、`规则仓库暂时无法访问。` | 全仓搜索 `KazumiRuleRepository` / `KazumiRuleCatalog`，`lib/` 下只有该文件自身，其余命中全在 `test/`。整个文件目前只有测试在用。 |
| `tvbox_xbpq_hydrator.dart:116`、`146`、`166`、`178`、`179`、`221`、`230`、`299`、`303`、`306`、`309`、`317`、`320`、`325`、`328`、`331`、`375`、`376`、`380`、`386`、`391`、`402`、`406`、`410`、`412`、`414`、`416` | `XBPQ 站点数量超过 N 条安全上限…`、`…已隔离跳过。`、`XBPQ ext 为空…`、`XBPQ JSON 根节点必须是对象。` 等 27 条 | 这些字符串只写入 `TvBoxXbpqHydrationSite.message` / `_ResolvedReference.reason` / `_JsonFetch.failure`。唯一消费方 `sources/source_rule_bridge.dart:112-118` 只读 `hydration.executableRules`，从不读 `message`/`sites`。注：这批文案术语密度极高（`XBPQ`/`ext`/`JAR`/`同源`/`隔离`/`播放链`），一旦接到界面需整批重写。 |
| `csp_rule_support.dart:114` | `规则已保留，但它引用的 CSP 包未通过当前版本的固定哈希审计。` | `androidCspUnsupportedReason` 的返回值经 `rule_importer.dart:471` 写入 `unsupportedReason`，理论上会走到 `_ruleDisplayNote:1240` 上屏——**但这条与主报告记录的行号内容不符**：主报告把 `csp_rule_support.dart:114` 记为「需要接入 XX 执行器」模板之一，实际该行是这句哈希审计文案。若确认可达，它是 B 类（`CSP 包`/`固定哈希审计`/`审计`），建议改为 `这个来源用的扩展包没通过安全校验，暂时用不了。` |
| `android_csp_bridge.dart:222`、`230`、`237`、`243`、`255`、`608` | `The native CSP bridge is available on Android only.` 等英文异常消息 | `rule_playback_resolver.dart:530` 的 `_resolveAndroidCsp` 用裸 `catch (_) { return const []; }` 全部吞掉，不产生 PlaybackLine，也不进 `_friendlyError`。 |
| `drpy_runtime_io.dart:128`、`255`、`258`、`382`、`1468`、`1471`、`1526`、`1617`、`1620`、`1712` 等 | `drpy rule has no inline source or resolvable ext URL.` 等英文消息 | 全部写入 `DrpyRuntimeResult.error`；`rule_playback_resolver.dart:361-363` 检测到 `error != null` 直接 `return const []`，消息不进任何 UI 字段。 |
| `rule_importer.dart:215`、`269`、`405`、`464`、`494`、`524`、`562`、`604` 等 `tags:` | `['Animeko', 'CSS', '在线播放']`、`['Animeko', '暂不支持']`、`['推荐', '已验证']` 等 | 规则页从不渲染 `RulePlugin.tags`：全仓 `\.tags` 命中中，`rule_playback_resolver.dart:2009`/`2055`/`2079` 只做 `tags.contains('4K')` 判断，`source_management_page.dart:318` 渲染的是 `VideoSource.tags`（另一个类型）。 |
| `rule_playback_resolver.dart:852-854`、`1668`、`1718`、`2483`、`2839-2840` | 中文代码注释 | 注释，非文案。 |
| `rule_playback_resolver.dart:4310`、`4383`、`4389`、`4399` | `线路${n}` / `第${n}集`（TVBox 解析兜底命名） | 这些是解析中间产物的兜底标题，会经 `_TvBoxPlayGroup.name` / `_TvBoxEpisode.title` 参与匹配；`4399` 的组名最终可能进 `_resolveAndroidCspLine:587` 的 line title。命名本身符合中文习惯，无需改。 |
| `rule_playback_resolver.dart:2009`、`5629`、`5633` | `分辨率未知`、`动态流`、`约 N MB` | 可达但被播放器侧同名逻辑覆盖：`playback_line_display.dart:814-838` 的 `_sizeLabel`/`_resolutionLabel` 会用同样的字符串重算，实际显示走播放器那份。属播放页审查范围（`动态流` 宜改 `直播`），此处不重复计入。 |

## 9. 统计

- **读了 19 个文件**（`lib/src/rules/**/*.dart` 全部），没有未读完的文件。其中 9 个文件含中文文案（`rule_playback_resolver.dart` 5634 行分 8 段读完；`animeko_webview_sniffer*.dart` 4 个文件、`drpy_runtime*.dart` 4 个文件、`android_csp_bridge.dart` 共 9 个文件无中文）。
- **审阅中文字符串约 240 条**（含注释、正则、JSON 字段键名等非文案项）。
- **A 类 21 条**、**B 类 88 条**（其中 16 条同时含 A、B 两类问题，已在「问题」列标注 `A/B`，按主问题各计一次，不重复累加）。
- **建议保留 8 条**。
- **不可达约 75 条**（`legacyCuratedRuleDefinitions` 整块约 30 条 + `tvbox_xbpq_hydrator.dart` 27 条 + `kazumi_rule_repository.dart` 7 条 + 英文异常与 tags 若干）。

### 两处与主报告的差异，请复核

1. **`csp_rule_support.dart:114` 的实际内容与主报告记录不符。** 主报告把它列为「需要接入 XX 执行器后才能解析」8 处同模板之一，但该行实际是 `'规则已保留，但它引用的 CSP 包未通过当前版本的固定哈希审计。'`。全仓搜索 `需要接入` 只有 5 处命中（`rule_plugin_repository.dart:827`/`846`/`914`/`933` + `rule_playback_resolver.dart:319`），其中前四处在不可达的 `legacyCuratedRuleDefinitions` 里；`rule_plugin_page.dart:1248` 与 `rule_importer.dart:279` 是同语义变体（`当前版本还没有接入 X 执行器。` / `当前还没有接入 Animeko 的 X 源执行器。`），文字并不相同。8 处这个数字建议按实际改成「5 处原模板 + 3 处变体」。
2. **`rule_plugin_page.dart:1038` 之外还有一处引擎代号上屏**：`rule_plugin_page.dart:1909` 的选规则对话框副标题也直接插值 `rule.engine`，是独立代码路径，已在上表第 1 节收录。

