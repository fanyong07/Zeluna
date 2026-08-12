# Zeluna

**番剧 · 剧集 · 电影，一个客户端看完。**

Zeluna 是跨平台影视聚合播放器。打开即用：统一在线服务提供中文资料与已验证播放线路，播放器按 B 站习惯设计，桌面和手机同一套雾蓝「画廊 + 放映厅」界面。

默认在线服务：[api.zeluna.top](https://api.zeluna.top)

---

## 为什么是 Zeluna

| | |
| --- | --- |
| **打开就能看** | 不必先配源、导规则。首页、搜索、详情和线路由在线服务统一提供。 |
| **资料靠谱** | 番剧走 Bangumi，影视走 TMDB；标题、海报、简介、分集信息面向中文用户整理。 |
| **线路先验证再给你** | 后端多站绑定同一作品，缓存可播地址；不代理、不存片，失败可自动换线。 |
| **播放器好用** | 通栏进度、弹幕输入、选集/线路/字幕、倍速与快捷键；支持平台还可开 Anime4K 超分。 |
| **多端一致** | Flutter 构建，Windows / Android / Web 等同一套体验；日夜间一键切换。 |

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
- 多线路切换；播放失败时可自动换线  
- Anime4K 实时超分（视平台支持，在「设置 → 播放设置」开启）  
- Bilibili 公开字幕、弹弹play 等弹幕匹配（可关）  

### 账号与同步
- 邮箱注册 / 验证码 / 登录 / 改密 / 找回密码  
- 令牌存系统安全凭据，客户端不保存密码  
- 同一邮箱可在 Android 与 Windows 登录并共享云端资料
- 收藏、追番、历史、播放进度、外观与播放设置支持增量云同步
- 下载媒体、规则 Cookie / 令牌等私密本地数据不会上传云端

### 进阶（可选）
- 规则订阅 / 网页选择器、自定义直链、本地文件——作为官方线路的补充  
- 自建后端：把默认服务换成你自己的实例  

日常使用无需导入任何源；扩展能力给需要的人，不挡新手。

---

## 界面

**画廊 + 放映厅**

- 浏览：暖纸面（浅色）/ 暖炭灰（深色），雾蓝强调  
- 播放：固定放映厅深色，专注内容  
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

```text
┌─────────────┐     作品 ID / 搜索      ┌──────────────────┐
│  Zeluna App │ ───────────────────► │  在线服务 API     │
│  Flutter    │ ◄─────────────────── │  api.zeluna.top   │
└─────────────┘   元数据 + 可播线路     │  (可自建)         │
       │                                └────────┬─────────┘
       │ 可选：规则订阅 / 直链 / 本地文件          │ Bangumi · TMDB
       ▼                                         │ 多站线路探测与缓存
  media_kit 播放器                                ▼
                                          不中转、不存储视频流
```

- 客户端只使用稳定 ID：`bangumi:{id}`、`tmdb:tv:{id}`、`tmdb:movie:{id}`  
- 服务端完成资料聚合与线路验证；片源直连播放器  
- 后端不可用时，应用会明确提示，而不会假装仍有官方线路  

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
- Web 端下载能力受浏览器限制  
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
