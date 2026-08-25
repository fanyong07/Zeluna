# Zeluna Playback Coverage & Reliability Epic 最终验收报告

> 状态：Final。完整 Live VPS Coverage、生产部署、真实公网播放回归、
> v1.0.10 Android / Windows 打包和 GitHub 草稿 Release 均已完成。

## 1. 精确版本与交付边界

```text
base commit:                  59332ca
playback implementation:     31ca280f68fe259da88abf9165a9c6f9255fe176
release commit:              057001f92641394e1b88732721f228b010d29d4b
Flutter version:             1.0.10+51
public release name:         v1.0.10
Quality Gates run:           32768164647 (success)
GitHub Release:              v1.0.10 draft
```

发布提交 `057001f` 以 `31ca280` 为直接父提交，只增加版本准备；APK、Windows
ZIP、release gate 和 manifest 均绑定该精确 release commit。GitHub Release 保持
Draft，不等同于已经公开发布，也尚未创建可见的正式 Git tag。

Android APK 使用项目历史兼容 Debug 证书，只用于内部侧载和覆盖安装，不能当作
商店生产签名。

## 2. 已解决的问题

原事故不是单一“源失效”，而是以下行为叠加后把可恢复播放表现为
`24 来源 · 0 可播`：

- 只搜索第一个 alias，季名、译名或英文名不同就漏掉正确作品；
- 最快标题命中提前结束，错误作品或前六个失败候选占满解析名额；
- 缺失年份和类型被伪造成具体年份 / TV；
- SP、OVA 和非数字标签导致分集位置偏移；
- quick miss 被写成正式负缓存；
- route failure 污染整站健康状态；
- 明确年份、季数或媒体类型冲突仍可能进入播放解析；
- 客户端把未查询、超时、匹配失败、无当前集和线路失效统一显示为“没找到”。

最终实现包括：多 alias 渐进搜索、有界候选竞速、失败候选释放 slot、明确集号优先、
quick/full 缓存边界、route/provider 健康分层、来源卡片去重，以及独立的
`SourceMatchEvidence` / `SourceMatchAnalysis`。明确年份冲突、季数冲突和不兼容媒体
类型现在直接 `playback_eligible=false`，不会进入线路解析、缓存、Coverage KPI 或
legacy baseline；`anime/movie` 动画电影保持兼容，未知年份和未知类型保持中立。

## 3. 来源库存

```text
候选登记逻辑数量: 80（不自动晋级）
生产配置数量:     20
生产启用数量:     17
生产禁用数量:      3
core:              9
fallback:          1
specialist:        3
client_probe:      4
quarantine:        3（全部 disabled）
```

生产部署后已在运行进程中直接导入 `MACCMS_SITES` 复核，确认 `configured=20`、
`enabled=17`、`disabled=3`。禁用的 quarantine 不进入用户查询。

## 4. 完整 Live VPS Coverage

### 4.1 数据集与证据

```text
target egress:          洛杉矶生产 VPS
probe code HEAD:        31ca280f68fe259da88abf9165a9c6f9255fe176
selected sources:       17 enabled configured sources
benchmark subjects:     100
benchmark cases:        167
episode 1 cases:        100
mid-episode cases:       67
anime / tv / movie:      34 / 33 / 33
schema:                 zeluna.maccms-probe.v3
generated UTC:          2026-08-24T22:24:17.798246+00:00
JSON bytes:             4,795,445
JSON SHA-256:           4d51a1387c887b319e1aa14a3ad20310ac5a439432d6c42c5002ea505b4a4a85
stdout bytes:           1,921
stderr bytes:           0
```

证据文件保存在 `release/evidence-v1.0.10/`。原始 nohup 启动器只记录 PID，没有
落盘数值 exit code；因此不能声称有独立的 `exit=0` 文件。完成证据是：探针进程已
退出、最终 JSON 原子写入、stdout 输出最终结构化路径、stderr 为空，且 JSON 可完整
解析为 17 个来源 × 167 个案例。

### 4.2 最终 KPI

本轮探针本身已运行修复后的身份过滤逻辑；重新调用当前
`build_coverage_kpis()` 与 JSON 内存储值一致：

