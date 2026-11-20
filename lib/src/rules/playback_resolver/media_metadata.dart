part of '../rule_playback_resolver.dart';

// Media signature validation and HLS/DASH metadata parsing.

class _ProbeMediaMetadata {
  const _ProbeMediaMetadata({
    this.format,
    this.startupProfile = PlaybackStartupProfile.unknown,
    this.sizeBytes,
    this.sizeEstimated = false,
    this.videoWidth,
    this.videoHeight,
    this.bitrate,
    this.codecs,
    this.isLive = false,
    this.adaptive = false,
    this.variantUri,
    this.variants = const <_HlsProbeVariant>[],
    this.durationSeconds,
    this.sampleSegmentUri,
    this.sampleSegmentUris = const <Uri>[],
    this.segmentCandidates = const <_HlsProbeSegment>[],
    this.sampleSegmentDurationSeconds,
    this.dashResources = const <_DashProbeResource>[],
  });

  final String? format;
  final String startupProfile;
  final int? sizeBytes;
  final bool sizeEstimated;
  final int? videoWidth;
  final int? videoHeight;
  final int? bitrate;
  final String? codecs;
  final bool isLive;
  final bool adaptive;
  final Uri? variantUri;
  final List<_HlsProbeVariant> variants;
  final double? durationSeconds;
  final Uri? sampleSegmentUri;
  final List<Uri> sampleSegmentUris;
  final List<_HlsProbeSegment> segmentCandidates;
  final double? sampleSegmentDurationSeconds;
  final List<_DashProbeResource> dashResources;

  _ProbeMediaMetadata copyWith({
    String? startupProfile,
    int? sizeBytes,
    bool? sizeEstimated,
    bool? isLive,
    double? durationSeconds,
    Uri? sampleSegmentUri,
    List<Uri>? sampleSegmentUris,
    List<_HlsProbeSegment>? segmentCandidates,
    double? sampleSegmentDurationSeconds,
  }) {
    return _ProbeMediaMetadata(
      format: format,
      startupProfile: startupProfile ?? this.startupProfile,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      sizeEstimated: sizeEstimated ?? this.sizeEstimated,
      videoWidth: videoWidth,
      videoHeight: videoHeight,
      bitrate: bitrate,
      codecs: codecs,
      isLive: isLive ?? this.isLive,
      adaptive: adaptive,
      variantUri: variantUri,
      variants: variants,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      sampleSegmentUri: sampleSegmentUri ?? this.sampleSegmentUri,
      sampleSegmentUris: sampleSegmentUris ?? this.sampleSegmentUris,
      segmentCandidates: segmentCandidates ?? this.segmentCandidates,
      sampleSegmentDurationSeconds:
          sampleSegmentDurationSeconds ?? this.sampleSegmentDurationSeconds,
      dashResources: dashResources,
    );
  }
}

_ProbeMediaMetadata _mediaMetadataFromSample(
  Uri sourceUri,
  _PlayableProbeResponse sample,
) {
  final text = utf8.decode(sample.sample, allowMalformed: true);
  final format = _detectedMediaFormat(
    sourceUri,
    sample.response.headers['content-type'],
    text,
  );
  if (format == 'HLS') {
    return _hlsProbeMetadata(
      sourceUri,
      text,
      sampleComplete: sample.sampleComplete,
    ).copyWith(startupProfile: PlaybackStartupProfile.hls);
  }
  if (format == 'DASH') return _dashProbeMetadata(sourceUri, text);

  final dimensions = format == 'MP4'
      ? _mp4Dimensions(sample.sample) ?? _resolutionDimensionsForUrl(sourceUri)
      : _resolutionDimensionsForUrl(sourceUri);
  return _ProbeMediaMetadata(
    format: format,
    startupProfile: format == 'MP4'
        ? _mp4StartupProfile(sample.sample)
        : PlaybackStartupProfile.unknown,
    sizeBytes: _responseTotalBytes(sample.response),
    videoWidth: dimensions?.width,
    videoHeight: dimensions?.height,
  );
}

final RegExp _hlsExtensionPattern = RegExp(r'\.m3u8(?:$|[?#])');
final RegExp _dashExtensionPattern = RegExp(r'\.mpd(?:$|[?#])');
final RegExp _mp4ExtensionPattern = RegExp(r'\.(?:mp4|m4v)(?:$|[?#])');
final RegExp _webmExtensionPattern = RegExp(r'\.webm(?:$|[?#])');
final RegExp _flvExtensionPattern = RegExp(r'\.flv(?:$|[?#])');
final RegExp _mkvExtensionPattern = RegExp(r'\.mkv(?:$|[?#])');
final RegExp _manifestExtensionPattern = RegExp(r'\.(?:m3u8|mpd)(?:$|[?#])');

