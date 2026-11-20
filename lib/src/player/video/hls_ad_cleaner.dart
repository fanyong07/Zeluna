import 'dart:math' as math;

/// Result of cleaning an HLS media playlist on-device.
final class HlsCleanReport {
  const HlsCleanReport({
    this.groupsCut = 0,
    this.segmentsCut = 0,
    this.microCut = 0,
    this.secondsCut = 0.0,
    this.segmentsKept = 0,
  });

  final int groupsCut;
  final int segmentsCut;
  final int microCut;
  final double secondsCut;
  final int segmentsKept;

  bool get changed => segmentsCut > 0 || microCut > 0;
}

final class HlsCleanResult {
  const HlsCleanResult({required this.playlist, required this.report});

  final String playlist;
  final HlsCleanReport report;
}

final _uriAttrRe = RegExp(r'URI="([^"]+)"');
final _hexTokenRe = RegExp(r'[0-9a-f]{12,}', caseSensitive: false);
final _digitsRe = RegExp(r'\d+');

/// Cleans pre-roll / mid-roll / post-roll ad segments from an HLS media
/// playlist without proxying any media bytes.
///
/// Mirrors the server-side domestic collection-site rules:
/// 1. Deterministic `#EXT-X-CUE-OUT` .. `#EXT-X-CUE-IN` ranges.
/// 2. Short-segment clusters, edge micro-clusters, and odd-host clusters.
/// 3. `#EXT-X-DISCONTINUITY` mid-roll ad islands (2s–50s, <=15% segment share)
///    whose path prefix, filename skeleton, or `#EXT-X-KEY` diverges from the
///    dominant feature stream.
/// 4. Preserves `#EXT-X-DISCONTINUITY` between kept feature groups and guards
///    against over-cutting (>50% removed or <30s kept on >60s streams).
HlsCleanResult cleanHlsPlaylist(String text, {Uri? baseUri}) {
  if (text.trim().isEmpty || text.contains('#EXT-X-STREAM-INF')) {
    return HlsCleanResult(playlist: text, report: const HlsCleanReport());
  }

  final rawLines = text.split(RegExp(r'\r?\n'));
  final semanticLines = _findCueOutLines(rawLines);
  final parsed = _parseMediaPlaylist(rawLines);
  final groups = parsed.groups;
  if (groups.isEmpty) {
    return HlsCleanResult(playlist: text, report: const HlsCleanReport());
  }

  final allDurations = <double>[
    for (final group in groups)
      for (final entry in group)
        if (entry.duration != null && entry.duration! > 0) entry.duration!,
  ];
  final totalDuration = allDurations.fold<double>(0, (a, b) => a + b);
  final globalMedian = _median(allDurations);
  // Scale strictly with the playlist's own median GOP duration. A fixed 2.0s
  // floor destroys real feature segments on modern 2s-4s MacCMS HLS encodes.
  final shortThreshold = globalMedian > 0 ? globalMedian / 3.0 : 0.0;

  final totalEntries = groups.fold<int>(0, (sum, g) => sum + g.length);
  final hostCount = <String, int>{};
  final dirCount = <String, int>{};
  final skeletonCount = <String, int>{};
  final keyCount = <String, int>{};

  var activeKey = _extractKeySignature(parsed.header, baseUri) ?? 'NONE';
  final groupMeta = <_GroupMeta>[];

  for (final group in groups) {
    final gHosts = <String>{};
    final gDirs = <String>{};
    final gSkeletons = <String>{};
    final gKeys = <String>{};
    for (final entry in group) {
      final entryKey = _extractKeySignature([
        ...entry.preTags,
        ...entry.tags,
      ], baseUri);
      if (entryKey != null) activeKey = entryKey;
      gKeys.add(activeKey);
      keyCount[activeKey] = (keyCount[activeKey] ?? 0) + 1;
      for (final rawUri in entry.uris) {
        final resolved = _resolveUri(baseUri, rawUri);
        final parsedUri = Uri.tryParse(resolved);
        final host = parsedUri?.host.toLowerCase() ?? '';
        if (host.isNotEmpty) {
          gHosts.add(host);
          hostCount[host] = (hostCount[host] ?? 0) + 1;
        }
        final path = parsedUri?.path ?? rawUri.split('?').first;
        final dir = _dirPrefixOf(path);
        if (dir.isNotEmpty) {
          gDirs.add(dir);
          dirCount[dir] = (dirCount[dir] ?? 0) + 1;
        }
        final skeleton = _filenameSkeletonOf(path);
        if (skeleton.isNotEmpty) {
          gSkeletons.add(skeleton);
          skeletonCount[skeleton] = (skeletonCount[skeleton] ?? 0) + 1;
        }
      }
    }
    groupMeta.add(
      _GroupMeta(
        hosts: gHosts,
        dirs: gDirs,
        skeletons: gSkeletons,
        keys: gKeys,
      ),
    );
  }

  final dominantHost = _mostFrequent(hostCount);
  final totalHostSegments = hostCount.values.fold<int>(0, (a, b) => a + b);
  final oddHostLimit = math.max(2, (totalHostSegments * 0.05).floor());
  final dominantDir = _dominantValue(dirCount, totalEntries);
  final dominantSkeleton = _dominantValue(skeletonCount, totalEntries);
  final dominantKey = _dominantValue(keyCount, totalEntries);
  final islandMaxSegments = math.max(2, (totalEntries * 0.15).floor());

  var groupsCut = 0;
  var segmentsCut = 0;
  var secondsCut = 0.0;
  final keptGroups = <({int index, List<_PlaylistEntry> entries})>[];

  for (var i = 0; i < groups.length; i++) {
    final group = groups[i];
    final durations = <double>[
      for (final entry in group)
        if (entry.duration != null && entry.duration! > 0) entry.duration!,
    ];
    final groupTotal = durations.fold<double>(0, (a, b) => a + b);
    final groupMedian = _median(durations);
    final meta = groupMeta[i];

    var cut = false;
    if (group.every((e) => semanticLines.contains(e.lineIndex))) {
      cut = true;
    } else if (globalMedian > 0 &&
        group.length >= 2 &&
        groupMedian > 0 &&
        groupMedian <= shortThreshold) {
      cut = true;
    } else if (globalMedian > 0 &&
        groups.length > 1 &&
        (i == 0 || i == groups.length - 1) &&
        groupTotal < 60.0 &&
        groupMedian > 0 &&
        groupMedian < globalMedian * 0.7) {
      cut = true;
    } else if (dominantHost.isNotEmpty &&
        meta.hosts.any(
          (host) => host != dominantHost && (hostCount[host] ?? 0) <= oddHostLimit,
        )) {
      cut = true;
    } else if (groups.length >= 2 &&
        groupTotal >= 2.0 &&
        groupTotal <= 50.0 &&
        group.length <= islandMaxSegments) {
      if (dominantDir.isNotEmpty &&
          meta.dirs.isNotEmpty &&
          !meta.dirs.contains(dominantDir)) {
        cut = true;
      } else if (dominantSkeleton.isNotEmpty &&
          meta.skeletons.isNotEmpty &&
          !meta.skeletons.contains(dominantSkeleton)) {
        cut = true;
      } else if (dominantKey.isNotEmpty &&
          meta.keys.isNotEmpty &&
          !meta.keys.contains(dominantKey)) {
        cut = true;
      }
    }

    if (cut) {
      groupsCut++;
      segmentsCut += group.length;
      secondsCut += groupTotal;
    } else {
      keptGroups.add((index: i, entries: group));
    }
  }

  final flat = <({int groupIndex, _PlaylistEntry entry})>[
    for (final kept in keptGroups)
      for (final entry in kept.entries)
        (groupIndex: kept.index, entry: entry),
  ];
  final allowMicroShortStreak = globalMedian >= 5.0;
  final isShort = <bool>[
    for (final item in flat)
      allowMicroShortStreak &&
          item.entry.duration != null &&
          item.entry.duration! <= shortThreshold,
  ];

  bool inShortStreak(int i) {
    if (!isShort[i]) return false;
    return (i > 0 && isShort[i - 1]) ||
        (i + 1 < isShort.length && isShort[i + 1]);
  }

  var microCut = 0;
  var segmentsKept = 0;
  var keptDuration = 0.0;
  int? lastGroupIndex;
  final body = <String>[];

  for (var i = 0; i < flat.length; i++) {
    final item = flat[i];
    final entry = item.entry;
    if (semanticLines.contains(entry.lineIndex) || inShortStreak(i)) {
      microCut++;
      secondsCut += entry.duration ?? 0.0;
      continue;
    }
    if (lastGroupIndex != null && item.groupIndex == lastGroupIndex + 1) {
      body.add('#EXT-X-DISCONTINUITY');
    }
    lastGroupIndex = item.groupIndex;
    for (final tag in entry.preTags) {
      body.add(_rewriteUriAttr(tag, baseUri));
    }
    body.add(entry.extinf);
    for (final tag in entry.tags) {
      body.add(_rewriteUriAttr(tag, baseUri));
    }
    for (final uri in entry.uris) {
      body.add(_resolveUri(baseUri, uri));
    }
    segmentsKept++;
    keptDuration += entry.duration ?? 0.0;
  }

  final report = HlsCleanReport(
    groupsCut: groupsCut,
    segmentsCut: segmentsCut,
    microCut: microCut,
    secondsCut: secondsCut,
    segmentsKept: segmentsKept,
  );

  // Conservative guardrail: never wipe out more than half of a playlist.
  if (report.changed &&
      totalEntries > 0 &&
      (segmentsKept < totalEntries * 0.5 ||
          (totalDuration > 60.0 && keptDuration < 30.0))) {
    return HlsCleanResult(
      playlist: text,
      report: HlsCleanReport(segmentsKept: totalEntries),
    );
  }

  final outLines = <String>[
    for (final line in parsed.header) _rewriteUriAttr(line, baseUri),
    ...body,
    if (parsed.hasEndlist || report.changed) '#EXT-X-ENDLIST',
  ];
  return HlsCleanResult(playlist: '${outLines.join('\n')}\n', report: report);
}

