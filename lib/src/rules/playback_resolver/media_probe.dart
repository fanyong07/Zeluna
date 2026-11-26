part of '../rule_playback_resolver.dart';

// Bounded media probes, redirect handling, and probe caching.

const _playableProbeTimeout = Duration(seconds: 8);
const _playlistMetadataTimeout = Duration(seconds: 6);
const _metadataEnrichmentBudget = Duration(seconds: 2);
const _probeChunkIdleTimeout = Duration(milliseconds: 1200);
const _initialProbeRangeEnd = 2048;
const _maxBinaryProbeSampleBytes = 64 * 1024;
const _maxManifestProbeSampleBytes = 512 * 1024;
const _minimumBinaryProbeBytes = 4 * 1024;
const _maxDrpyMediaRedirects = 3;
const _maxRuleRedirects = 5;
const _maxConcurrentPlayableProbes = 10;
const _maxConcurrentMetadataProbes = 8;
const _availableProbeCacheTtl = Duration(minutes: 2);
const _failedProbeCacheTtl = Duration(seconds: 20);
const _maxProbeCacheEntries = 256;

extension _MediaProbe on RulePlaybackResolver {
  Future<_PlayableProbeResult> _probePlayableUrl(
    http.Client client,
    String url,
    Map<String, String> headers, {
    bool enrichMetadata = true,
    bool forceRefresh = false,
    bool catalog = false,
    bool live = false,
  }) async {
    final target = Uri.tryParse(url);
    if (target == null || !target.hasScheme) {
      return const _PlayableProbeResult(false, '视频地址格式不正确。');
    }
    _throwIfLookupCancelled(target);
    _ensureSandboxedRuleUri(target, RuleUrlPurpose.media);
    if (catalogShortClip(target, live: live)) {
      return const _PlayableProbeResult(
        false,
        catalogShortClipMessage,
        errorCategory: 'short_clip',
      );
    }
    final requestUri = ruleRequestUri(target);
    // A known playlist needs its bounded manifest, not a 2 KB binary sniff
    // followed by the same request again. Opaque URLs retain the fallback path.
    final path = target.path.toLowerCase();
    final sourceHeaders = _videoProbeHeaders(headers);
    final requestHeaders = ruleRequestHeaders(
      target,
      path.endsWith('.m3u8') || path.endsWith('.mpd')
          ? _manifestProbeHeaders(sourceHeaders)
          : sourceHeaders,
    );
    final key = ruleRequestCacheKey(
      '${enrichMetadata ? 'PROBE' : 'PROBE_QUICK'}'
      '${catalog ? '_CATALOG' : ''}${live ? '_LIVE' : ''}'
      '${_requiresDrpyPublicMediaProbe ? '_DRPY_PUBLIC' : ''}',
      requestUri,
      requestHeaders,
    );
    if (!forceRefresh) {
      final cached = _freshCacheValue(_probeCache, key);
      if (cached != null) return cached;
    }

    final inFlightKey = _resolveScopedInFlightKey(key);
    final existing = _probeRequests[inFlightKey];
    if (existing != null) return existing;

    final cacheGeneration = _cacheGeneration;
    final limiter = forceRefresh
        ? _foregroundProbeLimiter
        : _playableProbeLimiter;
    final request = limiter.run(
      () => _performPlayableProbe(
        client,
        sourceUri: target,
        requestUri: requestUri,
        headers: requestHeaders,
        sourceHeaders: sourceHeaders,
        enrichMetadata: enrichMetadata,
        catalog: catalog,
        live: live,
      ),
    );
    _probeRequests[inFlightKey] = request;
    try {
      final result = await request;
      _throwIfLookupCancelled(requestUri);
      if (cacheGeneration == _cacheGeneration) {
        _storeCacheValue(
          _probeCache,
          key,
          result,
          result.available ? _availableProbeCacheTtl : _failedProbeCacheTtl,
          _maxProbeCacheEntries,
        );
      }
      return result;
    } finally {
      if (identical(_probeRequests[inFlightKey], request)) {
        _probeRequests.remove(inFlightKey);
      }
    }
  }

