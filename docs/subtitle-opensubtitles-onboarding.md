# OpenSubtitles 服务端接入：申请入口与授权边界

核验日期：**2026-09-17（Asia/Hong_Kong）**。范围：仅 OpenSubtitles.com REST API 的官方公开资料；有界核验，不是接入、版权法律意见或生产验收。

## 1. 结论

**可以推进服务运营方申请应用 API key；准确入口是 <https://www.opensubtitles.com/en/consumers>。但尚未确认 Zeluna 获准永久集中保存字幕正文，并向无需 OpenSubtitles 账号的多名观看者持续提供。申请到 Key 不等于取得上述内容使用许可。** [O1,O2,O3]

- 用户已允许服务端申请字幕源 API 凭据，观看者无需注册；**未允许付费**。此前“不得新增任何账号或 Key”的限制不再适用于本轮，但不因此自动获得内容授权。
- 官方明确提供无需提示观看者登录 OpenSubtitles 的项目咨询路线：<https://www.opensubtitles.com/contact>；订阅价格页的 Enterprise / 联系入口为 <https://www.opensubtitles.com/en/contact.html>。[O1,O2]
- 商用许可、永久保存、多用户再分发和免费服务级接入是否适用于本项目：**未确认，等待站方对具体用途书面说明**。不将未知写成违法、全面禁止或全球无可用来源。
- 工程交接建议：OpenSubtitles 保持 `pending_provider_agreement`，不因获得 Key 就启用字幕正文永久入库或对外分发。不重复实现适配器，也不研究或修改其他来源路线。

## 2. 准确申请入口与账户区别

| 对象 | 已核验结论 | 依据与限制 |
| --- | --- | --- |
| 应用申请入口 | <https://www.opensubtitles.com/en/consumers>，亦有官方简写 <https://www.opensubtitles.com/consumers> | 官方 Getting started 指向 profile 的 API consumers；创建 consumer 即得到该应用所需 Key。价格页再次列出完整入口。[O1,O2] |
| 运营方账户 | 标准自助申请需要运营方自己的 OpenSubtitles.com 账户 | 官方步骤为 register/login → create Consumer；本轮读取 consumers 也返回登录页，含 Sign up 链接。[O2,O3] |
| 登录与注册 | 登录：<https://www.opensubtitles.com/en/users/sign_in>；注册：<https://www.opensubtitles.com/en/users/sign_up> | 来自 consumers 登录页面的实际链接；仅核验入口，没有打开注册流程或提交资料。[O3] |
| 应用 Key | 每个应用使用一个应用级 Key；请求携带 `Api-Key` | 不应让观看者各自申请应用 Key；官方将其与用户 JWT 明确区分。[O1] |
| 用户登录 / JWT | **不是所有 API 调用都必须登录一个用户账户**；官方说明 consumer 可独立查询，并有有限免用户登录下载 | 获取 Key 所需的运营方账号，不等于每次请求都需要该账号的 JWT。普通用户认证额度与服务级项目接入不能混为一谈。[O1] |
| 无观看者账号的服务 | 官方要求说明项目并联系站方；价格表也列有无需用户登录的方案 | 证明存在接入路径，不证明本项目已经获准、不证明一定免费，也不证明能共享一个普通用户/VIP 配额服务所有人。[O1,O2] |

**不要在 Stoplight 文档站注册以申请 OpenSubtitles Key。** Getting started 明示该站仅是文档，申请应在 OpenSubtitles.com 的账户内完成。[O1]

官方还明确反对把开发者用户名和密码硬编码到公开分发的应用中供所有用户共用。[O1] 本项目如继续，只在服务端仓库外的私有配置保存凭据；不下发客户端，不写 Git 或日志，**不要求用户在聊天里粘贴 Key、密码或 Cookie**。

是否需要额外的服务账号/JWT、账号类型和认证组合，以站方批准的服务方案为准；不能从自助注册步骤推定一套普通用户账号就是合法且足量的多用户服务账户。

## 3. 存储、缓存、多用户提供与商用

