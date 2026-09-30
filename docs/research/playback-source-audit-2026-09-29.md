# Zeluna 全播放源、已安装规则与双出口实测（2026-09-29）

> 首轮历史快照：后续已完成跨三分类复测、代码修复和 9 条安装配置清理；当前结论以同目录 rule-audit-followup.md/json 为准。本页“未改设置”等表述仅针对首轮。

## 1. 最终结论
**建议保留洛杉矶主后端，在韩国 AWS 评估一个受限的只读补充节点；不建议整套迁移，也不建议现在部署通用 Drpy/浏览器聚合平台。** 两轮证据支持韩国补充 AniCh、最大、百度、速博；不同来源应选择各自更好的出口，而非全站改走韩国。

- 两地各检查完整 118 个配置条目；本机持久化的 64 个已安装规则全部纳入清单，其中 27 个启用。规则独立探测键去重后为 53 个任务，**仍不等于 53 个独立站/片库**。
- 当前 118 项 = 13 爬虫 + 20 正式 MacCMS + 80 待晋级候选 + 5 旧 TVBox 兼容项；生产只启用 9 个 provider（MacCMS 聚合 + 8 爬虫），正式 MacCMS 17 启用、3 原隔离。测试禁用项不等于重新启用。
- 新原站补测：央视官方公开点播样本的两种 HLS 地址均在两地通过；Akianime 与二站动漫搜索、详情、剧集均可读，但静态路径未取得可验媒体，仍须客户端运行/进一步适配。
- 未修改应用设置、源表、白名单、权重、数据库或业务代码；未提交、推送、打包、发布、重启或新增服务。韩国只创建本次临时审计目录与隔离 Python 环境。

## 2. 背景、目标与范围
目标：区分目录活性、规则活性、媒体活性和出口限制，避免用 HTTP 200/搜索命中/仓库活跃冒充可播放；评估新增源及第二出口价值。

### 已验证
- 从当前 Windows Zeluna 的 Hive 文件只读解析规则相关记录；没有打开写入模式，没有复制账号数据库或读取安全存储凭据。找到 1 套账号范围的规则保存状态。Android/其他设备安装状态未读取。
- LA 使用运行服务器已有代码；KR 临时复制同一生产 Python 快照，不启动 API 服务、不挂数据库。两侧均无代理环境变量，使用服务器自身出口。
- 后端四部固定样本：《庆余年》2019 第1/3集、《流浪地球》2019、《葬送的芙莉莲》2023 第1/3集、《铃芽之旅》2022。匹配使用项目现有类型/年份/标题规则，逐条验证适配器返回的媒体，不在首条成功处停止。
- 媒体检查包含格式判别、HLS 清单/必要子清单/必要密钥/首媒体段；不是完整片库、整集下载、连续观看、首帧或移动网络证明。无匹配不能推出源站永久无资源。
- 安装的 Animeko/XBPQ 规则采用实际保存的静态选择器，按样本页抽测；最多选2个播放页、每页最多4个媒体候选。JS/JAR 不执行；验证码、授权、DRM不绕过。静态未取得媒体与失效分别记录。
- 新候选规则只按固定 SHA 读取 JSON/XPath；央视只使用公开点播 API 返回的地址，不改写分辨率/路径、不使用直播解密。

### 未验证
真实 Android/Windows 播放器首帧、长播、跳转、字幕、广告情况；所有作品所有集数；签名 URL 跨出口与客户端 IP 绑定；完整 Drpy/CSP/浏览器嗅探兼容性；AWS 账单额度、CPU 积分和实际出网费用；来源内容的分发授权。

## 3. 双出口全量结果

| 第一轮 | 返回线路 | 服务器通过 | 需客户端出口确认 | 本次失败 |
|---|---:|---:|---:|---:|
| 洛杉矶 | 427 | 153 | 135 | 139 |
| 韩国 AWS | 409 | 247 | 19 | 143 |

同标签/样本/集数/媒体主机可对齐 406 个线路身份：其中韩国通过但 LA 未通过 109 个，反向 12 个。这是辅助对齐，不是签名 URL 字节相同、同时并发或长期稳定性的因果证明。总线路数随搜索、源站、时间变化，不将差值直接说成新增独立源。

### 第二轮：8 个重点条目复核
| 来源 | LA第一轮 | KR第一轮 | LA第二轮 | KR第二轮 | 建议 |
|---|---|---|---|---|---|
| anich | 68 / 43 / 26 | 104 / 3 / 30 | 69 / 43 / 25 | 108 / 3 / 26 | 韩国有重复增益，保留LA兜底 |
| xgcartoon | 3 / 0 / 0 | 未取得样本线路 | 3 / 0 / 0 | 未取得样本线路 | 保留LA；韩国无样本命中 |
| 极速 | 0 / 6 / 6 | 6 / 0 / 6 | 0 / 6 / 6 | 3 / 0 / 3 | 有增益但搜索超时，先低权重观察 |
| 速博 | 3 / 0 / 9 | 6 / 0 / 6 | 2 / 0 / 10 | 6 / 0 / 6 | 韩国优先候选 |
| 百度 | 0 / 3 / 0 | 3 / 0 / 0 | 0 / 3 / 0 | 3 / 0 / 0 | 韩国优先候选 |
| 无尽 | 0 / 6 / 0 | 未取得样本线路 | 0 / 6 / 0 | 未取得样本线路 | 韩国受限；不以韩国替代LA客户端候选 |
| 最大 | 0 / 6 / 0 | 6 / 0 / 0 | 0 / 6 / 0 | 6 / 0 / 0 | 韩国优先候选 |
| 虎牙 | 0 / 0 / 12 | 6 / 0 / 6 | 3 / 0 / 9 | 0 / 0 / 10 | 第二轮退化，暂不晋级稳定池 |

表中每格为 **服务器通过 / 需客户端 / 失败**，不是用户/独立片源数量。第二轮汇总 LA 77 通过、KR 126 通过，亦存在分母与搜索返回变化。

