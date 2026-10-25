# KazumiRules 当前规则验证与 Zeluna 最小内置建议（2026-10-05）

## 1. 结论与当前交接点

**已接入3个通过Windows原生验收的来源：MX动漫（MXdm）、稀饭动漫（xfdmneo）、月城动漫（moonci）。** 只适配已验证的静态HTML路径，不恢复deprecated旧集合。稀饭与月城共享 `play.xfvod.pro`，是两个站点入口而非两套独立媒体后端。[S-MXdm][S-xfdmneo][S-moonci][N1][N2]

- 16条索引规则完成声明审查，9个去重且符合边界的站点实际请求；3个来源通过相邻两集静态媒体提取及有界媒体读取。声明防爬/验证码、私密授权字段或不受支持API模式的来源未强行接入。[E1]
- Windows：实际解析器、线路发现/预热控制器与原生播放器验证通过。3源共6个集数均有解码画面、正视频尺寸、推进中的播放时间和内存PNG帧；第二集全部命中预热缓存，查线记录为0ms。[N1][N2]
- Android：Debug构建与平台规则测试通过；无已连接设备，**Android真实首帧未验证**。Windows证据不能替代Android播放验收。[N3]
- 三源已挂入 `E:/anime/lib/src/rules/rule_plugin_repository.dart`；既有账号迁移后可用，并保留用户禁用/卸载选择。MIT许可随双端构建附带。[L5][N3]
- 已移除未通过媒体读取的 `dl.playxf.top` / `bfikuncdn.com` 权限，只使用已审查的精确域名。未执行下载JS、未启用WebView、未绕过访问限制、未使用真实账号。[E1][L5]
- 未提交、推送、部署或制作正式发布包；本地Debug构建不等于用户安装版已经更新。[N3]

### 精确原始规则JSON路径

| 候选 | 固定提交快照（绝对路径） | 版本 | 上游原始字节SHA-256 |
| --- | --- | --- | --- |
| MXdm | `E:/anime/output/kazumi-validation-20261005/rules/MXdm.json` | 2.4 | `61d0e4d505828125fadba4ef4b6cca6196d1dd8e2ef870b37817a885a2d4c4f7` |
| xfdmneo | `E:/anime/output/kazumi-validation-20261005/rules/xfdmneo.json` | 1.1 | `fa84edbaba7024fb60abe70a754201e05faec9f69e6b8aef86fb5b47bc24e0c0` |
| moonci | `E:/anime/output/kazumi-validation-20261005/rules/moonci.json` | 1.0 | `b742eb4b9c76754cf0ca80b28ebe355319d52d12a973a0b4d499ccf8d0eef6d0` |

均绑定提交 `fce5e15a2e6b57500912d41b3f1c65bb3eb7d392`。快照字节已核对，派生原生配置另建，不改写上游快照。机器交接：`E:/anime/output/kazumi-validation-20261005/implementation-handoff.json`。[E3]

## 2. 背景、范围和本地基线

目标是在不干扰主线程播放记忆、预热、切集及重复检测修复的前提下，找到当前模型能安全消费的声明式来源，而不是凑来源数量。

- 初始Git HEAD：`849cbca2735da6a28ae17872c8b054453f138f6f`；工作区原有未提交改动，主线程持续并行修改。没有reset、clean、stash、切分支或覆盖他人文件。
- 先读 `E:/anime/AGENTS.md`、`E:/anime/CONTRIBUTING.md`、`E:/anime/SECURITY.md`、现有规则仓库/导入器/解析器/模型/权限策略、工程进度和安全探测脚本。[L1][L2][L3][L4]
- 进度文档引用的 `CODEX_ZELUNA_ENGINEERING_SPEC.md` 未在本轮限定查找位置找到，不称为已读原文件；遵循实际可读的项目规则和工程检查点。
- 正确内置基线是 `rule_plugin_repository.dart` 的 `_verifiedBuiltInRules`：饭团动漫、爱看机器人、青空次元、独播库、泥视频。其下 `legacyCuratedRuleDefinitions` 明确deprecated，不是“当前启用的7个Kazumi”。源码定义也不等于用户实际安装/启用状态，本研究未读账号配置。[L5]
- 上游 `useNativePlayer=true` 是播放器选择，**不代表Zeluna静态解析或双平台兼容**。16条规则均声明 `useWebview=true`，有的还声明API或防爬；不能整包直接升级为可信内置。[S-index][L1][L2]

