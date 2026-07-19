class MediaDownloadResult {
  const MediaDownloadResult({
    required this.success,
    required this.message,
    this.path,
    this.bytes = 0,
  });

  final bool success;
  final String message;
  final String? path;
  final int bytes;
}
