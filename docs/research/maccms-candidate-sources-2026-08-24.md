# Zeluna MacCMS 候选来源研究（2026-08-24）

## 1. 结论

本轮形成 **100 条公开 endpoint lead**：

- **80 条主候选**：按当前可见品牌和主机暂定为 80 个逻辑组；
- **20 条镜像/别名候选**：只用于域名迁移和去重研究，**不得作为 20 个新增 production source 计数**；
- **0 条完成结构验证**；
- **0 条完成 Smoke**；
- **0 条完成 Coverage Benchmark**；
- **0 条可以据此直接晋级 production**。

明确结论：**这些条目只是候选线索，不是“可用源”“无广告源”“合法授权源”或“生产可播源”。** 本轮只读取提交 SHA 固定的公开 GitHub 维护者配置，没有请求下面任何候选 API，也没有访问详情、播放清单、密钥或媒体分片。

```text
LIVE PRODUCTION-EGRESS PROBE NOT RUN
```

## 2. 范围与合规边界

本轮做了：

- 从公开 GitHub 仓库中的维护者配置抽取明确写出的 `http(s)` MacCMS `provide/vod` URL；
- 保留每条候选的提交固定原始证据；
- 与当前 `server/server/scrapers/maccms_sites.py` 的 20 条正式记录做主机级排除；
- 排除 IP literal、内嵌凭据、Cookie/token/signature、私有地址、明显成人源和 XML-only 路径；
- 对同品牌多域名做镜像/别名分组，避免数量虚增。

本轮没有做：

- 不调用 kanju1 私有 API、ticket、HMAC、CDN、账号或 Cookie；
- 不探测候选站 API，不搜索作品，不读取媒体 URL；
- 不绕过登录、配额、签名、DRM 或访问控制；
- 不把公开配置的出现视为站点授权、版权许可或服务条款许可；
- 不修改生产代码、正式来源表、测试、VPS 或 release。

GitHub 公开配置只能证明“某维护者在该提交中公开列出过这个 URL”。它不能证明 endpoint 仍在线、返回标准 JSON、内容正确、没有广告、允许第三方聚合或拥有内容权利。即使仓库本身有开源许可证，也不能替代上游站点和内容权利人的授权。

## 3. 可复现证据清单

本轮用于候选表的输入文件共 **8 个，已读 8 个，跳过 0 个**；合计 **429,022 bytes / 6,465 lines**。按配置对象抽取到 555 次 `provide/vod` URL 出现，经过现有正式源排除、敏感项排除、格式筛选、主机去重和人工范围复核后，保留下面 100 条 lead。各排除原因可能重叠，因此不把差值伪装成互斥分类统计。

| ID | 一手配置证据 | 提交时间（UTC） | bytes / lines | SHA-256 | 仓库许可状态 | 用途 |
| --- | --- | --- | ---: | --- | --- | --- |
| G1 | [cluntop/tvbox `js/cj.json`][G1] | 2026-08-24 | 18,295 / 593 | `06fac5d8d765b57999955306d8c848bd03f18e142b637932c328e425702edce3` | MIT | 当前维护的 CMS 列表，作为优先证据 |
| G2 | [xiongjian83/TvBox `ZY.json`][G2] | 2026-08-24 | 41,700 / 254 | `70f5bc36e0487596c7c31048bdcb8ab0b22affb8a5fe5c1f468b3fd724a35839` | 未声明 | 当前维护的大型来源配置 |
| G3 | [hd9211/Tvbox1 `zy.json`][G3] | 2026-08-17 | 56,542 / 326 | `ca325fa64d5512f9bcccac5fd286295c2e4624414d678fdb64812fe4d6afccc8` | 未声明 | 当前维护的大型来源配置 |
| G4 | [heroaku/TVboxo `Text/cmstv.json`][G4] | 2026-03-01 | 8,372 / 246 | `7e4fda1ac4e0cb91fab128917924b1679b138821181ce926427be8bbf4b1478b` | 未声明 | CMS 点播配置补充与名称交叉核对 |
| G5 | [qist/tvbox `dianshi.json`][G5] | 2026-08-24 | 50,029 / 234 | `f4d7f8d8d15dd3eca756316e419c6437d146320fdf6796ecec69d603762540bd` | 未声明 | 当前维护配置的镜像交叉证据 |
| G6 | [anaer/Meow `meow.json`][G6] | 2026-07-05 | 176,197 / 3,845 | `6ed342bc21c74ee4648a728e1a52d9ec33f1a3dc7dc53e5d5662b6391c06e318` | 未声明 | 多域名与迁移镜像线索 |
| G7 | [shidahuilang/shuyuan-bak `UZ.json`][G7] | 2026-08-07 | 17,641 / 583 | `63bcd86fcf1c98918bc960dff95adabd811b6ae43bae24c2b5c90b5fe8ffe849` | GPL-3.0 | 当前配置中的补充候选 |
| G8 | [liu673cn/bug `vod/m.json`][G8] | 2023-12-10 | 60,246 / 384 | `3cd1acb44d33a98a608bf1174d17a421049bc8e6dde6de18ff133455876823c3` | 未声明 | 历史线索；统一标为高时效风险 |

