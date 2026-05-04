import 'rule_models.dart';

class RulePluginRepository {
  const RulePluginRepository();

  List<RulePlugin> get allRules => _curatedRules;

  List<RulePlugin> rulesFor(RuleContentType type) {
    return _curatedRules
        .where((rule) => rule.contentType == type)
        .toList(growable: false);
  }

  List<RulePlugin> installedRules(RulePluginState state) {
    return _curatedRules
        .where((rule) => state.installedIds.contains(rule.id))
        .toList(growable: false);
  }

  List<RulePlugin> enabledRulesFor(
    RulePluginState state,
    RuleContentType type,
  ) {
    return _curatedRules
        .where(
          (rule) =>
              rule.contentType == type &&
              state.installedIds.contains(rule.id) &&
              state.enabledIds.contains(rule.id),
        )
        .toList(growable: false);
  }

  RulePluginState defaultState() {
    final installed = {
      for (final rule in _curatedRules)
        if (rule.installedByDefault) rule.id,
    };
    return RulePluginState(installedIds: installed, enabledIds: installed);
  }

  RulePlugin? byId(String id) {
    for (final rule in _curatedRules) {
      if (rule.id == id) return rule;
    }
    return null;
  }
}

DateTime _date(
  int year,
  int month,
  int day, [
  int hour = 0,
  int minute = 0,
  int second = 0,
]) {
  return DateTime(year, month, day, hour, minute, second);
}

const _native = 'native';
const _xbpq = 'XBPQ';
const _xyq = 'XYQHiker';
const _drpy = 'drpy-js';