  Future<_PlayableProbeResult> _playableCandidateStatus(
    http.Client client,
    String url,
    Map<String, String> headers, {
    required bool verifyPlayable,
    bool verifyExplicitMedia = false,
  }) {
    // A URL-looking string is only a candidate. Even the quick path performs
    // a bounded media probe so dead CDN links and HTML error pages never leave
    // the resolver as `available=true`.
    return _probePlayableUrl(
      client,
      url,
      headers,
      enrichMetadata: verifyPlayable || verifyExplicitMedia,
    );
  }

  Future<_PlayableProbeResult> _performPlayableProbe(
    http.Client client, {
    required Uri sourceUri,
    required Uri requestUri,
    required Map<String, String> headers,
    required Map<String, String> sourceHeaders,
    required bool enrichMetadata,
    required bool catalog,
    required bool live,
  }) async {
    final stopwatch = Stopwatch()..start();

    Duration totalLatency() {
      if (stopwatch.isRunning) stopwatch.stop();
      return stopwatch.elapsed;
    }

    try {
      var sample = await _sendPlayableProbe(
        client,
        requestUri,
        headers,
        timeout: _playableProbeTimeout,
      );
      var response = sample.response;
      if (response.statusCode >= 200 && response.statusCode < 300) {
        if (!sample.sampleComplete &&
            _isManifestResponse(requestUri, response)) {
          try {
            final expandedSample = await _sendPlayableProbe(
              client,
              ruleRequestUri(sourceUri),
              ruleRequestHeaders(
                sourceUri,
                _manifestProbeHeaders(sourceHeaders),
              ),
              timeout: _playlistMetadataTimeout,
            );
            if (expandedSample.response.statusCode >= 200 &&
                expandedSample.response.statusCode < 300) {
              sample = expandedSample;
              response = expandedSample.response;
            }
          } catch (_) {
            // The bounded initial sample is still validated below. If it does
            // not contain a complete manifest, the line will be rejected.
          }
        }
        final validation = _validatePlayableSample(sourceUri, sample);
        if (!validation.available) {
          return _PlayableProbeResult(
            false,
            validation.message,
            latency: totalLatency(),
          );
        }
        final detectedFormat = _detectedMediaFormat(
          sourceUri,
          response.headers['content-type'],
          utf8.decode(sample.sample, allowMalformed: true),
        );
        _ProbeMediaMetadata metadata;
        try {
          metadata = _mediaMetadataFromSample(sourceUri, sample);
          if (enrichMetadata) {
            metadata = await _probeMediaMetadata(
              client,
              sourceUri: sourceUri,
              sourceHeaders: sourceHeaders,
              sample: sample,
            );
          }
        } catch (_) {
          if (detectedFormat == 'HLS' || detectedFormat == 'DASH') {
            return _PlayableProbeResult(
              false,
              '媒体清单格式无效，无法确认真实播放分片。',
              latency: totalLatency(),
            );
          }
          // Container metadata is optional for a signature-confirmed file.
          metadata = const _ProbeMediaMetadata();
        }
        if (catalogShortClip(
          sourceUri,
          format: metadata.format ?? detectedFormat ?? '',
          bytes: metadata.sizeBytes,
          estimated: metadata.sizeEstimated,
          seconds: metadata.durationSeconds,
          live: live || metadata.isLive,
          catalog: catalog,
        )) {
          return const _PlayableProbeResult(
            false,
            catalogShortClipMessage,
            errorCategory: 'short_clip',
          );
        }
        if (metadata.format == 'HLS') {
          final hlsFailure = await _verifyHlsMediaReachability(
            client,
            sourceUri: sourceUri,
            sourceHeaders: sourceHeaders,
            metadata: metadata,
          );
          if (hlsFailure != null) {
            return _PlayableProbeResult(
              false,
              hlsFailure,
              latency: totalLatency(),
            );
          }
        }
        if (metadata.format == 'DASH') {
          final dashFailure = await _verifyDashMediaReachability(
            client,
            sourceUri: sourceUri,
            sourceHeaders: sourceHeaders,
            metadata: metadata,
          );
          if (dashFailure != null) {
            return _PlayableProbeResult(
              false,
              dashFailure,
              latency: totalLatency(),
            );
          }
        }
        return _PlayableProbeResult(
          true,
          '',
          latency: totalLatency(),
          format: metadata.format,
          startupProfile: metadata.startupProfile,
          sizeBytes: metadata.sizeBytes,
          sizeEstimated: metadata.sizeEstimated,
          videoWidth: metadata.videoWidth,
          videoHeight: metadata.videoHeight,
          bitrate: metadata.bitrate,
          codecs: metadata.codecs,
          isLive: metadata.isLive,
          adaptive: metadata.adaptive,
        );
      }
      if (response.statusCode == 403) {
        return _PlayableProbeResult(
          false,
          '视频服务器拒绝了访问，可能限制了地区或来源。',
          errorCategory: 'http_403',
          latency: totalLatency(),
        );
      }
      if (response.statusCode == 404) {
        return _PlayableProbeResult(
          false,
          '视频 CDN 返回 404，这条播放地址已经失效。',
          errorCategory: 'http_404',
          latency: totalLatency(),
        );
      }
      return _PlayableProbeResult(
        false,
        '视频 CDN 返回 HTTP ${response.statusCode}。',
        errorCategory: 'http_${response.statusCode}',
        latency: totalLatency(),
      );
    } on TimeoutException {
      return _PlayableProbeResult(
        false,
        '视频 CDN 连接超时。',
        errorCategory: 'timeout',
        latency: totalLatency(),
      );
    } catch (error) {
      return _PlayableProbeResult(
        false,
        '视频 CDN 无法访问：${_shortError(error)}',
        errorCategory: _probeFailureCategory(error),
        latency: totalLatency(),
      );
    }
  }

