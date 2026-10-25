import 'dart:async';
import 'package:flutter/gestures.dart';
import 'dart:math' as math;

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
import 'catalog_controller.dart';
import 'subject_playability.dart';
import 'search_ranking.dart';
import '../shared_ui/skeleton.dart';

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
    platform: _publicPlatformLabel(
      subject.platform,
      fallback: platformFallback,
    ),
    language: subject.language,
    region: _publicMetadataValue(subject.region),
    status: _publicStatusLabel(subject.status),
    categories: [
      for (final item in subject.categories)
        if (tmdbGenreLabel(item.name).isNotEmpty &&
            !_isInternalMetadataLabel(tmdbGenreLabel(item.name)) &&
            (!preferChinese ||
                !isAnime ||
                isLikelyChineseTitle(tmdbGenreLabel(item.name))))
          AnimeCategory(
            name: tmdbGenreLabel(item.name),
            count: item.count,
            imageUrl: item.imageUrl,
          ),
    ],
    tags: [
      for (final item in subject.tags)
        if (tmdbGenreLabel(item.name).isNotEmpty &&
            !_isInternalMetadataLabel(tmdbGenreLabel(item.name)) &&
            (!preferChinese ||
                !isAnime ||
                isLikelyChineseTitle(tmdbGenreLabel(item.name))))
          AnimeTag(
            name: tmdbGenreLabel(item.name),
            count: item.count,
            imageUrl: item.imageUrl,
          ),
    ],
    totalEpisodes: subject.totalEpisodes,
    ratingScore: subject.ratingScore,
    ratingRank: subject.ratingRank,
    ratingTotal: subject.ratingTotal,
    source: subject.source,
  );
}

/// Platform arrives in English from several feeds -- TMDB sends "Movie", TVMaze
/// sends "Scripted", and 14 fallback paths hardcode `platform: 'Scripted'`. The
/// old code only substituted a fallback when the field was *empty*, so a
/// non-empty English token printed as-is on hero badges while the metadata line
/// beside it said 电影.
String _publicPlatformLabel(String raw, {String fallback = ''}) {
  final normalized = raw.trim().toLowerCase().replaceAll(' ', '_');
  const labels = <String, String>{
    'scripted': '剧集',
    'series': '剧集',
    'tv_series': '剧集',
    'tv_show': '剧集',
    'miniseries': '剧集',
    'mini_series': '剧集',
    'documentary': '纪录片',
    'reality': '真人秀',
    'talk_show': '访谈',
    'variety': '综艺',
    'movie': '电影',
    'film': '电影',
    'ova': 'OVA',
    'ona': 'ONA',
    'tv': 'TV',
    'web': '网络',
    'animation': '动画',
  };
  final mapped = labels[normalized];
  if (mapped != null) return mapped;
  return _publicMetadataValue(raw, fallback: fallback);
}