### 既有候选池（不是新发现仓库）
80 个候选中，本轮只有 7 个条目返回样本媒体。HG 两地均有通过（LA6/KR10）；非凡 LA0/KR6；U酷 LA0/KR5；新浪 LA1/KR6；爱胆 LA2/KR12；金鹰两地各3；秒播仅客户端候选。其余73个本次未取得匹配线路。这些是既有候选，不自动晋级，也不重复计算为新增站点。

## 4. 已安装规则与订阅发现
- 64 条安装记录 = 59 自定义 + 5 内置。自定义中 39 Animeko、12 TVBox API、8 Drpy 条目；TVBox/Drpy有跨动漫/剧集/电影别名。
- 两个非空订阅地址均可取回并按项目兼容逻辑解析：xhztv 53 个站点配置、creamycake 18 个 web-selector。另一个历史仓库记录 URL 为空，不能在线刷新。订阅数量与安装数量不要求相等。
- xhztv 含 JSON 注释/尾逗号，严格 json.loads 首次不通过，但与项目一致的清洗后通过；**不能据此把订阅判死**。原始测试记录保留初判，补核文件给出最终结论。
- omofun111 的保存域名 enlienli.link：两地 DNS 失败。荐片脚本所在 rihou.vip：两地 DNS 失败。
- 已装“360官源”Drpy 的 runtime/ext 两个固定地址两地 HTTP404。与后端 MacCMS 的“360”不是同一条规则，不能把后端360一起禁用。
- “聚玩盒子4K”两份脚本文本仍可取，但未执行，**不认定能播**。订阅/JAR可取不代表宿主兼容、安全或所有内站正常。
- 已装稀饭、yinghua2 樱花、青空出现服务器媒体通过；饭团 acgfta 与替换 acgpost 在韩国通过、LA403。已装 yhdm6go 樱花虽能搜索/提取地址但抽测媒体失败，与 yinghua2 不能混同。
- girigiri 后端爬虫可播，但保存的 Animeko 规则样本选择器未命中；应区分规则漂移和原站死亡。风铃旧 aafun.cc 也需对照上游当前入口核验后再更新，不能自动换域。
- 爱看机器人 LA 原生公开清单补测：media_checked，媒体状态 {'server_verified': 2, 'unavailable': 2, 'client_probe_required': 4}；此补测优先于首轮‘原生解析未执行’的记录。
- 爱看机器人 KR 原生公开清单补测：media_checked，媒体状态 {'server_verified': 8}；此补测优先于首轮‘原生解析未执行’的记录。

## 5. 新源与规则仓库
独立研究收敛8个核心一手仓库，详见同目录研究文档。Predidit/KazumiRules 是项目既有上游，可寻找增量；creamycake 是已安装订阅；hjdhnx/drpy3 是新引擎/协议参考，不能直接替换本项目 Drpy2 子集。旧 dr_py 已归档，原 drpy-node 本轮匿名404，不能以镜像提交时间冒充原作者状态。未找到经一手出处核实、去重且无需私密认证的全新 MacCMS 端点。

| 新候选 | LA补测 | KR补测 | 处理建议 |
|---|---|---|---|
| CCTV-public-VOD | 服务器通过2 / 客户端0 / 失败0 | 服务器通过2 / 客户端0 / 失败0 | 可做专用小适配；不等于已接入或全片库证明 |
| akianime | episodes_ok_client_runtime_required；剧集链接84 | episodes_ok_client_runtime_required；剧集链接84 | 可加入候选规则；需客户端/播放器页适配，不当直链后端立即启用 |
| ezdmw | episodes_ok_client_runtime_required；剧集链接114 | episodes_ok_client_runtime_required；剧集链接114 | 可加入候选规则；需客户端/播放器页适配，不当直链后端立即启用 |

央视样本为《动画大放映》2026-09-29 14:05；仅验证该公开样本两种返回 HLS，未登录或请求付费权限。Akianime 得到84个、二站114个剧集链接，可能包含多线路重复，不能说成84/114集或已可播。

## 6. 韩国 VPS 方案与限制
- 实测实例 t3.small，2 vCPU，约1.86GiB内存，磁盘剩余约23.1GiB。探测前可用内存约531MiB，已有约1.0GiB swap占用。机器运行 OpenClaw/Hermes 等既有服务，不是空机。
- 建议只建无状态的源搜索/解析/媒体诊断 worker：不迁移账号/收藏/上传/数据库；不复制私密认证；不开放公共代理。主后端仅通过受限服务间入口调用。
- 首批按源路由：AniCh/最大/百度/速博评估韩国，xgcartoon保留LA；极速观察，虎牙不晋级。保留客户端验证候选和失败回退，不能删来源凑通过率。
- 初始并发建议2，总并发与超时有上限；先测实际RSS再设资源限额，保持既有服务余量。禁止无上限浏览器嗅探、全站预缓存、批量爬取或转码。
- 默认只返回元数据和经检查的播放候选，不默认持续中转视频。韩国验证通过不保证其他客户端IP可用；若媒体有IP绑定，必须设计同出口会话/签名失效重取并实机验收，不能简单转发URL就宣称问题解决。
- AWS实例/出网/CPU积分的实际账单与剩余额度未读取；官方计费文档提示应分别核算这些维度。**没有据此估计用户费用或承诺免费**。启用媒体转发、升级实例或其他付费动作须另行确认。

## 7. 代码/部署一致性与验证
- 本地基线 main / d07d3e40306433b239e0d7e2eed91974eb6aab7d。生产无可读Git元信息；以SHA256记录文件快照，不冒认生产等于本地HEAD。
- 统一换行后，全量探针、正式站表、候选表与本地一致；生产 aggregator 比本地少“批次超时保留已搜到MacCMS结果”的修复。本轮两地使用相同生产快照公平比较，未悄悄更新线上。
- 结束前再次只读提取应用规则，64安装/27启用及所选规则记录与初次完全一致。应用使用中的整份Hive文件元数据有变化/刷新，不将其冒认成整份文件哈希未变；本任务未写应用文件。
- 本地 probe_all_routes/probe_maccms 相关测试通过：14 tests + 20 subtests。Flutter只读内置规则导出测试1项通过；这不是完整应用回归或客户端播放验证。
- 新脚本使用公网DNS校验/固定解析传输；拒绝私网与凭据式URL，响应有界，错误只记录类型；下载规则只当数据，不执行。媒体完整URL、Cookie、Authorization、SSH秘密、账号标识均不写入交付证据。

