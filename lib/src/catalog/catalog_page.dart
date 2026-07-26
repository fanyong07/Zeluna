import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app/anime_app.dart';
import '../data/anime_controller.dart';
import '../data/chinese_text.dart';
import '../domain/anime_models.dart';
import '../domain/subject_content_type.dart';
import '../shared_ui/app_chrome.dart';
import '../shared_ui/app_navigation.dart';
import '../shared_ui/poster_card.dart';
import '../sources/external_source_adapters.dart';
import 'subject_playability.dart';

const _internalMetadataProviderNames = <String>[
  'Internet Archive',
  'Archive.org',
  'Wikimedia Commons',
  'MyAnimeList',
  'Bangumi',
  'AniList',
  'Jikan',
  'Kitsu',
  'Cinemeta',
  'TVMaze',
  'Wikidata',
  'Wikimedia',
  'PeerTube',
  'Archive',
];

final _internalMetadataProviderPattern = RegExp(
  _internalMetadataProviderNames.map(RegExp.escape).join('|'),
  caseSensitive: false,
);

bool _isInternalMetadataLabel(String value) {
  return _internalMetadataProviderPattern.hasMatch(value.trim());
}

String _publicMetadataValue(String value, {String fallback = ''}) {
  final normalized = value.trim();
  if (normalized.isEmpty || _isInternalMetadataLabel(normalized)) {
    return fallback;
  }
  return normalized;
}

String _publicSummary(String value) {
  var normalized = value.trim();
  if (normalized.isEmpty) return '内容资料正在完善。';

  normalized = normalized
      .replaceAll(
        RegExp(
          '来自\\s*(?:${_internalMetadataProviderNames.map(RegExp.escape).join('|')})\\s*的',
          caseSensitive: false,
        ),
        '',
      )
      .replaceAll(_internalMetadataProviderPattern, '')
      .replaceAll(RegExp(r'\s*[/+|]\s*'), ' ')
      .replaceAll(RegExp(r'\s{2,}'), ' ')
      .replaceFirst(RegExp(r'^[\s、，。:：;；·-]+'), '')
      .trim();
  return normalized.isEmpty ? '内容资料正在完善。' : normalized;
}

bool _preferChineseMetadata(BuildContext context) {
  return ProviderScope.containerOf(
        context,
      ).read(animeControllerProvider).value?.services.preferBangumiChinese ??
      true;
}

AnimeSubject _publicSubjectMetadata(
  BuildContext context,
  AnimeSubject subject,
) {
  final contentType = subjectContentTypeOf(subject);
  final isAnime = contentType == SubjectContentType.anime;
  final preferChinese = _preferChineseMetadata(context);
  final platformFallback = switch (contentType) {
    SubjectContentType.anime => '番剧',
    SubjectContentType.series => '剧集',
    SubjectContentType.movie => '电影',
  };
  return AnimeSubject(
    id: subject.id,
    title: subject.title,
    originalTitle: subject.originalTitle,
    summary: preferChinese && isAnime && !isLikelyChineseText(subject.summary)
        ? '暂无中文简介。'
        : _publicSummary(subject.summary),
    coverUrl: subject.coverUrl,
    bannerUrl: subject.bannerUrl,
    date: subject.date,
    platform: _publicMetadataValue(
      subject.platform,
      fallback: platformFallback,
    ),
    language: subject.language,
    region: _publicMetadataValue(subject.region),
    status: _publicMetadataValue(subject.status),
    categories: subject.categories
        .where(
          (item) =>
              !_isInternalMetadataLabel(item.name) &&
              (!preferChinese || !isAnime || isLikelyChineseTitle(item.name)),
        )
        .toList(growable: false),
    tags: subject.tags
        .where(
          (item) =>
              !_isInternalMetadataLabel(item.name) &&
              (!preferChinese || !isAnime || isLikelyChineseTitle(item.name)),
        )
        .toList(growable: false),
    totalEpisodes: subject.totalEpisodes,
    ratingScore: subject.ratingScore,
    ratingRank: subject.ratingRank,
    ratingTotal: subject.ratingTotal,
    source: subject.source,
  );
}

class CatalogPage extends ConsumerStatefulWidget {
  const CatalogPage({super.key});

  @override
  ConsumerState<CatalogPage> createState() => _CatalogPageState();
}

class _CatalogPageState extends ConsumerState<CatalogPage> {
  AnimeHomeTab _tab = AnimeHomeTab.recommended;
  bool _showFilters = false;
  String _type = '全部';
  String _language = '全部';
  String _year = '全部';
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AsyncAnimeGate(
      builder: (context, state) {
        return AppChrome(
          active: _chromeDestination,
          searchController: _searchController,
          onSearch: _openSearch,
          trailing: _HomeToolbar(
            selected: _tab,
            onChanged: (tab) => setState(() => _tab = tab),
            onSchedule: () => context.push('/schedule'),
            onProfile: () => context.push('/profile'),
          ),
          rightRail: _HomeRightRail(
            feed: state.homeFeed,
            state: state,
            onOpen: _openDetail,
          ),
          bottomPlayer: _MiniNowPlaying(
            subject: state.homeFeed.hero,
            progress: _watchProgress(state.history),
          ),
          child: _body(state.homeFeed),
        );
      },
    );
  }

  ChromeDestination get _chromeDestination {
    return switch (_tab) {
      AnimeHomeTab.recent => ChromeDestination.home,
      AnimeHomeTab.recommended => ChromeDestination.home,
      AnimeHomeTab.browse => ChromeDestination.anime,
      AnimeHomeTab.category => ChromeDestination.series,
      AnimeHomeTab.tag => ChromeDestination.movie,
    };
  }

  double _watchProgress(List<LibraryEntry> history) {
    if (history.isEmpty) return 0.62;
    final latest = history.first.episode?.number ?? 1;
    final total = history.first.subject.totalEpisodes;
    if (total <= 0) return 0.35;
    return (latest / total).clamp(0.05, 1);
  }

  Widget _body(AnimeHomeFeed feed) {
    final compact = MediaQuery.sizeOf(context).width < 760;
    final content = switch (_tab) {
      AnimeHomeTab.recent => _RecentTab(
        subjects: feed.recent,
        onOpen: _openDetail,
      ),
      AnimeHomeTab.recommended => _RecommendTab(
        feed: feed,
        onOpen: _openDetail,
      ),
      AnimeHomeTab.browse => _IndexTab(
        subjects: feed.index,
        showFilters: _showFilters,
        type: _type,
        language: _language,
        year: _year,
        onToggleFilters: () => setState(() => _showFilters = !_showFilters),
        onTypeChanged: (value) => setState(() => _type = value),
        onLanguageChanged: (value) => setState(() => _language = value),
        onYearChanged: (value) => setState(() => _year = value),
        onOpen: _openDetail,
      ),
      AnimeHomeTab.category => _TileCloud<AnimeCategory>(
        items: feed.categories
            .where((item) => !_isInternalMetadataLabel(item.name))
            .toList(growable: false),
        labelOf: (item) => '${item.name}(${item.count})',
        imageOf: (item) => item.imageUrl,
        onTap: (item) => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => SubjectListPage(
              title: item.name,
              subtitle: '分类',
              loader: (ref) => ref
                  .read(animeControllerProvider.notifier)
                  .categorySubjects(item.name),
            ),
          ),
        ),
      ),
      AnimeHomeTab.tag => _TileCloud<AnimeTag>(
        items: feed.tags
            .where((item) => !_isInternalMetadataLabel(item.name))
            .toList(growable: false),
        labelOf: (item) => '${item.name}(${item.count})',
        imageOf: (item) => item.imageUrl,
        onTap: (item) => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => SubjectListPage(
              title: item.name,
              subtitle: '标签',
              loader: (ref) => ref
                  .read(animeControllerProvider.notifier)
                  .tagSubjects(item.name),
            ),
          ),
        ),
      ),
    };
    return Padding(
      padding: EdgeInsets.fromLTRB(compact ? 14 : 24, 2, compact ? 14 : 0, 24),
      child: content,
    );
  }

  void _openDetail(AnimeSubject subject) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => DetailPage(subject: subject)),
    );
  }

  void _openSearch(String keyword) {
    final query = keyword.trim();
    if (query.isEmpty) return;
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (context) => SearchPage(keyword: query)));
  }
}

class SubjectListPage extends ConsumerStatefulWidget {
  const SubjectListPage({
    super.key,
    required this.title,
    required this.loader,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final Future<List<AnimeSubject>> Function(WidgetRef ref) loader;

  @override
  ConsumerState<SubjectListPage> createState() => _SubjectListPageState();
}

class _SubjectListPageState extends ConsumerState<SubjectListPage> {
  late Future<List<AnimeSubject>> _subjectsFuture;

  @override
  void initState() {
    super.initState();
    _subjectsFuture = _loadSubjects();
  }

  @override
  void didUpdateWidget(covariant SubjectListPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.title != widget.title ||
        oldWidget.subtitle != widget.subtitle ||
        !identical(oldWidget.loader, widget.loader)) {
      _subjectsFuture = _loadSubjects();
    }
  }

  Future<List<AnimeSubject>> _loadSubjects() {
    return Future<List<AnimeSubject>>.sync(() => widget.loader(ref));
  }

  @override
  Widget build(BuildContext context) {
    return AppChrome(
      active: widget.subtitle == '标签'
          ? ChromeDestination.movie
          : ChromeDestination.series,
      title: widget.subtitle == null
          ? widget.title
          : '${widget.subtitle}：${widget.title}',
      showSearch: false,
      onBack: () => safeNavigateBack(context),
      rightRail: _StaticFilterRail(title: widget.subtitle ?? '筛选'),
      child: FutureBuilder<List<AnimeSubject>>(
        future: _subjectsFuture,
        builder: (context, snapshot) {
          final subjects = snapshot.data ?? const <AnimeSubject>[];
          if (snapshot.connectionState == ConnectionState.waiting) {
            return _SubjectListLoading(
              title: widget.title,
              subtitle: widget.subtitle,
            );
          }
          final compact = MediaQuery.sizeOf(context).width < 760;
          return Padding(
            padding: EdgeInsets.fromLTRB(
              compact ? 14 : 24,
              compact ? 0 : 6,
              compact ? 14 : 0,
              24,
            ),
            child: _SubjectResultView(subjects: subjects, title: widget.title),
          );
        },
      ),
    );
  }
}

class _SubjectListLoading extends StatelessWidget {
  const _SubjectListLoading({required this.title, required this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 760;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        compact ? 14 : 24,
        compact ? 8 : 18,
        compact ? 14 : 0,
        24,
      ),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: AppPanel(
            key: const ValueKey('subject-list-loading'),
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 18 : 24,
              vertical: compact ? 18 : 22,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.view_module_outlined,
                  size: compact ? 28 : 32,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 12),
                Text(
                  '正在整理$title',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '正在加载${subtitle ?? '内容'}结果…',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum MetadataHubKind { anime, series, movie }

enum _PlaybackFilter {
  all('全部'),
  playable('直连播放'),
  metadataOnly('规则查源');

  const _PlaybackFilter(this.label);

  final String label;
}

class MetadataHubPage extends ConsumerStatefulWidget {
  const MetadataHubPage({super.key, required this.kind});

  final MetadataHubKind kind;

  @override
  ConsumerState<MetadataHubPage> createState() => _MetadataHubPageState();
}

class _MetadataHubPageState extends ConsumerState<MetadataHubPage> {
  String _type = '全部';
  String _language = '全部';
  String _year = '全部';
  _PlaybackFilter _playbackFilter = _PlaybackFilter.all;
  Future<List<AnimeSubject>>? _subjectsFuture;
  int _subjectsRequestVersion = 0;
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshSubjectsInBackground();
    });
  }