  Future<_ProbeMediaMetadata> _probeMediaMetadata(
    http.Client client, {
    required Uri sourceUri,
    required Map<String, String> sourceHeaders,
    required _PlayableProbeResponse sample,
  }) async {
    var metadata = _mediaMetadataFromSample(sourceUri, sample);
    final needsExpandedManifest =
        !sample.sampleComplete &&
        (metadata.format == 'HLS' || metadata.format == 'DASH');
    final needsExtraRequest =
        needsExpandedManifest ||
        (metadata.format == 'HLS' &&
            (metadata.variantUri != null ||
                (!metadata.isLive && metadata.sampleSegmentUri != null)));
    if (!needsExtraRequest) return metadata;
    final enriched = await _metadataProbeLimiter.runIfAvailable(() async {
      final enrichmentStopwatch = Stopwatch()..start();
      Duration requestTimeout() {
        final remaining =
            _metadataEnrichmentBudget - enrichmentStopwatch.elapsed;
        if (remaining <= Duration.zero) {
          throw TimeoutException('Media metadata enrichment timed out.');
        }
        return remaining < _playlistMetadataTimeout
            ? remaining
            : _playlistMetadataTimeout;
      }

      var enriched = metadata;
      try {
        if (needsExpandedManifest) {
          final expandedSample = await _sendPlayableProbe(
            client,
            ruleRequestUri(sourceUri),
            ruleRequestHeaders(sourceUri, _manifestProbeHeaders(sourceHeaders)),
            timeout: requestTimeout(),
          );
          if (expandedSample.response.statusCode >= 200 &&
              expandedSample.response.statusCode < 400) {
            enriched = _mediaMetadataFromSample(sourceUri, expandedSample);
          }
        }
        if (enriched.format != 'HLS') return enriched;

        final variantUri = enriched.variantUri;
        if (variantUri != null) {
          final childHeaders = ruleChildHeaders(
            sourceUri,
            variantUri,
            sourceHeaders,
          );
          final variantSample = await _sendPlayableProbe(
            client,
            ruleRequestUri(variantUri),
            ruleRequestHeaders(variantUri, _manifestProbeHeaders(childHeaders)),
            timeout: requestTimeout(),
          );
          if (variantSample.response.statusCode >= 200 &&
              variantSample.response.statusCode < 400) {
            final media = _mediaMetadataFromSample(variantUri, variantSample);
            var sizeBytes = media.sizeBytes;
            var sizeEstimated = media.sizeEstimated;
            final durationSeconds = media.durationSeconds;
            if (sizeBytes == null &&
                !media.isLive &&
                durationSeconds != null &&
                durationSeconds > 0 &&
                enriched.bitrate != null &&
                enriched.bitrate! > 0) {
              sizeBytes = (enriched.bitrate! * durationSeconds / 8).round();
              sizeEstimated = true;
            }
            enriched = enriched.copyWith(
              sizeBytes: sizeBytes,
              sizeEstimated: sizeEstimated,
              isLive: media.isLive,
              durationSeconds: durationSeconds,
              sampleSegmentUri: media.sampleSegmentUri,
              sampleSegmentUris: media.sampleSegmentUris,
              segmentCandidates: media.segmentCandidates,
              sampleSegmentDurationSeconds: media.sampleSegmentDurationSeconds,
            );
          }
        }
        if (enriched.sizeBytes == null && !enriched.isLive) {
          enriched = await _estimateHlsSizeFromSegment(
            client,
            metadata: enriched,
            credentialSourceUri: sourceUri,
            sourceHeaders: sourceHeaders,
            timeout: requestTimeout(),
          );
        }
      } catch (_) {
        // 规格补全失败不影响线路可播放性，保留首个清单已经确认的信息。
      }
      return enriched;
    });
    return enriched ?? metadata;
  }

