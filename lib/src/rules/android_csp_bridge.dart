import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

@immutable
class AndroidCspSite {
  const AndroidCspSite({
    required this.spiderMd5,
    required this.siteKey,
    required this.api,
    this.ext = '',
  });

  final String spiderMd5;
  final String siteKey;
  final String api;

  /// Serialized TVBox `ext`. Map-shaped values must be JSON encoded by the caller.
  final String ext;

  Map<String, Object?> toChannelArguments() => {
    'spiderMd5': spiderMd5,
    'siteKey': siteKey,
    'api': api,
    'ext': ext,
  };
}

@immutable
class AndroidCspPackageCapabilities {
  const AndroidCspPackageCapabilities({
    required this.packageId,
    required this.artifactUrl,
    required this.md5,
    required this.sha256,
    required this.allowedApis,
  });

  factory AndroidCspPackageCapabilities.fromMap(Map<Object?, Object?> map) =>
      AndroidCspPackageCapabilities(
        packageId: _requiredString(map, 'packageId'),
        artifactUrl: _requiredString(map, 'artifactUrl'),
        md5: _requiredString(map, 'md5'),
        sha256: _requiredString(map, 'sha256'),
        allowedApis: _stringList(map['allowedApis']),
      );

  final String packageId;
  final String artifactUrl;
  final String md5;
  final String sha256;
  final List<String> allowedApis;

  bool allowsApi(String api) => allowedApis.contains(api.trim());
}

@immutable
class AndroidCspCapabilities {
  const AndroidCspCapabilities({
    required this.packages,
    required this.supportsGuard,
    required this.supportsDianshi,
  });

  factory AndroidCspCapabilities.fromMap(Map<Object?, Object?> map) {
    final rawPackages = map['packages'];
    final packages = rawPackages is List
        ? rawPackages
              .whereType<Map>()
              .map(
                (item) => AndroidCspPackageCapabilities.fromMap(
                  Map<Object?, Object?>.from(item),
                ),
              )
              .toList(growable: false)
        : const <AndroidCspPackageCapabilities>[];
    return AndroidCspCapabilities(
      packages: packages,
      supportsGuard: map['supportsGuard'] == true,
      supportsDianshi: map['supportsDianshi'] == true,
    );
  }

  final List<AndroidCspPackageCapabilities> packages;
  final bool supportsGuard;
  final bool supportsDianshi;

  AndroidCspPackageCapabilities? packageForMd5(String md5) {
    final normalized = md5.trim().toLowerCase();
    for (final package in packages) {
      if (package.md5 == normalized) return package;
    }
    return null;
  }
}

@immutable
class AndroidCspPreparation {
  const AndroidCspPreparation({
    required this.packageId,
    required this.md5,
    required this.sha256,
    required this.bytes,
    required this.fromCache,
  });

  factory AndroidCspPreparation.fromMap(Map<Object?, Object?> map) =>
      AndroidCspPreparation(
        packageId: _requiredString(map, 'packageId'),
        md5: _requiredString(map, 'md5'),
        sha256: _requiredString(map, 'sha256'),
        bytes: (map['bytes'] as num?)?.toInt() ?? 0,
        fromCache: map['fromCache'] == true,
      );

  final String packageId;
  final String md5;
  final String sha256;
  final int bytes;
  final bool fromCache;
}

class AndroidCspException implements Exception {
  const AndroidCspException(this.code, this.message, [this.details]);

  final String code;
  final String message;
  final Object? details;

  @override
  String toString() => 'AndroidCspException($code): $message';
}

/// Android-only bridge for the pinned, audited TVBox Spider packages.
///
/// This class never accepts an artifact URL or digest from imported rule data.
/// The Android implementation owns the immutable URL and MD5/SHA-256 allowlist.
class AndroidCspBridge {
  AndroidCspBridge({
    MethodChannel? channel,
    @visibleForTesting bool? platformSupported,
  }) : _channel = channel ?? const MethodChannel(channelName),
       _platformSupported = platformSupported;

  static const channelName = 'app.anime.anime/csp';

  final MethodChannel _channel;
  final bool? _platformSupported;

  bool get isSupported =>
      _platformSupported ??
      (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  Future<AndroidCspCapabilities> getCapabilities() async =>
      AndroidCspCapabilities.fromMap(await _invokeMap('getCapabilities'));

  Future<AndroidCspPreparation> prepare(String spiderMd5) async =>
      AndroidCspPreparation.fromMap(
        await _invokeMap('prepare', {'spiderMd5': spiderMd5}),
      );

  Future<void> initialize(AndroidCspSite site) async {
    await _invokeMap('initialize', site.toChannelArguments());
  }

  Future<String> searchContent({
    required AndroidCspSite site,
    required String keyword,
    bool quick = false,
    String? page,
  }) async {
    final response = await _invokeMap('searchContent', {
      ...site.toChannelArguments(),
      'keyword': keyword,
      'quick': quick,
      'page': ?page,
    });
    return _requiredString(response, 'json');
  }

  Future<String> detailContent({
    required AndroidCspSite site,
    required List<String> ids,
  }) async {
    final response = await _invokeMap('detailContent', {
      ...site.toChannelArguments(),
      'ids': ids,
    });
    return _requiredString(response, 'json');
  }

  Future<String> playerContent({
    required AndroidCspSite site,
    required String id,
    String flag = '',
    List<String> vipFlags = const [],
  }) async {
    final response = await _invokeMap('playerContent', {
      ...site.toChannelArguments(),
      'flag': flag,
      'id': id,
      'vipFlags': vipFlags,
    });
    return _requiredString(response, 'json');
  }

  Future<bool> destroy(AndroidCspSite site) async {
    final response = await _invokeMap('destroy', site.toChannelArguments());
    return response['destroyed'] == true;
  }

  Future<void> destroyAll() async {
    await _invokeMap('destroyAll');
  }

  Future<Map<Object?, Object?>> _invokeMap(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    if (!isSupported) {
      throw const AndroidCspException(
        'csp_platform_unsupported',
        'The native CSP bridge is available on Android only.',
      );
    }
    try {
      final response = await _channel.invokeMethod<Object?>(method, arguments);
      if (response is! Map) {
        throw const AndroidCspException(
          'csp_result_invalid',
          'The native CSP bridge returned an invalid response.',
        );
      }
      return Map<Object?, Object?>.from(response);
    } on PlatformException catch (error) {
      throw AndroidCspException(
        error.code,
        error.message ?? 'The native CSP bridge failed.',
        error.details,
      );
    } on MissingPluginException catch (error) {
      throw AndroidCspException(
        'csp_bridge_unavailable',
        'The Android CSP bridge is unavailable in this build.',
        error,
      );
    }
  }
}

String _requiredString(Map<Object?, Object?> map, String key) {
  final value = map[key];
  if (value is String && value.isNotEmpty) return value;
  throw AndroidCspException(
    'csp_result_invalid',
    'The native CSP response is missing $key.',
  );
}

List<String> _stringList(Object? value) {
  if (value is! List) return const [];
  return List<String>.unmodifiable(value.whereType<String>());
}
