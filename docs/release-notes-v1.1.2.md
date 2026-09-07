# Zeluna v1.1.2 候选交付说明

## 背景与目标

本次集中处理启动体验、Windows全屏恢复、外部请求安全与取消、服务端弹幕降级，以及可量化的包体减重。候选版本来自pubspec.yaml的1.1.2+56；此说明不是已公开发布的声明。

## Highlights

- 撤下Flutter与Android启动图片及固定等待，保留初始化、失败重试和原始素材，应用桌面图标不变。
- Windows进入全屏去掉原生边框，退出后恢复原有窗口位置/尺寸或最大化状态；覆盖播放器换集、换线、暂停/恢复。
- 弹弹play凭据仅在服务端读取，客户端不保存或传递私密凭据；外部失败不得阻断社区弹幕。
- 公开播放清单请求约束地址、重定向、协议和解析结果；规则网页请求独立处理取消、HTTP策略与响应回收。
- 默认Android仍为universal，新增单ABI包体报告与精确源码构建凭据，不悄悄减少设备覆盖。

## Compatibility

- 保留现有Android launcher组件，不修改applicationId和用户数据。
- 不升级依赖/SDK、不启用额外provider、不迁移生产数据库、不删除缓存。
- 单ABI测量仅是同源码Profile诊断，不能作为正式Release体积或真机升级证明。

## Verification

- 本地回归：Flutter 820通过、26跳过；服务端621通过、111个subtests通过；分析、格式、工具回归、仓库扫描和Python依赖漏洞审计通过。跳过项不计作通过。
- 完成标准：候选精确SHA的Quality Gates全绿，干净工作区，门禁凭据与版本、SHA、包体哈希一致。
- Windows已完成真实播放器加外部Win32的本地文件/loopback HTTP全屏检查；不等于公网片源或Android真机验收。
- Android真实设备安装/覆盖升级、真实账号隔离、公网片源与弹弹play真实联调仍需独立记录。
- 四材料inventory的既有实读记录见engineering-goal-progress.md：total=4、read=4、skipped=0；不声称本轮重新阅读。

## Rollback

- 服务端部署前保留一致性数据库备份、旧源码清单和包；维持现有密钥、数据库和上传目录。失败时恢复旧源码并重新检查健康，不删除或回退用户数据。
- 包与标签不可改名、覆盖或复用；客户端修复使用新的递增版本。

## Security 与待确认

- 本机key.properties引用的keystore缺失；公开Android发布需维护者通过本机安全配置提供受保护生产签名并确认升级身份，不索要聊天明文密码。
- 禁止以历史debug证书绕过公开发布检查，不擅自更换applicationId。
- 生产弹弹play当前未启用且未配置凭据；后续在服务器安全配置后单独验收，不将mock测试称为真实联调。
- LICENSE、THIRD_PARTY_NOTICES与各自独立许可证必须随交付保留。
