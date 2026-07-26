import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:charset/charset.dart';
import 'package:crypto/crypto.dart';
import 'package:html/dom.dart' as html_dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:jsf/jsf.dart';

import 'drpy_runtime_models.dart';

const _loopbackHost = '127.0.0.1';
const _maxBrokerRequestBytes = 512 * 1024;
const _maxRuntimeLogs = 48;
const _maxRuntimeLogLength = 500;

typedef DrpyAddressLookup = Future<List<InternetAddress>> Function(String host);

Future<List<InternetAddress>> _defaultDrpyAddressLookup(String host) =>
    InternetAddress.lookup(host);

Future<void> ensurePublicDrpyHttpUri(Uri uri) =>
    _ensurePublicHttpUri(uri, _defaultDrpyAddressLookup);

http.Client createDrpyPublicHttpClient({DrpyAddressLookup? addressLookup}) {
  final lookup = addressLookup ?? _defaultDrpyAddressLookup;
  final ioClient = HttpClient();
  ioClient.findProxy = (_) => 'DIRECT';
  ioClient.connectionFactory = (uri, proxyHost, proxyPort) async {
    if (proxyHost != null || proxyPort != null) {
      throw const SocketException('drpy HTTP proxies are disabled.');
    }
    final addresses = await _publicAddressesForUri(uri, lookup);
    final orderedAddresses = addresses.toList(growable: false)
      ..sort((a, b) {
        final aRank = a.type == InternetAddressType.IPv4 ? 0 : 1;
        final bRank = b.type == InternetAddressType.IPv4 ? 0 : 1;
        return aRank.compareTo(bRank);
      });
    final port = uri.hasPort
        ? uri.port
        : uri.scheme.toLowerCase() == 'https'
        ? 443
        : 80;
    var cancelled = false;
    ConnectionTask<Socket>? activeTask;
    Socket? connectedSocket;
    Future<Socket> connect() async {
      Object? lastError;
      StackTrace? lastStackTrace;
      for (final address in orderedAddresses) {
        if (cancelled) {
          throw const SocketException('drpy connection cancelled.');
        }
        try {
          final task = await Socket.startConnect(address, port);
          activeTask = task;
          final rawSocket = await task.socket;
          activeTask = null;
          if (cancelled) {
            rawSocket.destroy();
            throw const SocketException('drpy connection cancelled.');
          }
          connectedSocket = rawSocket;
          if (uri.scheme.toLowerCase() != 'https') return rawSocket;
          final secureSocket = await SecureSocket.secure(
            rawSocket,
            host: uri.host,
          );
          connectedSocket = secureSocket;
          return secureSocket;
        } catch (error, stackTrace) {
          activeTask = null;
          connectedSocket?.destroy();
          connectedSocket = null;
          if (cancelled) rethrow;
          lastError = error;
          lastStackTrace = stackTrace;
        }
      }
      if (lastError != null && lastStackTrace != null) {
        Error.throwWithStackTrace(lastError, lastStackTrace);
      }
      throw const SocketException('drpy public host has no usable address.');
    }

    final socket = connect();
    return ConnectionTask.fromSocket(socket, () {
      cancelled = true;
      activeTask?.cancel();
      connectedSocket?.destroy();
    });
  };
  return IOClient(ioClient);
}

class DrpyRuntime {
  DrpyRuntime({
    DrpyLocalStorage? storage,
    this.limits = const DrpyRuntimeLimits(),
    DrpyAddressLookup? addressLookup,
  }) : storage = storage ?? DrpyLocalStorage(),
       _addressLookup = addressLookup ?? _defaultDrpyAddressLookup;

  final DrpyLocalStorage storage;
  final DrpyRuntimeLimits limits;
  final DrpyAddressLookup _addressLookup;

  Future<void> ensurePublicUri(Uri uri) =>
      _ensurePublicHttpUri(uri, _addressLookup);

  http.Client createPublicHttpClient() =>
      createDrpyPublicHttpClient(addressLookup: _addressLookup);

  Future<DrpyRuntimeResult> resolve(
    DrpyRuntimeRequest request, {
    http.Client? client,
  }) async {
    if (request.ruleSource.trim().isEmpty && request.ruleUrl.trim().isEmpty) {
      return const DrpyRuntimeResult(
        candidates: [],
        error: 'drpy rule has no inline source or resolvable ext URL.',
      );
    }

    final ownedClient = client == null;
    final effectiveClient = client ?? createPublicHttpClient();
    final broker = await _DrpyHttpBroker.start(
      client: effectiveClient,
      limits: limits,
      baseHeaders: request.requestHeaders,
      credentialOrigin: request.credentialOrigin,
      addressLookup: _addressLookup,
    );
    try {
      final payload = <String, Object?>{
        'brokerPort': broker.port,
        'brokerToken': broker.token,
        'limits': _limitsToJson(limits),
        'ruleId': request.ruleId,
        'ruleSource': request.ruleSource,
        'ruleUrl': request.ruleUrl,
        'keyword': request.keyword,
        'episodeNumber': request.episodeNumber,
        'episodeTitle': request.episodeTitle,
        'storage': storage.snapshot(request.ruleId),
      };
      final raw = await Isolate.run(() => _runDrpyWorker(payload)).timeout(
        limits.overallTimeout,
        onTimeout: () => <String, Object?>{
          'ok': false,
          'error': 'drpy execution exceeded the total time budget.',
          'candidates': const <Object?>[],
          'logs': const <Object?>[],
          'storage': storage.snapshot(request.ruleId),
        },
      );
      final nextStorage = raw['storage'];
      if (nextStorage is Map) {
        storage.replace(
          request.ruleId,
          nextStorage.map((key, value) => MapEntry(key.toString(), value)),
        );
      }
      return _runtimeResultFromJson(raw);
    } finally {
      await broker.close();
      if (ownedClient) effectiveClient.close();
    }
  }
}

Map<String, Object?> _limitsToJson(DrpyRuntimeLimits limits) => {
  'javascriptTimeoutMs': limits.javascriptTimeout.inMilliseconds,
  'networkTimeoutMs': limits.networkTimeout.inMilliseconds,
  'maxScriptBytes': limits.maxScriptBytes,
  'maxResponseBytes': limits.maxResponseBytes,
  'maxRedirects': limits.maxRedirects,
  'maxStorageEntries': limits.maxStorageEntries,
  'maxStorageValueBytes': limits.maxStorageValueBytes,
};

DrpyRuntimeResult _runtimeResultFromJson(Map<String, Object?> raw) {
  final candidates = <DrpyPlaybackCandidate>[];
  final rawCandidates = raw['candidates'];
  if (rawCandidates is List) {
    for (final value in rawCandidates.whereType<Map>()) {
      final candidate = DrpyPlaybackCandidate.fromJson(
        value.cast<String, dynamic>(),
      );
      if (candidate.url.trim().isNotEmpty) candidates.add(candidate);
    }
  }
  final logs = raw['logs'] is List
      ? (raw['logs'] as List)
            .map((value) => value.toString())
            .toList(growable: false)
      : const <String>[];
  final error = raw['ok'] == true
      ? null
      : (raw['error']?.toString().trim().isEmpty ?? true)
      ? 'drpy execution failed.'
      : raw['error'].toString();
  return DrpyRuntimeResult(candidates: candidates, error: error, logs: logs);
}

