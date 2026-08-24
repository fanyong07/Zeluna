# Zeluna PR6 目标出口实测证据（2026-08-24）

## 背景与目标

PR6 需要把 MacCMS Smoke、Coverage、候选注册表和来源晋级流程真正跑通，
并以 Zeluna 生产 VPS 的网络出口为准。此次实测用于验证工具、修正已知问题源
分层，并筛出值得人工审核的候选；它不等于内容授权或自动上线批准。

```text
LIVE PRODUCTION-EGRESS PROBE: RUN
```

## 范围与安全边界

- 在 `/tmp/zeluna-pr6-92e0ff961df7` 隔离目录运行当前代码，未覆盖生产目录。
- 生产 `zeluna.service` 全程为 `active`。
- 生产 `server/aggregator.py` 前后 SHA-256 均为
  `22fffa52496b730980fc89545772733c637ca6fd2ae22628e6745a2b9f02b621`。
- 未读取或复制 kanju1 私有 API、ticket、HMAC、Cookie、账号、CDN 或配额能力。
- JSON 报告逐项检查 URL 查询串和 userinfo，脱敏检查均通过。
- 候选只保留为数据；本轮自动晋级数为 0，生产站表新增数为 0。

## 输入与可复现证据

| 输入 | 数量 / SHA-256 |
| --- | --- |
| 候选注册表 | 80 个独立逻辑候选；`0d996624775b2415dde1a0eb72ae86d02c233b046ff84c7339ca22188fb8a672` |
| 排除镜像/别名 | 20 个，不计入候选或生产数量 |
| Coverage 数据集 | 48 个案例，anime/tv/movie 各 16；`4ae0c64fc4767b3af18d58bbb8f49c35b82aaa46e1ca340b559f21f19873f1bd` |
| VPS 实测 Probe 工具 | `6b73b7fe709b1142d072173bfb6fb13a39c45b93679725161af1b3dbf73c2436` |
| 本轮正式源表 | `fc4253f979167fedbfccfaedb095d982b3c9c883f9daa38b56e1994ec28c1332` |
| VPS 证据清单 | `/opt/zeluna/probe-results/pr6-20260824-6b73b7fe/evidence-manifest.json` |
| 证据清单 SHA-256 | `afcaf3ddbba93e15d6e41962de06f133edfb00e35a95238d7d22d52f0ad2d2fa` |

仓库提交前又将候选来源证据收紧为固定 40 位 GitHub commit permalink；当前
`probe_maccms.py` SHA-256 为
`ed8c10c66be64a1dc229bc85e9dd543b299a1d2f22b36e49e197b4d432105ec1`。
这项改动发生在任何网络请求之前，默认注册表仍严格解析为同一组 80 个候选，未改变
搜索、详情、分集或媒体验证执行路径，因此没有伪造或重写上表已归档的 VPS 实测证据。

Live Coverage 使用 6 个平衡案例（anime/tv/movie 各 2）控制外部请求量；完整
48 案例数据集、加载器和 Mock 全链路测试已在仓库中验证，但本轮没有把 48 案例
对所有 100 个来源全部打满。

## 当前正式源 Smoke

| 指标 | 结果 |
| --- | ---: |
| 配置来源 | 20 |
| 当前启用 | 17 |
| 完成 Smoke | 20 |
| 搜索成功 | 16 |
| 详情成功 | 16 |
| 至少一类服务端真实可播 | 10 |

完成服务端真实媒体验证的来源为：iKun、光速、如意、猫眼、速博、红牛、虎牙、
量子、电影天堂、魔都2。报告中另有机房受限的 `client_probe_required`，不能把它
误写成服务端可播，也不能简单等同于用户住宅网络不可播。

报告：`configured-smoke-v2.json`，SHA-256
`38c40fd817b12b1ed45dc91ede16c5a9893b95a57cb87ecc3e670822715e0433`。

## 当前正式源平衡 Coverage