/// Raw feed statuses arrive in English ("aired", "releasing"); the UI
/// speaks Chinese. Unknown values fall through to the generic sanitizer.
String _publicStatusLabel(String raw) {
  final normalized = raw.trim().toLowerCase().replaceAll(' ', '_');
  const labels = <String, String>{
    'aired': '已完结',
    'finished': '已完结',
    'finished_airing': '已完结',
    'complete': '已完结',
    'completed': '已完结',
    'ended': '已完结',
    'airing': '连载中',
    'currently_airing': '连载中',
    'releasing': '连载中',
    'ongoing': '连载中',
    'returning_series': '连载中',
    'upcoming': '即将播出',
    'not_yet_released': '即将播出',
    'not_yet_aired': '即将播出',
    'planned': '即将播出',
    'cancelled': '已取消',
    'canceled': '已取消',
    'hiatus': '休止中',
  };
  return labels[normalized] ?? _publicMetadataValue(raw);
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
          onOpenSuggestion: (subject) => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => DetailPage(subject: subject),
            ),
          ),
          trailing: _HomeToolbar(
            selected: _tab,
            onChanged: (tab) => setState(() => _tab = tab),
            onSchedule: () => context.push('/schedule'),
          ),
          compactAction: AppIconButton(
            icon: Icons.calendar_month_outlined,
            tooltip: '新番时间表',
            onPressed: () => context.push('/schedule'),
          ),
          bottomPlayer: _MiniNowPlaying(
            subject: state.homeFeed.hero,
            progress: _historyPlaybackProgress(state.history),
          ),
          child: _body(
            state.homeFeed,
            personalizedRecommendations:
                state.homePreferences.personalizedRecommendations,
          ),
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

  Widget _body(
    AnimeHomeFeed feed, {
    required bool personalizedRecommendations,
  }) {
    final compact = MediaQuery.sizeOf(context).width < 760;
    final content = switch (_tab) {
      AnimeHomeTab.recent => _RecentTab(
        subjects: feed.recent,
        onOpen: _openDetail,
      ),
      AnimeHomeTab.recommended => _RecommendTab(
        feed: feed,
        personalizedRecommendations: personalizedRecommendations,
        onOpen: _openDetail,
        onRotate: () =>
            ref.read(animeControllerProvider.notifier).rotateRecommendations(),
        onNotInterested: (subject) => ref
            .read(animeControllerProvider.notifier)
            .markRecommendationNotInterested(subject),
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
      padding: EdgeInsets.fromLTRB(
        compact ? 14 : 24,
        12,
        compact ? 14 : 24,
        24,
      ),
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
      // The right rail here used to be _StaticFilterRail: two panels of
      // hardcoded SmallBadge chips with no onTap. They looked like filter and
      // sort controls, could not be operated, and duplicated the real sort
      // dropdown. Dropped rather than left as decoration.
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
    return KeyedSubtree(
      key: const ValueKey('subject-list-loading'),
      child: PosterGridSkeleton(
        count: 12,
        padding: EdgeInsets.fromLTRB(
          compact ? 14 : 24,
          12,
          compact ? 14 : 8,
          24,
        ),
      ),
    );
  }
}

enum MetadataHubKind { anime, series, movie }

enum _PlaybackFilter {
  all('全部'),
  playable('可播放');

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
  CatalogSortMode _sortMode = CatalogSortMode.recommended;
  _PlaybackFilter _playbackFilter = _PlaybackFilter.all;
  Future<List<AnimeSubject>>? _subjectsFuture;
  int _subjectsRequestVersion = 0;
  List<AnimeSubject> _loadedSubjects = const [];
  String? _nextCursor;
  bool _loadingMore = false;
  bool _loadMoreError = false;
  bool _loadMoreCheckScheduled = false;
  bool _pageReadyForMore = false;
  final _scrollController = ScrollController();
  bool get _usesFullCatalog =>
      _sortMode != CatalogSortMode.recommended ||
      _type != '全部' ||
      _language != '全部' ||
      _year != '全部';
  CatalogQuery get _query => CatalogQuery(
    contentType: _subjectContentTypeFor(widget.kind),
    sort: _sortMode,
    genre: _type,
    language: _language,
    year: int.tryParse(_year.replaceAll('年', '')),
  );
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_scheduleLoadMoreCheck);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshSubjectsInBackground();
    });
  }

  @override
  void didUpdateWidget(covariant MetadataHubPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.kind == widget.kind) return;
    _subjectsRequestVersion++;
    _sortMode = CatalogSortMode.recommended;
    _type = _language = _year = '全部';
    _playbackFilter = _PlaybackFilter.all;
    _nextCursor = null;
    _loadedSubjects = const [];
    _loadingMore = false;
    _loadMoreError = false;
    _subjectsFuture = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshSubjectsInBackground();
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
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
          onOpenSuggestion: (subject) => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => DetailPage(subject: subject),
            ),
          ),
          trailing: AppIconButton(
            icon: Icons.refresh_rounded,
            tooltip: '刷新列表',
            onPressed: _reloadSubjects,
          ),
          compactAction: AppIconButton(
            icon: Icons.refresh_rounded,
            tooltip: '刷新列表',
            onPressed: _reloadSubjects,
          ),
          bottomPlayer: _MiniNowPlaying(
            subject: state.homeFeed.hero,
            progress: _historyPlaybackProgress(state.history),
          ),
          child: FutureBuilder<List<AnimeSubject>>(
            future: _subjectsFuture ??= _loadSubjects(ref),
            builder: (context, snapshot) {
              final rawSubjects = snapshot.data ?? const <AnimeSubject>[];
              final subjects = _filterSubjects(rawSubjects);
              final loading =
                  snapshot.connectionState == ConnectionState.waiting &&
                  (!_usesFullCatalog || _loadedSubjects.isEmpty);
              final compact = MediaQuery.sizeOf(context).width < 760;
              _pageReadyForMore =
                  snapshot.connectionState == ConnectionState.done &&
                  !snapshot.hasError;
              if (_pageReadyForMore) _scheduleLoadMoreCheck();
              return NotificationListener<ScrollMetricsNotification>(
                onNotification: (notification) {
                  if (notification.depth == 0 &&
                      notification.metrics.axis == Axis.vertical) {
                    _scheduleLoadMoreCheck();
                  }
                  return false;
                },
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    compact ? 14 : 24,
                    compact ? 0 : 2,
                    compact ? 14 : 24,
                    24,
                  ),
                  child: CustomScrollView(
                    controller: _scrollController,
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
                        child: _CatalogSortControl(
                          selected: _sortMode,
                          onChanged: _selectSortMode,
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
                          onTypeChanged: (value) =>
                              _changeFilters(() => _type = value),
                          onLanguageChanged: (value) =>
                              _changeFilters(() => _language = value),
                          onYearChanged: (value) =>
                              _changeFilters(() => _year = value),
                          onPlaybackFilterChanged: (value) =>
                              setState(() => _playbackFilter = value),
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: SizedBox(height: compact ? 10 : 14),
                      ),
                      if (loading)
                        const SliverToBoxAdapter(
                          child: SizedBox(
                            height: 360,
                            child: PosterGridSkeleton(count: 8),
                          ),
                        )
                      else if (snapshot.hasError)
                        SliverToBoxAdapter(
                          child: Column(
                            children: [
                              const EmptyState(
                                icon: Icons.cloud_off_outlined,
                                title: '片库暂时加载失败',
                                message: '这不代表没有作品。请检查网络后重试。',
                              ),
                              TextButton(
                                onPressed: _reloadSubjects,
                                child: const Text('重试'),
                              ),
                            ],
                          ),
                        )
                      else if (subjects.isEmpty)
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: EmptyState(
                            icon: _icon,
                            title: _nextCursor != null
                                ? '继续查找匹配作品'
                                : '$_title 暂无结果',
                            message: _nextCursor != null
                                ? '正在自动查找后面的结果，请稍候。'
                                : _emptyMessage,
                          ),
                        )
                      else
                        _SubjectGridSliver(
                          subjects: subjects,
                          onOpen: _openDetail,
                          showPlaybackAvailability: true,
                          trailingBuilder:
                              _sortMode == CatalogSortMode.recommended &&
                                  state
                                      .homePreferences
                                      .personalizedRecommendations
                              ? (subject) => _RecommendationCardMenu(
                                  subject: subject,
                                  onNotInterested: () =>
                                      _markMetadataNotInterested(
                                        subject,
                                        rawSubjects,
                                      ),
                                )
                              : null,
                        ),
                      if (!loading && !snapshot.hasError && _nextCursor != null)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: Center(
                              child: _loadMoreError
                                  ? TextButton.icon(
                                      key: const ValueKey('catalog-retry-more'),
                                      onPressed: _loadMore,
                                      icon: const Icon(Icons.refresh_rounded),
                                      label: const Text('加载失败，点击重试'),
                                    )
                                  : _loadingMore
                                  ? const Row(
                                      key: ValueKey('catalog-loading-more'),
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        ),
                                        SizedBox(width: 10),
                                        Text('正在加载'),
                                      ],
                                    )
                                  : const SizedBox(height: 16),
                            ),
                          ),
                        ),
                      const SliverToBoxAdapter(child: SizedBox(height: 120)),
                    ],
                  ),
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
      return '当前筛选条件下没有可播放内容，切回“全部”能看到所有内容。';
    }
    return switch (widget.kind) {
      MetadataHubKind.anime => '这里还没有匹配的番剧，换个筛选条件或稍后刷新试试。',
      MetadataHubKind.series => '当前剧集资料里没有匹配条目，换个分类或年份试试。',
      MetadataHubKind.movie => '当前电影资料里没有匹配条目，换个分类或年份试试。',
    };
  }

  Future<List<AnimeSubject>> _loadSubjects(
    WidgetRef ref, {
    bool waitForRefresh = false,
  }) async {
    _pageReadyForMore = false;
    final controller = ref.read(animeControllerProvider.notifier);
    if (_usesFullCatalog) {
      final version = _subjectsRequestVersion;
      final page = await controller.queryCatalog(_query);
      if (!mounted || version != _subjectsRequestVersion) return const [];
      _nextCursor = page.nextCursor;
      _loadedSubjects = page.subjects;
      return page.subjects;
    }
    _nextCursor = null;
    return switch (widget.kind) {
      MetadataHubKind.anime => controller.discoverSubjects(
        waitForRefresh: waitForRefresh,
        sort: _sortMode,
      ),
      MetadataHubKind.series => controller.seriesSubjects(
        waitForRefresh: waitForRefresh,
        sort: _sortMode,
      ),
      MetadataHubKind.movie => controller.movieSubjects(
        waitForRefresh: waitForRefresh,
        sort: _sortMode,
      ),
    };
  }

  void _changeFilters(VoidCallback change) {
    _subjectsRequestVersion++;
    setState(() {
      change();
      _nextCursor = null;
      _loadedSubjects = const [];
      _loadingMore = false;
      _loadMoreError = false;
      _subjectsFuture = _loadSubjects(ref)..ignore();
    });
  }

  void _selectSortMode(CatalogSortMode value) {
    if (value != _sortMode) _changeFilters(() => _sortMode = value);
  }

  void _scheduleLoadMoreCheck() {
    if (_loadMoreCheckScheduled) return;
    _loadMoreCheckScheduled = true;
    // Defer until layout so short pages and window resizing also load enough
    // results, without calling setState during a scroll-metrics notification.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadMoreCheckScheduled = false;
      if (!mounted ||
          !_pageReadyForMore ||
          !_usesFullCatalog ||
          _nextCursor == null ||
          _loadingMore ||
          _loadMoreError ||
          !_scrollController.hasClients) {
        return;
      }
      final position = _scrollController.position;
      if (position.hasContentDimensions && position.extentAfter <= 480) {
        unawaited(_loadMore());
      }
    });
  }

  Future<void> _loadMore() async {
    final cursor = _nextCursor;
    if (cursor == null || _loadingMore) return;
    final version = _subjectsRequestVersion;
    final query = _query;
    setState(() {
      _loadingMore = true;
      _loadMoreError = false;
    });
    try {
      final page = await ref
          .read(animeControllerProvider.notifier)
          .queryCatalog(query, cursor: cursor);
      if (!mounted || version != _subjectsRequestVersion) return;
      final subjects = <String, AnimeSubject>{
        for (final item in [..._loadedSubjects, ...page.subjects])
          item.identityKey: item,
      }.values.toList(growable: false);
      setState(() {
        _loadedSubjects = subjects;
        _nextCursor = page.nextCursor == cursor ? null : page.nextCursor;
        _loadingMore = false;
        _subjectsFuture = Future.value(subjects);
      });
    } catch (_) {
      if (!mounted || version != _subjectsRequestVersion) return;
      setState(() {
        _loadingMore = false;
        _loadMoreError = true;
      });
    }
  }

  Future<void> _refreshSubjectsInBackground() async {
    if (_usesFullCatalog) return;
    final requestVersion = ++_subjectsRequestVersion;
    try {
      await ref.read(animeControllerProvider.future);
      if (!mounted || requestVersion != _subjectsRequestVersion) return;
      final subjects = await _loadSubjects(ref, waitForRefresh: true);
      if (!mounted || requestVersion != _subjectsRequestVersion) return;
      setState(() {
        _subjectsFuture = Future.value(subjects);
      });
    } catch (_) {
      // Keep the already visible cache or fallback list on refresh failures.
    }
  }

  Future<void> _reloadSubjects() async {
    if (_usesFullCatalog) {
      _changeFilters(() {});
      return;
    }
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
    setState(() {
      _nextCursor = null;
      _loadingMore = false;
      _loadMoreError = false;
      _subjectsFuture = _loadSubjects(ref, waitForRefresh: true)..ignore();
    });
  }

  Future<void> _markMetadataNotInterested(
    AnimeSubject subject,
    List<AnimeSubject> currentSubjects,
  ) async {
    final requestVersion = ++_subjectsRequestVersion;
    final reordered = <AnimeSubject>[
      ...currentSubjects.where((item) => !sameSubjectIdentity(item, subject)),
      subject,
    ];
    setState(() {
      _subjectsFuture = Future.value(reordered);
    });
    try {
      await ref
          .read(animeControllerProvider.notifier)
          .markRecommendationNotInterested(subject);
      if (!mounted || requestVersion != _subjectsRequestVersion) return;
      final refreshed = await _loadSubjects(ref);
      if (!mounted || requestVersion != _subjectsRequestVersion) return;
      setState(() {
        _subjectsFuture = Future.value(refreshed);
      });
    } catch (_) {
      if (!mounted || requestVersion != _subjectsRequestVersion) return;
      setState(() {
        _subjectsFuture = Future.value(currentSubjects);
      });
      _showToast(context, '暂时无法更新推荐偏好');
    }
  }

  List<AnimeSubject> _filterSubjects(List<AnimeSubject> subjects) => subjects
      .where((subject) {
        if (!subjectMatchesContentType(
          subject,
          _subjectContentTypeFor(widget.kind),
        )) {
          return false;
        }
        // Full-catalogue conditions were applied before pagination by the loader.
        // A second approximate tag/title filter here used to discard valid results.
        return _playbackFilter != _PlaybackFilter.playable ||
            hasKnownDirectPlayback(subject);
      })
      .toList(growable: false);

  void _openDetail(AnimeSubject subject) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => DetailPage(subject: subject)),
    );
  }

  void _openSearch(String keyword) {
    final query = keyword.trim();
    if (query.isEmpty) return;
    final scope = switch (widget.kind) {
      MetadataHubKind.anime => SubjectContentType.anime,
      MetadataHubKind.series => SubjectContentType.series,
      MetadataHubKind.movie => SubjectContentType.movie,
    };
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => SearchPage(keyword: query, scope: scope),
      ),
    );
  }
}