  Future<String?> _verifyHlsMediaReachability(
    http.Client client, {
    required Uri sourceUri,
    required Map<String, String> sourceHeaders,
    required _ProbeMediaMetadata metadata,
  }) async {
    final variants = metadata.variants.isNotEmpty
        ? metadata.variants.take(3).toList(growable: false)
        : metadata.variantUri == null
        ? const <_HlsProbeVariant>[]
        : <_HlsProbeVariant>[_HlsProbeVariant(uri: metadata.variantUri!)];
    if (variants.isEmpty) {
      return _verifyHlsSegments(
        client,
        credentialSourceUri: sourceUri,
        sourceHeaders: sourceHeaders,
        metadata: metadata,
      );
    }

    String? lastFailure;
    for (final variant in variants) {
      try {
        final variantHeaders = ruleChildHeaders(
          sourceUri,
          variant.uri,
          sourceHeaders,
        );
        final variantSample = await _sendPlayableProbe(
          client,
          ruleRequestUri(variant.uri),
          ruleRequestHeaders(
            variant.uri,
            _manifestProbeHeaders(variantHeaders),
          ),
          timeout: _playlistMetadataTimeout,
        );
        final validation = _validatePlayableSample(variant.uri, variantSample);
        if (variantSample.response.statusCode < 200 ||
            variantSample.response.statusCode >= 300 ||
            !validation.available) {
          lastFailure = 'HLS 子清单已经失效。';
          continue;
        }
        final mediaMetadata = _mediaMetadataFromSample(
          variant.uri,
          variantSample,
        );
        final failure = await _verifyHlsSegments(
          client,
          credentialSourceUri: variant.uri,
          sourceHeaders: variantHeaders,
          metadata: mediaMetadata,
        );
        if (failure == null) return null;
        lastFailure = failure;
      } on TimeoutException {
        lastFailure = 'HLS 子清单或媒体分片验证超时。';
      } catch (_) {
        lastFailure = 'HLS 子清单无法解析或访问。';
      }
    }
    return lastFailure ?? 'HLS 主清单内没有可播放的子清单。';
  }