## 4. 主候选（80 个暂定逻辑组）

所有条目的 `review_status` 均为 `candidate`。除非 notes 另有说明，统一风险是：**只存在公开配置证据，API 结构、内容范围、条款/授权、广告信号和可播性均未验证。**

| # | name | api | discovered_from | review_status | notes / 风险 |
| ---: | --- | --- | --- | --- | --- |
| 1 | 1080P资源 | `https://1080api.com/api.php/provide/vod/` | [G2] | candidate | HTTPS；名称暗示清晰度，不代表实际码率或可播质量。 |
| 2 | 1080zyk优质资源库 | `https://api.1080zyku.com/inc/api.php/provide/vod/` | [G7] | candidate | HTTPS；`/inc/api.php` 前缀需先验证与现有 JSON parser 的兼容性。 |
| 3 | 49资源 | `https://49zyw.com/api.php/provide/vod/` | [G2] | candidate | HTTPS；需确认响应 schema、分页和内容类型范围。 |
| 4 | 68资源 | `https://68zy88.com/api.php/provide/vod/` | [G2] | candidate | HTTPS；品牌信息有限，人工合规和内容范围复核优先。 |
| 5 | 蓝天90 | `https://90sr.com/api.php/provide/vod/` | [G6] | candidate | HTTPS；配置名称不稳定，需用返回站点标识确认真实 provider。 |
| 6 | 樱花资源 | `https://m3u8.apiyhzy.com/api.php/provide/vod/` | [G1] | candidate | HTTPS；域名含 `m3u8` 不等于线路已验证，仍须完整验线。 |
| 7 | 蜂巢片库 | `https://api.fczy888.me/api.php/provide/vod/` | [G3] | candidate | HTTPS；内容类型和权利状态未知。 |
| 8 | 金马资源 | `https://api.jmzy.com/api.php/provide/vod/` | [G3] | candidate | HTTPS；需验证标题匹配、分集标签和媒体 Host 多样性。 |
| 9 | 牛牛资源 | `https://api.niuniuzy.me/api.php/provide/vod/` | [G1] | candidate | HTTPS；Epic 既有研究 lead，本轮只补充公开 endpoint 证据。 |
| 10 | OK资源 | `https://api.okzy.org/api.php/provide/vod/` | [G3] | candidate | HTTPS；与 `okzyw9.com` 可能同品牌，晋级前先做身份归并。 |
| 11 | 天空资源 | `https://api.tiankongapi.com/api.php/provide/vod/` | [G2] | candidate | HTTPS；需验证默认响应是否为 JSON 而非 XML/HTML。 |
| 12 | TOM资源 | `https://api.tomcaiji.com/api.php/provide/vod/` | [G2] | candidate | HTTPS；品牌与维护主体未知，需人工 review。 |
| 13 | U酷资源 | `https://api.ukuapi.com/api.php/provide/vod/` | [G1] | candidate | HTTPS；Epic 既有研究 lead，另有镜像条目不得重复计数。 |
| 14 | 无限资源 | `https://api.wuxianzy.net/api.php/provide/vod/` | [G3] | candidate | HTTPS；名称容易与“无尽”混淆，provider identity 必须独立确认。 |
| 15 | 旺旺资源 | `https://api.wwzy.tv/api.php/provide/vod/` | [G1] | candidate | HTTPS；可能偏短剧，先按 content type 做 coverage 分类。 |
| 16 | 新浪资源 | `https://api.xinlangapi.com/xinlangapi.php/provide/vod/` | [G1] | candidate | HTTPS；脚本名不是标准 `api.php`，需做结构兼容验证。 |
| 17 | 易看资源 | `https://api.yikanapi.com/api.php/provide/vod/` | [G2] | candidate | HTTPS；内容范围和站点授权未知。 |
| 18 | 秒播资源 | `https://api.zeqaht.com/api.php/provide/vod/` | [G6] | candidate | HTTPS；配置中的品牌名与域名不一致，先确认 provider identity。 |
| 19 | 白狐资源 | `https://baihuzy.com/api.php/provide/vod/` | [G3] | candidate | HTTPS；只在单一证据文件出现，时效和结构风险较高。 |
| 20 | 豆瓣资源 | `https://caiji.dbzy.tv/api.php/provide/vod/` | [G1] | candidate | HTTPS；名称不代表豆瓣官方合作，UI 和文档不得作官方暗示。 |
| 21 | 快车资源 | `https://caiji.kczyapi.com/api.php/provide/vod/` | [G2] | candidate | HTTPS；需确认是否与“快播”配置别名混用。 |
| 22 | 可可资源 | `https://caiji.kekezyapi.com/api.php/provide/vod/` | [G2] | candidate | HTTPS；单一公开配置证据，需优先结构检查。 |
| 23 | 茅台资源 | `https://caiji.maotaizy.cc/api.php/provide/vod/` | [G1] | candidate | HTTPS；Epic 既有研究 lead，本轮未做实时访问。 |
| 24 | 奇虎资源 | `https://caiji.qhzyapi.com/api.php/provide/vod/` | [G2] | candidate | HTTPS；名称不代表 360/奇虎官方合作。 |
| 25 | 非凡资源 | `https://cj.ffzyapi.com/api.php/provide/vod/` | [G1] | candidate | HTTPS；存在多个历史域名，必须按同一 logical provider 去重。 |
| 26 | 影图资源 | `https://cj.vodimg.top/api.php/provide/vod/` | [G2] | candidate | HTTPS；需检查封面 URL 和媒体 URL 是否为公网安全目标。 |
| 27 | 丫丫资源 | `https://cj.yayazy.net/api.php/provide/vod/` | [G1] | candidate | HTTPS；另有镜像域名，晋级前先确认独立性。 |
| 28 | 华为吧资源 | `https://cjhwba.com/api.php/provide/vod/` | [G7] | candidate | HTTPS；名称不代表华为官方合作，禁止任何官方暗示。 |
| 29 | CK资源 | `https://ckzy.me/api.php/provide/vod/` | [G1] | candidate | HTTPS；存在旧 HTTP 同名域名，先做身份和迁移关系审查。 |
| 30 | 卧龙资源 | `https://collect.wolongzy.cc/api.php/provide/vod/` | [G1] | candidate | HTTPS；存在多个相近域名，只能按一个 provider 进入 KPI。 |
| 31 | 大漠资源 | `https://damozy.com/api.php/provide/vod/` | [G2] | candidate | HTTPS；需确认 JSON schema 和当前维护主体。 |
| 32 | 海外看资源 | `https://haiwaikan.com/api.php/provide/vod/` | [G2] | candidate | HTTPS；原配置标记 VPN，可能有明显地域/出口差异。 |
| 33 | 花都影视 | `https://hdys2.com/api.php/provide/vod/` | [G2] | candidate | HTTPS；内容范围和权利状态未知。 |
| 34 | HG资源 | `https://hong.hgyx.vip/api.php/provide/vod/` | [G6] | candidate | HTTPS；标识不透明，必须先确认内容类型和站点主体。 |
| 35 | 神马资源 | `https://img.smdyw.top/api.php/provide/vod` | [G7] | candidate | HTTPS；API 位于 `img` 子域，需额外验证重定向和响应类型。 |
| 36 | 小黄人资源 | `https://iqyi.xiaohuangrentv.com/api.php/provide/vod/` | [G4] | candidate | HTTPS；`iqyi` 子域不代表爱奇艺官方接口或授权。 |
| 37 | 极光资源 | `https://jiguang.la/api.php/provide/vod/` | [G2] | candidate | HTTPS；单一配置证据，需优先确认 endpoint 所有权。 |
| 38 | 金鹰资源 | `https://jinyingzy.com/api.php/provide/vod/` | [G1] | candidate | HTTPS；Epic 既有 research lead，另有镜像条目不得重复计数。 |
| 39 | 黑木耳资源 | `https://json.heimuer.xyz/api.php/provide/vod/` | [G3] | candidate | HTTPS；存在多个 JSON/XML 子域，需确认稳定主入口。 |
| 40 | 聚星资源 | `https://jxzyw.top/api.php/provide/vod/` | [G3] | candidate | HTTPS；内容类型和可播链路均未验证。 |
| 41 | 快看资源 | `https://kuaikan-api.com/api.php/provide/vod/` | [G2] | candidate | HTTPS；需检查是否返回直接媒体 URL 或播放器页面。 |
| 42 | 乐视资源 | `https://leshiapi.com/api.php/provide/vod/` | [G7] | candidate | HTTPS；名称不代表乐视官方合作，另有旧域名需去重。 |
| 43 | 爱胆资源 | `https://lovedan.net/api.php/provide/vod/` | [G6] | candidate | HTTPS；配置中存在“爱胆/艾旦”异名，先归一化 source identity。 |
| 44 | 秒看资源 | `https://mkzy.vip/api.php/provide/vod/` | [G2] | candidate | HTTPS；需验证站点类型、结构和合法使用条件。 |
| 45 | 新马影视 | `https://movie.gsl99.com/api.php/provide/vod/` | [G2] | candidate | HTTPS；`movie` 子域可能偏电影，先作为 movie specialist 候选评估。 |
| 46 | 魔爪资源 | `https://mozhuazy.com/api.php/provide/vod/` | [G1] | candidate | HTTPS；需检查搜索、详情和分集完整性。 |
| 47 | OLE资源 | `https://olevod1.com/api.php/provide/vod/` | [G6] | candidate | HTTPS；消费站域名暴露 API 不等于允许第三方聚合，合规审查优先。 |
| 48 | 飘零资源 | `https://p2100.net/api.php/provide/vod/` | [G1] | candidate | HTTPS；需确认当前站点主体和稳定域名。 |
| 49 | 四圈资源 | `https://pg.fenwe078.cf/api.php/provide/vod/` | [G2] | candidate | HTTPS；免费子域形态有较高迁移风险，先验证 DNS/证书稳定性。 |
| 50 | 闪电资源 | `https://sdzyapi.com/api.php/provide/vod/` | [G1] | candidate | HTTPS；另有子域镜像，按同一 provider 处理。 |
| 51 | 索尼资源 | `https://suoniapi.com/api.php/provide/vod/` | [G1] | candidate | HTTPS；Epic 既有 research lead，名称不代表 Sony 官方合作。 |
| 52 | 天涯资源 | `https://ty.tyyszy5.com/api.php/provide/vod/` | [G3] | candidate | HTTPS；存在多个域名，需建立 alias/migration 关系。 |
| 53 | 小绵羊资源 | `https://vs.okcdn100.top/api.php/provide/vod/` | [G3] | candidate | HTTPS；API 位于 CDN 风格子域，需验证所有权与重定向安全。 |
| 54 | 39影视 | `https://www.39kan.com/api.php/provide/vod/` | [G8] | candidate | HTTPS；证据快照来自 2023，时效风险高。 |
| 55 | 电影雷达 | `https://www.dianyingleida.com/api.php/provide/vod/` | [G2] | candidate | HTTPS；可能偏电影，先作为 movie specialist 候选评估。 |
| 56 | 飞速资源 | `https://www.feisuzyapi.com/api.php/provide/vod/` | [G7] | candidate | HTTPS；存在多个同品牌域名，必须按一个 logical provider 去重。 |
| 57 | 映迷资源 | `https://www.inmi.app/api.php/provide/vod/` | [G7] | candidate | HTTPS；消费站域名/API 授权未知，人工 review 优先。 |
| 58 | 快云资源 | `https://www.kuaiyunzy.com/api.php/provide/vod/` | [G2] | candidate | HTTPS；需验证是否仍由原维护主体运营。 |
| 59 | 人人影视 | `https://www.rrvipw.com/api.php/provide/vod/` | [G2] | candidate | HTTPS；名称不代表任何官方/原品牌合作，权利审查优先。 |
| 60 | 无忧资源 | `https://www.wyvod.com/api.php/provide/vod/` | [G6] | candidate | HTTPS；仅单一配置证据，需验证标准 JSON 行为。 |
| 61 | 享看资源 | `https://xkanzy10.com/api.php/provide/vod/` | [G2] | candidate | HTTPS；带编号域名可能频繁迁移，稳定性风险较高。 |
| 62 | 熊掌资源 | `https://xzcjz.com/api.php/provide/vod/` | [G2] | candidate | HTTPS；需确认详情和播放字段是否符合 MacCMS v10 JSON。 |
| 63 | 优速资源 | `https://yszyw1.top/api.php/provide/vod/` | [G3] | candidate | HTTPS；带编号域名可能是迁移入口，先验证 canonical host。 |
| 64 | 速看资源 | `https://ziyuan.skm3u8.com/api.php/provide/vod/` | [G2] | candidate | HTTPS；域名含 `m3u8` 不代表首分片可读。 |
| 65 | 宝片资源 | `https://zpsps.com/api.php/provide/vod/` | [G4] | candidate | HTTPS；只在一份 CMS 配置中出现，需高优先级结构检查。 |
| 66 | 看看资源 | `https://zy.hikan.xyz/api.php/provide/vod/` | [G2] | candidate | HTTPS；免费子域形态有迁移和证书风险。 |
| 67 | 虾米资源 | `https://zy.hls.one/api.php/provide/vod/` | [G3] | candidate | HTTPS；`hls` 域名不等于返回线路已通过媒体验证。 |
| 68 | 金蝉资源 | `https://zy.jinchancaiji.com/api.php/provide/vod/` | [G3] | candidate | HTTPS；需验证 content type 覆盖和媒体 Host 独立性。 |
| 69 | Fox API资源 | `https://api.foxzyapi.com/api.php/provide/vod/` | [G8] | candidate | HTTPS；证据快照来自 2023，需先确认域名和维护主体是否仍有效。 |
| 70 | 酷点资源 | `https://api.kuapi.cc/api.php/provide/vod/` | [G8] | candidate | HTTPS；证据快照来自 2023，结构与时效均未验证。 |
| 71 | 诺迅资源 | `https://caiji.nxflv.com/api.php/provide/vod/` | [G8] | candidate | HTTPS；证据快照来自 2023，需确认是否仍为同一 provider。 |
| 72 | 共青春影院 | `https://gqcyy.com/api.php/provide/vod/` | [G8] | candidate | HTTPS；历史配置线索，消费站接口授权和时效风险高。 |
| 73 | 考拉TV | `https://ikaola.tv/api.php/provide/vod/` | [G8] | candidate | HTTPS；证据快照来自 2023，需重新确认 endpoint 和条款。 |
| 74 | 松鼠资源 | `https://m3u8.songshuzy.com/api.php/provide/vod/` | [G8] | candidate | HTTPS；历史线索，需验证域名、schema 和首媒体段。 |
| 75 | 想看资源 | `https://m3u8.xiangkanapi.com/api.php/provide/vod/` | [G8] | candidate | HTTPS；证据快照来自 2023，另有同品牌域名需去重。 |
| 76 | 趣看资源 | `https://qkmp4.cn/api.php/provide/vod/` | [G8] | candidate | HTTPS；历史配置线索，可能偏 MP4，需验证 Range 与文件头。 |
| 77 | 200121资源 | `https://www.200121.com/api.php/provide/vod/` | [G8] | candidate | HTTPS；数字品牌信息不足且证据较旧，人工 review 优先。 |
| 78 | 八戒资源 | `https://www.bajiezy.xyz/api.php/provide/vod/` | [G8] | candidate | HTTPS；历史配置线索，免费子域和时效风险较高。 |
| 79 | 冠军资源 | `https://www.cmpzy.com/api.php/provide/vod/` | [G8] | candidate | HTTPS；证据快照来自 2023，需重新确认结构和授权。 |
| 80 | 鱼乐资源 | `https://www.ylzy1.com/api.php/provide/vod/` | [G8] | candidate | HTTPS；历史配置线索，带编号域名可能存在迁移风险。 |

