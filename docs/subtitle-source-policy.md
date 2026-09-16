# Jimaku 字幕来源政策与适配交接

核验日期：2026-09-16。范围仅为规则、官方源码及适配边界；不涉及应用实现、部署、账号申请、AI、字幕或视频文件下载。

## 结论与背景

Zeluna 拟保留片源现有简中字幕，按需补充原文字幕。**Jimaku 网页自动来源必须默认禁用：本轮取得的线上 robots 对通用客户端明确禁止全站自动抓取，而不仅是许可未知。** 匿名可读取、用户点击触发、源代码开放，均不能作为允许自动采集的依据。手动导入本地字幕仍可独立使用。

启用条件：站方明确允许目标客户端及实际目录、详情和下载路径的访问，且重新核验当时的公开规则。没有明确依据就不启用；不能仅通过一个普通配置开关无条件解除政策限制。官方 API 是另一条需要凭据的路线，不符合本次“不新增账号或 Key”的约束。

## 官方规则与本轮证据

1. [线上 robots](https://jimaku.cc/robots.txt)：通过本机 You MCP `fetch_page` 实时读取（`cached=false`）。普通客户端段为 `User-agent: *`、`Disallow: /`。若干具名搜索引擎另有允许段，但该段仍排除了 `/entry/*/download/`、`/entry/*/bulk` 等路径。**不得伪装搜索引擎身份；不能因为只下载一集或用户点击就视作豁免。** robots 是站点自动访问规则证据，不替代字幕版权或商业授权。
2. `you_search` 检索 `site:jimaku.cc terms robots automated scraping usage policy` 成功返回但无结果。**未找到独立公示条款，不等于没有条款或获得授权。** 本次未穷举所有站点页面。
3. 固定提交的 [帮助页模板](https://github.com/Rapptz/jimaku/blob/65a948645e0149b51211cac4934bf44eae06e525/templates/help.html) 明确说明目录组织、字幕命名与分季规则；它不是对 Zeluna 匿名自动抓取的授权。AI 生成字幕可能存在于站点，站方要求标记；本项目不生成 AI 字幕，若后续允许接入，应避免把标记为 AI 的文件误称为官方原文。
4. 按要求调用了 `web.run` 读取官方帮助页，但没有得到可用内容；不计为交叉验证成功。主要证据来自 You MCP 的实时 robots 与官方固定提交内容。

执行有界：共 5 次 You MCP 检索／内容工具调用（包括批量源码请求与一次缓存复读），另 1 次 web.run；没有登录、注册、绕过保护或下载用户文件。获知 robots 后，结构复核仅针对 GitHub 官方源码，不继续自动遍历 Jimaku 目录和文件。

## 固定提交中的路由与 HTML 结构

以下全部针对 `65a948645e0149b51211cac4934bf44eae06e525`，**不代表线上部署版本一致，也不代表当前允许执行这些请求**。通过 `you_contents` 获取官方 raw 源码核验。

| 部分 | 已核验结构与实施提示 | 官方源码 |
| --- | --- | --- |
| 分类目录 | `GET /` 是动画目录；`GET /dramas` 是非动画目录。两者构造模板时接受 `Option<Account>`，即代码层面允许无登录访问。不是按作品名返回单条结果的搜索 API。 | [src/routes/mod.rs](https://github.com/Rapptz/jimaku/blob/65a948645e0149b51211cac4934bf44eae06e525/src/routes/mod.rs) |
| 目录 HTML | `.files` 内的 `.entry` 携带 `data-extra="{{ entry.data()\|json }}"`；作品链接为 `a.table-data.file-name[href="/entry/{id}"]`，另有 `.file-modified` 时间。搜索框 `#search-files` 的提示按分类使用 AniList／TMDB。提取 HTML 属性须先正确解码，再解析 JSON，不能执行页面脚本。 | [templates/index.html](https://github.com/Rapptz/jimaku/blob/65a948645e0149b51211cac4934bf44eae06e525/templates/index.html) |
| 目录脚本 | 脚本使用 `.entry`、`dataset.anilistId`、`dataset.tmdbId`、`dataset.name` 并读取页面 URL 的 `searchParams`。模板同时加载 `files.js`、`fuzzysort.min.js`。本轮未审计 `files.js`，不能假定这些 dataset 字段都是原始 HTML 直接提供，也不能虚构 `?search=` 为后端检索接口。 | [static/index.js](https://github.com/Rapptz/jimaku/blob/65a948645e0149b51211cac4934bf44eae06e525/static/index.js) |
| 作品详情 | `GET /entry/{id}` 对应 `get_entry`，接受可选账号；模板含 `h1.title`、AniList／TMDB 链接、备注，以及内联 `entryId` 和 JSON `entryData`。不应使用 eval 提取内联信息。不存在的目录会重定向到 `/`，因此 HTTP 成功不能直接判为详情命中。 | [src/routes/entry.rs](https://github.com/Rapptz/jimaku/blob/65a948645e0149b51211cac4934bf44eae06e525/src/routes/entry.rs)、[templates/entry.html](https://github.com/Rapptz/jimaku/blob/65a948645e0149b51211cac4934bf44eae06e525/templates/entry.html) |
| 文件链接 | `get_file_entries` 从目录生成 `FileEntry { url, name, size, last_modified }`；URL 为 `/entry/{entry_id}/download/{编码后的文件名}`，名称使用 percent_encode，时间为 RFC3339。下载处理器不要求 Account，但会验证文件路径。不要手工拼接未经校验的用户文件名，也不要访问 bulk。 | [src/routes/entry.rs](https://github.com/Rapptz/jimaku/blob/65a948645e0149b51211cac4934bf44eae06e525/src/routes/entry.rs) |

安全可提取信息仅包括：站内作品 ID、显示名、页面明确提供的外部作品 ID／链接、目录时间；经结构确认后可读取目录 JSON 中实际存在的别名和标记；文件的显示名、站内下载路径、大小与修改时间。`FileEntry` 字段已由源码确认，**完整目录 JSON 键集合及文件列表 DOM 选择器未在本轮锁定**，后续离线适配测试应使用固定源码生成的样例，而非猜测字段。

不从英文作品名推断字幕为英文；不从修改时间推断作品年份；不把站内作品 ID 当作 Zeluna 自身作品稳定 ID；不从文件名猜出的集数直接认定绑定成功。

## 分季与匹配规则

依据上述官方帮助模板：

- AniList 按不同条目／季组织，一条 AniList 条目对应一个目录。不能将其中一季字幕绑定整部作品所有季。
- TMDB 会将多个季度合并到同一条目，Jimaku 对应目录也可能混合多季。必须结合明确季号与季内集号；缺少季号时不能默认第一季。
- 来源版本、重定时等信息可能体现在文件名；文件名不是可靠、完整的分集数据库。同名、重制版、特别篇及版本不明确时必须人工确认。
- “找到对应作品／集数”与“时间轴同步”分别验收；不保证全作品覆盖、字幕质量或与 Zeluna 实际片源同步。

## 实现边界与验收

- 默认禁用状态不应向 Jimaku 发起目录、详情或内容请求；展示“来源暂不可用，请导入字幕”，不要伪装成“未找到字幕”。
- 当前可以实现并测试独立解析器、候选模型与导入功能；网页适配仅用离线样例测试，不能把真实站点冒烟测试作为自动门禁。
- 即使未来取得许可，也只做授权范围内的按需访问、短时缓存及限流；遇到登录、验证码、403／429 或保护页即停止，不换身份绕过。
- 获取接口只接受已验证候选 ID；限制体积、扩展名、来源域名及重定向，每一跳重新验证地址。不得接受任意 URL，不发送视频播放链接、用户 Cookie 或账号令牌。
- 不提供全站扫描、BT、整部视频下载、账号 Key 申请、AI 转写翻译或集中再分发；手动导入文件仅本地使用。
- 本轮未知：独立完整条款、应用专属许可、字幕再分发权、线上源码版本、完整目录 JSON schema，以及实际账号 API 与字幕匹配播放闭环。任何未知不得在交付中写成已验证。

完成标准：默认网络适配关闭且无对站点的外发请求；手动导入不受影响；界面区分受限与无结果；重新启用必须留下新的规则证据和允许范围。本文件仅调研交接，不代表应用或服务端功能已实现。