  @override
  void didUpdateWidget(covariant MetadataHubPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.kind == widget.kind) return;
    _subjectsRequestVersion++;
    _subjectsFuture = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshSubjectsInBackground();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AsyncAnimeGate(
      builder: (context, state) {
        return AppChrome(
          active: _active,
          searchController: _searchController,
          onSearch: _openSearch,
          trailing: _MetadataTopFilters(
            selected: _type,
            values: _typeValues,
            onChanged: (value) => setState(() => _type = value),
            onRefresh: _reloadSubjects,
          ),
          rightRail: _MetadataRightRail(
            state: state,
            kind: widget.kind,
            onCategory: _openCategory,
            onTag: _openTag,
            onFilter: _selectTypeFilter,
          ),
          bottomPlayer: _MiniNowPlaying(
            subject: state.homeFeed.hero,
            progress: _watchProgress(state.history),
          ),
          child: FutureBuilder<List<AnimeSubject>>(
            future: _subjectsFuture ??= _loadSubjects(ref),
            builder: (context, snapshot) {
              final rawSubjects = snapshot.data ?? const <AnimeSubject>[];
              final subjects = _filterSubjects(rawSubjects);
              if (snapshot.connectionState == ConnectionState.waiting) {
                return _MetadataLoading(kind: widget.kind);
              }
              final compact = MediaQuery.sizeOf(context).width < 760;
              return Padding(
                padding: EdgeInsets.fromLTRB(
                  compact ? 14 : 24,
                  compact ? 0 : 2,
                  compact ? 14 : 0,
                  24,
                ),
                child: CustomScrollView(
                  slivers: [
                    SliverToBoxAdapter(
                      child: _MetadataHeader(
                        kind: widget.kind,
                        title: _title,
                        subtitle: _subtitle(subjects.length),
                        icon: _icon,
                        subjects: subjects,
                        state: state,
                        onOpen: _openDetail,
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: SizedBox(height: compact ? 10 : 14),
                    ),
                    SliverToBoxAdapter(
                      child: _InlineFilterPanel(
                        type: _type,
                        language: _language,
                        year: _year,
                        playbackFilter: _playbackFilter,
                        typeValues: _typeValues,
                        languageValues: _languageValues,
                        onTypeChanged: (value) => setState(() => _type = value),
                        onLanguageChanged: (value) =>
                            setState(() => _language = value),
                        onYearChanged: (value) => setState(() => _year = value),
                        onPlaybackFilterChanged: (value) =>
                            setState(() => _playbackFilter = value),
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: SizedBox(height: compact ? 10 : 14),
                    ),
                    if (subjects.isEmpty)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: _EmptyState(
                          icon: _icon,
                          title: '$_title 暂无结果',
                          message: _emptyMessage,
                        ),
                      )
                    else
                      _SubjectGridSliver(
                        subjects: subjects,
                        onOpen: _openDetail,
                        landscape: widget.kind == MetadataHubKind.series,
                        showPlaybackAvailability: true,
                      ),
                    const SliverToBoxAdapter(child: SizedBox(height: 120)),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  ChromeDestination get _active {
    return switch (widget.kind) {
      MetadataHubKind.anime => ChromeDestination.anime,
      MetadataHubKind.series => ChromeDestination.series,
      MetadataHubKind.movie => ChromeDestination.movie,
    };
  }

  String get _title {
    return switch (widget.kind) {
      MetadataHubKind.anime => '番剧',
      MetadataHubKind.series => '剧集',
      MetadataHubKind.movie => '电影',
    };
  }

  IconData get _icon {
    return switch (widget.kind) {
      MetadataHubKind.anime => Icons.explore_outlined,
      MetadataHubKind.series => Icons.live_tv_outlined,
      MetadataHubKind.movie => Icons.movie_outlined,
    };
  }

  List<String> get _typeValues {
    return switch (widget.kind) {
      MetadataHubKind.anime => const [
        '全部',
        '动画',
        '奇幻',
        '喜剧',
        '冒险',
        '科幻',
        '校园',
        '音乐',
      ],
      MetadataHubKind.series => const [
        '全部',
        '美剧',
        '韩剧',
        '日剧',
        '英剧',
        '剧情',
        '犯罪',
        '动作',
        '科幻',
      ],
      MetadataHubKind.movie => const [
        '全部',
        '电影',
        '剧情',
        '动作',
        '科幻',
        '奇幻',
        '冒险',
        '喜剧',
      ],
    };
  }

  List<String> get _languageValues {
    return switch (widget.kind) {
      MetadataHubKind.anime => const ['全部', '日语', '国语', '英语', '韩语', '其他'],
      MetadataHubKind.series => const ['全部', '英语', '韩语', '日语', '国语', '其他'],
      MetadataHubKind.movie => const ['全部', '英语', '国语', '日语', '韩语', '其他'],
    };
  }

  String _subtitle(int _) => '';

  String get _emptyMessage {
    if (_playbackFilter == _PlaybackFilter.playable) {
      return '当前筛选条件下没有直连内容，可切回“全部”或选择“规则查源”。';
    }
    if (_playbackFilter == _PlaybackFilter.metadataOnly) {
      return '当前筛选条件下没有需要规则查源的内容，可切回“全部”或选择“直连播放”。';
    }
    return switch (widget.kind) {
      MetadataHubKind.anime => '当前番剧元数据里没有匹配条目，换个筛选条件或稍后刷新试试。',
      MetadataHubKind.series => '当前剧集资料里没有匹配条目，换个分类或年份试试。',
      MetadataHubKind.movie => '当前电影资料里没有匹配条目，换个分类或年份试试。',
    };
  }

  Future<List<AnimeSubject>> _loadSubjects(
    WidgetRef ref, {
    bool waitForRefresh = false,
  }) {
    final controller = ref.read(animeControllerProvider.notifier);
    return switch (widget.kind) {
      MetadataHubKind.anime => controller.discoverSubjects(
        waitForRefresh: waitForRefresh,
      ),
      MetadataHubKind.series => controller.seriesSubjects(
        waitForRefresh: waitForRefresh,
      ),
      MetadataHubKind.movie => controller.movieSubjects(
        waitForRefresh: waitForRefresh,
      ),
    };
  }

  Future<void> _refreshSubjectsInBackground() async {
    final requestVersion = ++_subjectsRequestVersion;
    try {
      await ref.read(animeControllerProvider.future);
      if (!mounted || requestVersion != _subjectsRequestVersion) return;
      final subjects = await _loadSubjects(ref, waitForRefresh: true);
      if (!mounted || requestVersion != _subjectsRequestVersion) return;
      setState(() => _subjectsFuture = Future.value(subjects));
    } catch (_) {
      // Keep the already visible cache or fallback list on refresh failures.
    }
  }

  Future<void> _reloadSubjects() async {
    final kind = switch (widget.kind) {
      MetadataHubKind.anime => 'anime',
      MetadataHubKind.series => 'series',
      MetadataHubKind.movie => 'movie',
    };
    await ref
        .read(animeControllerProvider.notifier)
        .invalidateMetadataCache(kind);
    if (!mounted) return;
    _subjectsRequestVersion++;
    setState(() => _subjectsFuture = _loadSubjects(ref, waitForRefresh: true));
  }

  List<AnimeSubject> _filterSubjects(List<AnimeSubject> subjects) {
    return subjects
        .where((subject) {
          final kindOk = subjectMatchesContentType(
            subject,
            _subjectContentTypeFor(widget.kind),
          );
          final text = _metadataText(subject);
          final typeOk = _type == '全部' || _matchesType(subject, _type, text);
          final languageOk =
              _language == '全部' || _matchesLanguage(subject, _language);
          final yearOk =
              _year == '全部' || subject.year == _year.replaceAll('年', '');
          final directlyPlayable = hasKnownDirectPlayback(subject);
          final playbackOk = switch (_playbackFilter) {
            _PlaybackFilter.all => true,
            _PlaybackFilter.playable => directlyPlayable,
            _PlaybackFilter.metadataOnly => !directlyPlayable,
          };
          return kindOk && typeOk && languageOk && yearOk && playbackOk;
        })
        .toList(growable: false);
  }

  bool _matchesType(AnimeSubject subject, String type, String text) {
    final normalized = type.toLowerCase();
    if (normalized == '电影') {
      return subjectMatchesContentType(subject, SubjectContentType.movie);
    }
    if (normalized == '美剧') {
      return text.contains('united states') ||
          text.contains('english') ||
          text.contains('美国') ||
          text.contains('英语');
    }
    if (normalized == '英剧') {
      return text.contains('united kingdom') ||
          text.contains('british') ||
          text.contains('英国');
    }
    if (normalized == '韩剧') {
      return text.contains('korea') ||
          text.contains('korean') ||
          text.contains('韩国') ||
          text.contains('韩语');
    }
    if (normalized == '日剧') {
      return text.contains('japan') ||
          text.contains('japanese') ||
          text.contains('日本') ||
          text.contains('日语');
    }
    const aliases = {
      '剧情': ['drama', '剧情'],
      '犯罪': ['crime', '犯罪'],
      '动作': ['action', '动作'],
      '科幻': ['science fiction', 'sci-fi', '科幻'],
      '奇幻': ['fantasy', '奇幻'],
      '冒险': ['adventure', '冒险'],
      '喜剧': ['comedy', '喜剧'],
    };
    final values = aliases[type] ?? [normalized];
    return values.any(text.contains);
  }

  bool _matchesLanguage(AnimeSubject subject, String language) {
    final text = '${subject.language} ${subject.region}'.toLowerCase();
    return switch (language) {
      '日语' =>
        text.contains('日语') ||
            text.contains('japanese') ||
            text.contains('japan') ||
            text.contains('日本'),
      '国语' =>
        text.contains('国语') ||
            text.contains('中文') ||
            text.contains('chinese') ||
            text.contains('china') ||
            text.contains('中国'),
      '英语' =>
        text.contains('英语') ||
            text.contains('english') ||
            text.contains('united states') ||
            text.contains('united kingdom') ||
            text.contains('美国') ||
            text.contains('英国'),
      '韩语' =>
        text.contains('韩语') ||
            text.contains('korean') ||
            text.contains('korea') ||
            text.contains('韩国'),
      '其他' =>
        !(_matchesLanguage(subject, '日语') ||
            _matchesLanguage(subject, '国语') ||
            _matchesLanguage(subject, '英语') ||
            _matchesLanguage(subject, '韩语')),
      _ => true,
    };
  }

  double _watchProgress(List<LibraryEntry> history) {
    if (history.isEmpty) return 0.62;
    final latest = history.first.episode?.number ?? 1;
    final total = history.first.subject.totalEpisodes;
    if (total <= 0) return 0.35;
    return (latest / total).clamp(0.05, 1);
  }

  String _metadataText(AnimeSubject subject) {
    return [
      subject.title,
      subject.originalTitle,
      subject.platform,
      subject.language,
      subject.region,
      subject.status,
      ...subject.categories.map((item) => item.name),
      ...subject.tags.map((item) => item.name),
    ].join(' ').toLowerCase();
  }

  void _selectTypeFilter(String value) {
    if (!_typeValues.contains(value)) return;
    setState(() {
      _type = value;
      _language = '全部';
      _year = '全部';
    });
  }

  void _openDetail(AnimeSubject subject) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => DetailPage(subject: subject)),
    );
  }

  void _openSearch(String keyword) {
    final query = keyword.trim();
    if (query.isEmpty) return;
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (context) => SearchPage(keyword: query)));
  }

  void _openCategory(AnimeCategory category) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => SubjectListPage(
          title: category.name,
          subtitle: '分类',
          loader: (ref) => ref
              .read(animeControllerProvider.notifier)
              .categorySubjects(category.name),
        ),
      ),
    );
  }

  void _openTag(AnimeTag tag) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => SubjectListPage(
          title: tag.name,
          subtitle: '标签',
          loader: (ref) =>
              ref.read(animeControllerProvider.notifier).tagSubjects(tag.name),
        ),
      ),
    );
  }
}

class _MetadataTopFilters extends StatelessWidget {
  const _MetadataTopFilters({
    required this.selected,
    required this.values,
    required this.onChanged,
    required this.onRefresh,
  });