## 5. 镜像、别名与迁移候选（20 条，不独立计数）

这些 URL 可能是上表逻辑组或当前正式源的镜像、旧域名、专线路径。它们可以帮助找回迁移后的 endpoint，但在没有证明独立内容覆盖和独立维护主体前，**不得提升 `candidate_source_count`、`production_source_count` 或 host-diversity KPI**。

| # | name / provisional group | api | discovered_from | review_status | notes / 风险 |
| ---: | --- | --- | --- | --- | --- |
| M01 | 360镜像（当前正式 360） | `https://360zy.tv/api.php/provide/vod/` | [G6] | candidate | 与当前正式 `360` 同品牌；只作迁移线索，不算新增 source。 |
| M02 | 樱花镜像 | `https://api.apiyhzy.com/api.php/provide/vod/` | [G6] | candidate | 与主候选樱花同品牌；先比较站点标识、内容和媒体 Host。 |
| M03 | U酷镜像 | `https://api.ukuapi88.com/api.php/provide/vod/` | [G1] | candidate | 与 U酷主候选疑似同一 provider，不得重复计数。 |
| M04 | 无尽镜像（当前正式无尽） | `https://api.wujinapi.cc/api.php/provide/vod/` | [G1] | candidate | 与当前正式无尽同品牌；只用于域名迁移研究。 |
| M05 | 无尽镜像（当前正式无尽） | `https://api.wujinapi.com/api.php/provide/vod/` | [G1] | candidate | 与当前正式无尽同品牌；只用于域名迁移研究。 |
| M06 | 无尽镜像（当前正式无尽） | `https://api.wujinapi.net/api.php/provide/vod/` | [G1] | candidate | 与当前正式无尽同品牌；只用于域名迁移研究。 |
| M07 | 豆瓣镜像 | `https://dbzy.tv/api.php/provide/vod/` | [G1] | candidate | 与豆瓣主候选疑似同一 provider，名称仍不得暗示豆瓣官方。 |
| M08 | 卧龙镜像 | `https://collect.wolongzyw.com/api.php/provide/vod/` | [G1] | candidate | 与卧龙主候选疑似同一 provider，需做绑定和 Host 对照。 |
| M09 | 华为吧镜像 | `https://huawei8.live/api.php/provide/vod/` | [G3] | candidate | 与华为吧主候选疑似同一 provider，不代表华为官方合作。 |
| M10 | 华为吧镜像 | `https://hw8.live/api.php/provide/vod/` | [G2] | candidate | 与华为吧主候选疑似同一 provider，不得重复计数。 |
| M11 | 黑木耳镜像 | `https://json02.heimuer.xyz/api.php/provide/vod/` | [G4] | candidate | 与黑木耳主候选疑似同一 provider，先确认 canonical endpoint。 |
| M12 | 金鹰镜像 | `https://jyzyapi.com/api.php/provide/vod/` | [G1] | candidate | 与金鹰主候选疑似同一 provider，不代表任何官方合作。 |
| M13 | 乐视镜像 | `https://leshizyapi.com/api.php/provide/vod/` | [G2] | candidate | 与乐视主候选疑似同一 provider，不得作官方暗示。 |
| M14 | 飞速镜像 | `https://m3u8.feisuzyapi.com/api.php/provide/vod/` | [G7] | candidate | 与飞速主候选疑似同一 provider，只作域名/线路迁移线索。 |
| M15 | 天空专线路径 | `https://m3u8.tiankongapi.com/api.php/provide/vod/from/tkm3u8/` | [G7] | candidate | 与天空主候选同品牌且限定线路，不算独立 source。 |
| M16 | 天涯镜像 | `https://tyyszy.com/api.php/provide/vod/` | [G1] | candidate | 与天涯主候选疑似同一 provider，需确认当前 canonical host。 |
| M17 | 卧龙镜像 | `https://wolongzyw.com/api.php/provide/vod/` | [G1], [G5] | candidate | 多份当前配置出现，但仍需与卧龙主候选合并评估。 |
| M18 | 丫丫镜像 | `https://yayazy2.com/api.php/provide/vod/` | [G6] | candidate | 与丫丫主候选疑似同一 provider，不得重复计数。 |
| M19 | 想看镜像 | `https://xiangkanzy.com/api.php/provide/vod/` | [G8] | candidate | 与想看主候选同品牌且证据较旧，只作迁移线索。 |
| M20 | 樱花历史域名 | `https://yhzy.cc/api.php/provide/vod/` | [G8] | candidate | 与樱花主候选同品牌且证据较旧，只作历史迁移线索。 |

