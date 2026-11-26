# Zeluna 项目规则

本文件适用于整个仓库。处理版本升级、打包、Git 标签、GitHub Release 或 `release/` 产物时，必须遵守以下规则。

## 版本与发布命名

- `pubspec.yaml` 使用 Flutter 标准格式 `major.minor.patch+build`，例如 `1.0.1+42`。`v` 只用于对外名称，不写入 `pubspec.yaml`。
- 每次交付新版本都要递增用户可见版本号。默认修复和小更新递增 patch：`v1.0.1`、`v1.0.2`；成组新功能递增 minor；不兼容升级才递增 major。
- `+build` 是 Android 内部构建号，必须单调递增且不得复用；它保留在包元数据和发布清单中，默认不出现在应用显示名称、Git 标签或安装包文件名中。
- 对外统一使用 `vX.Y.Z`：应用版本显示、Git 标签和 GitHub Release 名称保持一致。
- 发布产物统一命名为 `Zeluna-vX.Y.Z-Android.apk` 和 `Zeluna-vX.Y.Z-Windows.zip`；Windows ZIP 内必须包含完整可运行目录及 `Zeluna.exe`。
- 已发布版本不可改名、覆盖或复用。任何修复都创建新的 `X.Y.Z+build`，并绑定新的精确 Git HEAD、Quality Gates 凭据和 release manifest。
- 过渡规则：如果最新版本仍是 `1.0.0+41`，下一版使用 `1.0.1+42`，对外显示为 `v1.0.1`；之后从最新已发布 manifest 或 Git 标签继续递增。

完成标准：打包前同时确认用户可见版本号和 build 均已递增；APK、Windows ZIP、Git 标签、门禁凭据和 manifest 的版本及 Git SHA 完全一致。