  final String selected;
  final List<String> values;
  final ValueChanged<String> onChanged;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 900;
    if (compact) {
      return IconButton(
        tooltip: '刷新当前频道',
        onPressed: onRefresh,
        icon: const Icon(Icons.refresh_rounded),
      );
    }
    return AppPanel(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 5),
      radius: 10,
      color: AppColors.bg2,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final value in values.take(6))
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: InkWell(
                onTap: () => onChanged(value),
                borderRadius: BorderRadius.circular(8),
                child: SmallBadge(label: value, active: value == selected),
              ),
            ),
          IconButton(
            tooltip: '刷新当前频道',
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh_rounded, size: 19),
          ),
        ],
      ),
    );
  }
}

class _MetadataLoading extends StatelessWidget {
  const _MetadataLoading({required this.kind});

  final MetadataHubKind kind;

  @override
  Widget build(BuildContext context) {
    final title = switch (kind) {
      MetadataHubKind.anime => '正在整理番剧元数据',
      MetadataHubKind.series => '正在加载剧集元数据',
      MetadataHubKind.movie => '正在加载电影元数据',
    };
    final message = switch (kind) {
      MetadataHubKind.anime => '正在汇总近期热门番剧并补充中文资料。',
      MetadataHubKind.series => '正在汇总热门剧集、分集信息与中文资料。',
      MetadataHubKind.movie => '正在汇总热门电影与开放可播放影片。',
    };
    return Center(
      child: AppPanel(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 32,
              height: 32,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: AppColors.text,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: AppColors.muted),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetadataHeader extends StatelessWidget {
  const _MetadataHeader({
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.subjects,
    required this.state,
    required this.onOpen,
  });

  final MetadataHubKind kind;
  final String title;
  final String subtitle;
  final IconData icon;
  final List<AnimeSubject> subjects;
  final AnimeState state;
  final ValueChanged<AnimeSubject> onOpen;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 760;
    final bannerSubjects = subjects
        .where((item) => (item.bannerUrl ?? '').isNotEmpty)
        .toList(growable: false);
    final imageSubjects = subjects
        .where((item) => (item.coverUrl ?? '').isNotEmpty)
        .toList(growable: false);
    final leadPool = bannerSubjects.isNotEmpty
        ? bannerSubjects
        : imageSubjects.isNotEmpty
        ? imageSubjects
        : subjects;
    final lead = leadPool.isEmpty
        ? null
        : leadPool[(DateTime.now().day + kind.index * 7) % leadPool.length];
    final following = state.following.isNotEmpty
        ? state.following
        : state.history;
    final continueEntry = following.firstOrNull;
    final danmakuReady =
        state.services.dandanplayDanmakuEnabled ||
        state.services.bilibiliDanmakuEnabled ||
        state.services.customDanmakuEnabled;
    final height = compact ? 220.0 : 280.0;
    return SizedBox(
      height: height,
      child: AppPanel(
        padding: EdgeInsets.zero,
        borderColor: AppColors.borderBright,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (lead != null)
                BackdropArt(
                  bannerUrl: lead.bannerUrl,
                  posterUrl: lead.coverUrl,
                  title: lead.title,
                )
              else
                const ColoredBox(color: AppColors.panel),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      Color(0xF0060912),
                      Color(0xCC060912),
                      Color(0x55060912),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  compact ? 16 : 22,
                  compact ? 14 : 18,
                  compact ? 16 : 22,
                  compact ? 14 : 18,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!compact)
                      CircleAvatar(
                        radius: 21,
                        backgroundColor: AppColors.primary.withValues(
                          alpha: 0.22,
                        ),
                        child: Icon(icon, color: AppColors.text, size: 22),
                      ),
                    const Spacer(),
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          (compact
                                  ? Theme.of(context).textTheme.titleLarge
                                  : Theme.of(context).textTheme.headlineSmall)
                              ?.copyWith(
                                color: AppColors.text,
                                fontWeight: FontWeight.w900,
                              ),
                    ),
                    if (subtitle.isNotEmpty) ...[
                      SizedBox(height: compact ? 4 : 6),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AppColors.muted,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    if (kind == MetadataHubKind.anime) ...[
                      SizedBox(height: compact ? 10 : 14),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final compact = constraints.maxWidth < 700;
                          final chips = <Widget>[
                            _AnimekoStatusChip(
                              icon: Icons.play_circle_outline,
                              label: continueEntry == null
                                  ? '还没有续看'
                                  : '续看 ${continueEntry.subject.title}',
                              active: continueEntry != null,
                              onTap: continueEntry == null
                                  ? null
                                  : () => onOpen(continueEntry.subject),
                            ),
                            _AnimekoStatusChip(
                              icon: Icons.calendar_month_outlined,
                              label: '今日更新 ${_todayCount(subjects)} 部',
                              active: _todayCount(subjects) > 0,
                            ),
                          ];
                          if (!compact) {
                            chips.addAll([
                              _AnimekoStatusChip(
                                icon: Icons.subtitles_outlined,
                                label: danmakuReady ? '弹幕已接入' : '弹幕未开启',
                                active: danmakuReady,
                              ),
                            ]);
                          }
                          return compact
                              ? Wrap(spacing: 8, runSpacing: 8, children: chips)
                              : Row(
                                  children: [
                                    for (var i = 0; i < chips.length; i++) ...[
                                      Expanded(child: chips[i]),
                                      if (i != chips.length - 1)
                                        const SizedBox(width: 8),
                                    ],
                                  ],
                                );
                        },
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  int _todayCount(List<AnimeSubject> items) {
    final now = DateTime.now();
    return items.where((item) {
      final date = DateTime.tryParse(item.date ?? '');
      return date != null && date.month == now.month && date.day == now.day;
    }).length;
  }
}

class _AnimekoStatusChip extends StatelessWidget {
  const _AnimekoStatusChip({
    required this.icon,
    required this.label,
    required this.active,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: active
              ? AppColors.primary.withValues(alpha: 0.22)
              : const Color(0x99101522),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: active ? AppColors.borderBright : AppColors.border,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 17,
                color: active ? AppColors.text : AppColors.muted,
              ),
              const SizedBox(width: 7),
              Flexible(
                fit: FlexFit.loose,
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: active ? AppColors.text : AppColors.muted,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InlineFilterPanel extends StatelessWidget {
  const _InlineFilterPanel({
    required this.type,
    required this.language,
    required this.year,
    required this.playbackFilter,
    required this.typeValues,
    required this.languageValues,
    required this.onTypeChanged,
    required this.onLanguageChanged,
    required this.onYearChanged,
    required this.onPlaybackFilterChanged,
  });

  final String type;
  final String language;
  final String year;
  final _PlaybackFilter playbackFilter;
  final List<String> typeValues;
  final List<String> languageValues;
  final ValueChanged<String> onTypeChanged;
  final ValueChanged<String> onLanguageChanged;
  final ValueChanged<String> onYearChanged;
  final ValueChanged<_PlaybackFilter> onPlaybackFilterChanged;

  @override
  Widget build(BuildContext context) {
    final years = [
      '全部',
      for (var y = DateTime.now().year; y >= 2013; y--) '$y年',
    ];
    final compact = MediaQuery.sizeOf(context).width < 760;
    return AppPanel(
      padding: EdgeInsets.fromLTRB(
        compact ? 10 : 14,
        compact ? 6 : 10,
        compact ? 10 : 14,
        compact ? 6 : 10,
      ),
      child: Column(
        children: [
          _FilterRow(
            label: '类型',
            values: typeValues,
            selected: type,
            onChanged: onTypeChanged,
          ),
          _FilterRow(
            label: '语言',
            values: languageValues,
            selected: language,
            onChanged: onLanguageChanged,
          ),
          _FilterRow(
            label: '年份',
            values: years,
            selected: year,
            onChanged: onYearChanged,
          ),
          _FilterRow(
            label: '播放',
            values: _PlaybackFilter.values
                .map((value) => value.label)
                .toList(growable: false),
            selected: playbackFilter.label,
            onChanged: (value) => onPlaybackFilterChanged(
              _PlaybackFilter.values.firstWhere((item) => item.label == value),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetadataRightRail extends StatelessWidget {
  const _MetadataRightRail({
    required this.state,
    required this.kind,
    required this.onCategory,
    required this.onTag,
    required this.onFilter,
  });

  final AnimeState state;
  final MetadataHubKind kind;
  final ValueChanged<AnimeCategory> onCategory;
  final ValueChanged<AnimeTag> onTag;
  final ValueChanged<String> onFilter;

  @override
  Widget build(BuildContext context) {
    final feed = state.homeFeed;
    final categories = _categories(feed);
    final tags = _tags(feed);
    final subjects = _railSubjects(feed);
    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 6, 20, 24),
      children: [
        AppPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionTitle(title: _title, subtitle: _subtitle),
              const SizedBox(height: 12),
              if (subjects.isEmpty)
                Text(
                  _sourceMessage,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: AppColors.muted),
                )
              else
                for (final subject in subjects.take(5))
                  CompactSubjectRow(
                    subject: _publicSubjectMetadata(context, subject),
                    onTap: () => _openSubject(context, subject),
                  ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        AppPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionTitle(title: kind == MetadataHubKind.anime ? '分类' : '频道'),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final category in categories)
                    _FilterChipButton(
                      label: category.count > 0
                          ? '${category.name}(${category.count})'
                          : category.name,
                      onTap: () => _handleCategory(category),
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        AppPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionTitle(title: kind == MetadataHubKind.anime ? '标签' : '特色'),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final tag in tags)
                    _FilterChipButton(
                      label: tag.count > 0
                          ? '${tag.name}(${tag.count})'
                          : tag.name,
                      onTap: kind == MetadataHubKind.anime
                          ? () => _handleTag(tag)
                          : null,
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  String get _sourceMessage {
    return switch (kind) {
      MetadataHubKind.anime => '正在整理近期热门番剧与中文资料。',
      MetadataHubKind.series => '正在整理电视剧、连续剧和网剧资料。',
      MetadataHubKind.movie => '正在整理热门电影与开放影片资料。',
    };
  }

  List<AnimeCategory> _categories(AnimeHomeFeed feed) {
    return switch (kind) {
      MetadataHubKind.anime =>
        feed.categories
            .where((item) => !_isInternalMetadataLabel(item.name))
            .take(12)
            .toList(),
      MetadataHubKind.series => const [
        AnimeCategory(name: '美剧'),
        AnimeCategory(name: '韩剧'),
        AnimeCategory(name: '日剧'),
        AnimeCategory(name: '英剧'),
        AnimeCategory(name: '剧情'),
        AnimeCategory(name: '犯罪'),
        AnimeCategory(name: '动作'),
        AnimeCategory(name: '科幻'),
      ],
      MetadataHubKind.movie => const [
        AnimeCategory(name: '电影'),
        AnimeCategory(name: '剧情'),
        AnimeCategory(name: '动作'),
        AnimeCategory(name: '科幻'),
        AnimeCategory(name: '奇幻'),
        AnimeCategory(name: '冒险'),
        AnimeCategory(name: '喜剧'),
      ],
    };
  }

  List<AnimeTag> _tags(AnimeHomeFeed feed) {
    return switch (kind) {
      MetadataHubKind.anime =>
        feed.tags
            .where((item) => !_isInternalMetadataLabel(item.name))
            .take(16)
            .toList(),
      MetadataHubKind.series => const [
        AnimeTag(name: '热门剧集'),
        AnimeTag(name: '最近播出'),
        AnimeTag(name: '中文资料'),
        AnimeTag(name: '免登录'),
      ],
      MetadataHubKind.movie => const [
        AnimeTag(name: '热门电影'),
        AnimeTag(name: '开放影片'),
        AnimeTag(name: '中文资料'),
        AnimeTag(name: '免登录'),
      ],
    };
  }

  String get _title {
    return switch (kind) {
      MetadataHubKind.anime => '番剧推荐',
      MetadataHubKind.series => '影视剧',
      MetadataHubKind.movie => '电影索引',
    };
  }

  String get _subtitle {
    return switch (kind) {
      MetadataHubKind.anime => '综合热度与评分',
      MetadataHubKind.series => '电视剧 / 连续剧 / 网剧',
      MetadataHubKind.movie => '院线电影 / 网络电影',
    };
  }

  List<AnimeSubject> _railSubjects(AnimeHomeFeed feed) {
    return switch (kind) {
      MetadataHubKind.anime =>
        feed.recommended
            .where(
              (subject) =>
                  subjectMatchesContentType(subject, SubjectContentType.anime),
            )
            .toList(growable: false),
      MetadataHubKind.series => const [],
      MetadataHubKind.movie => const [],
    };
  }

  void _openSubject(BuildContext context, AnimeSubject subject) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => DetailPage(subject: subject)),
    );
  }

  void _handleCategory(AnimeCategory category) {
    if (kind == MetadataHubKind.anime) {
      onCategory(category);
      return;
    }
    onFilter(category.name);
  }

  void _handleTag(AnimeTag tag) {
    if (kind == MetadataHubKind.anime) {
      onTag(tag);
    }
  }
}

class _FilterChipButton extends StatelessWidget {
  const _FilterChipButton({required this.label, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Opacity(
        opacity: enabled ? 1 : 0.72,
        child: SmallBadge(label: label),
      ),
    );
  }
}

class SchedulePage extends ConsumerStatefulWidget {
  const SchedulePage({super.key});

  static const _weekdays = [
    (0, '周日'),
    (1, '周一'),
    (2, '周二'),
    (3, '周三'),
    (4, '周四'),
    (5, '周五'),
    (6, '周六'),
  ];

  @override
  ConsumerState<SchedulePage> createState() => _SchedulePageState();
}

class _SchedulePageState extends ConsumerState<SchedulePage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  late final Future<Map<int, List<AnimeSubject>>> _scheduleFuture;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: SchedulePage._weekdays.length,
      vsync: this,
      initialIndex: DateTime.now().weekday % 7,
    );
    _scheduleFuture = ref
        .read(animeControllerProvider.notifier)
        .weeklySchedule();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppChrome(
      active: ChromeDestination.schedule,
      title: '周期表',
      showSearch: false,
      onBack: () => safeNavigateBack(context),
      rightRail: AsyncAnimeGate(
        builder: (context, state) => _ScheduleRightRail(state: state),
      ),
      child: FutureBuilder<Map<int, List<AnimeSubject>>>(
        future: _scheduleFuture,
        builder: (context, snapshot) {
          final schedule = snapshot.data ?? const <int, List<AnimeSubject>>{};
          return Padding(
            padding: const EdgeInsets.fromLTRB(24, 6, 0, 24),
            child: Column(
              children: [
                AnimatedBuilder(
                  animation: _tabController.animation!,
                  builder: (context, child) => _WeekCalendarStrip(
                    schedule: schedule,
                    selectedIndex: _tabController.animation!.value
                        .round()
                        .clamp(0, SchedulePage._weekdays.length - 1),
                    onSelected: _tabController.animateTo,
                  ),
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: AppPanel(
                    padding: EdgeInsets.zero,
                    child: snapshot.connectionState == ConnectionState.waiting
                        ? const Center(child: CircularProgressIndicator())
                        : TabBarView(
                            controller: _tabController,
                            children: [
                              for (final item in SchedulePage._weekdays)
                                _SubjectResultView(
                                  key: ValueKey('schedule-result-${item.$1}'),
                                  subjects:
                                      schedule[item.$1] ??
                                      const <AnimeSubject>[],
                                  title: item.$2,
                                ),
                            ],
                          ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SubjectResultView extends StatelessWidget {
  const _SubjectResultView({
    super.key,
    required this.subjects,
    required this.title,
  });

  final List<AnimeSubject> subjects;
  final String title;

  @override
  Widget build(BuildContext context) {
    if (subjects.isEmpty) {
      return _EmptyState(
        icon: Icons.movie_filter_outlined,
        title: '$title 暂无结果',
        message: '暂时没有可展示条目，稍后刷新或换个分类试试。',
      );
    }
    return _SubjectGrid(
      subjects: subjects,
      onOpen: (subject) => Navigator.of(context).push(
        MaterialPageRoute(builder: (context) => DetailPage(subject: subject)),
      ),
    );
  }
}

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key, required this.keyword});

  final String keyword;

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  late Future<_SearchPageData> _search;

  @override
  void initState() {
    super.initState();
    _search = _load();
  }

  @override
  void didUpdateWidget(covariant SearchPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.keyword != widget.keyword) _search = _load();
  }

  Future<_SearchPageData> _load() async {
    final controller = ref.read(animeControllerProvider.notifier);
    final subjectsFuture = controller.search(widget.keyword);
    final torrentsFuture = controller.searchTorrentResources(widget.keyword);
    final subjects = await subjectsFuture;
    final torrents = await torrentsFuture;
    return _SearchPageData(subjects: subjects, torrents: torrents);
  }

  void _retry() {
    setState(() => _search = _load());
  }

  @override
  Widget build(BuildContext context) {
    return AppChrome(
      active: ChromeDestination.anime,
      title: '搜索：${widget.keyword}',
      showSearch: false,
      onBack: () => safeNavigateBack(context),
      rightRail: _SearchRightRail(keyword: widget.keyword),
      child: FutureBuilder<_SearchPageData>(
        future: _search,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError || snapshot.data == null) {
            return _SearchLoadError(onRetry: _retry);
          }
          return _SearchResultBody(
            data: snapshot.data!,
            onOpenSubject: (subject) => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => DetailPage(subject: subject),
              ),
            ),
            onOpenTorrent: (resource) =>
                _openTorrentResource(context, resource),
          );
        },
      ),
    );
  }
}

class _SearchPageData {
  const _SearchPageData({required this.subjects, required this.torrents});

  final List<AnimeSubject> subjects;
  final SourceAdapterBatch<TorrentResource> torrents;
}

class _SearchResultBody extends StatelessWidget {
  const _SearchResultBody({
    required this.data,
    required this.onOpenSubject,
    required this.onOpenTorrent,
  });

  final _SearchPageData data;
  final ValueChanged<AnimeSubject> onOpenSubject;
  final ValueChanged<TorrentResource> onOpenTorrent;

  @override
  Widget build(BuildContext context) {
    final liveSubjects = data.subjects
        .where((item) => item.source.startsWith('m3u-channel:'))
        .toList(growable: false);
    final mediaSubjects = data.subjects
        .where((item) => !item.source.startsWith('m3u-channel:'))
        .toList(growable: false);
    final torrents = data.torrents.items;
    if (mediaSubjects.isEmpty && liveSubjects.isEmpty && torrents.isEmpty) {
      return const _EmptyState(
        icon: Icons.search_off_rounded,
        title: '没有找到相关内容',
        message: '可以换一个片名、频道名或字幕组关键词再试。',
      );
    }

    return CustomScrollView(
      slivers: [
        if (data.torrents.hasFailures)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(24, 6, 8, 8),
              child: AppPanel(
                borderColor: AppColors.borderBright,
                child: Text('部分外部资源源站暂时不可用，已展示其余可用结果。'),
              ),
            ),
          ),
        if (mediaSubjects.isNotEmpty) ...[
          const _SearchSectionHeader(
            icon: Icons.movie_filter_outlined,
            title: '影视与资料',
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(24, 0, 0, 0),
            sliver: _SubjectGridSliver(
              subjects: mediaSubjects,
              onOpen: onOpenSubject,
            ),
          ),
        ],
        if (liveSubjects.isNotEmpty) ...[
          const _SearchSectionHeader(
            icon: Icons.live_tv_outlined,
            title: '直播频道',
            subtitle: '来自已启用的 M3U 源，打开后会直接进入播放器',
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(24, 0, 0, 0),
            sliver: _SubjectGridSliver(
              subjects: liveSubjects,
              onOpen: onOpenSubject,
            ),
          ),
        ],
        if (torrents.isNotEmpty) ...[
          const _SearchSectionHeader(
            icon: Icons.download_for_offline_outlined,
            title: 'BT / 磁力资源',
            subtitle: '仅交给外部 BT 客户端处理，不会伪装成内置在线播放',
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(24, 0, 8, 0),
            sliver: SliverList.separated(
              itemCount: torrents.length,
              itemBuilder: (context, index) => _TorrentResourceCard(
                resource: torrents[index],
                onOpen: () => onOpenTorrent(torrents[index]),
              ),
              separatorBuilder: (context, index) => const SizedBox(height: 10),
            ),
          ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 120)),
      ],
    );
  }
}

class _SearchSectionHeader extends StatelessWidget {
  const _SearchSectionHeader({
    required this.icon,
    required this.title,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 18, 8, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: AppColors.primary),
            const SizedBox(width: 10),
            Expanded(
              child: SectionTitle(title: title, subtitle: subtitle),
            ),
          ],
        ),
      ),
    );
  }
}

class _TorrentResourceCard extends StatelessWidget {
  const _TorrentResourceCard({required this.resource, required this.onOpen});

  final TorrentResource resource;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final meta = <String>[
      resource.sourceName,
      if (resource.category.trim().isNotEmpty) resource.category.trim(),
      if ((resource.sizeLabel ?? '').trim().isNotEmpty) resource.sizeLabel!,
      if (resource.seeders != null) '做种 ${resource.seeders}',
    ];
    return AppPanel(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 720;
          final details = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                resource.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: AppColors.text,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                meta.join(' · '),
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
              ),
            ],
          );
          final action = FilledButton.icon(
            onPressed: onOpen,
            icon: const Icon(Icons.open_in_new, size: 18),
            label: const Text('外部客户端打开'),
          );
          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [details, const SizedBox(height: 12), action],
            );
          }
          return Row(
            children: [
              const Icon(
                Icons.cloud_download_outlined,
                color: AppColors.primary,
                size: 30,
              ),
              const SizedBox(width: 14),
              Expanded(child: details),
              const SizedBox(width: 14),
              action,
            ],
          );
        },
      ),
    );
  }
}

