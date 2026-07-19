import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/rules/rule_plugin_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('semantic duplicate rules keep only the newer complete rule', () {
    final older = _rule(
      id: 'user:old',
      version: '1.0',
      updatedAt: DateTime(2026, 1, 1),
    );
    final newer = _rule(
      id: 'user:new',
      version: '2.0',
      updatedAt: DateTime(2026, 7, 1),
    );
    final repository = RulePluginRepository(extraRules: [older, newer]);

    final matching = repository.allRules.where(
      (rule) => rule.baseUrl == 'https://duplicate.example/',
    );

    expect(matching, hasLength(1));
    expect(matching.single.id, newer.id);
    expect(repository.byId(older.id)?.id, newer.id);
  });

  test('normalization migrates installed and enabled duplicate aliases', () {
    final older = _rule(
      id: 'user:old-state',
      version: '1.0',
      updatedAt: DateTime(2026, 1, 1),
    );
    final newer = _rule(
      id: 'user:new-state',
      version: '2.0',
      updatedAt: DateTime(2026, 7, 1),
    );
    final repository = RulePluginRepository(extraRules: [older, newer]);
    final legacyState = RulePluginState(
      installedIds: {older.id},
      enabledIds: {older.id},
      customRules: [older, newer],
    );
    final normalized = repository.normalizeState(
      RulePluginState(
        installedIds: {older.id},
        enabledIds: {older.id},
        customRules: [older, newer],
        repositories: [
          RuleRepositoryRecord(
            id: 'old-record',
            name: '重复仓库',
            url: 'https://example.com/rules.json',
            importedAt: DateTime(2026, 1, 1),
            ruleCount: 1,
          ),
          RuleRepositoryRecord(
            id: 'new-record',
            name: '重复仓库',
            url: 'https://example.com/rules.json/',
            importedAt: DateTime(2026, 7, 1),
            ruleCount: 2,
          ),
        ],
      ),
    );

    expect(normalized.customRules, hasLength(1));
    expect(normalized.customRules.single.id, newer.id);
    expect(normalized.installedIds, {newer.id});
    expect(normalized.enabledIds, {newer.id});
    expect(normalized.repositories, hasLength(1));
    expect(normalized.repositories.single.id, 'new-record');
    expect(
      repository.playbackRulesFor(legacyState, RuleContentType.anime),
      hasLength(1),
    );
    expect(
      repository.playbackRulesFor(legacyState, RuleContentType.anime).single.id,
      newer.id,
    );
  });

  test('same host with different content types remains separate', () {
    final anime = _rule(
      id: 'user:anime',
      version: '1.0',
      updatedAt: DateTime(2026, 7, 1),
    );
    final movie = _rule(
      id: 'user:movie',
      version: '1.0',
      updatedAt: DateTime(2026, 7, 1),
      contentType: RuleContentType.movie,
    );
    final repository = RulePluginRepository(extraRules: [anime, movie]);

    expect(repository.byId(anime.id), isNotNull);
    expect(repository.byId(movie.id), isNotNull);
  });

  test(
    'same site with different engines or search routes remains separate',
    () {
      final native = _rule(
        id: 'user:native-route',
        version: '1.0',
        updatedAt: DateTime(2026, 7, 1),
      );
      final xbpq = _rule(
        id: 'user:xbpq-route',
        version: '1.0',
        updatedAt: DateTime(2026, 7, 1),
        engine: 'XBPQ',
      );
      final alternateSearch = _rule(
        id: 'user:alternate-search',
        version: '1.0',
        updatedAt: DateTime(2026, 7, 1),
        searchUrl: 'https://duplicate.example/find?q=@keyword',
      );
      final repository = RulePluginRepository(
        extraRules: [native, xbpq, alternateSearch],
      );

      expect(
        repository.allRules.where(
          (rule) => rule.baseUrl == 'https://duplicate.example/',
        ),
        hasLength(3),
      );
    },
  );

  test('ports, queries and non-Latin names are not collapsed accidentally', () {
    final portA = _rule(
      id: 'user:port-a',
      version: '1.0',
      updatedAt: DateTime(2026, 7, 1),
      baseUrl: 'https://duplicate.example:8443/api?channel=a',
    );
    final portB = _rule(
      id: 'user:port-b',
      version: '1.0',
      updatedAt: DateTime(2026, 7, 1),
      baseUrl: 'https://duplicate.example:9443/api?channel=b',
    );
    final japanese = _rule(
      id: 'user:japanese',
      name: 'アニメ配信',
      version: '1.0',
      updatedAt: DateTime(2026, 7, 1),
      baseUrl: '',
      searchUrl: '',
    );
    final korean = _rule(
      id: 'user:korean',
      name: '애니메이션',
      version: '1.0',
      updatedAt: DateTime(2026, 7, 1),
      baseUrl: '',
      searchUrl: '',
    );
    final repository = RulePluginRepository(
      extraRules: [portA, portB, japanese, korean],
    );

    expect(repository.byId(portA.id)?.id, portA.id);
    expect(repository.byId(portB.id)?.id, portB.id);
    expect(repository.byId(japanese.id)?.id, japanese.id);
    expect(repository.byId(korean.id)?.id, korean.id);
  });

  test('clipboard repositories with the same name keep separate history', () {
    final rule = _rule(
      id: 'user:repository-history',
      version: '1.0',
      updatedAt: DateTime(2026, 7, 1),
    );
    final repository = RulePluginRepository(extraRules: [rule]);
    final normalized = repository.normalizeState(
      RulePluginState(
        installedIds: {rule.id},
        customRules: [rule],
        repositories: [
          RuleRepositoryRecord(
            id: 'clipboard:first',
            name: '用户规则仓库',
            url: '',
            importedAt: DateTime(2026, 7, 1),
            ruleCount: 1,
          ),
          RuleRepositoryRecord(
            id: 'clipboard:second',
            name: '用户规则仓库',
            url: '',
            importedAt: DateTime(2026, 7, 2),
            ruleCount: 1,
          ),
        ],
      ),
    );

    expect(normalized.repositories, hasLength(2));
  });
}

RulePlugin _rule({
  required String id,
  required String version,
  required DateTime updatedAt,
  String name = '重复规则',
  String engine = 'native',
  String baseUrl = 'https://duplicate.example/',
  String searchUrl = 'https://duplicate.example/search?wd=@keyword',
  RuleContentType contentType = RuleContentType.anime,
}) {
  return RulePlugin(
    id: id,
    name: name,
    version: version,
    source: RuleSourceKind.custom,
    contentType: contentType,
    engine: engine,
    updatedAt: updatedAt,
    qualityScore: 80,
    tags: const ['native'],
    baseUrl: baseUrl,
    searchUrl: searchUrl,
    searchable: true,
    quickSearch: true,
    filterable: false,
    kazumi: const KazumiParserConfig(
      searchList: '//div',
      searchName: '//a',
      searchResult: '//a',
      chapterRoads: '//ul',
      chapterResult: '//li/a',
    ),
  );
}