## 6. 建议的 Source Promotion Pipeline

每条候选必须按顺序通过，不能因为公开配置里写了 `type: 1` 或 `quickSearch: 1` 就跳级：

1. **人工合规审查**：确认站点主体、公开使用条款、内容权利、第三方聚合/缓存/再展示许可；没有明确许可就保持 candidate 或 quarantine。
2. **静态安全检查**：只允许 `http(s)`；拒绝 userinfo、凭据和私有 IP；解析 DNS 后再次阻止私网/保留地址；重定向逐跳复验；限制端口、超时和响应体。
3. **结构检查**：验证 `ac=list`、`ac=detail`、`wd`、`ids`、分页、JSON content type、必需字段、错误响应和速率限制；不访问媒体。
4. **目标 VPS Smoke**：在生产出口执行 search → detail → episode mapping → media candidate → manifest/file header → key（如有）→ first segment/range；完整脱敏。
5. **Coverage Benchmark**：按 anime/tv/movie 和困难样本输出 coverage、wrong match、wrong episode、latency、server verified、client probe 和 unique media hosts。
6. **人工 Review 与分层**：只将有授权且通过证据的站点晋级 `core`、`fallback`、`specialist` 或 `client_probe`；失败进入 `quarantine`。
7. **运行时隔离**：candidate registry 与正式 `maccms_sites.py` 分开；任何用户请求都不能 fan-out 到全部候选。