class _SearchLoadError extends StatelessWidget {
  const _SearchLoadError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: AppPanel(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.wifi_off_rounded,
              color: AppColors.muted,
              size: 36,
            ),
            const SizedBox(height: 10),
            const Text('搜索暂时失败，请检查网络后重试。'),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重新搜索'),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _openTorrentResource(
  BuildContext context,
  TorrentResource resource,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('交给外部 BT 客户端？'),
      content: const Text(
        'BT 下载会向对等网络暴露你的公网 IP，并可能消耗较多流量和磁盘空间。应用本身不会在线播放或后台下载这个资源。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('继续打开'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;

  var launched = false;
  try {
    launched = await launchUrl(
      resource.magnetUri,
      mode: LaunchMode.externalApplication,
    );
  } catch (_) {}
  if (launched || !context.mounted) return;

  await Clipboard.setData(ClipboardData(text: resource.magnetUri.toString()));
  if (context.mounted) {
    _showToast(context, '未找到可用的 BT 客户端，磁力链接已复制。');
  }
}

class DetailPage extends ConsumerStatefulWidget {
  const DetailPage({super.key, required this.subject});

  final AnimeSubject subject;

  @override
  ConsumerState<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends ConsumerState<DetailPage> {
  late Future<AnimeDetailBundle> _detailFuture;

  @override
  void initState() {
    super.initState();
    _detailFuture = _loadDetail();
  }

  @override
  void didUpdateWidget(covariant DetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!sameSubjectIdentity(oldWidget.subject, widget.subject)) {
      _detailFuture = _loadDetail();
    }
  }

