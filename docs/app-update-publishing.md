# Android 应用内更新与静态清单发布

## 两种更新来源

### 默认：GitHub 最新正式 Release，无自建服务器也可工作

包含更新模块的客户端默认请求：

```text
https://api.github.com/repos/fanyong07/Zeluna/releases/latest
```

客户端选择非 draft、非 prerelease 的正式版本，读取该版本已有的 `zeluna-release-manifest-v2` 清单及精确命名的 APK：

```text
Tag:       vX.Y.Z
Manifest:  Zeluna-vX.Y.Z-manifest.json
APK:       Zeluna-vX.Y.Z-Android.apk
```

版本、APK 名称、字节数及 SHA-256 来自该正式 Release 的清单；用户可见更新说明来自 GitHub Release body。匿名 API 返回 403/429 时，客户端仅对固定的 GitHub 仓库 latest 页面发起 HEAD 请求，沿同仓库的重定向获取严格版本 Tag，再读取该版本清单；此时更新说明显示“更新内容请参阅发布说明”，通过“查看完整发布说明”打开对应发布页。不解析网页 HTML，也不请求或保存 GitHub token。默认模式不要求额外部署服务，也不要求为既有 GitHub Release 添加静态更新清单 asset。正常网络访问 GitHub 仍是前提，私有内网地址不是更新源。

本次改动尚未发布含更新模块的新版应用。**首次需手动安装未来正式发布、已经集成该模块的 APK**；当前已安装的旧版本不会仅因生成一份 JSON 就获得更新入口。此后 Android 原地更新必须保持包名 `app.anime.anime` 与兼容签名，并遵守仓库规则同时递增用户可见版本 `X.Y.Z` 和内部 build 号。

### 可选：独立 HTTPS 静态清单

有自定义分发需求时，从**已发布且可信的 release-v2 manifest** 派生 `zeluna-app-update-v1` JSON，放在公共 HTTPS 静态托管上。APK 默认仍从原 GitHub Release 下载；`--download-base-url` 只是显式选择已存在、逐字节相同的 APK 镜像目录。

自定义构建通过以下编译期配置选择静态清单：

```text
--dart-define=ZELUNA_UPDATE_MANIFEST_URL=https://updates.example.com/zeluna/android/update-vX.Y.Z.json
```

例如，在既有正式构建流程中添加此参数（示意命令，本工具不执行构建）：

```powershell
flutter build apk --release --dart-define=ZELUNA_UPDATE_MANIFEST_URL=https://updates.example.com/zeluna/android/latest.json
```

该构建命令示例不是发布步骤全集；实际交付仍执行原有 Quality Gates、构建凭据、版本及签名流程。配置属于编译期参数；已有二进制不会自动读入后来更改的配置。启用自定义 URL 后客户端读取该静态清单，而不是默认 GitHub latest 入口。清单 URL 与下载 URL 都应使用公共 HTTPS，保持有效证书；依赖重定向时，链路中的目标也须满足客户端网络策略。

## 离线生成命令

使用 Python 3.10 或更新版本；无第三方 Python 依赖。脚本只读取本地 manifest 和可选 notes 文件，**不发起 HTTP 请求、DNS 查询、构建、签名或发布操作**。

以下命令在仓库根目录运行。`release-notes.txt` 是操作者准备的 UTF-8 用户发布说明；输出使用全新路径，重跑时需另选文件名。

```powershell
python -B tool/create_app_update_feed.py `
  --manifest release/v1.3.1-769ee519ada0/Zeluna-v1.3.1-manifest.json `
  --output out/app-updates/v1.3.1/update.json `
  --notes-file release-notes.txt
```

上述现有版本仅用于展示派生方式，不创建新版本，不代表当前已发布 APK 已经包含更新模块。

短说明可以直接提供文本；`--notes` 与 `--notes-file` 二选一：

```powershell
python -B tool/create_app_update_feed.py `
  --manifest release/v1.3.1-769ee519ada0/Zeluna-v1.3.1-manifest.json `
  --output out/app-updates/v1.3.1/update-mirror.json `
  --notes "此处填写该正式版本真实的用户发布说明。" `
  --download-base-url https://downloads.example.com/zeluna/v1.3.1 `
  --min-sdk 24
