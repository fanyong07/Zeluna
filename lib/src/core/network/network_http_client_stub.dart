import 'package:http/http.dart' as http;

import 'network_security.dart';

http.Client createNetworkHttpClient(NetworkRequestPolicy policy) =>
    PolicyHttpClient(inner: http.Client(), policy: policy);