研究子任务写入仅限本文档与 `E:/anime/output/kazumi-validation-20261005/`。主线程后续完成业务代码、测试、许可资产与本地构建，最终状态以第1、6、7节为准；未改生产服务与用户账号。

## 3. 上游当前提交、许可证、索引

- 现场读取GitHub仓库页 `currentOid`，main为 **`fce5e15a2e6b57500912d41b3f1c65bb3eb7d392`**。首次观察为 **2026-10-05 09:01:53（UTC+8）**，后续复核SHA相同；提交页时间为 **2026-10-04 05:51:05（UTC+8）**。不把索引更新时间、pushed_at或搜索抓取时间当提交时间。[S-repo][S-commit][E3]
- 许可证实际为 **MIT，Copyright (c) 2024 Predidit**。复制/派生规则应保留版权与许可文本；该规则许可不等于视频内容、站点品牌或传播权授权，本研究未验证那些权利。[S-license]
- `index.json` 共16项；原始字节SHA-256：`21b427e8f027a586cd453cc73a5238fde04e78b3d244f9e327bc5afb85432354`。本地索引是等价格式化JSON，不以其本地哈希冒充原始下载哈希。[S-index][E3]
- 优先 `you-chrome-research.you_search`，本次空结果；匿名GitHub REST仓库/提交接口均403，未寻找凭据。改用公开GitHub仓库页、提交页及固定提交raw文件。`web.run`返回空内容，未作为证据。
- 15份无非空凭据命名字段的原始规则保存在ignored快照。`xfdmnext` 的两个API请求配置含Authorization字段，值不输出、不保存、不使用、不验证有效性，只存脱敏字段路径和安全结构，未保存完整原始规则。[S-xfdmnext][E3]
- 上游README只列到API Level 5，当前JSON已含6/8；按实际字段审查，不据README推定本地支持。[S-readme][S-sorani][S-xfdmnext]

## 4. 方法、安全边界与证据等级

1. 复用当前 `PublicHttpTransport`：全部DNS答案须为公网，连接固定到校验IP并保留TLS SNI/证书验证；拒绝私网、非HTTP(S)、URL用户信息。各跳转、子清单和媒体请求均经此transport。[L4]
2. 来源并发 **2**，同host间隔至少 **650ms**；每请求整体 **18s**、单来源 **130s**；最多3次重定向。页面至多2MiB，清单/文件头至多512KiB，HLS首段至多256KiB，清单最多3层，不整集下载。[E1]
3. 不继承环境代理、不发Cookie/Authorization、无自动重定向。401/403/429或明显挑战即停止；声明防爬的规则不探站；HLS出现非NONE密钥声明即停止，不取密钥、不处理DRM。[E1]
4. 优先《葬送的芙莉莲》，最多备用《鬼灭之刃》；每详情最多前两条符合当前选集语义的线路，每线两个相邻集数。首轮9站共65次有界请求，随后只有限复核候选和倒序问题，没有扩采片库。[E1][E2]
5. XPath实际使用项目Dart依赖 `html 0.15.6`、`xpath_selector_html_parser 3.0.1`。辅助进程只接收内存HTML并返回脱敏条目，**不是Flutter/原生播放测试**。媒体提取是当前 `_extractPlayableUrl` 的Python等价静态分支，不eval脚本。[L2][E1]
6. 未保存HTML、HLS清单、媒体片段、签名媒体URL、真实Cookie或凭据。只保存域名、状态、耗时、集数和摘要；普通公开详情/播放页面路径可保留，媒体URL只在内存。保存JSON已扫查非空凭据字段、敏感URL参数与具体媒体URL，零命中。[E4]
7. 本探针未对媒体HTTP400去掉Range重试，而当前resolver已有400/405/416有界回退。因此moonci首线400不是永久失效证明。MXdm一次连接失败仅做一次有限复测，不对拒绝或挑战重试。[L2][E2]

| 等级 | 实际证明 | 不证明 |
| --- | --- | --- |
| L0 | 声明审查，或首页失败/按边界跳过 | 搜索、媒体、可播 |
| L1 | 搜索命中、详情/集数结构已读 | 正确的相邻播放页、媒体 |
| L2 | 相邻两集播放页可读 | 有效媒体 |
| L3 | 当前静态分支提取到媒体候选 | 媒体可读取 |
| L4 | 两集媒体路径不同；清单/有界媒体前缀可读，容器/分段签名有效且摘要不同 | 完整片段/全片、解码、首帧、Android |
| W | 主线程Windows真实resolver/media_kit原生记录 | Android、用户冷启动、UI切集性能、长播 |

