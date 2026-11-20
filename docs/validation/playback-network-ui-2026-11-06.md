# 播放线路整理与连接优化验证（2026-11-06）

本文记录开发修改与本机 QA 阶段；截至该阶段尚未提交、推送或发布，未覆盖 v1.3.0 安装包。后续用户已授权提交和双包发布，本轮纳入 [v1.3.1](../release-notes-v1.3.1.md)；正式交付状态以新版本 Release 的 manifest / 验收报告为准。

## 1. 手动“本机重查（本集）”移除

- 移除线路按钮、确认弹窗、页面状态/取消逻辑，以及仅供该按钮调用的 discovery API。
- 保留正常选线、自动章节/媒体解析、自动探测、失败诊断、完整 URL 查看/复制。
- `clientQuerySupported` 等来自后端的领域字段与自动 resolver 请求上下文继续保留，不把删除 UI 误做为删除自动播放能力。

## 2. AniCh 取证与采用边界

本地源码为 README 标注的 1.0.0，不是此前分析的 1.5.27 二进制等版源码。

| 机制 | 原始证据 | 本轮结论 |
| --- | --- | --- |
| 自定义 Dart DNS / JSON DoH | AOT 字符串 `utils/dns.dart`、`queryDNS`、`lookupAddresses`、`MyHttpOverrides`、`application/dns-json` 与三个解析地址 | 能力存在；默认启用、TTL、失败顺序及是否覆盖 libmpv 未证实，不照搬未经证实的默认值。 |
| API / 线路切换 | `autoApiSwitch`、“当接口不可用时自动尝试访问其他接口”、“播放失败自动切换线路” | 可用性回退，区别于媒体 CDN 吞吐优化。 |
| 缓冲 / 磁盘缓存 | `cache-secs`、`cache-on-disk`、`demuxer-max-*`、“缓冲时长”、“磁盘缓存” | 选项存在；默认值未知，本轮不以扩大起播缓冲制造提速假象。 |
| 已取得的线路池本地切换，媒体与弹幕并行启动 | 1.0 源码 bangumi_vod/controller.dart | 缩短关键路径，不代表 CDN 带宽提升。 |

本地证据位于 `C:/Users/h1175/Documents/deepseek-harness/default-workspace/anich-re/`：`AniCh-main/README.md:44–47`；`strings/app.so.str` 的 7941、13007、14804、18633、26154 行；`strings/app.so.clean.txt` 的 124779、133052、135511、150364 行。二进制字符串仅作为静态能力证据，不代表实播默认启用。

## 3. 本轮连接与探测优化

- [DNS 地址缓存](../../lib/src/core/network/network_address_cache.dart)：系统解析结果共享，30 秒本地保守有效期，最多 128 条缓存/跟踪项，LRU 淘汰，同主机并发解析 single-flight，单次解析 3 秒超时。
- 只缓存地址，不缓存策略审批；[HTTP 接入](../../lib/src/core/network/network_http_client_io.dart) 每次命中仍重新核对所有地址，保留域名 SNI / TLS 证书校验。错误/空结果不缓存；失败连接竞速使对应主机失效；clear/evict 后旧 future 不回填。
- 128 条是缓存与跟踪容量，不是实际 DNS 请求并发上限。未跟踪的溢出 lookup 不落缓存。
- 原有 IPv4/IPv6 250 ms 连接竞速与播放器 HTTP client lease 池保留，未重复实现。
- [后台线路验证](../../lib/src/playback/playback_discovery_controller.dart)：保持最多四个并发候选，为每个候选增加 12 秒预算及独立 child token。一个超时/异常候选释放槽位，其他线路继续；保留真实 URL、headers、descriptor、已有媒体信息与失败状态。
- 超时/失败候选不被标为可播放；提示通过“搜索全部线路”重新验证，不直接把未解析章节交给 native player。

## 4. 修复真实运行中的搜索进度卡住

症状：真实视频继续播放，但“正在查找全部线路（14/24）· 已找到 48 条”数分钟不变。

确定因果链：