| 问题 | 已验证 | 未确认 / 不得推定 |
| --- | --- | --- |
| 搜索结果缓存 | 价格页列出 `Caching Search results`：Free/Light/Startup 为 24h，Basic/Premium/Pro/Enterprise 为 60m。[O2] | 表格没有授予字幕正文的永久保存权；也不能把该字段自行解释成正文缓存的许可期限。 |
| 本地字幕目录 | 官方 Subtitle Exports 明确提供字幕**元数据** JSON，用于本地目录副本。[O5] | 元数据目录不是字幕正文库；导出功能不是永久保存并分发 SRT/ASS/VTT 的授权。没有下载导出文件。 |
| 无账号观看者 | 官方入门文档明确有项目咨询入口；订阅表存在无需用户登录的方案。[O1,O2] | 本项目应采用何种免费/付费服务方案、允许多少观看者、是否允许共享服务端出口：未确认。 |
| 字幕正文永久集中保存 | 本轮所读 API 文档和套餐说明未明确授予 Zeluna 此权限 | 是否允许永久保存、镜像、备份、修改格式、停止订阅后保留：未确认。不是断言所有用途被禁止。 |
| 从自有服务器向多用户提供 | API 文档能证明接口和服务方案存在 | 是否允许由 Zeluna 直接提供文件、是否只能透传/短期缓存、内容权利和删除责任范围：未确认。 |
| 商业用途 | 已核实官方应用订阅报价和 Enterprise 询价渠道。[O2] | 收费 API 的存在不等于向 Zeluna 授予商业再分发权；Free 能否用于此商业/服务用途亦未确认。 |

本轮额外尝试提取官方 Contact 和 Disclaimer 页面，You Contents 未返回可用正文；**没有将不可读页面说成“已读完整条款”，也没有使用消费者页面中的第三方浏览器扩展条款替代字幕 API 许可**。上述“未确认”仅针对已获得的官方资料，不代表穷尽了站方全部合同或私人合作安排。

## 4. 费用与额度：仅列核验日官方文档明确值

以下是 **2026-09-17 实读官方文档的公开说明/报价，不是本项目获配额度、实测吞吐、已接受报价或零成本保证**。没有购买，也没有访问购买结算链接。[O1,O2,O4]

### 4.1 标准入门文档

- consumer 不登录用户：文档写明每 IP 每 24 小时 **5 次字幕下载**。
- 普通已注册用户：文档写明 **20 次**；VIP 用户：**1000 次**，处于同一下载额度语境。
- `Under Development`：临时允许无用户认证 **100 次下载/日**，不是生产长期配额。
- 下载计数于 **UTC 00:00** 重置。
- 搜索不按下载次数扣限额，但仍受请求速率限制。[O1,O4]

这些数字来自入门页正文，并非通过账号或下载接口实测；不将普通用户/VIP 的数值移用为全体 Zeluna 用户的获准服务额度。

### 4.2 应用级订阅价格表

| 方案 | USD/月 | 每 IP 请求/秒 | 下载/24h（原表） | 搜索结果缓存（原表） |
| --- | ---: | ---: | --- | --- |
| Free | 0 | 5 | `user`，不是给整个应用承诺的固定数字 | 24h |
| Light | 20 | 5 | 2000 | 24h |
| Startup | 50 | 5 | 5000 | 24h |
| Basic | 100 | 50 | 15000 | 60m |
| Premium | 200 | 50 | 50000 | 60m |
| Pro | 400 | 50 | 100000 | 60m |
| Enterprise | 询价 | 询价 | 询价 | 60m |

官方同页写明年订阅 **20% 折扣**；本轮未验证结算税费、地区差异或最终账单，不换算成交价。[O2]

需保留的文档边界：

1. 价格表所有档位 `User need to log in` 都标为否，但 Free 下载栏只写 `user`；入门页又说明有限匿名额度及增额的用户认证要求。不能据此宣称免费无限量、免费完整满足免注册服务，需站方解释本项目适用规则。[O1,O2]
2. Best-Practices 写通用 **5 请求/秒/IP**，价格页另列高档位 50；按适用方案和实际返回限流头执行，不把高档位上限用于免费 Key。[O2,O4]
3. `/login` 文档限制 **1 请求/秒**；出现认证失败应停止重复使用同样凭据。本文不实施登录。[O4]
4. **用户尚未允许付费**：任何收费订阅或合作报价都须另行确认，不自动购买 VIP 或应用套餐。

## 5. 用户自行完成的最少步骤

### A. 取得应用凭据：一次官方账户操作

由账号所有者打开 **<https://www.opensubtitles.com/en/consumers>** → 登录自己的 OpenSubtitles.com 账户（没有账户才点 Sign up）→ 创建一个用于 Zeluna 的 Consumer → 在自己的安全配置环境保存生成的应用 Key。[O1,O2,O3]

