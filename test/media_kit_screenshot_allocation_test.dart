import 'dart:ffi';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/ffi/ffi.dart';
import 'package:media_kit/generated/libmpv/bindings.dart' as generated;
import 'package:media_kit/src/player/native/utils/screenshot.dart';

void main() {
  group('vendored screenshot-raw allocation', () {
    for (final subtitles in [false, true]) {
      test(
        'uses pointer slots and explicit terminator (subtitles=$subtitles)',
        () {
          final allocator = _TrackingAllocator();
          var nodeFrees = 0;
          final value = withScreenshotResult<int>(
            includeLibassSubtitles: subtitles,
            allocator: allocator,
            command: (args, result) {
              expect(allocator.requests.first, 3 * sizeOf<Pointer<Utf8>>());
              expect(args[0].cast<Utf8>().toDartString(), 'screenshot-raw');
              expect(
                args[1].cast<Utf8>().toDartString(),
                subtitles ? 'subtitles' : 'video',
              );
              // Allocator poisons memory, so this proves explicit termination.
              expect(args[2], nullptr);
              expect(result.ref.format, generated.mpv_format.MPV_FORMAT_NONE);
              return 0;
            },
            freeNodeContents: (_) => nodeFrees++,
            readResult: (_) => 42,
          );
          expect(value, 42);
          expect(nodeFrees, 1);
          expect(allocator.requests.length, 4);
          expect(allocator.outstanding, isEmpty);
          expect(allocator.guardsIntact, isTrue);
        },
      );
    }

    for (final pointerBytes in [4, 8]) {
      test('argv slot contract models ${pointerBytes * 8}-bit ABI', () {
        final allocator = _TrackingAllocator();
        withScreenshotResult<void>(
          includeLibassSubtitles: false,
          allocator: allocator,
          command: (_, _) => -1,
          freeNodeContents: (_) => fail('failed command has no node contents'),
          readResult: (_) => fail('failed command has no result'),
        );
        // Execute the production helper on the host ABI, then model its typed
        // element count on both ABIs. This is not a 32-bit native execution.
        final slotCount = allocator.requests.first ~/ sizeOf<Pointer<Utf8>>();
        expect(slotCount, 3);
        expect(slotCount * pointerBytes, pointerBytes == 4 ? 12 : 24);
        final oldByteCount = ['screenshot-raw', 'video'].join().length;
        expect(oldByteCount, 19);
        expect(oldByteCount < slotCount * pointerBytes, pointerBytes == 8);
        expect(allocator.outstanding, isEmpty);
      });
    }

    test('command failure skips result and frees every Dart allocation', () {
      final allocator = _TrackingAllocator();
      final value = withScreenshotResult<bool>(
        includeLibassSubtitles: false,
        allocator: allocator,
        command: (_, _) => -12,
        freeNodeContents: (_) => fail('mpv result is unset on failure'),
        readResult: (_) => fail('must not read an unset result'),
      );
      expect(value, isNull);
      expect(allocator.outstanding, isEmpty);
      expect(allocator.guardsIntact, isTrue);
    });

    for (final stage in ['command', 'reader', 'node free']) {
      test('$stage exception still frees owned allocations', () {
        final allocator = _TrackingAllocator();
        var nodeFrees = 0;
        expect(
          () => withScreenshotResult<bool>(
            includeLibassSubtitles: false,
            allocator: allocator,
            command: (_, _) {
              if (stage == 'command') throw StateError(stage);
              return 0;
            },
            freeNodeContents: (_) {
              nodeFrees++;
              if (stage == 'node free') throw StateError(stage);
            },
            readResult: (_) {
              if (stage == 'reader') throw StateError(stage);
              return true;
            },
          ),
          throwsStateError,
        );
        expect(nodeFrees, stage == 'command' ? 0 : 1);
        expect(allocator.outstanding, isEmpty);
        expect(allocator.guardsIntact, isTrue);
      });
    }

    for (final failAt in [1, 2, 3, 4]) {
      test('allocation $failAt failure releases partial argv/result', () {
        final allocator = _TrackingAllocator(failAt: failAt);
        expect(
          () => withScreenshotResult<bool>(
            includeLibassSubtitles: false,
            allocator: allocator,
            command: (_, _) => fail('allocation should fail first'),
            freeNodeContents: (_) => fail('command never succeeded'),
            readResult: (_) => fail('command never succeeded'),
          ),
          throwsStateError,
        );
        expect(allocator.outstanding, isEmpty);
        expect(allocator.guardsIntact, isTrue);
      });
    }
  });

  group('decoded-frame result reader', () {
    test('accepts actual raw frame map and returns bool only', () {
      final fixture = _FrameResult();
      addTearDown(fixture.dispose);
      final allocator = _TrackingAllocator();
      var nodeFrees = 0;
      final value = withScreenshotResult<bool>(
        includeLibassSubtitles: false,
        allocator: allocator,
        command: (_, result) {
          fixture.attach(result);
          return 0;
        },
        freeNodeContents: (_) => nodeFrees++,
        readResult: hasDecodedScreenshotFrame,
      );
      expect(value, isTrue);
      expect(nodeFrees, 1);
      expect(allocator.outstanding, isEmpty);
    });

    for (final invalid in [
      'not a map',
      'null map',
      'missing data',
      'null bytes',
      'short bytes',
      'zero width',
      'negative height',
      'short stride',
    ]) {
      test('rejects $invalid', () {
        final fixture = _FrameResult();
        addTearDown(fixture.dispose);
        final result = calloc<generated.mpv_node>();
        addTearDown(() => calloc.free(result));
        fixture.attach(result);
        switch (invalid) {
          case 'not a map':
            result.ref.format = generated.mpv_format.MPV_FORMAT_NONE;
          case 'null map':
            result.ref.u.list = nullptr;
          case 'missing data':
            fixture.values[0].format = generated.mpv_format.MPV_FORMAT_NONE;
          case 'null bytes':
            fixture.bytes.ref.data = nullptr;
          case 'short bytes':
            fixture.bytes.ref.size = 19;
          case 'zero width':
            fixture.values[2].u.int64 = 0;
          case 'negative height':
            fixture.values[3].u.int64 = -1;
          case 'short stride':
            fixture.values[1].u.int64 = 7;
        }
        expect(hasDecodedScreenshotFrame(result), isFalse);
      });
    }
  });
}