String? _detectedMediaFormat(
  Uri sourceUri,
  String? rawContentType,
  String sampleText,
) {
  final contentType = (rawContentType ?? '').toLowerCase();
  final lowerUrl = sourceUri.toString().toLowerCase();
  final trimmed = sampleText.trimLeft();
  if (trimmed.startsWith('#EXTM3U')) {
    return 'HLS';
  }
  if (trimmed.startsWith('<MPD') || trimmed.contains('<MPD ')) {
    return 'DASH';
  }
  if (contentType.contains('mpegurl')) return 'HLS';
  if (contentType.contains('dash+xml')) return 'DASH';
  if (contentType.contains('video/mp4')) {
    return 'MP4';
  }
  if (contentType.contains('webm')) {
    return 'WebM';
  }
  if (contentType.contains('x-flv')) {
    return 'FLV';
  }
  if (contentType.contains('matroska')) {
    return 'MKV';
  }
  if (_hlsExtensionPattern.hasMatch(lowerUrl)) return 'HLS';
  if (_dashExtensionPattern.hasMatch(lowerUrl)) return 'DASH';
  if (_mp4ExtensionPattern.hasMatch(lowerUrl)) return 'MP4';
  if (_webmExtensionPattern.hasMatch(lowerUrl)) return 'WebM';
  if (_flvExtensionPattern.hasMatch(lowerUrl)) return 'FLV';
  if (_mkvExtensionPattern.hasMatch(lowerUrl)) return 'MKV';
  return null;
}

bool _isManifestResponse(Uri requestUri, http.StreamedResponse response) {
  final contentType = response.headers['content-type']?.toLowerCase() ?? '';
  if (contentType.contains('mpegurl') || contentType.contains('dash+xml')) {
    return true;
  }
  final target = ruleProxyUpstreamUri(requestUri) ?? requestUri;
  final lower = target.toString().toLowerCase();
  return _manifestExtensionPattern.hasMatch(lower);
}

Uri _resolvePlaylistReference(Uri playlistUri, String rawReference) {
  final reference = Uri.tryParse(rawReference.trim());
  if (reference == null) return playlistUri.resolve(rawReference);
  final upstream = ruleProxyUpstreamUri(reference);
  if (upstream != null) {
    if (kIsWeb) {
      return reference.hasScheme ? reference : Uri.base.resolveUri(reference);
    }
    return upstream;
  }
  return playlistUri.resolveUri(reference);
}

Uri? _safeHttpPlaylistReference(Uri playlistUri, String rawReference) {
  try {
    final resolved = _resolvePlaylistReference(playlistUri, rawReference);
    final upstream = ruleProxyUpstreamUri(resolved) ?? resolved;
    if (!const {'http', 'https'}.contains(upstream.scheme.toLowerCase()) ||
        upstream.host.isEmpty) {
      return null;
    }
    return resolved;
  } catch (_) {
    return null;
  }
}