用户只需反馈“已创建应用凭据”，**不要把 Key/密码粘贴到聊天中**。具体 Consumer 表单必填项、邮箱验证或人工审批时长未在登录后实测，不虚构按钮、通过率或办理时间。不要点购买套餐；创建账户时由用户自行审阅条款。

### B. 要达到“永久内置库 + 观看者不注册”：还必须确认使用范围

最少再由用户通过官方 **<https://www.opensubtitles.com/contact>**（价格页另列 <https://www.opensubtitles.com/en/contact.html>）发出一次用途询问，请站方书面确认下列范围；本轮只提供草稿，**未联系、未提交**：[O1,O2]

> We are evaluating OpenSubtitles for Zeluna. Only our server would hold one application API key; viewers should not need OpenSubtitles accounts. May we retrieve subtitle files, retain them permanently on our own server, and serve them to multiple users through our app? Please confirm whether commercial use is permitted, the permitted retention and redistribution scope, attribution and deletion requirements, and the applicable account/authentication requirements, quotas and pricing. We have not approved any paid plan. Is there a free authorized arrangement for this use? If permanent storage is not permitted, what caching and delivery model do you support?

A 只完成“有 Key”，不完成“有内容授权”；B 未得到明确答复前不启动永久入库或多用户分发。若回复需要收费，回到用户确认；若只允许短时缓存，另行明确产品效果，不把它包装成永久内置库。

## 6. 官方出处与核验方法

全部核验日期为 **2026-09-17（Asia/Hong_Kong）**。优先并实际使用本地 You MCP：

使用本机已配置的 `you-chrome-research.secure_launcher`，凭据来自本地加密池；具体私有路径不写入仓库。

通过 stdio MCP 执行 `health`、`you_search`、`you_contents`；正文请求关闭本地缓存，并指定 `max_age=0`。未读取/输出凭据池内容。最终依据如下官方页面正文，不以第三方博客或论坛普通用户评论作许可凭据。关闭缓存不等于掌握站方内部合同或保证所有官方页面同步更新。

| 编号 | 官方出处 | 本轮核验情况 |
| --- | --- | --- |
| O1 | [Getting started](https://opensubtitles.stoplight.io/docs/opensubtitles-api/e3750fd63a100-getting-started) | 成功提取正文：应用 Key 与用户 JWT、consumers 链接、匿名/用户额度、免观看者账号咨询入口。页面夹带状态组件加载错误，未将组件错误误认为正文不可读。 |
| O2 | [API Subscription prices](https://opensubtitles.stoplight.io/docs/opensubtitles-api/fcgiyz3p7sqn9-api-subscription-prices) | 成功提取完整套餐表及 register/login → Consumer 的申请步骤；未打开支付页面。 |
| O3 | [API consumers](https://www.opensubtitles.com/en/consumers) | 未认证提取返回登录页面，读到登录/注册链接；未登录、未填表。 |
| O4 | [Best-Practices](https://opensubtitles.stoplight.io/docs/opensubtitles-api/6ef2e232095c7-best-practices) | 成功提取正文：IP 请求限速、429 与登录限速。 |
| O5 | [Subtitle Exports](https://opensubtitles.stoplight.io/docs/opensubtitles-api/9r7wihp19dlpl-subtitle-exports) | 成功提取说明，明确是 metadata / local catalog；没有请求任何导出文件。 |
| O6 | [Contact](https://www.opensubtitles.com/contact)、[Enterprise 联系入口](https://www.opensubtitles.com/en/contact.html)、[Disclaimer](https://www.opensubtitles.com/en/tos.html) | 联系入口由 O1/O2 的官方超链接核实；直接正文提取未得到可用内容，表单可用性和完整法律条款未验证。 |

## 7. 交接与验收边界

- **已验证**：准确 Key 申请入口、运营方自助申请账户要求、Key/JWT 的区别、官方免观看者账号咨询路线、公开套餐价格和文档额度。
- **未知/未验证**：Zeluna 商用许可、永久字幕正文存储、多用户再分发、适用服务认证与免费方案、实际账号获配额度、登录后表单流程、合作答复和真实字幕覆盖/播放效果。
- 本轮未注册、登录、提交表单、发送消息、下载字幕、支付、部署、提交或推送代码；没有新增适配器。
- 本轮唯一写入的项目文件为 `docs/subtitle-opensubtitles-onboarding.md`。`docs/subtitle-provider-onboarding.md` 的主任务记录、其他来源路线与 Git 推送由主任务负责，不在这里重写或复核。
