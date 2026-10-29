# 播放实现参考核验（2026-10-30）

## 取证范围

通过官方 GitHub API 固定提交、读取真实源码。不运行第三方脚本，不引入第三方播放器代码；源码缓存留在被忽略的 `.codex_tmp/playback-refactor-20261030/references`。

| 项目 | 读取的提交 | 许可边界 |
| --- | --- | --- |
| Sle2p/AniCh | c5729a28af239aec78c7059ad122ff00f3f7c47a | API 无许可证信息，不推定有复制授权 |
| Predidit/Kazumi | 87543b51fa0341299a235c47cf5c0c4bfef29818 | GPL-3.0；只借鉴设计，不复制源码 |
| bloc97/Anime4K | 7684e9586f8dcc738af08a1cdceb024cc184f426 | MIT；本轮不更换已有着色器 |

这些是本轮读取快照，不代表后续永远最新。

## AniCh

读取 `lib/src/pages/bangumi_vod/controller.dart`、`lib/src/apis/bangumi.dart`、`lib/src/widgets/player/controller.dart`。

`getPlayUrl` 从指定条目/集数后端取得线路集合；`setPlayer` 将选中地址交给 media_kit。当前快照在该方法使用空 headers，不代表所有上游无需反盗链头。公开客户端不提供完整服务端查源实现，不能因此把对方私有服务当作本项目后端。借鉴点是线路提供者与本机播放器分工，不复制私有接口和编码算法。

源码：https://github.com/Sle2p/AniCh/tree/c5729a28af239aec78c7059ad122ff00f3f7c47a/lib/src

## Kazumi

读取：
- `lib/services/video_source/webview_video_source_service.dart`
- `lib/services/video_source/video_source_resolver_pool.dart`
- `lib/webview/video/impl/video_webview_android_impl.dart`
- `lib/pages/player/controller/player_playback_controller.dart`

确认的设计：解析与播放分离；一个 WebView 实例的任务串行且可取消；Android 观察网页实际网络/视频行为，而不是只匹配初始 HTML；任务结束卸载页面；播放器打开携带调用方 headers，并在异步步骤后检查当前 player 所有权。存在格式提示、解码配置和缓存策略。

注意：此快照使用 `enableAndroidSurfaceProducer`，Zeluna 锁定的 media_kit_video 2.0.1 没有该参数。不能机械复制或为套参数盲升依赖。

Zeluna 独立实现受权限约束的统一网页解析入口和原生 openRequest，保留暂停/取消意图、信任边界，不绕过 CAPTCHA。

源码：https://github.com/Predidit/Kazumi/tree/87543b51fa0341299a235c47cf5c0c4bfef29818/lib

## Anime4K

读取 README 与 LICENSE。其作用是实时画质处理/着色器，不负责来源搜索、网络代理或媒体解码。没有视频帧时，超分无法修复地址缺失、HTTP 403、TLS 或解码问题。本轮不以改画质算法冒充播放修复。

源码：https://github.com/bloc97/Anime4K/tree/7684e9586f8dcc738af08a1cdceb024cc184f426

## 验证边界

参考项目能运行不等于本项目所有库存源可播。地域限制、手机网络、硬件解码与画面输出仍需目标设备证据。HTTP、模拟器、时间轴进度不是用户手机修复证明。
