# Android 应用内更新实现与验证（2026-11-07）

## 交付状态

这是源码实现和隔离验证，不是一次版本发布。保持现有 `1.3.1+87` 发布记录不变，未创建 Git 提交、Tag、GitHub Release，未覆盖现有发布包，未修改用户手机上的应用。先前 Android 稳定性修复保留。

入口：**我的 → 版本信息 → 应用更新**；杂项设置中的“应用更新”也会进入同页。

完整操作：

1. 点击“检查更新”，查看版本、大小与说明；“查看完整发布说明”可打开对应发布页。
2. 点击“下载更新”，显示已下载大小/总大小，可取消、失败后重新下载。
3. 完成字节数与 SHA-256 校验，再由 Android 原生代码检查包名、版本、最低 SDK、ABI 和当前签名证书集合。
4. 点击“立即安装”。缺少安装来源权限时，显示按钮进入本应用的系统权限页；返回后再次点击安装，不自动触发安装。
5. 由 Android 安装器显示更新确认。模块从不卸载旧版、静默安装或清除业务数据。

首次获得本功能仍需要手动安装**未来正式发布且含更新模块的 APK**。后续更新保持包名和签名，并按原有发布规则递增可见版本与 build。

## 设计与边界

- [仓库发现器](<../lib/src/updates/app_update_repository.dart>) 默认读取固定 GitHub 仓库最新正式 Release 与既有 v2 manifest；无须部署新服务。仅匿名 API 返回 403/429 时，使用同仓库固定 HEAD 重定向发现严格版本 Tag，不解析 HTML，不使用 token。对应生产网络限流分支已实际跑通。
- [更新模型](<../lib/src/updates/app_update_models.dart>) 严格解析清单，比较数值语义版本与 Android build，拒绝版本回退。可用编译参数选择公共 HTTPS 静态清单，具体见 [发布说明](<app-update-publishing.md>)。
- [流式下载器](<../lib/src/updates/app_update_download_io.dart>) 使用既有公共网络策略：HTTPS、证书校验、每跳地址检查、无账号凭证；请求头超时 20 秒、流空闲超时 30 秒、总时限 15 分钟。文件最大 512 MiB，流式计算 SHA-256，不把 APK 整体放进内存；临时文件写完验证后原子重命名。
- 使用 Android 私有 `cache/app_updates/`，不申请通用存储权限。FileProvider 仅暴露此子目录。原生路径、文件类型和链接检查防止访问其他文件；后台单线程执行大文件 hash、ZIP 与 APK 解析，每次点击安装重新验证。
- 签名预检要求当前 signer 集合精确相同，不自动接受签名轮换。最终 APK 密码学签名验证和安装由 Android 系统完成。
- [应用级控制器](<../lib/src/updates/app_update_controller.dart>) 保持单个操作，离开设置页下载继续。取消/失败删除完成前保持锁，避免旧清理删掉新任务文件；恢复前台与删除/安装互斥。设置写入串行并隔离过期失败回滚。
- [持久化](<../lib/src/updates/app_update_store.dart>) 独立于账号和业务数据。已完成下载的清单和私有路径可恢复，恢复必须再次经原生验证。真实 Hive 的嵌套动态 Map 读回会递归规范化，打开失败可重试，不用默认值覆盖尚未读取成功的配置。
- 可选“启动时检查更新”**默认关闭**。开启后每 24 小时最多检查一次，失败也计入间隔，不自动下载/安装。播放路由上不启动检查或显示更新条。
- Windows/Web 保持现有功能，不执行 Android 方法调用，显示当前只提供 Android 应用内更新。

## 已执行验证

### 单元与组件

- 模型/发现器/下载器 28 项定向测试：畸形清单、版本和 asset 不一致、SHA/长度错误、重定向规则、取消、头部/空闲/总时限、私有路径清理、API 限流备用路径。
- 原生 Kotlin 20 项测试全部通过，0 忽略、0 assumption skip，包含实际符号链接测试；使用缓存 Kotlin 编译器及真实 Android 36、Flutter embedding、AndroidX 类路径编译。
- Hive 持久化 7 项测试通过，包含真实关闭/重开、嵌套 Map、打开失败后重试与写入快照隔离。
- Controller/UI 覆盖明确点击才安装、权限返回、进程重启恢复、低存储、签名失败、取消/销毁晚回调、单并发清理、设置写竞争、安装重验失败重新下载、播放器不弹提示。
- Flutter 全量回归：**1511 通过、28 跳过**；其中新增 updater 模型/网络/下载/控制器/UI/持久化共 56 项。最后补充的播放器 push/pop 路由断言另行重跑通过。
- Flutter 静态分析：No issues found；Web 构建及 Wasm dry run 成功（没有把 Web 声称为 Android 安装端）。
- 发布清单工具 stdlib unittest **39 项通过**；还使用现有真实 v1.3.1 manifest 生成新暂存 feed，源 release 文件不变。
- 仓库检查与 `git diff --check` 通过，最终格式检查 19 个文件、0 改动。
- 最终 `lib/main.dart` 完整 Android 应用 Profile 构建通过；实际 aapt 包名为 `app.anime.anime.qa`，是隔离 QA 构建而非正式可分发版本。
- 初轮测试发现并修复了更新条在 Navigator 外部使用 Tooltip 的 Overlay 问题；复审补齐真实 Hive 嵌套 Map 恢复、清理/下载竞争、恢复前台竞争、失败初始化重试和设置写入竞争。上述问题均有回归覆盖。