## 7. 本轮排除规则

以下类型没有进入上表：

- 当前正式表中的 20 个 endpoint 主机；
- kanju1 私有 API、ticket、CDN、HMAC、Cookie、token 或账号数据；
- IP literal、localhost、私网/保留地址和带 userinfo 的 URL；
- 只给 XML (`/at/xml`) 且没有同证据 JSON/base endpoint 的条目；
- 明显成人/情色来源；
- 解析器、播放器页、网盘、DRM、BT、磁力、视频代理和需要登录的入口；
- 仅有第三方文章转述、搜索摘要或无法固定提交证据的 URL。

## 8. 待确认事项

1. 站点许可和内容权利必须由项目所有者/法务做人工确认；公开 endpoint 不构成授权。
2. 本文记录的是候选发现阶段；PR6 后续已生成独立的
   `server/data/maccms_candidates.json`，由严格 schema/validator 加载并保持
   `review_status=candidate`，不代表本文发现时已经完成验证。
3. G8 是 2023 历史快照，只适合补充 lead，不能与 2026 当前配置同等看待。
4. 任何 promotion 结论必须来自目标 Zeluna VPS 出口的当前 Smoke/Coverage 证据；本机 HTTP 200、GitHub 配置出现或域名可解析都不够。

## 9. PR6 后续状态