Map<String, Object?> _runDrpyWorker(Map<String, Object?> payload) {
  final limits = (payload['limits'] as Map).cast<String, Object?>();
  final storage = payload['storage'] is Map
      ? Map<String, Object?>.from(
          (payload['storage'] as Map).map(
            (key, value) => MapEntry(key.toString(), value),
          ),
        )
      : <String, Object?>{};
  final logs = <String>[];
  final brokerPort = payload['brokerPort'] as int;
  final brokerToken = payload['brokerToken'] as String;

  Map<String, Object?> brokerRequest(
    String url,
    Map<String, Object?> options, {
    bool includeBaseCredentials = true,
  }) {
    final optionHeaders = _stringMap(options['headers']);
    final request = <String, Object?>{
      'token': brokerToken,
      'url': url,
      'includeBaseCredentials': includeBaseCredentials,
      'options': {...options, 'headers': optionHeaders},
    };
    return _syncBrokerCall(
      brokerPort,
      request,
      maxBytes: (limits['maxResponseBytes'] as int) * 2 + 256 * 1024,
    );
  }

  String source = payload['ruleSource']?.toString() ?? '';
  try {
    if (source.trim().isEmpty) {
      final loaded = brokerRequest(payload['ruleUrl'].toString(), {
        'method': 'GET',
        'encoding': 'utf-8',
      }, includeBaseCredentials: false);
      source = loaded['content']?.toString() ?? '';
    }
    if (utf8.encode(source).length > (limits['maxScriptBytes'] as int)) {
      throw const FormatException('drpy script exceeds the configured limit.');
    }
    if (source.trim().isEmpty) {
      throw const FormatException('drpy script is empty.');
    }

    final js = JsRuntime(
      options: JsRuntimeOptions(
        memoryLimitBytes: 64 * 1024 * 1024,
        maxStackSizeBytes: 1024 * 1024,
        timeout: Duration(milliseconds: limits['javascriptTimeoutMs'] as int),
      ),
    );
    try {
      js.registerFunction('req', (arguments) {
        final url = arguments.isEmpty ? '' : arguments.first?.toString() ?? '';
        final options = arguments.length > 1 && arguments[1] is Map
            ? (arguments[1] as Map).cast<String, Object?>()
            : <String, Object?>{};
        return brokerRequest(url, options);
      });
      js.registerFunction('__drpyLocalGet', (arguments) {
        final key = arguments.isEmpty ? '' : arguments.first?.toString() ?? '';
        return storage[key];
      });
      js.registerFunction('__drpyLocalSet', (arguments) {
        final key = arguments.isEmpty ? '' : arguments.first?.toString() ?? '';
        if (key.isEmpty || key.length > 128) {
          throw const FormatException('invalid drpy local-storage key.');
        }
        if (!storage.containsKey(key) &&
            storage.length >= (limits['maxStorageEntries'] as int)) {
          throw const FormatException(
            'drpy local-storage entry limit reached.',
          );
        }
        final value = arguments.length > 1 ? arguments[1] : null;
        if (utf8.encode(jsonEncode(value)).length >
            (limits['maxStorageValueBytes'] as int)) {
          throw const FormatException('drpy local-storage value is too large.');
        }
        storage[key] = value;
        return true;
      });
      js.registerFunction('__drpyLocalDelete', (arguments) {
        final key = arguments.isEmpty ? '' : arguments.first?.toString() ?? '';
        storage.remove(key);
        return true;
      });
      js.registerFunction('__drpyLog', (arguments) {
        if (logs.length >= _maxRuntimeLogs) return null;
        final value = arguments.isEmpty
            ? ''
            : arguments.first?.toString() ?? '';
        logs.add(
          value.length <= _maxRuntimeLogLength
              ? value
              : value.substring(0, _maxRuntimeLogLength),
        );
        return null;
      });
      js.registerFunction('__drpyUrlJoin', (arguments) {
        final base = arguments.isEmpty ? '' : arguments.first?.toString() ?? '';
        final value = arguments.length > 1
            ? arguments[1]?.toString() ?? ''
            : '';
        final baseUri = Uri.tryParse(base);
        if (baseUri == null) return value;
        return baseUri.resolve(value).toString();
      });
      js.registerFunction('__drpyBase64Encode', (arguments) {
        final value = arguments.isEmpty
            ? ''
            : arguments.first?.toString() ?? '';
        return base64Encode(utf8.encode(value));
      });
      js.registerFunction('__drpyBase64Decode', (arguments) {
        final value = arguments.isEmpty
            ? ''
            : arguments.first?.toString() ?? '';
        return utf8.decode(base64Decode(value), allowMalformed: true);
      });
      js.registerFunction('__drpyMd5', (arguments) {
        final value = arguments.isEmpty
            ? ''
            : arguments.first?.toString() ?? '';
        return md5.convert(utf8.encode(value)).toString();
      });
      js.registerFunction('__drpyPdfa', (arguments) {
        final html = arguments.isEmpty ? '' : arguments.first?.toString() ?? '';
        final selector = arguments.length > 1
            ? arguments[1]?.toString() ?? ''
            : '';
        return jsonEncode(
          _drpyPdfa(
            html,
            selector,
            maxInputBytes: limits['maxResponseBytes'] as int,
          ),
        );
      });
      js.registerFunction('__drpyPdfh', (arguments) {
        final html = arguments.isEmpty ? '' : arguments.first?.toString() ?? '';
        final selector = arguments.length > 1
            ? arguments[1]?.toString() ?? ''
            : '';
        return _drpyPdfh(
          html,
          selector,
          maxInputBytes: limits['maxResponseBytes'] as int,
        );
      });
      js.execInitScript(_drpySubsetBootstrap);
      js.setGlobal('__drpyRuleSource', source);
      js.setGlobal('__drpyKeyword', payload['keyword']?.toString() ?? '');
      js.setGlobal('__drpyEpisodeNumber', payload['episodeNumber'] ?? 1);
      js.setGlobal(
        '__drpyEpisodeTitle',
        payload['episodeTitle']?.toString() ?? '',
      );
      final encoded = js.eval(
        'JSON.stringify(__drpyResolveSafe(__drpyRuleSource, '
        '__drpyKeyword, __drpyEpisodeNumber, __drpyEpisodeTitle))',
        filename: 'drpy_subset_execute.js',
      );
      final decoded = jsonDecode(encoded?.toString() ?? '{}');
      if (decoded is! Map) {
        throw const FormatException('drpy returned an invalid result.');
      }
      if (decoded['ok'] != true) {
        return <String, Object?>{
          'ok': false,
          'error': decoded['error']?.toString() ?? 'drpy execution failed.',
          'candidates': const <Object?>[],
          'logs': logs,
          'storage': storage,
        };
      }
      return <String, Object?>{
        'ok': true,
        'candidates': decoded['candidates'] is List
            ? decoded['candidates'] as List
            : const <Object?>[],
        'logs': logs,
        'storage': storage,
      };
    } finally {
      js.dispose();
    }
  } catch (error) {
    return <String, Object?>{
      'ok': false,
      'error': _friendlyRuntimeError(error),
      'candidates': const <Object?>[],
      'logs': logs,
      'storage': storage,
    };
  }
}

const _maxDrpySelectorLength = 2048;
const _maxDrpySelectorResults = 2048;

final _drpyPositionSelector = RegExp(
  r':(eq|lt|gt)\(\s*(-?\d+)\s*\)',
  caseSensitive: false,
);
final _drpyAttributeOption = RegExp(
  r'(?:url|src|href|-original|-src|-play|-url|style)$|'
  r'^(?:data-|url-|src-)',
  caseSensitive: false,
);

List<String> _drpyPdfa(
  String source,
  String parse, {
  required int maxInputBytes,
}) {
  if (!_drpyHtmlHelperInputAllowed(source, parse, maxInputBytes)) {
    return const [];
  }
  final document = html_parser.parse(source);
  for (final fallback in _drpySelectorFallbacks(parse)) {
    try {
      final selectors = _drpySelectorSegments(fallback);
      if (selectors.isEmpty) continue;
      final elements = _drpySelectElements(document, selectors);
      if (elements.isEmpty) continue;
      final result = <String>[];
      var outputBytes = 0;
      for (final element in elements.take(_maxDrpySelectorResults)) {
        final value = element.outerHtml;
        final valueBytes = utf8.encode(value).length;
        if (outputBytes + valueBytes > maxInputBytes) break;
        outputBytes += valueBytes;
        result.add(value);
      }
      if (result.isNotEmpty) return result;
    } catch (_) {
      // drpy selector helpers are intentionally tolerant. A malformed branch
      // may still be followed by a compatible `||` fallback.
    }
  }
  return const [];
}

