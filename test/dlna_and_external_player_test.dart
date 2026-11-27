import 'dart:io';

import 'package:anime/src/player/dlna_cast_service.dart';
import 'package:anime/src/player/external_player_launcher.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:xml/xml.dart';

final location = Uri.parse('http://192.168.1.2:1400/desc/device.xml');
final device = DlnaDevice(
  id: 'tv',
  name: 'TV',
  controlUri: location.resolve('/avt'),
  host: location.host,
);
String description(String control) =>
    '<root xmlns="urn:schemas-upnp-org:device-1-0"><device><friendlyName>客厅电视</friendlyName><UDN>uuid:tv</UDN><serviceList><service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType><controlURL>$control</controlURL></service></serviceList></device></root>';
const media = 'https://media.example/video?a=1&ampersand=2';

void main() {
  test('SSDP accepts only literal LAN IPv4 over HTTP(S)', () {
    Uri? parse(String url) =>
        parseSsdpLocation('HTTP/1.1 200 OK\r\nlOcAtiOn: $url\r\n\r\n');
    for (final host in [
      '10.0.0.1',
      '172.16.1.1',
      '172.31.255.1',
      '192.168.1.255',
      '169.254.0.3',
    ]) {
      expect(parse('https://$host/a')?.host, host);
    }
    for (final url in [
      'https://8.8.8.8/x',
      'http://172.15.0.1',
      'http://172.32.0.1',
      'http://192.168.1.256',
      'http://localhost',
      'file:///tmp/x',
      'http://192.168.0.1@public.example',
      'http://10.0.0.1.evil.example',
      'http://010.0.1.1',
    ]) {
      expect(parse(url), isNull, reason: url);
    }
  });
  test(
    'device description resolves relative and absolute LAN control URLs',
    () {
      for (final path in ['avt', '/avt', 'http://192.168.1.2:1400/avt']) {
        final parsed = parseDlnaDeviceDescription(description(path), location)!;
        expect(parsed.name, '客厅电视');
        expect(parsed.id, 'uuid:tv');
        expect(parsed.controlUri, location.resolve(path));
      }
      expect(
        parseDlnaDeviceDescription(
          description('//public.example/avt'),
          location,
        ),
        isNull,
      );
      expect(parseDlnaDeviceDescription('<invalid', location), isNull);
    },
  );
  test('XML round-trips URL and title through SOAP and nested DIDL', () {
    const url = 'https://media.example/video?q=<x>&next=yes';
    const title = '电影 & <片名>';
    final soap = XmlDocument.parse(
      buildSetAvTransportUriSoap(mediaUrl: url, title: title),
    );
    expect(soap.findAllElements('CurrentURI').single.innerText, url);
    final didl = XmlDocument.parse(
      soap.findAllElements('CurrentURIMetaData').single.innerText,
    );
    expect(
      didl.findAllElements('title', namespace: '*').single.innerText,
      title,
    );
    expect(didl.findAllElements('res').single.innerText, url);
  });
  test(
    'cast sends SetAVTransportURI then Play, never follows redirects',
    () async {
      final calls = <String>[];
      final service = DlnaCastService(
        client: MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.url, device.controlUri);
          expect(request.followRedirects, isFalse);
          expect(request.headers['content-type'], 'text/xml; charset="utf-8"');
          final action = XmlDocument.parse(request.body)
              .findAllElements('Body', namespace: '*')
              .single
              .childElements
              .single
              .name
              .local;
          expect(
            request.headers['soapaction'],
            '"urn:schemas-upnp-org:service:AVTransport:1#$action"',
          );
          calls.add(action);
          return http.Response('', 200);
        }),
      );
      await service.castMedia(device, mediaUrl: media, title: 'Test');
      expect(calls, ['SetAVTransportURI', 'Play']);
      await expectLater(
        service.castMedia(device, mediaUrl: 'file:///secret', title: ''),
        throwsFormatException,
      );
      expect(calls, hasLength(2));
    },
  );
  test('failed SetURI never sends Play', () async {
    var attempts = 0;
    final service = DlnaCastService(
      client: MockClient((_) async {
        attempts++;
        return http.Response(
          '',
          302,
          headers: {'location': 'https://public.example/avt'},
        );
      }),
    );
    await expectLater(
      service.castMedia(device, mediaUrl: media, title: ''),
      throwsA(isA<HttpException>()),
    );
    expect(attempts, 1);
  });
  testWidgets(
    'external launcher validates URL before invoking native chooser',
    (tester) async {
      const channel = MethodChannel('app.anime.anime/external-player');
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        c,
      ) async {
        calls.add(c);
        return true;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      expect(
        await launchAndroidExternalPlayer(url: 'file:///test.mp4'),
        isFalse,
      );
      expect(calls, isEmpty);
      expect(
        await launchAndroidExternalPlayer(url: media, title: 'Test'),
        isTrue,
      );
      expect(calls.single.method, 'openVideoUrl');
      expect(calls.single.arguments, {'url': media, 'title': 'Test'});
      expect(
        await launchWindowsExternalPlayer(
          const ExternalPlayerApp(
            id: 'mpv',
            name: 'mpv',
            executablePath: 'mpv.exe',
          ),
          url: media,
        ),
        isFalse,
      );
    },
  );
}
