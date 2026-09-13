# 全线路 VPS 验收与独立影视接入（2026-09-13 UTC）

## 背景与目标
用户要求影视剧资源也走独立源，并验证所有线路，完成后合并 main、双端同版打包及服务器上线。验收不能把搜索命中当成播放成功，也不能通过删线路凑成功率。

## 范围与关键规则
- 盘点 118 个配置条目：20 个正式 MacCMS、13 个爬虫、80 个未晋级候选、5 个旧 TVBox 兼容接口。条目不等于独立站点，可能共享源站。
- 全部条目均有结果；实际查询《庆余年》2019 第1/3集、《流浪地球》2019、《葬送的芙莉莲》2023 第1/3集、《铃芽之旅》2022。
- 采用应用当前标题、类型、年份和季数匹配规则；逐条检查匹配样本返回的全部媒体线路，不截前三条、不首次成功即结束。相同 URL 的网络结果可以复用，但保留每个返回的线路身份。
- 验证清单、必要密钥和首媒体分片；不保存完整媒体地址、签名参数、Cookie 或请求头。不等于全部作品全部集数、连续观看或 Android/Windows 解码验收。
- 保留正式 20 条（17 启用、3 原隔离）、80 候选和所有 AniCh 兜底；不自动晋级候选。旧 VOD 元数据/解析兼容层不参与稳定作品发现，也不计作独立片源。

## 已验证结果
- 样本共返回 444 条线路：171 条服务器媒体验证通过，99 条需客户端出口确认，174 条未通过。
- 没有匹配或未返回媒体的条目在下表明确标注，不能据此断言源站永久没有资源。
- AniCh 在《葬送的芙莉莲》第1/3集分别返回60/61条，全部进入本次逐条验证，不再把历史“58条”当成固定上限。
- 西瓜卡通首次匹配成功但无媒体；定位为播放器 iframe.src 改由同源公开接口动态填充。补充最小解析后，番剧第1/3集及动画电影共3条均通过服务器媒体检查；保留 HTTPS、播放器域名及视频ID校验，授权失败不尝试绕过。
- 樱花冷索引未命中四个主样本。独立补测一页索引506条后，《紫罗兰永恒花园剧场版》2020匹配成功，媒体为需客户端验证；不把它计成服务器通过。

## 全量条目结果
每格为“服务器通过 / 需客户端 / 未通过”；无线路则记录发现状态。

