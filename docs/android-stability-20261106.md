# Android 卡顿与闪退专项修复

状态：本地源代码修复，未提交、推送或发布。基线 `769ee519ada04cf62971a07794119c8be300fe52`，发布版本仍为 `1.3.1+87`。本轮 Profile 包是独立 `.qa` 集成测试入口，不是可分发升级包。

## 已证实的代码问题与处理

| 问题 | 证据 | 处理 |
| --- | --- | --- |
| media_kit 截图 FFI argv 分配不足 | `['screenshot-raw','video']` 原先按字符串总长度分配 19 字节；64 位 NULL 终止指针数组至少需要 24 字节。第三个指针越过分配范围。 | 将精确 1.2.6 运行时代码纳入本地 override，按指针元素数分配、显式 NULL 终止，释放路径用 finally 管理。来源、许可证、哈希和补丁范围见 [补丁说明](../third_party/media_kit/PATCHES.md)。 |
| 首帧探测重复做 JPEG 编码 | 原每 400ms 探测调用 screenshot(image/jpeg)，只为判断有无视频帧。 | 原生 worker 检查真实 screenshot-raw node 的尺寸、stride、像素指针与数据长度，只返回布尔值。不编码 JPEG、不跨 isolate 传像素；实际 native screenshot 命令仍有开销。 |
| 超时后重复排入 native 共享锁 | Future.timeout 不取消原始 compute/native 调用；原 finally 清除 reading 后继续轮询。 | 当前 monitor generation 超时即退休，在通知回调前取消。独立首帧 hard deadline 保留。**不宣称取消了已挂起命令或释放全局锁。** |
| 进度事件重建整个移动播放页 | 390×844 布局，30 次进度/缓冲更新，使 PlayerPage、详情和线路列表各重建 30 次。 | 保留每次原始进度供恢复、预取和弹幕逻辑使用；使用局部 Listenable 更新播放器区域，避免详情/选集/线路排序跟随进度刷新。相同测试这些静态区域均 0 次重建。 |
| 详情、弹幕仓库长期缓存无上限 | 应用生命周期中访问新条目会一直保留。 | 详情 32 项 LRU；弹幕最多 8 个时间轴且累计 50,000 条评论，命中提升热度但不续 TTL。超大时间轴完整返回、仅跳过缓存。保持账号隔离、single-flight 和旧请求失效语义。 |
| Android 多隐藏 WebView 及共享存储竞争 | 并行创建任务会共用全局 Cookie/Storage；缺少 renderer-gone 处理。 | 进程级单活跃队列、最多 8 个等待任务；取消及时返回，初始化/释放/全局清理收尾完成后才放行下一任务。开启并消费 renderer-gone，清理 JS 等待上限 500ms。native 创建/销毁回执失败时暂停后续创建，直到进程重启。URL/权限限制与 Windows 路径保持。 |

关键代码：[播放器](../lib/src/player/player_page.dart)、[首帧监控](../lib/src/player/video/native_video_controller.dart)、[截图 helper](../third_party/media_kit/lib/src/player/native/utils/screenshot.dart)、[WebView 队列](../lib/src/rules/android_webview_task_queue.dart)、[WebView 生命周期](../lib/src/rules/animeko_webview_sniffer_io.dart)、[详情缓存](../lib/src/catalog/catalog_controller.dart)、[弹幕缓存](../lib/src/data/danmaku_repository.dart)。

## 验证

