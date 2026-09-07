# Zeluna 执行状态与后续验收 — 2026-09-06

## 结论与范围

本轮已完成本地修复、资源减重、ABI 构建验证、依赖 PR 分类、规则网页请求职责抽离和回归检查。2026-09-07用户进一步明确授权按功能提交、推送开发分支、合并主线、部署与发布；已进入候选交付收尾。完整四阶段目标尚未全部验收，必须以精确提交的远端门禁、部署记录和真实设备证据分别判定。

背景：用户要求检查整个仓库与提交/推送状态、执行减重及推进方案，同时确认 Windows 全屏并撤下启动加载图片。此文件供后续开发继续执行；它不是发布证明。远端写入与部署授权来自用户的明确指令，不代表允许绕过生产签名、精确SHA门禁、不可覆盖发布规则或删除数据/缓存。

- 工作区：`E:\anime`；分支：`claude/anime-source-layer`。
- 本轮审计基准：`fac7ebbf55a2ff7b225be75afd87443f611860c2`、`1.1.1+55`；不是当前候选HEAD。
- 原有全屏/弹弹play等改动已保留并按功能提交；下面的历史审计数据注明原快照，不能当作当前工作区状态。
- 2026-09-07重新核对远端最高已发布版本为v1.1.0、本地正式manifest为1.1.0+54后，候选版本递增为`1.1.2+56`。尚未通过全部公开发布前置条件，不创建或复用已发布标签。
- 构建产物只用于本地验证；已安装的旧版不会因此自动更新。

## 2026-09-07交付前复查

- 已独立提交：Windows全屏状态恢复、启动图与固定等待撤除、弹弹play服务端凭据边界、播放清单公共网络校验、发现调度预算、可取消网页请求职责抽离、Android架构/包体/构建凭据、Android启动CI契约、外部弹幕总等待预算。全部保留原功能提交，不强推或改写旧历史。
- CI启动冒烟原先误断言`.MainActivity`，现按Manifest保留的`.SplashActivity`检查竖屏和横屏；新增三项回归先失败再通过，未跳过启动/PID/崩溃/ANR检查。
- 代码审查发现外部弹幕搜索与评论串行耗时可能超过客户端8秒期限；现已加入6秒总等待预算，超时只降级外部弹幕并返回已有社区弹幕。新增预算契约与普通/个人端点的挂起、串行慢响应回归；相关32项测试通过。共享上游任务保留原缓存生命周期，不因单个请求超时强制取消。
- 服务只读预检：`zeluna.service`运行，v3状态接口200，数据库quick_check为ok、迁移版本`0015_premium_line_catalog`；依赖和数据库结构无需升级。代码差异已按CRLF/LF归一识别，部署时更新完整相关包且保留现有数据库、上传目录、配置和可回滚旧源码。
- 生产环境弹弹play仍关闭，AppId/AppSecret均未配置；不擅自开启，部署代码不等于真实上游联调完成。
- 本机Android签名配置引用的keystore不存在，公开Android发布被阻断。不得新建不明签名身份、改applicationId或将历史内部debug签名作为生产签名。
- 版本候选文档不预填CI成功、主线合并或部署完成；最终结果由对应SHA的远端run、不可变门禁凭据和脱敏部署账本证明。

## 四阶段状态与完成条件

| 阶段 | 本轮已做 | 仍需完成才能验收 |
| --- | --- | --- |
| 1. 安全与现有功能收尾 | 公网清单请求边界、启动图撤下、原生及真实播放器全屏；本地HTTP换集/换线/暂停恢复；相关单测 | 真实外部片源全屏验收；弹弹play服务端真实联调 |
| 2. 主线与交付一致 | 核对全历史、远端引用、7个开放PR、Release；加强APK构建凭据 | 合并主线、精确HEAD CI、版本和Release一致；写入授权与本机GitHub认证已确认 |
| 3. 包体与资源减重 | 移除打包副本、保留原素材、同源码单ABI/三ABI实测 | Android真机安装/覆盖升级和功能验收；正式Release体积实测；确认支持架构 |
| 4. 降复杂度与真实质量 | 抽离取消控制、网页请求与共享HTTP策略；修复调度饥饿/拒绝跳转的响应流回收；复用100作品/167集基线 | 分阶段拆解规则解析与播放器职责；当前两端真实播放、换线、恢复与账号隔离记录 |

