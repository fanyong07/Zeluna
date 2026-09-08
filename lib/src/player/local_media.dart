/// Converts a picker path to a player URL without treating Windows drive letters
/// as URI schemes. Already formed URLs (including web blob URLs) stay unchanged.
String localMediaPlaybackUrl(String path) {
  final isWindowsPath =
      RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(path) || path.startsWith(r'\\');
  if (isWindowsPath) return Uri.file(path, windows: true).toString();
  if (Uri.tryParse(path)?.hasScheme ?? false) return path;
  return Uri.file(path, windows: false).toString();
}
