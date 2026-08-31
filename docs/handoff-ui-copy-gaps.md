# 交接：UI 文案审查的方法论缺口

写给下一个会话。**上一轮改了 200 多条文案并声称「零残留」，那个结论是错的** —— 它只意味着「我词表里的词没有残留」。用户上手一试就发现四个问题，其中一个直接证明了方法本身有洞。

## 已知的四个问题（都未修复）

上一轮的范围是 Anime4K 重构 + UI 文案，这四条都不在范围内，属于片源聚合层。

### 1 · 界面显示 `在线服务 · anich`

**这条最要紧，因为它证明了方法论缺口。**

`anich` 这个小写显示名**在 `lib/` 下根本不存在**。全库大小写不敏感搜索只有 4 处匹配，全都不上屏：

- `zeluna_backend_playback_repository.dart:226` / `:442` — 函数名 `_decodeAniChUrl`
- `anime4k_shader_manager.dart:10` / `:64` — 上一轮我自己写的代码注释

真正的来源在 `zeluna_backend_playback_repository.dart:342`：

```dart
providerName: serverProviderName.isNotEmpty
    ? serverProviderName          // ← 后端下发，客户端不参与
    : tag.isNotEmpty
    ? tag
    : _providerName(source),
```

`在线服务 · ` 这个前缀来自同文件 `:570` 的 `_providerName()`，但 `anich` 是后端 JSON 里的值。

所以：**搜源码字面量的方法对后端下发的显示名完全无效**。要修得在客户端加一层显示名映射（后端值 → 用户可见名），或者改后端。用户明确要求过界面不出现这个名字。

### 2 · 所有 anich 线路被折叠成一条

用户要求「全部线路都显示出来」。截图里 anich 只出现 1 条，而实际该源有几十条线路。当前是按 provider 聚合去重后只留一条，需要改成逐条展开。相关逻辑在 `zeluna_backend_playback_repository.dart` 的 `lines.add(...)` 附近和 `playback_line_display.dart` 的排序/分组。

### 3 · 27 条其它来源几乎全是「未找到匹配」/「不是这部作品」

截图里第 2–14 条全部失败，只有第 1 条能播。这是**匹配层**的问题（标题别名、集数编号对不上），不是文案问题。注意「不是这部作品」和「未找到匹配」这两个词是上一轮我改的（原文是「匹配不足」和「未找到匹配」），措辞本身没问题，暴露的是底下匹配率太低。

### 4 · 全屏播放器进度条异常

截图里进度条只画到约 1/8 处，而时间是 `2:38 / 23:45`（约 11%）—— 比例大致对得上，但进度条右侧有一段明显的浅色区域延伸到屏幕中部，看着像缓冲条渲染错位。另外右下角「退出全屏」按钮浮在进度条上方，位置也不对。相关文件 `player_page.dart`、`player_canvas.dart`、`player_panels.dart`。

## 方法论缺口（这是重点）

上一轮用了两种方法，各有盲区：

| 方法 | 抓到什么 | 抓不到什么 |
|---|---|---|
| 关键词扫描（对着术语表 grep） | B 类约 20 条 | **A 类 0 条**。词表外的词全漏 —— 「在浩瀚的星海之中」「待补」「待配置」谁也列不进词表 |
| 逐行通读（5 个 UI 区域，subagent） | A 类 55 条、B 类 165 条 | 后端下发的值；data 层三个大文件只做了定向核查 |

两种方法**都是在看源码里的字符串字面量**。共同盲区：

1. **后端下发的显示名** —— provider 名、来源标签、线路标题、quality 字段。源码里只有占位符。`anich` 就是这类。
2. **未逐行读的 data 层** —— `external_service_repository.dart`(1840)、`anime_controller.dart`(2544)、`bangumi_metadata_repository.dart`(1572)。这个缺口上一轮报告里标过，没补。而 provider 显示名、来源标签最可能就在这里。
3. **大小写与变体** —— 我搜 `AniCh` 时用的是精确大小写，没覆盖 `anich`。虽然这次证明小写在源码里不存在，但这个疏漏本身说明扫描不严谨。

## 建议的做法

不要再搜「已知的坏词」。反向追踪**所有会上屏的值**：

- Widget 参数：`text:` / `label:` / `title:` / `subtitle:` / `tooltip:` / `hintText:` / `message:`
- 进入这些字段的模型值：`PlaybackLine.providerName` / `.title` / `.format` / `.message`、`AnimeSubject.platform` / `.status`
- 每个值往上追到源头，判断它是客户端常量、后端下发、还是上游 API 原样透传

后端下发的那批需要在客户端加显示名映射层 —— 这也是唯一能保证「界面不出现内部代号」的做法，因为后端返回什么客户端控制不了。

## 上一轮做对的部分（可以信）

这些有测试锁住、构建验证过，不用重做：

- Anime4K 四档 × 六模式，链逐条对上上游模板（`test/anime4k_shader_manager_test.dart`）
- 解析器消息经 `playbackLineFailureLabel` 净化（三个上屏点都接了）
- `_friendlyError` / `_shortError` 不再插值 `error.toString()`
- 占位符改用 `isMetadataPlaceholder()`（`test/chinese_metadata_repository_test.dart`）
- 删掉的假 UI：伪造评分分布、`_StaticFilterRail`、`_SearchRightRail`、写死的「刚刚」
- 修掉的显示错误：追番进度读第一集、纯元数据源标「在线可播」、英文状态值上屏、搜索框承诺演员搜索

明细在 `docs/ui-copy-audit.md` 和 `docs/ui-copy-audit-rules.md`。那两份文件里的「实际改动纪要」记了偏离原建议的地方及原因。

## 当前状态

- HEAD `e42dd0c`，版本 `1.1.0+54`，已推 `claude/anime-source-layer`
- 795 个测试通过，`flutter analyze` 零问题，`dart format` 干净
- GitHub Releases 有 v1.1.0（6 个附件）和 v1.0.12（4 个附件），本地旧产物已清理
- `release/Zeluna-v1.1.0-Windows` 是个残缺目录，被进程占用删不掉，内容与 `.zip` 重复，可以直接删
- `release/archive/` 596 MB 未动（含 `prelicense` 基线，等用户确认）
- `build/` 5.66 GB 未清（`flutter clean` 即可）
