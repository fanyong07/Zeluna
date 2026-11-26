import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// A generated uncompressed AVI using only Dart byte operations. AVI is a
// supported local-file format; no download, binary fixture or encoder is needed.
Future<File> writeGeneratedPlayerTestVideo(Directory directory) async {
  const width = 64;
  const height = 36;
  const frameCount = 1800;
  const frameSize = width * height * 3;
  Uint8List words(List<int> values) {
    final data = ByteData(values.length * 4);
    for (var i = 0; i < values.length; i++) {
      data.setUint32(i * 4, values[i], Endian.little);
    }
    return data.buffer.asUint8List();
  }

  Uint8List chunk(String type, List<int> body) =>
      (BytesBuilder(copy: false)
            ..add(ascii.encode(type))
            ..add(words([body.length]))
            ..add(body)
            ..add(body.length.isOdd ? [0] : const []))
          .takeBytes();
  Uint8List list(String type, List<int> body) => chunk(
    'LIST',
    (BytesBuilder(copy: false)
          ..add(ascii.encode(type))
          ..add(body))
        .takeBytes(),
  );
  final streamHeader = ByteData(56);
  streamHeader.buffer.asUint8List().setRange(0, 8, ascii.encode('vidsDIB '));
  streamHeader.setUint32(20, 1, Endian.little);
  streamHeader.setUint32(24, 10, Endian.little);
  streamHeader.setUint32(32, frameCount, Endian.little);
  streamHeader.setUint32(36, frameSize, Endian.little);
  streamHeader.setUint32(40, 0xffffffff, Endian.little);
  streamHeader.setInt16(52, width, Endian.little);
  streamHeader.setInt16(54, height, Endian.little);
  final bitmap = ByteData(40)
    ..setUint32(0, 40, Endian.little)
    ..setInt32(4, width, Endian.little)
    ..setInt32(8, height, Endian.little)
    ..setUint16(12, 1, Endian.little)
    ..setUint16(14, 24, Endian.little)
    ..setUint32(20, frameSize, Endian.little);
  final headers = list(
    'hdrl',
    (BytesBuilder(copy: false)
          ..add(
            chunk(
              'avih',
              words([
                100000,
                frameSize * 10,
                0,
                0x10,
                frameCount,
                0,
                1,
                frameSize,
                width,
                height,
                0,
                0,
                0,
                0,
              ]),
            ),
          )
          ..add(
            list(
              'strl',
              (BytesBuilder(copy: false)
                    ..add(chunk('strh', streamHeader.buffer.asUint8List()))
                    ..add(chunk('strf', bitmap.buffer.asUint8List())))
                  .takeBytes(),
            ),
          ))
        .takeBytes(),
  );
  final frames = BytesBuilder(copy: false);
  final index = BytesBuilder(copy: false);
  var offset = 4;
  for (var frame = 0; frame < frameCount; frame++) {
    final pixels = Uint8List(frameSize)
      ..fillRange(0, frameSize, 40 + frame % 180);
    final encoded = chunk('00db', pixels);
    frames.add(encoded);
    index
      ..add(ascii.encode('00db'))
      ..add(words([0x10, offset, frameSize]));
    offset += encoded.length;
  }
  final body =
      (BytesBuilder(copy: false)
            ..add(ascii.encode('AVI '))
            ..add(headers)
            ..add(list('movi', frames.takeBytes()))
            ..add(chunk('idx1', index.takeBytes())))
          .takeBytes();
  return File(
    '${directory.path}/generated.avi',
  ).writeAsBytes(chunk('RIFF', body));
}
