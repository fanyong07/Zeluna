import '../core/network/network_security.dart';

const appUpdateMaxApkBytes = 512 * 1024 * 1024;
const appUpdateMaxJsonBytes = 512 * 1024;
const appUpdateMaxNotesLength = 20000;
const appUpdatePackageName = 'app.anime.anime';

const appUpdateJsonPolicy = NetworkRequestPolicy(
  service: NetworkServiceKind.metadataApi,
  httpsOnly: true,
  allowPrivateNetwork: false,
  maxResponseBytes: appUpdateMaxJsonBytes,
  requestTimeout: Duration(seconds: 20),
  allowSyntheticDns: true,
  rejectRedirects: false,
);

class UpdateRelease {
  const UpdateRelease({
    required this.version,
    required this.buildNumber,
    required this.apkUri,
    required this.sha256,
    required this.bytes,
    required this.notes,
    this.releasePage,
    this.abis = const [],
    this.minSdk,
  });

  final String version;
  final int buildNumber;
  final Uri apkUri;
  final String sha256;
  final int bytes;
  final String notes;
  final Uri? releasePage;
  final List<String> abis;
  final int? minSdk;

  String get displayVersion => 'v$version';

  bool isNewerThan(String currentVersion, int currentBuild) {
    if (buildNumber <= currentBuild ||
        !isUpdateVersion(version) ||
        !isUpdateVersion(currentVersion)) {
      return false;
    }
    final next = version.split('.').map(BigInt.parse).toList();
    final current = currentVersion.split('.').map(BigInt.parse).toList();
    for (var i = 0; i < 3; i++) {
      final comparison = next[i].compareTo(current[i]);
      if (comparison != 0) return comparison > 0;
    }
    return true;
  }

  Map<String, Object?> toJson() => {
    'schema': 'zeluna-app-update-v1',
    'platform': 'android',
    'package_name': appUpdatePackageName,
    'version': version,
    'build_number': buildNumber,
    'apk': {
      'url': apkUri.toString(),
      'sha256': sha256,
      'bytes': bytes,
      if (abis.isNotEmpty) 'abis': abis,
      if (minSdk != null) 'min_sdk': minSdk,
    },
    'notes': notes,
    if (releasePage != null) 'release_page': releasePage.toString(),
  };

  factory UpdateRelease.fromJson(Map<String, dynamic> json) {
    if (json['schema'] != 'zeluna-app-update-v1' ||
        json['platform'] != 'android' ||
        json['package_name'] != appUpdatePackageName) {
      throw invalidUpdateManifest;
    }
    final version = json['version'];
    final build = json['build_number'];
    final apk = json['apk'];
    final notes = json['notes'];
    if (version is! String ||
        !isUpdateVersion(version) ||
        build is! int ||
        build <= 0 ||
        build > 0x7fffffff ||
        apk is! Map<String, dynamic> ||
        notes is! String ||
        notes.length > appUpdateMaxNotesLength) {
      throw invalidUpdateManifest;
    }
    final hash = apk['sha256'];
    final bytes = apk['bytes'];
    final abis = apk['abis'];
    final minSdk = apk['min_sdk'];
    if (hash is! String ||
        !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(hash) ||
        bytes is! int ||
        bytes <= 0 ||
        bytes > appUpdateMaxApkBytes ||
        (apk.containsKey('abis') &&
            (abis is! List ||
                abis.length > 16 ||
                abis.any(
                  (abi) =>
                      abi is! String ||
                      !RegExp(r'^[a-zA-Z0-9_-]{1,64}$').hasMatch(abi),
                ))) ||
        (apk.containsKey('min_sdk') &&
            (minSdk is! int || minSdk <= 0 || minSdk > 0x7fffffff))) {
      throw invalidUpdateManifest;
    }
    return UpdateRelease(
      version: version,
      buildNumber: build,
      apkUri: parseUpdateUri(apk['url']),
      sha256: hash.toLowerCase(),
      bytes: bytes,
      notes: notes,
      releasePage: json.containsKey('release_page')
          ? parseUpdateUri(json['release_page'])
          : null,
      abis: abis == null ? const [] : List<String>.unmodifiable(abis),
      minSdk: minSdk as int?,
    );
  }
}

bool isUpdateVersion(String value) =>
    value.length <= 128 &&
    RegExp(
      r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$',
    ).hasMatch(value);

Uri parseUpdateUri(Object? value) {
  if (value is! String || value.isEmpty || value.length > 8192) {
    throw invalidUpdateManifest;
  }
  try {
    final uri = Uri.parse(value);
    appUpdateJsonPolicy.ensureUriAllowed(uri);
    if (uri.hasFragment) throw invalidUpdateManifest;
    return uri;
  } on FormatException {
    throw invalidUpdateManifest;
  } on NetworkSecurityException {
    throw invalidUpdateManifest;
  }
}

const invalidUpdateManifest = UpdateFailure(
  'invalid_manifest',
  '更新信息格式错误，请稍后重试',
);

class UpdateCancelled implements Exception {
  const UpdateCancelled();

  @override
  String toString() => '更新已取消';
}

class UpdateCancellation {
  bool _cancelled = false;
  final Map<Object, void Function()> _listeners = {};

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final listeners = _listeners.values.toList();
    _listeners.clear();
    for (final listener in listeners) {
      _notify(listener);
    }
  }

  void throwIfCancelled() {
    if (_cancelled) throw const UpdateCancelled();
  }

  /// Returns an idempotent unlink callback. Late registrations fire immediately.
  void Function() register(void Function() listener) {
    if (_cancelled) {
      _notify(listener);
      return () {};
    }
    final key = Object();
    _listeners[key] = listener;
    return () => _listeners.remove(key);
  }

  static void _notify(void Function() listener) {
    try {
      listener();
    } catch (_) {
      // One transport's close failure must not prevent other cancellation hooks.
    }
  }
}

class UpdateProgress {
  const UpdateProgress({required this.received, required this.total});

  final int received;
  final int total;
}

class UpdateFailure implements Exception {
  const UpdateFailure(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

class InstalledUpdateEnvironment {
  const InstalledUpdateEnvironment({
    required this.packageName,
    required this.versionName,
    required this.versionCode,
    required this.sdkInt,
    required this.supportedAbis,
    required this.canRequestInstallPackages,
  });

  final String packageName;
  final String versionName;
  final int versionCode;
  final int sdkInt;
  final List<String> supportedAbis;
  final bool canRequestInstallPackages;

  factory InstalledUpdateEnvironment.fromMap(Map<Object?, Object?> map) {
    final package = map['packageName'];
    final version = map['versionName'];
    final code = map['versionCode'];
    final sdk = map['sdkInt'];
    final abis = map['supportedAbis'];
    final canInstall = map['canRequestInstallPackages'];
    if (package is! String ||
        package.isEmpty ||
        version is! String ||
        !isUpdateVersion(version) ||
        code is! int ||
        code <= 0 ||
        code > 0x7fffffff ||
        sdk is! int ||
        sdk <= 0 ||
        abis is! List ||
        abis.any((abi) => abi is! String || abi.isEmpty) ||
        canInstall is! bool) {
      throw const UpdateFailure('invalid_environment', '读取当前应用信息失败');
    }
    return InstalledUpdateEnvironment(
      packageName: package,
      versionName: version,
      versionCode: code,
      sdkInt: sdk,
      supportedAbis: List<String>.unmodifiable(abis),
      canRequestInstallPackages: canInstall,
    );
  }
}
