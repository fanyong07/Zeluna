import 'package:http/http.dart' as http;

import 'network_http_client_stub.dart'
    if (dart.library.io) 'network_http_client_io.dart'
    as platform;
import 'network_security.dart';

http.Client createNetworkHttpClient(NetworkRequestPolicy policy) =>
    platform.createNetworkHttpClient(policy);

http.Client createUntrustedSourceHttpClient({
  int maxResponseBytes = 4 * 1024 * 1024,
  Duration timeout = const Duration(seconds: 12),
}) => createNetworkHttpClient(
  NetworkRequestPolicy(
    service: NetworkServiceKind.rulePage,
    httpsOnly: false,
    allowPrivateNetwork: false,
    maxResponseBytes: maxResponseBytes,
    requestTimeout: timeout,
    rejectRedirects: false,
  ),
);

http.Client createTrustedMediaProbeHttpClient() => createNetworkHttpClient(
  const NetworkRequestPolicy(
    service: NetworkServiceKind.mediaResource,
    httpsOnly: false,
    allowPrivateNetwork: false,
    maxResponseBytes: 512 * 1024,
    requestTimeout: Duration(seconds: 12),
    allowSyntheticDns: true,
    allowLiteralBenchmarkAddress: true,
    rejectRedirects: false,
  ),
);
