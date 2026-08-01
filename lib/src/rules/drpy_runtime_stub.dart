import 'package:http/http.dart' as http;

import '../core/network/network_http_client.dart';
import 'drpy_runtime_models.dart';

Future<void> ensurePublicDrpyHttpUri(Uri uri) async {
  final scheme = uri.scheme.toLowerCase();
  final host = uri.host.toLowerCase();
  if (!const {'http', 'https'}.contains(scheme) || host.isEmpty) {
    throw const FormatException(
      'drpy requests only allow public HTTP(S) URLs.',
    );
  }
  if (uri.userInfo.isNotEmpty) {
    throw const FormatException(
      'drpy request URLs cannot contain credentials.',
    );
  }
  if (host == 'localhost' || host.endsWith('.localhost')) {
    throw const FormatException('drpy private-network request blocked.');
  }
}

http.Client createDrpyPublicHttpClient({Object? addressLookup}) =>
    createUntrustedSourceHttpClient(maxResponseBytes: 2 * 1024 * 1024);

class DrpyRuntime {
  DrpyRuntime({
    DrpyLocalStorage? storage,
    this.limits = const DrpyRuntimeLimits(),
    Object? addressLookup,
  }) : storage = storage ?? DrpyLocalStorage();

  final DrpyLocalStorage storage;
  final DrpyRuntimeLimits limits;

  Future<void> ensurePublicUri(Uri uri) => ensurePublicDrpyHttpUri(uri);

  http.Client createPublicHttpClient() => createDrpyPublicHttpClient();

  Future<DrpyRuntimeResult> resolve(
    DrpyRuntimeRequest request, {
    http.Client? client,
  }) async {
    return const DrpyRuntimeResult(
      candidates: [],
      error: 'drpy-js is only available on Android and Windows native builds.',
    );
  }
}