  Future<String?> _verifyHlsSegments(
    http.Client client, {
    required Uri credentialSourceUri,
    required Map<String, String> sourceHeaders,
    required _ProbeMediaMetadata metadata,
  }) async {
    final candidates = metadata.segmentCandidates.isNotEmpty
        ? metadata.segmentCandidates.take(3).toList(growable: false)
        : metadata.sampleSegmentUris.isNotEmpty
        ? metadata.sampleSegmentUris
              .take(3)
              .map((uri) => _HlsProbeSegment(uri: uri))
              .toList(growable: false)
        : metadata.sampleSegmentUri == null
        ? const <_HlsProbeSegment>[]
        : <_HlsProbeSegment>[_HlsProbeSegment(uri: metadata.sampleSegmentUri!)];
    if (candidates.isEmpty) {
      return 'HLS 清单没有返回可验证的媒体分片。';
    }
    var timedOut = false;
    final keyAvailability = <Uri, bool>{};
    // VOD starts with the first segment. A working later segment cannot make
    // its missing opening segment/key playable; the decoder still opens it.
    // Live windows may expire while checked, so retain their recent fallback.
    for (final candidate in candidates.take(metadata.isLive ? 3 : 1)) {
      try {
        var aes128KeyVerified = false;
        if (candidate.usesAes128) {
          final keyUri = candidate.keyUri;
          if (keyUri == null) continue;
          aes128KeyVerified =
              keyAvailability[keyUri] ??
              await _verifyHlsAes128Key(
                client,
                credentialSourceUri: credentialSourceUri,
                keyUri: keyUri,
                sourceHeaders: sourceHeaders,
              );
          keyAvailability[keyUri] = aes128KeyVerified;
          if (!aes128KeyVerified) continue;
        }
        final segmentUri = candidate.uri;
        final segmentHeaders = ruleChildHeaders(
          credentialSourceUri,
          segmentUri,
          sourceHeaders,
        );
        final segmentSample = await _sendPlayableProbe(
          client,
          ruleRequestUri(segmentUri),
          ruleRequestHeaders(segmentUri, _videoProbeHeaders(segmentHeaders)),
          timeout: _playlistMetadataTimeout,
        );
        if (segmentSample.response.statusCode >= 200 &&
            segmentSample.response.statusCode < 300 &&
            (_validatePlayableSample(segmentUri, segmentSample).available ||
                (aes128KeyVerified &&
                    _isOpaqueEncryptedHlsSegment(segmentSample)))) {
          return null;
        }
      } on TimeoutException {
        timedOut = true;
      } catch (_) {
        // Try another recent/alternate segment before rejecting the line.
      }
    }
    return timedOut ? 'HLS 媒体分片验证超时。' : 'HLS 清单存在，但媒体分片无法读取。';
  }

  Future<bool> _verifyHlsAes128Key(
    http.Client client, {
    required Uri credentialSourceUri,
    required Uri keyUri,
    required Map<String, String> sourceHeaders,
  }) async {
    final keyHeaders = ruleChildHeaders(
      credentialSourceUri,
      keyUri,
      sourceHeaders,
    );
    final sample = await _sendPlayableProbe(
      client,
      ruleRequestUri(keyUri),
      ruleRequestHeaders(keyUri, _videoProbeHeaders(keyHeaders)),
      timeout: _playlistMetadataTimeout,
    );
    return sample.response.statusCode >= 200 &&
        sample.response.statusCode < 300 &&
        sample.sample.length == 16;
  }

  Future<String?> _verifyDashMediaReachability(
    http.Client client, {
    required Uri sourceUri,
    required Map<String, String> sourceHeaders,
    required _ProbeMediaMetadata metadata,
  }) async {
    if (metadata.dashResources.isEmpty) {
      return 'DASH 清单没有可验证的初始化或媒体分片。';
    }
    for (final resource in metadata.dashResources.take(3)) {
      try {
        final childHeaders = ruleChildHeaders(
          sourceUri,
          resource.uri,
          sourceHeaders,
        );
        final sample = await _sendPlayableProbe(
          client,
          ruleRequestUri(resource.uri),
          ruleRequestHeaders(resource.uri, _videoProbeHeaders(childHeaders)),
          timeout: _playlistMetadataTimeout,
        );
        if (sample.response.statusCode < 200 ||
            sample.response.statusCode >= 300 ||
            !_validatePlayableSample(resource.uri, sample).available) {
          return 'DASH ${resource.label}无法读取。';
        }
      } on TimeoutException {
        return 'DASH ${resource.label}验证超时。';
      } catch (_) {
        return 'DASH ${resource.label}无法访问。';
      }
    }
    return null;
  }