## 已实现的变更与保护边界

### 启动与全屏

- Flutter 启动页改为纯色背景，保留初始化和失败重试；不加载图片，不再人为等待500ms。
- Android 保留既有 launcher 组件 `SplashActivity`，直接继承主 Flutter Activity，撤去图片 Activity、缓存引擎交接和700ms固定延迟。
- Android 12+ 启动图标改为透明占位；应用桌面图标未改。700ms和500ms可能重叠，不能相加成实际启动提速。
- 删除一个约2.39MiB的原生启动图打包副本；原素材 `E:\anime\assets\brand\splash\zeluna_android_splash.png` 保留，并从Flutter资源清单撤下。
- 本轮用真实 `AppFullscreenController` 与 Windows runner 进行外部Win32检测：普通窗口、最大化窗口、重复/幂等进入退出共3轮，均无标题栏和调整边框，窗口边界等于显示器边界，原尺寸/位置或最大化状态正确恢复。
- 真实 `PlayerPage`、media_kit解码和Video首帧的集成测试现有本地文件与本地HTTP两个用例，最终相同测试源码连续2轮均通过（每轮2个用例）。生产代码未因本次补测改动。
- 本地文件用例每轮29个独立Win32快照、7组按钮/F/Esc切换与全屏卸载；普通/最大化窗口都覆盖。每轮真实播放日志仅1次line_open_requested和1次first_frame，解码错误0。
- 本地HTTP用例每轮49个Win32快照。除相同基础全屏操作，还在普通/最大化状态分别驱动：进入全屏→下一集→暂停→恢复→备用线路→上一集→Esc退出。切换中保持无标题栏/边框且窗口Rect等于monitor Rect，退出后尺寸、位置、普通/最大化状态、style、extendedStyle和WINDOWPLACEMENT均恢复。
- HTTP用例每轮7次预期打开、7次真实首帧、解码错误0；原生解码器当前媒体URI、播放进度、暂停/恢复状态与真实HTTP请求共同校验，避免仅凭推荐首帧去重计数推断成功。两轮两个用例合计156个窗口快照。
- 按钮与换集/换线操作用WidgetTester真实命中；F/Esc由独立无控制台Win32助手发给指定PID的Flutter窗口，是定向窗口消息，不是人工实体键盘或全局SendInput。助手拒绝其他进程、非法动作和覆盖旧响应文件。
- 测试现场用Dart生成AVI；HTTP服务仅绑定loopback随机端口，仅暴露该生成视频的3个实际访问路径，真实处理Range并交由原生解码。账号/存储/目录发现仍是内存替身；不访问真实账号或外部片源。受控HTTP通过不等于公网CDN、真实片源身份、线上弹幕、真实账号隔离或Android验收。
- 测试工具先前的问题已区分：Y4M不兼容、控制栏热区与助手抢焦点已解决。本次HTTP扩展两轮运行均无运行失败，仅修正新增测试的3处格式规则；未修改生产逻辑迁就测试。
- 探针与测试进程已结束。HTTP集成测试后的正常入口构建见 `windows-normal-entry-after-http.log`；网页请求抽离后的最新正常入口构建见 `page-client-20260907/windows-normal-entry.log`。构建目录不是已安装旧版的自动更新，也不是正式Release。

### 服务端清单安全

- 请求前校验DNS全部结果，仅允许公网地址；连接固定到已验证IP，并保留Host/TLS SNI。
- 关闭环境代理继承和自动重定向；每一跳和每层子清单重新验证。
- 流式限制单清单4MiB、最多5次重定向、总预算12秒，拒绝压缩响应。
- 相对清单地址基于最终逻辑URL解析；失败保留原线路回退。
- 只验证本地代码和测试，未部署线上。

### 小步减复杂度与额外回归修复

