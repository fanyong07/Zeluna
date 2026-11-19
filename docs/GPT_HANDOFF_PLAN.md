# Zeluna 重构进度与 GPT 接续施工手册（番剧 · 剧集 · 电影三栖版）

> **当前工作分支**：`feat/stability-adclean-perf`
> **远端仓库**：`https://github.com/fanyong07/Zeluna.git`
> **适用对象**：后续接手本分支继续施工的 AI 开发者（GPT / Codex）与维护者。

---

## 一、施工铁律（接续开发必须严格遵守）

1. **只做当前工单明确要求的改动**，严禁顺手重构无关文件，严禁在全部工单真机验收前擅自修改 `pubspec.yaml` 版本号。
2. **严禁过度防御性编程**：
   - 优先做减法/简化现有链路，严禁为了修 Bug 再叠一层新的 Proxy / Bridge / Wrapper / Watchdog / Fallback 状态机。
   - **禁止**把普通公开媒体流重新改回默认走 Flutter UI 主 Isolate 本地 `NativeMediaBridge`（这会重新引发 Windows AB-BA 假死与 Android 掉帧）。
   - **禁止**把 `RuleUrlPolicy` 的 `RuleUrlPurpose.media` 改回静态硬编码 `mediaDomains` 白名单（只守住私网/回环 SSRF 阻断与跨站不泄露 Cookie/Authorization 底线即可）。
   - **禁止**重新引入每 400ms 调用 `player.screenshot()` 检测首帧。
3. **仓库卫生红线**：严禁在仓库中新增或提交任何临时调试脚本、快照压缩包或数据库（如 `_debug_*.py`、`.codex_tmp*`、`*.tar.gz`、`*.db`）。
4. **每次只完成 1 个工单并单独 commit**，提交前必须跑通该工单指定的 `flutter analyze` / `flutter test` / `uv run pytest -q`。

---

## 二、已完成工单与提交记录（已验证通过）

| 状态 | 工单 | Commit SHA | 核心改动摘要 | 验证结果 |
| :---: | :--- | :--- | :--- | :--- |
| ✅ | **工单 1**：Android 启动防卡死与闪退 | `5f00295` | 1. `SecureCloudAccountTokenStore` 全链路加 KeyStore 异常保护与 2s 超时；`AccountController.initialize()` 给 `restoreSession` 加 1.2s 冷启动超时与异常降级，绝不卡死/打崩冷启动。<br>2. `deferred_fonts.dart` 移动端跳过冷启动强加载 8.2MB 额外中文字体。<br>3. `AndroidManifest.xml` 开启 `android:largeHeap="true"`。<br>4. `poster_card.dart` 移动端 `BackdropArt` 移除大半径 `ImageFilter.blur(sigma=20)`。 | 40/40 Flutter 启动、账号、卡片性能测试全绿 |
| ✅ | **工单 2**：根治 Windows 假死 + `mpv` 秒开调优 | `dfa22e4` | 1. `NativeMediaTransport.prepare()` 默认对无 `Cookie`/`Authorization` 的公开直链直连 `mpv` 原生 C 层，彻底消除 Windows UI 主线程 AB-BA 死锁。<br>2. `NativeMediaBridge` 移除流转发循环中的逐块 `flush()`，并允许 m3u8 接收 gzip。<br>3. `NativeVideoController` 删除每 400ms `player.screenshot()` 首帧轮询，改用零开销监听视频 `width`/`height` + `position`。<br>4. 注入 `PlayerConfiguration(bufferSize: 64MB)` 与 `mpv` 秒开/抗弱网参数（`probesize=524288`、`analyzeduration=1.5`、`cache=yes`、`demuxer-max-bytes=64MiB`、`reconnect=1`、`http_persistent=1`、`http_multiple=1`）。 | 60/60 播放器与传输测试全绿 |
| ✅ | **工单 3 + 4（服务端）**：修复去广告 4 个 Bug + 升级国内片中广告孤岛清洗 + 解除并发锁 | `24d73cf` | 1. 修复 `AD_CARRIER_CACHE.record_manifest()` 仅查 `CUE-OUT` 且在 64KB 截断/Master 清单上误记 `False` 导致国内采集站 100% 跳过剪裁的 Bug。<br>2. 修复 `hls_clean.py` 的 `_absolute()` 误调 `to_fetch_url()` 将客户端 TS 分片写成本机 `127.0.0.1` 的 Bug。<br>3. 修复 `hls_clean.py` 拒收 `gzip` 及 `_parse()` 把段前 `#EXT-X-KEY` 错塞进 header 并吞掉非广告边界 `#EXT-X-DISCONTINUITY` 的 Bug。<br>4. 升级 **DISCONTINUITY 片中广告孤岛清洗**（2s~50s、异路径/异文件名骨架/异加密密钥）+ 50% 防误剪安全阀。<br>5. `PlaybackService._quick_refresh_semaphore` 放宽至默认并发 6；`ContentAggregator` 复用共享 `httpx.AsyncClient` 连接池；删除 `anich_transport.py` 重复的 `base` 属性。 | 103 + 81 服务端 pytest 全绿 |
| ✅ | **工单 4（客户端）+ 5a + 主题语义红** | `882d742` | 1. 新增纯 Dart 同构清洗器 `lib/src/player/video/hls_ad_cleaner.dart`（含完整单测 `test/hls_ad_cleaner_test.dart`）并接入 `NativeMediaBridge._rewritePlaylist()`。<br>2. 松绑 `lib/src/rules/rule_security.dart` 中 `RuleUrlPolicy.allows()` 的静态 `mediaDomains` 白名单（保留私网 SSRF 阻断与 `pageDomains` 隔离），立刻解放 CDN 频繁换域的活源。<br>3. 恢复 `lib/src/app/app_theme.dart` 的 `ColorScheme.error` 语义红。 | 34/34 Flutter 单测全绿 |

