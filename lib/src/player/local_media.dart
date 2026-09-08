/// Converts a picker path to a player URL without treating Windows drive letters
/// as URI schemes. Already formed URLs (including web blob URLs) stay unchanged.
String localMediaPlaybackUrl(String path) {
  final isWindowsPath =
      RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(path) || path.startsWith(r'\\');
  if (isWindowsPath) return Uri.file(path, windows: true).toString();
  if (Uri.tryParse(path)?.hasScheme ?? false) return path;
  return Uri.file(path, windows: false).toString();
}

/// Keeps Windows network shares intact at the native player boundary.
/// The engine's URI parser drops a UNC authority from a file URL, but accepts
/// the native UNC path. Keep the file URL unchanged for the resolver and Web.
String nativeMediaPlaybackResource(String url, {required bool windows}) {
  if (!windows) return url;
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.isScheme('file') || uri.host.isEmpty) return url;
  return uri.toFilePath(windows: true);
}