_ProbeMediaMetadata _hlsProbeMetadata(
  Uri sourceUri,
  String manifest, {
  required bool sampleComplete,
}) {
  final lines = manifest
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n')
      .map((line) => line.trim())
      .toList(growable: false);
  final variants = <_HlsProbeVariant>[];
  for (var index = 0; index < lines.length; index++) {
    final line = lines[index];
    if (!line.startsWith('#EXT-X-STREAM-INF:')) continue;
    final attributes = _parseHlsAttributes(
      line.substring(line.indexOf(':') + 1),
    );
    String? uriText;
    for (var uriIndex = index + 1; uriIndex < lines.length; uriIndex++) {
      final candidate = lines[uriIndex];
      if (candidate.isEmpty || candidate.startsWith('#')) continue;
      uriText = candidate;
      break;
    }
    if (uriText == null) continue;
    final dimensions = _resolutionDimensions(attributes['RESOLUTION'] ?? '');
    final variantUri = _safeHttpPlaylistReference(sourceUri, uriText);
    if (variantUri != null) {
      variants.add(
        _HlsProbeVariant(
          uri: variantUri,
          width: dimensions?.width,
          height: dimensions?.height,
          bitrate:
              int.tryParse(attributes['AVERAGE-BANDWIDTH'] ?? '') ??
              int.tryParse(attributes['BANDWIDTH'] ?? ''),
          codecs: attributes['CODECS'],
        ),
      );
    }
  }
  if (variants.isNotEmpty) {
    variants.sort((left, right) {
      final pixels = right.pixelCount.compareTo(left.pixelCount);
      if (pixels != 0) return pixels;
      return (right.bitrate ?? 0).compareTo(left.bitrate ?? 0);
    });
    final selected = variants.first;
    return _ProbeMediaMetadata(
      format: 'HLS',
      videoWidth: selected.width,
      videoHeight: selected.height,
      bitrate: selected.bitrate,
      codecs: selected.codecs,
      adaptive: true,
      variantUri: selected.uri,
      variants: List<_HlsProbeVariant>.unmodifiable(variants),
    );
  }

  final hasEndList = lines.contains('#EXT-X-ENDLIST');
  final durationSeconds = lines
      .where((line) => line.startsWith('#EXTINF:'))
      .map((line) => line.substring('#EXTINF:'.length).split(',').first)
      .map(double.tryParse)
      .whereType<double>()
      .fold<double>(0, (total, duration) => total + duration);
  var byteRangeBytes = 0;
  var mediaSegmentCount = 0;
  var rangedMediaSegmentCount = 0;
  Uri? sampleSegmentUri;
  final sampleSegmentUris = <Uri>[];
  final segmentCandidates = <_HlsProbeSegment>[];
  double? sampleSegmentDurationSeconds;
  double? pendingDuration;
  int? pendingByteRangeBytes;
  String? encryptionMethod;
  Uri? encryptionKeyUri;
  for (final line in lines) {
    if (line.startsWith('#EXTINF:')) {
      pendingDuration = double.tryParse(
        line.substring('#EXTINF:'.length).split(',').first,
      );
      continue;
    }
    if (line.startsWith('#EXT-X-KEY:')) {
      final attributes = _parseHlsAttributes(
        line.substring(line.indexOf(':') + 1),
      );
      final method = attributes['METHOD']?.trim().toUpperCase();
      if (method == null || method.isEmpty || method == 'NONE') {
        encryptionMethod = null;
        encryptionKeyUri = null;
      } else {
        encryptionMethod = method;
        final rawKeyUri = attributes['URI']?.trim();
        encryptionKeyUri = rawKeyUri == null || rawKeyUri.isEmpty
            ? null
            : _safeHttpPlaylistReference(sourceUri, rawKeyUri);
      }
      continue;
    }
    if (line.startsWith('#EXT-X-BYTERANGE:')) {
      pendingByteRangeBytes = int.tryParse(
        line.substring('#EXT-X-BYTERANGE:'.length).split('@').first.trim(),
      );
      continue;
    }
    if (line.isEmpty || line.startsWith('#') || pendingDuration == null) {
      continue;
    }
    mediaSegmentCount++;
    if (pendingByteRangeBytes != null && pendingByteRangeBytes > 0) {
      rangedMediaSegmentCount++;
      byteRangeBytes += pendingByteRangeBytes;
    }
    final segmentUri = _safeHttpPlaylistReference(sourceUri, line);
    if (segmentUri != null) {
      sampleSegmentUris.add(segmentUri);
      segmentCandidates.add(
        _HlsProbeSegment(
          uri: segmentUri,
          encryptionMethod: encryptionMethod,
          keyUri: encryptionKeyUri,
        ),
      );
    }
    sampleSegmentDurationSeconds ??= pendingDuration;
    pendingDuration = null;
    pendingByteRangeBytes = null;
  }
  final hasExactByteRangeTotal =
      mediaSegmentCount > 0 &&
      rangedMediaSegmentCount == mediaSegmentCount &&
      byteRangeBytes > 0;
  final dimensions = _resolutionDimensionsForUrl(sourceUri);
  final orderedSegmentUris = hasEndList
      ? sampleSegmentUris
      : sampleSegmentUris.reversed.toList(growable: false);
  final orderedSegmentCandidates = hasEndList
      ? segmentCandidates
      : segmentCandidates.reversed.toList(growable: false);
  sampleSegmentUri = _firstOrNull(orderedSegmentUris);
  return _ProbeMediaMetadata(
    format: 'HLS',
    sizeBytes: hasEndList && hasExactByteRangeTotal ? byteRangeBytes : null,
    videoWidth: dimensions?.width,
    videoHeight: dimensions?.height,
    isLive: sampleComplete && !hasEndList,
    durationSeconds: hasEndList && durationSeconds > 0 ? durationSeconds : null,
    sampleSegmentUri: sampleSegmentUri,
    sampleSegmentUris: List<Uri>.unmodifiable(orderedSegmentUris),
    segmentCandidates: List<_HlsProbeSegment>.unmodifiable(
      orderedSegmentCandidates,
    ),
    sampleSegmentDurationSeconds: sampleSegmentDurationSeconds,
  );
}

