import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../core/network/network_http_client.dart';
import '../core/network/network_security.dart';
import 'app_update_models.dart';

class _GitHubRateLimited implements Exception {
  const _GitHubRateLimited();
}

abstract interface class AppUpdateRepository {
  Future<UpdateRelease?> check(UpdateCancellation cancellation);
}

/// A fresh, policy-wrapped transport is owned by each check/download operation.
/// Test transports cannot bypass URI checks or automatic-redirect suppression.
http.Client createAppUpdateHttpClient(
  NetworkRequestPolicy policy, {
  http.Client Function()? clientFactory,
}) => RedirectingNetworkHttpClient(
  inner: clientFactory == null
      ? createNetworkHttpClient(policy)
      : PolicyHttpClient(inner: clientFactory(), policy: policy),
  policy: policy,
);

class ReleaseAppUpdateRepository implements AppUpdateRepository {
  ReleaseAppUpdateRepository({
    http.Client Function()? clientFactory,
    Uri? endpoint,
    this.targetPlatform = 'android',
    String manifestUrl = const String.fromEnvironment(
      'ZELUNA_UPDATE_MANIFEST_URL',
    ),
    this.checkTimeout = const Duration(seconds: 30),
  }) : _clientFactory = clientFactory,
       _endpoint = endpoint ?? githubLatestEndpoint,
       _manifestUrl = manifestUrl;

  static final githubLatestEndpoint = Uri.parse(
    'https://api.github.com/repos/fanyong07/Zeluna/releases/latest',
  );

  final http.Client Function()? _clientFactory;
  final Uri _endpoint;
  final String _manifestUrl;
  final String targetPlatform;
  String _artifactName(String tag) =>
      'Zeluna-$tag-${targetPlatform == 'windows' ? 'Windows.zip' : 'Android.apk'}';
  final Duration checkTimeout;

  @override
  Future<UpdateRelease?> check(UpdateCancellation cancellation) async {
    cancellation.throwIfCancelled();
    final operation = UpdateCancellation();
    final aborted = Completer<UpdateRelease?>();
    var timedOut = false;
    http.Client? client;
    final unlinkParent = cancellation.register(operation.cancel);
    final unlinkAbort = operation.register(() {
      client?.close();
      if (!aborted.isCompleted) aborted.completeError(const UpdateCancelled());
    });
    final timer = Timer(checkTimeout, () {
      timedOut = true;
      operation.cancel();
    });
    try {
      final policyClient = _clientFactory == null
          ? createNetworkHttpClient(appUpdateJsonPolicy)
          : PolicyHttpClient(
              inner: _clientFactory(),
              policy: appUpdateJsonPolicy,
            );
      client = RedirectingNetworkHttpClient(
        inner: policyClient,
        policy: appUpdateJsonPolicy,
      );
      final activeClient = client;
      final work = () async {
        if (_manifestUrl.isNotEmpty) {
          final json = await _json(
            activeClient,
            parseUpdateUri(_manifestUrl),
            operation,
          );
          final release = UpdateRelease.fromJson(json!);
          if (release.platform != targetPlatform) throw invalidUpdateManifest;
          return release;
        }
        try {
          final release = await _json(
            activeClient,
            _endpoint,
            operation,
            allowNotFound: true,
            allowRateLimitFallback: _endpoint == githubLatestEndpoint,
          );
          if (release == null) return null;
          return await _githubRelease(activeClient, release, operation);
        } on _GitHubRateLimited {
          final tag = await _latestPublicTag(policyClient, operation);
          return _manifestRelease(
            activeClient,
            tag,
            operation,
            notes: '更新内容请参阅发布说明',
          );
        }
      }();
      final result = await Future.any([work, aborted.future]);
      cancellation.throwIfCancelled();
      operation.throwIfCancelled();
      return result;
    } catch (error) {
      if (cancellation.isCancelled) throw const UpdateCancelled();
      if (timedOut || error is TimeoutException) {
        throw const UpdateFailure('check_timeout', '检查更新超时，请稍后重试');
      }
      if (error is UpdateFailure || error is UpdateCancelled) rethrow;
      if (error is FormatException || error is TypeError) {
        throw invalidUpdateManifest;
      }
      if (error is NetworkSecurityException) {
        throw const UpdateFailure('network_policy', '更新地址或响应不符合要求');
      }
      throw const UpdateFailure('check_network', '检查更新失败，请检查网络后重试');
    } finally {
      timer.cancel();
      unlinkParent();
      unlinkAbort();
      operation.cancel();
      client?.close();
    }
  }