  Future<_ProbeMediaMetadata> _estimateHlsSizeFromSegment(
    http.Client client, {
    required _ProbeMediaMetadata metadata,
    required Uri credentialSourceUri,
    required Map<String, String> sourceHeaders,
    required Duration timeout,
  }) async {
    final segmentUri = metadata.sampleSegmentUri;
    final segmentDuration = metadata.sampleSegmentDurationSeconds;
    final totalDuration = metadata.durationSeconds;
    if (segmentUri == null ||
        segmentDuration == null ||
        segmentDuration <= 0 ||
        totalDuration == null ||
        totalDuration <= 0) {
      return metadata;
    }
    final segmentSample = await _sendPlayableProbe(
      client,
      ruleRequestUri(segmentUri),
      ruleRequestHeaders(
        segmentUri,
        ruleChildHeaders(credentialSourceUri, segmentUri, sourceHeaders),
      ),
      timeout: timeout,
    );
    if (segmentSample.response.statusCode < 200 ||
        segmentSample.response.statusCode >= 400) {
      return metadata;
    }
    final segmentBytes = _responseTotalBytes(segmentSample.response);
    if (segmentBytes == null || segmentBytes <= 0) return metadata;
    final estimatedBytes = (segmentBytes * totalDuration / segmentDuration)
        .round();
    return metadata.copyWith(sizeBytes: estimatedBytes, sizeEstimated: true);
  }

  Future<_PlayableProbeResponse> _sendPlayableProbe(
    http.Client client,
    Uri requestUri,
    Map<String, String> headers, {
    required Duration timeout,
  }) async {
    final stopwatch = Stopwatch()..start();
    final first = await _sendPlayableProbeOnce(
      client,
      requestUri,
      headers,
      timeout: timeout,
    );
    const rangeRejectedStatuses = <int>{400, 405, 416};
    final hasRange = headers.keys.any((name) => name.toLowerCase() == 'range');
    if (!hasRange ||
        !rangeRejectedStatuses.contains(first.response.statusCode)) {
      return first;
    }
    final remaining = timeout - stopwatch.elapsed;
    if (remaining <= Duration.zero) return first;
    return _sendPlayableProbeOnce(
      client,
      requestUri,
      withoutRuleHeader(headers, 'range'),
      timeout: remaining,
    );
  }

