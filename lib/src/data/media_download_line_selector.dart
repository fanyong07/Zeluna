import '../domain/anime_models.dart';

List<PlaybackLine> singleFileDownloadCandidates(Iterable<PlaybackLine> lines) {
  final candidates = lines
      .where(
        (line) =>
            line.available &&
            line.url?.trim().isNotEmpty == true &&
            !_isSegmentedLine(line) &&
            !_isUnsupportedProtocol(line.url!),
      )
      .toList();
  candidates.sort((left, right) {
    final score = _singleFileScore(left).compareTo(_singleFileScore(right));
    if (score != 0) return score;
    final latency = (left.latency ?? const Duration(days: 1)).compareTo(
      right.latency ?? const Duration(days: 1),
    );
    if (latency != 0) return latency;
    return left.providerName.compareTo(right.providerName);
  });
  return candidates;
}

List<PlaybackLine> hlsDownloadCandidates(Iterable<PlaybackLine> lines) {
  return lines
      .where(
        (line) =>
            line.available &&
            line.url?.trim().isNotEmpty == true &&
            _isHlsLine(line) &&
            !_isUnsupportedProtocol(line.url!),
      )
      .toList(growable: false);
}

bool isSegmentedDownloadLine(PlaybackLine line) => _isSegmentedLine(line);
bool isHlsDownloadLine(PlaybackLine line) => _isHlsLine(line);

int _singleFileScore(PlaybackLine line) {
  final url = line.url!.toLowerCase();
  final format = line.format.toLowerCase();
  if (_hasSingleFileExtension(url)) return 0;
  if (_isKnownSingleFileFormat(format)) return 1;
  return 2;
}

bool _isSegmentedLine(PlaybackLine line) {
  final url = line.url?.toLowerCase() ?? '';
  final format = line.format.toLowerCase();
  if (_hasSingleFileExtension(url)) return false;
  if (_looksLikeManifestUrl(url)) return true;
  if (_isKnownSingleFileFormat(format)) return false;
  return format == 'hls' ||
      format == 'dash' ||
      format.contains('m3u8') ||
      format.contains('mpeg-dash') ||
      format.contains('application/dash+xml');
}

bool _isHlsLine(PlaybackLine line) {
  final url = line.url?.toLowerCase() ?? '';
  final format = line.format.toLowerCase();
  if (_hasSingleFileExtension(url)) return false;
  return RegExp(r'\.m3u8(?:$|[?#])').hasMatch(url) ||
      url.contains('type=m3u8') ||
      url.contains('format=m3u8') ||
      format == 'hls' ||
      format.contains('m3u8') ||
      format.contains('mpegurl');
}

bool _hasSingleFileExtension(String value) => RegExp(
  r'\.(?:mp4|webm|mkv|mov|m4v|flv)(?:$|[?#])',
  caseSensitive: false,
).hasMatch(value);

bool _looksLikeManifestUrl(String value) =>
    RegExp(r'\.(?:m3u8|mpd)(?:$|[?#])', caseSensitive: false).hasMatch(value) ||
    value.contains('type=m3u8') ||
    value.contains('format=m3u8') ||
    value.contains('type=mpd') ||
    value.contains('format=mpd');

bool _isKnownSingleFileFormat(String value) =>
    value.contains('mp4') ||
    value.contains('webm') ||
    value.contains('matroska') ||
    value == 'mkv' ||
    value == 'mov' ||
    value == 'm4v' ||
    value == 'flv';

bool _isUnsupportedProtocol(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null) return true;
  return uri.scheme != 'http' && uri.scheme != 'https';
}
