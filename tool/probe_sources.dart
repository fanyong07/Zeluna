import 'dart:convert';
import 'dart:io';

import 'package:anime/src/rules/tvbox_xbpq_hydrator.dart';
import 'package:anime/src/sources/external_source_adapters.dart';
import 'package:anime/src/sources/source_catalog_models.dart';

Future<void> main(List<String> arguments) async {
  final query = arguments.isEmpty ? 'CCTV' : arguments.join(' ').trim();
  final decoded = jsonDecode(
    await File('assets/data/sources_catalog.json').readAsString(),
  );
  if (decoded is! Map) throw const FormatException('Invalid source catalog');
  final catalog = SourceCatalogState.fromJson(decoded.cast<String, dynamic>());

  final hydrator = TvBoxXbpqHydrator();
  final m3u = M3uSourceAdapter();
  final dmhy = DmhySourceAdapter();
  try {
    var hydratedXbpq = 0;
    for (final source in catalog.sources.where(
      (source) => source.kind == VideoSourceKind.tvBox,
    )) {
      final result = await hydrator.hydrateSource(source);
      hydratedXbpq += result.executableRules.length;
      for (final site in result.sites) {
        final status = site.hasExecutableRule ? 'OK ' : 'SKIP';
        stdout.writeln('XBPQ $status ${site.siteName} - ${site.message}');
      }
    }
    stdout.writeln('XBPQ executable rules: $hydratedXbpq');

    final m3uResult = await m3u.search(
      sources: catalog.sources,
      query: query,
      limit: 20,
    );
    stdout.writeln(
      'M3U query "$query": ${m3uResult.items.length} result(s), '
      '${m3uResult.failures.length} failed source(s)',
    );
    for (final channel in m3uResult.items.take(8)) {
      stdout.writeln('M3U OK   ${channel.sourceName} / ${channel.name}');
    }

    final torrentResult = await dmhy.search(
      sources: catalog.sources,
      query: query,
      limit: 20,
    );
    stdout.writeln(
      'BT query "$query": ${torrentResult.items.length} result(s), '
      '${torrentResult.failures.length} failed source(s)',
    );
  } finally {
    hydrator.close();
    m3u.close();
    dmhy.close();
  }
}