  Future<_PlayableProbeResponse> _sendPlayableProbeOnce(
    http.Client client,
    Uri requestUri,
    Map<String, String> headers, {
    required Duration timeout,
  }) async {
    final drpyPublicOnly = _requiresDrpyPublicMediaProbe;
    final sandboxedRule = _activeRulePlaybackResolveContext?.rule != null;
    final abortTrigger = Completer<void>();
    void abort() {
      if (!abortTrigger.isCompleted) abortTrigger.complete();
    }

    final cancellationToken =
        _activeRulePlaybackResolveContext?.cancellationToken;
    final unregisterCancellation = cancellationToken?.register(abort);
    final operation = () async {
      final stopwatch = Stopwatch()..start();
      var currentUri = requestUri;
      var currentHeaders = headers;
      late http.StreamedResponse response;
      for (var redirect = 0; ; redirect++) {
        if (sandboxedRule) {
          _ensureSandboxedRuleUri(currentUri, RuleUrlPurpose.media);
        }
        if (drpyPublicOnly) {
          await _drpyRuntime.ensurePublicUri(
            ruleProxyUpstreamUri(currentUri) ?? currentUri,
          );
        }
        final request =
            http.AbortableRequest(
                'GET',
                currentUri,
                abortTrigger: abortTrigger.future,
              )
              ..followRedirects = false
              ..maxRedirects = 0
              ..headers.addAll(currentHeaders);
        response = await client.send(request);
        final location = response.headers['location'];
        if (!isRuleHttpRedirect(response.statusCode) ||
            location == null ||
            location.trim().isEmpty) {
          break;
        }
        // Release this hop before URI parsing or policy validation can throw.
        // The client is shared; only this response belongs to the probe.
        final subscription = response.stream.listen(null);
        await subscription.cancel();
        final redirectLimit = drpyPublicOnly
            ? _maxDrpyMediaRedirects
            : _maxRuleRedirects;
        if (redirect >= redirectLimit) {
          throw const HttpException('media redirect limit reached.');
        }
        final nextUri = currentUri.resolve(location.trim());
        if (sandboxedRule) {
          _ensureSandboxedRuleUri(nextUri, RuleUrlPurpose.media);
        }
        if (drpyPublicOnly) {
          await _drpyRuntime.ensurePublicUri(
            ruleProxyUpstreamUri(nextUri) ?? nextUri,
          );
        }
        currentHeaders = ruleChildHeaders(currentUri, nextUri, currentHeaders);
        currentUri = nextUri;
      }
      if (response.statusCode < 200 || response.statusCode >= 400) {
        stopwatch.stop();
        final subscription = response.stream.listen(null);
        await subscription.cancel();
        return _PlayableProbeResponse(response, latency: stopwatch.elapsed);
      }
      final stream = StreamIterator<List<int>>(response.stream);
      final sample = <int>[];
      Duration? firstByteLatency;
      final manifestResponse = _isManifestResponse(requestUri, response);
      final sampleLimit = manifestResponse
          ? _maxManifestProbeSampleBytes
          : _maxBinaryProbeSampleBytes;
      final contentLength = int.tryParse(
        response.headers['content-length'] ?? '',
      );
      final targetBytes = contentLength == null || contentLength <= 0
          ? null
          : contentLength.clamp(1, sampleLimit);
      final readUnknownLength = targetBytes == null;
      var sampleComplete = false;
      try {
        // 清单读取到 EOF/上限；未知长度的二进制累计到最小嗅探量，
        // 既允许容器签名跨 chunk，也避免 Range 被忽略后持续下载。
        var firstChunk = true;
        while (sample.length < sampleLimit) {
          var idleTimedOut = false;
          final hasNext = firstChunk || !readUnknownLength
              ? await stream.moveNext()
              : await stream.moveNext().timeout(
                  _probeChunkIdleTimeout,
                  onTimeout: () {
                    idleTimedOut = true;
                    return false;
                  },
                );
          if (!hasNext) {
            final totalBytes = _responseTotalBytes(response);
            sampleComplete =
                !idleTimedOut &&
                (totalBytes == null || totalBytes <= sample.length);
            break;
          }
          firstByteLatency ??= stopwatch.elapsed;
          final chunk = stream.current;
          final remaining = sampleLimit - sample.length;
          sample.addAll(
            chunk.length <= remaining ? chunk : chunk.take(remaining),
          );
          firstChunk = false;
          if (targetBytes != null && sample.length >= targetBytes) {
            final totalBytes = _responseTotalBytes(response);
            sampleComplete = totalBytes != null && totalBytes <= sample.length;
            break;
          }
          if (targetBytes == null &&
              !manifestResponse &&
              sample.length >= _minimumBinaryProbeBytes) {
            break;
          }
        }
      } finally {
        stopwatch.stop();
        await stream.cancel();
      }
      return _PlayableProbeResponse(
        response,
        sample: List<int>.unmodifiable(sample),
        latency: firstByteLatency ?? stopwatch.elapsed,
        sampleComplete: sampleComplete,
      );
    }();
    try {
      return await operation.timeout(
        timeout,
        onTimeout: () {
          abort();
          throw TimeoutException('Media probe timed out after $timeout.');
        },
      );
    } finally {
      unregisterCancellation?.call();
    }
  }
}

class _PlayableProbeResponse {
  const _PlayableProbeResponse(
    this.response, {
    this.sample = const [],
    this.latency,
    this.sampleComplete = false,
  });

  final http.StreamedResponse response;
  final List<int> sample;
  final Duration? latency;
  final bool sampleComplete;
}

int? _responseTotalBytes(http.StreamedResponse response) {
  final contentRange = response.headers['content-range'] ?? '';
  final rangeMatch = RegExp(r'/\s*(\d+)\s*$').firstMatch(contentRange);
  final rangeTotal = int.tryParse(rangeMatch?.group(1) ?? '');
  if (rangeTotal != null && rangeTotal > 0) return rangeTotal;
  if (response.statusCode != 200) return null;
  final contentLength = int.tryParse(response.headers['content-length'] ?? '');
  return contentLength != null && contentLength > 0 ? contentLength : null;
}

class _AsyncLimiter {
  _AsyncLimiter(this.limit) : assert(limit > 0);

  final int limit;
  var _active = 0;
  final List<Completer<void>> _waiters = [];

  Future<T> run<T>(Future<T> Function() action) async {
    if (_active >= limit) {
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    } else {
      _active++;
    }
    try {
      return await action();
    } finally {
      _release();
    }
  }

