import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../core/network/network_http_client.dart';
import '../../core/network/network_security.dart';
import '../../data/zeluna_backend_playback_repository.dart';
import '../../domain/anime_models.dart';
import '../../domain/subject_content_type.dart';
import 'subtitle_document.dart';

class SupplementalSubtitleCandidate {
  const SupplementalSubtitleCandidate({
    required this.id,
    required this.provider,
    required this.entryId,
    required this.fileName,
    required this.language,
    required this.autoMatch,
    required this.reasons,
  });
  final String id;
  final String provider;
  final String entryId;
  final String fileName;
  final String language;
  final bool autoMatch;
  final List<String> reasons;
  factory SupplementalSubtitleCandidate.fromJson(Map<String, dynamic> json) =>
      SupplementalSubtitleCandidate(
        id: json['id'] as String,
        provider: json['provider'] as String,
        entryId: json['entry_id'] as String,
        fileName: json['file_name'] as String,
        language: json['language'] as String,
        autoMatch: json['auto_match'] == true,
        reasons: (json['reasons'] as List? ?? []).whereType<String>().toList(),
      );
}

class SubtitleSearchResult {
  const SubtitleSearchResult(
    this.status,
    this.message, [
    this.candidates = const [],
  ]);
  final String status;
  final String message;
  final List<SupplementalSubtitleCandidate> candidates;
}

class SubtitleRepository {
  SubtitleRepository(ExternalServiceSettings settings, {http.Client? client}) {
    final service = settings.playbackBackendSelfHosted
        ? NetworkServiceKind.selfHostedPlaybackBackend
        : NetworkServiceKind.officialPlaybackBackend;
    _baseUri = settings.playbackBackendEnabled
        ? ZelunaBackendPlaybackRepository.normalizeBaseUrl(
            settings.playbackBackendEndpoint,
            service: service,
            allowInsecureSelfHosted: settings.allowInsecurePlaybackBackend,
          )
        : null;
    final policy = NetworkRequestPolicy.forService(
      service,
      allowInsecureSelfHosted: settings.allowInsecurePlaybackBackend,
    );
    _client = client == null
        ? createNetworkHttpClient(policy)
        : PolicyHttpClient(inner: client, ownsInner: false, policy: policy);
  }
  late final Uri? _baseUri;
  late final http.Client _client;
  Uri _endpoint(String suffix) => _baseUri!.replace(
    pathSegments: [
      ..._baseUri.pathSegments.where((value) => value.isNotEmpty),
      'api',
      'v3',
      'subtitles',
      ...suffix.split('/'),
    ],
    query: null,
    fragment: null,
  );

  Future<SubtitleSearchResult> search(
    AnimeSubject subject,
    AnimeEpisode episode,
    String language, {
    String? confirmedEntryId,
  }) async {
    if (_baseUri == null) {
      return const SubtitleSearchResult('manual_required', '在线服务未启用，可以直接导入字幕');
    }
    try {
      final response = await _client
          .post(
            _endpoint('search'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'subject_key': subject.identityKey,
              'episode_key': episode.identityKey(
                subjectKey: subject.identityKey,
              ),
              'title': subject.title,
              'original_title': subject.originalTitle,
              'media_type': subjectContentTypeOf(subject).name,
              'aliases': <String>{
                subject.title,
                subject.originalTitle,
              }.where((s) => s.trim().isNotEmpty).toList(),
              'year': int.tryParse(subject.year),
              'episode_number': episode.number,
              'season_number': episode.seasonNumber,
              'season_episode_number': episode.seasonEpisodeNumber,
              'language': language,
              'confirmed_entry_id': confirmedEntryId,
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 404 || response.statusCode == 405) {
        return const SubtitleSearchResult(
          'manual_required',
          '当前服务尚未支持字幕检索，手动导入不受影响',
        );
      }
      if (response.statusCode != 200) {
        return const SubtitleSearchResult(
          'provider_unavailable',
          '字幕检索暂时不可用，请稍后重试或手动导入',
        );
      }
      if (response.bodyBytes.length > 1024 * 1024) {
        throw const FormatException();
      }
      final json =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      return SubtitleSearchResult(
        json['status'] as String,
        json['message'] as String,
        (json['candidates'] as List? ?? [])
            .whereType<Map>()
            .map(
              (item) => SupplementalSubtitleCandidate.fromJson(
                item.cast<String, dynamic>(),
              ),
            )
            .toList(),
      );
    } catch (_) {
      return const SubtitleSearchResult(
        'provider_unavailable',
        '字幕检索连接失败，现有播放不受影响；可以手动导入',
      );
    }
  }

  Future<SubtitleDocument> download(
    SupplementalSubtitleCandidate candidate,
  ) async {
    if (_baseUri == null || !RegExp(r'^[a-f0-9]{32}$').hasMatch(candidate.id)) {
      throw const SubtitleFileException('字幕候选已失效，请重新查找');
    }
    try {
      return await (() async {
        final response = await _client.send(
          http.Request('GET', _endpoint('${candidate.id}/content')),
        );
        if (response.statusCode != 200) {
          await response.stream.drain<void>();
          throw const SubtitleFileException('字幕下载失败或候选已过期，请重新查找');
        }
        final builder = BytesBuilder(copy: false);
        await for (final chunk in response.stream) {
          if (builder.length + chunk.length > maxSubtitleBytes) {
            throw const SubtitleFileException('字幕文件超过 5 MB');
          }
          builder.add(chunk);
        }
        return parseSubtitle(
          builder.takeBytes(),
          candidate.fileName,
          candidate.language,
        );
      })().timeout(const Duration(seconds: 15));
    } on SubtitleFileException {
      rethrow;
    } catch (_) {
      throw const SubtitleFileException('字幕下载连接失败，请重试或手动导入');
    }
  }

  void dispose() => _client.close();
}