String _drpyPdfh(String source, String parse, {required int maxInputBytes}) {
  if (!_drpyHtmlHelperInputAllowed(source, parse, maxInputBytes)) return '';
  final document = html_parser.parse(source);
  for (final fallback in _drpySelectorFallbacks(parse)) {
    try {
      final parsed = _drpyPdfhSelector(fallback);
      final elements = parsed.selectors.isEmpty
          ? [
              if (document.body != null) document.body!,
              if (document.body == null && document.documentElement != null)
                document.documentElement!,
            ]
          : _drpySelectElements(document, parsed.selectors);
      if (elements.isEmpty) continue;
      final value = _drpyElementValue(elements.first, parsed.option);
      if (value.isNotEmpty) return value;
    } catch (_) {
      // Keep trying explicit fallback selectors instead of failing the rule.
    }
  }
  return '';
}

bool _drpyHtmlHelperInputAllowed(
  String source,
  String parse,
  int maxInputBytes,
) {
  final selector = parse.trim();
  if (source.isEmpty || selector.isEmpty) return false;
  if (selector.length > _maxDrpySelectorLength) return false;
  return utf8.encode(source).length <= maxInputBytes;
}

List<String> _drpySelectorFallbacks(String parse) {
  final raw = parse
      .split('||')
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toList(growable: false);
  if (raw.length < 2) return raw;
  final first = raw.first;
  final separator = first.lastIndexOf('&&');
  if (separator < 0) return raw;
  final prefix = first.substring(0, separator + 2);
  return [
    first,
    for (final fallback in raw.skip(1))
      fallback.contains('&&') ? fallback : '$prefix$fallback',
  ];
}

List<String> _drpySelectorSegments(String parse) => parse
    .split('&&')
    .map((value) => value.trim())
    .where((value) => value.isNotEmpty)
    .toList(growable: false);

_DrpyPdfhSelector _drpyPdfhSelector(String parse) {
  final parts = _drpySelectorSegments(parse).toList(growable: true);
  if (parts.isEmpty) {
    return const _DrpyPdfhSelector([], _DrpyHtmlOption.text);
  }
  final last = parts.last;
  final option = _drpyHtmlOption(last);
  if (option != null) {
    parts.removeLast();
    return _DrpyPdfhSelector(parts, option);
  }
  return _DrpyPdfhSelector(parts, _DrpyHtmlOption.text);
}

_DrpyHtmlOption? _drpyHtmlOption(String value) {
  final normalized = value.trim();
  switch (normalized.toLowerCase()) {
    case 'text':
      return _DrpyHtmlOption.text;
    case 'html':
      return _DrpyHtmlOption.html;
    case 'outerhtml':
      return _DrpyHtmlOption.outerHtml;
  }
  final attribute = normalized.startsWith('@')
      ? normalized.substring(1)
      : normalized;
  const commonAttributes = {
    'alt',
    'title',
    'content',
    'value',
    'poster',
    'id',
    'class',
    'name',
    'rel',
    'action',
  };
  if (_drpyAttributeOption.hasMatch(attribute) ||
      commonAttributes.contains(attribute.toLowerCase())) {
    return _DrpyHtmlOption.attribute(attribute);
  }
  return null;
}

List<html_dom.Element> _drpySelectElements(
  html_dom.Document document,
  List<String> selectors,
) {
  var current = <html_dom.Element>[];
  for (var index = 0; index < selectors.length; index++) {
    final parsed = _drpyCssSelector(selectors[index]);
    if (parsed.selector.isEmpty) return const [];
    final matches = index == 0
        ? document.querySelectorAll(parsed.selector)
        : [
            for (final element in current)
              ...element.querySelectorAll(parsed.selector),
          ];
    current = _drpyApplyPositionFilters(matches, parsed.filters);
    if (current.isEmpty) return const [];
  }
  return current;
}

_DrpyCssSelector _drpyCssSelector(String raw) {
  final filters = <_DrpyPositionFilter>[];
  for (final match in _drpyPositionSelector.allMatches(raw)) {
    final index = int.tryParse(match.group(2) ?? '');
    if (index == null) continue;
    filters.add(
      _DrpyPositionFilter((match.group(1) ?? '').toLowerCase(), index),
    );
  }
  final selector = raw.replaceAll(_drpyPositionSelector, '').trim();
  return _DrpyCssSelector(selector, filters);
}

List<html_dom.Element> _drpyApplyPositionFilters(
  List<html_dom.Element> elements,
  List<_DrpyPositionFilter> filters,
) {
  var current = elements;
  for (final filter in filters) {
    final index = filter.index < 0
        ? current.length + filter.index
        : filter.index;
    switch (filter.operation) {
      case 'eq':
        if (index < 0 || index >= current.length) return const [];
        current = [current[index]];
        break;
      case 'lt':
        final end = index.clamp(0, current.length).toInt();
        current = current.sublist(0, end);
        break;
      case 'gt':
        final start = (index + 1).clamp(0, current.length).toInt();
        current = current.sublist(start);
        break;
    }
    if (current.isEmpty) return const [];
  }
  return current;
}

String _drpyElementValue(html_dom.Element element, _DrpyHtmlOption option) {
  switch (option.kind) {
    case _DrpyHtmlOptionKind.text:
      return element.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    case _DrpyHtmlOptionKind.html:
      return element.innerHtml.trim();
    case _DrpyHtmlOptionKind.outerHtml:
      return element.outerHtml.trim();
    case _DrpyHtmlOptionKind.attribute:
      return (element.attributes[option.attribute.toLowerCase()] ?? '').trim();
  }
}

enum _DrpyHtmlOptionKind { text, html, outerHtml, attribute }

class _DrpyHtmlOption {
  const _DrpyHtmlOption._(this.kind, [this.attribute = '']);

  static const text = _DrpyHtmlOption._(_DrpyHtmlOptionKind.text);
  static const html = _DrpyHtmlOption._(_DrpyHtmlOptionKind.html);
  static const outerHtml = _DrpyHtmlOption._(_DrpyHtmlOptionKind.outerHtml);

  factory _DrpyHtmlOption.attribute(String name) =>
      _DrpyHtmlOption._(_DrpyHtmlOptionKind.attribute, name);

  final _DrpyHtmlOptionKind kind;
  final String attribute;
}

class _DrpyPdfhSelector {
  const _DrpyPdfhSelector(this.selectors, this.option);

  final List<String> selectors;
  final _DrpyHtmlOption option;
}

class _DrpyCssSelector {
  const _DrpyCssSelector(this.selector, this.filters);

  final String selector;
  final List<_DrpyPositionFilter> filters;
}

class _DrpyPositionFilter {
  const _DrpyPositionFilter(this.operation, this.index);

  final String operation;
  final int index;
}

Map<String, String> _stringMap(Object? value) {
  if (value is! Map) return const {};
  final result = <String, String>{};
  for (final entry in value.entries) {
    final key = entry.key.toString().trim();
    final item = entry.value?.toString() ?? '';
    if (key.isNotEmpty && item.isNotEmpty) result[key] = item;
  }
  return result;
}

String _friendlyRuntimeError(Object error) {
  final text = error.toString().replaceFirst(RegExp(r'^\w+Exception:\s*'), '');
  if (text.contains('DRPY_SUBSET:')) {
    return text.substring(text.indexOf('DRPY_SUBSET:') + 'DRPY_SUBSET:'.length);
  }
  return text.length <= 500 ? text : text.substring(0, 500);
}

Map<String, Object?> _syncBrokerCall(
  int port,
  Map<String, Object?> request, {
  required int maxBytes,
}) {
  final socket = RawSynchronousSocket.connectSync(_loopbackHost, port);
  try {
    socket.writeFromSync([...utf8.encode(jsonEncode(request)), 10]);
    final bytes = BytesBuilder(copy: false);
    while (true) {
      final chunk = socket.readSync(64 * 1024);
      if (chunk == null || chunk.isEmpty) {
        throw const SocketException('drpy HTTP broker closed unexpectedly.');
      }
      final newline = chunk.indexOf(10);
      bytes.add(newline < 0 ? chunk : chunk.sublist(0, newline));
      if (bytes.length > maxBytes) {
        throw const FormatException('drpy HTTP broker response is too large.');
      }
      if (newline >= 0) break;
    }
    final decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
    if (decoded is! Map) {
      throw const FormatException('drpy HTTP broker returned invalid data.');
    }
    final result = decoded.cast<String, Object?>();
    if (result['ok'] != true) {
      throw HttpException(
        result['error']?.toString() ?? 'drpy request failed.',
      );
    }
    return result;
  } finally {
    socket.closeSync();
  }
}