class _CatalogSortControl extends StatelessWidget {
  const _CatalogSortControl({required this.selected, required this.onChanged});

  final CatalogSortMode selected;
  final ValueChanged<CatalogSortMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 760;
    if (compact) {
      return AppPanel(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            Icon(Icons.sort_rounded, size: 18, color: context.inkMuted),
            const SizedBox(width: 8),
            Text(
              '排序',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: context.inkMuted,
                fontWeight: FontWeight.w700,
              ),
            ),
            const Spacer(),
            DropdownButtonHideUnderline(
              child: DropdownButton<CatalogSortMode>(
                key: const ValueKey('catalog-sort-dropdown'),
                value: selected,
                isDense: true,
                borderRadius: BorderRadius.circular(10),
                items: [
                  for (final mode in CatalogSortMode.values)
                    DropdownMenuItem(value: mode, child: Text(mode.label)),
                ],
                onChanged: (value) {
                  if (value != null) onChanged(value);
                },
              ),
            ),
          ],
        ),
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: SegmentedButton<CatalogSortMode>(
        key: const ValueKey('catalog-sort-segmented'),
        segments: [
          for (final mode in CatalogSortMode.values)
            ButtonSegment(value: mode, label: Text(mode.label)),
        ],
        selected: {selected},
        showSelectedIcon: false,
        onSelectionChanged: (values) => onChanged(values.first),
        style: const ButtonStyle(
          visualDensity: VisualDensity(horizontal: -2, vertical: -2),
          padding: WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          ),
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
    final entry = state.history.firstOrNull;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 24,
        runSpacing: 10,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(width: 14),
              Text(
                '${subjects.length} 部作品',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          if (kind == MetadataHubKind.anime && entry != null)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 300),
              child: TextButton.icon(
                onPressed: () => onOpen(entry.subject),
                icon: const Icon(Icons.play_circle_outline, size: 20),
                label: Text(
                  '续看 ${entry.subject.title}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
        ],
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
    final rows = <Widget>[
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
    ];
    return AppPanel(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        children: [
          rows.first,
          ExpansionTile(
            key: ValueKey(
              compact ? 'mobileMetadataFilters' : 'desktopMetadataFilters',
            ),
            tilePadding: const EdgeInsets.symmetric(horizontal: 2),
            childrenPadding: const EdgeInsets.only(bottom: 8),
            title: const Text('更多筛选'),
            subtitle:
                language == '全部' &&
                    year == '全部' &&
                    playbackFilter == _PlaybackFilter.all
                ? null
                : Text('$language · $year · ${playbackFilter.label}'),
            children: rows.skip(1).toList(growable: false),
          ),
        ],
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
  late Future<Map<int, List<AnimeSubject>>> _scheduleFuture;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: SchedulePage._weekdays.length,
      vsync: this,
      initialIndex: DateTime.now().weekday % 7,
    );
    _scheduleFuture =
        ref.read(animeControllerProvider.notifier).weeklySchedule()..ignore();
  }

  void _reloadSchedule() => setState(() {
    _scheduleFuture =
        ref.read(animeControllerProvider.notifier).weeklySchedule()..ignore();
  });

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppChrome(
      active: ChromeDestination.schedule,
      title: '新番时间表',
      showSearch: false,
      trailing: AppIconButton(
        icon: Icons.refresh_rounded,
        tooltip: '刷新时间表',
        onPressed: _reloadSchedule,
      ),
      compactAction: AppIconButton(
        icon: Icons.refresh_rounded,
        tooltip: '刷新时间表',
        onPressed: _reloadSchedule,
      ),
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
                        ? const PosterGridSkeleton(
                            count: 8,
                            padding: EdgeInsets.all(16),
                          )
                        : snapshot.hasError ||
                              schedule.values.every((items) => items.isEmpty)
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text('暂时无法获取放送日历'),
                                const SizedBox(height: 8),
                                const Text('不会用历史番剧代替本周更新。'),
                                TextButton(
                                  onPressed: _reloadSchedule,
                                  child: const Text('重试'),
                                ),
                              ],
                            ),
                          )
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
      return EmptyState(
        icon: Icons.movie_filter_outlined,
        title: '$title 暂无结果',
        message: '暂时没有内容，稍后刷新或换个分类试试。',
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

const _searchScopeOptions = <(SubjectContentType?, String)>[
  (null, '全部'),
  (SubjectContentType.anime, '番剧'),
  (SubjectContentType.series, '剧集'),
  (SubjectContentType.movie, '电影'),
];

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key, required this.keyword, this.scope});

  final String keyword;

  /// Restricts results to one catalogue. Null searches the whole library and
  /// additionally surfaces live channels and BT resources.
  final SubjectContentType? scope;

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  late Future<_SearchPageData> _search;
  SubjectContentType? _scope;
  late final TextEditingController _queryController;
  late String _keyword;

  @override
  void initState() {
    super.initState();
    _scope = widget.scope;
    _keyword = widget.keyword;
    _queryController = TextEditingController(text: _keyword);
    _search = _load();
  }

  @override
  void didUpdateWidget(covariant SearchPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.keyword != widget.keyword) {
      _keyword = widget.keyword;
      _queryController.text = _keyword;
      _search = _load();
    }
  }

  Future<_SearchPageData> _load() async {
    final controller = ref.read(animeControllerProvider.notifier);
    final subjectsFuture = controller.search(_keyword);
    final torrentsFuture = controller.searchTorrentResources(_keyword);
    final subjects = await subjectsFuture;
    final torrents = await torrentsFuture;
    return _SearchPageData(subjects: subjects, torrents: torrents);
  }

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  void _submit(String value) {
    final query = value.trim();
    if (query.isEmpty) return;
    setState(() {
      _keyword = query;
      _search = _load();
    });
  }

  void _retry() {
    setState(() => _search = _load());
  }

  @override
  Widget build(BuildContext context) {
    return AppChrome(
      active: ChromeDestination.anime,
      title: '搜索：$_keyword',
      searchController: _queryController,
      onSearch: _submit,
      onBack: () => safeNavigateBack(context),
      // _SearchRightRail is gone: its "热门搜索" panel was the current keyword
      // plus five hardcoded words, and its "类型筛选" chips had no onTap. Real
      // search history exists (searchHistoryStore) if this rail is ever rebuilt.
      child: FutureBuilder<_SearchPageData>(
        future: _search,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const SearchPageSkeleton();
          }
          if (snapshot.hasError || snapshot.data == null) {
            return _SearchLoadError(onRetry: _retry);
          }
          return _SearchResultBody(
            data: snapshot.data!,
            keyword: _keyword,
            scope: _scope,
            onScopeChanged: (value) => setState(() => _scope = value),
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
    required this.keyword,
    required this.scope,
    required this.onScopeChanged,
    required this.onOpenSubject,
    required this.onOpenTorrent,
  });

  final _SearchPageData data;
  final String keyword;
  final SubjectContentType? scope;
  final ValueChanged<SubjectContentType?> onScopeChanged;
  final ValueChanged<AnimeSubject> onOpenSubject;
  final ValueChanged<TorrentResource> onOpenTorrent;

  @override
  Widget build(BuildContext context) {
    final liveSubjects = scope == null
        ? data.subjects
              .where((item) => item.source.startsWith('m3u-channel:'))
              .toList(growable: false)
        : const <AnimeSubject>[];
    final mediaSubjects = rankSearchSubjects(
      keyword,
      data.subjects.where((item) => !item.source.startsWith('m3u-channel:')),
      scope: scope,
    );
    final torrents = scope == null
        ? data.torrents.items
        : const <TorrentResource>[];
    final scopeChips = SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 10, 8, 2),
        child: Wrap(
          spacing: 8,
          children: [
            for (final option in _searchScopeOptions)
              FilterChip(
                label: Text(option.$2),
                selected: scope == option.$1,
                onSelected: (_) => onScopeChanged(option.$1),
              ),
          ],
        ),
      ),
    );
    if (mediaSubjects.isEmpty && liveSubjects.isEmpty && torrents.isEmpty) {
      return CustomScrollView(
        slivers: [
          scopeChips,
          SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyState(
              icon: Icons.search_off_rounded,
              title: '没有找到相关内容',
              message: scope == null
                  ? '可以换一个片名、频道名或字幕组关键词再试。'
                  : '这个分类里没有匹配结果，可以切到“全部”再搜一次。',
            ),
          ),
        ],
      );
    }

    return CustomScrollView(
      slivers: [
        scopeChips,
        if (scope == null && data.torrents.hasFailures)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(24, 6, 8, 8),
              child: AppPanel(
                borderColor: AppColors.borderBright,
                child: Text('部分外部资源暂时打不开，已展示其余结果。'),
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
            subtitle: '需要用外部 BT 客户端打开，应用内不播放',
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
                  color: context.ink,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                meta.join(' · '),
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: context.inkMuted),
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
              Icon(
                Icons.cloud_download_outlined,
                color: Theme.of(context).colorScheme.primary,
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
            Icon(Icons.wifi_off_rounded, color: context.inkMuted, size: 36),
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
        final compact = MediaQuery.sizeOf(context).width < 760;

        void play(AnimeEpisode episode) {
          final controller = ref.read(animeControllerProvider.notifier);
          final accountContextVersion = controller.accountContextVersion;
          if (!context.mounted ||
              !controller.isAccountContextCurrent(accountContextVersion)) {
            return;
          }
          final resumePosition =
              historyEntry?.episode?.id == episode.id &&
                  (historyEntry?.positionSeconds ?? 0) > 0
              ? Duration(seconds: historyEntry!.positionSeconds)
              : Duration.zero;
          context.push(
            '/player',
            extra: PlaySessionRequest(
              subject: bundle.subject,
              episodes: bundle.episodes,
              episode: episode,
              resumePosition: resumePosition,
              initialLine: controller.prefetchedLineForEpisode(
                bundle.subject,
                episode,
              ),
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
            bottomPlayer: _MiniNowPlaying(
              subject: bundle.subject,
              progress: historyEntry?.playbackProgress,
            ),
            child: Stack(
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    compact ? 14 : 24,
                    compact ? 2 : 6,
                    compact ? 14 : 24,
                    24,
                  ),
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
                              _showToast(context, '这部作品还没有可下载的集数');
                              return;
                            }
                            _showToast(context, '正在准备下载…');
                            final message = await controller.queueOffline(
                              bundle.subject,
                              episode,
                            );
                            if (context.mounted) _showToast(context, message);
                          },
                        ),
                      ),
                      const SliverToBoxAdapter(child: SizedBox(height: 14)),
                      SliverPersistentHeader(
                        pinned: true,
                        delegate: _DetailTabsHeaderDelegate(compact: compact),
                      ),
                    ],
                    body: snapshot.connectionState == ConnectionState.waiting
                        ? const DetailTabsSkeleton()
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
  });

  final AnimeHomeTab selected;
  final ValueChanged<AnimeHomeTab> onChanged;
  final VoidCallback onSchedule;

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
            color: Theme.of(context).colorScheme.surface,
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
          tooltip: '新番时间表',
          onTap: onSchedule,
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
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
          child: SizedBox(
            width: 40,
            height: 38,
            child: Icon(icon, size: 20, color: context.ink),
          ),
        ),
      ),
    );
  }
}