Set<int> _findCueOutLines(List<String> lines) {
  final result = <int>{};
  int? openStart;
  for (var i = 0; i < lines.length; i++) {
    final upper = lines[i].trim().toUpperCase();
    if (upper.startsWith('#EXT-X-CUE-OUT')) {
      if (openStart != null) {
        for (var line = openStart + 1; line < i; line++) {
          result.add(line);
        }
      }
      openStart = i;
    } else if (upper.startsWith('#EXT-X-CUE-IN') && openStart != null) {
      for (var line = openStart + 1; line < i; line++) {
        result.add(line);
      }
      openStart = null;
    }
  }
  if (openStart != null) {
    for (var line = openStart + 1; line < lines.length; line++) {
      result.add(line);
    }
  }
  return result;
}

_ParsedPlaylist _parseMediaPlaylist(List<String> lines) {
  final header = <String>[];
  final groups = <List<_PlaylistEntry>>[];
  _PlaylistEntry? currentEntry;
  List<_PlaylistEntry>? currentGroup;
  var pendingTags = <String>[];
  var seenMedia = false;
  var hasEndlist = false;

  void flushEntry() {
    if (currentEntry != null) {
      currentGroup ??= <_PlaylistEntry>[];
      currentGroup!.add(currentEntry!);
      currentEntry = null;
    }
  }

  void flushGroup() {
    flushEntry();
    if (currentGroup != null && currentGroup!.isNotEmpty) {
      groups.add(currentGroup!);
    }
    currentGroup = null;
  }

  for (var i = 0; i < lines.length; i++) {
    final raw = lines[i];
    final stripped = raw.trim();
    if (stripped.isEmpty) continue;
    final upper = stripped.toUpperCase();
    if (upper == '#EXT-X-DISCONTINUITY') {
      flushGroup();
      continue;
    }
    if (upper == '#EXT-X-ENDLIST') {
      hasEndlist = true;
      continue;
    }
    if (upper.startsWith('#EXTINF')) {
      flushEntry();
      seenMedia = true;
      double? duration;
      final colon = stripped.indexOf(':');
      if (colon >= 0) {
        final rawDur = stripped.substring(colon + 1).split(',').first.trim();
        duration = double.tryParse(rawDur);
      }
      currentEntry = _PlaylistEntry(
        extinf: raw,
        duration: duration,
        lineIndex: i,
        preTags: pendingTags,
      );
      pendingTags = <String>[];
    } else if (stripped.startsWith('#')) {
      if (currentEntry != null) {
        if (upper.startsWith('#EXT-X-KEY') || upper.startsWith('#EXT-X-MAP')) {
          pendingTags.add(raw);
        } else {
          currentEntry!.tags.add(raw);
        }
      } else if (seenMedia) {
        pendingTags.add(raw);
      } else {
        header.add(raw);
      }
    } else {
      if (currentEntry != null) {
        currentEntry!.uris.add(stripped);
      } else {
        header.add(raw);
      }
    }
  }
  flushGroup();
  return _ParsedPlaylist(
    header: header,
    groups: groups,
    hasEndlist: hasEndlist,
  );
}