- 全量 Flutter 测试：**1,455 通过，28 跳过**，`flutter test --no-pub --concurrency=2 --reporter expanded`。
- `flutter analyze --no-pub`：No issues found。
- FFI 定向测试：21/21；WebView 生命周期/队列/准入：14/14；弹幕 repository/controller：42/42；详情 controller：23/23。
- 修复前后移动布局测试保持相同数据、事件数量、视口、播放进度和打开次数。测试证明减少重建工作，**不是物理手机 FPS、耗电或 PSS 测量**。
- Android API35 / x86_64 / read-only AVD / 独立 `app.anime.anime.qa`，Profile 原生 FFI 回归通过：12 次打开、60 次重复布尔帧探测、12 次有效 JPEG、暂停与 probe/stop/dispose 并发完成。此项使用 null VO 和本地生成 64×36 AVI，验证 native 内存/生命周期，不验证屏幕绘制。
- 同一 API35 模拟器的正常 auto 输出路径（mediacodec_embed）Profile H264 回归通过：真实纹理帧持续增长、10 秒播放时钟推进、暂停稳定、重新打开有独立首帧；实际截图可见生成的彩条与时间码。
- 强制普通 GPU 路径的 H264 实测未通过：该 API35 x86_64/SwiftShader 环境持续 no_image，hard watchdog 正常触发，没有 native 崩溃。此环境正常 auto 路径使用独立 direct-surface 兼容层；强制 GPU 结果保留为失败，**不替代真实 ARM GPU 路径验收**。
- `flutter build web --no-pub`：成功；Wasm dry run 也成功（没有把此检查当作浏览器运行测试）。
- WebView 原生 renderer crash：**Profile 实测通过**。真实 Chromium 回报 `didCrash=true`，宿主 PID 存活；当前 sniff 返回 null，后续新实例成功读取 allowlisted 媒体地址，真实 Cookie 清理成功；创建 2 次、dispose 回执 2 次、同时活跃 handle 最大 1。该结果不把 dispose 回执等同于 `WebView.destroy()` 已完成。
- 原生 WebView 测试曾先后暴露测试夹具的创建就绪竞态、loadData 页面标记未就绪；均保留失败日志。最终使用真实 about:blank 导航、真实 onLoadStop、测试侧 DOM 写入、再转发原事件给生产扫描器；未改网络策略或伪造原生回调。

详细执行证据位于本地忽略的 [.codex_tmp/android-stability-20261106](../.codex_tmp/android-stability-20261106/)；该目录不作为发布产物。集成入口：[native_frame_probe_stability_test.dart](../integration_test/native_frame_probe_stability_test.dart)、[android_webview_stability_test.dart](../integration_test/android_webview_stability_test.dart)。

## 重现 native Profile 测试

先运行 `flutter pub get`，再从 android 目录构建。显式 `-P` 很重要：本轮环境变量配置曾被 Flutter 构建链覆盖，APK 实际没有 `.qa` 后缀；该包未安装。之后一律检查实际 APK identity 再运行。

```powershell
.\gradlew.bat assembleProfile `
  -Ptarget=integration_test/native_frame_probe_stability_test.dart `
  -Ptarget-platform=android-x64 -PzelunaQaApplication=true `
  -PzelunaTargetAbi=x86_64 -Pkotlin.incremental=false `
  -Pkotlin.compiler.execution.strategy=in-process --max-workers=1
```

WebView fixture 只替换 target 为 `integration_test/android_webview_stability_test.dart`，运行时强制检查 `.qa`。它通过真实插件与 Chromium 测试持有的 WebView 执行 `chrome://crash`，不应作为正常产品入口。只在独立 QA 环境运行。宿主 launcher 为 `app.anime.anime.SplashActivity`，MainActivity 不对外导出。

## 真机验收与仍存在的限制

目前连接的 x86_64 设备装的是 `1.1.12+66`，没有本次 `1.3.1` 的退出记录。未覆盖或清理该设备。没有用户物理手机的闪退 trace，因此以上明确缺陷尚未与该手机崩溃建立因果对应。

- ARM64 手机的 OEM GPU/硬解码、后台切换、连续播放、低内存压力仍需真机验收。
- 32 位 screenshot argv 布局已有模型测试；现有生成绑定的 size_t ABI 未做 ARMv7 运行验证，本轮不宣称已覆盖。
- 仓库缓存预算不限制一次弹幕解析、正在显示的时间轴、native/GPU 内存峰值；本轮没有改解析器或削减返回弹幕。
- 原生截图真正挂起时仍可能阻塞共享锁与 dispose。此次只消除每代超时后的重复积队，未引入危险的提前销毁或解锁。
- 现用 WebView 插件的 dispose 回执不是 `WebView.destroy()` 已完成的证明；其原生实现正常通过 about:blank/onPageFinished 销毁，renderer 已死亡时仍需单独核查长期 Java/native 对象保留。

手机复现后可运行 [应用限定诊断脚本](../tool/collect_android_stability.py)：

```powershell
python tool/collect_android_stability.py --serial PHONE_ADB_SERIAL --adb "PATH_TO_ADB"
```

脚本只读取 app 的版本、型号/API/ABI、exit-info、meminfo、gfxinfo、UID 限定日志；不安装、不清数据、不抓整机 bugreport。URL、常见认证和 Cookie 字段会脱敏，分享前仍应检查自由文本。需要保留闪退时间、手机型号/系统版本、触发页面/操作、是否开启 Anime4K。

## 发布边界

本轮不自动沿用之前的发布授权。不提交、不推送、不新建 GitHub Release，也不覆盖 v1.3.1。后续对外交付修复包须先递增版本/build，再按仓库规则绑定精确提交、Quality Gates 和 manifest。
