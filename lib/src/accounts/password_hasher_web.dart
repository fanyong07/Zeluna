@JS()
library;

import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

Future<String> derivePasswordHash({
  required String password,
  required String salt,
  required int iterations,
}) async {
  final subtle = web.window.crypto.subtle;
  final passwordBytes = Uint8List.fromList(utf8.encode(password));
  final saltBytes = Uint8List.fromList(
    base64Url.decode(base64Url.normalize(salt)),
  );
  final key = await subtle
      .importKey(
        'raw',
        passwordBytes.toJS,
        'PBKDF2'.toJS,
        false,
        <JSString>['deriveBits'.toJS].toJS,
      )
      .toDart;
  final bits = await subtle
      .deriveBits(
        _Pbkdf2Params(
          name: 'PBKDF2',
          salt: saltBytes.toJS,
          iterations: iterations,
          hash: 'SHA-256',
        ),
        key,
        256,
      )
      .toDart;
  return base64UrlEncode(bits.toDart.asUint8List()).replaceAll('=', '');
}

extension type _Pbkdf2Params._(JSObject _) implements JSObject {
  external factory _Pbkdf2Params({
    String name,
    JSUint8Array salt,
    int iterations,
    String hash,
  });
}