  Future<AnimeDetailBundle> _loadDetail() {
    return ref.read(animeControllerProvider.notifier).detail(widget.subject);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AnimeDetailBundle>(
      future: _detailFuture,
      builder: (context, snapshot) {
        final detail = snapshot.data;
        final bundle =
            detail ??
            AnimeDetailBundle(
              subject: widget.subject,
              episodes: const [],
              characters: const [],
              staff: const [],
              recommendations: const [],
            );
        final animeState = ref.watch(animeControllerProvider).value;
        final following =
            animeState?.following.any(
              (item) => sameSubjectIdentity(item.subject, bundle.subject),
            ) ??
            false;
        final collected =
            animeState?.favorites.any(
              (item) => sameSubjectIdentity(item.subject, bundle.subject),
            ) ??
            false;
        final historyEntry = animeState?.history
            .where((item) => sameSubjectIdentity(item.subject, bundle.subject))
            .firstOrNull;

        Future<void> play(AnimeEpisode episode) async {
          final controller = ref.read(animeControllerProvider.notifier);
          final accountContextVersion = controller.accountContextVersion;
          final recorded = await controller.addHistory(
            bundle.subject,
            episode,
            expectedAccountContextVersion: accountContextVersion,
          );
          if (!context.mounted ||
              !recorded ||
              !controller.isAccountContextCurrent(accountContextVersion)) {
            return;
          }
          context.push(
            '/player',
            extra: PlaySessionRequest(
              subject: bundle.subject,
              episodes: bundle.episodes,
              episode: episode,
            ),
          );
        }

        AnimeEpisode? continueEpisode() {
          final watched = historyEntry?.episode;
          if (watched != null &&
              bundle.episodes.any((item) => item.id == watched.id)) {
            return watched;
          }
          return bundle.episodes.firstOrNull;
        }

        return DefaultTabController(
          length: 5,
          child: AppChrome(
            active: _activeForSubject(bundle.subject),
            showSearch: false,
            title: bundle.subject.title,
            onBack: () => safeNavigateBack(context),
            rightRail: _DetailRightRail(
              bundle: bundle,
              onOpen: (item) {
                Navigator.of(context).pushReplacement(
                  MaterialPageRoute(
                    builder: (context) => DetailPage(subject: item.subject),
                  ),
                );
              },
            ),
            bottomPlayer: _MiniNowPlaying(
              subject: bundle.subject,
              progress: 0.58,
            ),
            child: Stack(
              children: [
                _BlurredBackdrop(subject: bundle.subject),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 6, 0, 24),
                  child: NestedScrollView(
                    key: const ValueKey('detailUnifiedScroll'),
                    headerSliverBuilder: (context, innerBoxIsScrolled) => [
                      SliverToBoxAdapter(
                        child: _DetailHero(
                          key: const ValueKey('detailHero'),
                          subject: bundle.subject,
                          following: following,
                          collected: collected,
                          onPlay: continueEpisode() == null
                              ? null
                              : () => play(continueEpisode()!),
                          onFollowing: () async {
                            final selected = await ref
                                .read(animeControllerProvider.notifier)
                                .toggleFollowing(bundle.subject);
                            if (context.mounted) {
                              _showToast(
                                context,
                                selected ? '已加入追番列表' : '已取消追番',
                              );
                            }
                          },
                          onCollect: () async {
                            final selected = await ref
                                .read(animeControllerProvider.notifier)
                                .toggleFavorite(bundle.subject);
                            if (context.mounted) {
                              _showToast(
                                context,
                                selected ? '已加入收藏列表' : '已取消收藏',
                              );
                            }
                          },
                          onDownload: () async {
                            final controller = ref.read(
                              animeControllerProvider.notifier,
                            );
                            if (!controller.supportsOfflineDownloads) {
                              _showToast(context, '网页版暂不支持离线下载，请使用桌面或移动客户端。');
                              return;
                            }
                            if (bundle.subject.source.startsWith(
                              'm3u-channel:',
                            )) {
                              _showToast(context, '直播频道暂不支持离线下载。');
                              return;
                            }
                            final episode = continueEpisode();
                            if (episode == null) {
                              _showToast(context, '当前条目还没有可下载的集数');
                              return;
                            }
                            _showToast(context, '正在解析线路并开始下载…');
                            final message = await controller.queueOffline(
                              bundle.subject,
                              episode,
                            );
                            if (context.mounted) _showToast(context, message);
                          },
                        ),
                      ),
                      const SliverToBoxAdapter(child: SizedBox(height: 14)),
                      const SliverPersistentHeader(
                        pinned: true,
                        delegate: _DetailTabsHeaderDelegate(),
                      ),
                    ],
                    body: snapshot.connectionState == ConnectionState.waiting
                        ? const Center(child: CircularProgressIndicator())
                        : TabBarView(
                            children: [
                              _DetailInfo(bundle: bundle),
                              _EpisodeGrid(bundle: bundle, onPlay: play),
                              _CharacterGrid(items: bundle.characters),
                              _StaffGrid(items: bundle.staff),
                              _RecommendationGrid(
                                items: bundle.recommendations,
                                onOpen: (item) {
                                  Navigator.of(context).pushReplacement(
                                    MaterialPageRoute(
                                      builder: (context) =>
                                          DetailPage(subject: item.subject),
                                    ),
                                  );
                                },
                              ),
                            ],
                          ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

ChromeDestination _activeForSubject(AnimeSubject subject) {
  return switch (subjectContentTypeOf(subject)) {
    SubjectContentType.anime => ChromeDestination.home,
    SubjectContentType.series => ChromeDestination.series,
    SubjectContentType.movie => ChromeDestination.movie,
  };
}

class _HomeToolbar extends StatelessWidget {
  const _HomeToolbar({
    required this.selected,
    required this.onChanged,
    required this.onSchedule,
    required this.onProfile,
  });

  final AnimeHomeTab selected;
  final ValueChanged<AnimeHomeTab> onChanged;
  final VoidCallback onSchedule;
  final VoidCallback onProfile;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 860;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!compact)
          AppPanel(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 5),
            radius: 10,
            color: AppColors.bg2,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final tab in AnimeHomeTab.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: InkWell(
                      onTap: () => onChanged(tab),
                      borderRadius: BorderRadius.circular(8),
                      child: SmallBadge(
                        label: tab.label,
                        active: tab == selected,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        if (!compact) const SizedBox(width: 10),
        _ChromeIconButton(
          icon: Icons.calendar_month_outlined,
          tooltip: '周期表',
          onTap: onSchedule,
        ),
        const SizedBox(width: 8),
        _ChromeIconButton(
          icon: Icons.person_outline,
          tooltip: '我的',
          onTap: onProfile,
        ),
      ],
    );
  }
}

class _ChromeIconButton extends StatelessWidget {
  const _ChromeIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppColors.panelHigh,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.border),
          ),
          child: SizedBox(
            width: 40,
            height: 38,
            child: Icon(icon, size: 20, color: AppColors.text),
          ),
        ),
      ),
    );
  }
}

class _HomeRightRail extends StatelessWidget {
  const _HomeRightRail({
    required this.feed,
    required this.state,
    required this.onOpen,
  });

  final AnimeHomeFeed feed;
  final AnimeState state;
  final ValueChanged<AnimeSubject> onOpen;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 6, 20, 24),
      children: [
        AppPanel(
          child: Column(
            children: [
              const SectionTitle(title: '我的内容'),
              const SizedBox(height: 12),
              _PlaylistRow(
                image: state.following.firstOrNull?.subject.coverUrl,
                title: '追番',
                count: state.following.length,
              ),
              _PlaylistRow(
                image: state.favorites.firstOrNull?.subject.coverUrl,
                title: '收藏',
                count: state.favorites.length,
              ),
              _PlaylistRow(
                image: state.history.firstOrNull?.subject.coverUrl,
                title: '观看记录',
                count: state.history.length,
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        AppPanel(
          child: Column(
            children: [
              SectionTitle(
                title: '最近更新',
                action: Text(
                  '更多 ›',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: AppColors.muted,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              for (final subject in feed.recent.take(5))
                CompactSubjectRow(
                  subject: _publicSubjectMetadata(context, subject),
                  trailing: '刚刚',
                  onTap: () => onOpen(subject),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PlaylistRow extends StatelessWidget {
  const _PlaylistRow({
    required this.image,
    required this.title,
    required this.count,
  });

  final String? image;
  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: 46,
              height: 32,
              child: PosterArt(coverUrl: image, title: title),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: AppColors.text,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          Text(
            '$count',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: AppColors.muted,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniNowPlaying extends StatelessWidget {
  const _MiniNowPlaying({required this.subject, required this.progress});

  final AnimeSubject subject;
  final double progress;

  @override
  Widget build(BuildContext context) {
    return AppPanel(
      padding: const EdgeInsets.all(10),
      radius: 10,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              height: 62,
              width: double.infinity,
              child: PosterArt(
                coverUrl: subject.bannerUrl,
                fallbackCoverUrl: subject.coverUrl,
                title: subject.title,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            subject.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: AppColors.text,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: progress,
            minHeight: 4,
            borderRadius: BorderRadius.circular(4),
            backgroundColor: AppColors.border,
            color: AppColors.primary,
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: const [
              Icon(Icons.skip_previous, color: AppColors.muted, size: 20),
              CircleAvatar(
                radius: 19,
                backgroundColor: AppColors.primary,
                child: Icon(Icons.play_arrow_rounded, color: Colors.white),
              ),
              Icon(Icons.skip_next, color: AppColors.muted, size: 20),
            ],
          ),
        ],
      ),
    );
  }
}

class _RecentTab extends StatelessWidget {
  const _RecentTab({required this.subjects, required this.onOpen});

  final List<AnimeSubject> subjects;
  final ValueChanged<AnimeSubject> onOpen;

  @override
  Widget build(BuildContext context) {
    return _SubjectGrid(subjects: subjects, onOpen: onOpen, landscape: true);
  }
}

class _RecommendTab extends StatefulWidget {
  const _RecommendTab({required this.feed, required this.onOpen});

  final AnimeHomeFeed feed;
  final ValueChanged<AnimeSubject> onOpen;

  @override
  State<_RecommendTab> createState() => _RecommendTabState();
}

class _RecommendTabState extends State<_RecommendTab> {
  late final PageController _heroController;
  int _heroIndex = 0;

  @override
  void initState() {
    super.initState();
    _heroController = PageController();
  }

  @override
  void didUpdateWidget(covariant _RecommendTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.feed != widget.feed) {
      _heroIndex = 0;
      if (_heroController.hasClients) _heroController.jumpToPage(0);
    }
  }

  @override
  void dispose() {
    _heroController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 760;
    final heroSubjects = _heroSubjects(widget.feed);
    final heroIndex = heroSubjects.isEmpty
        ? 0
        : _heroIndex.clamp(0, heroSubjects.length - 1).toInt();
    final shortcuts = _shortcuts(widget.feed);
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(0, 0, 0, 14),
            child: _HeroCarousel(
              controller: _heroController,
              subjects: heroSubjects,
              index: heroIndex,
              onChanged: (index) => setState(() => _heroIndex = index),
              onOpen: widget.onOpen,
              onDotTap: _animateToHero,
            ),
          ),
        ),
        if (compact)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 0, 0, 12),
              child: const _MobileQuickActions(),
            ),
          ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(0, 0, 0, 10),
            child: SizedBox(
              height: 74,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemBuilder: (context, index) {
                  final item = shortcuts[index];
                  return _CategoryShortcut(
                    label: item.label,
                    subtitle: item.subtitle,
                    bannerUrl: item.subject?.bannerUrl,
                    posterUrl: item.subject?.coverUrl,
                    onTap: () => context.push(item.route),
                  );
                },
                separatorBuilder: (context, index) => const SizedBox(width: 10),
                itemCount: shortcuts.length,
              ),
            ),
          ),
        ),
        const SliverToBoxAdapter(
          child: SectionTitle(title: '今日推荐', icon: Icons.local_fire_department),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 10)),
        _SubjectGridSliver(
          subjects: widget.feed.recommended,
          onOpen: widget.onOpen,
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 20)),
        const SliverToBoxAdapter(
          child: SectionTitle(title: '新番更新', icon: Icons.update),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 10)),
        _SubjectGridSliver(
          subjects: widget.feed.recent,
          onOpen: widget.onOpen,
          landscape: true,
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 120)),
      ],
    );
  }

  List<AnimeSubject> _heroSubjects(AnimeHomeFeed feed) {
    final candidates = _uniqueSubjectList([
      feed.hero,
      ...feed.recommended,
      ...feed.recent,
    ]);
    final withBanners = candidates
        .where((item) => (item.bannerUrl ?? '').isNotEmpty)
        .toList(growable: false);
    return [
      ...withBanners,
      ...candidates.where((item) => !withBanners.contains(item)),
    ].take(7).toList(growable: false);
  }

  List<_HomeShortcutData> _shortcuts(AnimeHomeFeed feed) {
    final anime = _uniqueSubjectList([
      feed.hero,
      ...feed.recent,
      ...feed.recommended,
    ]);
    final series = _uniqueSubjectList(feed.seriesHighlights);
    final movies = _uniqueSubjectList(feed.movieHighlights);
    final used = <String>{};
    AnimeSubject? pick(
      List<AnimeSubject> candidates, {
      bool Function(AnimeSubject subject)? where,
    }) {
      if (candidates.isEmpty) return null;
      final offset = (DateTime.now().day + used.length * 5) % candidates.length;
      final rotated = [...candidates.skip(offset), ...candidates.take(offset)];
      for (final item in rotated) {
        final key = '${item.source}:${item.id}';
        if (used.contains(key) || (where != null && !where(item))) continue;
        used.add(key);
        return item;
      }
      for (final item in rotated) {
        final key = '${item.source}:${item.id}';
        if (used.add(key)) return item;
      }
      return null;
    }

    bool hasCategory(AnimeSubject item, Iterable<String> values) {
      final text = [
        item.title,
        item.status,
        ...item.categories.map((category) => category.name),
      ].join(' ').toLowerCase();
      return values.any((value) => text.contains(value.toLowerCase()));
    }

    return [
      _HomeShortcutData(
        label: '番剧',
        subtitle: '本季热门与近期更新',
        route: '/anime',
        subject: pick(anime),
      ),
      _HomeShortcutData(
        label: '剧集',
        subtitle: '全球热门电视剧',
        route: '/series',
        subject: pick(series),
      ),
      _HomeShortcutData(
        label: '电影',
        subtitle: '热门电影与公开原片',
        route: '/movies',
        subject: pick(movies),
      ),
      _HomeShortcutData(
        label: '动漫电影',
        subtitle: '动画长片与剧场版',
        route: '/movies',
        subject: pick(
          movies,
          where: (item) => hasCategory(item, const ['animation', '动画']),
        ),
      ),
      _HomeShortcutData(
        label: '纪录片',
        subtitle: '纪录影像与公开馆藏',
        route: '/movies',
        subject: pick(
          movies,
          where: (item) =>
              hasCategory(item, const ['documentary', '纪录', 'archive']),
        ),
      ),
      _HomeShortcutData(
        label: '综艺',
        subtitle: '真人秀与娱乐节目',
        route: '/series',
        subject: pick(
          series,
          where: (item) =>
              hasCategory(item, const ['reality', 'talk', 'game show', '综艺']),
        ),
      ),
    ];
  }

  void _animateToHero(int index) {
    if (!_heroController.hasClients) return;
    _heroController.animateToPage(
      index,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }
}