_ProbeMediaMetadata _dashProbeMetadata(Uri sourceUri, String manifest) {
  try {
    final document = XmlDocument.parse(manifest);
    final elements = document.descendants.whereType<XmlElement>().toList();
    final mpd = _firstOrNull(
      elements.where((item) => item.name.local == 'MPD'),
    );
    final isDynamic = mpd?.getAttribute('type')?.toLowerCase() == 'dynamic';
    final durationSeconds = _parseIsoDurationSeconds(
      mpd?.getAttribute('mediaPresentationDuration') ??
          _firstOrNull(
            elements
                .where((item) => item.name.local == 'Period')
                .map((item) => item.getAttribute('duration'))
                .whereType<String>(),
          ),
    );
    final allRepresentations = elements
        .where((item) => item.name.local == 'Representation')
        .toList();
    final audioRepresentations = allRepresentations.where((item) {
      final mimeType = _xmlInheritedAttribute(item, 'mimeType') ?? '';
      final contentType = _xmlInheritedAttribute(item, 'contentType') ?? '';
      return mimeType.toLowerCase().startsWith('audio/') ||
          contentType.toLowerCase() == 'audio';
    }).toList();
    var representations = allRepresentations.where((item) {
      final mimeType = _xmlInheritedAttribute(item, 'mimeType') ?? '';
      final contentType = _xmlInheritedAttribute(item, 'contentType') ?? '';
      return mimeType.toLowerCase().startsWith('video/') ||
          contentType.toLowerCase() == 'video' ||
          _xmlInheritedInt(item, 'width') != null ||
          _xmlInheritedInt(item, 'height') != null;
    }).toList();
    if (representations.isEmpty) {
      representations = allRepresentations
          .where((item) => !audioRepresentations.contains(item))
          .toList();
    }
    if (representations.isEmpty) representations = [...allRepresentations];
    representations.sort((left, right) {
      final leftWidth = _xmlInheritedInt(left, 'width') ?? 0;
      final leftHeight = _xmlInheritedInt(left, 'height') ?? 0;
      final rightWidth = _xmlInheritedInt(right, 'width') ?? 0;
      final rightHeight = _xmlInheritedInt(right, 'height') ?? 0;
      final pixels = (rightWidth * rightHeight).compareTo(
        leftWidth * leftHeight,
      );
      if (pixels != 0) return pixels;
      return (_xmlInheritedInt(right, 'bandwidth') ?? 0).compareTo(
        _xmlInheritedInt(left, 'bandwidth') ?? 0,
      );
    });
    final selected = _firstOrNull(representations);
    audioRepresentations.sort(
      (left, right) => (_xmlInheritedInt(right, 'bandwidth') ?? 0).compareTo(
        _xmlInheritedInt(left, 'bandwidth') ?? 0,
      ),
    );
    final selectedAudio = _firstOrNull(audioRepresentations);
    final width = selected == null ? null : _xmlInheritedInt(selected, 'width');
    final height = selected == null
        ? null
        : _xmlInheritedInt(selected, 'height');
    final videoBitrate = selected == null
        ? null
        : _xmlInheritedInt(selected, 'bandwidth');
    final audioBitrate = selectedAudio == null
        ? null
        : _xmlInheritedInt(selectedAudio, 'bandwidth');
    final bitrate = videoBitrate == null && audioBitrate == null
        ? null
        : (videoBitrate ?? 0) + (audioBitrate ?? 0);
    final videoCodecs = selected == null
        ? null
        : _xmlInheritedAttribute(selected, 'codecs');
    final audioCodecs = selectedAudio == null
        ? null
        : _xmlInheritedAttribute(selectedAudio, 'codecs');
    final codecs = [
      videoCodecs,
      audioCodecs,
    ].whereType<String>().where((item) => item.trim().isNotEmpty).join(',');
    final estimatedBytes =
        !isDynamic &&
            durationSeconds != null &&
            durationSeconds > 0 &&
            bitrate != null &&
            bitrate > 0
        ? (bitrate * durationSeconds / 8).round()
        : null;
    final fallbackDimensions = _resolutionDimensionsForUrl(sourceUri);
    final resources = selected == null
        ? const <_DashProbeResource>[]
        : _dashProbeResources(sourceUri, selected);
    return _ProbeMediaMetadata(
      format: 'DASH',
      sizeBytes: estimatedBytes,
      sizeEstimated: estimatedBytes != null,
      videoWidth: width ?? fallbackDimensions?.width,
      videoHeight: height ?? fallbackDimensions?.height,
      bitrate: bitrate,
      codecs: codecs.isEmpty ? null : codecs,
      isLive: isDynamic,
      adaptive: representations.length > 1,
      durationSeconds: durationSeconds,
      dashResources: resources,
    );
  } catch (_) {
    final dimensions = _resolutionDimensionsForUrl(sourceUri);
    return _ProbeMediaMetadata(
      format: 'DASH',
      videoWidth: dimensions?.width,
      videoHeight: dimensions?.height,
    );
  }
}

List<_DashProbeResource> _dashProbeResources(
  Uri manifestUri,
  XmlElement representation,
) {
  final resources = <_DashProbeResource>[];
  final baseUri = _dashRepresentationBaseUri(manifestUri, representation);
  final templateAttributes = _dashSegmentTemplateAttributes(representation);
  if (templateAttributes.isNotEmpty) {
    final initialization = _dashExpandTemplate(
      templateAttributes['initialization'],
      representation,
      templateAttributes,
    );
    final media = _dashExpandTemplate(
      templateAttributes['media'],
      representation,
      templateAttributes,
    );
    final initializationUri = initialization == null
        ? null
        : _safeHttpPlaylistReference(baseUri, initialization);
    final mediaUri = media == null
        ? null
        : _safeHttpPlaylistReference(baseUri, media);
    if (initializationUri != null) {
      resources.add(_DashProbeResource(initializationUri, '初始化分片'));
    }
    if (mediaUri != null && mediaUri != initializationUri) {
      resources.add(_DashProbeResource(mediaUri, '媒体分片'));
    }
  }

  if (resources.isEmpty) {
    final segmentList = _dashInheritedChild(representation, 'SegmentList');
    if (segmentList != null) {
      final initialization = _xmlDirectChild(segmentList, 'Initialization');
      final initializationSource = initialization?.getAttribute('sourceURL');
      final initializationUri = initializationSource == null
          ? null
          : _safeHttpPlaylistReference(baseUri, initializationSource);
      if (initializationUri != null) {
        resources.add(_DashProbeResource(initializationUri, '初始化分片'));
      }
      final firstSegment = _firstOrNull(
        _xmlDirectChildren(segmentList, 'SegmentURL'),
      );
      final mediaSource = firstSegment?.getAttribute('media');
      final mediaUri = mediaSource == null
          ? null
          : _safeHttpPlaylistReference(baseUri, mediaSource);
      if (mediaUri != null && mediaUri != initializationUri) {
        resources.add(_DashProbeResource(mediaUri, '媒体分片'));
      }
    }
  }

  if (resources.isEmpty) {
    final segmentBase = _dashInheritedChild(representation, 'SegmentBase');
    final directBase = _xmlDirectChild(representation, 'BaseURL');
    if (directBase != null || (segmentBase != null && baseUri != manifestUri)) {
      resources.add(_DashProbeResource(baseUri, '媒体文件'));
    }
  }
  return List<_DashProbeResource>.unmodifiable(resources);
}