- 将取消控制从规则解析器抽到 `E:\anime\lib\src\rules\rule_playback_cancellation.dart`，旧导入通过export保持兼容。新增4个公共行为测试；未更换状态管理或重写解析器。
- 2026-09-07把网页GET/POST、缓存/在途请求、取消/超时、重定向移到 `E:\anime\lib\src\rules\rule_page_client.dart`；网页与媒体共用的代理路由、缓存键和跨站凭据过滤移到 `E:\anime\lib\src\rules\rule_http_policy.dart`。保留 `RulePlaybackResolver` 入口及原异常/测试函数导出，客户端仍由调用方持有，不改媒体解码/账号存储/窗口代码。
- 网页GET与POST复用同一请求流程；缓存仍5分钟、最多128条，清空后旧请求不再回填，独立解析不共享可取消的在途请求。解析器由5604行降至5225行，新模块分别216/194行；这是职责集中而非总代码或安装包已等量变小。
- 沿用 `resolveRule` 公共入口新增12项行为回归：POST的301/302/303与307/308语义、跨源Cookie剥离、失败不缓存、拒绝跳转释放响应流、缓存复用/清空/迟到响应、并发取消隔离、超时中止且不关闭共享客户端。前4项缓存/取消特征测试在抽离前先通过。
- 响应流回收用例先稳定失败（Expected true / Actual false），再以“先释放不使用的跳转响应，再校验目的地”的小修复转绿。该修复只覆盖网页跳转，不把它描述成所有媒体/网络资源生命周期已全面审计。

- 首次最终服务端全量出现1个偶发失败：请求数2，但实际只查询了1个来源。单独5轮中复现1次，未以重跑碰巧通过结案。
- 最小回归稳定复现了原因：备用线路各自计时，先醒来的线路可能消耗第二个别名额度，挤掉同批来源首次查询。
- 改为共用一个备用批次计时器，保留总预算、并发上限和取消回收；新增确定性公平性与关闭计时器测试。
- 修复后全量616项通过，原症状10次加确定性回归25次，共35次连续通过。

## 减重实测与不可夸大的收益

### 资源

停止打包4个无引用品牌图，合计2,135,873字节，原始文件均保留；活跃应用图标、3份中文字体、媒体库和画质增强着色器保持。

`cupertino_icons` 曾作为候选试移除，但构建确认仍有图标字体引用，已恢复。当前 `pubspec.lock` 与本轮执行前SHA-256一致，未升级依赖，不能把删除图标依赖计入收益。

### Android ABI

以下为网页请求抽离前的同源码Profile体积实验；不是本次抽离后源码的APK，也不是正式Release包。本次Flutter改动不新增素材/依赖，但不凭推断承诺新包精确体积。

| 同源码Profile诊断包 | 实际字节 | MiB | 实际架构 |
| --- | ---: | ---: | --- |
| 默认三架构 | 159,225,507 | 151.85 | arm64-v8a、armeabi-v7a、x86_64 |
| ARM64单架构 | 65,458,657 | 62.43 | arm64-v8a |

差值93,766,850字节，约89.42MiB/58.89%。两包使用相同源码、构建模式和签名；共同的ARM64应用/引擎二进制、资源清单与中文字体哈希相同。两包签名均经工具验证，但这不是生产签名认可。

这说明架构精简有实际收益，不代表最终Release必然减少同一百分比，也不是安装体积或首帧提速。原1.1.1旧Release约132.73MiB，不能与新Profile混比；60MiB正式包目标尚未证实。

实现采用 `--target-platform android-arm64 -PzelunaTargetAbi=arm64-v8a`。只设target-platform不会过滤全部传递JNI库；当前Flutter的split-per-abi会改变versionCode，因此不使用split。实测两个APK均为versionName=1.1.1、versionCode=55，launcher保持。

默认正式打包仍是三架构；切换ARM64会失去armv7-only与x86设备兼容，必须先确认目标设备范围。同一版本只交付一种架构目标，不覆盖旧同名文件。

曾发现增量APK有约16MiB空洞；保留该诊断APK后重新生成包，最终统计已排除这一测量干扰。新增只读ZIP体积工具，分别统计实际压缩内容与ZIP/签名/对齐开销，拒绝覆盖旧报告。

### 本地磁盘（盘点，不是已清理）

