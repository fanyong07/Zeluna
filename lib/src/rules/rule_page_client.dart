import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'rule_http_policy.dart';
import 'rule_models.dart';
import 'rule_playback_cancellation.dart';
import 'rule_security.dart';

const _responseCacheTtl = Duration(minutes: 5);
const _maxResponseCacheEntries = 128;
const _maxRuleRedirects = 5;

/// Explicit lookup scope: cancellation and approved domains travel together.
/// Distinct scopes never share in-flight requests, even for identical URLs.
class RulePageRequestScope {
  const RulePageRequestScope(this.cancellationToken, {this.rule});

  final RulePlaybackCancellationToken? cancellationToken;
  final RulePlugin? rule;
}

/// Buffered rule-page requests, with bounded caching and guarded redirects.
/// The caller owns [http.Client]; this module aborts requests, never the client.
class RulePageClient {
  RulePageClient({required this.timeout});

  final Duration timeout;
  final Map<String, ({String value, DateTime expiresAt})> _cache = {};
  final Map<(RulePageRequestScope?, String), Future<String>> _requests = {};
  var _generation = 0;

  void clearCaches() {
    _generation++;
    _cache.clear();
    _requests.clear();
  }

  Future<String> get(
    http.Client client,
    Uri url,
    Map<String, String> headers, {
    RulePageRequestScope? scope,
  }) => _request(client, 'GET', url, headers, scope: scope);

  Future<String> post(
    http.Client client,
    Uri url,
    String body,
    Map<String, String> headers, {
    RulePageRequestScope? scope,
  }) => _request(client, 'POST', url, headers, body: body, scope: scope);

  Future<String> _request(
    http.Client client,
    String method,
    Uri url,
    Map<String, String> headers, {
    String? body,
    RulePageRequestScope? scope,
  }) async {
    _throwIfCancelled(scope, url);
    _ensureAllowed(scope, url);
    final requestUri = ruleRequestUri(url);
    final requestHeaders = ruleRequestHeaders(url, headers);
    final key = ruleRequestCacheKey(
      method,
      requestUri,
      requestHeaders,
      body: body ?? '',
    );
    final cached = _cache[key];
    if (cached != null) {
      if (DateTime.now().isBefore(cached.expiresAt)) return cached.value;
      _cache.remove(key);
    }

    final inFlightKey = (scope, key);
    final existing = _requests[inFlightKey];
    if (existing != null) return existing;

    final generation = _generation;
    final request = _send(
      client,
      method,
      requestUri,
      requestHeaders,
      body: body,
      scope: scope,
    ).then(_responseText);
    _requests[inFlightKey] = request;
    try {
      final result = await request;
      _throwIfCancelled(scope, requestUri);
      if (generation == _generation) {
        _cache.remove(key);
        _cache[key] = (
          value: result,
          expiresAt: DateTime.now().add(_responseCacheTtl),
        );
        while (_cache.length > _maxResponseCacheEntries) {
          _cache.remove(_cache.keys.first);
        }
      }
      return result;
    } finally {
      if (identical(_requests[inFlightKey], request)) {
        _requests.remove(inFlightKey);
      }
    }
  }

  Future<http.Response> _send(
    http.Client client,
    String method,
    Uri uri,
    Map<String, String> headers, {
    String? body,
    RulePageRequestScope? scope,
  }) async {
    final abortTrigger = Completer<void>();
    void abort() {
      if (!abortTrigger.isCompleted) abortTrigger.complete();
    }

    final cancellationToken = scope?.cancellationToken;
    final unregisterCancellation = cancellationToken?.register(abort);
    final sandboxed = scope?.rule != null;
    final operation = () async {
      var currentMethod = method;
      var currentUri = uri;
      var currentHeaders = headers;
      var currentBody = body;
      for (var redirect = 0; ; redirect++) {
        _ensureAllowed(scope, currentUri);
        final request =
            http.AbortableRequest(
                currentMethod,
                currentUri,
                abortTrigger: abortTrigger.future,
              )
              ..followRedirects = !sandboxed
              ..headers.addAll(currentHeaders);
        if (currentBody != null) request.body = currentBody;
        final response = await client.send(request);
        final location = response.headers['location'];
        if (!sandboxed ||
            !isRuleHttpRedirect(response.statusCode) ||
            location == null ||
            location.trim().isEmpty) {
          return http.Response.fromStream(response);
        }
        // No redirect body is consumed. Release it before any validation can
        // throw, including a denied destination or malformed Location header.
        final subscription = response.stream.listen(null);
        await subscription.cancel();
        if (redirect >= _maxRuleRedirects) {
          throw StateError('这个来源的网页一直在跳转，已停下。');
        }
        final nextUri = currentUri.resolve(location.trim());
        _ensureAllowed(scope, nextUri);
        currentHeaders = ruleChildHeaders(currentUri, nextUri, currentHeaders);
        if (response.statusCode == 303 ||
            ((response.statusCode == 301 || response.statusCode == 302) &&
                currentMethod.toUpperCase() == 'POST')) {
          currentMethod = 'GET';
          currentBody = null;
          currentHeaders = withoutRuleHeader(currentHeaders, 'content-type');
        }
        currentUri = nextUri;
      }
    }();
    try {
      return await operation.timeout(
        timeout,
        onTimeout: () {
          abort();
          throw TimeoutException('Rule request timed out after $timeout.');
        },
      );
    } finally {
      unregisterCancellation?.call();
    }
  }
}

void _throwIfCancelled(RulePageRequestScope? scope, Uri uri) {
  if (scope?.cancellationToken?.isCancelled ?? false) {
    throw http.RequestAbortedException(uri);
  }
}

void _ensureAllowed(RulePageRequestScope? scope, Uri uri) {
  final rule = scope?.rule;
  if (rule == null) return;
  if (!RuleUrlPolicy(rule.effectiveManifest).allows(uri, RuleUrlPurpose.page)) {
    throw StateError('这个来源想访问未授权的网站，已拦下。');
  }
}

String _responseText(http.Response response) {
  if (response.statusCode < 200 || response.statusCode >= 400) {
    throw HttpException('HTTP ${response.statusCode}');
  }
  return utf8.decode(response.bodyBytes, allowMalformed: true);
}

class HttpException implements Exception {
  const HttpException(this.message);

  final String message;

  @override
  String toString() => message;
}