Uri _dashRepresentationBaseUri(Uri manifestUri, XmlElement representation) {
  final hierarchy = <XmlElement>[];
  XmlNode? current = representation;
  while (current is XmlElement) {
    hierarchy.add(current);
    current = current.parent;
  }
  var result = manifestUri;
  for (final element in hierarchy.reversed) {
    final baseText = _xmlDirectChild(element, 'BaseURL')?.innerText.trim();
    if (baseText != null && baseText.isNotEmpty) {
      result = _safeHttpPlaylistReference(result, baseText) ?? result;
    }
  }
  return result;
}

Map<String, String> _dashSegmentTemplateAttributes(XmlElement representation) {
  final hierarchy = <XmlElement>[];
  XmlNode? current = representation;
  while (current is XmlElement) {
    hierarchy.add(current);
    current = current.parent;
  }
  final result = <String, String>{};
  XmlElement? timelineSource;
  for (final element in hierarchy.reversed) {
    final template = _xmlDirectChild(element, 'SegmentTemplate');
    if (template == null) continue;
    for (final attribute in template.attributes) {
      result[attribute.name.local] = attribute.value;
    }
    if (_xmlDirectChild(template, 'SegmentTimeline') != null) {
      timelineSource = template;
    }
  }
  final timeline = timelineSource == null
      ? null
      : _xmlDirectChild(timelineSource, 'SegmentTimeline');
  final firstTimelineEntry = timeline == null
      ? null
      : _firstOrNull(_xmlDirectChildren(timeline, 'S'));
  final timelineStart = firstTimelineEntry?.getAttribute('t');
  if (timelineStart != null && timelineStart.isNotEmpty) {
    result['_firstTime'] = timelineStart;
  }
  return result;
}

String? _dashExpandTemplate(
  String? template,
  XmlElement representation,
  Map<String, String> attributes,
) {
  if (template == null || template.trim().isEmpty) return null;
  var result = template.trim();
  final representationId = representation.getAttribute('id') ?? '';
  final bandwidth =
      representation.getAttribute('bandwidth') ??
      _xmlInheritedAttribute(representation, 'bandwidth') ??
      '';
  result = result
      .replaceAll(r'$RepresentationID$', representationId)
      .replaceAll(r'$Bandwidth$', bandwidth);
  final number = int.tryParse(attributes['startNumber'] ?? '') ?? 1;
  result = result.replaceAllMapped(RegExp(r'\$Number(?:%0(\d+)d)?\$'), (match) {
    final width = int.tryParse(match.group(1) ?? '') ?? 0;
    return width <= 0 ? '$number' : number.toString().padLeft(width, '0');
  });
  if (result.contains(r'$Time$')) {
    final firstTime = attributes['_firstTime'];
    if (firstTime == null || firstTime.isEmpty) return null;
    result = result.replaceAll(r'$Time$', firstTime);
  }
  return result.replaceAll(r'$$', r'$');
}

XmlElement? _dashInheritedChild(XmlElement element, String localName) {
  XmlNode? current = element;
  while (current is XmlElement) {
    final child = _xmlDirectChild(current, localName);
    if (child != null) return child;
    current = current.parent;
  }
  return null;
}

XmlElement? _xmlDirectChild(XmlElement element, String localName) {
  for (final child in element.childElements) {
    if (child.name.local == localName) return child;
  }
  return null;
}

List<XmlElement> _xmlDirectChildren(XmlElement element, String localName) {
  return element.childElements
      .where((child) => child.name.local == localName)
      .toList(growable: false);
}

