import 'package:anime/src/sources/source_catalog_models.dart';
import 'package:anime/src/sources/source_catalog_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'source catalog repository loads bundled sources_catalog.json',
    () async {
      final catalog = await const SourceCatalogRepository().loadCatalog();

      expect(catalog.version, 2);
      expect(catalog.importedCount, 12);
      expect(catalog.enabledCount, 11);
      expect(
        catalog.sourceById('m3u:d4f93800591801a8a9053c6f')?.enabled,
        isFalse,
      );
      expect(
        catalog.sourceById('public:internet_archive')?.kind,
        VideoSourceKind.publicMedia,
      );
      expect(
        catalog.sourceById('public:wikimedia_commons')?.kind,
        VideoSourceKind.publicMedia,
      );
      expect(catalog.sourceById('torrent:dmhy')?.displayName, '动漫花园');
      expect(catalog.sourceById('torrent:dmhy')?.supportsSearch, isTrue);
      expect(
        catalog.sources.any((source) => source.kind == VideoSourceKind.tvBox),
        isTrue,
      );
      expect(
        catalog
            .sourceById('tvbox:0ceee47b675d78d6320a8b53')
            ?.rawConfig['sites'],
        isA<List>(),
      );
      expect(
        catalog.sources.any((source) => source.kind == VideoSourceKind.liveM3u),
        isTrue,
      );
      expect(
        catalog.sources.any((source) => source.kind == VideoSourceKind.torrent),
        isTrue,
      );
    },
  );

  test('source catalog applies saved enabled overrides', () async {
    final catalog = await const SourceCatalogRepository().loadCatalog(
      enabledOverrides: const {'tvbox:0ceee47b675d78d6320a8b53': false},
    );

    expect(
      catalog.sourceById('tvbox:0ceee47b675d78d6320a8b53')?.enabled,
      isFalse,
    );
    expect(catalog.enabledCount, 10);
  });
}
