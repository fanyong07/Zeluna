/// Unlike a Range sample, only a measured *whole file* can rule out a feature.
const catalogShortClipMessage = '疑似站点贴片广告或无效短片，已自动跳过';

bool catalogShortClip(
  Uri uri, {
  String format = '',
  int? bytes,
  bool estimated = false,
  num? seconds,
  bool live = false,
  bool catalog = false,
}) {
  final path = uri.path.toLowerCase();
  final type = format.toLowerCase();
  if (live ||
      {'hls', 'm3u8', 'dash', 'mpd'}.contains(type) ||
      path.endsWith('.m3u8') ||
      path.endsWith('.mpd')) {
    return false;
  }
  if (uri.host == 'highlight-video.cdn.bcebos.com' &&
      path.startsWith('/video/6s/')) {
    return true;
  }
  final single =
      {'mp4', 'webm', 'mkv', 'flv', 'm4v'}.contains(type) ||
      RegExp(r'\.(mp4|webm|mkv|flv|m4v)$').hasMatch(path);
  if (!single) return false;
  if (path.contains('/video/6s/')) return true;
  final adPath =
      uri.host.startsWith('ad.') ||
      uri.pathSegments.any(
        (s) => {
          'ad',
          'ads',
          'advert',
          'advertisement',
          'preroll',
        }.contains(s.toLowerCase()),
      );
  if (estimated || bytes == null || bytes <= 0 || bytes >= 5 * 1024 * 1024) {
    return false;
  }
  final validDuration = seconds != null && seconds.isFinite && seconds >= 0
      ? seconds
      : null;
  if (validDuration != null) {
    return validDuration < 60;
  }
  return catalog || adPath;
}