最终构建后，`E:\anime\build` 约7.07GiB、`E:\anime\.dart_tool` 约2.19GiB，合计约9.25GiB。它们是可重建候选，而非本轮已释放空间；清理会丢失本地构建/测试证据并增加重建时间。

批准清理前先转存必要证据并核验绝对路径。白名单仅上述两项；`release`、`.git`、`.codex_tmp`、`.playwright-cli`、用户数据、签名配置和原始素材均不在清理范围。本轮未清理任何既有缓存/历史包。

## Git、推送边界与PR逐项决策（2026-09-06初查快照）

2026-09-06可达历史共304个提交，当前HEAD祖先链287个。已检查提交清单与变更统计，并以公开页面和 `git ls-remote` 核对当前远端。

- 远端main：`901942147ba24d59642c309eba092679f93ba052`，是当前HEAD的祖先，落后26提交。
- 远端开发分支：`95fed305949bdda7ea6f56987d902b1a822d30e1`；本地HEAD再领先1提交，此外还有本轮/既有未提交修改。
- 公开版本可见v1.1.0，但 `/releases/latest` 仍指向v1.0.12；本地版本1.1.1+55，最新本地正式manifest仍为1.1.0+54。
- Git记录提交与引用，不记录服务器所有push事件。无权限恢复已删除/不可达历史或完整服务端推送审计，不能声称“每一次推送都已还原”。
- 初查gh返回401；2026-09-07已确认原因是失效环境变量遮蔽本机现有登录。只在gh子进程移除覆盖变量后，账户与仓库push权限正常；无需用户重新登录，不复制或打印凭据。

| PR | 判断 | 执行边界 |
| --- | --- | --- |
| #24 播放覆盖与身份修复 | 分支提交已是当前HEAD祖先；主线收敛后再处理PR | 无需重复cherry-pick；未关闭/合并远端PR |
| #6 path_provider 2.1.6 | 可作为独立低风险候选 | 隔离副本依赖解析、analyze、808项Flutter测试通过；未真机验证/未合并 |
| #14 go_router 17.5.0 | 可作为独立候选 | 同上；锁文件只改变目标依赖 |
| #10 xml 7.0.1 | 单独安排升级，不夹进稳定修复 | 同上；同时带动dbus 0.7.12→0.7.15、image 4.8.0→4.9.2，需平台回归 |
| #8 flutter_riverpod 3.4.2 | 暂缓 | 包要求Dart>=3.12.0；当前Dart3.11.1/Flutter3.41.3无法解析。SDK升级应独立验证 |
| #13 四包组合升级 | 拆分再评估 | 包含file_picker 12.0.0-beta.7及secure_storage大版本，稳定发布不一起盲合 |
| #15 setup-uv 10.0.1 | 待真实runner验证 | 已检查固定commit差异，未把本地静态检查当作GitHub CI通过 |

隔离测试只表示“当前工作内容 + 单项升级”的本地结果，不等于原PR全部内容或平台升级验收。当前仓库依赖未变。

## 关键验证账本

- 最新Flutter全量：820通过、26跳过（原808加新增12项网页请求回归）；analyze零问题，格式检查247文件零变化。网页抽离后生产源码已有变化，旧808项/HTTP源码快照不能冒充当前源码凭据；当前快照见 `page-client-20260907`。此前Windows真实播放器本地文件/HTTP两个集成用例连续2轮通过；本次未重跑原生交互，两端启动/全屏生产文件哈希未变，最终重新构建Windows正常入口。
- 26项跳过来自旧控制器规则导入23项、drpy1项、目录页2项；不计作通过，也不推断全覆盖率。
- 2026-09-07最新Python全量：621通过、111个subtests通过（329.11秒）；包含外部弹幕总等待预算新增5项回归。Ruff、compileall、pip-audit --strict均通过，未发现已知漏洞。Starlette/httpx弃用提示1项，未因此贸然升级框架。旧616项仅为历史基线，不与本次累计。
- 工具：Python unittest 11项（含新增3项Android launcher契约）；Android包结构/凭据15用例；Windows包结构、精确HEAD gate、不可覆盖规则均通过。
- 仓库扫描包含tracked+正常untracked文件，强密钥标记/禁止产物检查通过；不是全面证明不存在任何秘密。
- 依赖策略：159个Dart、72个Python包通过；本轮先前pip-audit未发现已知漏洞，结果是时间点快照。
- 构建：Windows正常入口Debug、Android ARM64及默认三架构Profile通过；实际APK无旧启动/闲置品牌图。
- 未构建正式Release，未运行当前精确源码的远端Quality Gates，未做当前真机/线上联调。

