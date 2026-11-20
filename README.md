# Zeluna

**番剧 · 剧集 · 电影，一个客户端看完。**

Zeluna 是面向番剧、电视剧和电影的跨平台播放器。默认在线服务提供中文资料与播放线路，也可在客户端接入自己的媒体库。界面采用黑白「画廊 + 放映厅」设计。

默认在线服务：[api.zeluna.top](https://api.zeluna.top)

---

## 为什么是 Zeluna

| | |
| --- | --- |
| **开箱可用** | 首页、搜索、详情和默认线路由在线服务提供，不必先配置媒体库或导入规则。 |
| **资料靠谱** | 番剧走 Bangumi，影视走 TMDB；标题、海报、简介、分集信息面向中文用户整理。 |
| **多线路播放** | 在线服务探测并缓存多站线路；客户端结合本机测速和广告标记排序，失败可自动换线。 |
| **播放器好用** | 通栏进度、弹幕输入、选集/线路/字幕、倍速与快捷键；支持平台还可开 Anime4K 超分。 |
| **多端一致** | Windows、Android 和 Web 采用同一套黑白界面；支持浅色和深色主题切换。 |

---

## 功能一览

### 发现与片库
- 番剧、电视剧、电影分频道浏览与搜索  
- 「全部 / 可播放」筛选，优先看已确认有线路的内容  
- 详情页：简介、分集、推荐与播放入口  
- 追番、收藏、历史记录本地优先；登录云账号后可跨设备同步

### 播放
- MP4 / WebM / MKV / HLS / DASH 等常见格式（`media_kit`）  
- B 站风格控制层：进度、弹幕、快进快退、倍速、音量、全屏、截图  
- 支持多线路切换；遇到广告时可用「标记有广告并换线」，降低这条线路的优先级
- Anime4K 实时超分（视平台支持，在「设置 → 播放设置」开启）  
- Bilibili 公开字幕、Zeluna 服务端接入[弹弹play开放弹幕网络](https://www.dandanplay.com/)（可关）

### Android 应用内更新
- **我的 → 版本信息 → 应用更新**：检查新版本、查看说明、下载安装包，再由 Android 确认安装
- 下载进度、取消与重试；安装前核对完整性、版本、包名与当前签名
- 可选启动时检查，默认关闭，不自动下载或安装，播放时不显示更新提示
- 旧版用户先手动覆盖安装 v1.4.0；后续版本可从 App 内检查与下载，无需卸载旧版

### 账号与同步
- 邮箱注册 / 验证码 / 登录 / 改密 / 找回密码  
- 令牌存系统安全凭据，客户端不保存密码  
- 同一邮箱可在 Android 与 Windows 登录并共享云端资料
- 收藏、追番、历史、播放进度、外观与播放设置支持增量云同步
- 下载内容、规则 Cookie / 令牌和私有媒体库连接信息仅留在本机，不参与云同步

### 进阶（可选）
- 私有媒体库：在 Windows / Android 的「设置 → 媒体源」添加 Emby、Jellyfin 或 WebDAV / Alist；匹配到的番剧、剧集和电影会在原有播放页显示为私有线路。
- 规则订阅：支持 Kazumi、Animeko、TVBox 及 MoonTV / LunaTV / LibreTV JSON 订阅，内置常用开源社区订阅快捷填入，预览后可整组启用；应用运行时定期刷新，新增或变更的规则须再次确认。
- 自定义直链、本地文件和自建后端也可作为默认服务的补充。

日常使用无需导入任何源；扩展能力给需要的人，不挡新手。

---

## 界面

**画廊 + 放映厅**

- 浏览：浅色纯白底、深色纯黑底，使用灰阶和反差区分控件，红色保留给错误提示。
- 播放：固定深色放映厅，不随浏览主题改变。
- 桌面与移动端统一导航、卡片、空态与错误提示  

---

## 快速开始

### 使用已部署服务（推荐）

1. 安装 Windows / Android 客户端，或打开 Web 版  
2. 默认已指向 `https://api.zeluna.top`  
3. 需要时在 **设置 → 在线服务** 修改地址，或关闭在线服务  

> 公开包请确认来源可信。自行编译见下文。

### 从源码运行

```powershell
flutter pub get
flutter run -d windows
```

本机实时调试可双击仓库根目录的 `启动实时调试.cmd`，或运行
`powershell -NoProfile -File tool/run_dev.ps1`。保持终端打开，修改 Dart
界面后按小写 `r` 热重载；需要重新执行初始化时按大写 `R`；按 `q` 结束。
启动脚本不会自动监视文件，也不会清理账号或应用数据。Android 连接开发设备后，
可用 `tool/run_dev.ps1 -Device <设备ID>` 启动同样的调试会话。

热重载依赖当前源码、Flutter SDK 和运行中的调试连接，独立 EXE/APK 不会自动
同步代码。原生插件/平台代码修改需要停止后重跑。Debug 版只用于功能和界面体验，
性能不能等同于正式 Release 版；本地调试产物不替代正式发布的 exact-HEAD 门禁。


Web 本地预览：

```powershell
flutter build web
$env:PORT=5174
node tools/dev_web_server.mjs
```

浏览器打开 `http://127.0.0.1:5174/`。也可用 `tools\start-web.bat`（端口 `5190`，已兼容 Clash fake-IP）。

指定后端（可选）：

```powershell
flutter run -d windows `
  --dart-define=ZELUNA_BACKEND_ENABLED=true `
  --dart-define=ZELUNA_BACKEND_URL=https://api.zeluna.top `
  --dart-define=ZELUNA_ACCOUNT_URL=https://api.zeluna.top
```

---

## 它如何工作

| 位置 | 职责 |
| --- | --- |
| 在线服务 | 聚合 Bangumi 番剧和 TMDB 剧集、电影资料，匹配、探测并缓存播放线路。按需清洗 HLS 播放清单，不保存视频文件。云账号与同步也是可选的在线功能。 |
| Zeluna 客户端 | 展示资料，解析已启用的客户端规则，探测和排序候选线路，播放、切线和显示弹幕。测速与广告标记保留在本机。 |
| 私有媒体库 | 由客户端连接和选片，不经 Zeluna 在线服务。连接信息与凭据保存在系统安全存储，不上传云端。 |

- 客户端和服务端以 `bangumi:{id}`、`tmdb:tv:{id}`、`tmdb:movie:{id}` 关联作品。
- 普通公开媒体默认由播放器直连片源；需要隔离凭据或明确启用本机清洗时，才在本机做播放转接。
- 管理员可将经过授权和审核的远程 HLS / MP4 / DASH 地址绑定到稳定作品 ID。管理线路只保存地址与审核资料，使用与 URL 无关的 `line_id`，在响应时与聚合线路合并，不进入聚合缓存。
- 在线服务不可用时，应用会提示，不把未验证的线路显示为默认可播。

部署与运维细节见 [`server/DEPLOY.md`](server/DEPLOY.md)。

---

## 平台与构建

| 平台 | 说明 |
| --- | --- |
| Windows | 主要桌面目标，`flutter run -d windows` |
| Android | Debug 侧载或签名 Release / AAB |
| Web | 须 HTTPS 部署；开发请用自带 dev server，勿直接打开 `index.html` |

Release 检查与打包：

```powershell
powershell -ExecutionPolicy Bypass -File tool/check_release.ps1
# 另见 tool/package_windows_release.ps1、tool/package_android_release.ps1
```

正式 Android 包需自备 `android/key.properties`（参考 `android/key.properties.example`），密钥勿提交。  
元数据令牌（TMDB / Bangumi）应配置在**服务端**环境中，不要打进公开客户端。

验证：

```powershell
flutter analyze
flutter test
cd server && uv sync --frozen --all-groups && uv run pytest -q
```

---

## 自建后端

`server/` 提供 FastAPI 统一后端：目录与播放 API、线路缓存、云账号与邮件验证码、后台预热。

自建实例还可启用 `managed.urls` 管理线路。该能力默认关闭；部署者完成数据库迁移后，通过现有管理员认证依次执行“添加 → 验线 → 批准 → 启用”，再开启播放合并开关。只接受公共 HTTP(S) 直接媒体地址，请求头仅允许非敏感的 `Referer` 和 `Origin`。

```powershell
cd server
uv sync --frozen --all-groups
uv run python run.py
# http://127.0.0.1:8000
```

生产使用 `run_prod.py`，并配置 `SECRET_KEY`、SMTP、`CORS_ORIGINS`、HTTPS 等，详见 [`server/DEPLOY.md`](server/DEPLOY.md)。

在 App **设置 → 在线服务** 填入你的地址即可；也可用 `ZELUNA_BACKEND_URL` / `ZELUNA_ACCOUNT_URL` 在构建时写死。

---

## 当前限制

- 离线下载：单文件与未加密 HLS VOD；DASH / 直播 / 加密 HLS 暂不支持  
- Web 端下载能力受浏览器限制，暂不支持连接私有媒体库。
- 私有线路的原画播放取决于源文件、网络和设备解码能力。
- 未统一接入 DLNA / AirPlay / Chromecast（可复制地址到外部播放器）  
- 下载媒体、下载任务以及规则 Cookie / 令牌仍仅保存在当前设备
- Anime4K 在部分平台（如 Web）不可用  
- 自动更新需在正式发布渠道确定后配置  

---

## 使用说明

- 请仅添加和播放你有权访问的内容。  
- Zeluna 不预置付费影视账号，也不在服务器上缓存视频文件。  
- 用户自行导入的规则、Cookie 与令牌只保存在本机。  
- 项目仍在活跃迭代，接口与界面可能继续调整。  

---

## 文档地图

| 文档 | 内容 |
| --- | --- |
| 本 README | 产品介绍与快速开始 |
| [`server/DEPLOY.md`](server/DEPLOY.md) | 后端生产部署、环境变量、验收 |
| [`server/.env.example`](server/.env.example) | 服务端环境变量模板 |
| `assets/shaders/anime4k/` | Anime4K 着色器资源说明 |

---

## 贡献与反馈

欢迎 Issue / PR。提交前建议本地通过：

```powershell
flutter analyze
flutter test
```

较大改动请先说明动机与影响面（客户端 / 服务端 / 两者）。

---

## 许可证

Zeluna 项目代码采用 [Apache License 2.0](LICENSE) 许可。第三方依赖、字体、
着色器和其他外部素材继续适用各自的许可证与声明，详见
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。
