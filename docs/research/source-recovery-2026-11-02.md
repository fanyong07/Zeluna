# 未接入/停用来源修复与准入（2026-11-02）

## 背景和目标

此前118个后端登记项中93项不参与查询：80候选、5停用爬虫、3隔离源、5旧TVBox接口。用户明确要求修复可修复项、核实新域名并启用能用的来源。登记项不等于独立网站，HTTP200/搜索命中/媒体可读/安卓解码必须分别计数。

## 范围与边界

- 本轮只修改后端适配器、来源配置和相关测试；无需更换客户端APK。
- 不重写播放器、不加视频代理、不下载视频文件、不关TLS、不绕过站方搜索限制或白名单、不执行第三方脚本。
- 无可靠新域名或媒体仍失效的登记项保留；不是删除候选或宣称永久关停。
- 后端运行白名单只追加3项，保留已有全部提供方：`crawler.jibi`、`crawler.yinghua2`、`crawler.wedm`。wedm只有客户端候选证据。

## 实现

1. 新增共享JSON/XML解析器，搜索/详情/取集均走同一路径。XML详情使用videolist，禁止DTD、实体与外部网络解析，限制解析大小；HTML和错误JSON不再冒充空片库。
2. 旧TVBox适配器使用共享类型、年份和集数规则；数字/空年份不再使整批结果丢失；不再默认伪造2024；跳过SP/OVA，不以位置顶替缺集；保留不同来源相同标题。
3. 错误区分不支持搜索、DNS、TLS、连接超时、接口结构错误；日志不记录原始上游异常或完整媒体链接。
4. 6项候选明确转入正式来源表，原始候选行在本次审计证据保存；候选数80→74，总登记项仍118，不额外复制6项占位。
5. XML来源只从服务器解析；Android本地重查仍只发布JSON描述符，不能向旧客户端谎报XML为JSON。

## 准入配置

|来源|处理|调度|
|---|---|---|
|叽哔动漫 jibi|追加运行白名单|正常查源，逐条媒体仍须验证|
|樱花动漫 yinghua2|追加运行白名单并使用当前跳转域|正常查源，逐条媒体仍须验证|
|极速|解除旧隔离|core/quick，不预爬|
|金鹰资源|候选转正式，规范API路径|core/quick，不预爬|
|新浪资源|候选转正式，去掉旧josn路径|fallback，不抢首播、不预爬|
|HG资源|候选转正式|fallback，败犬无集不算成功、不预爬|
|U酷资源、非凡资源、1080zyk优质资源库|候选转正式但仅客户端候选|client_probe，不抢首播、不预爬|
|wedm|追加运行白名单|只取得客户端候选，不能宣称可播|

其它未过门槛来源仍不启用：706当前源站522；dbku不支持番剧、电影对照没有匹配；风车连接异常；暴风/旧量子媒体失效。旧TVBox组仍关闭，避免与现有MacCMS重复发请求；修复后的适配器保留供以后明确启用。

## 域名/接口核验

|来源|旧地址问题|已核验配置|
|---|---|---|
|樱花动漫|旧域每次301跳转|`https://www.yinghuabb.com/`，由旧www.yinghua2.com真实跳转确认|
|金鹰|多个同站路径并存|`https://jyzyapi.com/provide/vod`，完整搜索/详情/第1、3集/媒体检查|
|新浪|旧路径尾部josn|`https://api.xinlangapi.com/xinlangapi.php/provide/vod`，完整媒体检查|
|非凡|旧候选为明文HTTP|`https://api.ffzyapi.com/api.php/provide/vod`，HTTPS目录和候选媒体可获取|
|闪电|旧sdzyapi接口|`https://xsd.sdzyapi.com/api.php/provide/vod/from/sdm3u8/at/xml`，公开列表20项，关键词搜索关闭|
|快车|旧caiji.kczyapi.com证书错误|`https://caiji.kuaichezy.org/api.php/provide/vod`，公开列表20项，关键词搜索关闭|
|OK|旧域DNS失败|`https://api.okzyw.net/api.php/provide/vod`，公开列表20项，关键词搜索关闭|
|天涯|旧ty.tyyszy5.com|`https://tyyszyapi.com/api.php/provide/vod`，公开列表20项，关键词搜索关闭|
|索尼|旧通用接口不支持关键词搜索|站方指定`/from/snm3u8/at/xml`，公开列表20项，仍不支持搜索，继续候选|

新域名只有目录可读而没有样本播放证据时，不会自动晋级。索尼站方帮助页明确提及白名单及APP接口使用限制，不尝试规避；闪电站方提示欧美线路播放受限，不用海外机房结果代表国内手机。