/// Real playback progress of the most recent history entry, or null when no
/// entry carries a usable position/duration pair.
double? _historyPlaybackProgress(List<LibraryEntry> history) {
  for (final entry in history) {
    final progress = entry.playbackProgress;
    if (progress != null) return progress;
  }
  return null;
}

class _MiniNowPlaying extends StatelessWidget {
  const _MiniNowPlaying({required this.subject, this.progress});

  final AnimeSubject subject;
  final double? progress;

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
              color: context.ink,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          if (progress != null)
            LinearProgressIndicator(
              value: progress,
              minHeight: 4,
              borderRadius: BorderRadius.circular(4),
              backgroundColor: AppColors.border,
              color: Theme.of(context).colorScheme.primary,
            )
          else
            const SizedBox(height: 4),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              Icon(Icons.skip_previous, color: context.inkMuted, size: 20),
              const CircleAvatar(
                radius: 19,
                backgroundColor: AppColors.primary,
                child: Icon(Icons.play_arrow_rounded, color: Colors.white),
              ),
              Icon(Icons.skip_next, color: context.inkMuted, size: 20),
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
    return _SubjectGrid(subjects: subjects, onOpen: onOpen);
  }
}

class _RecommendTab extends StatefulWidget {
  const _RecommendTab({
    required this.feed,
    required this.personalizedRecommendations,
    required this.onOpen,
    required this.onRotate,
    required this.onNotInterested,
  });

