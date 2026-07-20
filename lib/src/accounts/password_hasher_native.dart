import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

Future<String> derivePasswordHash({
  required String password,
  required String salt,
  required int iterations,
}) {
  return compute(_pbkdf2Sha256, <String, Object>{
    'password': password,
    'salt': salt,
    'iterations': iterations,
  });
}

String _pbkdf2Sha256(Map<String, Object> input) {
  final password = input['password']! as String;
  final salt = base64Url.decode(base64Url.normalize(input['salt']! as String));
  final iterations = input['iterations']! as int;
  final hmac = Hmac(sha256, utf8.encode(password));
  var block = hmac.convert([...salt, 0, 0, 0, 1]).bytes;
  final derived = List<int>.from(block);
  for (var round = 1; round < iterations; round++) {
    block = hmac.convert(block).bytes;
    for (var index = 0; index < derived.length; index++) {
      derived[index] ^= block[index];
    }
  }
  return base64UrlEncode(derived).replaceAll('=', '');
}