- 探测结束后所有后台审计进程均已退出；LA服务PID、代码哈希、provider集合未变且HTTP200；KR原有用户服务仍active，监听端点与探测前相同，未上线Zeluna服务。

## 8. 后续实施与验收标准（待授权，不是已执行）
1. 先确认是否更新/禁用明确失效的已装规则；不清空订阅、不覆盖用户关闭状态。
2. 若授权接入韩国：仅部署限额只读worker，配置服务间认证/最小网络暴露，记录回滚；保留LA主后端与原数据库。
3. 独立添加央视公开点播小适配；Akianime/二站先做客户端兼容验证，不直接塞到MacCMS表。
4. 在精确代码版本上验证两端来源选择、首帧、连续播放、跳转和失败回退，测试同源跨出口限制；确认旧账号/收藏不变。
5. 只有完成客户端验收、资源/账单检查及独立复核后才晋级稳定池或发布新版本；发布时另遵守版本递增与精确HEAD门禁。

## 附录A：118条完整后端条目

每格为服务器通过 / 需客户端 / 失败。未返回线路保留诊断，不当作永久失效。registered-but-disabled依然探测，但配置未改。
| 类别 | 名称 | LA | 韩国 | 无匹配/发现异常摘要（LA；KR） |
|---|---|---|---|---|
| crawler | age | 2 / 4 / 4 | 未取得样本线路 | 样本已匹配；search_miss×1 |
| crawler | dm706 | 未取得样本线路 | 未取得样本线路 | search_timeout:read_timeout×1；search_timeout:read_timeout×1 |
| crawler | girigiri | 5 / 0 / 0 | 5 / 0 / 0 | search_miss×2；search_miss×2 |
| crawler | anich | 68 / 43 / 26 | 104 / 3 / 30 | 样本已匹配；样本已匹配 |
| crawler | xgcartoon | 3 / 0 / 0 | 未取得样本线路 | search_hit_no_match×2；search_miss×4 |
| crawler | yhdmm | 未取得样本线路 | 未取得样本线路 | search_miss×4；search_miss×4 |
| crawler | jibi | 未取得样本线路 | 未取得样本线路 | search_miss×4；search_miss×4 |
| crawler | yinghua2 | 未取得样本线路 | 未取得样本线路 | search_miss×4；search_miss×4 |
| crawler | wedm | 未取得样本线路 | 未取得样本线路 | search_miss×4；search_miss×4 |
| crawler | xifan | 5 / 0 / 0 | 4 / 0 / 1 | search_miss×2；search_miss×2 |
| crawler | nivod | 未取得样本线路 | 未取得样本线路 | search_timeout:read_timeout×4；search_timeout:read_timeout×4 |
| crawler | ppnix | 3 / 0 / 1 | 3 / 0 / 1 | 样本已匹配；样本已匹配 |
| crawler | dbku | 未取得样本线路 | 未取得样本线路 | search_hit_no_match×2; search_miss×1；search_hit_no_match×2; search_miss×1 |
| configured | iKun | 6 / 0 / 0 | 6 / 0 / 0 | 样本已匹配；样本已匹配 |
| configured | 光速 | 6 / 0 / 6 | 6 / 0 / 6 | 样本已匹配；样本已匹配 |
| configured | 如意 | 4 / 0 / 4 | 4 / 0 / 4 | searching×1；searching×1 |
| configured | 豪华 | 6 / 0 / 6 | 6 / 0 / 6 | 样本已匹配；样本已匹配 |
| configured | 极速 | 0 / 6 / 6 | 6 / 0 / 6 | 样本已匹配；样本已匹配 |
| configured | 猫眼 | 3 / 0 / 0 | 4 / 0 / 0 | search_timeout:read_timeout×2；search_hit_no_match×1 |
| configured | 魔都2 | 6 / 0 / 0 | 6 / 0 / 0 | 样本已匹配；样本已匹配 |
| configured | 速博 | 3 / 0 / 9 | 6 / 0 / 6 | 样本已匹配；样本已匹配 |
| configured | 魔都 | 5 / 0 / 1 | 6 / 0 / 0 | 样本已匹配；样本已匹配 |
| configured | 红牛 | 6 / 0 / 6 | 6 / 0 / 6 | 样本已匹配；样本已匹配 |
| configured | 风车 | 未取得样本线路 | 未取得样本线路 | not_queried×3; search_error:unknown_exception×1；not_queried×3; search_error:unknown_exception×1；补查：LA:连接/TLS/协议等传输失败/RemoteProtocolError；KR:连接/TLS/协议等传输失败/RemoteProtocolError |
| configured | 爱奇艺 | 2 / 0 / 0 | 4 / 0 / 0 | search_error:search_error×3；search_hit_no_match×1 |
| configured | 量子 | 0 / 0 / 12 | 0 / 0 / 12 | 样本已匹配；样本已匹配 |
| configured | 电影天堂 | 2 / 8 / 2 | 6 / 0 / 6 | 样本已匹配；样本已匹配 |
| configured | 暴风 | 0 / 0 / 6 | 0 / 0 / 6 | 样本已匹配；样本已匹配 |
| configured | 百度 | 0 / 3 / 0 | 3 / 0 / 0 | search_miss×1；search_miss×1 |
| configured | 无尽 | 0 / 6 / 0 | 未取得样本线路 | 样本已匹配；search_error:restricted×4；补查：LA:直接查询已恢复命中 HTTP200；KR:HTTP 拒绝/错误 HTTP403 |
| configured | 最大 | 0 / 6 / 0 | 6 / 0 / 0 | 样本已匹配；样本已匹配 |
| configured | 360 | 6 / 0 / 0 | 6 / 0 / 0 | 样本已匹配；样本已匹配 |
| configured | 虎牙 | 0 / 0 / 12 | 6 / 0 / 6 | 样本已匹配；样本已匹配 |
| candidate | 1080P资源 | 未取得样本线路 | 未取得样本线路 | search_error:unknown_exception×4；search_error:unknown_exception×4；补查：LA:域名解析失败；KR:域名解析失败 |
| candidate | 1080zyk优质资源库 | 未取得样本线路 | 未取得样本线路 | search_error:parser_mismatch×4；search_error:parser_mismatch×4；补查：LA:返回 XML，与 JSON 适配器不匹配 HTTP200；KR:返回 XML，与 JSON 适配器不匹配 HTTP200 |
| candidate | 49资源 | 未取得样本线路 | 未取得样本线路 | search_error:unknown_exception×4；search_error:unknown_exception×4；补查：LA:连接/TLS/协议等传输失败/ConnectError；KR:连接/TLS/协议等传输失败/ConnectError |
| candidate | 68资源 | 未取得样本线路 | 未取得样本线路 | search_error:unknown_exception×4；search_error:unknown_exception×4；补查：LA:域名解析失败；KR:域名解析失败 |
| candidate | 蓝天90 | 未取得样本线路 | 未取得样本线路 | search_error:search_error×4；search_error:search_error×4；补查：LA:HTTP 拒绝/错误 HTTP404；KR:HTTP 拒绝/错误 HTTP404 |
| candidate | 樱花资源 | 未取得样本线路 | 未取得样本线路 | search_error:restricted×4；search_error:restricted×4；补查：LA:HTTP 拒绝/错误 HTTP403；KR:HTTP 拒绝/错误 HTTP403 |
| candidate | 蜂巢片库 | 未取得样本线路 | 未取得样本线路 | search_error:unknown_exception×4；search_error:unknown_exception×4；补查：LA:域名解析失败；KR:域名解析失败 |
| candidate | 金马资源 | 未取得样本线路 | 未取得样本线路 | search_error:unknown_exception×4；search_error:unknown_exception×4；补查：LA:连接/TLS/协议等传输失败/ConnectError；KR:连接/TLS/协议等传输失败/ConnectError |
| candidate | 牛牛资源 | 未取得样本线路 | 未取得样本线路 | search_error:parser_mismatch×4；search_error:parser_mismatch×4；补查：LA:返回非 JSON 内容 HTTP200；KR:返回非 JSON 内容 HTTP200 |
| candidate | OK资源 | 未取得样本线路 | 未取得样本线路 | search_error:unknown_exception×4；search_error:unknown_exception×4；补查：LA:连接/TLS/协议等传输失败/ConnectError；KR:连接/TLS/协议等传输失败/ConnectError |
| candidate | 天空资源 | 未取得样本线路 | 未取得样本线路 | search_error:parser_mismatch×4；search_error:parser_mismatch×4；补查：LA:返回非 JSON 内容 HTTP200；KR:返回非 JSON 内容 HTTP200 |
| candidate | TOM资源 | 未取得样本线路 | 未取得样本线路 | search_error:unknown_exception×4；search_error:unknown_exception×4；补查：LA:域名解析失败；KR:域名解析失败 |
| candidate | U酷资源 | 0 / 12 / 0 | 5 / 2 / 5 | 样本已匹配；样本已匹配 |
| candidate | 无限资源 | 未取得样本线路 | 未取得样本线路 | search_error:unknown_exception×4；search_error:unknown_exception×4；补查：LA:域名解析失败；KR:域名解析失败 |
| candidate | 旺旺资源 | 未取得样本线路 | 未取得样本线路 | search_error:parser_mismatch×4；search_error:parser_mismatch×4；补查：LA:返回非 JSON 内容 HTTP200；KR:返回非 JSON 内容 HTTP200 |
| candidate | 新浪资源 | 1 / 0 / 11 | 6 / 0 / 6 | 样本已匹配；样本已匹配 |
| candidate | 易看资源 | 未取得样本线路 | 未取得样本线路 | search_error:unknown_exception×4；search_error:unknown_exception×4；补查：LA:域名解析失败；KR:域名解析失败 |
| candidate | 秒播资源 | 0 / 4 / 0 | 0 / 4 / 0 | search_hit_no_match×1；search_hit_no_match×1 |
| candidate | 白狐资源 | 未取得样本线路 | 未取得样本线路 | search_error:unknown_exception×4；search_error:unknown_exception×4；补查：LA:域名解析失败；KR:域名解析失败 |
| candidate | 豆瓣资源 | 未取得样本线路 | 未取得样本线路 | search_error:unknown_exception×4；search_error:unknown_exception×4；补查：LA:域名解析失败；KR:域名解析失败 |
| candidate | 快车资源 | 未取得样本线路 | 未取得样本线路 | search_error:unknown_exception×4；search_error:unknown_exception×4；补查：LA:连接/TLS/协议等传输失败/ConnectError；KR:连接/TLS/协议等传输失败/ConnectError |
| candidate | 可可资源 | 未取得样本线路 | 未取得样本线路 | search_error:unknown_exception×4；search_error:unknown_exception×4；补查：LA:域名解析失败；KR:域名解析失败 |
| candidate | 茅台资源 | 未取得样本线路 | 未取得样本线路 | search_miss×4；search_miss×4；补查：LA:空/非标准 JSON 清单 HTTP200；KR:空/非标准 JSON 清单 HTTP200 |
| candidate | 奇虎资源 | 未取得样本线路 | 未取得样本线路 | search_error:unknown_exception×4；search_error:unknown_exception×4；补查：LA:域名解析失败；KR:域名解析失败 |
| candidate | 非凡资源 | 0 / 12 / 0 | 6 / 0 / 6 | 样本已匹配；样本已匹配 |
| candidate | 影图资源 | 未取得样本线路 | 未取得样本线路 | search_error:restricted×4；search_error:restricted×4；补查：LA:HTTP 拒绝/错误 HTTP403；KR:HTTP 拒绝/错误 HTTP403 |
| candidate | 丫丫资源 | 未取得样本线路 | 未取得样本线路 | search_error:parser_mismatch×4；search_error:parser_mismatch×4；补查：LA:返回非 JSON 内容 HTTP200；KR:返回非 JSON 内容 HTTP200 |
| candidate | 华为吧资源 | 未取得样本线路 | 未取得样本线路 | search_error:search_error×4；search_error:search_error×4；补查：LA:HTTP 拒绝/错误 HTTP404；KR:HTTP 拒绝/错误 HTTP404 |
| candidate | CK资源 | 未取得样本线路 | 未取得样本线路 | search_miss×4；search_miss×4；补查：LA:空/非标准 JSON 清单 HTTP200；KR:空/非标准 JSON 清单 HTTP200 |
| candidate | 卧龙资源 | 未取得样本线路 | 未取得样本线路 | search_error:unknown_exception×4；search_error:unknown_exception×4；补查：LA:域名解析失败；KR:域名解析失败 |
| candidate | 大漠资源 | 未取得样本线路 | 未取得样本线路 | search_error:unknown_exception×4；search_error:unknown_exception×4；补查：LA:连接/TLS/协议等传输失败/ConnectError；KR:连接/TLS/协议等传输失败/ConnectError |
| candidate | 海外看资源 | 未取得样本线路 | 未取得样本线路 | search_error:unknown_exception×4；search_error:unknown_exception×4；补查：LA:连接/TLS/协议等传输失败/ConnectError；KR:连接/TLS/协议等传输失败/ConnectError |
| candidate | 花都影视 | 未取得样本线路 | 未取得样本线路 | search_error:unknown_exception×4；search_error:unknown_exception×4；补查：LA:域名解析失败；KR:域名解析失败 |
| candidate | HG资源 | 6 / 7 / 7 | 10 / 0 / 10 | 样本已匹配；样本已匹配 |
| candidate | 神马资源 | 未取得样本线路 | 未取得样本线路 | search_error:parser_mismatch×4；search_error:parser_mismatch×4；补查：LA:返回非 JSON 内容 HTTP200；KR:返回非 JSON 内容 HTTP200 |
| candidate | 小黄人资源 | 未取得样本线路 | 未取得样本线路 | search_error:unknown_exception×4；search_error:unknown_exception×4；补查：LA:域名解析失败；KR:域名解析失败 |
| candidate | 极光资源 | 未取得样本线路 | 未取得样本线路 | search_error:unknown_exception×4；search_error:unknown_exception×4；补查：LA:域名解析失败；KR:域名解析失败 |
| candidate | 金鹰资源 | 3 / 0 / 9 | 3 / 0 / 7 | 样本已匹配；样本已匹配 |
| candidate | 黑木耳资源 | 未取得样本线路 | 未取得样本线路 | search_error:parser_mismatch×4；search_error:parser_mismatch×4；补查：LA:返回非 JSON 内容 HTTP200；KR:返回非 JSON 内容 HTTP200 |
| candidate | 聚星资源 | 未取得样本线路 | 未取得样本线路 | search_error:unknown_exception×4；search_error:unknown_exception×4；补查：LA:域名解析失败；KR:域名解析失败 |
| candidate | 快看资源 | 未取得样本线路 | 未取得样本线路 | search_error:unknown_exception×4；search_error:unknown_exception×4；补查：LA:连接/TLS/协议等传输失败/ConnectError；KR:连接/TLS/协议等传输失败/ConnectError |
| candidate | 乐视资源 | 未取得样本线路 | 未取得样本线路 | search_error:unknown_exception×4；search_error:unknown_exception×4；补查：LA:域名解析失败；KR:域名解析失败 |
| candidate | 爱胆资源 | 2 / 20 / 5 | 12 / 10 / 5 | 样本已匹配；样本已匹配 |
| candidate | 秒看资源 | 未取得样本线路 | 未取得样本线路 | search_error:unknown_exception×4；search_error:unknown_exception×4；补查：LA:域名解析失败；KR:域名解析失败 |
| candidate | 新马影视 | 未取得样本线路 | 未取得样本线路 | search_timeout:connect_timeout×4；search_timeout:connect_timeout×4；补查：LA:连接/TLS/协议等传输失败/ConnectError；KR:连接/TLS/协议等传输失败/ConnectError |
| candidate | 魔爪资源 | 未取得样本线路 | 未取得样本线路 | search_error:unknown_exception×4；search_error:unknown_exception×4；补查：LA:连接/TLS/协议等传输失败/ConnectError；KR:连接/TLS/协议等传输失败/ConnectError |
| candidate | OLE资源 | 未取得样本线路 | 未取得样本线路 | search_error:unknown_exception×4；search_error:unknown_exception×4；补查：LA:连接/TLS/协议等传输失败/ConnectError；KR:连接/TLS/协议等传输失败/ConnectError |
| candidate | 飘零资源 | 未取得样本线路 | 未取得样本线路 | search_error:restricted×4；search_error:restricted×4；补查：LA:HTTP 拒绝/错误 HTTP403；KR:HTTP 拒绝/错误 HTTP403 |
| candidate | 四圈资源 | 未取得样本线路 | 未取得样本线路 | search_error:unknown_exception×4；search_error:unknown_exception×4；补查：LA:域名解析失败；KR:域名解析失败 |
| candidate | 闪电资源 | 未取得样本线路 | 未取得样本线路 | search_error:parser_mismatch×4；search_error:parser_mismatch×4；补查：LA:返回非 JSON 内容 HTTP200；KR:返回非 JSON 内容 HTTP200 |
| candidate | 索尼资源 | 未取得样本线路 | 未取得样本线路 | search_error:parser_mismatch×4；search_error:parser_mismatch×4；补查：LA:返回非 JSON 内容 HTTP200；KR:返回非 JSON 内容 HTTP200 |
| candidate | 天涯资源 | 未取得样本线路 | 未取得样本线路 | search_error:parser_mismatch×4；search_error:parser_mismatch×4；补查：LA:返回非 JSON 内容 HTTP200；KR:返回非 JSON 内容 HTTP200 |
| candidate | 小绵羊资源 | 未取得样本线路 | 未取得样本线路 | search_error:search_error×4；search_error:search_error×4；补查：LA:HTTP 拒绝/错误 HTTP404；KR:HTTP 拒绝/错误 HTTP404 |
| candidate | 39影视 | 未取得样本线路 | 未取得样本线路 | search_error:search_error×4；search_error:search_error×3; search_timeout:read_timeout×1；补查：LA:HTTP 拒绝/错误 HTTP523；KR:HTTP 拒绝/错误 HTTP523 |
| candidate | 电影雷达 | 未取得样本线路 | 未取得样本线路 | search_error:search_error×4；search_error:search_error×4；补查：LA:HTTP 拒绝/错误 HTTP502；KR:HTTP 拒绝/错误 HTTP502 |
| candidate | 飞速资源 | 未取得样本线路 | 未取得样本线路 | search_error:parser_mismatch×4；search_error:parser_mismatch×4；补查：LA:返回非 JSON 内容 HTTP200；KR:返回非 JSON 内容 HTTP200 |
| candidate | 映迷资源 | 未取得样本线路 | 未取得样本线路 | search_error:unknown_exception×4；search_error:unknown_exception×4；补查：LA:连接/TLS/协议等传输失败/ConnectError；KR:连接/TLS/协议等传输失败/ConnectError |
| candidate | 快云资源 | 未取得样本线路 | 未取得样本线路 | search_timeout:connect_timeout×4；search_timeout:connect_timeout×4；补查：LA:连接/TLS/协议等传输失败/ConnectTimeout；KR:连接/TLS/协议等传输失败/ConnectTimeout |
| candidate | 人人影视 | 未取得样本线路 | 未取得样本线路 | search_error:unknown_exception×4；search_error:unknown_exception×4；补查：LA:连接/TLS/协议等传输失败/ConnectError；KR:连接/TLS/协议等传输失败/ConnectError |
| candidate | 无忧资源 | 未取得样本线路 | 未取得样本线路 | search_error:restricted×4；search_error:restricted×4；补查：LA:HTTP 拒绝/错误 HTTP403；KR:HTTP 拒绝/错误 HTTP403 |
| candidate | 享看资源 | 未取得样本线路 | 未取得样本线路 | search_error:unknown_exception×4；search_error:unknown_exception×4；补查：LA:域名解析失败；KR:域名解析失败 |
| candidate | 熊掌资源 | 未取得样本线路 | 未取得样本线路 | search_error:unknown_exception×4；search_error:unknown_exception×4；补查：LA:域名解析失败；KR:域名解析失败 |
| candidate | 优速资源 | 未取得样本线路 | 未取得样本线路 | search_error:unknown_exception×4；search_error:unknown_exception×4；补查：LA:域名解析失败；KR:域名解析失败 |
| candidate | 速看资源 | 未取得样本线路 | 未取得样本线路 | search_error:unknown_exception×4；search_error:unknown_exception×4；补查：LA:域名解析失败；KR:域名解析失败 |
| candidate | 宝片资源 | 未取得样本线路 | 未取得样本线路 | search_error:search_error×4；search_error:search_error×4；补查：LA:HTTP 拒绝/错误 HTTP404；KR:HTTP 拒绝/错误 HTTP404 |
| candidate | 看看资源 | 未取得样本线路 | 未取得样本线路 | search_error:parser_mismatch×4；search_error:parser_mismatch×4；补查：LA:返回非 JSON 内容 HTTP200；KR:返回非 JSON 内容 HTTP200 |
| candidate | 虾米资源 | 未取得样本线路 | 未取得样本线路 | search_error:unknown_exception×4；search_error:unknown_exception×4；补查：LA:域名解析失败；KR:域名解析失败 |
| candidate | 金蝉资源 | 未取得样本线路 | 未取得样本线路 | search_error:unknown_exception×4；search_error:unknown_exception×4；补查：LA:域名解析失败；KR:域名解析失败 |
| candidate | Fox API资源 | 未取得样本线路 | 未取得样本线路 | search_error:parser_mismatch×4；search_error:parser_mismatch×4；补查：LA:返回非 JSON 内容 HTTP200；KR:返回非 JSON 内容 HTTP200 |
| candidate | 酷点资源 | 未取得样本线路 | 未取得样本线路 | search_error:unknown_exception×4；search_error:unknown_exception×4；补查：LA:域名解析失败；KR:域名解析失败 |
| candidate | 诺迅资源 | 未取得样本线路 | 未取得样本线路 | search_error:parser_mismatch×4；search_error:parser_mismatch×4；补查：LA:返回非 JSON 内容 HTTP200；KR:返回非 JSON 内容 HTTP200 |
| candidate | 共青春影院 | 未取得样本线路 | 未取得样本线路 | search_error:search_error×4；search_error:search_error×4；补查：LA:HTTP 拒绝/错误 HTTP404；KR:HTTP 拒绝/错误 HTTP404 |
| candidate | 考拉TV | 未取得样本线路 | 未取得样本线路 | search_error:restricted×4；search_error:restricted×4；补查：LA:HTTP 拒绝/错误 HTTP403；KR:HTTP 拒绝/错误 HTTP403 |
| candidate | 松鼠资源 | 未取得样本线路 | 未取得样本线路 | search_error:unknown_exception×4；search_error:unknown_exception×4；补查：LA:域名解析失败；KR:域名解析失败 |
| candidate | 想看资源 | 未取得样本线路 | 未取得样本线路 | search_error:unknown_exception×4；search_error:unknown_exception×4；补查：LA:域名解析失败；KR:域名解析失败 |
| candidate | 趣看资源 | 未取得样本线路 | 未取得样本线路 | search_error:parser_mismatch×4；search_error:search_error×3; search_error:unknown_exception×1；补查：LA:返回非 JSON 内容 HTTP200；KR:HTTP 拒绝/错误 HTTP204 |
| candidate | 200121资源 | 未取得样本线路 | 未取得样本线路 | search_error:unknown_exception×4；search_error:unknown_exception×4；补查：LA:域名解析失败；KR:域名解析失败 |
| candidate | 八戒资源 | 未取得样本线路 | 未取得样本线路 | search_error:parser_mismatch×3; search_error:unknown_exception×1；search_error:search_error×4；补查：LA:返回非 JSON 内容 HTTP200；KR:HTTP 拒绝/错误 HTTP204 |
| candidate | 冠军资源 | 未取得样本线路 | 未取得样本线路 | search_error:unknown_exception×4；search_error:unknown_exception×4；补查：LA:域名解析失败；KR:域名解析失败 |
| candidate | 鱼乐资源 | 未取得样本线路 | 未取得样本线路 | search_error:unknown_exception×4；search_error:unknown_exception×4；补查：LA:域名解析失败；KR:域名解析失败 |
| tvbox_compatibility | 暴风 | 0 / 0 / 2 | 0 / 0 / 2 | 样本已匹配；样本已匹配 |
| tvbox_compatibility | 量子 | 0 / 0 / 4 | 0 / 0 / 4 | 样本已匹配；样本已匹配 |
| tvbox_compatibility | 非凡 | 0 / 4 / 0 | 2 / 0 / 2 | 样本已匹配；样本已匹配 |
| tvbox_compatibility | 索尼 | 未取得样本线路 | 未取得样本线路 | 样本已匹配；样本已匹配；补查：LA:域名解析失败；KR:域名解析失败 |
| tvbox_compatibility | 海外看 | 未取得样本线路 | 未取得样本线路 | 样本已匹配；样本已匹配；补查：LA:域名解析失败；KR:域名解析失败 |



