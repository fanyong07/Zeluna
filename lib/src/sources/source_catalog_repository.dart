import 'dart:convert';

import 'package:flutter/services.dart';

import 'source_catalog_models.dart';

class SourceCatalogRepository {
  const SourceCatalogRepository({
    this.bundle,
    this.assetPath = 'assets/data/sources_catalog.json',
  });

  final AssetBundle? bundle;
  final String assetPath;

  Future<SourceCatalogState> loadCatalog({
    Map<String, bool> enabledOverrides = const {},
  }) async {
    final text = await (bundle ?? rootBundle).loadString(assetPath);
    final decoded = jsonDecode(text);
    if (decoded is! Map) {
      throw const FormatException('sources_catalog.json root is not an object');
    }
    return SourceCatalogState.fromJson(
      decoded.cast<String, dynamic>(),
      enabledOverrides: enabledOverrides,
    );
  }
}
