# Zeluna

跨平台动漫、电视剧和电影资料聚合与播放客户端，使用 Flutter 构建。

## 当前能力

- 聚合 Bangumi、AniList、Jikan/MyAnimeList、Kitsu、Cinemeta、TVMaze、Wikidata 资料。
- Cinemeta 电影/剧集按热门目录多页加载，提供 IMDb 标识、海报、横幅和基础详情。
- 接入 Internet Archive 官方公开媒体搜索、分页与经许可/文件探测后的直接播放。
- 接入 Sepia Search + PeerTube，仅展示明确开放许可且非 NSFW 的视频，并解析 HLS / MP4。
- 接入 Wikimedia Commons MediaWiki API，仅保留公共领域、CC0、CC BY、CC BY-SA 视频，并按 480p / 720p / 1080p 匹配可用的 WebM 转码，不改变目录排序。
- 电影和剧集按 IMDb ID 批量使用 Wikidata 中文标题与简介；AniList、Jikan、Kitsu 动漫按原名严格匹配 Bangumi 中文资料，未匹配时保留原文而不伪造翻译。
- 支持规则插件解析、自定义网络直链和本地媒体文件。
- 使用 `media_kit` 播放 MP4、WebM、MKV、HLS、DASH 等常见格式。
- 提供 YouTube / 哔哩哔哩风格控制层：进度、快进快退、倍速、音量、全屏、影院模式、截图、选集、线路、字幕和弹幕。
- 网页播放器会区分“浏览器阻止自动播放”和“媒体地址失效”，并提供原生播放按钮兜底；电影、剧集、番剧频道可只看已验证可播放内容。
- 支持 Bangumi/Bilibili/弹弹play 等公开资料、字幕和弹幕匹配框架。
- 支持本机多账号注册、登录、切换、改密和资料管理；收藏、追番、历史与个人偏好按账号隔离。
- 本地保存追番、收藏、历史、设置和下载任务；首次创建账号会把已有游客数据完整迁移到新账号，并清空游客空间。
- 桌面端和移动端使用统一的黑白中性设计系统，支持顶栏日间/夜间快速切换，以及一致的导航、卡片、筛选、加载/空白/错误状态与响应式布局。

## 运行

```powershell
flutter pub get
flutter run -d windows
```

网页调试：

```powershell
flutter build web
$env:PORT=5174
node tools/dev_web_server.mjs
```

打开 `http://127.0.0.1:5174/`。开发服务器包含媒体代理，用于缓解部分网页视频和横幅图片的跨域限制；网页预览建议使用该服务器，不要直接双击 `build/web/index.html`。

## 验证

```powershell
flutter analyze
flutter test
flutter build web --release
```

## Android 内测与正式发布

本地侧载内测使用 debug APK，不需要生产密钥：

```powershell
flutter build apk --debug
```

正式 APK / AAB 不允许使用 Android debug 证书。发布前先复制
`android/key.properties.example` 为 `android/key.properties`，填写四项真实值并让
`storeFile` 指向本机私有密钥库；密钥、密码和 `key.properties` 均不得提交。缺少字段、
仍使用示例值、密钥库不存在、别名或密码无效时，release 构建会直接失败。

```powershell
flutter build appbundle --release
flutter build apk --release
powershell -ExecutionPolicy Bypass -File tool/check_release.ps1
```

公开发布前还必须确认最终包名和版本号。当前通用包名会被发布检查脚本主动阻断。

## 数据源说明

- 资料源默认使用公开 API，不要求用户填写账号密钥。
- Internet Archive 条目的授权状态由各条目自身说明决定。
- 资料条目与播放线路分开管理；没有直链的条目只显示为“仅资料”。
- PeerTube 内容来自不同开放视频实例，应用会过滤许可与内网地址，但仍以条目自身声明为准。
- Wikimedia Commons 会在发现和播放前分别复验许可，只接受公共领域、CC0、CC BY、CC BY-SA，并优先使用官方 WebM 转码。
- 规则插件和用户自定义地址只负责解析用户主动访问的内容。
- 自定义仓库支持 GitHub 仓库首页、raw JSON 和本地 JSON；Cookie、Token、Authorization、TVBox 多仓与脚本引用会按原配置保存。
- 应用本身不预置账号、Cookie、付费服务密钥或私有影视凭据；用户导入的配置保存在本机。
- 请只添加和播放自己有权访问的媒体。

## 当前限制

- 离线下载支持 MP4、WebM 等单文件及未加密 HLS VOD；DASH、直播清单和加密 HLS 暂不支持。
- 网页端离线下载受浏览器限制，推荐使用桌面或移动客户端。
- 原生 DLNA、AirPlay、Chromecast 投屏尚未统一接入；当前可以复制播放地址到外部播放器。
- 当前账号系统仅在本机生效，密码不会以明文保存，但不会加密设备文件；云账号、邮件找回和跨设备同步尚未启用。
- 自动更新需要在确定正式发布地址后配置。

## 服务端

`server/` 包含 FastAPI 兼容服务端原型：

```powershell
cd server
pip install -r requirements.txt
python run.py
```

服务端仍属于开发模式。部署前必须更换 `SECRET_KEY`、限制 CORS、删除演示账号并配置 HTTPS 和正式数据库。