| 指标 | 结果 |
| --- | ---: |
| 作品至少一条服务端真可播 | 81 / 100（81.00%） |
| 分集至少一条服务端真可播 | 130 / 167（77.8443%） |
| 作品零服务端可播 | 19 / 100（19.00%） |
| 分集零服务端可播 | 37 / 167（22.1557%） |
| 动漫 Episode 1 覆盖 | 23 / 34（67.6471%） |
| 电视剧 Episode 1 覆盖 | 29 / 33（87.8788%） |
| 电影 Episode 1 覆盖 | 29 / 33（87.8788%） |
| 单 Host 作品 | 15 / 100（15.00%） |
| 多 Host 作品 | 66 / 100（66.00%） |
| 仅客户端复验、无服务端确认的分集 | 3 / 167（1.7964%） |

同一轮真实观测的确定性旧策略模型：

| 策略 | 作品可播 | 分集可播 | 零可播作品 | 多 Host |
| --- | ---: | ---: | ---: | ---: |
| alias 0，第一个匹配 | 6% | 13.1737% | 94% | 0% |
| alias 0，最多 6 个候选 | 75% | 72.4551% | 25% | 60% |
| 当前策略 | 81% | 77.8443% | 19% | 66% |

legacy 数值是同批观测的确定性模型，不是旧二进制运行时重放。

### 4.3 正确性审核边界

```text
wrong_match automatically reviewed:   1,157 observations
explicit wrong_match found:                0
wrong_episode automatically reviewed:    851 observations
explicit wrong_episode found:               0
```

这里的 0 只表示自动 evidence 能明确判断的年份、季数、媒体类型和显式集号范围内未
发现冲突；未带足够元数据、位置 fallback 和只需客户端复验的观测不算人工审核，不能
外推成“全部 2,839 个来源/案例组合都由人工确认正确”。

### 4.4 19 个零可播作品逐项归因

下表列出 Episode 1 没有服务端真可播线路的全部作品；所有项目均已查询 15 个有响应
来源，另有 iKun / 爱奇艺在本轮长期网络等待后无有效搜索响应。

| 类型 | 作品 ID | 主要归因 |
| --- | --- | --- |
| anime | anime-attack-on-titan-final | 3 个候选无第 1 集，其余匹配不足/无结果 |
| anime | anime-mushoku-season-2 | 搜索无结果或身份匹配不足 |
| anime | anime-monogatari-second-season | 搜索无结果或身份匹配不足 |
| anime | anime-spy-family-season-1 | 2 条候选均 stale_route |
| anime | anime-haikyu-season-1 | 搜索无结果或身份匹配不足 |
| anime | anime-my-hero-academia-season-1 | 搜索无结果或身份匹配不足 |
| anime | anime-kaguya-sama-season-1 | 搜索无结果或身份匹配不足 |
| anime | anime-apothecary-diaries-season-1 | 搜索无结果或身份匹配不足 |
| anime | anime-scissor-seven-season-1 | 唯一候选 stale_route |
| anime | anime-fog-hill-season-1 | 搜索命中但身份匹配不足 |
| anime | anime-heaven-official-season-1 | 唯一候选 stale_route |
| tv | tv-hanzawa-naoki-season-1 | 搜索无结果或身份匹配不足 |
| tv | tv-three-body-2023 | 唯一候选 stale_route |
| tv | tv-knockout-2023 | 1 条客户端复验候选，未获服务端确认 |
| tv | tv-3-body-problem-2024 | 搜索无结果或身份匹配不足 |
| movie | movie-dune-2021 | 唯一候选 stale_route |
| movie | movie-parasite-2019 | 唯一候选 stale_route |
| movie | movie-kung-fu-hustle | 唯一候选 stale_route |
| movie | movie-dark-knight | 1 条 stale_route + 1 条客户端复验候选 |

严格身份过滤会降低虚高覆盖率，但避免“能打开却是另一季/另一部作品”的更严重错误。
本轮 iKun 和爱奇艺搜索响应率为 0，说明 81% 是该时段、该出口的保守快照，不是第三方
资源站永久可用性承诺；部署后的真实公网回归中 iKun 已恢复并能提供线路。

## 5. 测试与 Quality Gates

在当前 `31ca280` 源码上重新执行：

```text
uv sync --project server --frozen --all-groups: passed
uv run --project server pytest -q:              335 passed, 79 subtests passed
uv run --project server ruff check .:           passed
python -m compileall -q server tests tools:      passed
git diff --check:                               passed
```

GitHub `Quality Gates` 在精确 release HEAD `057001f92641394e1b88732721f228b010d29d4b`
上全部成功，run ID `32768164647`，覆盖 Flutter analyze/test、Android build + emulator、
Windows build + WebView、Web build、Python/Alembic/Ruff/audit 和 secrets/licenses/SBOM。

## 6. VPS 部署与回滚

生产服务部署前已创建：