```

| 参数 | 约定 |
| --- | --- |
| `--manifest PATH` | 必需。现有 `zeluna-release-manifest-v2` JSON，只读；支持 UTF-8 BOM，最多 512 KiB。 |
| `--output PATH` | 必需。仓库内外均可使用新的输出路径；父目录按需创建。现有文件、目录、符号链接均报错，不截断或覆盖。 |
| `--notes-file PATH` | 可选。读取 UTF-8/BOM 文本，保留换行；与 `--notes` 互斥。 |
| `--notes TEXT` | 可选。真实的用户发布说明，不是门禁凭据、Git SHA 或构建日志。两种 notes 参数均省略时输出空字符串。 |
| `--download-base-url URL` | 可选。APK 所在的公共 HTTPS **目录**，默认 `https://github.com/fanyong07/Zeluna/releases/download/vX.Y.Z`。文件名由版本生成，不接受来自 artifact `path` 的地址。 |
| `--min-sdk N` | 可选。默认 `24`，必须是 `1..2147483647` 的整数；操作者须与发布 APK 的真实最低 Android API 保持一致。 |

工具保守保护路径中名为 `release` 的目录（大小写不敏感），并检查解析后的符号链接/目录联接目标；输出请放在独立暂存目录。它只创建新文件，**不创建或覆盖 release 产物、不改名旧版本、不写 GitHub asset、不删除旧文件**。输入检查完成后才创建输出父目录，输出使用独占创建（`xb`），即使另一进程抢先创建同名文件也会报错。磁盘写入中断时可能留下不完整的新文件，请丢弃该暂存产物并另选新路径重新生成；勿将其部署。

## 输出 schema 示例

以下展示从既有 `1.3.1+87` 清单派生的字段形状。`notes` 是操作者输入，不会自动从网络下载；SHA-256、字节数和 ABI 直接来自源 manifest。

```json
{
  "schema": "zeluna-app-update-v1",
  "platform": "android",
  "package_name": "app.anime.anime",
  "version": "1.3.1",
  "build_number": 87,
  "apk": {
    "url": "https://github.com/fanyong07/Zeluna/releases/download/v1.3.1/Zeluna-v1.3.1-Android.apk",
    "sha256": "ba6701b8fcb46a4e99d8ccd442c1e0a12408efc8a44cbe8dfa28eb6591efe4eb",
    "bytes": 133140679,
    "abis": ["arm64-v8a", "armeabi-v7a", "x86_64"],
    "min_sdk": 24
  },
  "notes": "此处填写该正式版本真实的用户发布说明。",
  "release_page": "https://github.com/fanyong07/Zeluna/releases/tag/v1.3.1"
}
```

字段与客户端 [更新模型](<../lib/src/updates/app_update_models.dart>) 对齐：

- 输入 schema 必须为 `zeluna-release-manifest-v2`，版本必须是无前导零的 `X.Y.Z+build`；输出 `version` 去掉 `+build`，最长 128 字符，`build_number` 为 `1..2147483647` 的 JSON 整数。
- 只选**唯一且大小写精确匹配**的 `Zeluna-vX.Y.Z-Android.apk`；旧版本、改名文件、带路径的名称、备用包和同名重复项均不作为有效选择。其他 artifact 不参与 APK 数据推导。
- `apk.bytes` 是正整数，最大 `512 * 1024 * 1024`；`sha256` 是 64 位十六进制，输出归一化为小写。布尔值不当作整数。
- `apk.abis` 复制选中项的 `native_abis`，要求 1 至 16 个互异字符串，每项匹配 `[a-zA-Z0-9_-]{1,64}`。
- `notes` 上限为 20000 个 **UTF-16 code unit**，与 Dart `String.length` 一致：常见中文字符计 1，常见 emoji 计 2。超长报错，不静默截断用户文本。
- `release_page` 固定指向此仓库的 `https://github.com/fanyong07/Zeluna/releases/tag/vX.Y.Z`，自定义下载域名不会改变它。
- 最终 JSON 最多 512 KiB，URL 最多 8192 字符。

### HTTPS 与路径处理

下载目录只接受 HTTPS，不含 userinfo、查询串或 fragment，包括空 `?`、`#`；无效端口、控制字符、反斜杠均报错。禁止 localhost / `.localhost` / `.local`、私有或特殊用途 IP 字面量及非规范数字地址（例如 `127.1`、整数 IPv4、八进制/十六进制写法）。使用公共 ASCII 完整域名或公共规范 IPv4；当前客户端对 IPv6 字面量较严格，工具选择公共域名作为 IPv6 网络的兼容入口。

