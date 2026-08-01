import 'package:http/http.dart' as http;

import 'network_http_client_stub.dart'
    if (dart.library.io) 'network_http_client_io.dart'
    as platform;
import 'network_security.dart';

http.Client createNetworkHttpClient(NetworkRequestPolicy policy) =>
    platform.createNetworkHttpClient(policy);
