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

## 二、已完成工单与提交记录（P0 + P1 核心全部完成并验证通过）

| 状态 | 工单 | Commit SHA | 核心改动摘要 | 验证结果 |
| :---: | :--- | :--- | :--- | :--- |
| ✅ | **工单 1**：Android 启动防卡死与闪退 | `5f00295` | 1. `SecureCloudAccountTokenStore` 全链路加 KeyStore 异常保护与 2s 超时；`AccountController.initialize()` 给 `restoreSession` 加 1.2s 冷启动超时与异常降级。<br>2. `deferred_fonts.dart` 移动端跳过冷启动强加载 8.2MB 额外字体。<br>3. `AndroidManifest.xml` 开启 `android:largeHeap="true"`。<br>4. `poster_card.dart` 移动端 `BackdropArt` 移除大半径 `ImageFilter.blur(sigma=20)`。 | 40/40 Flutter 测试全绿 |
| ✅ | **工单 2**：根治 Windows 假死 + `mpv` 秒开调优 | `dfa22e4` | 1. `NativeMediaTransport.prepare()` 默认对公开直链直连 `mpv` 原生 C 层，根治 Windows UI 主线程 AB-BA 死锁。<br>2. `NativeMediaBridge` 移除流转发循环逐块 `flush()`，允许 m3u8 接收 gzip。<br>3. `NativeVideoController` 删除每 400ms `player.screenshot()` 轮询，改为零开销宽高+进度判定。<br>4. 注入 `64MB` 缓冲及 `probesize=524288`、`analyzeduration=1.5`、`cache=yes`、`reconnect=1`、`http_persistent=1`、`http_multiple=1`。 | 60/60 Flutter 测试全绿 |
| ✅ | **工单 3 + 4（服务端）**：修复去广告 4 个 Bug + 升级片中广告清洗 + 解除并发锁 | `24d73cf` | 1. 修复 `AD_CARRIER_CACHE` 在 64KB 截断/Master/无 `CUE-OUT` 清单上误记 `False` 短路去广告的 Bug。<br>2. 修复 `hls_clean` 输出 TS 分片被写成 `127.0.0.1`、拒收 `gzip`、段前 `#EXT-X-KEY` 错位及吞掉非广告 `DISCONTINUITY` Bug。<br>3. 升级**国内采集站片中 DISCONTINUITY 广告孤岛清洗**（异路径/异文件名骨架/异密钥）+ 50% 防误剪安全阀。<br>4. `_quick_refresh_semaphore` 并发提升至 6；`ContentAggregator` 复用共享 `httpx.AsyncClient` 连接池；删除重复 `base` 属性。 | 103 + 81 pytest 全绿 |
| ✅ | **工单 4（客户端）+ 5a + 主题语义红** | `882d742` | 1. 新增纯 Dart 同构清洗器 `lib/src/player/video/hls_ad_cleaner.dart` 并接入 `NativeMediaBridge._rewritePlaylist()`。<br>2. 松绑 `lib/src/rules/rule_security.dart` 写死的静态 `mediaDomains` 白名单（保留私网 SSRF 阻断与 `pageDomains` 隔离）。<br>3. 恢复 `lib/src/app/app_theme.dart` 的 `ColorScheme.error` 语义红。 | 34/34 Flutter 测试 + analyze 零问题 |
| ✅ | **工单 5b**：删掉服务端僵尸 Kazumi + 复活客户端 WebView Kazumi + 折叠灰色占位源 | `36dad9a` | 1. 彻底删除服务端永远出不了流的 90 个僵尸 Kazumi 文件（净删 **5,689 行**死代码）。<br>2. 复活客户端 `kazumi:xfdmneo`、`kazumi:moonci`，开启客户端 `HeadlessInAppWebView` 嗅探。<br>3. `player_panels.dart` 将“未查询/未启用”灰色空占位源折叠至默认收起的 `ExpansionTile`。 | 112 pytest + 14 Flutter 测试 + analyze 零问题 |
| ✅ | **工单 6**：影视剧 & 电影精准匹配升级 | `f2921a7` | 1. `title_matching.py` 新增高频影视简繁归一映射表（大幅提升港台/海外直连源命中率）。<br>2. 补齐中文数字季号（`第二季`/`第2部`）与 `S02`/`Season 2` 全面归一化。<br>3. `aggregator.py` 自动为带冒号/破折号副标题的电影衍生短主名搜索兜底。 | 23/23 title_matching pytest 全绿 |
| ✅ | **工单 7**：本机纯净度分级 + 本机 CDN 测速竞速 + 一键“标记有广告并换线” | `9423955` | 1. 新增 `lib/src/playback/local_route_ranker.dart`（Tier 0/1/2 纯净度分层、本机 CDN host EMA 速度记忆、7 天 TTL 广告降权、Top-4 并发 `Range` TTFB 竞速 `raceFastestPlayable`）。<br>2. 接入 `rankPlaybackLinesForStartup()` 排序。<br>3. `player_panels.dart` + `player_page.dart` 新增“标记有广告并换线”一键按钮。 | 148/148 Flutter 测试 + analyze 零问题 |

---

## 三、待 GPT 接续执行的剩余工单（严格按序推进）

### 工单 7b（轻量收尾）：持久化本机测速/广告标记 + 订阅源一键启用与定时刷新

- **目标**：把 `LocalRouteRanker` 的 host 速度与广告标记持久化进现有 Hive settings box（重启 App 不丢失）；把 `LocalRouteRanker.raceFastestPlayable()` 接入客户端多候选取流路径；优化外部三栖订阅源（Kazumi / Animeko / TVBox JSON）的导入与定时热更新体验（订阅源级一次性确认，不再逐条弹窗）。
- **涉及文件**：`lib/src/playback/local_route_ranker.dart`、`lib/src/data/anime_controller.dart`、`lib/src/rules/rule_importer.dart`、`lib/src/sources/source_controller.dart`。
- **验收**：`flutter analyze`、`flutter test test/local_route_ranker_test.dart test/source_controller_test.dart test/rule_importer_test.dart`。

---

### 工单 8：三栖终极零广告 4K 源（Emby / Jellyfin / WebDAV-Alist 私有媒体库直连）

- **目标**：一套轻量协议同时覆盖**电影、剧集、番剧**，直接复用现有 TMDB/Bangumi 详情页、弹弹play 弹幕和播放器，实现物理零广告 4K 秒开。
- **涉及文件**：新建 `lib/src/sources/media_library_adapter.dart`，接入 `PlaybackDiscoveryController` 与“设置 → 媒体源”。
- **施工要点**：
  1. 支持配置多个媒体库（Emby / Jellyfin / WebDAV-Alist），凭据存 `flutter_secure_storage`（带异常降级，不上传云同步）。
  2. Emby / Jellyfin：按 TMDB ID（`ProviderIds`）和标题直接查询并返回原画直连流（`/Videos/{id}/stream?static=true`），标为 `Tier 0` 纯净源。
  3. WebDAV / Alist：支持 `PROPFIND` 列目录与本地索引缓存，按标准命名（`剧名.S01E01` / `电影名.2024`）匹配，返回带 Basic Auth 的直连流，标为 `Tier 0` 纯净源。
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