1. 规则 repository 原先直接复用 caller cancellation token。
2. Dart StreamController 正常 close 时也调用 onCancel；规则 producer 因此反向取消 caller token。
3. discovery 合并器检测 token 已取消而退出，未发最终 complete。
4. 页面线路 repository 的 onDone 因 token 取消而提前退出，未关闭 scanInProgress。

修复：[规则 producer](../../lib/src/data/playback_source_repository.dart) 改用独占 child session；parent 只单向取消 child；正常结束/取消订阅只清理 child，注销 parent 回调，不反向取消 caller。

先新增回归并运行，旧实现得到 `Expected: false / Actual: true`；修复后规则正常完成、父取消、子取消、真实规则 producer 与 backend 合并、页面 scan 状态回归通过。没有用隐藏 spinner 或假 complete 掩盖后台工作。

## 5. 线路布局

[共享线路卡片](../../lib/src/player/ui/playback_line_tile.dart) 与[播放来源面板](../../lib/src/player/ui/player_panels.dart)：全宽行、统一左右内边距、固定编号 gutter、内容区撑满；指标使用响应式等宽轨道（宽屏四列、窄屏/大字两列），不按延迟数字或 URL 长度挤动后续内容。选中/hover 不改变外框几何。保留语义色和独立 URL 手势，不添加虚假大小或分辨率。

## 6. 验证记录与解释

最终收尾：

- 完整 Flutter 测试：**1392 通过、28 跳过**，包含 DNS、候选超时/异常、四槽取消/clear/dispose、scan ownership 真实 producer 合并和线路布局新增回归；退出码 0。
- 全项目 `flutter analyze --no-pub`：No issues found，退出码 0。
- Windows 正常 App `--debug` 构建成功（非 integration_test 入口），退出码 0。现有 inappwebview 插件 CMake dev warning 不影响构建。
- 正常 App 重新启动后，真实搜索→详情→播放→全部线路扫描；[最终实跑截图](../../.codex_tmp/runtime-screenshots-20261106/23-final-aligned-panel-status.png) 显示 **71 条线路、15 条当前可播放、15 项待解析/暂无线**，扫描 spinner 已结束；视频持续播放至 4:13。选中/hover 及长短 URL 的整行宽度和内容列对齐已实看。
- 320/360 宽、2.4 倍字体、1280 宽屏及 hover/selection 几何回归共 18 项 UI 测试通过。
- 最终 debug runner SHA256：`f832b6a2406284d5014b63c53230b319114b0556ed56356d8bcb00c700303fd7`。Flutter debug 的 Dart 代码在 kernel payload，不由 runner EXE 单独区分；最终 kernel SHA256：`7befe8a3e196889bf18e861a8689fa31e578d53d48930e8a9c10596af165720e`。[截图旁 provenance](../../.codex_tmp/runtime-screenshots-20261106/23-final-aligned-panel-status.capture.json) 同时记录两者、PID 43652 与原始图片 hash，无图片编辑。
- 已发布 Release EXE SHA256 仍为 `58eedb8e2e881d3968a8b7964c33401c3c922e5c599d5051df5f0fdb0947c4f0`；版本与 release 目录无差异，未发布新包。

补充前轮证据：
- 定向 DNS/连接竞速/HTTP 取消/媒体 lease/controller：157 通过。
- Windows 原生实播集成：真实后端《葬送的芙莉莲》第 1 集，第一候选打开失败，第二候选验证并解码成功；1920×1080、13 个连续解码截图样本、样本中无 buffering、native error 数为 0，暂停位置变化 0。该集成隔离账号并固定选定的真实线路，不作为完整全部线路扫描的验证。
- 另启动正常开发 App 通过真实搜索→详情→播放→线路面板完成可视检查，复现并据此修复上述 scan token 所有权问题。
- 控制实验（非公网 CDN 基准）：模拟每次 DNS lookup 25 ms、同 host 20 次，未缓存 20 次解析/625 ms，缓存后 1 次解析/32 ms。该结果仅说明减少重复解析等待，不能当作视频下载提速倍数。

没有同设备同线路多轮冷/暖公网 A/B 统计，因此不发布首帧提升百分比或 CDN 加速倍数。