String _resolveUri(Uri? baseUri, String uri) {
  if (baseUri == null ||
      uri.startsWith('http://') ||
      uri.startsWith('https://')) {
    return uri;
  }
  return baseUri.resolve(uri).toString();
}

String _rewriteUriAttr(String tag, Uri? baseUri) {
  if (baseUri == null || !tag.contains('URI="')) return tag;
  return tag.replaceAllMapped(
    _uriAttrRe,
    (match) => 'URI="${_resolveUri(baseUri, match.group(1)!)}"',
  );
}

String _dirPrefixOf(String path) {
  final slash = path.lastIndexOf('/');
  return slash <= 0 ? '' : path.substring(0, slash);
}

String _filenameSkeletonOf(String path) {
  final name = path.split('/').last;
  if (name.isEmpty) return '';
  return name.replaceAll(_hexTokenRe, 'H').replaceAll(_digitsRe, '#');
}

String? _extractKeySignature(List<String> tags, Uri? baseUri) {
  String? keySig;
  for (final tag in tags) {
    final upper = tag.trim().toUpperCase();
    if (!upper.startsWith('#EXT-X-KEY:')) continue;
    if (upper.replaceAll(' ', '').contains('METHOD=NONE')) {
      keySig = 'NONE';
      continue;
    }
    final match = _uriAttrRe.firstMatch(tag);
    keySig = match != null
        ? _resolveUri(baseUri, match.group(1)!)
        : tag.trim();
  }
  return keySig;
}

