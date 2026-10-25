# 真人影视规则接入与验收（2026-10-06）

## 结论

本轮**新增两个可选规则，不新增默认启用源**：优质资源库、新浪资源。两者均通过电影及电视剧相邻两集的公开媒体链检测，但 Windows 完整播放/冷启动复测未达到默认启用标准。规则在列表中标为「可选 / 待实播复核」，不会在账号加载、刷新规则或新账号中自动安装、启用。

同时修复既有独播库规则：正确提取搜索标题、补全电视剧类别、仅补充实际验证的视频 CDN 域名。首次 Windows 电影/剧集实播及下一集预热通过；后续复测也出现网络超时，因此**不能称为持续稳定或秒开**。

本文件是主线程最终接入决策；`docs/live-action-rule-research-2026-10-05.md` 是此前研究子任务的 HTTP 阶段快照，关于「尚未接入」和「新浪止步加密清单」的描述仅代表当时阶段。初次探针目录保留 `20261005`，本次续验/决策日期采用会话客户端的 2026-10-06。

## 背景与目标

用户希望在已有 Kazumi 番剧规则之外补充真人电影和电视剧，而不是继续增加搜得到但播不了的来源。

目标：寻找公开、无需下载执行代码的来源；验证搜索、作品身份、集号、清单、媒体和原生播放；只有达到验收要求才纳入默认来源。已有线路记忆、预热、账号隔离和用户开关决定均保留。

## 范围和边界

- 只修改客户端规则声明、必要的 MacCMS 适配、匹配校验、回归/集成测试及本文档。
- 不改变 UI、播放器架构、网络安全策略、超时上限或原有缓存系统，不因测试失败拉长生产超时。
- 不提交/推送，不部署后端，不正式发布或安装新版本。`pubspec.yaml` 原有 `1.2.1+72` 不变；构建仅用于 Debug 验证。
- 不登录，不使用 Cookie、Authorization、私有凭据或破解解析；403/429/验证挑战止步，不降级 TLS。
- 不复制执行上游 JavaScript、JAR、Drpy；两条可选规则是独立编写的公开 API 适配。上游规则仓库许可未确认，没有复制其源码或整包分发配置。
- 只保存脱敏证据：host、状态、耗时、类别、集号、画面尺寸/时间推进。真实媒体 URL、签名、响应体、播放密钥和视频截图不落盘。

## 实际样本与结果

| 来源 | 样本 | HTTP 验证 | Windows 原生验收 | 最终处理 |
| --- | --- | --- | --- | --- |
| 独播库（既有） | 《流浪地球2》2023；《庆余年 第二季》2024 第1/2集 | 搜索、详情、页面、HLS、TS 前缀通过 | 首次三次均解码出画面；第二集预热命中。后续复测有超时/无首帧 | 保留既有默认策略及用户禁用决定，修正规则；不保证稳定 |
| 优质资源库（新增入口） | 《流浪地球》2019；《开端》2022 第1/2集 | 元数据、清单、64 KiB TS 前缀通过 | 完整电影+剧集首帧验收未通过；修复搜索适配后，直接解析电影可验证媒体，但耗时约15.8秒 | 可选、默认不安装/启用 |
| 新浪资源（新增入口） | 《流浪地球》2019；《开端》2022 第1/2集 | 元数据、HLS、正常公开 AES-128 identity 播放密钥、解码后 TS 前缀通过 | 多次视频 CDN 验证超时，未通过完整首帧验收 | 可选、默认不安装/启用 |

- 独播库首次成功记录：电影解析约3.6秒、打开到画面确认约5.6秒；电视剧第1集解析约2.7秒、画面约4.9秒；预热约2.4秒，第2集查线0毫秒、画面约5.2秒。这是单轮观察值，不是性能承诺。
- 后续快速查询与完整查询均保留失败记录；不以早期成功覆盖后期失败，不把 HTTP 200 或媒体前缀当原生成功。
- 优质与现有来源使用同族 `yzzy.play-cdn*`；新浪的媒体主机也已被爱看机器人使用。**新增的是直接查询入口，不能宣称增加两套独立媒体供应。**
- 未测试全片库、长时间连续播放、广告完整性、其他地域/VPS出口；页面标题/年份匹配不等于逐帧确认整片内容。
- Android 无连接设备：不能宣称真机播放通过。Windows 与 Android 构建/静态适配另见本文件的最终检查结果。

## 具体实现

### 1. 可选规则和权限

`lib/src/rules/bundled_live_action_rules.dart` 导出 `optionalLiveActionRules`，与 `_verifiedBuiltInRules` 分开收集。

| 规则ID | API 页面权限 | 媒体权限 | 特殊声明 |
| --- | --- | --- | --- |
| `zeluna:recommended:youzhi` | `api.yzzy-api.com` | `yzzy.play-cdn17.com`, `yzzy.play-cdn9.com` | `searchAction=list` |
| `zeluna:recommended:sina` | `api.xinlangapi.com` | `play.xluuss.com`, `g.xlzyd.com` | `searchAction=detail`，公开 `xlm3u8` 接口 |

两者 `installedByDefault=false`，仅声明 `movie/series`；无 WebView、JS、Cookie 和明文 HTTP。媒体权限不授予页面权限，不允许通配符及未经审查的同族域。新 CDN 需要重新审核，不自动扩权。规则的本地 official 标记只表示本项目审查的声明，不是站点品牌官方背书或稳定性认证；从 JSON 导入仍降级为 untrusted 并需正常审批。

### 2. 独播库修复