## 5. 全部16条规则筛选

耗时是本研究首轮单来源墙钟时间，含节流和多个请求，**不是首帧时间**。声明边界或同域去重跳过的来源不虚构网络耗时。[E1]

| 来源/版本 | 上游域名 | HTTP证据 | 首轮耗时 | 差异、失败原因与处理 |
| --- | --- | --- | --- | --- |
| 7sefun 1.3 | `www.7sefun.top` | L2 | 13.245s | 相邻播放页可读，当前静态提取为空；不推断已支持WebView。[S-7sefun] |
| aafun 1.2 | `www.moonci.com` | L0 | 未探站 | 与moonci同域，旧绝对定位XPath、chapterRoads为`//`；去重不重复探站。[S-aafun] |
| AGE 1.5 | `www.agedm.io` | L0 | 0.974s | 首页403，立即停止，不做浏览器/验证码绕过。[S-AGE] |
| akianime 1.4 | `www.akianime.cc` | L3 | 19.362s | 两条线路共四个播放页有候选，候选媒体均404，不算可播。[S-akianime] |
| baimao 1.0 | `www.baimaodm.com` | L2 | 21.305s | 相邻播放页可读、有iframe；静态提取为空，未加载iframe。[S-baimao] |
| dalvdm 1.1 | `www.sbdl.cc` | L0 | 未探站 | 声明启用防爬，按边界跳过。[S-dalvdm] |
| DM84 1.4 | `dmbus.cc` | L2 | 13.296s | 相邻播放页可读、有iframe；静态提取为空，未加载iframe。[S-DM84] |
| ezdmw 1.2 | `m.ezdmw.org` | L1 | 6.535s | 4组集数`[0,38,38,38]`，后三组从38、37、36倒序；当前按位置选集不代表正确第1/2集，未探媒体。[S-ezdmw] |
| giriGiriLove 2.4 | `ani.girigirilove.com` | L0 | 未探站 | 声明防爬/验证码，跳过。[S-giriGiriLove] |
| mgnacg 1.0 | `www.mgnacg.com` | L0 | 未探站 | 声明防爬/验证码，跳过。[S-mgnacg] |
| moonci 1.0 | `www.moonci.com` | L4 | 16.614s | 第二线两集MP4可读；第一线Range返回400。与xfdmneo共享已读媒体。[S-moonci] |
| mutefun 1.2 | `www.2kdm.com` | L0 | 未探站 | 声明防爬/验证码，跳过。[S-mutefun] |
| MXdm 2.4 | `www.dcc3.com` | L4 | 18.230s | 两作品的相邻两集HLS/首段前缀通过；第二作品一次连接失败，单次复测通过。首选。[S-MXdm] |
| sorani 1.0 | `www.sorani.net` | L0 | 未探站 | API模式、XPath空，native Kazumi未实现；已有独立sorani-api内置，不算新增。[S-sorani] |
| xfdmneo 1.1 | `dm1.xfdm.pro` | L4 | 11.321s | 两集MP4前缀及复测通过，前256KiB未见前置moov；不执行legacy iframe。[S-xfdmneo] |
| xfdmnext 1.1 | `next.xifanacg.com` | L0 | 未探站 | API模式、XPath空，API配置含Authorization字段；只做脱敏结构审查，不使用其中值。[S-xfdmnext] |

三条L4随后获得主线程W级记录，见第7节。403/404/超时/静态未提取均只是本机出口当次结果，不证明站点永久失效。[E1][N1]

## 6. 实现与故障修复

本轮先新增会失败的真实调用链回归，再做最小修复，未调整解码器缓存策略或创建隐藏播放器。

1. `E:/anime/lib/src/data/anime_controller.dart`：将按账号/作品保存的成功provider真正传入普通播放查询和查询模式入口；关闭记忆设置时不传偏好。此前UI能读取偏好，但冷启动查询没有消费。
2. `E:/anime/lib/src/data/playback_source_repository.dart`：记忆来源与预热备用来源使用“首条已验证可播线路”路径，仍执行清单/媒体检查；不再因为元数据补齐而等待站内全部线路。全量主动扫描路径保留。
3. `E:/anime/lib/src/playback/playback_discovery_controller.dart`：已通过客户端检测的下一集线路可在慢备用源完成前发布；最终缓存按记忆provider优先，最多保留主线+一条备用。账号/规则/后端作用域、取消、过期、强刷和迟到结果隔离保留。
4. `E:/anime/lib/src/player/playback_line_display.dart`：新鲜且已客户端验证的规则线路不在显示前重复探测；未经验证线路不因本次优化获得可播资格。
5. `E:/anime/lib/src/rules/bundled_kazumi_rules.dart`：固定上游提交的XPath转换为原生声明式规则，显式限制页面与媒体域；上游WebView标志不直接继承，因为本轮实际静态解析已能取出有效直链。原始规则快照不改写，防爬标志不绕过。

