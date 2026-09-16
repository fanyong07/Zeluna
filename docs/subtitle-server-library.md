# 服务器内置字幕库与 Google Drive 存储

## 当前状态（必须先读）

用户已将需求从「本地导入为主」改为「尽量覆盖所有作品、字幕放在服务器，容量不足可用其 Google One/Drive 5 TB 空间」。本文件是当前实现交接；`subtitle-enhancement.md` 的播放器部分仍适用，但服务器只做短期缓存的旧约束已被本文件取代。

**已完成代码路径，不等于内容或线上环境已准备好：**

- 已实现持久字幕库、运营批量入库、目录覆盖统计、客户端优先取内置字幕。
- 已实现可选的 Google Drive 私有文件适配；没有进行用户 OAuth，没有读写用户云盘，没有公开分享文件。
- **真实作品字幕下载 0、实际入库 0、生产部署 0。** 所有测试字幕均是测试生成的对白，不算作品覆盖率。
- 本机目录快照只有 9 部已缓存作品，不是生产服务器的全站目录。本机磁盘检查也不代表 VPS 剩余空间，不能据此擅自切换 Drive。
- Jimaku、Kitsunekko、OpenSubtitles、OPUS 的来源准入结论见 `subtitle-server-sources.md`。未取得批量获取和集中提供的明确依据前，不运行抓取或镜像任务。

## 目标与使用效果

首次在作品内启用「显示外挂字幕」后，应用查询服务器内置字幕；唯一且已人工核对身份的候选自动加载。同作品后续集沿用启用状态，优先加载其自己的缓存，否则查服务器；多个版本或未核对身份时仍需选择。片源原有中文和当前线路的双语标记保持不变。

最终范围是**持续扩展当前目录覆盖**，不是承诺覆盖全部已有、未来、特别篇和所有视频版本。国语已有中文通常不需要补一层。字幕身份匹配与时间轴一致性分别验收。

## 结构与数据边界

- `server/subtitle_library.py`：独立 SQLite 索引与内容哈希寻址文件；只在运营入库时初始化，API 普通读取不建表、不迁移主账号库。
- `server/subtitles.py`：先查持久库，再考虑已准入的在线 provider。内置字幕 ID 持久有效；旧在线临时候选仍有 10 分钟缓存。
- `server/subtitle_google_drive.py`：仅访问 Google 固定 HTTPS API，禁止重定向；只使用 `drive.file`，只存取指定私有文件夹的应用文件。
- `tools/subtitle_library.py`：服务器本地运营命令，无面向普通用户的上传、路径或任意 URL 代理接口。
- Flutter 手动导入仍仅在账号本地；**不会自动上传用户导入文件到服务器或 Google**。
- Google 只保存私有文件字节，索引留在服务器持久磁盘。客户端拿到的是服务端的候选 ID 和文件内容，不拿 Google 文件 ID、公开分享 URL 或 OAuth 凭据。

### 入库检查

每个文件都要求明确的作品稳定标识、分集号或已有分集稳定标识、语言、原文件名、来源说明、使用依据，以及允许向应用用户提供文件的声明。`identity_reviewed=true` 才允许自动加载；这不是自动推断。

- 支持 UTF-8 / UTF-16 BOM 的 SRT、VTT、ASS、SSA。
- 单文件 5 MiB，最多 50,000 条对白，单条内容受限。
- 验证有效起止时码及对白，不把 HTML、损坏编码、反向时间、空字幕或压缩包登记为可用内容。
- 内容 SHA-256 校验、原子写入、同内容去重；文件名／语言／版本不同的元数据不互相覆盖。
- 非当前导入目录中的文件（包括穿越、外部符号链接）拒绝读取。
- 大批量分为最多 500 条一批，逐条记录成功或失败，可以幂等重跑，不整批吞掉错误。
- 来源声明是运营审核记录，不是程序代替权利人授予许可。不得把开源下载器的许可证当作其中所有字幕的许可。

## 运营命令

以下命令在 `server/` 目录使用其现有 Python 环境执行；默认不会联网搜索、扫描视频文件或部署。

```text
python tools/subtitle_library.py inventory
python tools/subtitle_library.py storage-check
python tools/subtitle_library.py coverage --catalog-db /private/zeluna/data.db
python tools/subtitle_library.py import --manifest /private/approved/manifest.json --files /private/approved/files
```

最后一条默认 **dry-run**：验证清单和文件，不创建字幕库、不上传 Drive。确认报告后，运营人员显式加 `--apply` 才入库。`--root /private/subtitles` 可在子命令前覆盖索引与本地目录。

覆盖统计只读取 `catalog_subjects`，不查账号、令牌、视频 URL。区分缺失、部分收录、已知集数登记齐全、语言不明、集数不明、国语无需补原文。分母是本次本地数据库的已知目录，版本重复不重复计数；结果明确标记**只统计登记绑定，不证明实时下载和时间轴同步**。

清单形状（字段中的说明必须换成已核验值，不能把示例当真实字幕）：

```json
{
  "schema_version": 1,
  "items": [{
    "file": "season/subtitle.ja.srt",
    "subject_key": "bangumi:100",
    "episode_number": 1,
    "language": "ja",
    "file_name": "subtitle.ja.srt",
    "source": "填写实际字幕来源",
    "rights_basis": "permission",
    "rights_reference": "填写实际授权记录或许可依据",
    "redistribution_allowed": false,
    "identity_reviewed": false,
    "release": "填写实际对应片源版本"
  }]
}
```