工具离线检查的是 URL **语法和字面量**，不会解析域名或检测远端服务。某个域名的实际解析地址、证书、可用性与响应内容仍由部署环境和客户端网络层处理。

目录重复 `/` 与尾部 `/` 归一化后，将固定 APK basename 作为新路径段追加；不通过 `urljoin` 解析不可信 artifact 路径。`.` / `..`、编码斜杠或反斜杠、编码控制字符、嵌套百分号编码等均报错，避免目录跳转或二次解码歧义。URL 编码的普通路径文字可正常归一化。

## provenance 校验与明确边界

工具要求源 manifest 中已有以下 provenance：

- `git_sha` 为完整 40 位十六进制；
- `ci_run_id` 为正十进制数字（JSON 字符串或整数），`ci_run_url` 必须精确对应 `https://github.com/fanyong07/Zeluna/actions/runs/<ci_run_id>`；
- `quality_workflow` 精确为 `Quality Gates`；
- `generated_utc` 是以 `Z` 结尾的有效 ISO-8601 UTC 时间；
- 选中 APK 的 `build_receipt_sha256` 为 64 位十六进制，`legacy_debug_signing` 是显式布尔值。

这些是对**源清单声明的结构与一致性检查**。脚本不读取 artifact `path`，不打开 APK 或 build receipt 实物，不重新计算 APK 的 SHA-256/字节数，不分析包名、签名证书或 SDK，不查询 CI 成功状态，也不证明输入确实已在 GitHub 发布。应由发布负责人从可信的已发布 Release 取得原始清单并保留来源；随意编写字段不是发布证明。

输出 JSON 不新增或伪造门禁通过、重新签名、验包成功等声明。它不是 release manifest 的替代品，更不是 Quality Gates 的替代入口。包名固定为项目约定，最低 SDK 为输入声明；签名、安装兼容性和设备安装权限仍由真实构建、客户端校验和 Android 安装器负责。

## 签名与版本连续性

当前历史 Android Release 沿用项目历史 debug key 以保持已安装用户的升级兼容性；它**不是生产签名密钥**。`legacy_debug_signing: true` 只是既有发布事实的记录，不表示工具重新签名或提升了密钥可信度。

同包名原地升级要求签名兼容。任意换 key 会破坏现有安装的直接升级路径，勿把换签名当作静态清单配置修改。正式签名密钥迁移、签名 lineage/轮换、渠道切换和用户数据迁移需另行设计并测试；本工具不实施这些迁移。

每次真正交付新版本，沿用 [仓库发布规则](<../AGENTS.md>)：同时递增 `X.Y.Z` 和 build，绑定新的精确 Git HEAD、Quality Gates 凭据及 release manifest，使用新 Tag 与新产物。生成静态清单不会自动递增版本，也不会让同 build 的旧包成为新版本。

## 操作者后续部署检查

本改动只生成本地文件，以下为未来部署参考，不由脚本自动执行：

1. 在正常发布流程已经完成、可信 release-v2 清单已就绪后，检查版本、build、签名连续性和 APK 来源。
2. 运行离线命令输出到新的独立暂存路径，审阅用户说明、镜像地址和最低 SDK。若选镜像，镜像必须保留源 APK 的完全相同字节；修改包体后应发布新版本并走完整发布流程。
3. 将派生 JSON 放到独立公共 HTTPS 静态站点，建议 `Content-Type: application/json; charset=utf-8`。保留版本化文件；若部署方提供稳定 `latest.json` 地址，使用部署系统的原子切换和合理缓存策略管理该指向，不改旧 GitHub asset 或 release manifest。
4. 默认 GitHub 模式不需要步骤 2、3。自定义模式需让客户端构建参数指向相应 JSON，并在实际设备上验证更新检查、下载完整性、安装权限提示和系统安装流程。
5. 设备 SDK/ABI、安装来源权限和 Android 安装界面由客户端/原生更新模块负责；该 Python 工具只负责生成声明，不控制安装器。

## 轻量验证

```powershell
python -B -m unittest discover -s tool/tests -p test_app_update_feed.py -v
```

测试仅用 stdlib `unittest`、合成 manifest 与 `tempfile`，并将 socket/DNS 入口替换为立即报错，覆盖 schema、provenance、精确唯一 APK、数值与 Unicode 边界、HTTPS/路径处理、源文件不变、release 路径保护及并发同名输出保护。测试不修改真实 release、不构建 Flutter/Gradle、不访问外网、不触发发布。
