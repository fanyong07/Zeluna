import 'rule_models.dart';
import 'rule_security.dart';

// Hand-authored adapters for public MacCMS APIs, not downloaded code or JARs.
// Only HTTP media readability is verified. Native stability is NOT accepted;
// these optional candidates must not join the default startup/source set.
// See docs/live-action-rule-validation-2026-10-06.md for limits and provenance.
final optionalLiveActionRules = <RulePlugin>[
  RulePlugin(
    id: 'zeluna:recommended:youzhi',
    name: '优质资源库',
    version: '2026-10-06',
    source: RuleSourceKind.tvbox,
    contentType: RuleContentType.movie,
    engine: 'tvbox-json-api',
    updatedAt: DateTime(2026, 10, 6),
    qualityScore: 60,
    tags: const ['电影', '电视剧', '可选', '待实播复核'],
    baseUrl: 'https://api.yzzy-api.com/inc/api_mac10.php',
    searchUrl: 'https://api.yzzy-api.com/inc/api_mac10.php',
    searchable: true,
    quickSearch: true,
    filterable: false,
    installedByDefault: false,
    priority: 180,
    rawConfig: const {'searchAction': 'list'},
    permissionManifest: const RulePermissionManifest.official(
      id: 'zeluna:recommended:youzhi',
      name: '优质资源库',
      version: '2026-10-06',
      engine: 'tvbox-json-api',
      contentTypes: ['movie', 'series'],
      pageDomains: ['api.yzzy-api.com'],
      mediaDomains: ['yzzy.play-cdn17.com', 'yzzy.play-cdn9.com'],
      customReferer: true,
    ),
    note: '公开电影及剧集媒体链已验证，但冷启动偏慢，Windows完整实播未通过；默认不启用。与部分聚合来源共用媒体服务。',
  ),
  RulePlugin(
    id: 'zeluna:recommended:sina',
    name: '新浪资源',
    version: '2026-10-06',
    source: RuleSourceKind.tvbox,
    contentType: RuleContentType.movie,
    engine: 'tvbox-json-api',
    updatedAt: DateTime(2026, 10, 6),
    qualityScore: 60,
    tags: const ['电影', '电视剧', '可选', '待实播复核'],
    baseUrl:
        'https://api.xinlangapi.com/xinlangapi.php/provide/vod/from/xlm3u8/',
    searchUrl:
        'https://api.xinlangapi.com/xinlangapi.php/provide/vod/from/xlm3u8/',
    searchable: true,
    quickSearch: true,
    filterable: false,
    installedByDefault: false,
    priority: 181,
    rawConfig: const {'searchAction': 'detail'},
    permissionManifest: const RulePermissionManifest.official(
      id: 'zeluna:recommended:sina',
      name: '新浪资源',
      version: '2026-10-06',
      engine: 'tvbox-json-api',
      contentTypes: ['movie', 'series'],
      pageDomains: ['api.xinlangapi.com'],
      mediaDomains: ['play.xluuss.com', 'g.xlzyd.com'],
      customReferer: true,
    ),
    note: '公开电影及剧集媒体链已验证，但Windows复测多次CDN超时，默认不启用。使用正常公开HLS播放密钥，不调用解析服务。',
  ),
];
