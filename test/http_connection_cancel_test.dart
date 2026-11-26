import 'dart:async';
import 'dart:io';
import 'package:anime/src/core/network/connection_race.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'closing an HTTP connection race reports a catchable client exception',
    () async {
      final started = Completer<void>();
      final raw = HttpClient()
        ..connectionFactory = (uri, proxyHost, proxyPort) async {
          final race = raceConnections<Socket>(
            cancellationError: const SocketException('Connection cancelled'),
            candidates: [
              () async => ConnectionAttempt(Completer<Socket>().future, () {}),
            ],
            close: (socket) => socket.destroy(),
          );
          started.complete();
          return ConnectionTask.fromSocket(race.value, race.cancel);
        };
      final client = IOClient(raw);
      final request = client.get(Uri.parse('https://example.test/image'));
      final assertion = expectLater(
        request,
        throwsA(isA<http.ClientException>()),
      );
      await started.future;
      await Future<void>.delayed(Duration.zero);
      client.close();
      await assertion;
    },
  );
}
