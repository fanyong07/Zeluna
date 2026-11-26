// Local media_kit 1.2.6 screenshot patch. See PATCHES.md.
// Upstream media_kit is distributed under the MIT license in LICENSE.
import 'dart:ffi';

import 'package:media_kit/ffi/ffi.dart';
import 'package:media_kit/generated/libmpv/bindings.dart' as generated;

/// Executes screenshot-raw with owned, NULL-terminated argv and result storage.
///
/// [readResult] must finish reading/copying the node before returning: native
/// result memory is freed in finally, including when the reader throws.
/// Injectable callbacks and allocator allow regression tests without libmpv.
T? withScreenshotResult<T>({
  required bool includeLibassSubtitles,
  required int Function(
    Pointer<Pointer<Int8>> args,
    Pointer<generated.mpv_node> result,
  ) command,
  required void Function(Pointer<generated.mpv_node>) freeNodeContents,
  required T Function(Pointer<generated.mpv_node>) readResult,
  Allocator allocator = calloc,
}) {
  final args = [
    'screenshot-raw',
    includeLibassSubtitles ? 'subtitles' : 'video',
  ];
  // calloc<Pointer<Utf8>>(args.length + 1) in production, not string bytes.
  final arr = allocator<Pointer<Utf8>>(args.length + 1);
  final pointers = <Pointer<Utf8>>[];
  Pointer<generated.mpv_node> result = nullptr;
  var succeeded = false;
  try {
    arr[args.length] = nullptr;
    for (var i = 0; i < args.length; i++) {
      final pointer = args[i].toNativeUtf8(allocator: allocator);
      pointers.add(pointer);
      arr[i] = pointer;
    }
    result = allocator<generated.mpv_node>();
    result.ref.format = generated.mpv_format.MPV_FORMAT_NONE;
    if (command(arr.cast(), result) < 0) {
      // libmpv leaves result unset on error; it must not be read or freed as a
      // successful node. The caller maps null to its usual no-frame result.
      return null;
    }
    succeeded = true;
    return readResult(result);
  } finally {
    try {
      if (succeeded) {
        freeNodeContents(result);
      }
    } finally {
      for (final pointer in pointers) {
        allocator.free(pointer);
      }
      if (result != nullptr) {
        allocator.free(result);
      }
      allocator.free(arr);
    }
  }
}

/// Checks an actual screenshot-raw result, not playback clocks or metadata.
///
/// Reads only the result's shape and byte-array extent. No pixel allocation,
/// copy or encoding is needed, and no native pointer escapes this callback.
bool hasDecodedScreenshotFrame(Pointer<generated.mpv_node> result) {
  if (result.ref.format != generated.mpv_format.MPV_FORMAT_NODE_MAP) {
    return false;
  }
  final map = result.ref.u.list;
  if (map == nullptr ||
      map.ref.num <= 0 ||
      map.ref.keys == nullptr ||
      map.ref.values == nullptr) {
    return false;
  }
  int? width, height, stride;
  var byteCount = 0;
  var hasData = false;
  for (var i = 0; i < map.ref.num; i++) {
    if (map.ref.keys[i] == nullptr) continue;
    final key = map.ref.keys[i].cast<Utf8>().toDartString();
    final value = map.ref.values[i];
    if (value.format == generated.mpv_format.MPV_FORMAT_INT64) {
      switch (key) {
        case 'w':
          width = value.u.int64;
          break;
        case 'h':
          height = value.u.int64;
          break;
        case 'stride':
          stride = value.u.int64;
          break;
      }
    } else if (key == 'data' &&
        value.format == generated.mpv_format.MPV_FORMAT_BYTE_ARRAY &&
        value.u.ba != nullptr) {
      byteCount = value.u.ba.ref.size;
      hasData = value.u.ba.ref.data != nullptr;
    }
  }
  return width != null &&
      height != null &&
      stride != null &&
      width > 0 &&
      height > 0 &&
      stride >= width * 4 &&
      hasData &&
      // The final row need not include trailing alignment padding.
      byteCount >= (height - 1) * stride + width * 4;
}
