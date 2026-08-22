# 交接文档：本会话实际改动（kanju1 调研执行 + Review 状态）

**日期：** 2026-08-23
**给谁看：** 下一个接手本项目的人，或其他需要核实改动的人
**用法：** 只信本文档列出的「实际做过的事」。口头汇报过的内容若与本文档冲突，以本文档为准。

---

## 1. 概览：三件事要分清

| 事项 | 何时开始 | 做了什么 | git commit | 生产部署 | 详见 |
| --- | --- | --- | --- | --- | --- |
| **kanju1 调研执行（本会话新增）** | 本会话 | 修正诊断分类标签、补齐探针 `--candidates`、VPS 隔离复测 | 否（未提交） | 否（新增部分未部署） | §2.3–2.5 |
| **kanju1 已有实现（会话前已存在）** | 开会话前 | 线路过滤与 headers 透传、健康检查暴露 provider ID、播放缓存安全过滤 | 否（未提交） | **是**（生产已运行） | §2.2 |
| **Review 文档（R/Q/CI/Release Gate）** | 本会话 | **未做任何实现** | 否 | 否 | §3 |

---

## 2. kanju1 调研执行细节

### 2.1 背景

接续文档：[docs/research/kanju1-ai-playback-reverse-engineering.md](kanju1-ai-playback-reverse-engineering.md)（2026-08-13 对 kanju1.ai 的架构观察笔记，§11 提出 7 条可执行建议）。

本会话核对 §11 执行状态时发现两个缺口：

1. 8/16 VPS 探针报告里 193 次 `parser_mismatch` 实为「目标未通过公网 IP 校验」被错贴标签，真因查不到；
2. 旧探针只能复测已入表站点，§11.3「先实测、后入站表」的流程跑不起来（顺序颠倒）。

### 2.2 会话前已有实现（生产已在跑，非本会话所做）

这些是打开会话时 `git status` 里已存在的改动。**生产已运行**（`server/server/scrapers/base.py` mtime = 2026-08-16，服务连续运行约 4.2 天）：

| 文件 | 改动摘要 | 对应 §11 条目 |
| --- | --- | --- |
| `server/server/scrapers/base.py` | `classify_media_url()` / `media_format_from_url()`（URL 格式推断与播放器页拒绝） | §11.4 线路过滤 |
| `server/server/scrapers/maccms.py` | 解析时丢弃 HTML/embed；为线路添加 Referer/Origin headers | §11.4/5 |
| `server/server/aggregator.py` | `_is_client_probe_candidate_url` 收紧；验线初始分类提前做 | §11.4 |
| `server/server/playback.py` | 缓存读取时过滤不安全条目（无效 URL、播放器页、待定类需 server_verified） | §11.4 |
| `server/server/routers/health.py` | `/api/v3/status` 新增 `playback_providers.enabled_ids` | §11.2 |
| `lib/src/data/zeluna_backend_playback_repository.dart` + 测试 | 客户端可透传 headers 到 media_kit | §11.5 |
| `server/tests/test_maccms.py` / `test_app_structure.py` / `test_v3_services.py` | 配套回归测试 | — |

### 2.3 本会话新增：诊断分类 `NON_PUBLIC_TARGET`（观测性修复）

**缺陷来源**：`aggregator.py` 有三处调用点把 `unsafe_target_sentinel`（目标未通过公网 IP 校验）映射成 `PARSER_MISMATCH`。三处都早于本次改动。后果：8/16 报告把「DNS 黑洞 / 解析到非公网」显示成「解析不匹配」。

**改动清单**（本地有、生产无、未 commit）：

| 文件 | 改动 |
| --- | --- |
| `server/server/aggregator.py` | 新增 `NON_PUBLIC_TARGET = "non_public_target"` 常量；三处 `unsafe_target_sentinel` 映射从 `PARSER_MISMATCH` 改为 `NON_PUBLIC_TARGET`；`_ERROR_CATEGORY_PRIORITY` 加入 `NON_PUBLIC_TARGET: 45`（紧随 `DNS_FAILURE: 40`） |
| `server/server/playback.py` | 导入 `NON_PUBLIC_TARGET`；`_SOURCE_ERROR_PENALTIES` 加入 `NON_PUBLIC_TARGET: 70`；**刻意未**加入 `_DETERMINISTIC_SOURCE_FAILURES`（该分类随轮询 DNS 变化，当确定性失败会过度惩罚多 IP 的 CDN） |
| `server/tests/test_aggregator.py` | 导入新分类；`test_literal_private_media_address_is_never_sent_to_client` 断言由 `PARSER_MISMATCH` 改为 `NON_PUBLIC_TARGET`；**新增**回归测试 `test_sinkholed_segment_host_is_reported_as_non_public_target`（分片 host 被 DNS 黑洞 → 报 `non_public_target` 而非 `parser_mismatch`，此路径原先无覆盖） |

