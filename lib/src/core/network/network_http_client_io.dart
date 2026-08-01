import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'network_security.dart';

http.Client createNetworkHttpClient(NetworkRequestPolicy policy) {
  final ioClient = HttpClient()
    ..autoUncompress = true
    ..connectionTimeout = policy.requestTimeout
    ..findProxy = (_) => 'DIRECT';
  if (!policy.allowPrivateNetwork) {
    ioClient.connectionFactory = (uri, proxyHost, proxyPort) async {
      if (proxyHost != null || proxyPort != null) {
        throw const SocketException('Network proxies are disabled.');
      }
      policy.ensureUriAllowed(uri);
      final addresses = await _publicAddresses(uri, policy);
      final port = uri.hasPort
          ? uri.port
          : uri.scheme.toLowerCase() == 'https'
          ? 443
          : 80;
      var cancelled = false;
      ConnectionTask<Socket>? activeTask;
      Socket? activeSocket;
      Future<Socket> connect() async {
        Object? lastError;
        StackTrace? lastStackTrace;
        for (final address in addresses) {
          if (cancelled) throw const SocketException('Connection cancelled.');
          try {
            final task = await Socket.startConnect(address, port);
            activeTask = task;
            final socket = await task.socket;
            activeTask = null;
            if (cancelled) {
              socket.destroy();
              throw const SocketException('Connection cancelled.');
            }
            activeSocket = socket;
            if (uri.scheme.toLowerCase() != 'https') return socket;
            final secure = await SecureSocket.secure(socket, host: uri.host);
            activeSocket = secure;
            return secure;
          } catch (error, stackTrace) {
            activeTask = null;
            activeSocket?.destroy();
            activeSocket = null;
            if (cancelled) rethrow;
            lastError = error;
            lastStackTrace = stackTrace;
          }
        }
        if (lastError != null && lastStackTrace != null) {
          Error.throwWithStackTrace(lastError, lastStackTrace);
        }
        throw const SocketException('No usable public address was found.');
      }

      return ConnectionTask.fromSocket(connect(), () {
        cancelled = true;
        activeTask?.cancel();
        activeSocket?.destroy();
      });
    };
  }
  return PolicyHttpClient(inner: IOClient(ioClient), policy: policy);
}

Future<List<InternetAddress>> _publicAddresses(
  Uri uri,
  NetworkRequestPolicy policy,
) async {
  final host = uri.host;
  final literal = InternetAddress.tryParse(host);
  final addresses = literal == null
      ? await InternetAddress.lookup(host).timeout(const Duration(seconds: 3))
      : [literal];
  final allowSyntheticDns =
      literal == null &&
      uri.scheme.toLowerCase() == 'https' &&
      policy.allowSyntheticDns;
  if (addresses.isEmpty ||
      addresses.any(
        (address) =>
            _isBlockedAddress(address, allowSyntheticDns: allowSyntheticDns),
      )) {
    throw const NetworkSecurityException(
      'DNS resolved to a private or special-purpose address.',
    );
  }
  return addresses.toList(growable: false)..sort((a, b) {
    final first = a.type == InternetAddressType.IPv4 ? 0 : 1;
    final second = b.type == InternetAddressType.IPv4 ? 0 : 1;
    return first.compareTo(second);
  });
}

bool _isBlockedAddress(
  InternetAddress address, {
  required bool allowSyntheticDns,
}) {
  if (address.isLoopback || address.isLinkLocal || address.isMulticast) {
    return true;
  }
  final bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv4 && bytes.length == 4) {
    return _isBlockedIpv4(bytes, allowSyntheticDns: allowSyntheticDns);
  }
  if (address.type == InternetAddressType.IPv6 && bytes.length == 16) {
    final mapped =
        bytes.take(10).every((value) => value == 0) &&
        bytes[10] == 0xff &&
        bytes[11] == 0xff;
    if (mapped) {
      return _isBlockedIpv4(
        bytes.sublist(12),
        allowSyntheticDns: allowSyntheticDns,
      );
    }
    final allZero = bytes.every((value) => value == 0);
    final loopback =
        bytes.take(15).every((value) => value == 0) && bytes.last == 1;
    final uniqueLocal = (bytes[0] & 0xfe) == 0xfc;
    final linkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80;
    return allZero || loopback || uniqueLocal || linkLocal || bytes[0] == 0xff;
  }
  return true;
}

bool _isBlockedIpv4(List<int> bytes, {required bool allowSyntheticDns}) {
  final first = bytes[0];
  final second = bytes[1];
  final third = bytes[2];
  return first == 0 ||
      first == 10 ||
      first == 127 ||
      (first == 100 && second >= 64 && second <= 127) ||
      (first == 169 && second == 254) ||
      (first == 172 && second >= 16 && second <= 31) ||
      (first == 192 && second == 0 && third == 0) ||
      (first == 192 && second == 0 && third == 2) ||
      (first == 192 && second == 168) ||
      (!allowSyntheticDns && first == 198 && (second == 18 || second == 19)) ||
      (first == 198 && second == 51 && third == 100) ||
      (first == 203 && second == 0 && third == 113) ||
      first >= 224;
}