## 后续执行顺序与验收标准

### 1. 固定本轮改动与主线

2026-09-07用户已明确授权提交、推送、主线合并、部署和公开发布，本机GitHub认证也已核验。继续执行这些已授权动作；不可把公开发布授权解释为允许调试签名替代生产签名或覆盖旧版。禁止向聊天粘贴token。

复核本轮与原有改动后按启动图/原生全屏、清单安全、弹幕接入、资源与发布工具、调度公平性分别整理提交；不覆盖原有工作。主线应包含全部选定提交，PR状态与祖先关系一致。本次候选已递增为1.1.2+56；打标签前再次核对tag/manifest和远端版本，不复用已有版本。

### 2. 真实设备和固定播放基线

复用 `E:\anime\server\data\maccms_coverage_cases.json`，已有100作品/167集，SHA-256为 `e62ada2c7082e9b11766de6a1f3cf99d6d03c354643a6f406fa47c13add7b9fe`。现有MacCMS覆盖工具可继续使用，避免再建重复基线。此数据不是授权证明，也不是本轮真实播放结果；仅使用有权访问的测试内容。

| 验收面 | 必须记录 | 当前状态 |
| --- | --- | --- |
| Android启动 | 冷/热启动、后台返回、无旧图、无双Activity闪屏、失败重试 | 无ADB设备，未验证 |
| Android覆盖升级 | 相同签名身份、版本递增、账号/设置/进度保留 | 未验证；不卸载、不清数据规避问题 |
| Windows播放器全屏 | 按钮/F/Esc；普通/最大化；换集与退出；真实窗口边界 | 原生层3轮；本地文件及本地HTTP两个用例各2轮通过，覆盖全屏中换集/换线/暂停恢复；真实外部片源未验证 |
| 作品与集数身份 | 100作品/167集记录类型、年份、季、集、来源，不把“有URL”当命中 | 只完成基线盘点，本轮真实结果0 |
| 首帧与换线 | 两端实际首帧时间、失败类别、换线后继续播放，不仅HTTP200 | 未验证；记录实测分布，不填估计值 |
| 进度与隔离 | 暂停恢复、切账号/来源、历史/下载/凭据不串用 | 本地自动测试有覆盖，真机端到端未验证 |
| WebView/下载/增强 | 有权访问的代表内容，两端正常/错误/取消路径 | 未验证 |
| 弹弹play | 服务端已有安全凭据，真实请求/签名/播放弹幕；客户端不持secret | mock通过，当前线上未验证 |

每条真实结果绑定新精确SHA、包哈希、平台/设备、时间、结果、错误分类和已脱敏证据；达不到的项明确写失败或未验证。旧2026-08-24覆盖报告仅代表其旧提交。

### 受控Windows播放器集成测试的复用

- 文件：`E:\anime\integration_test\player_fullscreen_windows_integration_test.dart`、`E:\anime\tool\ci\windows_player_window_probe.ps1`。
- 这是需要可交互Windows桌面的显式集成测试，不属于默认Flutter全量单元/组件测试，也不把其他平台的skip当作通过。
- 在 `E:\anime` 执行：`flutter test --no-pub -d windows integration_test/player_fullscreen_windows_integration_test.dart --dart-define=ZELUNA_TEST_REPOSITORY=E:\anime --dart-define=ZELUNA_TEST_OUTPUT=<本地证据目录>`。
- 默认执行本地文件和本地HTTP两个用例，会打开自己的临时播放器窗口。不要在测试期间抢焦点；Win32助手只操作该测试进程。HTTP仅监听loopback随机端口，视频与助手现场生成，用完删除，不入库。
- 每次运行后必须执行 `flutter build windows --debug --no-pub --target lib/main.dart` 恢复正常入口，避免把integration_test构建误当软件交付。
- 后续要扩大到真实外部片源，必须绑定受授权内容并实测网络/来源链路；不得把本地HTTP换集、换线结果直接写成公网来源或账号隔离已通过。