- 旧 XBPQ 搜索截取整个卡片的第一个链接，会得到评分/集数而非作品标题；改为只截取 `<h4 class="title">` 标题块。
- `contentTypes` 从 `movie` 补为 `movie/series`，不纳入番剧查源。
- 增加精确媒体域 `vid.dbokutv.com`，不扩大页面权限。
- 单元测试复现修复前的三个失败：未参与剧集查询、电影卡片解析失败、剧集卡片解析失败；修复后通过。

### 3. 通用 MacCMS 小范围适配

- 原引擎只用 `ac=detail/videolist` 搜关键词，优质只支持 `ac=list`。新增声明式 `searchAction`，仅接受 `list/detail/videolist`；未指定仍保持原有两种请求策略。
- 优质按 `list` 搜索后按条目 ID 查详情；新浪只发已确认的 `detail` 搜索，避免无意义重复查询。
- 真人匹配在可用元数据中核对年份和电影/剧集类型，并排除解说、预告、花絮等；详情响应再核对请求 ID 与身份，不能任取首项后请求错误视频。
- 缺失年份/类别的旧接口继续兼容，不声称缺数据时也能可靠识别所有同名翻拍。番剧评分策略不变。

## 回归与复验方法

- `test/dbku_rule_playback_test.dart`：真实卡片结构的合成 fixture、正确剧季/集号、媒体域及电影/电视剧参与度。
- `test/bundled_live_action_rules_test.dart`：Windows/Android 声明式执行能力、默认不安装/启用、精准权限、导入信任降级、list-only API、同名类别/年份和详情防误配。
- `test/source_controller_test.dart`：候选不自动迁移，只有显式安装才启用；账号切换、禁用、卸载和重新加载不反转用户选择。
- `integration_test/live_action_playback_test.dart`：需 `LIVE_ACTION_VALIDATION=true` 主动开启；隔离账号/缓存、实际解析器与播放器；电影和连续两集必须真实解码截图到内存、时间推进，第二集必须命中已就绪预热。失败仍失败，不跳过失败源凑数。
- 可用 `LIVE_ACTION_RULE=<规则ID>` 限定来源；`LIVE_ACTION_FULL_DISCOVERY=true` 单独验证完整查询。证据标记 quick/full/warmup，不混报为快速查询。
- Windows 集成测试会替换 Debug 启动目标；结束后必须以 `lib/main.dart` 恢复主应用构建。

## 默认启用的后续验收门槛

只有完成以下步骤才可把可选规则改为默认启用：

1. 重新验证电影及连续剧两集，确认年份、类型、集号及精确媒体/密钥主机。
2. Windows 正常查源路径在既有时限内返回可播放线路，三次样本均实际出画面、时间推进。
3. 下一集预热能成功，并保留记忆的 provider；不能依靠拉长全局时限或绕过媒体验证。
4. Android 真机执行同一流程；当前没有真机证据。
5. 至少在不同时间复测，保留失败记录，确认不是仅一次偶然成功。实播失败时继续保持默认关闭。
6. 若要发布，另遵守 AGENTS.md 的版本递增、精确 HEAD、门禁、manifest 和命名要求。

## 最终检查结果

- 格式检查：302个文件，0改动，通过。
- 静态分析：0问题。首次终检发现 ignored 诊断脚本的2处 `print` 提示，改为 `debugPrint` 后重跑通过，不关闭检查。
- 全量 Flutter 单元/组件测试：**1172通过，26跳过**。先前唯一失败是类别数量仍断言旧值；按最终策略同时断言「规则可见」和「候选默认不启用」后全量重跑通过。
- 仓库安全门禁与依赖策略门禁：通过（159 Dart、72 Python依赖）。
- Windows Debug：`lib/main.dart` 主应用目标构建通过，已恢复，不留下集成测试作为启动入口。
- Android Debug APK：构建通过；`adb devices` 无设备，**真机播放未验证**。
- `git diff --check`：通过。未提交、未推送、未部署，未修改既有版本号，既有UI和上一轮播放改动保留。
- **在线 Windows 六个电影/剧集验收用例的后续完整矩阵仍失败**。离线回归/构建通过不能覆盖此失败；两个新候选保持默认不安装/启用。

## 证据索引与来源

- 研究快照和固定上游配置定位：`docs/live-action-rule-research-2026-10-05.md`。
- 本地证据目录：`output/live-action-validation-20261005/`（已忽略，不提交）。
- HTTP：`research/result-youzhi.json`、`sina-public-hls/result-sina.json`、`dbku-media.json`。
- 原生早期成功：`dbku-native-windows.log`；后续失败：`final-native-windows.log`、`adapted-native-windows.log`；适配后直接解析诊断：`adapter-direct-diagnostic.log`。
- 单测修复前后：`dbku-before.log`、`dbku-after.log`、`identity-before.log`、`identity-after.log`、`final-focused.log`。
- 最终门禁及构建：`final-checks.json` 和 `final-*.log`。
- 公开规则声明（仅发现入口，未复制源码）：https://github.com/hd9211/Tvbox1/blob/9766d3045e3345aad84ce73fdbe23102159a059e/zy.json ，优质 `/sites/47`，新浪 `/sites/38`。
- 新浪站方 HTTPS 直连入口声明：https://xinlangzy.cc/index.php/help/index.html 。
- 其他候选：闪电403即停、淘片连接/TLS失败、金鹰止于原探针的保守加密边界；不将这些不同情况统一标作「永久失效」。PPnix有媒体清单但本轮未完成客户端专用适配；泥视频一次搜索超时也不能据此认定关站。
