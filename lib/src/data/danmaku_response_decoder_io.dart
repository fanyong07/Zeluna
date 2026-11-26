import 'dart:io';

List<int> decodeDanmakuResponse(List<int> bytes, String? contentEncoding) {
  final encoding = contentEncoding?.toLowerCase() ?? '';
  final looksLikeText = bytes.isNotEmpty && bytes.first == 0x3c;
  try {
    if (encoding.contains('deflate')) {
      try {
        return zlib.decode(bytes);
      } catch (_) {
        return ZLibCodec(raw: true).decode(bytes);
      }
    }
    if (encoding.contains('gzip')) return gzip.decode(bytes);
  } catch (_) {
    // The platform client may already have decompressed the response.
  }
  if (!looksLikeText) {
    try {
      return zlib.decode(bytes);
    } catch (_) {
      try {
        return ZLibCodec(raw: true).decode(bytes);
      } catch (_) {
        try {
          return gzip.decode(bytes);
        } catch (_) {
          // Keep the original bytes so the caller can degrade safely.
        }
      }
    }
  }
  return bytes;
}
