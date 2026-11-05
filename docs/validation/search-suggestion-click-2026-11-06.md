# 搜索联想词条点击无响应修复（2026-11-06）

## 症状与复现

在搜索框输入 `S` 后出现“命运石之门 / 白箱 / 间谍过家家 / 宋飞正传 / 神探夏洛克 / 邪恶力量”下拉列表；鼠标点击时仅收起列表，未打开详情。

已在原正常 Windows 开发 App 上重现，不是截图模拟：

- [修复前联想列表](../../.codex_tmp/runtime-screenshots-20261106/25-search-before-dropdown.png)
- [修复前点击白箱后仍停留搜索页](../../.codex_tmp/runtime-screenshots-20261106/26-search-before-pick-failed.png)：按住鼠标 120 ms 后松开。

## 根因与最小修改

1. [共享搜索框](../../lib/src/shared_ui/app_chrome.dart) 的输入框外围与浮层 TapRegion 已使用 `groupId: this`，但内部 TextField 未设 groupId，默认仍是 Flutter 的 `EditableText` 分组。点击浮层只保护外层组，内部输入框仍收到 pointer-down outside，先失焦；焦点监听关闭 OverlayPortal，InkWell 在 mouse-up / onTap 前被移除。
   - 修复：TextField 显式 `groupId: this`，与浮层一致。
   - 保留真正外部点击收起/失焦；没有 onTapDown 提前导航或延迟关闭 workaround，也未扩大浮层 hit 区。
2. [SearchPage](../../lib/src/catalog/catalog_page.dart) 未传 `onOpenSuggestion`，即使解决点击失效仍会回退到关键词搜索。补上与首页/分类页面一致的 `DetailPage(subject: subject)` 导航，点击精确对象，不再重搜。

SDK 对照：Flutter 3.41.3 的 TextField 默认 `groupId = EditableText`；EditableText 内部 TextFieldTapRegion 使用该组，默认鼠标 outside action 调用 unfocus。

## 回归与验证

新增 [13 项搜索浮层回归](../../test/app_search_overlay_test.dart)：

- Windows 鼠标首/末词条，1440/826 宽；Android touch 与 mouse，390 宽。
- 明确拆开 pointer-down → pump 80 ms → pointer-up，断言中间焦点/浮层保留，松开后回调恰好一次。默认 tester.tap 不足以覆盖该跨帧问题。
- 历史点击、单条删除/最后一条删除、不触发额外搜索。
- 真正外部点击收起；无详情 callback 时保留关键词搜索 fallback。
- 键盘搜索及实际鼠标点击搜索箭头。
- 首页、分类页、搜索结果页均打开精确 subject；只 push 一次，不额外发起 keyword search，返回恢复原页面且浮层不残留。

红→绿：修复前最初 12 项中 9 项失败、3 项通过；仅修复 groupId 后 mouse/history 恢复，搜索结果页导航回归仍失败；补齐 callback 后通过。之后新增搜索箭头回归，最终 **13/13 通过**。

最终验证：

- `flutter test --no-pub --reporter expanded`：**1405 通过、28 跳过**，退出码 0。
- `flutter analyze --no-pub`：**No issues found**，退出码 0。
- `flutter build windows --debug --no-pub`：成功，退出码 0；原生正常 App 入口，不是 integration_test fixture。
- 实际正常 App 首页输入 `S`，点击第二项“白箱”已打开详情：[修复后联想列表](../../.codex_tmp/runtime-screenshots-20261106/29-search-fixed-home-suggestions.png)、[白箱详情](../../.codex_tmp/runtime-screenshots-20261106/30-search-fixed-home-whitebox-detail.png)。
- 返回首页提交 `S` 进入搜索结果，再展开列表，鼠标按住 120 ms 点击第六项“邪恶力量”已直接打开该详情：[结果页联想列表](../../.codex_tmp/runtime-screenshots-20261106/32-search-fixed-results-suggestions.png)、[邪恶力量详情初始导航](../../.codex_tmp/runtime-screenshots-20261106/33-search-fixed-results-supernatural-detail.png)、[详情加载完成](../../.codex_tmp/runtime-screenshots-20261106/34-search-fixed-results-detail-loaded.png)。

正常开发 App PID：35052。runner SHA256：`f832b6a2406284d5014b63c53230b319114b0556ed56356d8bcb00c700303fd7`；本轮 Dart kernel SHA256：`50439b3d5ffe0426b6c2f94466cc03d8b83da22d4b54d4daef1cd55a80bb8ca9`。截图邻接 provenance JSON 同时记录 runner/kernel/image hash 和点击坐标，均为原始 PrintWindow 捕获，无图像编辑。

本次搜索修复仅修改两个业务文件并新增测试/验证记录；保留之前线路界面与网络优化修改。本文记录开发 QA 阶段，当时尚未提交/推送/发布；旧版 Release EXE SHA256 为 `58eedb8e2e881d3968a8b7964c33401c3c922e5c599d5051df5f0fdb0947c4f0`。后续用户已授权将这些改动统一纳入 [v1.3.1](../release-notes-v1.3.1.md) 提交与双包发布，新版交付状态以 Release 的 manifest / 验收报告为准。