  final AnimeHomeFeed feed;
  final bool personalizedRecommendations;
  final ValueChanged<AnimeSubject> onOpen;
  final VoidCallback onRotate;
  final FutureOr<void> Function(AnimeSubject subject) onNotInterested;

  @override
  State<_RecommendTab> createState() => _RecommendTabState();
}

class _RecommendTabState extends State<_RecommendTab> {
  static const _heroAutoplayInterval = Duration(seconds: 6);

  late final PageController _heroController;
  int _heroIndex = 0;
  int _heroCount = 0;
  Timer? _heroTimer;
  bool _heroHovering = false;
  final Set<String> _dismissedRecommendationKeys = {};

  @override
  void initState() {
    super.initState();
    _heroController = PageController();
    _heroTimer = Timer.periodic(_heroAutoplayInterval, (_) => _autoAdvance());
  }

  void _autoAdvance() {
    if (!mounted || _heroHovering || _heroCount < 2) return;
    if (MediaQuery.disableAnimationsOf(context)) return;
    _animateToHero((_heroIndex + 1) % _heroCount);
  }

  @override
  void didUpdateWidget(covariant _RecommendTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.feed != widget.feed) {
      _heroIndex = 0;
      if (_heroController.hasClients) _heroController.jumpToPage(0);
      final currentKeys = widget.feed.recommended
          .map(_recommendationCardKey)
          .toSet();
      _dismissedRecommendationKeys.removeWhere(
        (key) => !currentKeys.contains(key),
      );
    }
  }

  @override
  void dispose() {
    _heroTimer?.cancel();
    _heroController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final heroSubjects = _heroSubjects(widget.feed);
    _heroCount = heroSubjects.length;
    final heroIndex = heroSubjects.isEmpty
        ? 0
        : _heroIndex.clamp(0, heroSubjects.length - 1).toInt();
    final recommendations = widget.feed.recommended
        .where(
          (subject) => !_dismissedRecommendationKeys.contains(
            _recommendationCardKey(subject),
          ),
        )
        .toList(growable: false);
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(0, 0, 0, 14),
            child: MouseRegion(
              onEnter: (_) => _heroHovering = true,
              onExit: (_) => _heroHovering = false,
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
        ),
        SliverToBoxAdapter(
          child: SectionTitle(
            title: '为你推荐',
            icon: Icons.auto_awesome_rounded,
            action: TextButton.icon(
              key: const ValueKey('rotate-home-recommendations'),
              onPressed: widget.onRotate,
              icon: const Icon(Icons.shuffle_rounded, size: 18),
              label: const Text('换一批'),
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 10)),
        _SubjectGridSliver(
          subjects: recommendations,
          onOpen: widget.onOpen,
          trailingBuilder: widget.personalizedRecommendations
              ? (subject) => _RecommendationCardMenu(
                  subject: subject,
                  onNotInterested: () => _markNotInterested(subject),
                )
              : null,
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 20)),
        const SliverToBoxAdapter(
          child: SectionTitle(title: '新番更新', icon: Icons.update),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 10)),
        _SubjectGridSliver(subjects: widget.feed.recent, onOpen: widget.onOpen),
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
    final remaining = candidates
        .where(
          (item) =>
              _recommendationCardKey(item) != _recommendationCardKey(feed.hero),
        )
        .toList(growable: false);
    final withBanners = remaining
        .where((item) => (item.bannerUrl ?? '').trim().isNotEmpty)
        .toList(growable: false);
    return [
      feed.hero,
      ...withBanners,
      ...remaining.where((item) => !withBanners.contains(item)),
    ].take(7).toList(growable: false);
  }

  Future<void> _markNotInterested(AnimeSubject subject) async {
    final key = _recommendationCardKey(subject);
    setState(() => _dismissedRecommendationKeys.add(key));
    try {
      await widget.onNotInterested(subject);
    } catch (_) {
      if (!mounted) return;
      setState(() => _dismissedRecommendationKeys.remove(key));
      _showToast(context, '暂时无法更新推荐偏好');
    }
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

class _RecommendationCardMenu extends StatelessWidget {
  const _RecommendationCardMenu({
    required this.subject,
    required this.onNotInterested,
  });

  final AnimeSubject subject;
  final VoidCallback onNotInterested;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_RecommendationCardAction>(
      key: ValueKey('recommendation-menu-${_recommendationCardKey(subject)}'),
      tooltip: '推荐选项',
      child: const SizedBox.square(
        dimension: 28,
        child: Icon(Icons.more_horiz_rounded, size: 18),
      ),
      onSelected: (action) {
        if (action == _RecommendationCardAction.notInterested) {
          onNotInterested();
        }
      },
      itemBuilder: (context) => const [
        PopupMenuItem(
          value: _RecommendationCardAction.notInterested,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.block_rounded, size: 18),
              SizedBox(width: 10),
              Text('不感兴趣'),
            ],
          ),
        ),
      ],
    );
  }
}