站方核验页面（2026-11-02实时读取，不以搜索摘要代替实测）：
- https://shandianzy.com/
- https://suonizy.net/help/
- https://www.kuaichezy.com/
- https://www.wolongzyw.com/index.php/label/help1.html

公开配置仅作为发现线索：lkj5209/moontv-config、DaLongZhuaZi/moontv-config及原候选引用仓库。共提取25个已有来源的48个当前/替代接口并在LA隔离进程实测，未执行仓库脚本；站名相近但未证明属于同站的新地址不自动替换。

## 关键实测与限制

修复后的10项准入预检覆盖《败犬》2024年第1/3集、《葬送的芙莉莲》2023年第1/3集和《流浪地球》2019：共90条返回线路，29条服务器通过、38条客户端待验证、23条失败。部分源同一轮仍会超时，不能把一次通过称为稳定无故障；快路径仍须验证和候补。

- jibi：败犬女主太多了！: server_verified=5/unavailable=1；葬送的芙莉莲: client_probe_required=2/server_verified=3/unavailable=1；流浪地球: no_accepted_match。
- yinghua2：败犬女主太多了！: server_verified=5/unavailable=1；葬送的芙莉莲: no_accepted_match；流浪地球: no_accepted_match。
- wedm：败犬女主太多了！: client_probe_required=2；葬送的芙莉莲: client_probe_required=4；流浪地球: no_accepted_match。
- 极速：败犬女主太多了！: unavailable=2/server_verified=2；葬送的芙莉莲: unavailable=2/server_verified=2；流浪地球: unavailable=1/server_verified=1。
- 金鹰资源：败犬女主太多了！: unavailable=3/server_verified=1；葬送的芙莉莲: unavailable=2/server_verified=2；流浪地球: server_verified=1/unavailable=1。
- 新浪资源：败犬女主太多了！: unavailable=2/server_verified=2；葬送的芙莉莲: unavailable=3/server_verified=1；流浪地球: server_verified=1/unavailable=1。
- HG资源：败犬女主太多了！: detail_or_episodes_missing；葬送的芙莉莲: client_probe_required=2/server_verified=2/unavailable=2；流浪地球: server_verified=1/client_probe_required=3/unavailable=1。
- U酷资源：败犬女主太多了！: client_probe_required=4；葬送的芙莉莲: client_probe_required=4；流浪地球: client_probe_required=2。
- 非凡资源：败犬女主太多了！: client_probe_required=4；葬送的芙莉莲: client_probe_required=4；流浪地球: client_probe_required=2。
- 1080zyk优质资源库：败犬女主太多了！: client_probe_required=2；葬送的芙莉莲: client_probe_required=2；流浪地球: client_probe_required=1。

## 部署/回滚约束

- 先通过本次精确文件快照的单元/接口测试、Ruff和真实查源预检，再修改服务器。
- 部署前核对目标文件仍等于起点HEAD；逐项备份本次改动和环境文件；新文件和所有写入限定在项目目录。
- 仅向原PLAYBACK_PROVIDER_IDS追加上述3个ID，其它环境配置保持字节一致，不触碰数据库和用户数据。
- 重启后验本地和公开HTTPS状态、白名单回读、准入项真实查源、原有提供方保留、无新启动异常。失败回滚代码和该字段。
- 发布APK/Release需要新版本、构建号与精确HEAD门禁；本次不更新或覆盖既有Release。

## 验收和待验证

1. 真实调用链回归应证明JSON/XML均能搜索、读详情和定位正确集数；恶意XML不能读取文件/外部资源。
2. 总登记项118，候选74；XML不伪装成Android JSON本地重查；四项客户端候选不得标为服务器通过。
3. 公开服务可用、启用配置可回读；生产部署收据与每文件SHA独立保存。
4. 未连接用户无VPN安卓手机；首帧、90秒持续播放、跨网络稳定性仍未验证，本记录不宣称手机已修好。
5. 其它候选中的DNS失败/停搜/证书/受限/失效媒体不能由本项目单方面修复，没有可靠证据的新域名保持未确认。


## 线上复测发现的完整缓存阻塞（追加修复）

首轮部署后，实际《败犬》请求虽能返回恢复来源，但反复等待完整扫描。完整响应中PPnix为`not_queried`，而其能力仅为电视剧/电影，动漫查询本就不适用。缓存正确地拒绝了“未查完”的结果，却因此永远不能复用本轮有效动漫线路。

新增`unsupported_content_type`终态：不支持该类型的爬虫/采集源仍保留在清单，但明确没有发送请求，不记搜索失败，不冒充查询过。真正的`not_queried`仍阻止完整缓存，空/失败结果的缓存策略不放宽。回归测试先复现该失败，再验证完成清单可缓存且真实漏查仍不缓存。此修复不改用户数据或客户端版本。
