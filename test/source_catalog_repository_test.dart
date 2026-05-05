import 'package:anime/src/sources/source_catalog_models.dart';
import 'package:anime/src/sources/source_catalog_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'source catalog repository loads bundled sources_catalog.json',
    () async {
      final catalog = await const SourceCatalogRepository().loadCatalog();

      expect(catalog.version, 1);
      expect(catalog.importedCount, 10);
      expect(catalog.enabledCount, 10);
      expect(catalog.sourceById('torrent:dmhy')?.displayName, '动漫花园');
      expect(catalog.sourceById('torrent:dmhy')?.supportsSearch, isTrue);
      expect(
        catalog.sources.any((source) => source.kind == VideoSourceKind.tvBox),
        isTrue,
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
    expect(catalog.enabledCount, 9);
  });
}