/// Poison allocations and verify a guard beyond each requested byte count.
/// No undersized argv is ever passed to native mpv as part of this regression.
class _TrackingAllocator implements Allocator {
  _TrackingAllocator({this.failAt});

  final int? failAt;
  final requests = <int>[];
  final outstanding = <int, int>{};
  bool guardsIntact = true;

  @override
  Pointer<T> allocate<T extends NativeType>(int byteCount, {int? alignment}) {
    requests.add(byteCount);
    if (requests.length == failAt) throw StateError('allocation failure');
    final pointer = malloc.allocate<Uint8>(
      byteCount + 16,
      alignment: alignment,
    );
    pointer.asTypedList(byteCount + 16).fillRange(0, byteCount + 16, 0xa5);
    outstanding[pointer.address] = byteCount;
    return pointer.cast<T>();
  }

  @override
  void free(Pointer pointer) {
    final byteCount = outstanding.remove(pointer.address);
    if (byteCount == null) throw StateError('double free or foreign pointer');
    final bytes = pointer.cast<Uint8>().asTypedList(byteCount + 16);
    guardsIntact &= bytes.skip(byteCount).every((byte) => byte == 0xa5);
    malloc.free(pointer);
  }
}

class _FrameResult {
  final map = calloc<generated.mpv_node_list>();
  final values = calloc<generated.mpv_node>(4);
  final keys = calloc<Pointer<Int8>>(4);
  final bytes = calloc<generated.mpv_byte_array>();
  final pixels = calloc<Uint8>(20);
  final keyStrings = [
    'data',
    'stride',
    'w',
    'h',
  ].map((key) => key.toNativeUtf8()).toList();

  _FrameResult() {
    map.ref.num = 4;
    map.ref.values = values;
    map.ref.keys = keys;
    for (var i = 0; i < keyStrings.length; i++) {
      keys[i] = keyStrings[i].cast();
    }
    values[0].format = generated.mpv_format.MPV_FORMAT_BYTE_ARRAY;
    values[0].u.ba = bytes;
    bytes.ref.data = pixels.cast();
    bytes.ref.size = 20; // 2x2 BGRA, stride 12, final row without padding.
    for (var i = 1; i < 4; i++) {
      values[i].format = generated.mpv_format.MPV_FORMAT_INT64;
    }
    values[1].u.int64 = 12;
    values[2].u.int64 = 2;
    values[3].u.int64 = 2;
  }

  void attach(Pointer<generated.mpv_node> result) {
    result.ref.format = generated.mpv_format.MPV_FORMAT_NODE_MAP;
    result.ref.u.list = map;
  }

  void dispose() {
    for (final key in keyStrings) {
      malloc.free(key);
    }
    for (final pointer in <Pointer>[pixels, bytes, keys, values, map]) {
      calloc.free(pointer);
    }
  }
}