### 3. 精确HEAD发布

沿用 `E:\anime\docs\release-governance.md`。生产签名身份仍需明确认可；历史内部Debug证书不能冒充公开生产发布签名。

在全部验收和授权满足后，等待新精确SHA的远端Quality Gates，取得对应凭据，按选定架构打包，再核对versionName/build、签名、ABI、包哈希、CI run与manifest。Android跳过构建只能复用有匹配构建凭据的APK，不能给旧手工包补写新HEAD声明。

正式命名仍为 `Zeluna-vX.Y.Z-Android.apk` 和 `Zeluna-vX.Y.Z-Windows.zip`。APK新增 `.build.json`与`.sha256`旁件；清单记录实际架构与凭据摘要，签名真实性仍由发布检查负责。保留旧不可变版本，确认Latest确实指向新正式Release。

### 4. 继续减复杂度，不做框架重写

已完成本轮有边界的取消、网页请求与共享HTTP策略抽离；解析器现5225行，目录页4963行、播放器3057行仍偏大。暂不因外部验收等待而继续扩大重构。后续独立迭代再处理媒体探测资源生命周期、播放器会话状态等，每次只迁移一个公共契约并回归，不能声称巨型模块问题已全部解决。

每次迁移以原功能、账号隔离、取消与错误路径不退化为完成条件；不为追求行数缩减删中文字体、媒体引擎或画质功能。

## 证据位置与继续工作前的刷新

2026-09-07网页请求整理的最新证据位于下述根目录的 `page-client-20260907`：`verification.json`、`validated-source-files.json`、`flutter-tests.jsonl`、`flutter-analyze.log`、`flutter-format.log`、`windows-normal-entry.log`、`contract-before.log`、`contract-final.log`、`redirect-cleanup-red.log`及`redirect-cleanup-green.log`。`before/`保留仅本轮目标文件的原始副本。最新证据仅代表本地脏工作区，不是新Git提交/CI/Release凭据。

本轮证据根目录：`C:\Users\h1175\AppData\Local\Temp\zeluna-next-20260906`。

- `verification-summary-final.json`、`validated-source-files.json`：本地结果和源码摘要；不是CI发布凭据。
- `profile-comparison-final.json`、`*-final-profile-size.json`、`profile-signature-validation.json`：同模式体积/签名证据；对应诊断APK保留在同目录。
- `server-tests-final.log`、`fallback-wave-red.log`、`fallback-wave-green.log`、`fallback-wave-stress-final.log`：失败→修复→全量/连续回归。
- `flutter-tests.jsonl`、`dependency-matrix-results.json`及各PR日志：本地与隔离测试。
- `cache-candidates-final.json`、`remote-refs.txt`、公开GitHub页面快照：时间点盘点。
- Windows播放器最新证据：`player-fullscreen-http-run-1.log`、`player-fullscreen-http-run-2.log`；对应本地文件报告 `player-fullscreen-1788723363275677.json`、`player-fullscreen-1788723518188611.json`，HTTP报告 `player-fullscreen-1788723413590992.json`、`player-fullscreen-1788723568294689.json`。
- `player-fullscreen-http-verification-final.json`、`validated-source-after-http-player-test.json`：最新补充结果、命令及本地源码绑定；不是CI/发布凭据。原本地文件单用例证据保留，不与扩展后的测试重复累计。
- `windows-normal-entry-after-http.log`、`flutter-analyze-http-final.log`、`flutter-format-http-final.log`、`startup-fullscreen-http-final.log`：正常入口恢复及补充回归。
- Windows物理窗口证据：`C:\Users\h1175\AppData\Local\Temp\zeluna-fix-20260906\fullscreen\results.json`及同目录各轮JSON。
- 原仓库/提交盘点：`C:\Users\h1175\AppData\Local\Temp\zeluna-audit-20260906`。

这些目录是本机临时证据，不随Git发布且可能被系统清理；正式交付前选择必要的脱敏报告归档。继续执行时先重新检查工作区、远端引用、版本、设备和授权，不能把本文件的快照当成永远有效的状态。