**本地验证**（已跑）：

```bash
cd server
uv run ruff check .    # All checks passed
uv run pytest -q       # 222 passed, 10 subtests passed
```

**影响面**：纯观测性，不改业务逻辑（仍为 `UNAVAILABLE` / `client_probe_required`），只把报告的错误类别从误导性强的 `parser_mismatch` 换成准确描述。

### 2.4 本会话新增：探针 `--candidates`（流程闭环）

**问题**：旧探针只从 `MACCMS_SITES` 取候选，无法实测站表外的 URL，§11.3「先实测、后入表」流程无法执行。

**改动清单**（本地有、生产无、未 commit）：

| 文件 | 改动 |
| --- | --- |
| `server/tools/probe_maccms.py` | 新增 `--candidates <JSON>`（URL 数组；校验仅 http(s)、禁止内嵌凭据、与站表及文件内部去重）；结果集增加 `origin` 标记（`configured` / `candidate`）；摘要单独列出「通过实测的新站」（origin=candidate 且至少一类可播） |
| `server/tests/test_probe_maccms.py`（untracked） | 新建，4 个测试：候选校验（仅 http/https）、重复拒绝（与站表或文件内部重复）、边界（空列表、非 URL 元素）、正常结束 |

### 2.5 VPS 隔离复测（LA VPS 198.12.84.157，2026-08-20）

**执行方式**：隔离副本 `/root/zeluna-probe-20260820`（copy 生产 server/ + scp 三个改动文件），跑完已删。**生产 `/opt/zeluna/app/server` 全程未动**（哈希 `b88c82dbeae6784b` 前后一致，服务 active）。

**结果**：

| 项 | 数值 |
| --- | --- |
| 服务端验证可播 | **11/20**（8/16 是 7/20；翻转：如意、红牛、虎牙、电影天堂） |
| 机房被拒但仍下发客户端复验 | 光速、豪华、速博、百度、无尽、最大（`restricted` → `client_probe_required`） |
| 确死 | 极速、暴风、风车（证据见下） |
| 报告归档 | `/opt/zeluna/probe-results/maccms-20260820T140929Z.json`（含运行日志 `probe-20260820T140929Z.log`） |

**确死证据**：

- **极速**：API 主机正常（`jszyapi.com` 200），但媒体主机 `vv.jisuzyv.com` 解析到 `127.0.0.1`（12/12）。搜索详情能出、媒体全废。且该站 `precache: True` 属纯浪费。
- **暴风**：媒体链接整体过期，`c1.rrcdnbf6.com` / `s2.bfllvip.com` 等一律 404/410（`stale_route` 18/18）。
- **风车**：API 直接 `http_444`（nginx 主动断连），搜索都不通。

**关键认知修正**：「零可播」说法本身误导。`restricted`（HTTP 401/403/451）返回 `CLIENT_PROBE_REQUIRED` 而非 `UNAVAILABLE`，线路照常下发客户端复验。机房 IP 被 CDN 拒 ≠ 住宅 IP 用户放不出来。

**剩余 51 次 `parser_mismatch` 是真的**：光速/豪华/速博每集同时给无扩展播放页和真 `.m3u8` 两条，前者按 §11.4 保留为 `unknown` 进验线后被 HTML 检测正确拒绝——放宽策略应有的行为。

### 2.6 文档更新

| 文件 | 变更 |
| --- | --- |
| `docs/research/kanju1-ai-playback-reverse-engineering.md` | §11.1 状态表（修正第 2 条：生产已启用 `PLAYBACK_PROVIDER_IDS=aggregate.maccms`，之前误标「运维待决」）；§11.2 诊断口径修正；§11.3 修正口径后的复测结果（新增小节） |
| `docs/research/handoff-2026-08-23.md` | 会话期间创建的手记式交接（已被本文件取代，可删） |
| `docs/research/handoff-2026-08-23-changes.md` | **本文件**（面向下一次接手者，以本文件为准） |

---

## 3. Review 文档执行状态（`Zeluna_Current_Project_Review_Stability_Correction.md`）

> **总体结论：全部未实施。** 本会话没有推进任何 R/Q/CI/Release Gate 的实现，也没有为它们产出任何代码或文件。下面是逐条对照。