enum _RecommendationCardAction { notInterested }

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
      // 剧场版 is a content type, not a genre, so an exact categories match
      // would never hit it -- the same reason 正篇/特别篇 were dropped from the
      // filter row entirely.
      final typeOk = switch (type) {
        '全部' => true,
        '剧场版' => subjectMatchesContentType(subject, SubjectContentType.movie),
        _ => subject.categories.any((item) => item.name == type),
      };
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
  const _SubjectGrid({required this.subjects, required this.onOpen});

  final List<AnimeSubject> subjects;
  final ValueChanged<AnimeSubject> onOpen;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(0, 12, 8, 120),
      gridDelegate: _gridDelegate(context),
      itemCount: subjects.length,
      itemBuilder: (context, index) {
        final subject = subjects[index];
        final display = _publicSubjectMetadata(context, subject);
        return PosterCard(
          subject: display,
          // _publicMetadataValue only strips provider names; it does not
          // translate. Using it here printed raw upstream values such as
          // "releasing" or "Returning Series" on the poster badge while the
          // hero and detail pages showed Chinese for the same field.
          badge: display.status,
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
    this.showPlaybackAvailability = false,
    this.trailingBuilder,
  });

  final List<AnimeSubject> subjects;
  final ValueChanged<AnimeSubject> onOpen;
  final bool showPlaybackAvailability;
  final Widget Function(AnimeSubject subject)? trailingBuilder;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 760;
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(0, 0, compact ? 0 : 8, 0),
      sliver: SliverGrid(
        gridDelegate: _gridDelegate(context),
        delegate: SliverChildBuilderDelegate((context, index) {
          final subject = subjects[index];
          return PosterCard(
            subject: _publicSubjectMetadata(context, subject),
            badge: showPlaybackAvailability
                ? subjectPlaybackLabel(subject)
                : null,
            trailing: trailingBuilder?.call(subject),
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
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: AppOverlays.labelPlate(0.65),
                    ),
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
                          color: AppColors.theaterInk,
                          fontWeight: FontWeight.w700,
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
    final items = subjects.isEmpty ? [_fallbackHeroSubject] : subjects;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 600;
        final extra = math.max(
          0.0,
          MediaQuery.textScalerOf(context).scale(1) - 1,
        );
        return AppPanel(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              SizedBox(
                height: (compact ? 230 : 240) + extra * 180,
                child: PageView.builder(
                  controller: controller,
                  itemCount: items.length,
                  onPageChanged: onChanged,
                  itemBuilder: (context, page) => _HeroBannerSlide(
                    subject: items[page],
                    onTap: () => onOpen(items[page]),
                  ),
                ),
              ),
              if (items.length > 1)
                Padding(
                  key: const ValueKey('homeCarouselControls'),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Row(
                    children: [
                      for (var i = 0; i < items.length; i++)
                        Semantics(
                          label: '第 ${i + 1} 张推荐',
                          selected: i == index,
                          button: true,
                          child: InkWell(
                            onTap: () => onDotTap(i),
                            borderRadius: BorderRadius.circular(6),
                            child: SizedBox(
                              width: 28,
                              height: 44,
                              child: Center(
                                child: AnimatedContainer(
                                  duration:
                                      MediaQuery.disableAnimationsOf(context)
                                      ? Duration.zero
                                      : AppMotion.quick,
                                  height: 4,
                                  width: i == index ? 20 : 6,
                                  decoration: BoxDecoration(
                                    color: i == index
                                        ? Theme.of(context).colorScheme.primary
                                        : Theme.of(context).colorScheme.outline,
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      const Spacer(),
                      if (!compact) ...[
                        _HeroArrowButton(
                          icon: Icons.chevron_left_rounded,
                          tooltip: '上一张',
                          onTap: () => onDotTap(
                            (index - 1 + items.length) % items.length,
                          ),
                        ),
                        const SizedBox(width: 8),
                        _HeroArrowButton(
                          icon: Icons.chevron_right_rounded,
                          tooltip: '下一张',
                          onTap: () => onDotTap((index + 1) % items.length),
                        ),
                      ],
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
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: SizedBox(
            width: 38,
            height: 38,
            child: Icon(icon, size: 24, color: context.ink),
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
    final display = _publicSubjectMetadata(context, subject);
    final metadata = [
      subject.year,
      if (display.region.isNotEmpty) display.region,
      if (subject.totalEpisodes > 0) '全${subject.totalEpisodes}集',
    ].join(' · ');
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 600;
        return Padding(
          padding: EdgeInsets.all(compact ? 16 : 24),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: compact ? 104 : 142,
                height: compact ? 156 : 192,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  child: PosterArt(
                    coverUrl: subject.coverUrl,
                    title: subject.title,
                  ),
                ),
              ),
              SizedBox(width: compact ? 16 : 28),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '精选推荐',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: context.inkMuted,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      subject.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: compact
                          ? Theme.of(context).textTheme.titleMedium
                          : Theme.of(context).textTheme.headlineLarge,
                    ),
                    const SizedBox(height: 8),
                    if (!compact &&
                        !_preferChineseMetadata(context) &&
                        subject.originalTitle.trim().isNotEmpty &&
                        subject.originalTitle != subject.title)
                      Text(
                        subject.originalTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    Text(
                      metadata,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 16),
                    AccentButton(
                      icon: Icons.arrow_forward_rounded,
                      label: '查看详情',
                      onTap: onTap,
                      compact: compact,
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
            // 正篇 and 特别篇 used to sit here, but they are Bangumi *episode*
            // types and this row matches against subject.categories (genres),
            // so neither could ever select anything. 剧场版 stays because
            // _IndexTab special-cases it against the content type below.
            values: const ['全部', '动画', '剧场版', '奇幻', '喜剧', '冒险'],
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
    final chips = <Widget>[
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
    ];
    final options = Wrap(spacing: 8, runSpacing: 8, children: chips);

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
            return Row(
              children: [
                labelChip,
                const SizedBox(width: 10),
                Expanded(
                  child: SingleChildScrollView(
                    key: ValueKey('mobileFilter-$label'),
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (var index = 0; index < chips.length; index++) ...[
                          chips[index],
                          if (index != chips.length - 1)
                            const SizedBox(width: 8),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
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
    final display = _publicSubjectMetadata(context, subject);
    final scheme = Theme.of(context).colorScheme;
    final metadata = [
      subject.year,
      if (display.region.isNotEmpty) display.region,
      if (subject.totalEpisodes > 0) '全${subject.totalEpisodes}集',
    ].join(' · ');
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 640;
        Widget secondaryAction(
          IconData icon,
          String label,
          VoidCallback onTap,
        ) {
          if (compact) {
            // Keep text and touch targets at their real size on narrow screens.
            // Icons are redundant here; the labels also fit increased text size.
            return OutlinedButton(
              onPressed: onTap,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 44),
                padding: const EdgeInsets.symmetric(
                  horizontal: 4,
                  vertical: 10,
                ),
              ),
              child: Text(label, textAlign: TextAlign.center),
            );
          }
          return AccentButton(
            icon: icon,
            label: label,
            filled: false,
            onTap: onTap,
            compact: true,
          );
        }

        final secondary = <Widget>[
          secondaryAction(
            following ? Icons.check : Icons.add,
            following ? '已追番' : '追番',
            onFollowing,
          ),
          secondaryAction(
            collected ? Icons.favorite : Icons.favorite_border,
            collected ? '已收藏' : '收藏',
            onCollect,
          ),
          secondaryAction(Icons.download_outlined, '下载', onDownload),
        ];
        return AppPanel(
          key: const ValueKey('detailSummaryHeader'),
          padding: EdgeInsets.all(compact ? 16 : 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: compact ? 96 : 142,
                    height: compact ? 144 : 206,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                      child: PosterArt(
                        coverUrl: subject.coverUrl,
                        title: subject.title,
                      ),
                    ),
                  ),
                  SizedBox(width: compact ? 16 : 28),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          subject.title,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: compact
                              ? Theme.of(context).textTheme.titleLarge
                              : Theme.of(context).textTheme.headlineLarge,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          metadata,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            if (subject.ratingScore != null)
                              SmallBadge(
                                label:
                                    '★ ${subject.ratingScore!.toStringAsFixed(1)}',
                                active: true,
                              ),
                            if (display.platform.isNotEmpty)
                              SmallBadge(label: display.platform),
                            if (display.status.isNotEmpty)
                              SmallBadge(label: display.status),
                            if (subjectPlaybackLabel(subject).isNotEmpty)
                              SmallBadge(label: subjectPlaybackLabel(subject)),
                          ],
                        ),
                        if (!compact) ...[
                          if (subject.ratingTotal case final total?
                              when total > 0) ...[
                            const SizedBox(height: 8),
                            Text(
                              '$total 人评分',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                          const SizedBox(height: 22),
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              AccentButton(
                                icon: Icons.play_arrow_rounded,
                                label: '立即播放',
                                onTap: onPlay,
                              ),
                              ...secondary,
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              if (compact) ...[
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: onPlay,
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('立即播放'),
                ),
                const SizedBox(height: 8),
                // Three equal actions avoid an isolated download button on a new row.
                Row(
                  children: [
                    for (var i = 0; i < secondary.length; i++) ...[
                      if (i > 0) const SizedBox(width: 8),
                      Expanded(child: secondary[i]),
                    ],
                  ],
                ),
              ],
              if (onPlay == null) ...[
                const SizedBox(height: 10),
                Text(
                  '暂无可播放集数',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _DetailTabs extends StatelessWidget {
  const _DetailTabs();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final compact = MediaQuery.sizeOf(context).width < 760;
    // Flat underline tabs only — no rounded dark card behind the labels.
    // That card read as a second bottom bar on phones.
    return TabBar(
      isScrollable: true,
      tabAlignment: TabAlignment.start,
      dividerColor: scheme.outlineVariant.withValues(alpha: 0.55),
      indicatorSize: TabBarIndicatorSize.label,
      indicatorWeight: 2.5,
      indicatorColor: scheme.primary,
      labelColor: scheme.primary,
      unselectedLabelColor: scheme.onSurfaceVariant,
      overlayColor: WidgetStatePropertyAll(
        scheme.primary.withValues(alpha: 0.08),
      ),
      labelStyle: Theme.of(
        context,
      ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800),
      unselectedLabelStyle: Theme.of(
        context,
      ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      labelPadding: EdgeInsets.symmetric(horizontal: compact ? 14 : 18),
      tabs: [
        Tab(height: compact ? 44 : 52, text: '简介'),
        Tab(height: compact ? 44 : 52, text: '选集'),
        Tab(height: compact ? 44 : 52, text: '角色'),
        Tab(height: compact ? 44 : 52, text: '职员'),
        Tab(height: compact ? 44 : 52, text: '推荐'),
      ],
    );
  }
}

class _DetailTabsHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _DetailTabsHeaderDelegate({required this.compact});

  final bool compact;

  /// Text-only row; no icon stack, no card chrome.
  double get _extent => compact ? 48.0 : 56.0;

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
    final scheme = Theme.of(context).colorScheme;
    // Match page background so sticky tabs don't paint a floating slab.
    return ColoredBox(
      color: scheme.surface.withValues(alpha: overlapsContent ? 0.98 : 0.92),
      child: const Align(
        alignment: Alignment.bottomCenter,
        child: _DetailTabs(),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _DetailTabsHeaderDelegate oldDelegate) {
    return oldDelegate.compact != compact;
  }
}

class _DetailInfo extends StatelessWidget {
  const _DetailInfo({required this.bundle});

  final AnimeDetailBundle bundle;

  @override
  Widget build(BuildContext context) {
    final subject = _publicSubjectMetadata(context, bundle.subject);
    final summary = subject.summary.trim();
    final hasSummary = summary.isNotEmpty && !isMetadataPlaceholder(summary);
    final categories = subject.categories
        .map((item) => item.name.trim())
        .where((name) => name.isNotEmpty)
        .toList(growable: false);
    final tags = subject.tags
        .map((item) => item.name.trim())
        .where((name) => name.isNotEmpty)
        .toList(growable: false);
    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 0, 8, 120),
      children: [
        AppPanel(
          child: hasSummary
              ? Text(
                  summary,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: context.ink,
                    height: 1.7,
                  ),
                )
              : EmptyState(
                  icon: Icons.article_outlined,
                  title: '暂无简介',
                  message: '这部作品还没有可用的中文简介。',
                  compact: true,
                ),
        ),
        if (categories.isNotEmpty) ...[
          const SizedBox(height: 18),
          const _BlockTitle('分类'),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              for (final name in categories) _Chip(label: name, selected: true),
            ],
          ),
        ],
        if (tags.isNotEmpty) ...[
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = (constraints.maxWidth / 210).floor().clamp(1, 6);
        return GridView.builder(
          key: const ValueKey('detailEpisodeGrid'),
          padding: const EdgeInsets.fromLTRB(0, 0, 0, 120),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            mainAxisExtent: 58,
          ),
          itemCount: bundle.episodes.length,
          itemBuilder: (context, index) {
            final episode = bundle.episodes[index];
            final scheme = Theme.of(context).colorScheme;
            return InkWell(
              borderRadius: BorderRadius.circular(AppRadius.md),
              onTap: () => onPlay(episode),
              child: AppPanel(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                color: index == 0
                    ? scheme.primaryContainer
                    : scheme.surfaceContainer,
                borderColor: index == 0
                    ? scheme.primary
                    : scheme.outlineVariant,
                child: Row(
                  children: [
                    Text(
                      '${episode.number}',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: index == 0
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
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
      },
    );
  }
}

class _CharacterGrid extends StatelessWidget {
  const _CharacterGrid({required this.items});

  final List<AnimeCharacter> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const EmptyState(
        icon: Icons.person_outline_rounded,
        title: '暂无角色资料',
        message: '这部作品暂时没有角色信息。',
        compact: true,
      );
    }
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
    if (items.isEmpty) {
      return const EmptyState(
        icon: Icons.badge_outlined,
        title: '暂无制作人员资料',
        message: '这部作品暂时没有制作人员信息。',
        compact: true,
      );
    }
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
    if (items.isEmpty) {
      return const EmptyState(
        icon: Icons.auto_awesome_outlined,
        title: '暂无相关推荐',
        message: '这部作品暂时没有相关推荐。',
        compact: true,
      );
    }
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
          ).textTheme.titleMedium?.copyWith(color: context.ink),
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
          ).textTheme.bodySmall?.copyWith(color: context.inkMuted),
        ),
      ],
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
          color: context.ink,
          fontWeight: FontWeight.w700,
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

String _recommendationCardKey(AnimeSubject subject) =>
    '${subject.source}:${subject.id}';

SubjectContentType _subjectContentTypeFor(MetadataHubKind kind) {
  return switch (kind) {
    MetadataHubKind.anime => SubjectContentType.anime,
    MetadataHubKind.series => SubjectContentType.series,
    MetadataHubKind.movie => SubjectContentType.movie,
  };
}

const _fallbackHeroSubject = AnimeSubject(
  id: -1,
  title: '为你推荐',
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

class _WeekCalendarStrip extends StatefulWidget {
  const _WeekCalendarStrip({
    required this.schedule,
    required this.selectedIndex,
    required this.onSelected,
  });
  final Map<int, List<AnimeSubject>> schedule;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  @override
  State<_WeekCalendarStrip> createState() => _WeekCalendarStripState();
}

class _WeekCalendarStripState extends State<_WeekCalendarStrip> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _revealSelectedDay();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _WeekCalendarStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedIndex != widget.selectedIndex) _revealSelectedDay();
  }

  void _revealSelectedDay() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final start = widget.selectedIndex * 220.0;
      final end = start + 210;
      final view = _scroll.position.viewportDimension;
      if (start < _scroll.offset) {
        _moveTo(start);
      } else if (end > _scroll.offset + view) {
        _moveTo(end - view);
      }
    });
  }

  void _moveTo(double offset) {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      offset.clamp(0.0, _scroll.position.maxScrollExtent),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final overflow = constraints.maxWidth < 1530;
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (overflow)
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                const Expanded(
                  child: Text(
                    '拖动或滚轮查看更多日期',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: '前面的日期',
                  onPressed: () => _moveTo(_scroll.offset - 440),
                  icon: const Icon(Icons.chevron_left),
                ),
                IconButton(
                  tooltip: '后面的日期',
                  onPressed: () => _moveTo(_scroll.offset + 440),
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
          SizedBox(
            height: 142,
            child: Listener(
              onPointerSignal: (event) {
                if (event is PointerScrollEvent &&
                    _scroll.hasClients &&
                    _scroll.position.maxScrollExtent > 0) {
                  GestureBinding.instance.pointerSignalResolver.register(
                    event,
                    (resolved) {
                      final delta = event.scrollDelta.dx != 0
                          ? event.scrollDelta.dx
                          : event.scrollDelta.dy;
                      _scroll.jumpTo(
                        (_scroll.offset + delta).clamp(
                          0.0,
                          _scroll.position.maxScrollExtent,
                        ),
                      );
                    },
                  );
                }
              },
              child: ScrollConfiguration(
                behavior: ScrollConfiguration.of(context).copyWith(
                  dragDevices: {
                    PointerDeviceKind.mouse,
                    PointerDeviceKind.touch,
                    PointerDeviceKind.trackpad,
                    PointerDeviceKind.stylus,
                  },
                ),
                child: Scrollbar(
                  controller: _scroll,
                  thumbVisibility: overflow,
                  child: ListView.separated(
                    controller: _scroll,
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.only(bottom: 12),
                    itemCount: SchedulePage._weekdays.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(width: 10),
                    itemBuilder: (context, index) {
                      final day = SchedulePage._weekdays[index];
                      return Semantics(
                        key: ValueKey('schedule-day-$index'),
                        button: true,
                        selected: index == widget.selectedIndex,
                        child: SizedBox(
                          width: 210,
                          child: InkWell(
                            onTap: () => widget.onSelected(index),
                            borderRadius: BorderRadius.circular(8),
                            child: _DayCard(
                              label: day.$2,
                              subjects: widget.schedule[day.$1] ?? const [],
                              active: index == widget.selectedIndex,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
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
                      ).textTheme.bodySmall?.copyWith(color: context.inkMuted),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  subject?.title ?? '暂无更新',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: context.inkMuted,
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
                  ).textTheme.bodyMedium?.copyWith(color: context.inkMuted),
                )
              else
                for (final item in state.following.take(5))
                  CompactSubjectRow(
                    subject: _publicSubjectMetadata(context, item.subject),
                    // Was a static 提醒 label that looked like an action but
                    // was neither tappable nor backed by any reminder feature.
                    // Show where the user actually left off instead.
                    trailing: item.episode == null
                        ? null
                        : '看到第${item.episode!.number}集',
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
                  color: context.ink,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: context.inkMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

SliverGridDelegate _gridDelegate(BuildContext context) {
  final compact = MediaQuery.sizeOf(context).width < 760;
  // Cap tile width instead of column count so ultra-wide windows gain
  // columns rather than inflating each poster.
  return SliverGridDelegateWithMaxCrossAxisExtent(
    maxCrossAxisExtent: compact ? 232 : 188,
    mainAxisSpacing: compact ? 10 : 12,
    crossAxisSpacing: compact ? 10 : 12,
    childAspectRatio: compact ? 0.58 : 0.56,
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