## 附录B：64条已安装规则完整结果
按实际安装ID保留分类别名；同一底层探测可复用，不能按行相加独立站。只有被启用且通过平台/权限/兼容门限的规则才可能参与应用运行。本表不改用户选择。
| 名称 / 类型 | 引擎 | 已启用 | LA | 韩国 |
|---|---|---|---|---|
| 独播库 / movie | XBPQ | 是 | search_hits_no_sample_match / HTTP200 | search_hits_no_sample_match / HTTP200 |
| 爱看机器人 / anime | aikanbot-api | 是 | {'server_verified': 2, 'unavailable': 2, 'client_probe_required': 4} | {'server_verified': 8} |
| omofun111 / anime | animeko-web-selector | 是 | probe_error / UnsafeDestination | probe_error / UnsafeDestination |
| 樱花动漫 / anime | animeko-web-selector | 是 | 0 / 0 / 2 | 0 / 0 / 2 |
| 风铃动漫 / anime | animeko-web-selector | 是 | search_miss_or_selector_drift / HTTP200 | search_miss_or_selector_drift / HTTP200 |
| 饭团动漫(替换) / anime | animeko-web-selector | 是 | http_error / HTTP403 | 2 / 0 / 0 |
| 🔥聚玩盒子4K / movie | drpy-js | 是 | script_runtime_not_executed | script_runtime_not_executed |
| 🔥聚玩盒子4K / series | drpy-js | 是 | script_runtime_not_executed | script_runtime_not_executed |
| 🧡┃360┃官源 / anime | drpy-js | 是 | script_runtime_not_executed | script_runtime_not_executed |
| 🧡┃360┃官源 / movie | drpy-js | 是 | script_runtime_not_executed | script_runtime_not_executed |
| 🧡┃360┃官源 / series | drpy-js | 是 | script_runtime_not_executed | script_runtime_not_executed |
| 🧲┃荐片┃磁力 / anime | drpy-js | 是 | script_runtime_not_executed | script_runtime_not_executed |
| 🧲┃荐片┃磁力 / movie | drpy-js | 是 | script_runtime_not_executed | script_runtime_not_executed |
| 🧲┃荐片┃磁力 / series | drpy-js | 是 | script_runtime_not_executed | script_runtime_not_executed |
| 青空次元 / anime | sorani-api | 是 | 1 / 0 / 0 | 2 / 0 / 0 |
| 光速资源 / anime | tvbox-json-api | 是 | 6 / 0 / 0 | 6 / 0 / 0 |
| 茅台资源 / anime | tvbox-json-api | 是 | 无样本线路；search_miss×4 | 无样本线路；search_miss×4 |
| 🎥┃光速┃资源 / movie | tvbox-json-api | 是 | 6 / 0 / 6 | 4 / 0 / 4 |
| 🎥┃光速┃资源 / series | tvbox-json-api | 是 | 6 / 0 / 6 | 4 / 0 / 4 |
| 🎥┃索尼┃资源 / movie | tvbox-json-api | 是 | 无样本线路；search_error:parser_mismatch×4 | 无样本线路；search_timeout:read_timeout×2; search_error:parser_mismatch×2 |
| 🎥┃索尼┃资源 / series | tvbox-json-api | 是 | 无样本线路；search_error:parser_mismatch×4 | 无样本线路；search_timeout:read_timeout×2; search_error:parser_mismatch×2 |
| 🎥┃量子┃资源 / anime | tvbox-json-api | 是 | 0 / 0 / 12 | 0 / 0 / 12 |
| 🎥┃量子┃资源 / movie | tvbox-json-api | 是 | 0 / 0 / 12 | 0 / 0 / 12 |
| 🎥┃量子┃资源 / series | tvbox-json-api | 是 | 0 / 0 / 12 | 0 / 0 / 12 |
| 🧡┃初恋┃官源 / anime | tvbox-json-api | 是 | 无样本线路；search_error:parser_mismatch×4 | 无样本线路；search_error:search_error×4 |
| 🧡┃初恋┃官源 / movie | tvbox-json-api | 是 | 无样本线路；search_error:parser_mismatch×4 | 无样本线路；search_error:search_error×4 |
| 🧡┃初恋┃官源 / series | tvbox-json-api | 是 | 无样本线路；search_error:parser_mismatch×4 | 无样本线路；search_error:search_error×4 |
| 泥视频 / movie | XBPQ | 否 | probe_error / ReadTimeout | probe_error / ReadTimeout |
| 2k动漫 / anime | animeko-web-selector | 否 | search_miss_or_selector_drift / HTTP200 | search_miss_or_selector_drift / HTTP200 |
| E-ACG / anime | animeko-web-selector | 否 | http_error / HTTP403 | http_error / HTTP403 |
| E-ACG / anime | animeko-web-selector | 否 | http_error / HTTP403 | http_error / HTTP403 |
| MX动漫 / anime | animeko-web-selector | 否 | probe_error / ConnectError | probe_error / ConnectError |
| UZVOD / anime | animeko-web-selector | 否 | http_error / HTTP403 | http_error / HTTP403 |
| girigiri愛動漫 / anime | animeko-web-selector | 否 | search_miss_or_selector_drift / HTTP200 | search_miss_or_selector_drift / HTTP200 |
| hanime1_1080p / anime | animeko-web-selector | 否 | endpoint_only_outside_mainstream_scope / HTTP200 | endpoint_only_outside_mainstream_scope / HTTP403 |
| hanime1_720p / anime | animeko-web-selector | 否 | endpoint_only_outside_mainstream_scope / HTTP200 | endpoint_only_outside_mainstream_scope / HTTP403 |
| wedm / anime | animeko-web-selector | 否 | 0 / 2 / 0 | http_error / HTTP403 |
| 动漫蛋 / anime | animeko-web-selector | 否 | probe_error / ConnectError | probe_error / ConnectError |
| 去看吧 / anime | animeko-web-selector | 否 | http_error / HTTP403 | http_error / HTTP403 |
| 叽哔动漫 / anime | animeko-web-selector | 否 | 0 / 2 / 0 | 0 / 2 / 0 |
| 咕咕番 / anime | animeko-web-selector | 否 | episodes_ok_client_runtime_or_adapter_required / HTTP200 | episodes_ok_client_runtime_or_adapter_required / HTTP200 |
| 喵物次元 / anime | animeko-web-selector | 否 | search_miss_or_selector_drift / HTTP200 | search_miss_or_selector_drift / HTTP200 |
| 嘀哩嘀哩 / anime | animeko-web-selector | 否 | detail_ok_no_episode_selector_match / HTTP200 | detail_ok_no_episode_selector_match / HTTP200 |
| 嘀嗒影视 / anime | animeko-web-selector | 否 | challenge_client_required / HTTP200 | challenge_client_required / HTTP200 |
| 影视森林 / anime | animeko-web-selector | 否 | http_error / HTTP403 | http_error / HTTP403 |
| 新优酷 / anime | animeko-web-selector | 否 | http_error / HTTP403 | http_error / HTTP403 |
| 森之屋动漫 / anime | animeko-web-selector | 否 | episodes_ok_client_runtime_or_adapter_required / HTTP200 | episodes_ok_client_runtime_or_adapter_required / HTTP200 |
| 樱花动漫 / anime | animeko-web-selector | 否 | 2 / 0 / 0 | 2 / 0 / 0 |
| 次元城动画 / anime | animeko-web-selector | 否 | http_error / HTTP403 | search_miss_or_selector_drift / HTTP200 |
| 次元方舟 / anime | animeko-web-selector | 否 | http_error / HTTP403 | http_error / HTTP403 |
| 海星动漫 / anime | animeko-web-selector | 否 | episodes_ok_client_runtime_or_adapter_required / HTTP200 | episodes_ok_client_runtime_or_adapter_required / HTTP200 |
| 漫次元 / anime | animeko-web-selector | 否 | probe_error / ConnectError | probe_error / ConnectError |
| 热播之家 / anime | animeko-web-selector | 否 | challenge_client_required / HTTP200 | challenge_client_required / HTTP200 |
| 番茄动漫 / anime | animeko-web-selector | 否 | 0 / 2 / 0 | 0 / 2 / 0 |
| 稀饭动漫 / anime | animeko-web-selector | 否 | 2 / 0 / 0 | 2 / 0 / 0 |
| 第一动漫 / anime | animeko-web-selector | 否 | probe_error / ConnectError | probe_error / ConnectError |
| 米粒动漫 / anime | animeko-web-selector | 否 | episodes_ok_client_runtime_or_adapter_required / HTTP200 | episodes_ok_client_runtime_or_adapter_required / HTTP200 |
| 萌道动漫 / anime | animeko-web-selector | 否 | probe_error / RemoteProtocolError | probe_error / RemoteProtocolError |
| 虾皮动漫 / anime | animeko-web-selector | 否 | probe_error / ConnectError | probe_error / ConnectError |
| 蜜桃动漫 / anime | animeko-web-selector | 否 | probe_error / ConnectError | probe_error / ConnectError |
| 趣动漫 / anime | animeko-web-selector | 否 | search_miss_or_selector_drift / HTTP200 | search_miss_or_selector_drift / HTTP200 |
| 风车动漫 / anime | animeko-web-selector | 否 | probe_error / ConnectError | probe_error / ConnectError |
| 风车影视 / anime | animeko-web-selector | 否 | probe_error / RemoteProtocolError | probe_error / RemoteProtocolError |
| 饭团动漫 / anime | animeko-web-selector | 否 | http_error / HTTP403 | 2 / 0 / 0 |

## 附录C：证据与复现边界
- 机器可读证据：`E:/anime/docs/research/playback-source-audit-2026-09-29.json`；包含两地完整逐线路状态、首轮/复测时间与配置快照哈希、64规则及补核。
- 仓库研究：`E:/anime/docs/research/source-repository-discovery-2026-09-29.md`；作者仓库、精确SHA、许可/归档/提交证据分开记录。
- 本次临时复现脚本及脱敏输入：`E:/anime/.codex_tmp/source-audit-20260929/`。线上仅使用 `/tmp/zeluna-source-audit-20260929/`，不会自动定时运行。
- 现有探测入口：`E:/anime/server/tools/probe_all_routes.py`；参数 `--include-candidates --concurrency 3 --media-concurrency 3`；复测并发降为2。
- AWS核算参考来自官方 EC2 On-Demand pricing 与 Burstable performance instances 文档；经用户默认You.com MCP核实。web.run本次返回空结果，不将其当成功检索或虚构引用。