### 真实网络

生产客户端默认入口在匿名 API 限流时通过 HEAD 备用路径读取 `v1.3.1+87`。随后用实际流式下载器完整下载当前正式 APK（**只下载，不安装**）：

- 实际/预期字节数均 `133140679`。
- SHA-256 验证一致：`ba6701b8fcb46a4e99d8ccd442c1e0a12408efc8a44cbe8dfa28eb6591efe4eb`。
- 本次流式下载耗时约 68 秒，仅代表本机网络。

本地证据：[网络结果](<../.codex_tmp/app-update-20261107/live-download-result.json>)。

### 隔离 Android 设备

使用自有只读临时 AVD `Zeluna_Playback_QA_API35`、API 35/x86_64、Profile 模式，仅安装 `app.anime.anime.qa`。先用 aapt 验证 APK 包名，再执行 [原生集成测试](<../integration_test/android_app_update_test.dart>)。候选为独立生成的极小、同签名 `.qa` APK，不是分发版本。

实测通过：

- 同包名/同签名且新 build 的候选验证成功。
- 错误签名、包名、版本、SHA-256、缓存目录外路径均被拦截。
- 未允许安装来源时返回 `permissionRequired`，成功打开本应用系统权限页。
- 测试宿主只为 `.qa` 设置安装来源权限，然后由测试显式再次调用安装。
- 系统安装器实际显示 `Do you want to update this app?`，按钮为 `Cancel` / `Update`。证据来自真实 accessibility tree，而不是仅依赖 MethodChannel 的 `launched` 返回值。
- 最终取消系统安装，验证 `.qa` 仍为 build 87；未执行最终确认安装，未声称完整覆盖升级验收或用户实体手机覆盖。
- 已关闭本轮自有模拟器、loopback fixture 服务和 adb reverse；其他设备未动。

本地证据：[原生结果](<../.codex_tmp/app-update-20261107/native-result.json>)、[权限页](<../.codex_tmp/app-update-20261107/permission.png>)、[安装确认树](<../.codex_tmp/app-update-20261107/installer.xml>)。安装器 PNG 截得黑屏，截图原因未进一步定位，因此不把该 PNG 当成可见确认界面的证据；确认文本以同轮系统 accessibility tree 为准。

隔离构建命令（在仓库根目录执行，测试包只用于 QA；先确认输出 APK 包名为 `.qa` 再安装）：

```powershell
flutter build apk --profile `
  --target integration_test/android_app_update_test.dart `
  --target-platform android-x64 --build-name 1.3.1 --build-number 87 `
  -PzelunaQaApplication=true -PzelunaTargetAbi=x86_64 `
  -Pkotlin.incremental=false `
  -Pkotlin.compiler.execution.strategy=in-process
```

此命令固定历史 QA 宿主为 `1.3.1+87`，候选夹具默认 `1.3.2+88`，与正式版本号独立。若更换夹具版本，需同时设置测试的 `ZELUNA_QA_UPDATE_BUILD` / `ZELUNA_QA_UPDATE_VERSION` dart-define 和宿主构建参数；候选 build 必须大于宿主。此类版本覆盖只适用于 `.qa` 验证，不用于正式发布。

## 后续正式上线注意事项

- 正式发布继续使用既有版本递增、精确 Git SHA、Quality Gates、manifest 和签名链路，不使用本轮 QA APK。
- 已发布 Android 包使用历史 debug key；本实现保持升级兼容，不换签。正式签名迁移另行规划，不把修改 feed 当成换签办法。
- 当前不做断点续传或 Android 前台下载服务；系统结束进程后，未完成下载需要重下；已完成且仍存在的包可恢复。进入后台下载能否持续也受系统电量策略影响。
- 最低 SDK/ABI、厂商安装器和实际实体手机仍应在正式发版前验证；本轮设备验收是 API 35/x86_64 模拟器。
- 所有 `.codex_tmp/` 证据和本轮 QA 夹具均为本机忽略产物，不是发布文件。