Map<String, String> _parseHlsAttributes(String value) {
  final result = <String, String>{};
  var index = 0;
  while (index < value.length) {
    while (index < value.length &&
        (value.codeUnitAt(index) == 44 || value.codeUnitAt(index) == 32)) {
      index++;
    }
    final equals = value.indexOf('=', index);
    if (equals < 0) break;
    final key = value.substring(index, equals).trim().toUpperCase();
    index = equals + 1;
    String parsed;
    if (index < value.length && value.codeUnitAt(index) == 34) {
      index++;
      final end = value.indexOf('"', index);
      if (end < 0) {
        parsed = value.substring(index);
        index = value.length;
      } else {
        parsed = value.substring(index, end);
        index = end + 1;
      }
    } else {
      final comma = value.indexOf(',', index);
      if (comma < 0) {
        parsed = value.substring(index).trim();
        index = value.length;
      } else {
        parsed = value.substring(index, comma).trim();
        index = comma + 1;
      }
    }
    if (key.isNotEmpty) result[key] = parsed;
  }
  return result;
}

class _HlsProbeVariant {
  const _HlsProbeVariant({
    required this.uri,
    this.width,
    this.height,
    this.bitrate,
    this.codecs,
  });

  final Uri uri;
  final int? width;
  final int? height;
  final int? bitrate;
  final String? codecs;

  int get pixelCount => (width ?? 0) * (height ?? 0);
}

class _HlsProbeSegment {
  const _HlsProbeSegment({
    required this.uri,
    this.encryptionMethod,
    this.keyUri,
  });

  final Uri uri;
  final String? encryptionMethod;
  final Uri? keyUri;

  bool get usesAes128 => encryptionMethod?.toUpperCase() == 'AES-128';
}

class _DashProbeResource {
  const _DashProbeResource(this.uri, this.label);

  final Uri uri;
  final String label;
}

class _ResolutionDimensions {
  const _ResolutionDimensions({this.width, this.height});

  final int? width;
  final int? height;
}

_ResolutionDimensions? _resolutionDimensions(String value) {
  final match = RegExp(
    r'(\d{2,5})\s*x\s*(\d{2,5})',
    caseSensitive: false,
  ).firstMatch(value);
  final width = int.tryParse(match?.group(1) ?? '');
  final height = int.tryParse(match?.group(2) ?? '');
  if (width == null || height == null || width <= 0 || height <= 0) {
    return null;
  }
  return _ResolutionDimensions(width: width, height: height);
}

_ResolutionDimensions? _resolutionDimensionsForUrl(Uri uri) {
  final text = Uri.decodeFull(uri.toString());
  final exact = _resolutionDimensions(text);
  if (exact != null) return exact;
  final lower = text.toLowerCase();
  if (RegExp(r'(^|[^a-z0-9])4k([^a-z0-9]|$)').hasMatch(lower) ||
      RegExp(r'(^|[^0-9])2160p?([^0-9]|$)').hasMatch(lower)) {
    return const _ResolutionDimensions(width: 3840, height: 2160);
  }
  for (final height in const [1440, 1080, 720, 576, 480, 360, 240]) {
    if (RegExp('(^|[^0-9])${height}p?([^0-9]|\$)').hasMatch(lower)) {
      return _ResolutionDimensions(height: height);
    }
  }
  return null;
}

_ResolutionDimensions? _mp4Dimensions(List<int> bytes) {
  if (bytes.length < 92) return null;
  final data = ByteData.sublistView(Uint8List.fromList(bytes));
  _ResolutionDimensions? best;
  for (var typeOffset = 4; typeOffset + 4 <= bytes.length; typeOffset++) {
    if (bytes[typeOffset] != 0x74 ||
        bytes[typeOffset + 1] != 0x6B ||
        bytes[typeOffset + 2] != 0x68 ||
        bytes[typeOffset + 3] != 0x64) {
      continue;
    }
    final dataOffset = typeOffset + 4;
    if (dataOffset >= bytes.length) continue;
    final version = bytes[dataOffset];
    final widthOffset = dataOffset + (version == 1 ? 88 : 76);
    final heightOffset = widthOffset + 4;
    if (heightOffset + 4 > bytes.length) continue;
    final width = data.getUint32(widthOffset, Endian.big) >> 16;
    final height = data.getUint32(heightOffset, Endian.big) >> 16;
    if (width < 16 || width > 16384 || height < 16 || height > 16384) {
      continue;
    }
    final candidate = _ResolutionDimensions(width: width, height: height);
    if (best == null ||
        width * height > (best.width ?? 0) * (best.height ?? 0)) {
      best = candidate;
    }
  }
  return best;
}

String? _xmlInheritedAttribute(XmlElement element, String name) {
  XmlNode? current = element;
  while (current is XmlElement) {
    final value = current.getAttribute(name)?.trim();
    if (value != null && value.isNotEmpty) return value;
    current = current.parent;
  }
  return null;
}

T? _firstOrNull<T>(Iterable<T> values) {
  for (final value in values) {
    return value;
  }
  return null;
}

int? _xmlInheritedInt(XmlElement element, String name) {
  return int.tryParse(_xmlInheritedAttribute(element, name) ?? '');
}