示例故意保留 `redistribution_allowed=false`，会被拒绝入库。不能机械改成 true；必须先核验依据。可选 `episode_key` 用于已有非默认稳定标识；缺省使用现有 `stable_episode_key(subject_key, episode_number)`。

## 本地磁盘与 Google Drive

### 默认本地（无 Google 访问）

```text
SUBTITLE_BLOB_STORAGE=local
SUBTITLE_LIBRARY_DIR=/var/lib/zeluna/subtitles
SUBTITLE_CACHE_MAX_MB=256
```

字幕索引和 `objects/` 应位于持久磁盘，不能放到静态文件公开目录。`.gitignore` 排除了默认字幕内容目录；不要提交真实字幕、授权记录或凭据。

`storage-check` 只测命令当前所在机器的磁盘。应先在**确认的生产服务器**执行再决定是否需要 Drive，不能拿开发电脑容量冒充服务器容量。

### 可选 Drive（需要新的明确授权）

Google One/Drive 的 5 TB 存储空间不是 Google Cloud Storage bucket，也不是无限 API / 下载额度。官方配额与权限文档已经通过 You MCP 核验；不据此承诺免费、无限或无维护成本。

接入前必须：

1. 用户明确同意服务器持有可撤销的 OAuth 授权；若此前“不新增密钥”的约束仍坚持，需要另行确认服务端 OAuth 客户端配置，不暗中创建应用、启用计费或注册账号。
2. 准备服务器应用自己的 OAuth client，并由用户完成 Google 登录和 `https://www.googleapis.com/auth/drive.file` 授权。不是把账号密码或令牌粘贴到聊天。
3. 专用文件夹必须由该 OAuth 应用创建，或经官方 Picker 明确选给该应用；单纯复制任意私人文件夹 ID 不会自动赋予 `drive.file` 权限。
4. 保持专用文件夹未共享。本实现拒绝 `shared=true` 的文件夹和文件，不调用任何分享权限 API。
5. 将 authorized-user JSON 放在仓库外的私有路径。字段为 refresh_token、client_id、client_secret、scopes，类型为 authorized_user（Google credentials.to_json 可省略 type）。Linux 文件权限要求 0600；Windows 需运营人员设置仅服务账号可读的 ACL。

批准并完成授权后才配置：

```text
SUBTITLE_BLOB_STORAGE=google_drive
SUBTITLE_LIBRARY_DIR=/var/lib/zeluna/subtitles
SUBTITLE_GOOGLE_CREDENTIALS_FILE=/etc/zeluna/private/drive-authorized-user.json
SUBTITLE_GOOGLE_FOLDER_ID=专用私有文件夹ID
SUBTITLE_CACHE_MAX_MB=256
```

然后运行 `python tools/subtitle_library.py drive-check`：只检查专用文件夹与容量配额，不上传文件；不会输出令牌或用户邮箱。当前未执行过真实账号的这一步。

Drive 模式下，新入库字幕写入专用文件夹；服务器仅保留索引和有上限的 `cache/`，减少反复下载。缓存命中且哈希正确时无需访问 Drive；配额、权限、网络或内容校验失败均降级为字幕来源不可用，不影响视频。已有本地 `objects/` 不被自动迁移或删除，避免切换存储导致不可逆损失。

**备份要求：索引和 Google 文件都需要保留。只有 5 TB 文件而丢失作品分集索引，也无法可靠匹配。** 停用时可改回 local 并撤销 Google 授权；未保留本地原件的云端字幕会不可用，必须先安排迁回，不能承诺自动无损回切。

## 验证与未完成事项

- 最终代码服务端全量回归 778 项通过、233 项子测试通过；仅有既有 Starlette TestClient 弃用警告。日志：`artifacts/subtitle-qa/server-all-library-verified.log`。

- 已有 51 项字幕服务／持久库／Drive 适配测试通过，覆盖模拟上传下载、限定目录、拒绝广泛 scope、拒绝共享、禁止重定向、配额失败、内容校验、缓存与重启，以及同文件并发冷读仅下载一次。
- 客户端全量 912 项通过、26 项跳过，含无需手动导入就加载唯一内置候选，以及本地缓存复用；静态分析与 Web 构建另有当前日志。
- Google API 测试使用 MockTransport，不是用户账号联通证明；新库 HTTP 测试使用真实临时索引／文件和 ASGI 应用，但字节是合成字幕，不是实际作品。
- 源站实际批量下载、生产服务器容量与路径确认、用户 Drive OAuth、真实上传下载、生产部署、实际作品字幕同步均未完成。
- 不启用后台定时抓取任务：没有准入来源时，定时扫描不能解决覆盖问题。下一步应先确定字幕来源的服务端授权与允许的存储范围，再用生产目录按缺失清单入库。

## 官方参考

- https://developers.google.com/workspace/drive/api/guides/api-specific-auth
- https://developers.google.com/workspace/drive/api/guides/manage-uploads
- https://developers.google.com/workspace/drive/api/guides/manage-downloads
- https://developers.google.com/workspace/drive/api/guides/search-files
- https://developers.google.com/workspace/drive/api/guides/limits

来源核验是文档与接口规则核验，不是对用户账号实际权限、剩余容量或收费状态的核验。