class _CategoryShortcut extends StatelessWidget {
  const _CategoryShortcut({
    required this.label,
    required this.subtitle,
    required this.bannerUrl,
    required this.posterUrl,
    required this.onTap,
  });

  final String label;
  final String subtitle;
  final String? bannerUrl;
  final String? posterUrl;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 172,
        child: AppPanel(
          padding: EdgeInsets.zero,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(
              fit: StackFit.expand,
              children: [
                BackdropArt(
                  bannerUrl: bannerUrl,
                  posterUrl: posterUrl,
                  title: label,
                ),
                const DecoratedBox(
                  decoration: BoxDecoration(color: Color(0xAA090D18)),
                ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: AppColors.text,
                              fontWeight: FontWeight.w900,
                            ),
                      ),
                      const SizedBox(height: 2),
                      Flexible(
                        child: Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: AppColors.muted),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HomeShortcutData {
  const _HomeShortcutData({
    required this.label,
    required this.subtitle,
    required this.route,
    required this.subject,
  });

  final String label;
  final String subtitle;
  final String route;
  final AnimeSubject? subject;
}

class _MobileQuickActions extends StatelessWidget {
  const _MobileQuickActions();

  @override
  Widget build(BuildContext context) {
    final items = [
      _MobileQuickAction(
        icon: Icons.explore_outlined,
        label: '番剧',
        onTap: () => context.push('/anime'),
      ),
      _MobileQuickAction(
        icon: Icons.calendar_month_outlined,
        label: '追番',
        onTap: () => context.push('/schedule'),
      ),
      _MobileQuickAction(
        icon: Icons.history_rounded,
        label: '历史',
        onTap: () => context.push('/history'),
      ),
      _MobileQuickAction(
        icon: Icons.movie_outlined,
        label: '电影',
        onTap: () => context.push('/movies'),
      ),
    ];
    return SizedBox(
      height: 76,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: items.length,
        separatorBuilder: (context, index) => const SizedBox(width: 10),
        itemBuilder: (context, index) => items[index],
      ),
    );
  }
}

class _MobileQuickAction extends StatelessWidget {
  const _MobileQuickAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: AppPanel(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        color: AppColors.panelHigh,
        child: SizedBox(
          width: 68,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: colors.onSurface, size: 24),
              const SizedBox(height: 6),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: colors.onSurface,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _IndexTab extends StatelessWidget {
  const _IndexTab({
    required this.subjects,
    required this.showFilters,
    required this.type,
    required this.language,
    required this.year,
    required this.onToggleFilters,
    required this.onTypeChanged,
    required this.onLanguageChanged,
    required this.onYearChanged,
    required this.onOpen,
  });

  final List<AnimeSubject> subjects;
  final bool showFilters;
  final String type;
  final String language;
  final String year;
  final VoidCallback onToggleFilters;
  final ValueChanged<String> onTypeChanged;
  final ValueChanged<String> onLanguageChanged;
  final ValueChanged<String> onYearChanged;
  final ValueChanged<AnimeSubject> onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final filtered = subjects.where((subject) {
      final typeOk =
          type == '全部' || subject.categories.any((item) => item.name == type);
      final languageOk = language == '全部' || subject.language == language;
      final yearOk = year == '全部' || subject.year == year.replaceAll('年', '');
      return typeOk && languageOk && yearOk;
    }).toList();
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: AppPanel(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
            child: Column(
              children: [
                InkWell(
                  onTap: onToggleFilters,
                  borderRadius: BorderRadius.circular(8),
                  child: Row(
                    children: [
                      Icon(Icons.tune, color: scheme.onSurface, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '类型 · 语言 · 年份',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                color: scheme.onSurface,
                                fontWeight: FontWeight.w800,
                              ),
                        ),
                      ),
                      Icon(
                        showFilters
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                        color: scheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
                if (showFilters)
                  _FilterPanel(
                    type: type,
                    language: language,
                    year: year,
                    onTypeChanged: onTypeChanged,
                    onLanguageChanged: onLanguageChanged,
                    onYearChanged: onYearChanged,
                  ),
              ],
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 14)),
        _SubjectGridSliver(subjects: filtered, onOpen: onOpen),
        const SliverToBoxAdapter(child: SizedBox(height: 120)),
      ],
    );
  }
}

class _SubjectGrid extends StatelessWidget {
  const _SubjectGrid({
    required this.subjects,
    required this.onOpen,
    this.landscape = false,
  });

  final List<AnimeSubject> subjects;
  final ValueChanged<AnimeSubject> onOpen;
  final bool landscape;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(0, 12, 8, 120),
      gridDelegate: _gridDelegate(context, landscape: landscape),
      itemCount: subjects.length,
      itemBuilder: (context, index) {
        final subject = subjects[index];
        return PosterCard(
          subject: _publicSubjectMetadata(context, subject),
          landscape: landscape,
          badge: landscape ? '有资源' : _publicMetadataValue(subject.status),
          onTap: () => onOpen(subject),
        );
      },
    );
  }
}

class _SubjectGridSliver extends StatelessWidget {
  const _SubjectGridSliver({
    required this.subjects,
    required this.onOpen,
    this.landscape = false,
    this.showPlaybackAvailability = false,
  });

  final List<AnimeSubject> subjects;
  final ValueChanged<AnimeSubject> onOpen;
  final bool landscape;
  final bool showPlaybackAvailability;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 760;
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(0, 0, compact ? 0 : 8, 0),
      sliver: SliverGrid(
        gridDelegate: _gridDelegate(context, landscape: !compact && landscape),
        delegate: SliverChildBuilderDelegate((context, index) {
          final subject = subjects[index];
          return PosterCard(
            subject: _publicSubjectMetadata(context, subject),
            landscape: !compact && landscape,
            badge: showPlaybackAvailability
                ? subjectPlaybackLabel(subject)
                : null,
            onTap: () => onOpen(subject),
          );
        }, childCount: subjects.length),
      ),
    );
  }
}

class _TileCloud<T> extends StatelessWidget {
  const _TileCloud({
    required this.items,
    required this.labelOf,
    required this.imageOf,
    required this.onTap,
  });

