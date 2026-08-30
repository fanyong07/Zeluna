import 'dart:convert';

const gaoFanSpiderMd5 = '6c4ab3a9d232164c75534f9060506ee5';
const qistCustomSpiderMd5 = '41c87635d7592069884a5dafa12acabe';

const _gaoPinnedBase =
    'https://raw.githubusercontent.com/gaotianliuyun/gao/'
    '8213bb046f4dce746b5f2ddcddb13a336d0b0d60/';
const _qistPinnedBase =
    'https://raw.githubusercontent.com/qist/tvbox/'
    'f1ec5de1cb89fc0accfa2998dc5eccd5892efb1c/';

const Map<String, Set<String>> auditedAndroidCspApisByMd5 = {
  gaoFanSpiderMd5: {
    'csp_AList',
    'csp_Alllive',
    'csp_Anime1',
    'csp_AppSx',
    'csp_AppTT',
    'csp_Auete',
    'csp_Bili',
    'csp_Bttwoo',
    'csp_Djtt',
    'csp_Dm84',
    'csp_DouDou',
    'csp_FirstAid',
    'csp_Jpys',
    'csp_kanqiu926',
    'csp_Kekys',
    'csp_KkSs',
    'csp_Libvio',
    'csp_LiteApple',
    'csp_MIPanSo',
    'csp_NanGua',
    'csp_NewCz',
    'csp_Nmyswv',
    'csp_PanSearch',
    'csp_PanSso',
    'csp_Push',
    'csp_SixV',
    'csp_WoGG',
    'csp_YGP',
    'csp_YiSo',
    'csp_Ysj',
    'csp_Zxzj',
  },
  qistCustomSpiderMd5: {
    'csp_AList',
    'csp_Bili',
    'csp_Dm84',
    'csp_Douban',
    'csp_Jianpian',
    'csp_JustLive',
    'csp_Kanqiu',
    'csp_Kugou',
    'csp_Local',
    'csp_Market',
    'csp_PanSearch',
    'csp_PanSou',
    'csp_Push',
    'csp_Star',
    'csp_UpYun',
    'csp_WebDAV',
    'csp_Wogg',
    'csp_Xb6v',
    'csp_XiaoZhiTiao',
    'csp_XPathMacFilter',
    'csp_YiSo',
    'csp_Ysj',
    'csp_Zhaozy',
  },
};

bool isAndroidCspApi(String api) {
  final normalized = api.trim().toLowerCase();
  return normalized.startsWith('csp_') &&
      normalized != 'csp_xbpq' &&
      normalized != 'csp_drpy';
}

String? androidCspSpiderMd5(Map<String, dynamic> rawConfig) {
  for (final key in const ['spider', 'jar', 'jars']) {
    final result = _extractMd5(rawConfig[key]);
    if (result != null) return result;
  }
  return null;
}

String androidCspApi(Map<String, dynamic> rawConfig, {String fallback = ''}) {
  final site = rawConfig['site'];
  if (site is Map) {
    final value = site['api']?.toString().trim() ?? '';
    if (value.isNotEmpty) return value;
  }
  return fallback.trim();
}

bool isAuditedAndroidCspConfig(
  Map<String, dynamic> rawConfig, {
  String fallbackApi = '',
}) {
  final md5 = androidCspSpiderMd5(rawConfig);
  if (md5 == null) return false;
  final api = androidCspApi(rawConfig, fallback: fallbackApi);
  return auditedAndroidCspApisByMd5[md5]?.contains(api) ?? false;
}

String? androidCspUnsupportedReason(
  Map<String, dynamic> rawConfig, {
  String fallbackApi = '',
}) {
  final md5 = androidCspSpiderMd5(rawConfig);
  if (md5 == null || !auditedAndroidCspApisByMd5.containsKey(md5)) {
    return '规则已保留，但它依赖的组件未通过安全校验。';
  }
  final api = androidCspApi(rawConfig, fallback: fallbackApi);
  if (!(auditedAndroidCspApisByMd5[md5]?.contains(api) ?? false)) {
    return '规则已保留，但缺少可用的解析组件。';
  }
  return null;
}

String androidCspSiteKey(Map<String, dynamic> rawConfig, String fallback) {
  final site = rawConfig['site'];
  if (site is Map) {
    final key = site['key']?.toString().trim() ?? '';
    if (key.isNotEmpty) return key;
  }
  return fallback.trim();
}

String androidCspEncodedExt(Map<String, dynamic> rawConfig) {
  final md5 = androidCspSpiderMd5(rawConfig);
  final site = rawConfig['site'];
  final ext = site is Map ? site['ext'] : null;
  if (ext == null) return '';
  final resolved = _resolveExtValue(ext, md5);
  return resolved is String ? resolved : jsonEncode(resolved);
}

List<String> androidCspVipFlags(Map<String, dynamic> rawConfig) {
  final value = rawConfig['flags'];
  if (value is! List) return const [];
  return value
      .map((item) => item?.toString().trim() ?? '')
      .where((item) => item.isNotEmpty)
      .toList(growable: false);
}

String androidCspPinnedBase(String spiderMd5) => switch (spiderMd5) {
  gaoFanSpiderMd5 => _gaoPinnedBase,
  qistCustomSpiderMd5 => _qistPinnedBase,
  _ => '',
};

String? _extractMd5(Object? value) {
  if (value is String) {
    final match = RegExp(
      r'(?:^|;)md5;([0-9a-fA-F]{32})(?:;|$)',
    ).firstMatch(value.trim());
    return match?.group(1)?.toLowerCase();
  }
  if (value is List) {
    for (final item in value) {
      final result = _extractMd5(item);
      if (result != null) return result;
    }
  }
  if (value is Map) {
    for (final item in value.values) {
      final result = _extractMd5(item);
      if (result != null) return result;
    }
  }
  return null;
}

Object? _resolveExtValue(Object? value, String? spiderMd5) {
  if (value is String) return _resolveExtReference(value, spiderMd5);
  if (value is List) {
    return value.map((item) => _resolveExtValue(item, spiderMd5)).toList();
  }
  if (value is Map) {
    return {
      for (final entry in value.entries)
        entry.key.toString(): _resolveExtValue(entry.value, spiderMd5),
    };
  }
  return value;
}

String _resolveExtReference(String value, String? spiderMd5) {
  final text = value.trim();
  if (spiderMd5 == null || (!text.startsWith('./') && !text.startsWith('/'))) {
    return value;
  }
  final base = androidCspPinnedBase(spiderMd5);
  if (base.isEmpty) return value;
  return Uri.parse(base).resolve(text).toString();
}