回归覆盖冷启动记忆、慢备用源不阻挡缓存、记忆provider不被较低延迟备用源替换、避免重复检测、首条可播线路竞速、迁移/卸载选择和双平台可执行状态。

## 7. 实际验收结果

样本为《葬送的芙莉莲》第1、2集；媒体URL/请求头仅在内存。以下来自最终真实线路发现/预热集成测试，不是网页HTTP计时。`打开到画面确认`还包含600ms以上时间推进与PNG截图确认，不能当精确解码首帧时刻。[N2]

| 来源 | 第一集查线 | 下一集预热 | 第二集查线 | 第二集缓存 | 第一/二集打开到画面确认 | 解码尺寸 |
| --- | ---: | ---: | ---: | --- | --- | --- |
| MX动漫 | 5393ms | 4620ms | 0ms | 命中 | 7646 / 7578ms | 1280×720 |
| 稀饭动漫 | 2888ms | 1962ms | 0ms | 命中 | 7097 / 6670ms | 1920×1080 |
| 月城动漫 | 3803ms | 2442ms | 0ms | 命中 | 6983 / 6915ms | 1920×1080 |

- 全量Flutter：**1159通过、26个既有跳过**；`flutter analyze`无问题。
- Windows真实PlayerPage本地生成媒体测试：首帧、暂停、定位/倍速、全屏返回，以及6次快速切集全部通过。这验证控件与切集流程，不替代外网稳定性测试。
- Windows主应用Debug构建通过；最终已恢复 `lib/main.dart` 目标，不把集成测试程序留作应用构建。
- Android Debug构建通过；没有连接设备，没有安装或覆盖用户现有应用。
- 仓库安全门禁、依赖门禁、此次修改文件格式检查及 `git diff --check` 通过。
- 双端构建产物内均确认存在KazumiRules MIT许可资产。[N3]

## 8. 剩余边界与后续验收

- **还不是秒开**：本次去除了重复查询/检测和错误等待；本机外网样本打开到画面确认仍约6–9秒，不代表用户所有网络都一样。
- 稀饭与月城共享CDN；MXdm提供另一媒体路径。不要在UI或发布文案中把3站写成3个独立媒体后端。
- 仅短时、有限作品和相邻集数验证，未验证整站片库、长播稳定性、所有地区与未来域名变更。新增CDN必须补证再最小扩权，不能用全域通配“修复”。
- Android真实验收还需设备连接后运行同一opt-in原生用例，覆盖首集、预热、相邻集、暂停/恢复；APK能编译不等于已播放。
- 正式发布另行遵守版本递增、精确HEAD、Quality Gates与manifest要求，本轮未执行发布。
- 未来接入iframe/API来源应另开受控适配，先审查公开接口与权限；不执行仓库中的未知脚本，不使用公开粘贴的Authorization值，不绕过验证码/登录/TLS。

## 9. 一手来源与本地证据

### 上游固定提交