class _DrpyHttpBroker {
  _DrpyHttpBroker._({
    required this.server,
    required this.client,
    required this.limits,
    required this.token,
    required Map<String, String> baseHeaders,
    required String credentialOrigin,
    required this.addressLookup,
  }) : _baseHeaders = _validatedHeaders(baseHeaders),
       _credentialOrigin = _normalizedHttpOrigin(
         Uri.tryParse(credentialOrigin.trim()),
       );

  final ServerSocket server;
  final http.Client client;
  final DrpyRuntimeLimits limits;
  final String token;
  final Map<String, String> _baseHeaders;
  final String? _credentialOrigin;
  final DrpyAddressLookup addressLookup;
  late final StreamSubscription<Socket> _subscription;

  int get port => server.port;

  static Future<_DrpyHttpBroker> start({
    required http.Client client,
    required DrpyRuntimeLimits limits,
    required Map<String, String> baseHeaders,
    required String credentialOrigin,
    required DrpyAddressLookup addressLookup,
  }) async {
    final server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      shared: false,
    );
    final random = Random.secure();
    final token = base64Url.encode(
      List<int>.generate(24, (_) => random.nextInt(256)),
    );
    final broker = _DrpyHttpBroker._(
      server: server,
      client: client,
      limits: limits,
      token: token,
      baseHeaders: baseHeaders,
      credentialOrigin: credentialOrigin,
      addressLookup: addressLookup,
    );
    broker._subscription = server.listen(
      (socket) => unawaited(broker._handle(socket)),
    );
    return broker;
  }

  Future<void> _handle(Socket socket) async {
    try {
      final line = await socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(limits.networkTimeout);
      if (utf8.encode(line).length > _maxBrokerRequestBytes) {
        throw const FormatException('drpy broker request is too large.');
      }
      final decoded = jsonDecode(line);
      if (decoded is! Map || decoded['token'] != token) {
        throw const FormatException('invalid drpy broker request.');
      }
      final url = decoded['url']?.toString() ?? '';
      final options = decoded['options'] is Map
          ? (decoded['options'] as Map).cast<String, Object?>()
          : <String, Object?>{};
      final response = await _send(
        url,
        options,
        includeBaseCredentials: decoded['includeBaseCredentials'] == true,
      );
      socket.add([
        ...utf8.encode(jsonEncode({'ok': true, ...response})),
        10,
      ]);
    } catch (error) {
      socket.add([
        ...utf8.encode(
          jsonEncode({'ok': false, 'error': _friendlyRuntimeError(error)}),
        ),
        10,
      ]);
    } finally {
      try {
        await socket.flush();
      } catch (_) {
        // The worker may already have timed out and closed its loopback socket.
      }
      await socket.close();
    }
  }

  Future<Map<String, Object?>> _send(
    String rawUrl,
    Map<String, Object?> options, {
    required bool includeBaseCredentials,
  }) async {
    final parsedUri = Uri.tryParse(rawUrl.trim());
    if (parsedUri == null) {
      throw const FormatException('invalid drpy request URL.');
    }
    var uri = parsedUri;
    var method = options['method']?.toString().toUpperCase() ?? 'GET';
    if (method.isEmpty) method = 'GET';
    final optionHeaders = _validatedHeaders(_stringMap(options['headers']));
    var headers = _mergeHeadersCaseInsensitive(
      _baseHeadersFor(uri, includeCredentials: includeBaseCredentials),
      optionHeaders,
    );
    var body = _requestBody(options, headers);
    final followRedirects =
        options['redirect'] != 0 && options['redirect'] != false;

    for (var redirect = 0; ; redirect++) {
      await _ensurePublicHttpUri(uri, addressLookup);
      final request = http.Request(method, uri)
        ..followRedirects = false
        ..headers.addAll(headers);
      if (body.isNotEmpty && method != 'GET' && method != 'HEAD') {
        request.bodyBytes = body;
      }
      final streamed = await client
          .send(request)
          .timeout(limits.networkTimeout);
      if (followRedirects &&
          _isRedirect(streamed.statusCode) &&
          streamed.headers['location'] != null) {
        if (redirect >= limits.maxRedirects) {
          throw const HttpException('drpy redirect limit reached.');
        }
        final next = uri.resolve(streamed.headers['location']!);
        if (!_sameOrigin(uri, next)) {
          headers = _withoutCredentialHeaders(headers);
        }
        if (streamed.statusCode == 303 ||
            ((streamed.statusCode == 301 || streamed.statusCode == 302) &&
                method == 'POST')) {
          method = 'GET';
          body = const [];
        }
        final redirectSubscription = streamed.stream.listen(null);
        await redirectSubscription.cancel();
        uri = next;
        continue;
      }

      final bytes = BytesBuilder(copy: false);
      await for (final chunk in streamed.stream.timeout(
        limits.networkTimeout,
      )) {
        if (bytes.length + chunk.length > limits.maxResponseBytes) {
          throw const HttpException(
            'drpy response exceeds the configured limit.',
          );
        }
        bytes.add(chunk);
      }
      final data = bytes.takeBytes();
      final bufferMode = int.tryParse(options['buffer']?.toString() ?? '') ?? 0;
      final content = bufferMode > 0
          ? base64Encode(data)
          : _decodeResponse(data, options, streamed.headers);
      return <String, Object?>{
        'content': content,
        'headers': streamed.headers,
        'statusCode': streamed.statusCode,
        'code': streamed.statusCode,
        if (bufferMode > 0) 'base64': true,
      };
    }
  }

  Map<String, String> _baseHeadersFor(
    Uri target, {
    required bool includeCredentials,
  }) {
    final targetOrigin = _normalizedHttpOrigin(target);
    final allowCredentials =
        includeCredentials &&
        _credentialOrigin != null &&
        targetOrigin == _credentialOrigin;
    return {
      for (final entry in _baseHeaders.entries)
        if (!_credentialHeaderNames.contains(entry.key.toLowerCase()) ||
            allowCredentials)
          entry.key: entry.value,
    };
  }

  Future<void> close() async {
    await _subscription.cancel();
    await server.close();
  }
}

const _credentialHeaderNames = <String>{
  'authorization',
  'proxy-authorization',
  'cookie',
  'cookie2',
  'api-key',
  'x-api-key',
  'access-token',
  'x-access-token',
  'x-auth-token',
  'x-appid',
  'x-timestamp',
  'x-signature',
};

Map<String, String> _withoutCredentialHeaders(Map<String, String> headers) => {
  for (final entry in headers.entries)
    if (!_credentialHeaderNames.contains(entry.key.toLowerCase()))
      entry.key: entry.value,
};

Map<String, String> _mergeHeadersCaseInsensitive(
  Map<String, String> base,
  Map<String, String> overrides,
) {
  final result = Map<String, String>.from(base);
  for (final entry in overrides.entries) {
    final normalized = entry.key.toLowerCase();
    result.removeWhere((key, _) => key.toLowerCase() == normalized);
    result[entry.key] = entry.value;
  }
  return result;
}

