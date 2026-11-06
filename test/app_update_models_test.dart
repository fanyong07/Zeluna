import 'package:anime/src/updates/app_update_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('custom feed round trip and numerical semver/build ordering', () {
    final release = UpdateRelease.fromJson(feed());
    expect(release.displayVersion, 'v1.10.0');
    expect(release.isNewerThan('1.9.9', 86), isTrue);
    expect(release.isNewerThan('1.10.0', 86), isTrue);
    expect(release.isNewerThan('1.10.1', 86), isFalse);
    expect(release.isNewerThan('2.0.0', 1), isFalse);
    expect(release.isNewerThan('1.0.0', 87), isFalse);
    expect(release.isNewerThan('v1.0.0', 1), isFalse);
    expect(UpdateRelease.fromJson(release.toJson()).toJson(), release.toJson());
    expect(() => release.abis.add('x86'), throwsUnsupportedError);
  });

  test('strict scalar types and bounded metadata reject malformed feeds', () {
    final mutations = <void Function(Map<String, dynamic>)>[
      (j) => j['schema'] = 'other',
      (j) => j['platform'] = 'ios',
      (j) => j['package_name'] = 'other.app',
      (j) => j['version'] = '1.2',
      (j) => j['version'] = '01.2.3',
      (j) => j['version'] = '1.2.3+87',
      (j) => j['version'] = '1.2.3-rc1',
      (j) => j['build_number'] = '87',
      (j) => j['build_number'] = 87.0,
      (j) => j['build_number'] = 0,
      (j) => j['build_number'] = 0x80000000,
      (j) => j['notes'] = null,
      (j) => j['notes'] = 'x' * 20001,
      (j) => j['release_page'] = null,
      (j) => j['apk']['sha256'] = 'bad',
      (j) => j['apk']['bytes'] = '100',
      (j) => j['apk']['bytes'] = 0,
      (j) => j['apk']['bytes'] = appUpdateMaxApkBytes + 1,
      (j) => j['apk']['min_sdk'] = '21',
      (j) => j['apk']['min_sdk'] = null,
      (j) => j['apk']['abis'] = null,
      (j) => j['apk']['abis'] = [3],
    ];
    for (final mutate in mutations) {
      final json = feed();
      mutate(json);
      expect(() => UpdateRelease.fromJson(json), throwsA(isA<UpdateFailure>()));
    }
  });

  test('HTTPS public URLs only; error text does not expose raw URL', () {
    for (final url in [
      'http://github.com/file.apk',
      'https://user:secret@github.com/file.apk',
      'https://127.0.0.1/file.apk',
      'https://192.168.0.1/file.apk',
      'https://localhost/file.apk',
      'https://198.18.0.1/file.apk',
      'https://github.com/file.apk#fragment',
      'not a url',
    ]) {
      final json = feed();
      json['apk']['url'] = url;
      expect(
        () => UpdateRelease.fromJson(json),
        throwsA(
          isA<UpdateFailure>().having(
            (e) => e.message,
            'fixed message',
            isNot(contains(url)),
          ),
        ),
      );
    }
  });

  test('cancellation is idempotent; unlinked and late hooks behave', () {
    final token = UpdateCancellation();
    var calls = 0;
    final unlink = token.register(() => calls += 10);
    unlink();
    unlink();
    token.register(() => calls++);
    token.register(() => throw StateError('close failed'));
    token.register(() => calls++);
    token.cancel();
    token.cancel();
    expect(calls, 2);
    token.register(() => calls++);
    expect(calls, 3);
    expect(token.throwIfCancelled, throwsA(isA<UpdateCancelled>()));
  });

  test('installed environment bridge uses strict camelCase fields', () {
    final map = <Object?, Object?>{
      'packageName': appUpdatePackageName,
      'versionName': '1.3.1',
      'versionCode': 87,
      'sdkInt': 35,
      'supportedAbis': ['arm64-v8a'],
      'canRequestInstallPackages': false,
    };
    expect(InstalledUpdateEnvironment.fromMap(map).versionCode, 87);
    map['versionCode'] = '87';
    expect(
      () => InstalledUpdateEnvironment.fromMap(map),
      throwsA(isA<UpdateFailure>()),
    );
  });
}

Map<String, dynamic> feed() => {
  'schema': 'zeluna-app-update-v1',
  'platform': 'android',
  'package_name': 'app.anime.anime',
  'version': '1.10.0',
  'build_number': 87,
  'apk': <String, dynamic>{
    'url': 'https://github.com/fanyong07/Zeluna/app.apk',
    'sha256': 'a' * 64,
    'bytes': 100,
    'abis': ['arm64-v8a'],
    'min_sdk': 21,
  },
  'notes': '更新说明',
};
