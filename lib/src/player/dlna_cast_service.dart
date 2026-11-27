import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

const _transport = 'urn:schemas-upnp-org:service:AVTransport:1';
const _renderer = 'urn:schemas-upnp-org:device:MediaRenderer:1';
const _deadline = Duration(milliseconds: 2500);

class DlnaDevice {
  const DlnaDevice({
    required this.id,
    required this.name,
    required this.controlUri,
    required this.host,
  });
  final String id, name, host;
  final Uri controlUri;
}

bool _http(Uri uri) =>
    (uri.isScheme('http') || uri.isScheme('https')) && uri.host.isNotEmpty;
bool _lan(Uri uri) {
  if (!_http(uri) || uri.userInfo.isNotEmpty || uri.hasFragment) return false;
  final octets = uri.host.split('.');
  if (octets.length != 4) return false;
  final bytes = <int>[];
  for (final part in octets) {
    final n = int.tryParse(part);
    if (n == null || n < 0 || n > 255 || '$n' != part) return false;
    bytes.add(n);
  }
  return bytes[0] == 10 ||
      (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
      (bytes[0] == 192 && bytes[1] == 168) ||
      (bytes[0] == 169 && bytes[1] == 254);
}

Uri? parseSsdpLocation(String datagram) {
  for (final line in const LineSplitter().convert(datagram)) {
    final i = line.indexOf(':');
    if (i < 0 || line.substring(0, i).trim().toLowerCase() != 'location') {
      continue;
    }
    final uri = Uri.tryParse(line.substring(i + 1).trim());
    return uri != null && _lan(uri) ? uri : null;
  }
  return null;
}

DlnaDevice? parseDlnaDeviceDescription(String xmlBody, Uri locationUri) {
  if (!_lan(locationUri)) return null;
  try {
    final doc = XmlDocument.parse(xmlBody);
    for (final device in doc.findAllElements('device', namespace: '*')) {
      String? text(XmlElement e, String key) =>
          e.getElement(key, namespace: '*')?.innerText.trim();
      final name = text(device, 'friendlyName');
      final services = device.getElement('serviceList', namespace: '*');
      if (name == null || name.isEmpty || services == null) continue;
      for (final service in services.findElements('service', namespace: '*')) {
        if (text(service, 'serviceType') != _transport) continue;
        final path = text(service, 'controlURL');
        if (path == null || path.isEmpty) continue;
        final control = locationUri.resolve(path);
        if (!_lan(control)) continue;
        return DlnaDevice(
          id: text(device, 'UDN') ?? control.toString(),
          name: name,
          controlUri: control,
          host: control.host,
        );
      }
    }
  } on XmlException {
    return null;
  } on FormatException {
    return null;
  }
  return null;
}

String _envelope(String action, Map<String, String> fields) {
  final b = XmlBuilder()..declaration(encoding: 'utf-8');
  b.element(
    's:Envelope',
    attributes: {
      'xmlns:s': 'http://schemas.xmlsoap.org/soap/envelope/',
      's:encodingStyle': 'http://schemas.xmlsoap.org/soap/encoding/',
    },
    nest: () {
      b.element(
        's:Body',
        nest: () => b.element(
          'u:$action',
          attributes: {'xmlns:u': _transport},
          nest: () {
            b.element('InstanceID', nest: '0');
            fields.forEach((name, value) => b.element(name, nest: value));
          },
        ),
      );
    },
  );
  return b.buildDocument().toXmlString();
}

String buildSetAvTransportUriSoap({
  required String mediaUrl,
  required String title,
}) {
  final didl = XmlBuilder();
  didl.element(
    'DIDL-Lite',
    attributes: {
      'xmlns': 'urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/',
      'xmlns:dc': 'http://purl.org/dc/elements/1.1/',
      'xmlns:upnp': 'urn:schemas-upnp-org:metadata-1-0/upnp/',
    },
    nest: () {
      didl.element(
        'item',
        attributes: {'id': '0', 'parentID': '-1', 'restricted': '1'},
        nest: () {
          didl.element('dc:title', nest: title);
          didl.element('upnp:class', nest: 'object.item.videoItem');
          didl.element(
            'res',
            attributes: {'protocolInfo': 'http-get:*:*:*'},
            nest: mediaUrl,
          );
        },
      );
    },
  );
  return _envelope('SetAVTransportURI', {
    'CurrentURI': mediaUrl,
    'CurrentURIMetaData': didl.buildDocument().toXmlString(),
  });
}

String buildPlaySoap() => _envelope('Play', {'Speed': '1'});

class DlnaCastService {
  const DlnaCastService({http.Client? client}) : _client = client;
  final http.Client? _client;

  // Do not follow a LAN device's redirect outside the validated address. Limit
  // both time and buffered bytes even for chunked responses without a length.
  Future<String> _request(http.Request request) async {
    final client = _client ?? http.Client();
    Future<String> read() async {
      final response = await client.send(request..followRedirects = false);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.stream.listen(null).cancel();
        throw HttpException('设备拒绝了请求 (${response.statusCode})');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.stream) {
        if (bytes.length + chunk.length > 512 * 1024) {
          throw const FormatException('设备响应过大');
        }
        bytes.add(chunk);
      }
      return utf8.decode(bytes.takeBytes());
    }

    try {
      return await read().timeout(_deadline);
    } finally {
      if (_client == null) client.close();
    }
  }

  Future<List<DlnaDevice>> discoverDevices({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final locations = <Uri>{};
    final done = Completer<void>();
    final subscription = socket.listen(
      (event) {
        if (event != RawSocketEvent.read) return;
        final packet = socket.receive();
        if (packet == null || locations.length >= 32) return;
        final uri = parseSsdpLocation(latin1.decode(packet.data));
        if (uri != null) locations.add(uri);
      },
      onError: (Object e) {
        if (!done.isCompleted) done.completeError(e);
      },
    );
    try {
      final multicast = InternetAddress('239.255.255.250');
      for (final target in const [_renderer, _transport]) {
        socket.send(
          ascii.encode(
            'M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: "ssdp:discover"\r\nMX: 2\r\nST: $target\r\n\r\n',
          ),
          multicast,
          1900,
        );
      }
      await done.future.timeout(timeout, onTimeout: () {});
    } finally {
      socket.close();
      await subscription.cancel();
    }
    // A broken or offline renderer must not hide the other devices.
    final devices = await Future.wait(
      locations.map((uri) async {
        try {
          return parseDlnaDeviceDescription(
            await _request(http.Request('GET', uri)),
            uri,
          );
        } on Exception {
          return null;
        }
      }),
    );
    return {
      for (final d in devices.whereType<DlnaDevice>()) d.id: d,
    }.values.toList();
  }

  Future<void> castMedia(
    DlnaDevice device, {
    required String mediaUrl,
    required String title,
  }) async {
    final media = Uri.tryParse(mediaUrl);
    if (media == null || !_http(media) || !_lan(device.controlUri)) {
      throw const FormatException('无效的投屏地址');
    }
    Future<void> send(String action, String body) async {
      final request = http.Request('POST', device.controlUri)
        ..headers.addAll({
          'SOAPAction': '"$_transport#$action"',
          'Content-Type': 'text/xml; charset="utf-8"',
        })
        ..bodyBytes = utf8.encode(body);
      final result = await _request(request);
      if (result.trim().isNotEmpty &&
          XmlDocument.parse(
            result,
          ).findAllElements('Fault', namespace: '*').isNotEmpty) {
        throw const HttpException('设备不支持播放此媒体');
      }
    }

    await send(
      'SetAVTransportURI',
      buildSetAvTransportUriSoap(mediaUrl: mediaUrl, title: title),
    );
    await send('Play', buildPlaySoap());
  }
}
