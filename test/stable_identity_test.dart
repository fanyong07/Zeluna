import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:anime/src/core/identity/stable_identity.dart';

void main() {
  late Map<String, dynamic> fixture;

  setUpAll(() async {
    fixture =
        (jsonDecode(
              await File(
                'test/fixtures/stable_identity_vectors.json',
              ).readAsString(),
            )
            as Map<String, dynamic>);
  });

  test('shared UTF-8 SHA-256 vectors stay fixed', () {
    expect(fixture['version'], stableIdentityVersion);
    for (final vector in _vectors(fixture, 'digests')) {
      expect(stableDigest(vector['input'].toString()), vector['expected']);
    }
  });

  test('subject and episode identities match shared vectors', () {
    for (final vector in _vectors(fixture, 'subjects')) {
      expect(
        stableSubjectKey(
          source: vector['source'].toString(),
          identifier: vector['identifier']!,
        ),
        vector['expected'],
      );
    }
    for (final vector in _vectors(fixture, 'episodes')) {
      expect(
        stableEpisodeKey(
          subjectKey: vector['subjectKey'].toString(),
          normalizedNumber: vector['number']!,
        ),
        vector['expected'],
      );
    }
  });

  test('URI normalization preserves signed query order', () {
    for (final vector in _vectors(fixture, 'uris')) {
      expect(
        canonicalIdentityUri(vector['input'].toString()),
        vector['expected'],
      );
    }
    expect(
      canonicalIdentityUri('https://example.test/v?b=2&a=1'),
      isNot(canonicalIdentityUri('https://example.test/v?a=1&b=2')),
    );
    expect(
      () => canonicalIdentityUri('/relative/video.m3u8'),
      throwsFormatException,
    );
  });

  test('sensitive headers affect only irreversible fingerprints', () {
    for (final vector in _vectors(fixture, 'headers')) {
      final headers = _stringMap(vector['input']);
      final fingerprint = stableHeaderFingerprint(headers);
      expect(fingerprint, vector['expected']);
      expect(fingerprint, isNot(contains('value-one')));
      expect(fingerprint, isNot(contains('session=value-two')));

      final changedRange = {...headers, 'Range': 'bytes=4096-8192'};
      expect(stableHeaderFingerprint(changedRange), fingerprint);
      final changedCredential = {...headers, 'Authorization': 'value-three'};
      expect(stableHeaderFingerprint(changedCredential), isNot(fingerprint));
    }
  });

  test('line, download, rule and int identities match shared vectors', () {
    for (final vector in _vectors(fixture, 'playbackLines')) {
      expect(
        stablePlaybackLineKey(
          providerId: vector['providerId'].toString(),
          episodeKey: vector['episodeKey'].toString(),
          uri: vector['uri'].toString(),
          headers: _stringMap(vector['headers']),
        ),
        vector['expected'],
      );
    }
    for (final vector in _vectors(fixture, 'downloads')) {
      expect(
        stableDownloadTaskKey(
          subjectKey: vector['subjectKey'].toString(),
          episodeKey: vector['episodeKey'].toString(),
          providerId: vector['providerId'].toString(),
        ),
        vector['expected'],
      );
    }
    for (final vector in _vectors(fixture, 'rules')) {
      expect(
        stableRuleKey(
          ruleId: vector['ruleId'].toString(),
          engine: vector['engine'].toString(),
          sourceRepository: vector['sourceRepository'].toString(),
          contentHash: vector['contentHash'].toString(),
        ),
        vector['expected'],
      );
    }
    for (final vector in _vectors(fixture, 'int63')) {
      final value = stableInt63(vector['input'].toString());
      expect(value, vector['expected']);
      expect(value, inInclusiveRange(1, 0x7fffffffffffffff));
    }
  });
}

List<Map<String, dynamic>> _vectors(Map<String, dynamic> fixture, String key) {
  return (fixture[key] as List)
      .whereType<Map>()
      .map((item) => item.cast<String, dynamic>())
      .toList(growable: false);
}

Map<String, String> _stringMap(Object? value) {
  final map = value as Map;
  return {
    for (final entry in map.entries)
      entry.key.toString(): entry.value.toString(),
  };
}
