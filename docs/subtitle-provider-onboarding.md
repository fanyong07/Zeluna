# 字幕源接入：凭据批准后的执行清单

## 状态与目标

2026-09-17，用户已允许**服务端申请字幕源 API 凭据，终端观看者不必注册，收费另行确认**。这取代首版「不新增任何账号／密钥」的约束，但不等于已拿到凭据、内容存储许可、云盘授权或生产部署批准。

字幕基础设施已提交并推送到 `main`，提交 `6ba583f2fd905ea445cc34f5d4de4b875bf7c6a6`。真实作品下载与入库仍为 0。目标是从真实作品目录逐步提高日语／英语覆盖，不用测试文件或候选命中代替覆盖率。

## 两条来源路线

- 跨电影／电视剧的英语主来源：先核验 OpenSubtitles 的应用注册与服务级使用条款，结果见 `subtitle-opensubtitles-onboarding.md`。
- 日语补充：Jimaku 官方认证 API，而不是匿名网页爬取；凭据要求本轮已明确，集中存储／分发范围仍待确认。

## Jimaku：本轮官方核验

通过用户指定 You MCP 的 `you_search` 和 `you_contents` 实读官方 API 文档与帮助页，日期 2026-09-17：

1. 官方 API 要求站点账号；注册／登录入口为 <https://jimaku.cc/login>。[J1]
2. API Key 在账号页 <https://jimaku.cc/account> 生成。认证头是 `Authorization`；官方示例直接放 Key，不添加未经文档要求的 `Bearer`。[J1]
3. 限流按 IP，429 后依返回的 `x-ratelimit-reset-after` 等头等待，不能用轮换 IP／账号规避。[J1]
4. 官方支持入口为 <https://jimaku.cc/contact>。目前只核验入口，没有发送消息。[J1]
5. 帮助页说明手动批量下载会生成 ZIP，同时推荐独立 SRT／ASS。允许手动批量下载不自动等于允许建立面向多用户的长期字幕镜像。[J2]
6. 本轮文档没有明确授予 Zeluna 所需的长期服务器／私有 Drive 存放并向观看者提供的范围。因此先问清范围，再启用写入持久库；不是断言所有这种用途都被禁止。

此前匿名网页自动化的限制不应误写成「官方认证 API 不可用」；两者是不同路线。源码 AGPL 是程序许可，不能替代字幕文件的内容许可。[J3]

## 接入前必须补齐

- 官方账户／应用注册需要账号所有者完成交互登录。禁止通过聊天索要密码、Cookie 或 API Key，也不从无关配置提取其他服务的凭据。
- Key 仅落在服务端仓库外的私有配置。日志只输出是否已配置；不提交到 Git、不下发客户端。
- 记录提供方允许的自动访问、缓存时长、长期保存、用户范围、流量额度、署名与删除要求。若只准临时缓存，则不能当作永久内置库；需要向用户说明差异。
- 收费、Google OAuth 和生产上线分别确认。API Key 不等于 Google Drive 授权，也不等于已购套餐。

## 供用户审阅的询问草稿（未发送）

> We are integrating Japanese/English subtitles into Zeluna. End users should not need their own provider accounts. We would like to use one server-side application credential to retrieve subtitles for specific catalogue entries and, where permitted, retain subtitle files on our private server or private Google Drive and deliver them through our application. Could you confirm whether this use is permitted, the allowed retention and redistribution scope, any attribution/removal requirements, and the applicable rate limits and pricing? If permanent storage is not permitted, what caching and end-user delivery model do you support?

这是询问许可和接入条件，不是声称已有许可或代表用户接受合同。未经明确发送批准，不联系站方。

## 验收顺序

1. 账号所有者完成官方申请，将最小权限凭据安全配置到指定服务端环境。
2. 核验条款及允许范围后进行有限、按需样本查询，不启动全站抓取。
3. 用目录稳定 ID、季集信息绑定；身份有歧义时停留在待确认，不盲选。
4. 验证实际文件格式、语言、读写、原中文保留和时间同步。
5. 有真实样本通过后再讨论部署、批量覆盖与 Drive 容量方案。按未检索／无候选／限流／待授权／待匹配分别统计缺失原因。

## 官方出处

- [J1] <https://jimaku.cc/api/docs>，本轮实读，认证／限流／支持。
- [J2] <https://jimaku.cc/help>，本轮实读，下载和命名规则。
- [J3] <https://github.com/Rapptz/jimaku>，本轮实读，项目定位及软件许可证。

公共资料提取证据保留在被 Git 忽略的本地 `artifacts/subtitle-qa/jimaku-api-onboarding-evidence.json`；里面没有用户 API 凭据。