  Future<UpdateRelease?> _githubRelease(
    http.Client client,
    Map<String, dynamic> release,
    UpdateCancellation cancellation,
  ) async {
    if (release['draft'] is! bool || release['prerelease'] is! bool) {
      throw invalidUpdateManifest;
    }
    if (release['draft'] == true || release['prerelease'] == true) return null;
    final tag = release['tag_name'];
    if (tag is! String ||
        !tag.startsWith('v') ||
        !isUpdateVersion(tag.substring(1))) {
      throw invalidUpdateManifest;
    }
    final assets = release['assets'];
    if (assets is! List) throw invalidUpdateManifest;
    final manifestName = 'Zeluna-$tag-manifest.json';
    final artifactName = _artifactName(tag);
    final manifestAsset = _exactAsset(assets, manifestName);
    final artifactAsset = _exactAsset(assets, artifactName);
    final manifestSize = manifestAsset['size'];
    final artifactSize = artifactAsset['size'];
    if (manifestSize is! int ||
        manifestSize <= 0 ||
        manifestSize > appUpdateMaxJsonBytes ||
        artifactSize is! int ||
        artifactSize <= 0 ||
        artifactSize > appUpdateMaxApkBytes) {
      throw invalidUpdateManifest;
    }
    final body = release['body'];
    if (body != null && body is! String) throw invalidUpdateManifest;
    return _manifestRelease(
      client,
      tag,
      cancellation,
      notes: (body as String?) ?? '',
      manifestSize: manifestSize,
      artifactSize: artifactSize,
    );
  }

  /// The public latest redirect is an anonymous-rate-limit fallback, not HTML
  /// scraping. Every HEAD hop stays in this exact repository on github.com.
  Future<String> _latestPublicTag(
    http.Client policyClient,
    UpdateCancellation cancellation,
  ) async {
    var uri = Uri.parse('https://github.com/fanyong07/Zeluna/releases/latest');
    const prefix = '/fanyong07/Zeluna/releases/tag/';
    for (var hop = 0; hop <= 5; hop++) {
      cancellation.throwIfCancelled();
      appUpdateJsonPolicy.ensureUriAllowed(uri);
      final tag = uri.path.startsWith(prefix)
          ? uri.path.substring(prefix.length)
          : null;
      if (uri.host != 'github.com' ||
          uri.port != 443 ||
          uri.hasQuery ||
          uri.hasFragment ||
          (uri.path != '/fanyong07/Zeluna/releases/latest' &&
              (tag == null ||
                  !tag.startsWith('v') ||
                  !isUpdateVersion(tag.substring(1))))) {
        throw invalidUpdateManifest;
      }
      final response = await policyClient.send(
        http.Request('HEAD', uri)
          ..headers.addAll(const {
            'user-agent': 'Zeluna-App-Updater',
            'accept': '*/*',
          }),
      );
      await response.stream.listen(null).cancel();
      cancellation.throwIfCancelled();
      if (response.statusCode == 200 && tag != null) return tag;
      if (!const [301, 302, 303, 307, 308].contains(response.statusCode)) {
        throw const UpdateFailure('check_http', '更新服务暂时不可用，请稍后重试');
      }
      final location = response.headers['location'];
      if (location == null || location.isEmpty) throw invalidUpdateManifest;
      uri = uri.resolve(location);
    }
    throw invalidUpdateManifest;
  }