| 指标 | 结果 |
| --- | ---: |
| Benchmark cases | 6 |
| 至少一条服务端可播 | 100% |
| 至少两个不同媒体 Host 可播 | 83.33% |
| 单 Host 可播 | 16.67% |
| Zero playable | 0% |
| Anime coverage | 100% |
| TV coverage | 100% |
| Movie coverage | 100% |
| 完成 Coverage 的来源 | 20 |

`wrong_match_rate` 和 `wrong_episode_rate` 仍为 `NOT MEASURED`：此次自动探针没有
伪装成人工标题/分集审核。上述比例只证明这 6 个案例的真实媒体链路，不外推成
48 或 100 案例的最终 Epic 成绩。

报告：`configured-coverage-v2.json`，SHA-256
`691bb738c3359e9911e29944f5042ac09237d627ff4a794ad1e8ca2c84c8a47b`。

## 已知问题源复测与处置

| 来源 | Smoke / Coverage 证据 | 最终处置 |
| --- | --- | --- |
| 极速 | 搜索可响应，0 服务端可播；6 案例中 4 个只剩客户端复验，且媒体目标触发 `non_public_target` 安全门 | `enabled=false`、`tier=quarantine` |
| 暴风 | Smoke 18/18、Coverage 6/6 媒体候选均为 `stale_route` | `enabled=false`、`tier=quarantine` |
| 风车 | Smoke 与 Coverage 的 API 请求均为 `http_444` | `enabled=false`、`tier=quarantine` |

最终工具会在 URL 安全门失败时强制给出 quarantine 建议；不会因为还有
`client_probe_required` 就把非公网目标误推荐为 client-probe。

报告：`known-coverage-v3.json`，SHA-256
`810f8fafcbcb95540535496f52784dfa841a6c3e34c68e0b1bc986ed912d77e5`。

## 80 个候选 Smoke

| 指标 | 结果 |
| --- | ---: |
| 注册候选 | 80 |
| 搜索/详情成功 | 8 |
| 至少一类服务端真实可播 | 5 |
| 仅客户端复验候选 | 3 |

服务端真实可播候选：新浪资源、HG资源、金鹰资源、无忧资源、爱胆资源。

仅客户端复验候选：U酷资源、秒播资源、非凡资源。

报告：`candidate-smoke.json`，SHA-256
`f8ddaabe1e51c39611c3c9495093a5fc55b5f204e365af6f2411e55f3f2828ac`。

## 候选晋级流水线

对上述 8 个候选运行 `--profile promotion`，依次执行 Smoke、平衡 Coverage、
逐跳 URL 安全验证并保留人工审核门：

| 结果 | 来源 |
| --- | --- |
| 技术上可进入人工审核（5） | HG资源、爱胆资源、新浪资源、金鹰资源、无忧资源 |
| 建议 client-probe、但 Smoke 未通过（3） | U酷资源、秒播资源、非凡资源 |
| 自动晋级 | 0 |
| 正式表新增 | 0 |

5 个技术候选在 6 个案例的覆盖并集为 100%，其中 83.33% 案例存在两个以上不同
媒体 Host；这仍不是授权、长期稳定性或 48/100 案例结论。所有条目继续保持
`review_status=candidate`，必须完成站点主体、服务条款、内容权利和第三方聚合许可
的人工审核后才能决定是否进入 Core/Fallback/Specialist/Client Probe。

报告：`candidate-promotion-v4.json`，SHA-256
`5c13babb4527bbe3a3b5617c1ff0b1b4ab5429a6d12efbeaac7eb523f87bef20`。

## 本轮来源清单

```text
candidate: 80
configured: 20
enabled production: 17
core: 9
fallback: 1
specialist: 3
client_probe: 4
quarantine: 3
retired: 0
```

## 剩余限制

1. 5 个技术候选尚未通过合规人工审核，因此没有加入生产表。
2. Live Coverage 只有 6 个平衡案例；完整 48 案例和 Epic 最终 100 案例仍待后续阶段。
3. 错误作品和错误分集需要人工 ground truth 复核，当前必须报告 `NOT MEASURED`。
4. 本轮只归档实测证据，没有部署 PR6 代码或重启生产服务。