| 类别 | 来源 | 真人剧 | 真人电影 | 番剧 | 动画电影 |
|---|---|---|---|---|---|
| crawler | age | 未声明此类型 | 未声明此类型 | 2 / 4 / 4 | 未声明此类型 |
| crawler | dm706 | 未声明此类型 | 未声明此类型 | search_timeout | 未声明此类型 |
| crawler | girigiri | search_miss | search_miss | 3 / 0 / 0 | 1 / 0 / 0 |
| crawler | anich | 未声明此类型 | 未声明此类型 | 71 / 3 / 47 | 未声明此类型 |
| crawler | xgcartoon | search_hit_no_match | search_hit_no_match | 2 / 0 / 0 | 1 / 0 / 0 |
| crawler | yhdmm | search_miss | search_miss | search_miss | search_miss |
| crawler | jibi | search_miss | search_miss | search_miss | search_miss |
| crawler | yinghua2 | search_miss | search_miss | search_miss | search_miss |
| crawler | wedm | search_miss | search_miss | search_miss | search_miss |
| crawler | xifan | search_miss | search_miss | 4 / 0 / 0 | 1 / 0 / 0 |
| crawler | nivod | 6 / 2 / 4 | 5 / 1 / 0 | 8 / 2 / 0 | 2 / 0 / 1 |
| crawler | ppnix | 2 / 0 / 0 | 1 / 0 / 0 | 未声明此类型 | 0 / 0 / 1 |
| crawler | dbku | search_hit_no_match | search_hit_no_match | 未声明此类型 | search_miss |
| configured | iKun | 2 / 0 / 0 | 1 / 0 / 0 | 2 / 0 / 0 | 1 / 0 / 0 |
| configured | 光速 | 2 / 0 / 2 | 1 / 0 / 1 | 2 / 0 / 2 | 1 / 0 / 1 |
| configured | 如意 | searching | 1 / 0 / 1 | 2 / 0 / 2 | 1 / 0 / 1 |
| configured | 豪华 | 2 / 0 / 2 | 1 / 0 / 1 | 2 / 0 / 2 | 1 / 0 / 1 |
| configured | 极速 | 0 / 2 / 2 | 0 / 1 / 1 | 0 / 2 / 2 | 0 / 1 / 1 |
| configured | 猫眼 | 2 / 0 / 0 | 1 / 0 / 0 | search_hit_no_match | 1 / 0 / 0 |
| configured | 魔都2 | 2 / 0 / 0 | 1 / 0 / 0 | 2 / 0 / 0 | 1 / 0 / 0 |
| configured | 速博 | 0 / 0 / 4 | 0 / 0 / 2 | 1 / 0 / 3 | 0 / 0 / 2 |
| configured | 魔都 | 2 / 0 / 0 | 1 / 0 / 0 | 2 / 0 / 0 | 1 / 0 / 0 |
| configured | 红牛 | 1 / 0 / 3 | 1 / 0 / 1 | 2 / 0 / 2 | 1 / 0 / 1 |
| configured | 风车 | not_queried | not_queried | search_error | not_queried |
| configured | 爱奇艺 | 0 / 0 / 2 | 0 / 0 / 1 | search_hit_no_match | 0 / 0 / 1 |
| configured | 量子 | 0 / 0 / 4 | 0 / 0 / 2 | 0 / 0 / 4 | 0 / 0 / 2 |
| configured | 电影天堂 | 1 / 0 / 3 | 0 / 2 / 0 | 0 / 4 / 0 | 0 / 2 / 0 |
| configured | 暴风 | 0 / 0 / 2 | 0 / 0 / 1 | 0 / 0 / 2 | 0 / 0 / 1 |
| configured | 百度 | 0 / 2 / 0 | 0 / 1 / 0 | 匹配但无媒体 | search_miss |
| configured | 无尽 | 0 / 2 / 0 | 0 / 1 / 0 | 0 / 2 / 0 | 0 / 1 / 0 |
| configured | 最大 | 0 / 2 / 0 | 0 / 1 / 0 | 0 / 2 / 0 | 0 / 1 / 0 |
| configured | 360 | 2 / 0 / 0 | 1 / 0 / 0 | 2 / 0 / 0 | 1 / 0 / 0 |
| configured | 虎牙 | 0 / 0 / 4 | 0 / 0 / 2 | 0 / 0 / 4 | 0 / 0 / 2 |
| candidate | 1080P资源 | search_error | search_error | search_error | search_error |
| candidate | 1080zyk优质资源库 | search_error | search_error | search_error | search_error |
| candidate | 49资源 | search_error | search_error | search_error | search_error |
| candidate | 68资源 | search_error | search_error | search_error | search_error |
| candidate | 蓝天90 | search_error | search_error | search_error | search_error |
| candidate | 樱花资源 | search_error | search_error | search_error | search_error |
| candidate | 蜂巢片库 | search_error | search_error | search_error | search_error |
| candidate | 金马资源 | search_error | search_error | search_error | search_error |
| candidate | 牛牛资源 | search_error | search_error | search_error | search_error |
| candidate | OK资源 | search_error | search_error | search_error | search_error |
| candidate | 天空资源 | search_error | search_error | search_error | search_error |
| candidate | TOM资源 | search_error | search_error | search_error | search_error |
| candidate | U酷资源 | 0 / 4 / 0 | 0 / 2 / 0 | 0 / 4 / 0 | 0 / 2 / 0 |
| candidate | 无限资源 | search_error | search_error | search_error | search_error |
| candidate | 旺旺资源 | search_error | search_error | search_error | search_error |
| candidate | 新浪资源 | 2 / 0 / 2 | 1 / 0 / 1 | 0 / 0 / 4 | 0 / 0 / 2 |
| candidate | 易看资源 | search_error | search_error | search_error | search_error |
| candidate | 秒播资源 | search_hit_no_match | 0 / 1 / 0 | 0 / 2 / 0 | 0 / 1 / 0 |
| candidate | 白狐资源 | search_error | search_error | search_error | search_error |
| candidate | 豆瓣资源 | search_error | search_error | search_error | search_error |
| candidate | 快车资源 | search_error | search_error | search_error | search_error |
| candidate | 可可资源 | search_error | search_error | search_error | search_error |
| candidate | 茅台资源 | search_miss | search_miss | search_miss | search_miss |
| candidate | 奇虎资源 | search_error | search_error | search_error | search_error |
| candidate | 非凡资源 | 0 / 3 / 1 | 0 / 2 / 0 | 0 / 4 / 0 | 0 / 2 / 0 |
| candidate | 影图资源 | search_error | search_error | search_error | search_error |
| candidate | 丫丫资源 | search_error | search_error | search_error | search_error |
| candidate | 华为吧资源 | search_error | search_error | search_error | search_error |
| candidate | CK资源 | search_miss | search_miss | search_miss | search_miss |
| candidate | 卧龙资源 | search_error | search_error | search_error | search_error |
| candidate | 大漠资源 | search_error | search_error | search_error | search_error |
| candidate | 海外看资源 | search_error | search_error | search_error | search_error |
| candidate | 花都影视 | search_error | search_error | search_error | search_error |
| candidate | HG资源 | 2 / 2 / 4 | 1 / 3 / 1 | 2 / 2 / 2 | 1 / 0 / 0 |
| candidate | 神马资源 | search_error | search_error | search_error | search_error |
| candidate | 小黄人资源 | search_error | search_error | search_error | search_error |
| candidate | 极光资源 | search_error | search_error | search_error | search_error |
| candidate | 金鹰资源 | 0 / 0 / 4 | 0 / 0 / 2 | 0 / 0 / 4 | 0 / 0 / 2 |
| candidate | 黑木耳资源 | search_error | search_error | search_error | search_error |
| candidate | 聚星资源 | search_error | search_error | search_error | search_error |
| candidate | 快看资源 | search_error | search_error | search_error | search_error |
| candidate | 乐视资源 | search_error | search_error | search_error | search_error |
| candidate | 爱胆资源 | 2 / 2 / 0 | 0 / 5 / 1 | 0 / 10 / 2 | 0 / 3 / 2 |
| candidate | 秒看资源 | search_error | search_error | search_error | search_error |
| candidate | 新马影视 | search_timeout | search_timeout | search_timeout | search_timeout |
| candidate | 魔爪资源 | search_error | search_error | search_error | search_error |
| candidate | OLE资源 | search_error | search_error | search_error | search_error |
| candidate | 飘零资源 | search_error | search_error | search_error | search_error |
| candidate | 四圈资源 | search_error | search_error | search_error | search_error |
| candidate | 闪电资源 | search_error | search_error | search_error | search_error |
| candidate | 索尼资源 | search_error | search_error | search_error | search_error |
| candidate | 天涯资源 | search_error | search_error | search_error | search_error |
| candidate | 小绵羊资源 | search_error | search_error | search_error | search_error |
| candidate | 39影视 | search_error | search_error | search_error | search_error |
| candidate | 电影雷达 | search_error | search_error | search_error | search_error |
| candidate | 飞速资源 | search_error | search_error | search_error | search_error |
| candidate | 映迷资源 | search_error | search_error | search_error | search_error |
| candidate | 快云资源 | search_timeout | search_timeout | search_timeout | search_timeout |
| candidate | 人人影视 | search_error | search_error | search_error | search_error |
| candidate | 无忧资源 | search_error | search_error | search_error | search_error |
| candidate | 享看资源 | search_error | search_error | search_error | search_error |
| candidate | 熊掌资源 | search_error | search_error | search_error | search_error |
| candidate | 优速资源 | search_error | search_error | search_error | search_error |
| candidate | 速看资源 | search_error | search_error | search_error | search_error |
| candidate | 宝片资源 | search_error | search_error | search_error | search_error |
| candidate | 看看资源 | search_error | search_error | search_error | search_error |
| candidate | 虾米资源 | search_error | search_error | search_error | search_error |
| candidate | 金蝉资源 | search_error | search_error | search_error | search_error |
| candidate | Fox API资源 | search_error | search_error | search_error | search_error |
| candidate | 酷点资源 | search_error | search_error | search_error | search_error |
| candidate | 诺迅资源 | search_error | search_error | search_error | search_error |
| candidate | 共青春影院 | search_error | search_error | search_error | search_error |
| candidate | 考拉TV | search_error | search_error | search_error | search_error |
| candidate | 松鼠资源 | search_error | search_error | search_error | search_error |
| candidate | 想看资源 | search_error | search_error | search_error | search_error |
| candidate | 趣看资源 | search_error | search_error | search_error | search_error |
| candidate | 200121资源 | search_error | search_error | search_error | search_error |
| candidate | 八戒资源 | search_error | search_error | search_error | search_error |
| candidate | 冠军资源 | search_error | search_error | search_error | search_error |
| candidate | 鱼乐资源 | search_error | search_error | search_error | search_error |
| tvbox_compatibility | 暴风 | 0 / 0 / 2 | no_accepted_match | no_accepted_match | no_accepted_match |
| tvbox_compatibility | 量子 | 0 / 0 / 4 | no_accepted_match | no_accepted_match | no_accepted_match |
| tvbox_compatibility | 非凡 | 0 / 4 / 0 | no_accepted_match | no_accepted_match | no_accepted_match |
| tvbox_compatibility | 索尼 | no_accepted_match | no_accepted_match | no_accepted_match | no_accepted_match |
| tvbox_compatibility | 海外看 | no_accepted_match | no_accepted_match | no_accepted_match | no_accepted_match |

## 上线实施与验收
- 上线在备份、精确 SHA 的 Quality Gates、双端版本及构建清单检查后执行；保留账号、数据库、上传文件和原有来源配置。
- 在原 allowlist 上追加本轮已通过的独立来源 age、xifan、xgcartoon、nivod、ppnix；不替换原来的 MacCMS、GiriGiri、樱花或 AniCh。
- 候选80条和原隔离3条继续保留原状态；未验证来源不混入“已启用可播”数量。
- 上线后再复查 service、本机及公开 API、三类真实作品的发现/取流和数据库完整性。部署实际 SHA、备份位置、健康证据存入不可变发布凭据，而不是在提交前伪造“已上线”。

## 待确认与边界
- 99条 client_probe_required 不等于确认可播；需要对应客户端网络实测。
- 174条未通过包含源站/CDN不可达、媒体失效或拒绝访问，未删除或禁用这些来源。
- 匹配与片段验证不是人工观看内容证明，也未证明长时间播放、全部设备或全部作品永久可用。
- 历史四材料实读 inventory 沿用 engineering-goal-progress.md：total=4、read=4、skipped=0；不声称本轮重读历史四份原材料。
