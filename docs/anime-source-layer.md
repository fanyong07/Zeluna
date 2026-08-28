# 动漫直连源层

> 更新:2026-08-28

自建动漫取流的源层结构、站点判定口径与日常维护流程。影视剧仍由
`server/server/scrapers/maccms_sites.py`(18 站全品类)承担,本文只讲动漫直连站。

## 1. 分层

```
catalog(Bangumi/TMDB)         作品 / 剧集 / 集号
        ↓
anime_sites.py                站点清单:形态、状态、域名族
        ↓
domain_watch.py               域名体检与族内轮换(这类站换域极勤)
        ↓
site_index.py                 列表页 → title→sid 本地索引(搜索被挡时的入口)
        ↓
site_base.py + 各站 scraper   详情 → 播放页 → 解码 → 多线路冗余
        ↓
aggregator / playback         匹配打分 → 逐条验活 → 缓存 → 下发
        ↓
hls_clean.py(可选)           清单文本重写,剔除广告分片
```

## 2. 站点状态三值

`anime_sites.py` 的每一行都带 `status`,这个口径回答的是**"该改代码还是该等"**:

| 状态 | 含义 | 处置 |
|---|---|---|
| `ok` | 搜索/详情/播放/取流全通 | 注册进 aggregator,可服务用户 |
| `parsed-dead` | 解析链路通,但上游 CDN 已无货 | **保留解析器不删**,不注册;货源恢复只需改 status |
| `dead` | 拿不到 sid,或详情页无已知播放形态 | 不写解析器,只留记录与线索 |

区分 `parsed-dead` 与 `dead` 很重要:前者是别人的货源问题(等或换源),
后者是我们的适配问题(要写代码)。混为一谈会浪费大量精力在错误方向上。

当前(2026-08-28 实测):

- `ok`:`yhdmm`(8 线路)、`girigiri`(4 线路)
- `parsed-dead`:`yhdm365`(403 防盗链)、`dmttang`、`yhdmfan`、`yhnime`、`yinghuadh`(播放页多为正版站外链)
- `dead`:`yhdmone`、`yhdminfo`(详情页无播放形态)、`yhdmp`(js-gate 弃用域)

## 3. 验站必须用真实作品名

**用首页随机 sid 验站会把活站误判成死站。** 2026-08-28 首轮用随机 sid 时
`yhdmm` 取流 3/3 全 404;换成真实番剧名后 4/4 可播,再用工具复验拿到 8 条线路。
随机 sid 常指向没有片源的条目(下架、占位、预告),得到的 404 与"站点已死"
无法区分。

```powershell
cd server
python tools/site_discovery.py verify-chain --site yhdmm --title 死神 --episode 1
```

## 4. 域名轮换

同一品牌在用域名可以有十来个,旧域会变成落地页、JS 跳转告别页或直接失效。
`domain_watch.py` 把域名判成五类:

| 判定 | 特征 | 含义 |
|---|---|---|
| `content` | 首页含已知内容形态 | 可用 |
| `landing` | 体量够大但无内容形态 | 落地页,内容常在兄弟域/子域 |
| `js-gate` | ~4.7KB 且含 redirecting | **弃用域的告别页**,不是反爬门 |
| `empty` | 响应过小或 4xx 短体 | 疑似已迁移 |
| `dead` | 连接层失败 | 连不上 |

两条经验:

1. **遇到 "Redirecting…" 先搜同族新域**,不要急着上 headless 浏览器——
   成本差两个数量级,而且那通常只是弃用域的告别页;
2. **别拿主域的结果给站点判决**。内容常在 `anime.`/`ani.`/`m.` 子域;
   `resolve()` 遇落地页会自动抽取页面里的兄弟域逐个试。

`CONTENT_MARKS` 这张形态表是人工维护的,表越窄越容易把用新 URL 形态的活站
误判成 `landing`。因此域名判定只作候选线索,**不足以单独作为下线依据**。

```powershell
python tools/site_discovery.py audit                    # 全表体检
python tools/site_discovery.py audit --output audit.json
```

## 5. 搜索被挡时走本地索引

部分站的站内搜索不可用,但不是"没有搜索能力":

- **边缘缓存按路径缓存**:换关键词永远返回同一页(实测某站两个关键词返回
  长度恒为 67850B),请求根本到不了搜索逻辑,加 `no-cache` 无效;
- **首次搜索即弹验证码**,而浏览列表页完全不拦。