  final List<T> items;
  final String Function(T item) labelOf;
  final String? Function(T item) imageOf;
  final ValueChanged<T> onTap;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(0, 8, 8, 120),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: (MediaQuery.sizeOf(context).width / 160).floor().clamp(
          2,
          6,
        ),
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 2.35,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return InkWell(
          onTap: () => onTap(item),
          borderRadius: BorderRadius.circular(8),
          child: AppPanel(
            padding: EdgeInsets.zero,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  PosterArt(coverUrl: imageOf(item), title: labelOf(item)),
                  const DecoratedBox(
                    decoration: BoxDecoration(color: Color(0xAA090D18)),
                  ),
                  Align(
                    alignment: Alignment.bottomLeft,
                    child: Padding(
                      padding: const EdgeInsets.all(7),
                      child: Text(
                        labelOf(item),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _HeroCarousel extends StatelessWidget {
  const _HeroCarousel({
    required this.controller,
    required this.subjects,
    required this.index,
    required this.onChanged,
    required this.onOpen,
    required this.onDotTap,
  });

  final PageController controller;
  final List<AnimeSubject> subjects;
  final int index;
  final ValueChanged<int> onChanged;
  final ValueChanged<AnimeSubject> onOpen;
  final ValueChanged<int> onDotTap;

  @override
  Widget build(BuildContext context) {
    final safeSubjects = subjects.isEmpty ? [_fallbackHeroSubject] : subjects;
    final compact = MediaQuery.sizeOf(context).width < 760;
    return SizedBox(
      height: compact ? 232 : 296,
      child: AppPanel(
        padding: EdgeInsets.zero,
        borderColor: AppColors.borderBright,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            fit: StackFit.expand,
            children: [
              PageView.builder(
                controller: controller,
                itemCount: safeSubjects.length,
                onPageChanged: onChanged,
                itemBuilder: (context, page) {
                  final subject = safeSubjects[page];
                  return _HeroBannerSlide(
                    subject: subject,
                    onTap: () => onOpen(subject),
                  );
                },
              ),
              Positioned(
                left: 24,
                bottom: 18,
                child: Row(
                  children: [
                    for (var i = 0; i < safeSubjects.length; i++)
                      InkWell(
                        onTap: () => onDotTap(i),
                        borderRadius: BorderRadius.circular(6),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          width: i == index ? 34 : 14,
                          height: 8,
                          margin: const EdgeInsets.only(right: 6),
                          alignment: Alignment.center,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: i == index
                                  ? AppColors.primary
                                  : AppColors.borderBright,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const SizedBox.expand(),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (safeSubjects.length > 1)
                Positioned(
                  right: compact ? 12 : 18,
                  top: compact ? 14 : null,
                  bottom: compact ? null : 16,
                  child: Row(
                    children: [
                      _HeroArrowButton(
                        icon: Icons.chevron_left_rounded,
                        tooltip: '上一张',
                        onTap: () => onDotTap(
                          index == 0 ? safeSubjects.length - 1 : index - 1,
                        ),
                      ),
                      const SizedBox(width: 8),
                      _HeroArrowButton(
                        icon: Icons.chevron_right_rounded,
                        tooltip: '下一张',
                        onTap: () => onDotTap(
                          index == safeSubjects.length - 1 ? 0 : index + 1,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeroArrowButton extends StatelessWidget {
  const _HeroArrowButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppColors.panelHigh.withValues(alpha: 0.86),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.borderBright),
          ),
          child: SizedBox(
            width: 38,
            height: 38,
            child: Icon(icon, size: 24, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

class _HeroBannerSlide extends StatelessWidget {
  const _HeroBannerSlide({required this.subject, required this.onTap});

  final AnimeSubject subject;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final displaySubject = _publicSubjectMetadata(context, subject);
    final categoryText = displaySubject.categories
        .map((item) => item.name)
        .where((item) => item.trim().isNotEmpty)
        .take(2)
        .join('/');
    final isMovie = subject.platform.toLowerCase().contains('movie');
    final isAnime = subjectContentTypeOf(subject) == SubjectContentType.anime;
    final preferChinese = _preferChineseMetadata(context);
    final metadata = [
      if (subject.year != '未知') subject.year,
      if (displaySubject.region.isNotEmpty) displaySubject.region,
      if (categoryText.isNotEmpty) categoryText,
      if (isMovie)
        '电影'
      else if (subject.totalEpisodes > 0)
        '全${subject.totalEpisodes}集',
    ].join(' · ');
    final hasOriginalTitle =
        (!isAnime || !preferChinese) &&
        subject.originalTitle.trim().isNotEmpty &&
        subject.originalTitle.trim() != subject.title.trim();
    final directPlayable = hasKnownDirectPlayback(subject);
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 520;
        final contentWidth = (constraints.maxWidth - 48)
            .clamp(220.0, 520.0)
            .toDouble();
        return InkWell(
          onTap: onTap,
          child: Stack(
            fit: StackFit.expand,
            children: [
              BackdropArt(
                bannerUrl: subject.bannerUrl,
                posterUrl: subject.coverUrl,
                title: subject.title,
              ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Color(0xF0060912),
                      Color(0x88060912),
                      Color(0x22060912),
                    ],
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                  ),
                ),
              ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.transparent, Color(0xDD060912)],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                ),
              ),
              Positioned(
                left: compact ? 18 : 24,
                top: compact ? 18 : 24,
                bottom: compact ? 18 : 24,
                width: compact ? constraints.maxWidth - 36 : contentWidth,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        SmallBadge(
                          label: displaySubject.platform,
                          active: true,
                        ),
                        if (displaySubject.status.isNotEmpty)
                          SmallBadge(label: displaySubject.status),
                        if (directPlayable)
                          const SmallBadge(label: '可播放', active: true),
                      ],
                    ),
                    const Spacer(),
                    Text(
                      subject.title,
                      maxLines: compact ? 2 : 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          (compact
                                  ? Theme.of(context).textTheme.headlineMedium
                                  : Theme.of(context).textTheme.displaySmall)
                              ?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w900,
                              ),
                    ),
                    if (!compact && hasOriginalTitle) ...[
                      const SizedBox(height: 4),
                      Text(
                        subject.originalTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AppColors.muted,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Text(
                      metadata,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: AppColors.muted,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      displaySubject.summary,
                      maxLines: compact ? 2 : 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: AppColors.text,
                        height: 1.45,
                      ),
                    ),
                    SizedBox(height: compact ? 12 : 20),
                    AccentButton(
                      icon: Icons.play_arrow_rounded,
                      label: '查看详情',
                      onTap: onTap,
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _FilterPanel extends StatelessWidget {
  const _FilterPanel({
    required this.type,
    required this.language,
    required this.year,
    required this.onTypeChanged,
    required this.onLanguageChanged,
    required this.onYearChanged,
  });

  final String type;
  final String language;
  final String year;
  final ValueChanged<String> onTypeChanged;
  final ValueChanged<String> onLanguageChanged;
  final ValueChanged<String> onYearChanged;

  @override
  Widget build(BuildContext context) {
    final years = [
      '全部',
      for (var y = DateTime.now().year; y >= 2013; y--) '$y年',
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      child: Column(
        children: [
          _FilterRow(
            label: '类型',
            values: const ['全部', '动画', '正篇', '剧场版', '特别篇', '奇幻', '喜剧', '冒险'],
            selected: type,
            onChanged: onTypeChanged,
          ),
          _FilterRow(
            label: '语言',
            values: const ['全部', '日语', '国语', '英语', '韩语', '其他'],
            selected: language,
            onChanged: onLanguageChanged,
          ),
          _FilterRow(
            label: '年份',
            values: years,
            selected: year,
            onChanged: onYearChanged,
          ),
        ],
      ),
    );
  }
}

class _FilterRow extends StatelessWidget {
  const _FilterRow({
    required this.label,
    required this.values,
    required this.selected,
    required this.onChanged,
  });

  final String label;
  final List<String> values;
  final String selected;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final options = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final value in values)
          FilterChip(
            label: Text(value),
            selected: selected == value,
            onSelected: (_) => onChanged(value),
            showCheckmark: false,
            backgroundColor: scheme.surfaceContainerHigh,
            selectedColor: scheme.primary,
            side: BorderSide(
              color: selected == value ? scheme.primary : scheme.outlineVariant,
              width: selected == value ? 1.4 : 1,
            ),
            labelStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: selected == value ? scheme.onPrimary : scheme.onSurface,
              fontWeight: selected == value ? FontWeight.w900 : FontWeight.w700,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final labelChip = Container(
            constraints: const BoxConstraints(minWidth: 52, minHeight: 34),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: scheme.outline),
            ),
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: scheme.onSurface,
                fontWeight: FontWeight.w900,
              ),
            ),
          );
          if (constraints.maxWidth < 620) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [labelChip, const SizedBox(height: 9), options],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              labelChip,
              const SizedBox(width: 12),
              Expanded(child: options),
            ],
          );
        },
      ),
    );
  }
}

class _DetailHero extends StatelessWidget {
  const _DetailHero({
    super.key,
    required this.subject,
    required this.following,
    required this.collected,
    required this.onPlay,
    required this.onFollowing,
    required this.onCollect,
    required this.onDownload,
  });

  final AnimeSubject subject;
  final bool following;
  final bool collected;
  final VoidCallback? onPlay;
  final VoidCallback onFollowing;
  final VoidCallback onCollect;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    final directlyPlayable = hasKnownDirectPlayback(subject);
    final displaySubject = _publicSubjectMetadata(context, subject);
    final metadata = [
      subject.year,
      if (displaySubject.region.isNotEmpty) displaySubject.region,
      if (subject.totalEpisodes > 0) '${subject.totalEpisodes}集全',
    ].join('  |  ');
    Widget badges() => Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        SmallBadge(
          label: subjectPlaybackLabel(subject),
          active: directlyPlayable,
        ),
        SmallBadge(
          label: subject.ratingScore == null
              ? '暂无评分'
              : '★ ${subject.ratingScore!.toStringAsFixed(1)}',
          active: true,
        ),
        SmallBadge(label: displaySubject.platform),
        if (displaySubject.status.isNotEmpty)
          SmallBadge(label: displaySubject.status),
      ],
    );

    Widget actions({required bool compact}) => Wrap(
      spacing: 10,
      runSpacing: 8,
      children: [
        AccentButton(
          icon: Icons.play_arrow_rounded,
          label: directlyPlayable ? '立即播放' : '查找自定义线路',
          onTap: onPlay,
          compact: compact,
        ),
        AccentButton(
          icon: following ? Icons.check_rounded : Icons.add_rounded,
          label: following ? '已追番' : '追番',
          filled: false,
          onTap: onFollowing,
          compact: compact,
        ),
        AccentButton(
          icon: collected ? Icons.favorite : Icons.favorite_border,
          label: collected ? '已收藏' : '收藏',
          filled: false,
          onTap: onCollect,
          compact: compact,
        ),
        AccentButton(
          icon: Icons.download_outlined,
          label: '下载',
          filled: false,
          onTap: onDownload,
          compact: compact,
        ),
      ],
    );

    Widget information({required bool compact}) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        badges(),
        const SizedBox(height: 12),
        Text(
          subject.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style:
              (compact
                      ? Theme.of(context).textTheme.headlineMedium
                      : Theme.of(context).textTheme.displaySmall)
                  ?.copyWith(
                    color: AppColors.text,
                    fontWeight: FontWeight.w900,
                  ),
        ),
        const SizedBox(height: 8),
        Text(
          metadata,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: AppColors.muted,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          displaySubject.summary,
          maxLines: compact ? 2 : 3,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: AppColors.text, height: 1.45),
        ),
        const Spacer(),
        actions(compact: compact),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 720;
        return SizedBox(
          height: compact ? 360 : 292,
          child: AppPanel(
            padding: EdgeInsets.zero,
            borderColor: AppColors.borderBright,
            color: AppColors.panel.withValues(alpha: 0.72),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Positioned.fill(
                    child: BackdropArt(
                      bannerUrl: subject.bannerUrl,
                      posterUrl: subject.coverUrl,
                      title: subject.title,
                    ),
                  ),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: compact
                            ? const [Color(0xE6060912), Color(0xB8060912)]
                            : const [
                                Color(0xF2060912),
                                Color(0xAA060912),
                                Color(0x44060912),
                              ],
                        begin: compact
                            ? Alignment.bottomCenter
                            : Alignment.centerLeft,
                        end: compact
                            ? Alignment.topCenter
                            : Alignment.centerRight,
                      ),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.all(compact ? 16 : 22),
                    child: compact
                        ? information(compact: true)
                        : Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 154,
                                height: 220,
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: PosterArt(
                                    coverUrl: subject.coverUrl,
                                    title: subject.title,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 22),
                              Expanded(child: information(compact: false)),
                            ],
                          ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _DetailRightRail extends StatelessWidget {
  const _DetailRightRail({required this.bundle, required this.onOpen});

  final AnimeDetailBundle bundle;
  final ValueChanged<AnimeRecommendation> onOpen;

  @override
  Widget build(BuildContext context) {
    final score = bundle.subject.ratingScore;
    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 6, 20, 24),
      children: [
        AppPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionTitle(title: '评分详情'),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    score?.toStringAsFixed(1) ?? '-',
                    style: Theme.of(context).textTheme.displaySmall?.copyWith(
                      color: AppColors.primary,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${bundle.subject.ratingTotal ?? 0}人评分',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              for (var i = 5; i >= 1; i--) ...[
                Row(
                  children: [
                    SizedBox(
                      width: 28,
                      child: Text(
                        '$i星',
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
                      ),
                    ),
                    Expanded(
                      child: LinearProgressIndicator(
                        value: i == 5 ? 0.76 : (6 - i) * 0.05,
                        minHeight: 5,
                        borderRadius: BorderRadius.circular(5),
                        backgroundColor: AppColors.border,
                        color: AppColors.primary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),
        AppPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionTitle(title: '追番进度'),
              const SizedBox(height: 10),
              Text(
                '已连到第 ${bundle.episodes.isEmpty ? 0 : bundle.episodes.first.number} 集\n每周更新信息已自动整理。',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.muted,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        AppPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionTitle(title: '简介'),
              const SizedBox(height: 10),
              Text(
                _publicSubjectMetadata(context, bundle.subject).summary,
                maxLines: 7,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.muted,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        AppPanel(
          child: Column(
            children: [
              const SectionTitle(title: '大家都在看'),
              const SizedBox(height: 8),
              for (final item in bundle.recommendations.take(5))
                CompactSubjectRow(
                  subject: _publicSubjectMetadata(context, item.subject),
                  trailing:
                      item.subject.ratingScore?.toStringAsFixed(1) ??
                      item.relation,
                  onTap: () => onOpen(item),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DetailTabs extends StatelessWidget {
  const _DetailTabs();

  @override
  Widget build(BuildContext context) {
    return AppPanel(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: AppColors.panel.withValues(alpha: 0.86),
      child: const TabBar(
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        dividerColor: Colors.transparent,
        tabs: [
          Tab(icon: Icon(Icons.article_outlined), text: '简介'),
          Tab(icon: Icon(Icons.grid_view_rounded), text: '选集'),
          Tab(icon: Icon(Icons.person_outline), text: '角色'),
          Tab(icon: Icon(Icons.badge_outlined), text: '制作人员'),
          Tab(icon: Icon(Icons.star_outline), text: '推荐'),
        ],
      ),
    );
  }
}

class _DetailTabsHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _DetailTabsHeaderDelegate();

  static const _extent = 84.0;

  @override
  double get minExtent => _extent;

  @override
  double get maxExtent => _extent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor.withValues(alpha: 0.96),
      child: const Padding(
        padding: EdgeInsets.only(bottom: 12),
        child: _DetailTabs(),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _DetailTabsHeaderDelegate oldDelegate) => false;
}

class _DetailInfo extends StatelessWidget {
  const _DetailInfo({required this.bundle});

  final AnimeDetailBundle bundle;

  @override
  Widget build(BuildContext context) {
    final subject = _publicSubjectMetadata(context, bundle.subject);
    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 0, 8, 120),
      children: [
        AppPanel(
          child: Text(
            subject.summary,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: AppColors.text,
              height: 1.45,
            ),
          ),
        ),
        const SizedBox(height: 18),
        const _BlockTitle('分类'),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: [
            for (final category in subject.categories)
              _Chip(label: category.name, selected: true),
          ],
        ),
        const SizedBox(height: 18),
        const _BlockTitle('标签'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final tag in subject.tags.take(32))
              _Chip(
                label: tag.count > 0 ? '${tag.name}  ${tag.count}' : tag.name,
              ),
          ],
        ),
      ],
    );
  }
}

class _EpisodeGrid extends StatelessWidget {
  const _EpisodeGrid({required this.bundle, required this.onPlay});

  final AnimeDetailBundle bundle;
  final ValueChanged<AnimeEpisode> onPlay;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      key: const ValueKey('detailEpisodeGrid'),
      padding: const EdgeInsets.fromLTRB(0, 0, 8, 120),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: (MediaQuery.sizeOf(context).width / 252).floor().clamp(
          2,
          6,
        ),
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 4.2,
      ),
      itemCount: bundle.episodes.length,
      itemBuilder: (context, index) {
        final episode = bundle.episodes[index];
        return InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => onPlay(episode),
          child: AppPanel(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: index == 0
                ? Theme.of(context).colorScheme.primaryContainer
                : AppColors.panel,
            borderColor: index == 0
                ? Theme.of(context).colorScheme.primary
                : AppColors.border,
            child: Row(
              children: [
                Text(
                  '${episode.number}',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: index == 0
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    episode.title.trim().isEmpty
                        ? '第${episode.number}集'
                        : episode.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Icon(
                  Icons.play_arrow_rounded,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _CharacterGrid extends StatelessWidget {
  const _CharacterGrid({required this.items});

  final List<AnimeCharacter> items;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(0, 0, 8, 120),
      gridDelegate: _peopleDelegate(context),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return _PersonTile(
          imageUrl: item.imageUrl,
          name: item.name,
          role: item.relation,
          line: 'CV: ${item.cv}',
        );
      },
    );
  }
}

class _StaffGrid extends StatelessWidget {
  const _StaffGrid({required this.items});

  final List<AnimeStaff> items;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(0, 0, 8, 120),
      gridDelegate: _peopleDelegate(context),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return _PersonTile(
          imageUrl: item.imageUrl,
          name: item.name,
          role: item.role,
          line: item.career,
        );
      },
    );
  }
}

class _RecommendationGrid extends StatelessWidget {
  const _RecommendationGrid({required this.items, required this.onOpen});

  final List<AnimeRecommendation> items;
  final ValueChanged<AnimeRecommendation> onOpen;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(0, 0, 8, 120),
      gridDelegate: _gridDelegate(context),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return PosterCard(
          subject: _publicSubjectMetadata(context, item.subject),
          badge: _publicMetadataValue(item.relation),
          onTap: () => onOpen(item),
        );
      },
    );
  }
}

class _PersonTile extends StatelessWidget {
  const _PersonTile({
    required this.imageUrl,
    required this.name,
    required this.role,
    required this.line,
  });

  final String? imageUrl;
  final String name;
  final String role;
  final String line;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: AppPanel(
            padding: EdgeInsets.zero,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: PosterArt(coverUrl: imageUrl, title: name),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(color: AppColors.text),
        ),
        Text(
          role,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        Text(
          line,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
        ),
      ],
    );
  }
}

class _BlurredBackdrop extends StatelessWidget {
  const _BlurredBackdrop({required this.subject});

  final AnimeSubject subject;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (subject.bannerUrl != null || subject.coverUrl != null)
            ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: PosterArt(
                coverUrl: subject.bannerUrl,
                fallbackCoverUrl: subject.coverUrl,
                title: subject.title,
                fit: BoxFit.cover,
                allowHtmlFallback: false,
              ),
            )
          else
            const ColoredBox(color: AppColors.bg),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xAA060912), Color(0xF3060912), AppColors.bg],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BlockTitle extends StatelessWidget {
  const _BlockTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, this.selected = false});

  final String label;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: selected
            ? Theme.of(context).colorScheme.primaryContainer
            : Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: selected
                ? Theme.of(context).colorScheme.onPrimaryContainer
                : Theme.of(context).colorScheme.onSurface,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                color: Theme.of(context).colorScheme.primary,
                size: 42,
              ),
              const SizedBox(height: 14),
              Text(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.white60,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

void _showToast(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

List<AnimeSubject> _uniqueSubjectList(Iterable<AnimeSubject> subjects) {
  final seen = <String>{};
  final result = <AnimeSubject>[];
  for (final subject in subjects) {
    final kind = subjectContentTypeOf(subject).name;
    final normalized =
        (subject.originalTitle.trim().isNotEmpty
                ? subject.originalTitle
                : subject.title)
            .toLowerCase()
            .replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
    final key = '$kind:${subject.year}:$normalized';
    if (seen.add(key)) result.add(subject);
  }
  return result;
}

SubjectContentType _subjectContentTypeFor(MetadataHubKind kind) {
  return switch (kind) {
    MetadataHubKind.anime => SubjectContentType.anime,
    MetadataHubKind.series => SubjectContentType.series,
    MetadataHubKind.movie => SubjectContentType.movie,
  };
}

const _fallbackHeroSubject = AnimeSubject(
  id: -1,
  title: '今日推荐',
  originalTitle: 'Daily Picks',
  summary: '推荐内容正在准备中，稍后会自动刷新。',
  coverUrl: null,
  bannerUrl: null,
  date: null,
  platform: 'TV',
  language: '未知',
  region: '未知',
  status: '更新中',
  categories: [],
  tags: [],
  totalEpisodes: 0,
);

extension _FirstOrNull<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

class _StaticFilterRail extends StatelessWidget {
  const _StaticFilterRail({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 6, 20, 24),
      children: [
        AppPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionTitle(title: title == '筛选' ? '类型筛选' : '$title筛选'),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: const [
                  SmallBadge(label: '全部', active: true),
                  SmallBadge(label: '动画'),
                  SmallBadge(label: '剧场版'),
                  SmallBadge(label: '奇幻'),
                  SmallBadge(label: '冒险'),
                  SmallBadge(label: '日语'),
                  SmallBadge(label: '2020s'),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        const AppPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionTitle(title: '排序'),
              SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  SmallBadge(label: '综合', active: true),
                  SmallBadge(label: '评分'),
                  SmallBadge(label: '更新'),
                  SmallBadge(label: '热度'),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SearchRightRail extends StatelessWidget {
  const _SearchRightRail({required this.keyword});

  final String keyword;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 6, 20, 24),
      children: [
        AppPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionTitle(title: '热门搜索'),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  SmallBadge(label: keyword, active: true),
                  const SmallBadge(label: '三体'),
                  const SmallBadge(label: '人工智能'),
                  const SmallBadge(label: '时间旅行'),
                  const SmallBadge(label: '宇宙探索'),
                  const SmallBadge(label: '末日生存'),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        const AppPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionTitle(title: '类型筛选'),
              SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  SmallBadge(label: '科幻', active: true),
                  SmallBadge(label: '冒险'),
                  SmallBadge(label: '动画'),
                  SmallBadge(label: '剧集'),
                  SmallBadge(label: '电影'),
                  SmallBadge(label: '高分'),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _WeekCalendarStrip extends StatelessWidget {
  const _WeekCalendarStrip({
    required this.schedule,
    required this.selectedIndex,
    required this.onSelected,
  });

  final Map<int, List<AnimeSubject>> schedule;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final days = SchedulePage._weekdays;
    return SizedBox(
      height: 130,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: days.length,
        separatorBuilder: (context, index) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final day = days[index];
          return Semantics(
            key: ValueKey('schedule-day-$index'),
            button: true,
            selected: index == selectedIndex,
            child: SizedBox(
              width: 210,
              child: InkWell(
                onTap: () => onSelected(index),
                borderRadius: BorderRadius.circular(8),
                child: _DayCard(
                  label: day.$2,
                  subjects: schedule[day.$1] ?? const [],
                  active: index == selectedIndex,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _DayCard extends StatelessWidget {
  const _DayCard({
    required this.label,
    required this.subjects,
    required this.active,
  });

  final String label;
  final List<AnimeSubject> subjects;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final subject = subjects.firstOrNull;
    return AppPanel(
      padding: const EdgeInsets.all(12),
      borderColor: active
          ? Theme.of(context).colorScheme.primary
          : AppColors.border,
      color: active
          ? Theme.of(context).colorScheme.primaryContainer
          : AppColors.panel,
      child: Row(
        children: [
          if (subject != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 58,
                height: 86,
                child: PosterArt(
                  coverUrl: subject.coverUrl,
                  title: subject.title,
                ),
              ),
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: Theme.of(context).colorScheme.onSurface,
                              fontWeight: FontWeight.w900,
                            ),
                      ),
                    ),
                    Text(
                      '${subjects.length} 部更新',
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  subject?.title ?? '暂无更新',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.muted,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ScheduleRightRail extends StatelessWidget {
  const _ScheduleRightRail({required this.state});

  final AnimeState state;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 6, 20, 24),
      children: [
        AppPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionTitle(title: '我的追番'),
              const SizedBox(height: 12),
              if (state.following.isEmpty)
                Text(
                  '还没有追番，打开详情页可加入追番列表。',
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: AppColors.muted),
                )
              else
                for (final item in state.following.take(5))
                  CompactSubjectRow(
                    subject: _publicSubjectMetadata(context, item.subject),
                    trailing: '提醒',
                  ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        AppPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionTitle(title: '追番状态统计'),
              const SizedBox(height: 16),
              Row(
                children: [
                  _StatBlock(label: '已追', value: '${state.following.length}'),
                  const SizedBox(width: 10),
                  _StatBlock(label: '想看', value: '${state.favorites.length}'),
                  const SizedBox(width: 10),
                  _StatBlock(label: '历史', value: '${state.history.length}'),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StatBlock extends StatelessWidget {
  const _StatBlock({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.panelHigh,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.border),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(
            children: [
              Text(
                value,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: AppColors.text,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

SliverGridDelegateWithFixedCrossAxisCount _gridDelegate(
  BuildContext context, {
  bool landscape = false,
}) {
  final width = MediaQuery.sizeOf(context).width;
  final compact = width < 760;
  final columns = compact
      ? 2
      : landscape
      ? (width / 292).floor().clamp(2, 4)
      : (width / 180).floor().clamp(2, 6);
  return SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: columns,
    mainAxisSpacing: compact ? 10 : 12,
    crossAxisSpacing: compact ? 10 : 12,
    childAspectRatio: compact ? 0.58 : (landscape ? 1.48 : 0.56),
  );
}

SliverGridDelegateWithFixedCrossAxisCount _peopleDelegate(
  BuildContext context,
) {
  final width = MediaQuery.sizeOf(context).width;
  return SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: (width / 180).floor().clamp(2, 7),
    mainAxisSpacing: 14,
    crossAxisSpacing: 12,
    childAspectRatio: 0.72,
  );
}