String? _normalizedHttpOrigin(Uri? uri) {
  if (uri == null) return null;
  final scheme = uri.scheme.toLowerCase();
  if (!const {'http', 'https'}.contains(scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  final port = uri.hasPort ? uri.port : (scheme == 'https' ? 443 : 80);
  return '$scheme://${uri.host.toLowerCase()}:$port';
}

Map<String, String> _validatedHeaders(Map<String, String> headers) {
  final result = <String, String>{};
  for (final entry in headers.entries) {
    final name = entry.key.trim();
    final value = entry.value.trim();
    if (name.isEmpty || value.isEmpty || name.contains(RegExp(r'[\r\n:]'))) {
      continue;
    }
    if (value.contains(RegExp(r'[\r\n]'))) continue;
    final normalized = name.toLowerCase();
    if (normalized == 'host' || normalized == 'content-length') continue;
    result[name] = value;
  }
  return result;
}

List<int> _requestBody(
  Map<String, Object?> options,
  Map<String, String> headers,
) {
  final body = options['body'];
  final data = options['data'];
  if (body is String) return utf8.encode(body);
  final value = data ?? body;
  if (value is Map) {
    final postType = options['postType']?.toString().toLowerCase() ?? '';
    if (postType == 'json') {
      headers.putIfAbsent(
        'Content-Type',
        () => 'application/json; charset=utf-8',
      );
      return utf8.encode(jsonEncode(value));
    }
    headers.putIfAbsent(
      'Content-Type',
      () => 'application/x-www-form-urlencoded; charset=utf-8',
    );
    final encoded = value.entries
        .map(
          (entry) =>
              '${Uri.encodeQueryComponent(entry.key.toString())}='
              '${Uri.encodeQueryComponent(entry.value?.toString() ?? '')}',
        )
        .join('&');
    return utf8.encode(encoded);
  }
  return const [];
}

String _decodeResponse(
  List<int> bytes,
  Map<String, Object?> options,
  Map<String, String> headers,
) {
  final explicit = options['encoding']?.toString().trim() ?? '';
  final contentType = headers['content-type'] ?? '';
  final match = RegExp(
    r'''charset\s*=\s*["']?([^;"'\s]+)''',
    caseSensitive: false,
  ).firstMatch(contentType);
  final name = explicit.isNotEmpty ? explicit : match?.group(1) ?? 'utf-8';
  final normalized = name.toLowerCase().replaceAll('_', '-');
  if (normalized == 'utf-8' || normalized == 'utf8') {
    return utf8.decode(bytes, allowMalformed: true);
  }
  if (const {
    'gbk',
    'gb2312',
    'gb-2312',
    'cp936',
    'cp-936',
    'ms936',
    'windows-936',
    'csgbk',
    'gb18030',
    'csgb18030',
  }.contains(normalized)) {
    return const GbkCodec(allowMalformed: true).decode(bytes);
  }
  final encoding = Charset.getByName(name, utf8) ?? utf8;
  try {
    return encoding.decode(bytes);
  } on FormatException {
    return utf8.decode(bytes, allowMalformed: true);
  }
}

bool _isRedirect(int status) =>
    status == 301 ||
    status == 302 ||
    status == 303 ||
    status == 307 ||
    status == 308;

bool _sameOrigin(Uri first, Uri second) =>
    first.scheme.toLowerCase() == second.scheme.toLowerCase() &&
    first.host.toLowerCase() == second.host.toLowerCase() &&
    first.port == second.port;

Future<void> _ensurePublicHttpUri(
  Uri uri,
  DrpyAddressLookup addressLookup,
) async {
  await _publicAddressesForUri(uri, addressLookup);
}

Future<List<InternetAddress>> _publicAddressesForUri(
  Uri uri,
  DrpyAddressLookup addressLookup,
) async {
  final scheme = uri.scheme.toLowerCase();
  if (!const {'http', 'https'}.contains(scheme) || uri.host.isEmpty) {
    throw const FormatException(
      'drpy requests only allow public HTTP(S) URLs.',
    );
  }
  if (uri.userInfo.isNotEmpty) {
    throw const FormatException(
      'drpy request URLs cannot contain credentials.',
    );
  }
  final host = uri.host.toLowerCase();
  if (host == 'localhost' || host.endsWith('.localhost')) {
    throw const FormatException('drpy private-network request blocked.');
  }
  final literal = InternetAddress.tryParse(host);
  final addresses = literal == null
      ? await addressLookup(host).timeout(const Duration(seconds: 3))
      : [literal];
  if (addresses.isEmpty || addresses.any(_isBlockedAddress)) {
    throw const FormatException('drpy private-network request blocked.');
  }
  return List<InternetAddress>.unmodifiable(addresses);
}

bool _isBlockedAddress(InternetAddress address) {
  if (address.isLoopback || address.isLinkLocal || address.isMulticast) {
    return true;
  }
  final bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv4 && bytes.length == 4) {
    return _isBlockedIpv4Bytes(bytes);
  }
  if (address.type == InternetAddressType.IPv6 && bytes.length == 16) {
    final ipv4Mapped =
        bytes.take(10).every((value) => value == 0) &&
        bytes[10] == 0xff &&
        bytes[11] == 0xff;
    if (ipv4Mapped) return _isBlockedIpv4Bytes(bytes.sublist(12));
    final allZero = bytes.every((value) => value == 0);
    final loopback =
        bytes.take(15).every((value) => value == 0) && bytes.last == 1;
    final uniqueLocal = (bytes[0] & 0xfe) == 0xfc;
    final linkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80;
    return allZero || loopback || uniqueLocal || linkLocal || bytes[0] == 0xff;
  }
  return true;
}

bool _isBlockedIpv4Bytes(List<int> bytes) {
  if (bytes.length != 4) return true;
  final first = bytes[0];
  final second = bytes[1];
  final third = bytes[2];
  return first == 0 ||
      first == 10 ||
      first == 127 ||
      (first == 100 && second >= 64 && second <= 127) ||
      (first == 169 && second == 254) ||
      (first == 172 && second >= 16 && second <= 31) ||
      (first == 192 &&
          ((second == 0 && third == 0) ||
              (second == 0 && third == 2) ||
              (second == 88 && third == 99) ||
              second == 168)) ||
      (first == 198 &&
          (second == 18 || second == 19 || (second == 51 && third == 100))) ||
      (first == 203 && second == 0 && third == 113) ||
      first >= 224;
}

// Keep the bootstrap ASCII-only. Some Windows shells can transcode Chinese
// literals while patches are applied; property names use JavaScript escapes so
// imported UTF-8 rule scripts still see their original names.
const _drpySubsetBootstrap = r'''
globalThis.MOBILE_UA = 'Mozilla/5.0 (Linux; Android 11; Mobile) AppleWebKit/537.36 Chrome/124 Mobile Safari/537.36';
globalThis.PC_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124 Safari/537.36';
globalThis.IOS_UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148';
globalThis.UA = 'Mozilla/5.0';
globalThis.VODS = [];
globalThis.VOD = {};
globalThis.TABS = [];
globalThis.LISTS = [];
globalThis.input = '';
globalThis.KEY = '';
globalThis.MY_URL = '';
globalThis.MY_PAGE = 1;
globalThis.MY_FLAG = '';
globalThis.HOST = '';
globalThis.rule = {};
globalThis.fetch_params = {headers: {}};
globalThis.rule_fetch_params = {headers: {}};

globalThis.console = {
  log: (...args) => __drpyLog(args.map((value) => String(value)).join(' ')),
  warn: (...args) => __drpyLog(args.map((value) => String(value)).join(' ')),
  error: (...args) => __drpyLog(args.map((value) => String(value)).join(' ')),
};
globalThis.print = (...args) => console.log(...args);
globalThis.log = (...args) => console.log(...args);
globalThis.local = {
  get: (_scope, key) => __drpyLocalGet(String(key)),
  set: (_scope, key, value) => __drpyLocalSet(String(key), value),
  delete: (_scope, key) => __drpyLocalDelete(String(key)),
};
globalThis.setItem = (key, value) => __drpyLocalSet(String(key), value);
globalThis.getItem = (key, fallback) => {
  const value = __drpyLocalGet(String(key));
  return value === null || value === undefined ? fallback : value;
};
globalThis.clearItem = (key) => __drpyLocalDelete(String(key));
globalThis.urljoin = (base, value) => __drpyUrlJoin(String(base || ''), String(value || ''));
globalThis.urljoin2 = globalThis.urljoin;
globalThis.buildUrl = (base, params) => {
  const pairs = Object.entries(params || {}).map(([key, value]) =>
    `${encodeURIComponent(key)}=${encodeURIComponent(value === null || value === undefined ? '' : value)}`
  );
  if (!pairs.length) return String(base || '');
  const raw = String(base || '');
  return `${raw}${raw.includes('?') ? '&' : '?'}${pairs.join('&')}`;
};
globalThis.urlDeal = (value) => {
  const raw = String(value || '');
  if (/^https?:\/\//i.test(raw)) return raw;
  if (raw.startsWith('//')) return `https:${raw}`;
  return urljoin(HOST, raw);
};
globalThis.base64Encode = (value) => __drpyBase64Encode(String(value || ''));
globalThis.base64Decode = (value) => __drpyBase64Decode(String(value || ''));
globalThis.md5 = (value) => __drpyMd5(String(value || ''));
globalThis.pdfa = (html, parse) => {
  const encoded = __drpyCheckedNative(
    __drpyPdfa(String(html || ''), String(parse || '')),
  );
  try {
    const result = JSON.parse(String(encoded || '[]'));
    return Array.isArray(result) ? result : [];
  } catch (_) {
    return [];
  }
};
globalThis.pdfh = (html, parse) => {
  let value = String(__drpyCheckedNative(
    __drpyPdfh(String(html || ''), String(parse || '')),
  ) || '');
  if (/style\s*(?:\|\|.*)?$/i.test(String(parse || '')) && /url\(/i.test(value)) {
    const match = value.match(/url\(\s*(['"]?)(.*?)\1\s*\)/i);
    if (match) value = match[2];
  }
  return value;
};
globalThis.pd = (html, parse, base) => {
  const value = pdfh(html, parse);
  if (!value || /^(?:ftp|magnet|thunder|ws):/i.test(value)) return value;
  if (/^https?:\/\//i.test(value)) return value.slice(value.search(/https?:\/\//i));
  return urljoin(base || MY_URL || input || HOST, value);
};
globalThis.jsp = {
  pdfa: globalThis.pdfa,
  pdfh: globalThis.pdfh,
  pd: globalThis.pd,
};
globalThis.$js = {
  toString(fn) {
    const source = String(fn);
    const start = source.indexOf('{');
    const end = source.lastIndexOf('}');
    return start >= 0 && end > start
      ? `js:${source.slice(start + 1, end)}`
      : `js:${source}`;
  },
};

function __drpyNormalizeHeaders(headers) {
  const result = {};
  for (const [name, rawValue] of Object.entries(headers || {})) {
    const value = String(rawValue || '');
    result[name] = value === 'MOBILE_UA'
      ? MOBILE_UA
      : value === 'PC_UA'
      ? PC_UA
      : value === 'IOS_UA'
      ? IOS_UA
      : value === 'UA'
      ? UA
      : value;
  }
  return result;
}

function __drpyCheckedNative(value) {
  if (value && typeof value === 'object' &&
      (value['$jsf.type'] === 'DartError' ||
       value.name === 'DartError' ||
       (value.message && value.content === undefined))) {
    throw new Error(`DRPY_NATIVE:${String(value.message || 'Dart callback failed.')}`);
  }
  return value;
}

function request(url, options) {
  const next = options && typeof options === 'object' ? {...options} : {};
  next.headers = __drpyNormalizeHeaders({
    ...((rule && rule.headers) || {}),
    ...(next.headers || {}),
  });
  if (!next.encoding && rule && (rule.encoding || rule['\u7f16\u7801'])) {
    next.encoding = rule.encoding || rule['\u7f16\u7801'];
  }
  const response = __drpyCheckedNative(req(String(url || ''), next));
  if (!response || typeof response !== 'object' || response.content === undefined) {
    __drpyLog(`Unexpected req result: ${JSON.stringify(response)}`);
  }
  if (next.withHeaders) {
    return JSON.stringify({...response.headers, body: response.content});
  }
  return response.content || '';
}
globalThis.request = request;
globalThis.fetch = request;
globalThis.post = (url, options) => request(url, {...(options || {}), method: 'POST'});
globalThis.reqCookie = (url, options) => {
  const response = __drpyCheckedNative(
    req(String(url || ''), {...(options || {}), withHeaders: true}),
  );
  const headers = response.headers || {};
  const key = Object.keys(headers).find((name) => name.toLowerCase() === 'set-cookie');
  return {
    cookie: key ? String(headers[key]).split(';')[0] : '',
    html: response.content || '',
  };
};

function setResult(items) {
  if (!Array.isArray(items)) return [];
  globalThis.VODS = items.map((item) => ({
    vod_id: item.vod_id || item.url || '',
    vod_name: item.vod_name || item.title || '',
    vod_pic: item.vod_pic || item.pic_url || item.img || '',
    vod_remarks: item.vod_remarks || item.desc || '',
  }));
  return globalThis.VODS;
}
globalThis.setResult = setResult;
globalThis.setResult2 = (value) => {
  globalThis.VODS = value && Array.isArray(value.list) ? value.list : [];
  return globalThis.VODS;
};

function __drpyUnsupported(message) {
  throw new Error(`DRPY_SUBSET:${message}`);
}

function __drpyIsProcedural(value) {
  return typeof value === 'function' ||
    (typeof value === 'string' && value.trim().startsWith('js:'));
}

function __drpyMissingHelpers(value) {
  const code = typeof value === 'function'
    ? String(value)
    : String(value || '').replace(/^\s*js:/, '');
  const checks = [
    ['CryptoJS', /\bCryptoJS\b|\bgetCryptoJS\s*\(/],
    ['pq', /\bpq\s*[.(]/],
    ['cheerio', /\bcheerio\b/],
    ['JSEncrypt', /\bJSEncrypt\b/],
  ];
  return checks
    .filter((entry) => entry[1].test(code))
    .map((entry) => entry[0]);
}

function __drpyRun(value, args) {
  const missing = __drpyMissingHelpers(value);
  if (missing.length) {
    __drpyUnsupported(`Unsupported helper APIs: ${missing.join(', ')}`);
  }
  if (typeof value === 'function') return value.apply(rule, args || []);
  if (typeof value === 'string' && value.trim().startsWith('js:')) {
    return (0, eval)(value.trim().slice(3));
  }
  return value;
}

function __drpyObject(value) {
  if (typeof value === 'string') {
    try { return JSON.parse(value); } catch (_) { return value; }
  }
  return value;
}

function __drpyList(value, fallback) {
  const parsed = __drpyObject(value);
  if (Array.isArray(parsed)) return parsed;
  if (parsed && Array.isArray(parsed.list)) return parsed.list;
  return Array.isArray(fallback) ? fallback : [];
}

const __DRPY_MAX_SEARCH_ITEMS = 100;
const __DRPY_MAX_PLAY_LINES = 8;
const __DRPY_MAX_EPISODES = 500;

function __drpyBoundedString(value, maxLength) {
  if (value === null || value === undefined) return '';
  const text = typeof value === 'string' || typeof value === 'number' ||
      typeof value === 'boolean' ? String(value).trim() : '';
  return text.length <= maxLength ? text : text.slice(0, maxLength);
}

function __drpyDeclarativeParts(value) {
  if (typeof value !== 'string') return [];
  const parts = value.split(';').map((part) => part.trim());
  return parts.length === 5 || parts.length === 6 ? parts : [];
}

function __drpyJsonPath(root, rawPath) {
  let path = String(rawPath || '').trim();
  if (!path || path === '$') return root;
  if (path.startsWith('$.')) path = path.slice(2);
  else if (path.startsWith('.')) path = path.slice(1);
  path = path.replace(/\[(\d+)\]/g, '.$1');
  if (!path || /[\[\]]/.test(path)) return undefined;
  const parts = path.split('.');
  let value = root;
  for (const part of parts) {
    if (!part || !/^[A-Za-z0-9_$\-\u4e00-\u9fff]+$/.test(part) ||
        part === '__proto__' || part === 'prototype' || part === 'constructor') {
      return undefined;
    }
    if (Array.isArray(value)) {
      if (!/^\d+$/.test(part)) return undefined;
      const index = Number(part);
      if (!Number.isSafeInteger(index) || index < 0 || index >= value.length) {
        return undefined;
      }
      value = value[index];
      continue;
    }
    if (!value || typeof value !== 'object' ||
        !Object.prototype.hasOwnProperty.call(value, part)) {
      return undefined;
    }
    value = value[part];
  }
  return value;
}

function __drpyHttpValue(value, base) {
  const raw = __drpyBoundedString(value, 4096);
  if (!raw) return '';
  const resolved = /^https?:\/\//i.test(raw) ? raw : urljoin(base || HOST, raw);
  return /^https?:\/\//i.test(resolved) ? resolved : '';
}

function __drpyInheritedSearchRule(searchRule) {
  const firstRule = rule['\u4e00\u7ea7'] !== undefined
    ? rule['\u4e00\u7ea7']
    : rule.first;
  if (typeof searchRule === 'string' && searchRule.trim() === '*') {
    return firstRule;
  }
  if (typeof searchRule !== 'string' || typeof firstRule !== 'string' ||
      !searchRule.split(';').some((part) => part.trim() === '*')) {
    return searchRule;
  }
  const searchParts = searchRule.split(';');
  const firstParts = firstRule.split(';');
  return searchParts.map((part, index) =>
    part.trim() === '*' ? String(firstParts[index] || '').trim() : part.trim()
  ).join(';');
}

function __drpyDeclarativeSearch(searchRule) {
  const parts = __drpyDeclarativeParts(searchRule);
  if (!parts.length) {
    __drpyUnsupported('Declarative search must have 5 or 6 fields.');
  }
  if (!globalThis.input || !/^https?:\/\//i.test(globalThis.input)) {
    __drpyUnsupported('Declarative search has no HTTP search URL.');
  }
  const body = request(globalThis.input);
  const items = [];
  if (/^json:/i.test(parts[0])) {
    let decoded;
    try {
      decoded = JSON.parse(String(body || ''));
    } catch (_) {
      __drpyUnsupported('Declarative JSON search returned invalid JSON.');
    }
    const list = __drpyJsonPath(decoded, parts[0].slice(5));
    if (!Array.isArray(list)) return [];
    for (const item of list.slice(0, __DRPY_MAX_SEARCH_ITEMS)) {
      if (!item || typeof item !== 'object') continue;
      const title = __drpyBoundedString(__drpyJsonPath(item, parts[1]), 512);
      const id = __drpyBoundedString(__drpyJsonPath(item, parts[4]), 4096);
      if (!title || !id) continue;
      items.push({
        vod_id: id,
        vod_name: title,
        vod_pic: __drpyBoundedString(__drpyJsonPath(item, parts[2]), 4096),
        vod_remarks: __drpyBoundedString(__drpyJsonPath(item, parts[3]), 1024),
      });
    }
    return items;
  }

  const rows = pdfa(body, parts[0]).slice(0, __DRPY_MAX_SEARCH_ITEMS);
  for (const row of rows) {
    const title = __drpyBoundedString(pdfh(row, parts[1]), 512);
    const id = __drpyHttpValue(pd(row, parts[4], globalThis.input), globalThis.input);
    if (!title || !id) continue;
    items.push({
      vod_id: id,
      vod_name: title,
      vod_pic: parts[2]
        ? __drpyHttpValue(pd(row, parts[2], globalThis.input), globalThis.input)
        : '',
      vod_remarks: parts[3]
        ? __drpyBoundedString(pdfh(row, parts[3]), 1024)
        : '',
    });
  }
  return items;
}

function __drpyLoad(source) {
  globalThis.rule = {};
  const normalized = String(source || '').replace(
    /(^|[\r\n;])\s*(?:var|let|const)\s+rule\s*=/,
    '$1globalThis.rule =',
  );
  (0, eval)(normalized);
  if (!globalThis.rule || typeof globalThis.rule !== 'object') {
    __drpyUnsupported('The script did not export a rule object.');
  }
  globalThis.HOST = String(rule.host || '').replace(/\/$/, '');
  const ruleHeaders = __drpyNormalizeHeaders(rule.headers || {});
  globalThis.fetch_params = {headers: {...ruleHeaders}};
  globalThis.rule_fetch_params = {headers: {...ruleHeaders}};
  const preprocess = rule['\u9884\u5904\u7406'];
  if (__drpyIsProcedural(preprocess)) __drpyRun(preprocess, []);
}

function __drpySearchInput(keyword, page) {
  let value = String(rule.searchUrl || rule.search_url || '');
  if (!value) return keyword;
  value = value.split('[')[0]
    .replace(/\*\*/g, encodeURIComponent(keyword))
    .replace(/fykey/g, encodeURIComponent(keyword))
    .replace(/fypage/g, String(page));
  return /^https?:\/\//i.test(value) ? value : urljoin(HOST, value);
}

function __drpySearch(keyword) {
  let searchRule = rule['\u641c\u7d22'] !== undefined
    ? rule['\u641c\u7d22']
    : rule.search;
  searchRule = __drpyInheritedSearchRule(searchRule);
  globalThis.VODS = [];
  globalThis.KEY = keyword;
  globalThis.MY_PAGE = 1;
  globalThis.input = __drpySearchInput(keyword, 1);
  globalThis.MY_URL = globalThis.input;
  if (!__drpyIsProcedural(searchRule)) {
    return __drpyDeclarativeSearch(searchRule);
  }
  const returned = __drpyRun(searchRule, [keyword, false, 1]);
  return __drpyList(returned, globalThis.VODS);
}

function __drpyNormalizedTitle(value) {
  return String(value || '').toLowerCase().replace(
    /[\s\-_:\uFF1A\uFF0C\u3002\uFF01\uFF1F\u00B7]/g,
    '',
  );
}

function __drpyPickSearch(items, keyword) {
  if (!items.length) return null;
  const target = __drpyNormalizedTitle(keyword);
  let best = items[0];
  let bestScore = -1;
  for (const item of items) {
    const title = __drpyNormalizedTitle(item.vod_name || item.name || item.title);
    let score = 0;
    if (title === target) score = 100;
    else if (title.includes(target)) score = 70;
    else if (target.includes(title)) score = 55;
    if (score > bestScore) {
      best = item;
      bestScore = score;
    }
  }
  return best;
}

function __drpyDetailInput(id) {
  const raw = String(id || '');
  if (/^https?:\/\//i.test(raw)) return raw;
  let template = String(rule.detailUrl || '');
  if (template) {
    template = template.replace(/fyid/g, raw).replace(/fyclass/g, '');
    return /^https?:\/\//i.test(template) ? template : urljoin(HOST, template);
  }
  return urljoin(rule.homeUrl || HOST, raw);
}

function __drpyStaticDetailField(value, name) {
  if (value === undefined || value === null || value === '') return '';
  if (typeof value !== 'string' || __drpyIsProcedural(value) ||
      value.includes('\u91cd\u5b9a\u5411')) {
    __drpyUnsupported(`Procedural detail field is unsupported: ${name}.`);
  }
  return value.trim();
}

function __drpyStaticDetail(detailRule, hit) {
  const titleRule = __drpyStaticDetailField(detailRule.title, 'title');
  const imageRule = __drpyStaticDetailField(detailRule.img, 'img');
  __drpyStaticDetailField(detailRule.desc, 'desc');
  const contentRule = __drpyStaticDetailField(detailRule.content, 'content');
  const tabsRule = __drpyStaticDetailField(detailRule.tabs, 'tabs');
  const listsRule = __drpyStaticDetailField(detailRule.lists, 'lists');
  if (!listsRule) {
    __drpyUnsupported('Static detail has no episode-list selector.');
  }
  if (!/^https?:\/\//i.test(globalThis.input)) {
    __drpyUnsupported('Static detail has no HTTP detail URL.');
  }

  const body = request(globalThis.input);
  const tabNames = [];
  if (tabsRule) {
    for (const row of pdfa(body, tabsRule).slice(0, __DRPY_MAX_PLAY_LINES)) {
      const name = __drpyBoundedString(pdfh(row, 'Text'), 128);
      tabNames.push(name || `\u7ebf\u8def${tabNames.length + 1}`);
    }
  }

  const indexedLists = /#idv?\b/.test(listsRule);
  const planCount = indexedLists
    ? Math.max(1, Math.min(__DRPY_MAX_PLAY_LINES, tabNames.length))
    : 1;
  const groups = [];
  let episodeCount = 0;
  for (let index = 0; index < planCount; index++) {
    if (episodeCount >= __DRPY_MAX_EPISODES) break;
    const selector = listsRule
      .replace(/#idv\b/g, String(index))
      .replace(/#id\b/g, String(index));
    const episodes = [];
    const remaining = __DRPY_MAX_EPISODES - episodeCount;
    for (const row of pdfa(body, selector).slice(0, remaining)) {
      const url = __drpyHttpValue(
        pd(row, 'a&&href', globalThis.input),
        globalThis.input,
      );
      if (!url) continue;
      const name = __drpyBoundedString(
        pdfh(row, 'a&&Text') || pdfh(row, 'Text'),
        256,
      );
      episodes.push({
        name: name || `\u7b2c${episodeCount + episodes.length + 1}\u96c6`,
        url,
      });
    }
    episodeCount += episodes.length;
    if (episodes.length) {
      groups.push({
        name: tabNames[index] || `\u7ebf\u8def${groups.length + 1}`,
        episodes,
      });
    }
  }

  const titleSelector = titleRule.split(';')[0].trim();
  return {
    vod_id: globalThis.input,
    vod_name: titleSelector
      ? __drpyBoundedString(pdfh(body, titleSelector), 512)
      : __drpyBoundedString(hit.vod_name || hit.name || hit.title, 512),
    vod_pic: imageRule
      ? __drpyHttpValue(pd(body, imageRule, globalThis.input), globalThis.input)
      : __drpyBoundedString(hit.vod_pic || hit.pic || '', 4096),
    vod_content: contentRule
      ? __drpyBoundedString(pdfh(body, contentRule), 4096)
      : '',
    __drpyGroups: groups,
  };
}

function __drpyDetail(hit) {
  const detailRule = rule['\u4e8c\u7ea7'] !== undefined
    ? rule['\u4e8c\u7ea7']
    : rule.detail;
  const id = hit.vod_id || hit.id || hit.url || '';
  globalThis.VOD = {};
  globalThis.input = __drpyDetailInput(id);
  globalThis.MY_URL = globalThis.input;
  if (typeof detailRule === 'string' && detailRule.trim() === '*') {
    if (!/^https?:\/\//i.test(globalThis.input)) return globalThis.VOD;
    return {
      vod_id: globalThis.input,
      vod_name: __drpyBoundedString(
        hit.vod_name || hit.name || hit.title,
        512,
      ),
      __drpyGroups: [{
        name: 'direct',
        episodes: [{name: '\u6b63\u7247', url: globalThis.input}],
      }],
    };
  }
  if (!__drpyIsProcedural(detailRule)) {
    if (detailRule && typeof detailRule === 'object' &&
        !Array.isArray(detailRule)) {
      return __drpyStaticDetail(detailRule, hit);
    }
    __drpyUnsupported('Unsupported declarative detail rule.');
  }
  const returned = __drpyRun(detailRule, [id]);
  const parsed = __drpyObject(returned);
  if (parsed && Array.isArray(parsed.list) && parsed.list.length) {
    return parsed.list[0];
  }
  if (parsed && typeof parsed === 'object' && !Array.isArray(parsed) &&
      Object.keys(parsed).length) {
    return parsed;
  }
  return globalThis.VOD;
}

function __drpyPlayGroups(detail) {
  if (Array.isArray(detail.__drpyGroups)) {
    let total = 0;
    const groups = [];
    for (const rawGroup of detail.__drpyGroups.slice(0, __DRPY_MAX_PLAY_LINES)) {
      if (!rawGroup || !Array.isArray(rawGroup.episodes) ||
          total >= __DRPY_MAX_EPISODES) continue;
      const episodes = [];
      for (const rawEpisode of rawGroup.episodes.slice(
        0,
        __DRPY_MAX_EPISODES - total,
      )) {
        if (!rawEpisode || typeof rawEpisode !== 'object') continue;
        const url = __drpyBoundedString(rawEpisode.url, 4096);
        if (!url) continue;
        episodes.push({
          name: __drpyBoundedString(rawEpisode.name, 256) ||
            `\u7b2c${total + episodes.length + 1}\u96c6`,
          url,
        });
      }
      total += episodes.length;
      if (episodes.length) {
        groups.push({
          name: __drpyBoundedString(rawGroup.name, 128) ||
            `\u7ebf\u8def${groups.length + 1}`,
          episodes,
        });
      }
    }
    return groups;
  }
  const text = String(detail.vod_play_url || detail.play_url || '');
  if (!text) return [];
  const names = String(detail.vod_play_from || '').split('$$$');
  let total = 0;
  return text.split('$$$').slice(0, __DRPY_MAX_PLAY_LINES).map((group, index) => {
    const episodes = group.split('#').filter(Boolean)
      .slice(0, Math.max(0, __DRPY_MAX_EPISODES - total))
      .map((entry, episodeIndex) => {
        const separator = entry.indexOf('$');
        return separator < 0
          ? {name: `\u7b2c${episodeIndex + 1}\u96c6`, url: entry}
          : {name: entry.slice(0, separator), url: entry.slice(separator + 1)};
      });
    total += episodes.length;
    return {
    name: names[index] || `\u7ebf\u8def${index + 1}`,
      episodes,
    };
  }).filter((group) => group.episodes.length);
}

function __drpyPickEpisode(episodes, number, title) {
  if (!episodes.length) return null;
  const wantedTitle = __drpyNormalizedTitle(title);
  if (wantedTitle) {
    const exact = episodes.find(
      (episode) => __drpyNormalizedTitle(episode.name) === wantedTitle,
    );
    if (exact) return exact;
  }
  const wanted = Number(number) || 1;
  const numeric = episodes.find((episode) => {
    const match = String(episode.name || '').match(/\d+/);
    return match && Number(match[0]) === wanted;
  });
  if (numeric) return numeric;
  return episodes[Math.max(0, Math.min(episodes.length - 1, wanted - 1))];
}

function __drpyPlay(group, episode) {
  globalThis.input = String(episode.url || '');
  globalThis.MY_URL = globalThis.input;
  globalThis.MY_FLAG = group.name;
  globalThis.flag = group.name;
  const lazy = rule.lazy;
  let returned = lazy === undefined || lazy === null || lazy === ''
    ? globalThis.input
    : __drpyRun(lazy, [group.name, globalThis.input, []]);
  if (returned === undefined || returned === null || returned === '') {
    returned = globalThis.input;
  }
  const parsed = __drpyObject(returned);
  const play = parsed && typeof parsed === 'object' && !Array.isArray(parsed)
    ? parsed
    : {url: String(parsed || '')};
  const rawUrl = String(play.url || play.input || '');
  const url = /^https?:\/\//i.test(rawUrl) ? rawUrl : urljoin(HOST, rawUrl);
  const explicit = /\.(?:m3u8|mp4|m4a|mp3|flv|webm|mkv)(?:$|[?#])/i.test(url);
  const parseSpecified = play.parse !== undefined || play.jx !== undefined;
  const parse = Number(play.parse !== undefined ? play.parse : play.jx);
  const headers = __drpyNormalizeHeaders(
    play.header || play.headers || rule.headers || {},
  );
  const hasReferer = Object.keys(headers).some(
    (name) => name.toLowerCase() === 'referer',
  );
  if (!hasReferer && /^https?:\/\//i.test(HOST)) {
    headers.Referer = `${HOST.replace(/\/$/, '')}/`;
  }
  return {
    lineName: group.name,
    episodeName: episode.name,
    url,
    headers,
    requiresSniffing: !explicit &&
      ((parseSpecified && parse !== 0) || Boolean(rule.sniffer)),
  };
}

function __drpyResolve(source, keyword, episodeNumber, episodeTitle) {
  __drpyLoad(source);
  const hit = __drpyPickSearch(
    __drpySearch(String(keyword || '')),
    String(keyword || ''),
  );
  if (!hit) return {candidates: []};
  const detail = __drpyDetail(hit);
  const groups = __drpyPlayGroups(detail);
  const candidates = [];
  for (const group of groups.slice(0, 8)) {
    const episode = __drpyPickEpisode(
      group.episodes,
      episodeNumber,
      episodeTitle,
    );
    if (!episode) continue;
    const candidate = __drpyPlay(group, episode);
    if (candidate.url) candidates.push(candidate);
  }
  return {candidates};
}

function __drpyResolveSafe(source, keyword, episodeNumber, episodeTitle) {
  try {
    const resolved = __drpyResolve(source, keyword, episodeNumber, episodeTitle);
    return {ok: true, candidates: resolved.candidates || []};
  } catch (error) {
    const message = error && error.message ? error.message : String(error || '');
    return {
      ok: false,
      error: message
        .replace(/^DRPY_SUBSET:/, '')
        .replace(/^DRPY_NATIVE:/, ''),
      candidates: [],
    };
  }
}
''';