double? _parseIsoDurationSeconds(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  final match = RegExp(
    r'^P(?:(\d+(?:\.\d+)?)D)?(?:T(?:(\d+(?:\.\d+)?)H)?(?:(\d+(?:\.\d+)?)M)?(?:(\d+(?:\.\d+)?)S)?)?$',
  ).firstMatch(value.trim().toUpperCase());
  if (match == null) return null;
  final days = double.tryParse(match.group(1) ?? '') ?? 0;
  final hours = double.tryParse(match.group(2) ?? '') ?? 0;
  final minutes = double.tryParse(match.group(3) ?? '') ?? 0;
  final seconds = double.tryParse(match.group(4) ?? '') ?? 0;
  return days * 86400 + hours * 3600 + minutes * 60 + seconds;
}

_PlayableProbeResult _validatePlayableSample(
  Uri sourceUri,
  _PlayableProbeResponse sample,
) {
  final bytes = sample.sample;
  final rawContentType =
      sample.response.headers['content-type']?.toLowerCase() ?? '';
  final contentType = rawContentType.split(';').first.trim();
  final text = utf8.decode(bytes, allowMalformed: true);
  final trimmed = text.trimLeft();
  if (bytes.isEmpty) {
    return const _PlayableProbeResult(false, '视频地址返回了空内容。');
  }
  final lowerText = trimmed.toLowerCase();
  final looksLikeHtml =
      lowerText.startsWith('<!doctype html') ||
      lowerText.startsWith('<html') ||
      lowerText.startsWith('<head') ||
      lowerText.startsWith('<body') ||
      lowerText.contains('<html');
  if (looksLikeHtml) {
    return const _PlayableProbeResult(false, '视频地址返回的是网页或错误信息，不是媒体内容。');
  }

  final format = _detectedMediaFormat(sourceUri, rawContentType, text);
  if (format == 'HLS') {
    final manifestLines = trimmed
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n')
        .map((line) => line.trim())
        .toList(growable: false);
    final hasHeader =
        manifestLines.isNotEmpty && manifestLines.first == '#EXTM3U';
    final hasMediaReference = manifestLines.any(
      (line) => line.isNotEmpty && !line.startsWith('#'),
    );
    if (!hasHeader || !hasMediaReference) {
      return const _PlayableProbeResult(false, '视频地址返回的 HLS 清单无效或没有媒体分片。');
    }
    return const _PlayableProbeResult(true, '');
  }
  if (format == 'DASH') {
    try {
      final document = XmlDocument.parse(trimmed);
      if (document.rootElement.name.local != 'MPD') {
        return const _PlayableProbeResult(false, '视频地址返回的 DASH 清单无效。');
      }
    } catch (_) {
      return const _PlayableProbeResult(false, '视频地址返回的 DASH 清单无效。');
    }
    return const _PlayableProbeResult(true, '');
  }

  final hasMp4Signature = _hasIsoBmffSignature(bytes);
  final hasEbmlSignature = _sampleStartsWith(bytes, const [
    0x1A,
    0x45,
    0xDF,
    0xA3,
  ]);
  final hasFlvSignature = _sampleStartsWith(bytes, const [0x46, 0x4C, 0x56]);
  final hasTransportStreamSignature = _hasMpegTransportStreamSignature(bytes);
  final binaryMediaSignature =
      hasMp4Signature ||
      hasEbmlSignature ||
      hasFlvSignature ||
      hasTransportStreamSignature;

  if (format == 'MP4') {
    return hasMp4Signature
        ? const _PlayableProbeResult(true, '')
        : const _PlayableProbeResult(false, '视频地址没有返回有效的 MP4 数据。');
  }
  if (format == 'WebM' || format == 'MKV') {
    return hasEbmlSignature
        ? const _PlayableProbeResult(true, '')
        : const _PlayableProbeResult(false, '视频地址没有返回有效的视频容器数据。');
  }
  if (format == 'FLV') {
    return hasFlvSignature
        ? const _PlayableProbeResult(true, '')
        : const _PlayableProbeResult(false, '视频地址没有返回有效的 FLV 数据。');
  }
  if (binaryMediaSignature) {
    return const _PlayableProbeResult(true, '');
  }

  final looksLikeStructuredError =
      contentType.contains('json') ||
      contentType.contains('xml') ||
      lowerText.startsWith('{') ||
      lowerText.startsWith('[') ||
      lowerText.startsWith('<?xml');
  if (contentType.contains('text/html') || looksLikeStructuredError) {
    return const _PlayableProbeResult(false, '视频地址返回的是网页或错误信息，不是媒体内容。');
  }
  return const _PlayableProbeResult(false, '视频地址没有返回可识别的媒体内容。');
}

bool _sampleStartsWith(List<int> bytes, List<int> signature) {
  if (bytes.length < signature.length) return false;
  for (var index = 0; index < signature.length; index++) {
    if (bytes[index] != signature[index]) return false;
  }
  return true;
}

