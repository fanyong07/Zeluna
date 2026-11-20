# Zeluna 重构进度与交付清单（番剧 · 剧集 · 电影三栖版）

> **当前工作分支**：`feat/stability-adclean-perf`
> **远端仓库**：`https://github.com/fanyong07/Zeluna.git`
> **当前状态**：全部 9 个规划工单及代码审查后的可用性/稳定性加固已**全部完成并全量验收通过**。

---

## 一、全量验收门禁结果（当前 HEAD 实测）

| 检查项 | 命令 | 结果 |
| :--- | :--- | :--- |
| Dart / Flutter 静态分析 | `flutter analyze` | **0 issues** ✅ |
| Flutter 全量单元测试与组件测试 | `flutter test` | **1,340 passed / 0 failed**（28 skipped）✅ |
| 服务端全量测试 | `cd server && uv run pytest -q` | **1,121 passed / 0 failed**（311 subtests passed）✅ |

---

## 二、全部工单与提交记录

| 状态 | 工单 | Commit SHA | 核心改动摘要 |
| :---: | :--- | :--- | :--- |
| ✅ | **工单 1**：Android 启动防卡死与闪退 | `5f00295` | `SecureCloudAccountTokenStore` 全链路 KeyStore 异常保护与 2s 超时；`AccountController.initialize()` 1.2s 启动超时降级；移动端跳过 8.2MB 额外字体冷启动强加载；开启 `android:largeHeap="true"`；移动端移除 `ImageFilter.blur(sigma=20)`。 |
| ✅ | **工单 2**：根治 Windows 假死 + `mpv` 秒开调优 | `dfa22e4` | `NativeMediaTransport.prepare()` 默认对公开直链直连 `mpv` 原生 C 层；`NativeMediaBridge` 移除逐块 `flush()` 并允许 m3u8 gzip；删除每 400ms `player.screenshot()` 轮询；注入 `64MB` 缓冲与 `probesize`/`analyzeduration`/`reconnect`/`http_persistent` 等秒开参数。 |
| ✅ | **工单 3 + 4（服务端）**：去广告修复 + 片中广告清洗 + 并发解耦 | `24d73cf` | 修复 `AD_CARRIER_CACHE` 误短路、`hls_clean` `127.0.0.1` 泄漏、拒收 gzip、段前 `#EXT-X-KEY` 错位与吞 `DISCONTINUITY`；升级国内采集站片中广告孤岛清洗 + 50% 防误剪安全阀；验证并发提至 6；`ContentAggregator` 复用共享 `httpx.AsyncClient` 连接池。 |
| ✅ | **工单 4（客户端）+ 5a + 主题语义红** | `882d742` | 新增客户端同构清洗器 `lib/src/player/video/hls_ad_cleaner.dart`；松绑 `RuleUrlPolicy` 静态 `mediaDomains` 白名单（保留私网 SSRF 阻断与 `pageDomains` 隔离）；恢复 `ColorScheme.error` 语义红。 |
| ✅ | **工单 5b**：清僵尸 Kazumi + 复活 WebView 源 + 折叠占位源 | `36dad9a` | 删除服务端永远出不了流的 90 个僵尸 Kazumi 文件（净删 5,689 行）；复活客户端 `kazumi:xfdmneo`/`kazumi:moonci` WebView 嗅探；`player_panels.dart` 折叠未查询/未启用/未接入候选占位源至 `ExpansionTile`。 |
| ✅ | **工单 6**：影视剧 & 电影精准匹配升级 | `f2921a7`、`94b73c7` | `title_matching.py` 新增简繁归一、中文/英文季号标准归一（`s<N>`，不串季）及冒号/破折号副标题短主名兜底；同步对齐全部服务端与客户端旧测试断言。 |
| ✅ | **工单 7 + 7b**：本机纯净度分级、测速竞速、持久化与规则订阅 | `9423955`、`05edbbc`、`1b437b1` | `LocalRouteRanker` 实现 Tier 0/1/2 纯净度分级、本机 host EMA 速度记忆与 7 天 TTL 广告降权，持久化到 Hive settings box；接入同级 Top-4 并发 `Range` 竞速与一键「标记有广告并换线」；支持 Kazumi `index.json`（上限 256，支持安全公网重定向并跳过单个 404 坏文件）、Animeko、TVBox 整组订阅确认与按账号定时刷新。 |
| ✅ | **工单 8**：三栖零广告 4K 私有媒体库（Emby / Jellyfin / WebDAV-Alist） | `3372445`、`a63afee` | 新增 `media_library_adapter.dart` 与「设置 → 媒体源」页面，凭据仅存系统安全存储不上传云端；支持局域网 HTTP 与 HTTPS、Emby/Jellyfin 账号密码登录（仅存访问令牌与 `userId`）及 API 密钥、匿名 WebDAV、配置前「测试连接」；`NativeMediaBridge` 放行剥离凭据后的公网 CDN 302 重定向（全面支持 Alist 网盘 302 与 Emby 302，同时继续拦截私网 SSRF）；WebDAV 6 路并发扫描 + 目录/字幕组/中文集数/电影目录智能匹配；私有库与在线查线并发启动消除 750ms 串行等待。 |
| ✅ | **工单 9**：拆解巨型上帝文件 + 文档对齐 + 仓库大扫除 | `75b3de2` | 将 5,425 行的 `lib/src/rules/rule_playback_resolver.dart` 拆为主文件 536 行 + `lib/src/rules/playback_resolver/` 下 8 个职责清晰的 `part` 模块（单文件 ≤ 1,081 行）；对齐 `README.md` 与 `.gitignore`；清理根目录及 `server/` 下所有历史临时调试垃圾。 |

---

## 三、施工红线（后续维护持续遵守）

1. **禁止过度防御性编程**：不要把普通公开媒体流重新改回默认走 Flutter UI 主 Isolate 本地 `NativeMediaBridge`；不要把 `RuleUrlPolicy` 的 `RuleUrlPurpose.media` 改回静态硬编码 `mediaDomains` 白名单；不要重新引入 400ms `player.screenshot()` 轮询。
2. **版本发布规范**：严格遵守仓库根目录 `AGENTS.md`；真机验收并确认分支基线后再统一递增 `pubspec.yaml` 版本号与 `+build`。
3. **分支基线提示**：远端存在较新的 `v1.4.0`（`dd78583`，含 Android 应用内更新与 vendored `third_party/media_kit`），本分支基于较早的 `v1.2.13` 演进；合入主线发版前需做一次专门的合并集成与真机回归。