String _mostFrequent(Map<String, int> counts) {
  var bestKey = '';
  var bestValue = -1;
  for (final entry in counts.entries) {
    if (entry.value > bestValue) {
      bestKey = entry.key;
      bestValue = entry.value;
    }
  }
  return bestKey;
}

String _dominantValue(Map<String, int> counts, int total) {
  if (counts.isEmpty || total <= 0) return '';
  final best = _mostFrequent(counts);
  return (counts[best]! / total) >= 0.6 ? best : '';
}

double _median(List<double> values) {
  if (values.isEmpty) return 0.0;
  final sorted = [...values]..sort();
  final mid = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[mid]
      : (sorted[mid - 1] + sorted[mid]) / 2.0;
}

final class _ParsedPlaylist {
  const _ParsedPlaylist({
    required this.header,
    required this.groups,
    required this.hasEndlist,
  });

  final List<String> header;
  final List<List<_PlaylistEntry>> groups;
  final bool hasEndlist;
}

final class _PlaylistEntry {
  _PlaylistEntry({
    required this.extinf,
    required this.duration,
    required this.lineIndex,
    required this.preTags,
  });

  final String extinf;
  final double? duration;
  final int lineIndex;
  final List<String> preTags;
  final List<String> tags = <String>[];
  final List<String> uris = <String>[];
}

final class _GroupMeta {
  const _GroupMeta({
    required this.hosts,
    required this.dirs,
    required this.skeletons,
    required this.keys,
  });

  final Set<String> hosts;
  final Set<String> dirs;
  final Set<String> skeletons;
  final Set<String> keys;
}