绕行办法是抓列表页建 `title → sid` 本地索引,之后搜索是纯本地操作:
零风控、零延迟、不受对方搜索改版影响。代价是覆盖率取决于抓了多少页,
通常只够近期作品。

⚠️ 有些站**分页也被缓存**(第 2 页起内容重复),`build_index` 检测到重复页
即提前停止。

⚠️ 这类"假成功"极具误导性:第一次搜的词恰好命中缓存内容时看起来一切正常。
所以 `yhdmm.search()` 会校验结果与关键词的相关性,宁可返回空,也不把无关
作品当匹配结果喂给上层。

## 6. 站点级 Cookie(可选)

有些站只在首次搜索时弹验证码,人过一次后 session 长期有效。本项目
**不去绕验证码**,而是允许运维把自己的 Cookie 交给程序复用:

```powershell
$env:SCRAPER_COOKIE_GIRIGIRI = "PHPSESSID=你的值"
```

命名规则:`SCRAPER_COOKIE_` + 站名大写去掉非字母数字。没有 Cookie 时自动
退回本地索引,不中断流水线。

## 7. 广告剪裁

采集站的 m3u8 常插贴片广告。`hls_clean.py` 做两级剪裁:

- **组级**:以 `#EXT-X-DISCONTINUITY` 切组,整组符合"短分片簇 / 首尾小簇 /
  异域分片"即丢;
- **条目级**:仅当**连续 ≥2 条**短分片成簇才丢。孤立短分片多为正常收尾或
  换轨,宁可漏剪也不误删正片。

必守约束(写错会完全无法播放):`#EXT-X-KEY` 必须保留且 URI 转绝对(含段间
KEY 轮换)、`#EXT-X-ENDLIST` 只能在所有媒体段之后、主清单先选 variant。
mp4 等整包源无法按分片剪,只能换线。

**落地形态:即时重写不落盘。** `GET /api/v3/playlist/{token}` 拉取源清单、
内存中重写、返回文本;分片地址仍指向源站 CDN。清单是文本不是媒体,
server 不代理媒体字节、不写磁盘。

安全约束:该端点**只接受服务端签发的 token**(HMAC-SHA256,复用 `SECRET_KEY`),
不接受任何裸 URL 参数——否则它就成了开放代理与 SSRF 跳板。目标还要经
`_is_public_http_url` 复核;剪裁失败返回 502,由客户端回退原直链。

## 8. 高画质档清单

见到带"官方/简中/1080P/4K"等标注的线路时,`premium_line_catalog` 表登记
一条**元数据**记录:作品、集数、画质标注、来源标识、媒体主机、路径摘要
(sha256 前 16 位)。

**刻意不存完整地址**:这类直链天数级失效,存了也用不了,还扩大暴露面。
清单的用途是回答"这一集见过哪些画质档、来自哪个来源",实际取流仍须现场解析。
表中永远不含媒体字节。

```powershell
python tools/export_premium_catalog.py --format table
python tools/export_premium_catalog.py --format csv --output premium.csv
```

## 9. 新增一个站

1. 用外部搜索找候选域(工具不内置搜索凭据,凭据属部署者环境);
2. `site_discovery.py check-candidates --input candidates.json` 体检,
   只有 `content` 档值得继续;
3. `site_discovery.py verify-chain --site X --title <真实作品名>` 验全链;
4. 按判定结果写 `anime_sites.py`:`ok` 才写解析器并注册进 `aggregator.py`
   的 crawler 字典,`parsed-dead` 写解析器但不注册,`dead` 只留记录;
5. 解析器继承 `SiteAnimeScraper`,通常只需声明形态(`detail_template` /
   `play_link_patterns` / `list_paths`),复用基类的冗余选集与两级解码;
6. 配一个 `tests/test_<site>.py`(MockTransport + canned HTML)。

## 10. 运维红线

- 节流内置(每请求约 1s,429/503 退避);**别并发轰站点**;
- 采集站直链天数级失效,**不要长缓存,播放前现解析**;
- 站点改版会破解析规则 —— 这是自建源的主要维护成本;
- 广告识别是启发式,存在误报漏报;宁可漏剪也不误删正片;
- **不降低 TLS 校验**:外部参考实现为迁就"证书不规范的采集站"关掉了证书
  校验,本项目不采纳——降低全局安全基线换取个别站点可达并不值得;
- 仅限个人研究与互操作,勿对外提供二次分发服务。