---

## 三、待 GPT 接续执行的剩余工单（严格按序推进）

### 工单 5b：盘活三栖社区热更新订阅 + 删除服务端僵尸 Kazumi + 清理线路列表噪音

- **目标**：让番剧（Kazumi/Animeko）和影视剧/电影（TVBox JSON / XBPQ / DRPY）都能通过远程订阅热更新获取活源，同时删掉服务端永远出不了流的 3,200+ 行僵尸 `kazumi.py`，隐藏线路面板里满屏的“未查询/停用”占位行。
- **施工要点**：
  1. 清理 `lib/src/rules/bundled_kazumi_rules.dart` 中因旧域名白名单限制被人为加上的 `unsupportedReason`，让客户端 `HeadlessInAppWebView` 嗅探正常接管。
  2. 检查并打通 `lib/src/rules/rule_importer.dart` 与 `SourceController`：
     - 支持一键订阅并定时刷新外部 JSON 规则库：番剧兼容 KazumiRules / Animeko JSON；**影视剧与电影兼容标准 TVBox JSON 配置（MacCMS JSON / XBPQ / DRPY-JS）**；
     - 导入订阅源时改为“订阅源级一次性确认”，不要逼用户对每条站点规则逐个点权限审批弹窗。
  3. 彻底删除服务端僵尸模块 `crawler.kazumi`：`server/server/scrapers/anime/kazumi.py`、`kazumi_rules.py`、`kazumi_rules_data/`、`server/tests/test_kazumi.py` 及 `aggregator.py` / `config.py` / `.env.example` 中的引用。
  4. 修改客户端线路列表展示（或 `server/server/playback_inventory.py`）：默认折叠/隐藏 `source_inventory_entry == true` 且状态为 `not_queried / source_disabled / retired / compatibility_inactive` 的灰色空占位行（仅在“诊断详情”里按需查看）。
- **验收**：`flutter analyze`、`flutter test`、`cd server && uv run pytest -q` 全绿。

---

### 工单 6：影视剧与电影搜索命中率翻倍（TMDB 多译名 / 年份 / 分季精准匹配）

- **目标**：解决电影（大陆/港台译名差异、同名不同年份）和多季电视剧（美剧/韩剧/国产剧“第2季 / 第二季 / S02”）经常搜不到或匹配错季的问题。
- **涉及文件**：`server/server/title_matching.py`、`server/server/aggregator.py`、`lib/src/rules/rule_playback_resolver.dart`。
- **施工要点**：
  1. 电影（`movie`）：别名搜索依次尝试 `[中文主名, 去冒号副标题短名, 原名/别名]`；打分强校验上映年份（±1 年内加分，相差 ≥3 年大幅扣分）。
  2. 剧集（`tv`/`series`）：中英文季号双向归一化（`第2季` / `第二季` / `Season 2` / `S02` 等价），严防将第 1 季资源错配给第 2 季；第 1 季同时兼容无季号标题。
  3. 增加简繁等价比对，提高港台站与字幕组命中率。
