import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/anime_app.dart';
import '../data/anime_controller.dart';
import '../domain/anime_models.dart';
import '../shared_ui/app_chrome.dart';
import '../shared_ui/app_navigation.dart';
import '../shared_ui/poster_card.dart';

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
        items: feed.categories,
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
        items: feed.tags,
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
      padding: const EdgeInsets.fromLTRB(24, 2, 0, 24),
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

class SubjectListPage extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    return AppChrome(
      active: subtitle == '标签'
          ? ChromeDestination.movie
          : ChromeDestination.series,
      title: subtitle == null ? title : '$subtitle：$title',
      showSearch: false,
      onBack: () => safeNavigateBack(context),
      rightRail: _StaticFilterRail(title: subtitle ?? '筛选'),
      child: FutureBuilder<List<AnimeSubject>>(
        future: loader(ref),
        builder: (context, snapshot) {
          final subjects = snapshot.data ?? const <AnimeSubject>[];
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          return Padding(
            padding: const EdgeInsets.fromLTRB(24, 6, 0, 24),
            child: _SubjectResultView(subjects: subjects, title: title),
          );
        },
      ),
    );
  }
}

enum MetadataHubKind { anime, series, movie }

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
  Future<List<AnimeSubject>>? _subjectsFuture;
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
          active: _active,
          searchController: _searchController,
          onSearch: _openSearch,
          trailing: _MetadataTopFilters(
            selected: _type,
            values: _typeValues,
            onChanged: (value) => setState(() => _type = value),
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
              return Padding(
                padding: const EdgeInsets.fromLTRB(24, 2, 0, 24),
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
                    const SliverToBoxAdapter(child: SizedBox(height: 14)),
                    SliverToBoxAdapter(
                      child: _InlineFilterPanel(
                        type: _type,
                        language: _language,
                        year: _year,
                        typeValues: _typeValues,
                        languageValues: _languageValues,
                        onTypeChanged: (value) => setState(() => _type = value),
                        onLanguageChanged: (value) =>
                            setState(() => _language = value),
                        onYearChanged: (value) => setState(() => _year = value),
                      ),
                    ),
                    const SliverToBoxAdapter(child: SizedBox(height: 14)),
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

  String _subtitle(int count) {
    return switch (widget.kind) {
      MetadataHubKind.anime => '来自 Bangumi / AniList 的番剧元数据，共 $count 部',
      MetadataHubKind.series => '接入 TVMaze 影视剧元数据，共 $count 部',
      MetadataHubKind.movie => '接入 Wikidata 电影元数据，共 $count 部',
    };
  }

  String get _emptyMessage {
    return switch (widget.kind) {
      MetadataHubKind.anime => '当前番剧元数据里没有匹配条目，换个筛选条件或稍后刷新试试。',
      MetadataHubKind.series => '当前 TVMaze 剧集数据里没有匹配条目，换个分类或年份试试。',
      MetadataHubKind.movie => '当前 Wikidata 电影数据里没有匹配条目，换个分类或年份试试。',
    };
  }

  Future<List<AnimeSubject>> _loadSubjects(WidgetRef ref) {
    final controller = ref.read(animeControllerProvider.notifier);
    return switch (widget.kind) {
      MetadataHubKind.anime => controller.discoverSubjects(),
      MetadataHubKind.series => controller.seriesSubjects(),
      MetadataHubKind.movie => controller.movieSubjects(),
    };
  }

  List<AnimeSubject> _filterSubjects(List<AnimeSubject> subjects) {
    return subjects.where((subject) {
      final text = _metadataText(subject);
      final typeOk = _type == '全部' || _matchesType(subject, _type, text);
      final languageOk =
          _language == '全部' || _matchesLanguage(subject, _language);
      final yearOk = _year == '全部' || subject.year == _year.replaceAll('年', '');
      return typeOk && languageOk && yearOk;
    }).toList();
  }

  bool _matchesType(AnimeSubject subject, String type, String text) {
    final normalized = type.toLowerCase();
    if (normalized == '电影') return subject.platform.toLowerCase() == 'movie';
    if (normalized == '美剧') {
      return text.contains('united states') || text.contains('english');
    }
    if (normalized == '英剧') {
      return text.contains('united kingdom') || text.contains('british');
    }
    if (normalized == '韩剧') {
      return text.contains('korea') || text.contains('korean');
    }
    if (normalized == '日剧') {
      return text.contains('japan') || text.contains('japanese');
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
            text.contains('japan'),
      '国语' =>
        text.contains('国语') ||
            text.contains('chinese') ||
            text.contains('china'),
      '英语' =>
        text.contains('英语') ||
            text.contains('english') ||
            text.contains('united states') ||
            text.contains('united kingdom'),
      '韩语' =>
        text.contains('韩语') ||
            text.contains('korean') ||
            text.contains('korea'),
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
  });

  final String selected;
  final List<String> values;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 900;
    if (compact) return const SizedBox.shrink();
    return AppPanel(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 5),
      radius: 10,
      color: const Color(0xFF0F1421),
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
      MetadataHubKind.anime => '会合并多页 Bangumi 数据，通常几秒内完成。',
      MetadataHubKind.series => 'TVMaze 慢的时候会自动使用本地兜底列表。',
      MetadataHubKind.movie => 'Wikidata 慢的时候会自动使用本地热门电影兜底。',
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
    final lead = subjects.firstOrNull;
    final following = state.following.isNotEmpty
        ? state.following
        : state.history;
    final continueEntry = following.firstOrNull;
    final activeSources = state.sourceCatalog.enabledCount;
    final danmakuReady =
        state.services.dandanplayDanmakuEnabled ||
        state.services.bilibiliDanmakuEnabled ||
        state.services.customDanmakuEnabled;
    final height = kind == MetadataHubKind.anime ? 236.0 : 176.0;
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
                PosterArt(
                  coverUrl: lead.bannerUrl ?? lead.coverUrl,
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
                padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
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
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(
                            color: AppColors.text,
                            fontWeight: FontWeight.w900,
                          ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: AppColors.muted,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (kind == MetadataHubKind.anime) ...[
                      const SizedBox(height: 14),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final compact = constraints.maxWidth < 700;
                          final chips = [
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
                            _AnimekoStatusChip(
                              icon: Icons.hub_outlined,
                              label: '源 $activeSources 个',
                              active: activeSources > 0,
                            ),
                            _AnimekoStatusChip(
                              icon: Icons.subtitles_outlined,
                              label: danmakuReady ? '弹幕已接入' : '弹幕未开启',
                              active: danmakuReady,
                            ),
                          ];
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
              Expanded(
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
    required this.typeValues,
    required this.languageValues,
    required this.onTypeChanged,
    required this.onLanguageChanged,
    required this.onYearChanged,
  });

  final String type;
  final String language;
  final String year;
  final List<String> typeValues;
  final List<String> languageValues;
  final ValueChanged<String> onTypeChanged;
  final ValueChanged<String> onLanguageChanged;
  final ValueChanged<String> onYearChanged;

  @override
  Widget build(BuildContext context) {
    final years = [
      '全部',
      for (var y = DateTime.now().year; y >= 2013; y--) '$y年',
    ];
    return AppPanel(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
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
                    subject: subject,
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
              SectionTitle(title: kind == MetadataHubKind.anime ? '标签' : '来源'),
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
      MetadataHubKind.anime => 'Bangumi / AniList 番剧元数据',
      MetadataHubKind.series => '从 TVMaze 公开接口加载电视剧、连续剧和网剧资料。',
      MetadataHubKind.movie => '从 Wikidata 公开电影条目加载影片资料。',
    };
  }

  List<AnimeCategory> _categories(AnimeHomeFeed feed) {
    return switch (kind) {
      MetadataHubKind.anime => feed.categories.take(12).toList(),
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
      MetadataHubKind.anime => feed.tags.take(16).toList(),
      MetadataHubKind.series => const [
        AnimeTag(name: 'TVMaze'),
        AnimeTag(name: '公开剧集库'),
        AnimeTag(name: '最近播出'),
        AnimeTag(name: '免 Key'),
      ],
      MetadataHubKind.movie => const [
        AnimeTag(name: 'Wikidata'),
        AnimeTag(name: '电影实体'),
        AnimeTag(name: 'IMDb 标识'),
        AnimeTag(name: '免 Key'),
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
      MetadataHubKind.anime => feed.recommended,
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

class SchedulePage extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    return AppChrome(
      active: ChromeDestination.schedule,
      title: '周期表',
      showSearch: false,
      onBack: () => safeNavigateBack(context),
      rightRail: AsyncAnimeGate(
        builder: (context, state) => _ScheduleRightRail(state: state),
      ),
      child: FutureBuilder<Map<int, List<AnimeSubject>>>(
        future: ref.read(animeControllerProvider.notifier).weeklySchedule(),
        builder: (context, snapshot) {
          final schedule = snapshot.data ?? const <int, List<AnimeSubject>>{};
          return DefaultTabController(
            length: _weekdays.length,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 6, 0, 24),
              child: Column(
                children: [
                  _WeekCalendarStrip(
                    schedule: schedule,
                    onSelected: (index) =>
                        DefaultTabController.of(context).animateTo(index),
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: AppPanel(
                      padding: EdgeInsets.zero,
                      child: snapshot.connectionState == ConnectionState.waiting
                          ? const Center(child: CircularProgressIndicator())
                          : TabBarView(
                              children: [
                                for (final item in _weekdays)
                                  _SubjectResultView(
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
            ),
          );
        },
      ),
    );
  }
}

class _SubjectResultView extends StatelessWidget {
  const _SubjectResultView({required this.subjects, required this.title});

  final List<AnimeSubject> subjects;
  final String title;

  @override
  Widget build(BuildContext context) {
    if (subjects.isEmpty) {
      return _EmptyState(
        icon: Icons.movie_filter_outlined,
        title: '$title 暂无结果',
        message: 'Bangumi 暂时没有返回可展示条目，稍后刷新或换个分类试试。',
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

class SearchPage extends ConsumerWidget {
  const SearchPage({super.key, required this.keyword});

  final String keyword;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AppChrome(
      active: ChromeDestination.anime,
      title: '搜索：$keyword',
      showSearch: false,
      onBack: () => safeNavigateBack(context),
      rightRail: _SearchRightRail(keyword: keyword),
      child: FutureBuilder<List<AnimeSubject>>(
        future: ref.read(animeControllerProvider.notifier).search(keyword),
        builder: (context, snapshot) {
          final subjects = snapshot.data ?? const <AnimeSubject>[];
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          return Padding(
            padding: const EdgeInsets.fromLTRB(24, 6, 0, 24),
            child: _SubjectGrid(
              subjects: subjects,
              onOpen: (subject) => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => DetailPage(subject: subject),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class DetailPage extends ConsumerWidget {
  const DetailPage({super.key, required this.subject});

  final AnimeSubject subject;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder<AnimeDetailBundle>(
      future: ref.read(animeControllerProvider.notifier).detail(subject),
      builder: (context, snapshot) {
        final detail = snapshot.data;
        final bundle =
            detail ??
            AnimeDetailBundle(
              subject: subject,
              episodes: const [],
              characters: const [],
              staff: const [],
              recommendations: const [],
            );
        final animeState = ref.watch(animeControllerProvider).value;
        final favorite =
            animeState?.following.any(
              (item) => item.subject.id == bundle.subject.id,
            ) ??
            false;
        final historyEntry = animeState?.history
            .where((item) => item.subject.id == bundle.subject.id)
            .firstOrNull;

        void play(AnimeEpisode episode) {
          ref
              .read(animeControllerProvider.notifier)
              .addHistory(bundle.subject, episode);
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _DetailHero(
                        subject: bundle.subject,
                        favorite: favorite,
                        onPlay: continueEpisode() == null
                            ? null
                            : () => play(continueEpisode()!),
                        onFavorite: () async {
                          final selected = await ref
                              .read(animeControllerProvider.notifier)
                              .toggleFollowing(bundle.subject);
                          if (context.mounted) {
                            _showToast(context, selected ? '已加入追番列表' : '已取消追番');
                          }
                        },
                        onDownload: () {
                          final episode = continueEpisode();
                          if (episode == null) {
                            _showToast(context, '当前条目还没有可下载的集数');
                            return;
                          }
                          ref
                              .read(animeControllerProvider.notifier)
                              .queueOffline(bundle.subject, episode);
                          _showToast(context, '已加入下载管理');
                        },
                      ),
                      const SizedBox(height: 14),
                      const _DetailTabs(),
                      const SizedBox(height: 12),
                      Expanded(
                        child:
                            snapshot.connectionState == ConnectionState.waiting
                            ? const Center(child: CircularProgressIndicator())
                            : TabBarView(
                                children: [
                                  _DetailInfo(subject: bundle.subject),
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
                    ],
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
  final source = subject.source.toLowerCase();
  final platform = subject.platform.toLowerCase();
  if (source == 'wikidata' || platform.contains('movie')) {
    return ChromeDestination.movie;
  }
  if (source == 'tvmaze') return ChromeDestination.series;
  return ChromeDestination.home;
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
            color: const Color(0xFF0F1421),
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
              SectionTitle(
                title: '我的片单',
                action: Text(
                  '全部 12 ›',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: AppColors.muted,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _PlaylistRow(
                image: feed.hero.coverUrl,
                title: '我想看',
                count: state.favorites.length + 56,
              ),
              _PlaylistRow(
                image: feed.recent.firstOrNull?.coverUrl,
                title: '稍后观看',
                count: state.history.length + 24,
              ),
              _PlaylistRow(
                image: feed.recommended.firstOrNull?.coverUrl,
                title: '年度必看',
                count: state.following.length + 18,
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () {},
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('新建片单'),
                ),
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
                  subject: subject,
                  trailing: '刚刚',
                  onTap: () => onOpen(subject),
                ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        AppPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionTitle(title: '观看进度'),
              const SizedBox(height: 18),
              Row(
                children: [
                  SizedBox(
                    width: 82,
                    height: 82,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        CircularProgressIndicator(
                          value: state.history.isEmpty ? 0.68 : 0.82,
                          strokeWidth: 8,
                          backgroundColor: AppColors.border,
                          color: AppColors.primary,
                        ),
                        Center(
                          child: Text(
                            state.history.isEmpty ? '68%' : '82%',
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(
                                  color: AppColors.text,
                                  fontWeight: FontWeight.w900,
                                ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 18),
                  Expanded(
                    child: Text(
                      '本周观看时长\n${state.history.length * 2 + 16}小时 24分钟',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: AppColors.text,
                        height: 1.5,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var i = 0; i < 7; i++) ...[
                    Expanded(
                      child: Container(
                        height: 24.0 + (i % 4) * 12,
                        decoration: BoxDecoration(
                          color: i == 4
                              ? AppColors.primary
                              : AppColors.primary.withValues(alpha: 0.28),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                    if (i != 6) const SizedBox(width: 8),
                  ],
                ],
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
                coverUrl: subject.bannerUrl ?? subject.coverUrl,
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
    final heroSubjects = _heroSubjects(widget.feed);
    final heroIndex = heroSubjects.isEmpty
        ? 0
        : _heroIndex.clamp(0, heroSubjects.length - 1).toInt();
    final shortcutSubjects = _uniqueSubjectList(widget.feed.recommended);
    final shortcutCount = shortcutSubjects.length > 6
        ? 6
        : shortcutSubjects.length;
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
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(0, 0, 0, 10),
            child: SizedBox(
              height: 74,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemBuilder: (context, index) {
                  final subject = shortcutSubjects[index];
                  final labels = ['番剧', '剧集', '电影', '动漫电影', '纪录片', '综艺'];
                  return _CategoryShortcut(
                    label: labels[index % labels.length],
                    subtitle: index == 0 ? '追番进行时' : subject.status,
                    imageUrl: subject.bannerUrl ?? subject.coverUrl,
                    onTap: () => widget.onOpen(subject),
                  );
                },
                separatorBuilder: (context, index) => const SizedBox(width: 10),
                itemCount: shortcutCount,
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
    return _uniqueSubjectList([
      feed.hero,
      ...feed.recommended,
      ...feed.recent,
    ]).take(7).toList(growable: false);
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
    required this.imageUrl,
    required this.onTap,
  });

  final String label;
  final String subtitle;
  final String? imageUrl;
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
                PosterArt(coverUrl: imageUrl, title: label),
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
                      const Icon(
                        Icons.tune,
                        color: AppColors.primary,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '类型 · 语言 · 年份',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                color: AppColors.text,
                                fontWeight: FontWeight.w800,
                              ),
                        ),
                      ),
                      const Icon(
                        Icons.keyboard_arrow_down,
                        color: AppColors.muted,
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
          subject: subject,
          landscape: landscape,
          badge: landscape ? '有资源' : subject.status,
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
  });

  final List<AnimeSubject> subjects;
  final ValueChanged<AnimeSubject> onOpen;
  final bool landscape;

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(0, 0, 8, 0),
      sliver: SliverGrid(
        gridDelegate: _gridDelegate(context, landscape: landscape),
        delegate: SliverChildBuilderDelegate((context, index) {
          final subject = subjects[index];
          return PosterCard(
            subject: subject,
            landscape: landscape,
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
    return SizedBox(
      height: 264,
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
                  right: 18,
                  bottom: 16,
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final contentWidth = (constraints.maxWidth - 48)
            .clamp(220.0, 520.0)
            .toDouble();
        return InkWell(
          onTap: onTap,
          child: Stack(
            fit: StackFit.expand,
            children: [
              PosterArt(
                coverUrl: subject.bannerUrl ?? subject.coverUrl,
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
                left: 24,
                top: 24,
                bottom: 24,
                width: contentWidth,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SmallBadge(label: subject.platform, active: true),
                        const SizedBox(width: 8),
                        SmallBadge(label: subject.status),
                      ],
                    ),
                    const Spacer(),
                    Text(
                      subject.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.displaySmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${subject.year} · ${subject.region} · ${subject.subtitle} · 全${subject.totalEpisodes}集',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: AppColors.muted,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      subject.summary,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: AppColors.text,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 20),
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
          Container(
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.panelHigh,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppColors.border),
            ),
            child: Text(
              '筛选',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: AppColors.primary,
                fontWeight: FontWeight.w800,
              ),
            ),
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
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          Container(
            width: 52,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.panelHigh,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.border),
            ),
            child: Text(
              label,
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                color: AppColors.text,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemBuilder: (context, index) {
                final value = values[index];
                final active = selected == value;
                return InkWell(
                  onTap: () => onChanged(value),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 10,
                    ),
                    child: Text(
                      value,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: active ? AppColors.primary : AppColors.text,
                        fontWeight: active ? FontWeight.w800 : FontWeight.w500,
                      ),
                    ),
                  ),
                );
              },
              separatorBuilder: (context, index) => const SizedBox(width: 12),
              itemCount: values.length,
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailHero extends StatelessWidget {
  const _DetailHero({
    required this.subject,
    required this.favorite,
    required this.onPlay,
    required this.onFavorite,
    required this.onDownload,
  });

  final AnimeSubject subject;
  final bool favorite;
  final VoidCallback? onPlay;
  final VoidCallback onFavorite;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 292,
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
                child: PosterArt(
                  coverUrl: subject.bannerUrl ?? subject.coverUrl,
                  title: subject.title,
                ),
              ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Color(0xF2060912),
                      Color(0xAA060912),
                      Color(0x44060912),
                    ],
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(22),
                child: Row(
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
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              SmallBadge(
                                label: subject.ratingScore == null
                                    ? '暂无评分'
                                    : '★ ${subject.ratingScore!.toStringAsFixed(1)}',
                                active: true,
                              ),
                              SmallBadge(label: subject.platform),
                              SmallBadge(label: subject.status),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text(
                            subject.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.displaySmall
                                ?.copyWith(
                                  color: AppColors.text,
                                  fontWeight: FontWeight.w900,
                                ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '${subject.year}  |  ${subject.region}  |  ${subject.totalEpisodes}集全',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(
                                  color: AppColors.muted,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            subject.summary,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: AppColors.text, height: 1.45),
                          ),
                          const Spacer(),
                          Row(
                            children: [
                              AccentButton(
                                icon: Icons.play_arrow_rounded,
                                label: '立即观看',
                                onTap: onPlay,
                              ),
                              const SizedBox(width: 12),
                              AccentButton(
                                icon: favorite
                                    ? Icons.check_rounded
                                    : Icons.add_rounded,
                                label: favorite ? '已追番' : '追番',
                                filled: false,
                                onTap: onFavorite,
                              ),
                              const SizedBox(width: 12),
                              AccentButton(
                                icon: Icons.download_outlined,
                                label: '下载',
                                filled: false,
                                onTap: onDownload,
                              ),
                            ],
                          ),
                        ],
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
                '已连到第 ${bundle.episodes.isEmpty ? 0 : bundle.episodes.first.number} 集\n每周更新信息来自 Bangumi/AniList。',
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
                bundle.subject.summary,
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
                  subject: item.subject,
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

class _DetailInfo extends StatelessWidget {
  const _DetailInfo({required this.subject});

  final AnimeSubject subject;

  @override
  Widget build(BuildContext context) {
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
            color: index == 0 ? const Color(0xFF171A3A) : AppColors.panel,
            borderColor: index == 0 ? AppColors.primary : AppColors.border,
            child: Row(
              children: [
                Text(
                  '${episode.number}',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: index == 0 ? AppColors.primary : AppColors.muted,
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
                      color: AppColors.text,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const Icon(Icons.play_arrow_rounded, color: AppColors.primary),
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
          subject: item.subject,
          badge: item.relation,
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
          if (subject.bannerUrl != null)
            ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: Image.network(
                subject.bannerUrl!,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) =>
                    const ColoredBox(color: Colors.black),
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
        color: selected ? const Color(0xFF202020) : const Color(0xFF151515),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: selected ? Colors.white : AppColors.text,
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
  final seen = <Object>{};
  final result = <AnimeSubject>[];
  for (final subject in subjects) {
    final key = Object.hash(subject.source, subject.platform, subject.id);
    if (seen.add(key)) result.add(subject);
  }
  return result;
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
  const _WeekCalendarStrip({required this.schedule, required this.onSelected});

  final Map<int, List<AnimeSubject>> schedule;
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
          return SizedBox(
            width: 210,
            child: InkWell(
              onTap: () => onSelected(index),
              borderRadius: BorderRadius.circular(8),
              child: _DayCard(
                label: day.$2,
                subjects: schedule[day.$1] ?? const [],
                active: day.$1 == DateTime.now().weekday % 7,
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
      borderColor: active ? AppColors.primary : AppColors.border,
      color: active ? const Color(0xFF171A3A) : AppColors.panel,
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
                              color: AppColors.text,
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
                  CompactSubjectRow(subject: item.subject, trailing: '提醒'),
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
  final columns = landscape
      ? (width / 292).floor().clamp(2, 4)
      : (width / 180).floor().clamp(2, 6);
  return SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: columns,
    mainAxisSpacing: 12,
    crossAxisSpacing: 12,
    childAspectRatio: landscape ? 1.48 : 0.56,
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