```text
/opt/zeluna/backups/pre-playback-20260825-31ca280/
```

备份包括 SQLite 在线备份、完整 `server-before`、`zeluna.env` 和 systemd unit。
部署只替换播放正确性相关的 6 个文件：

```text
server/aggregator.py
server/playback.py
server/title_matching.py
server/playback_health.py
server/scrapers/maccms.py
server/scrapers/maccms_sites.py
```

账号、SQLite、uploads/backups、allowlist、`single_proxy`、WebUI、计费和 systemd 配置
没有被覆盖。部署后当前证据：

```text
service:                 active
bind/workdir:            127.0.0.1:8000 / /opt/zeluna/app/server
database integrity:      ok
alembic:                 0013_managed_playback_lines
users:                   1 (unchanged)
catalog_subjects:        2092 (unchanged)
source_bindings:         2031 (unchanged)
source_health:           32 (unchanged)
playback_cache:          140 (unchanged after deployment acceptance)
managed_playback_lines:  0 (unchanged)
environment SHA-256:     93aace4b787b9f18aa7e3ddb39ddb129d7a27055c4f99a04e5497de62c75cdb9
```

生产部署后关键源码 SHA-256：

```text
aggregator.py       7b5a43f3c1883d77bb4c72203e98442158727c2605a556062de23f847ba6a91b
playback.py         9766df839eed9e8beb29ede329098fe7cfac9589a28c6e6c6d795c08313a5531
title_matching.py   348c2a56cf42faf19903ea7c0cf09efda3830e54cafc9c1ccf854f402cd479ac
playback_health.py  62be650928e925a0371def9ae357e23188b01257e33ce98e6cdc0044f83cefa0
maccms.py           635dde422a7c789c682d613d8b07753152da53c68f74c1282f3e42442ed64e66
maccms_sites.py     5abff01cb37fb13253d461475db7c1ee13c4d60f2267111c00619254f91f4ff8
```

## 7. 真实公网播放回归

通过 `https://api.zeluna.top` 从客户端出口复核：

```text
/api/v3/status:                         200
anime search + quick playback:          200 / 3 lines / 3 usable
tv search + quick playback:             200 / 3 lines / 3 usable
movie search + quick playback:          200 / 3 lines / 3 usable
anime full playback:                    200 / 22 lines / 9 usable / 8 hosts
HLS manifest:                           200
AES-128 key (when present):             200 / 16 bytes
first media segment Range:              206 / 2,049 bytes
```

回归作品分别为《葬送的芙莉莲》《庆余年》《流浪地球》。这证明部署后 status、搜索、
quick/full playback、manifest、AES key 和首分片链路当前可用；不把单次回归外推为所有
第三方线路永久稳定。

## 8. v1.0.10 发布产物

全部产物只保存在项目内 `release/`，未创建 `E:\anime-release-*` 越界目录：

```text
Zeluna-v1.0.10-Android.apk
  bytes:   139,108,852
  SHA-256: 763272b6c7603887493030a9a7c709cb5b37602b0f7b2484cc34221b93b41c88
  package: app.anime.anime
  version: 1.0.10 / versionCode 51
  signing: APK Signature Scheme v2, historical compatibility Debug certificate

Zeluna-v1.0.10-Windows.zip
  bytes:   51,910,004
  SHA-256: 9501c7df8ec2bb2fad9f990a3ddeb70c5762e4f1182cf2ac6ce8f82849660da5
  entries: 109
  contains: Zeluna.exe + complete runnable data/plugin directory
```

同目录还包含两个 `.sha256`、
`release-gate-1.0.10+51-057001f92641.json` 和
`release-manifest-1.0.10+51-057001f92641.json`。文件哈希、sidecar 和 manifest 三方一致。

GitHub 已推送：

```text
origin/codex/playback-final-benchmark -> 31ca280
origin/codex/release-v1.0.10          -> 057001f
PR #24                                open draft, checks green
GitHub Release v1.0.10                draft, 6 assets uploaded
```

## 9. 剩余长期风险

1. 第三方资源站会随时漂移；Coverage 是时间点快照，不能替代持续健康检查。
2. `client_probe_required` 只表示 VPS 无法确认，既不计入 server verified，也不代表用户
   设备一定不可播。
3. 自动 evidence 没覆盖的观测仍需人工抽检，尤其是元数据缺失和位置 fallback。
4. 正式公开 Android Release 仍需单独受保护的生产签名；当前兼容 APK 不能上架商店。
5. GitHub Release 目前是 Draft；公开发布和正式 Git tag 应在人工查看本报告后进行。