- **验收**：补充同名不同年份电影、副标题电影、中英文季号互转、简繁匹配单测，全绿。

---

### 工单 7：客户端本机并发 TTFB 竞速选线 + 纯净度三级分层 + 一键“标记有广告”

- **目标**：摆脱海外 VPS 测速误导；把纯净源永远排在硬压广告采集站前面；给用户一键避坑能力。
- **涉及文件**：新建 `lib/src/playback/local_route_ranker.dart`（~150 行），修改 `lib/src/playback/playback_discovery_controller.dart`、`lib/src/player/player_page.dart`。
- **施工要点**：
  1. 建立纯净度三级分层：
     - `Tier 0`：私有片库 / 直连无广告源 / Animeko / Kazumi 优质站 / 托管线路；
     - `Tier 1`：经 HLS 清洗器确认干净或未知新源；
     - `Tier 2`：已知含硬压跑马灯广告的采集站，或用户标记过“有广告”的源/域名（默认排最后并标“可能含内置广告”）。
  2. 本机并发 TTFB 竞速：同档取 Top 4 候选，在客户端本机并发发起轻量 `Range: bytes=0-4095`（超时 2.5s）测 TTFB，谁最快返回有效 200/206 且非 HTML 立刻交给播放器并取消其余请求；将本机 CDN host EMA 延迟持久化到 Hive。
  3. 播放器线路菜单新增“标记此线路有广告并换线”按钮：本地将该源/host 降权至 Tier 2（TTL 7 天，可清除），立即无缝切到下一条可用线路并保留进度。
  4. **对于命中清洗器且不需要转发视频字节的本地 HLS 源**：在客户端仅通过极简本地内存清单端点提供清洗后的 m3u8 文本（清单内所有 `.ts` / `.key` 保持原始公网绝对 URL，由 `mpv` 直连拉分片，**绝不代理视频字节**）。
- **验收**：`flutter analyze` + 新增 `test/local_route_ranker_test.dart` 与相关 playback 测试全绿。

---

### 工单 8：三栖终极零广告 4K 源（Emby / Jellyfin / WebDAV-Alist 私有媒体库直连）

- **目标**：一套轻量协议同时覆盖电影、剧集、番剧，直接复用现有 TMDB/Bangumi 详情页、弹弹play 弹幕和播放器，实现物理零广告 4K 秒开。
- **涉及文件**：新建 `lib/src/sources/media_library_adapter.dart`，接入 `PlaybackDiscoveryController` 与“设置 → 媒体源”。
- **施工要点**：
  1. 支持配置多个媒体库（Emby / Jellyfin / WebDAV-Alist），凭据存 `flutter_secure_storage`（带异常降级，不上传云同步）。
  2. Emby / Jellyfin：按 TMDB ID（`ProviderIds`）和标题直接查询并返回原画直连流（`/Videos/{id}/stream?static=true`），标为 `Tier 0`。
  3. WebDAV / Alist：支持 `PROPFIND` 列目录与本地索引缓存，按标准命名（`剧名.S01E01` / `电影名.2024`）匹配，返回带 Basic Auth 的直连流，标为 `Tier 0`。
  4. 直接复用 `package:http` 与 `package:xml`，不引入重型第三方 SDK。
- **验收**：补充适配器单测 + `flutter analyze` 全绿。

---

### 工单 9：仓库卫生大扫除 + 文档对齐 + 拆解巨型上帝文件

- **目标**：彻底清除历史 AI 残留垃圾文件，降低长期维护成本。
- **施工要点**：
  1. 清理未追踪的临时目录/文件（根目录 `.codex_tmp*`、非法文件名 `e:anime.codex_tmp_readme_check.txt`、`server/tools/_*.py`、`server/data/integration_release/*.tar.gz`），完善 `.gitignore` 防止 `*.db`、`*_probe_*.json`、`.codex_tmp*` 再次污染仓库。
  2. 更新 `README.md`，与当前单色主题、三栖能力与端云分工保持一致。
  3. 将 5,719 行的 `lib/src/rules/rule_playback_resolver.dart` 按职责拆分为多个清晰文件（单文件 ≤ 1,200 行，零行为变更）。
- **验收**：全量 `flutter analyze`、`flutter test`、`cd server && uv run pytest -q` 全绿。
