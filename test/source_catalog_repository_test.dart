import 'package:anime/src/sources/source_catalog_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bundled source catalog is empty under the v3 backend flow', () async {
    final catalog = await const SourceCatalogRepository().loadCatalog();

    expect(catalog.version, 3);
    expect(catalog.importedCount, 0);
    expect(catalog.enabledCount, 0);
    expect(catalog.sources, isEmpty);
  });

  test('source catalog applies saved enabled overrides', () async {
    final catalog = await const SourceCatalogRepository().loadCatalog(
      enabledOverrides: const {'tvbox:0ceee47b675d78d6320a8b53': false},
    );

    expect(catalog.sourceById('tvbox:0ceee47b675d78d6320a8b53'), isNull);
    expect(catalog.enabledCount, 0);
  });
}