- [S-readme] https://github.com/Predidit/KazumiRules/blob/fce5e15a2e6b57500912d41b3f1c65bb3eb7d392/README.md
- [S-repo] https://github.com/Predidit/KazumiRules
- [S-commit] https://github.com/Predidit/KazumiRules/commit/fce5e15a2e6b57500912d41b3f1c65bb3eb7d392
- [S-index] https://github.com/Predidit/KazumiRules/blob/fce5e15a2e6b57500912d41b3f1c65bb3eb7d392/index.json
- [S-license] https://github.com/Predidit/KazumiRules/blob/fce5e15a2e6b57500912d41b3f1c65bb3eb7d392/LICENSE
- [S-MXdm] https://github.com/Predidit/KazumiRules/blob/fce5e15a2e6b57500912d41b3f1c65bb3eb7d392/MXdm.json
- [S-xfdmneo] https://github.com/Predidit/KazumiRules/blob/fce5e15a2e6b57500912d41b3f1c65bb3eb7d392/xfdmneo.json
- [S-moonci] https://github.com/Predidit/KazumiRules/blob/fce5e15a2e6b57500912d41b3f1c65bb3eb7d392/moonci.json
- [S-7sefun] https://github.com/Predidit/KazumiRules/blob/fce5e15a2e6b57500912d41b3f1c65bb3eb7d392/7sefun.json
- [S-aafun] https://github.com/Predidit/KazumiRules/blob/fce5e15a2e6b57500912d41b3f1c65bb3eb7d392/aafun.json
- [S-AGE] https://github.com/Predidit/KazumiRules/blob/fce5e15a2e6b57500912d41b3f1c65bb3eb7d392/AGE.json
- [S-akianime] https://github.com/Predidit/KazumiRules/blob/fce5e15a2e6b57500912d41b3f1c65bb3eb7d392/akianime.json
- [S-baimao] https://github.com/Predidit/KazumiRules/blob/fce5e15a2e6b57500912d41b3f1c65bb3eb7d392/baimao.json
- [S-dalvdm] https://github.com/Predidit/KazumiRules/blob/fce5e15a2e6b57500912d41b3f1c65bb3eb7d392/dalvdm.json
- [S-DM84] https://github.com/Predidit/KazumiRules/blob/fce5e15a2e6b57500912d41b3f1c65bb3eb7d392/DM84.json
- [S-ezdmw] https://github.com/Predidit/KazumiRules/blob/fce5e15a2e6b57500912d41b3f1c65bb3eb7d392/ezdmw.json
- [S-giriGiriLove] https://github.com/Predidit/KazumiRules/blob/fce5e15a2e6b57500912d41b3f1c65bb3eb7d392/giriGiriLove.json
- [S-mgnacg] https://github.com/Predidit/KazumiRules/blob/fce5e15a2e6b57500912d41b3f1c65bb3eb7d392/mgnacg.json
- [S-mutefun] https://github.com/Predidit/KazumiRules/blob/fce5e15a2e6b57500912d41b3f1c65bb3eb7d392/mutefun.json
- [S-sorani] https://github.com/Predidit/KazumiRules/blob/fce5e15a2e6b57500912d41b3f1c65bb3eb7d392/sorani.json
- [S-xfdmnext] https://github.com/Predidit/KazumiRules/blob/fce5e15a2e6b57500912d41b3f1c65bb3eb7d392/xfdmnext.json

### 源码和脱敏验收

- [L1] `E:/anime/lib/src/rules/kazumi_rule_repository.dart`、`E:/anime/lib/src/rules/rule_importer.dart`。
- [L2] `E:/anime/lib/src/rules/rule_playback_resolver.dart`。
- [L3] `E:/anime/lib/src/rules/rule_models.dart`、`E:/anime/lib/src/rules/rule_security.dart`。
- [L4] `E:/anime/server/server/public_http.py`、`E:/anime/output/kazumi-validation-20261005/validate_rules.py`。
- [L5] `E:/anime/lib/src/rules/rule_plugin_repository.dart`、`E:/anime/lib/src/rules/bundled_kazumi_rules.dart`。
- [E1] `E:/anime/output/kazumi-validation-20261005/validation.json`及同目录`result-*.json`。
- [E2] `E:/anime/output/kazumi-validation-20261005/confirmation-MXdm-1dbb34bc.json`、`confirmation-MXdm-a9decc9d.json`、`confirmation-xfdmneo-a9decc9d.json`。
- [E3] `E:/anime/output/kazumi-validation-20261005/commit.json`、`rule-inventory.json`及`rules/`固定提交快照。
- [E4] `E:/anime/output/kazumi-validation-20261005/xfdmnext-review-redacted.json`、探针的脱敏输出逻辑与研究落盘检查。
- [N1] `E:/anime/output/kazumi-native-windows-20261005.log`：原生解析/播放第一轮。
- [N2] `E:/anime/output/kazumi-warmup-windows-20261005.log`、`E:/anime/output/kazumi-playback-summary-20261005.json`：最终缓存消费、解码帧字节与时间推进。
- [N3] `E:/anime/output/playback-full-suite-20261005.log`、`playback-native-ui-20261005.log`、`playback-analyze-20261005.log`、`kazumi-android-build-20261005.log`、`kazumi-windows-build-20261005.log`、`kazumi-repository-gate-20261005.log`、`kazumi-dependency-gate-20261005.log`。

日志与快照位于ignored output目录，不属于发布或遥测上传数据。后续复测必须显式开启原生联网测试；默认测试运行不访问这些站点。
