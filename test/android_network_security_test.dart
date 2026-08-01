import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android release denies global cleartext while debug is scoped', () {
    final main = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final release = File(
      'android/app/src/release/AndroidManifest.xml',
    ).readAsStringSync();
    final debug = File(
      'android/app/src/debug/AndroidManifest.xml',
    ).readAsStringSync();
    final releasePolicy = File(
      'android/app/src/main/res/xml/network_security_config.xml',
    ).readAsStringSync();
    final debugPolicy = File(
      'android/app/src/debug/res/xml/network_security_config_debug.xml',
    ).readAsStringSync();

    expect(main, contains('android:usesCleartextTraffic="false"'));
    expect(main, contains('@xml/network_security_config'));
    expect(release, contains('android:usesCleartextTraffic="false"'));
    expect(release, isNot(contains('usesCleartextTraffic="true"')));
    expect(releasePolicy, contains('cleartextTrafficPermitted="false"'));
    expect(releasePolicy, isNot(contains('src="user"')));

    expect(debug, contains('android:usesCleartextTraffic="true"'));
    expect(debug, contains('@xml/network_security_config_debug'));
    expect(debugPolicy, contains('cleartextTrafficPermitted="false"'));
    expect(debugPolicy, contains('cleartextTrafficPermitted="true"'));
    expect(debugPolicy, contains('>localhost<'));
    expect(debugPolicy, contains('>10.0.2.2<'));
  });
}