bool _isOpaqueEncryptedHlsSegment(_PlayableProbeResponse sample) {
  final bytes = sample.sample;
  if (bytes.length < 16) return false;
  final contentType =
      sample.response.headers['content-type']?.toLowerCase() ?? '';
  if (contentType.contains('text/') ||
      contentType.contains('json') ||
      contentType.contains('xml')) {
    return false;
  }
  final prefix = utf8
      .decode(bytes.take(512).toList(growable: false), allowMalformed: true)
      .trimLeft()
      .toLowerCase();
  if (prefix.startsWith('<!doctype') ||
      prefix.startsWith('<html') ||
      prefix.startsWith('{') ||
      prefix.startsWith('[') ||
      prefix.contains('access denied') ||
      prefix.contains('not found')) {
    return false;
  }
  final sampled = bytes.take(512).toList(growable: false);
  final printable = sampled.where((value) {
    return value == 9 ||
        value == 10 ||
        value == 13 ||
        (value >= 32 && value <= 126);
  }).length;
  return printable / sampled.length < 0.85;
}

bool _hasIsoBmffSignature(List<int> bytes) {
  var offset = 0;
  final limit = bytes.length < 64 ? bytes.length : 64;
  while (offset + 8 <= limit) {
    final size =
        (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
    final type = String.fromCharCodes(bytes.skip(offset + 4).take(4));
    final plausibleSize =
        size == 0 || size == 1 || (size >= 8 && size <= 64 * 1024 * 1024);
    if (plausibleSize && const {'ftyp', 'styp', 'moof'}.contains(type)) {
      return true;
    }
    if (size < 8 || size > limit - offset) break;
    offset += size;
  }
  return false;
}

String _mp4StartupProfile(List<int> bytes) {
  var offset = 0;
  var sawMoov = false;
  var sawMdat = false;
  while (offset + 8 <= bytes.length) {
    var size = _readBigEndianUint32(bytes, offset);
    final type = String.fromCharCodes(bytes.skip(offset + 4).take(4));
    var headerSize = 8;
    if (size == 1) {
      if (offset + 16 > bytes.length) break;
      size = _readBigEndianUint64(bytes, offset + 8);
      headerSize = 16;
    }
    // styp/moof identifies fragmented ISO-BMFF. It does not prove that a
    // classic MP4 stores its moov box at the tail.
    if (type == 'styp' || type == 'moof') {
      return PlaybackStartupProfile.unknown;
    }
    if (type == 'moov') {
      if (sawMdat) return PlaybackStartupProfile.mp4TailMoov;
      sawMoov = true;
    }
    if (type == 'mdat') {
      if (sawMoov) return PlaybackStartupProfile.mp4FastStart;
      sawMdat = true;
    }
    if (size == 0 || size < headerSize) break;
    final nextOffset = offset + size;
    if (nextOffset <= offset || nextOffset > bytes.length) break;
    offset = nextOffset;
  }
  return PlaybackStartupProfile.unknown;
}

int _readBigEndianUint32(List<int> bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

int _readBigEndianUint64(List<int> bytes, int offset) =>
    (_readBigEndianUint32(bytes, offset) << 32) |
    _readBigEndianUint32(bytes, offset + 4);

bool _hasMpegTransportStreamSignature(List<int> bytes) {
  for (final stride in const <int>[188, 192, 204]) {
    final maxStart = stride < 32 ? stride : 32;
    for (var start = 0; start < maxStart; start++) {
      final second = start + stride;
      if (second >= bytes.length ||
          bytes[start] != 0x47 ||
          bytes[second] != 0x47) {
        continue;
      }
      final third = second + stride;
      if (third < bytes.length && bytes[third] != 0x47) continue;
      return true;
    }
  }
  return false;
}

String _formatForUrl(String url, String fallback) {
  final lower = url.toLowerCase();
  if (lower.contains('.m3u8') || lower.contains('type=m3u8')) return 'HLS';
  if (lower.contains('.mpd') || lower.contains('type=mpd')) return 'DASH';
  if (lower.contains('.mp4')) return 'MP4';
  if (lower.contains('.webm')) return 'WebM';
  if (lower.contains('.mkv')) return 'MKV';
  if (lower.contains('.flv')) return 'FLV';
  final normalizedFallback = fallback.trim().toUpperCase();
  return switch (normalizedFallback) {
    'HLS' || 'M3U8' => 'HLS',
    'DASH' || 'MPD' => 'DASH',
    'MP4' => 'MP4',
    'WEBM' => 'WebM',
    'MKV' => 'MKV',
    'FLV' => 'FLV',
    _ => '',
  };
}

String? _probeResolutionLabel(int? width, int? height) {
  if (height != null && height > 0) return '${height}P';
  if (width != null && width >= 3800) return '2160P';
  return null;
}

String? _resolutionLabelForUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  final dimensions = _resolutionDimensionsForUrl(uri);
  return _probeResolutionLabel(dimensions?.width, dimensions?.height);
}

String? _probeSizeLabel(_PlayableProbeResult probe) {
  if (probe.isLive) return '直播';
  final bytes = probe.sizeBytes;
  if (bytes == null || bytes <= 0) return null;
  final value = (bytes / 1024 / 1024).toStringAsFixed(1);
  return '${probe.sizeEstimated ? '约 ' : ''}$value MB';
}