final _curatedRules = <RulePlugin>[
  RulePlugin(
    id: 'kazumi:omofun03',
    name: 'omofun03',
    version: '1.1',
    source: RuleSourceKind.kazumi,
    contentType: RuleContentType.anime,
    engine: _native,
    updatedAt: _date(2026, 4, 26, 13, 1, 23),
    qualityScore: 96,
    tags: const ['native', '多线路', '番剧'],
    baseUrl: 'https://omofun03.top/',
    searchUrl: 'https://omofun03.top/vod/search.html?wd=@keyword',
    searchable: true,
    quickSearch: true,
    filterable: true,
    requiresWebView: true,
    installedByDefault: true,
    note: 'KazumiRules 中更新时间最新，字段完整，支持多线路和原生播放。',
  ),
  RulePlugin(
    id: 'kazumi:enlie',
    name: 'enlie',
    version: '1.0',
    source: RuleSourceKind.kazumi,
    contentType: RuleContentType.anime,
    engine: _native,
    updatedAt: _date(2026, 3, 11, 12, 26, 14),
    qualityScore: 90,
    tags: const ['native', '番剧'],
    baseUrl: 'https://enlienli.link/',
    searchUrl: 'https://enlienli.link/vod/search.html?wd=@keyword',
    searchable: true,
    quickSearch: true,
    filterable: true,
    installedByDefault: false,
    note: '规则较新且不依赖验证码，适合作为番剧备用源。',
  ),
  RulePlugin(
    id: 'kazumi:xfdmneo',
    name: 'xfdmneo',
    version: '1.1',
    source: RuleSourceKind.kazumi,
    contentType: RuleContentType.anime,
    engine: _native,
    updatedAt: _date(2026, 3, 8, 18, 0, 2),
    qualityScore: 88,
    tags: const ['native', '番剧'],
    baseUrl: 'https://dm1.xfdm.pro/',
    searchUrl: 'https://dm1.xfdm.pro/search.html?wd=@keyword',
    searchable: true,
    quickSearch: true,
    filterable: true,
    installedByDefault: false,
    note: '字段完整，更新时间靠前，作为无验证码备用规则保留。',
  ),
  RulePlugin(
    id: 'kazumi:lmm',
    name: 'LMM',
    version: '2.0',
    source: RuleSourceKind.kazumi,
    contentType: RuleContentType.anime,
    engine: _native,
    updatedAt: _date(2026, 3, 7, 17, 42, 43),
    qualityScore: 82,
    tags: const ['native', 'captcha', '多线路'],
    baseUrl: 'https://www.lmm85.com/',
    searchUrl: 'https://www.lmm85.com/vod/search.html?wd=@keyword',
    searchable: true,
    quickSearch: true,
    filterable: true,
    requiresWebView: true,
    requiresCaptcha: true,
    installedByDefault: true,
    note: '规则完整但带验证码，安装后作为手动备用源使用。',
  ),
  RulePlugin(
    id: 'kazumi:girigirilove',
    name: 'giriGiriLove',
    version: '2.1',
    source: RuleSourceKind.kazumi,
    contentType: RuleContentType.anime,
    engine: _native,
    updatedAt: _date(2026, 3, 7, 17, 32, 31),
    qualityScore: 81,
    tags: const ['native', 'captcha', '多线路'],
    baseUrl: 'https://anime.girigirilove.top',
    searchUrl:
        'https://anime.girigirilove.top/search/-------------/?wd=@keyword',
    searchable: true,
    quickSearch: true,
    filterable: true,
    requiresWebView: true,
    requiresCaptcha: true,
    installedByDefault: true,
    note: '字段完整但启用反爬验证，保留为可安装番剧规则。',
  ),
  RulePlugin(
    id: 'kazumi:xfdm',
    name: 'xfdm',
    version: '2.0',
    source: RuleSourceKind.kazumi,
    contentType: RuleContentType.anime,
    engine: _native,
    updatedAt: _date(2026, 3, 7, 17, 5, 45),
    qualityScore: 80,
    tags: const ['native', 'captcha'],
    baseUrl: 'https://dm.xifanacg.com/',
    searchUrl: 'https://dm.xifanacg.com/search.html?wd=@keyword',
    searchable: true,
    quickSearch: true,
    filterable: true,
    requiresWebView: true,
    requiresCaptcha: true,
    installedByDefault: true,
    note: 'KazumiRules 已列入索引，作为番剧规则的兜底线路。',
  ),
  RulePlugin(
    id: 'kazumi:mxdp',
    name: 'MXdm',
    version: '2.3',
    source: RuleSourceKind.kazumi,
    contentType: RuleContentType.anime,
    engine: _native,
    updatedAt: _date(2026, 2, 24, 21, 15, 41),
    qualityScore: 78,
    tags: const ['native', '番剧'],
    baseUrl: 'https://www.dcc3.com/',
    searchUrl: 'https://www.dcc3.com/search/?wd=@keyword',
    searchable: true,
    quickSearch: true,
    filterable: true,
    installedByDefault: false,
    note: '版本号较高，不带验证码，作为可安装备用规则。',
  ),
  RulePlugin(
    id: 'tvbox:hanjukankan',
    name: '韩剧看看',
    version: '1.0',
    source: RuleSourceKind.tvbox,
    contentType: RuleContentType.series,
    engine: _xbpq,
    updatedAt: _date(2026, 3, 7, 12, 0, 0),
    qualityScore: 94,
    tags: const ['XBPQ', '韩剧', '剧集'],
    baseUrl: 'https://www.hanjukankan.com/',
    searchUrl: 'https://www.hanjukankan.com/xvse{wd}abcdefghig{pg}klm.html',
    searchable: true,
    quickSearch: true,
    filterable: true,
    installedByDefault: true,
    note: '分类明确区分韩国剧集、韩国电影、韩国综艺，优先归入电视剧规则。',
  ),
  RulePlugin(
    id: 'tvbox:meijutt',
    name: '美剧天天',
    version: '1.0',
    source: RuleSourceKind.tvbox,
    contentType: RuleContentType.series,
    engine: 'csp',
    updatedAt: _date(2026, 3, 7, 12, 0, 0),
    qualityScore: 90,
    tags: const ['美剧', '剧集', '可搜索'],
    baseUrl: 'https://www.meijutt.net',
    searchUrl: '',
    searchable: true,
    quickSearch: true,
    filterable: true,
    installedByDefault: true,
    note: 'TVBox 配置中的美剧专用源，未携带私密授权信息。',
  ),
  RulePlugin(
    id: 'tvbox:ddys',
    name: '低端影视',
    version: '1.0',
    source: RuleSourceKind.tvbox,
    contentType: RuleContentType.series,
    engine: _drpy,
    updatedAt: _date(2026, 3, 7, 12, 0, 0),
    qualityScore: 86,
    tags: const ['drpy-js', '剧集', '电影'],
    baseUrl: 'https://ddys.pro',
    searchUrl: '',
    searchable: true,
    quickSearch: true,
    filterable: true,
    installedByDefault: false,
    note: '综合影视源，优先在电视剧频道使用，电影频道另配专用电影源。',
  ),
  RulePlugin(
    id: 'tvbox:dianyingxiansheng',
    name: '电影先生',
    version: '1.0',
    source: RuleSourceKind.tvbox,
    contentType: RuleContentType.movie,
    engine: _xbpq,
    updatedAt: _date(2026, 3, 7, 12, 0, 0),
    qualityScore: 94,
    tags: const ['XBPQ', '电影', '电视剧'],
    baseUrl: 'https://dianyi.ng',
    searchUrl: 'https://dianyi.ng/search--------------.html?wd={wd}',
    searchable: true,
    quickSearch: true,
    filterable: true,
    installedByDefault: true,
    note: '分类内含电影/电视剧/动漫/综艺，这里仅把电影规则归入电影频道。',
  ),
  RulePlugin(
    id: 'tvbox:dygang',
    name: '电影港',
    version: '1.0',
    source: RuleSourceKind.tvbox,
    contentType: RuleContentType.movie,
    engine: _xyq,
    updatedAt: _date(2026, 3, 7, 12, 0, 0),
    qualityScore: 92,
    tags: const ['XYQHiker', '电影', '磁力'],
    baseUrl: 'https://www.dygang.tv',
    searchUrl: 'https://www.dygang.tv/e/search/index123.php',
    searchable: true,
    quickSearch: true,
    filterable: true,
    installedByDefault: true,
    note: '电影分类完整，包含最新电影、经典高清、国配电影、4K 等频道。',
  ),
  RulePlugin(
    id: 'tvbox:new6v',
    name: '新6V',
    version: '1.0',
    source: RuleSourceKind.tvbox,
    contentType: RuleContentType.movie,
    engine: 'csp',
    updatedAt: _date(2026, 3, 7, 12, 0, 0),
    qualityScore: 88,
    tags: const ['电影', '可搜索'],
    baseUrl: 'https://www.66ss.org',
    searchUrl: '',
    searchable: true,
    quickSearch: true,
    filterable: true,
    installedByDefault: false,
    note: 'TVBox 中较常见的电影源，不需要本地授权信息。',
  ),
  RulePlugin(
    id: 'tvbox:kuba',
    name: '酷吧电影',
    version: '1.0',
    source: RuleSourceKind.tvbox,
    contentType: RuleContentType.movie,
    engine: 'csp',
    updatedAt: _date(2026, 3, 7, 12, 0, 0),
    qualityScore: 84,
    tags: const ['电影', '可搜索'],
    baseUrl: 'https://www.kubady2.com',
    searchUrl: '',
    searchable: true,
    quickSearch: true,
    filterable: true,
    installedByDefault: false,
    note: '电影向资源站，保留为可安装备用源。',
  ),
];