目标 VPS 的后续 Smoke/Coverage、候选晋级门和生产未变证明记录在
[`maccms-pr6-live-probe-2026-08-24.md`](maccms-pr6-live-probe-2026-08-24.md)。
当前仍是 80 个候选、0 个自动晋级、0 个据此新增到正式表；技术实测通过不替代
内容权利和服务条款的人工审核。

[G1]: https://github.com/cluntop/tvbox/blob/b5c28cee65981db5cac56bed6b215a7a74a7804b/js/cj.json
[G2]: https://github.com/xiongjian83/TvBox/blob/1717a78bad2dc29519f0efde4ab5d39876c787b3/ZY.json
[G3]: https://github.com/hd9211/Tvbox1/blob/9766d3045e3345aad84ce73fdbe23102159a059e/zy.json
[G4]: https://github.com/heroaku/TVboxo/blob/42edfca812780525e95a1c1c2d97d6ed664e27a4/Text/cmstv.json
[G5]: https://github.com/qist/tvbox/blob/36b5158f8510f242926348c15c2f3a13cfec0495/dianshi.json
[G6]: https://github.com/anaer/Meow/blob/dfd4a00fc94ef82ee8afe63d9b49bb74e06e031a/meow.json
[G7]: https://github.com/shidahuilang/shuyuan-bak/blob/399cba926cbcbc029ff2376d7248b67bbca19f29/UZ.json
[G8]: https://github.com/liu673cn/bug/blob/7820ab8e94f060401f791a646df760404276098e/vod/m.json