  Future<T?> runIfAvailable<T>(Future<T> Function() action) async {
    // Metadata is optional. Skipping enrichment when all slots are busy keeps
    // a confirmed playable line inside the repository's lookup budget.
    if (_active >= limit) return null;
    _active++;
    try {
      return await action();
    } finally {
      _release();
    }
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      // Transfer the active slot directly to the oldest waiter so a newly
      // arriving task cannot overtake it or briefly exceed the limit.
      _waiters.removeAt(0).complete();
      return;
    }
    _active--;
  }
}

class _TimedCacheEntry<T> {
  const _TimedCacheEntry(this.value, this.expiresAt);

  final T value;
  final DateTime expiresAt;
}

T? _freshCacheValue<T>(Map<String, _TimedCacheEntry<T>> cache, String key) {
  final entry = cache[key];
  if (entry == null) return null;
  if (DateTime.now().isBefore(entry.expiresAt)) return entry.value;
  cache.remove(key);
  return null;
}

void _storeCacheValue<T>(
  Map<String, _TimedCacheEntry<T>> cache,
  String key,
  T value,
  Duration ttl,
  int maxEntries,
) {
  cache.remove(key);
  cache[key] = _TimedCacheEntry(value, DateTime.now().add(ttl));
  while (cache.length > maxEntries) {
    cache.remove(cache.keys.first);
  }
}

class _PlayableProbeResult {
  const _PlayableProbeResult(
    this.available,
    this.message, {
    this.latency,
    this.errorCategory = '',
    this.format,
    this.startupProfile = PlaybackStartupProfile.unknown,
    this.sizeBytes,
    this.sizeEstimated = false,
    this.videoWidth,
    this.videoHeight,
    this.bitrate,
    this.codecs,
    this.isLive = false,
    this.adaptive = false,
  });

  final String errorCategory;
  final bool available;
  final String message;
  final Duration? latency;
  final String? format;
  final String startupProfile;
  final int? sizeBytes;
  final bool sizeEstimated;
  final int? videoWidth;
  final int? videoHeight;
  final int? bitrate;
  final String? codecs;
  final bool isLive;
  final bool adaptive;
}

/// User-facing text for a resolver exception.
///
/// Never interpolates the raw exception: `error.toString()` carries Dart's own
/// prefixes ("Bad state:", "SocketException:") and, for the drpy runtime,
/// English internal messages -- all of which used to reach Chinese UI verbatim.
/// StateError messages are written for users, so those pass through directly.
String _probeFailureCategory(Object error) {
  if (error is TimeoutException) return 'timeout';
  if (error is FormatException) return 'invalid_media';
  // Do not export exception text, which may embed signed URLs/credentials.
  final type = error.runtimeType.toString().toLowerCase();
  if (type.contains('handshake') || type.contains('tls')) return 'tls';
  if (type.contains('security')) return 'policy';
  if (type.contains('socket') || type.contains('client')) return 'connection';
  return 'probe_failed';
}

Map<String, String> _videoProbeHeaders(Map<String, String> headers) {
  final result = withoutRuleHeader(
    withoutRuleHeader(headers, 'accept'),
    'range',
  );
  result['Accept'] = '*/*';
  result['Range'] = 'bytes=0-$_initialProbeRangeEnd';
  return result;
}

Map<String, String> _manifestProbeHeaders(Map<String, String> headers) {
  return withoutRuleHeader(headers, 'range')
    ..['Range'] = 'bytes=0-${_maxManifestProbeSampleBytes - 1}';
}

/// Short user-facing text for a probe failure.
///
/// The old fallback truncated `error.toString()` to 60 characters and shipped
/// it, which put raw exception text -- English drpy messages included -- in the
/// line list.
String _shortError(Object error) {
  if (error is StateError) return error.message;
  final text = error.toString();
  if (text.contains('SocketException')) return '网络不可用，或来源连不上';
  if (text.contains('HandshakeException')) return '安全连接建立失败';
  if (text.contains('ClientException')) return '连接被中断';
  if (text.contains('TimeoutException')) return '连接超时';
  return '暂时连不上';
}