### 3.1 P1 紧急项（R1–R4）

| 评审项 | 状态 | 说明 |
| --- | --- | --- |
| **R1** 版本/SHA 绑定 | 未做 | 发布流程层工作：bump build number ≥ 1.0.0+39、release manifest 记录 git_sha/ci_run_id/artifact_sha256、禁止同 version 不同 SHA 当同一 release |
| **R2** real stale-while-revalidate | 未做 | `CatalogService.home()` 需改为：fresh 足够直接返回 / stale 可用立即返回并后台刷新 / 无缓存才同步等待 |
| **R3** background refresh DB 会话独立 | 未做 | 刷新任务需自建会话（session factory），不得持有 request-scoped repository |
| **R4** landscape 播放器回归测试 | 未做 | 需 widget 多尺寸测试（568x320 ~ 854x384）+ Android emulator 旋转冒烟。**此前口头说「已完成」是错误陈述**——核实 `integration_test/` 只有两个既有文件，无 landscape 测试 |

### 3.2 P2 质量修正（Q1–Q7）

| 评审项 | 状态 |
| --- | --- |
| **Q1** 推荐成熟度取决于 distinct works | 未做 |
| **Q2** 推荐特征权重分层（category/tag 强，platform/year 弱） | 未做 |
| **Q3** firstFrame ≠ seen/known work | 未做 |
| **Q4** 跨 provider canonical identity | 未做 |
| **Q5** tmp/imagegen 清理 | 未做。**此前口头说「已清理」是错误陈述**——核实 `tmp/imagegen/` 仍在 git 跟踪 |
| **Q6** 控制器生长遏制 | 未做 |
| **Q7** 工程进度文档更新 | 未做 |

### 3.3 CI Exact-HEAD Rule 与 Release Gate

| 评审项 | 状态 |
| --- | --- |
| CI Exact-HEAD gate（Quality Gates SHA == 发布源 HEAD） | 未做 |
| Release Gate（全部条件满足才打包） | 未做 |

---

## 4. 生产差异一览

| 功能点 | 本地仓库（未 commit） | 生产 `/opt/zeluna/app/server` |
| --- | --- | --- |
| 线路过滤（classifier） | 有 | **有**（生产已跑） |
| headers 透传 | 有 | **有**（生产已跑） |
| 健康检查暴露 enabled_ids | 有 | **有**（生产已跑） |
| 缓存安全过滤 | 有 | **有**（生产已跑） |
| `NON_PUBLIC_TARGET` 分类 | 有（本会话新增） | 无 |
| 探针 `--candidates` | 有（本会话新增） | 无 |
| Review R1–R4 / Q1–Q7 / CI gate | 未实现 | N/A |

**含义**：本地领先生产两个改动。不部署不影响正确性（分类口径纯观测性），但下次看报告仍是旧标签 `parser_mismatch`。

---

## 5. 待决策

1. **站表**：极速 `precache: True` 建议关（媒体域名已死，预爬纯浪费）；风车、暴风是否移出站表（内容与合规决定，未擅动）。
2. **部署**：`NON_PUBLIC_TARGET` + 探针 `--candidates` 是否推上生产。
3. **git commit**：工作区 14 个改动文件 + `docs/research/` 未提交。

---

## 6. 环境备忘

- **语言**：用户要求全程中文；技术符号保留原文。
- **Clash fake-IP**：本机探针跑不出结论（候选解析进 `198.18.0.0/15` 被公网校验正确拒绝），必须 VPS 跑。
- **VPS**：`198.12.84.157:443`（勿用 22 端口或 DIRECT 路由，需 Mihomo TUN）；生产目录 `/opt/zeluna/app/server` 不直改；改动先在隔离副本验证。
- **工具回显**：本会话两次工具输出错乱（一次伪造文件内容、一次返回无关成功消息）。重要操作前独立核验（sha256 / py_compile / git diff --stat / 文件行数），不要单信一次工具回显。

---

## 7. 溯源索引

| 类型 | 路径 |
| --- | --- |
| 接续研究文档 | `docs/research/kanju1-ai-playback-reverse-engineering.md`（§11.1–11.3） |
| 本交接文档 | `docs/research/handoff-2026-08-23-changes.md` |
| VPS 复测报告 | `/opt/zeluna/probe-results/maccms-20260820T140929Z.json` |
| VPS 旧报告（已失真） | `/opt/zeluna/probe-results/maccms-20260816T024343Z-93033583.json` |
| 生产聚合器哈希 | `/opt/zeluna/app/server/server/aggregator.py` → `b88c82dbeae6784b` |