  Future<UpdateRelease> _manifestRelease(
    http.Client client,
    String tag,
    UpdateCancellation cancellation, {
    required String notes,
    int? manifestSize,
    int? artifactSize,
  }) async {
    final version = tag.substring(1);
    final manifestName = 'Zeluna-$tag-manifest.json';
    final artifactName = _artifactName(tag);
    // The API's browser_download_url/url fields are never trusted as endpoints.
    final base = 'https://github.com/fanyong07/Zeluna/releases/download/$tag/';
    final manifest = (await _json(
      client,
      Uri.parse('$base$manifestName'),
      cancellation,
      expectedBytes: manifestSize,
    ))!;
    if (manifest['schema'] != 'zeluna-release-manifest-v2') {
      throw invalidUpdateManifest;
    }
    final fullVersion = manifest['version'];
    if (fullVersion is! String) throw invalidUpdateManifest;
    final parts = fullVersion.split('+');
    if (parts.length != 2 ||
        parts[0] != version ||
        !RegExp(r'^[1-9][0-9]*$').hasMatch(parts[1])) {
      throw invalidUpdateManifest;
    }
    final build = int.tryParse(parts[1]);
    if (build == null || build <= 0 || build > 0x7fffffff) {
      throw invalidUpdateManifest;
    }
    final artifacts = manifest['artifacts'];
    if (artifacts is! List) throw invalidUpdateManifest;
    final artifact = _exactAsset(artifacts, artifactName);
    if (artifact['bytes'] is! int ||
        (artifactSize != null && artifact['bytes'] != artifactSize) ||
        (targetPlatform == 'android' &&
            (artifact['native_abis'] is! List ||
                (artifact['native_abis'] as List).isEmpty))) {
      throw invalidUpdateManifest;
    }
    return UpdateRelease.fromJson({
      'schema': 'zeluna-app-update-v1',
      'platform': targetPlatform,
      'package_name': appUpdatePackageName,
      'version': version,
      'build_number': build,
      'apk': {
        'url': '$base$artifactName',
        'sha256': artifact['sha256'],
        'bytes': artifact['bytes'],
        if (targetPlatform == 'android') 'abis': artifact['native_abis'],
        if (targetPlatform == 'android' && artifact.containsKey('min_sdk'))
          'min_sdk': artifact['min_sdk'],
      },
      'notes': notes.length > appUpdateMaxNotesLength
          ? notes.substring(0, appUpdateMaxNotesLength)
          : notes,
      'release_page': 'https://github.com/fanyong07/Zeluna/releases/tag/$tag',
    });
  }

  Map<String, dynamic> _exactAsset(List<dynamic> values, String name) {
    final matches = values
        .whereType<Map<String, dynamic>>()
        .where((entry) => entry['name'] == name)
        .toList();
    if (matches.length != 1) throw invalidUpdateManifest;
    return matches.single;
  }

  Future<Map<String, dynamic>?> _json(
    http.Client client,
    Uri uri,
    UpdateCancellation cancellation, {
    bool allowNotFound = false,
    bool allowRateLimitFallback = false,
    int? expectedBytes,
  }) async {
    cancellation.throwIfCancelled();
    final request = http.Request('GET', uri)
      ..headers.addAll(const {
        'user-agent': 'Zeluna-App-Updater',
        'accept': 'application/json',
      });
    final response = await client.send(request);
    if (cancellation.isCancelled || response.statusCode != 200) {
      await response.stream.listen(null).cancel();
      cancellation.throwIfCancelled();
      if (allowNotFound && response.statusCode == 404) return null;
      if (allowRateLimitFallback &&
          (response.statusCode == 403 || response.statusCode == 429)) {
        throw const _GitHubRateLimited();
      }
      throw const UpdateFailure('check_http', '更新服务暂时不可用，请稍后重试');
    }
    final iterator = StreamIterator<List<int>>(response.stream);
    final unlink = cancellation.register(() => unawaited(iterator.cancel()));
    try {
      cancellation.throwIfCancelled();
      final builder = BytesBuilder(copy: false);
      while (await iterator.moveNext()) {
        cancellation.throwIfCancelled();
        final chunk = iterator.current;
        if (builder.length + chunk.length > appUpdateMaxJsonBytes) {
          throw invalidUpdateManifest;
        }
        builder.add(chunk);
      }
      cancellation.throwIfCancelled();
      if (expectedBytes != null && builder.length != expectedBytes) {
        throw invalidUpdateManifest;
      }
      final value = jsonDecode(utf8.decode(builder.takeBytes()));
      if (value is! Map<String, dynamic>) throw invalidUpdateManifest;
      return value;
    } finally {
      unlink();
      await iterator.cancel();
    }
  }
}
