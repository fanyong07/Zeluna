import '../domain/anime_models.dart';

enum CloudSyncRecordType {
  favorite('favorite'),
  following('following'),
  history('history'),
  playbackPosition('playback_position'),
  appearanceSettings('settings_appearance'),
  playbackSettings('settings_playback');

  const CloudSyncRecordType(this.wireName);

  final String wireName;

  static CloudSyncRecordType parse(Object? value) {
    final name = value?.toString() ?? '';
    return values.firstWhere(
      (item) => item.wireName == name,
      orElse: () => throw const FormatException('Unknown cloud sync type.'),
    );
  }
}

sealed class CloudSyncException implements Exception {
  const CloudSyncException(this.message);

  final String message;

  @override
  String toString() => message;
}

final class CloudSyncAuthenticationException extends CloudSyncException {
  const CloudSyncAuthenticationException()
    : super('Cloud account authentication is unavailable.');
}

final class CloudSyncUnavailableException extends CloudSyncException {
  const CloudSyncUnavailableException()
    : super('Cloud synchronization is temporarily unavailable.');
}

final class CloudSyncProtocolException extends CloudSyncException {
  const CloudSyncProtocolException()
    : super('Cloud synchronization returned an invalid response.');
}

abstract interface class CloudSyncTransport {
  Future<CloudSyncPushResult> push(List<CloudSyncMutation> mutations);

  Future<CloudSyncPullResult> pull({
    required int afterRevision,
    int limit = 200,
  });
}

final class CloudSyncMutation {
  CloudSyncMutation._({
    required this.mutationId,
    required this.type,
    required this.recordId,
    required this.payload,
    required this.deleted,
  });

  factory CloudSyncMutation.library({
    required String mutationId,
    required CloudSyncRecordType type,
    required LibraryEntry entry,
    bool deleted = false,
  }) {
    if (type != CloudSyncRecordType.favorite &&
        type != CloudSyncRecordType.following &&
        type != CloudSyncRecordType.history) {
      throw ArgumentError.value(type, 'type', 'Expected a library type.');
    }
    return CloudSyncMutation._checked(
      mutationId: mutationId,
      type: type,
      recordId: entry.subject.identityKey,
      payload: _libraryPayload(entry),
      deleted: deleted,
    );
  }

  factory CloudSyncMutation.playbackPosition({
    required String mutationId,
    required LibraryEntry entry,
  }) {
    final episode = entry.episode;
    if (episode == null) {
      throw ArgumentError.value(
        entry,
        'entry',
        'Playback requires an episode.',
      );
    }
    final duration = entry.durationSeconds < 0 ? 0 : entry.durationSeconds;
    final position = entry.positionSeconds < 0 ? 0 : entry.positionSeconds;
    final completed = position == 0 && duration > 0;
    return CloudSyncMutation._checked(
      mutationId: mutationId,
      type: CloudSyncRecordType.playbackPosition,
      recordId: episode.identityKey(subjectKey: entry.subject.identityKey),
      payload: {
        'subject': _subjectPayload(entry.subject),
        'episode': _episodePayload(episode, entry.subject.identityKey),
        'updatedAt': entry.updatedAt.toUtc().toIso8601String(),
        'positionSeconds': completed ? 0 : position,
        'durationSeconds': duration,
        'completed': completed,
      },
      deleted: false,
    );
  }

  factory CloudSyncMutation.appearance({
    required String mutationId,
    required AppearanceSettings settings,
  }) => CloudSyncMutation._checked(
    mutationId: mutationId,
    type: CloudSyncRecordType.appearanceSettings,
    recordId: 'settings:appearance',
    payload: settings.toJson(),
    deleted: false,
  );

  factory CloudSyncMutation.playbackSettings({
    required String mutationId,
    required PlaybackSettings settings,
  }) => CloudSyncMutation._checked(
    mutationId: mutationId,
    type: CloudSyncRecordType.playbackSettings,
    recordId: 'settings:playback',
    payload: _playbackSettingsPayload(settings),
    deleted: false,
  );

  factory CloudSyncMutation.fromJson(Map<String, dynamic> json) =>
      CloudSyncMutation._checked(
        mutationId: json['mutationId']?.toString() ?? '',
        type: CloudSyncRecordType.parse(json['type']),
        recordId: json['recordId']?.toString() ?? '',
        payload: _sanitizePayload(
          CloudSyncRecordType.parse(json['type']),
          json['payload'],
        ),
        deleted: json['deleted'] as bool? ?? false,
      );

  factory CloudSyncMutation._checked({
    required String mutationId,
    required CloudSyncRecordType type,
    required String recordId,
    required Map<String, dynamic> payload,
    required bool deleted,
  }) {
    _validateMutationId(mutationId);
    _validateRecordIdentity(type, recordId, payload);
    return CloudSyncMutation._(
      mutationId: mutationId,
      type: type,
      recordId: recordId,
      payload: Map<String, dynamic>.unmodifiable(payload),
      deleted: deleted,
    );
  }

  final String mutationId;
  final CloudSyncRecordType type;
  final String recordId;
  final Map<String, dynamic> payload;
  final bool deleted;

  Map<String, dynamic> toJson() => {
    'mutationId': mutationId,
    'type': type.wireName,
    'recordId': recordId,
    'schemaVersion': 1,
    'deleted': deleted,
    'payload': payload,
  };
}

final class CloudSyncRecord {
  CloudSyncRecord._({
    required this.type,
    required this.recordId,
    required this.payload,
    required this.deleted,
    required this.clientMutationId,
    required this.serverRevision,
  });

  factory CloudSyncRecord.fromJson(Map<String, dynamic> json) {
    final type = CloudSyncRecordType.parse(json['type']);
    final recordId = json['record_id']?.toString() ?? '';
    final payload = _sanitizePayload(type, json['payload']);
    _validateRecordIdentity(type, recordId, payload);
    final revision = _boundedInt(json['server_revision'], min: 1);
    final mutationId = json['client_mutation_id']?.toString() ?? '';
    _validateMutationId(mutationId);
    return CloudSyncRecord._(
      type: type,
      recordId: recordId,
      payload: Map<String, dynamic>.unmodifiable(payload),
      deleted: json['deleted'] as bool? ?? false,
      clientMutationId: mutationId,
      serverRevision: revision,
    );
  }

  final CloudSyncRecordType type;
  final String recordId;
  final Map<String, dynamic> payload;
  final bool deleted;
  final String clientMutationId;
  final int serverRevision;
}

final class CloudSyncPushResult {
  const CloudSyncPushResult({
    required this.acknowledged,
    required this.nextRevision,
  });

  factory CloudSyncPushResult.fromJson(Map<String, dynamic> json) {
    final raw = json['acknowledged'];
    if (raw is! List || raw.length > 100) {
      throw const FormatException('Invalid cloud sync acknowledgement list.');
    }
    return CloudSyncPushResult(
      acknowledged: List<CloudSyncRecord>.unmodifiable(
        raw.map((item) => CloudSyncRecord.fromJson(_stringMap(item))),
      ),
      nextRevision: _boundedInt(json['next_revision'], min: 0),
    );
  }

  final List<CloudSyncRecord> acknowledged;
  final int nextRevision;
}

final class CloudSyncPullResult {
  const CloudSyncPullResult({
    required this.records,
    required this.nextRevision,
  });

  factory CloudSyncPullResult.fromJson(Map<String, dynamic> json) {
    final raw = json['records'];
    if (raw is! List || raw.length > 500) {
      throw const FormatException('Invalid cloud sync record list.');
    }
    return CloudSyncPullResult(
      records: List<CloudSyncRecord>.unmodifiable(
        raw.map((item) => CloudSyncRecord.fromJson(_stringMap(item))),
      ),
      nextRevision: _boundedInt(json['next_revision'], min: 0),
    );
  }

  final List<CloudSyncRecord> records;
  final int nextRevision;
}

Map<String, dynamic> _sanitizePayload(CloudSyncRecordType type, Object? value) {
  final json = _stringMap(value);
  return switch (type) {
    CloudSyncRecordType.favorite ||
    CloudSyncRecordType.following ||
    CloudSyncRecordType.history => _libraryPayload(LibraryEntry.fromJson(json)),
    CloudSyncRecordType.playbackPosition => _playbackPositionPayload(json),
    CloudSyncRecordType.appearanceSettings => AppearanceSettings.fromJson(
      json,
    ).toJson(),
    CloudSyncRecordType.playbackSettings => _playbackSettingsPayload(
      PlaybackSettings.fromJson(json),
    ),
  };
}

Map<String, dynamic> _libraryPayload(LibraryEntry entry) => {
  'subject': _subjectPayload(entry.subject),
  'episode': entry.episode == null
      ? null
      : _episodePayload(entry.episode!, entry.subject.identityKey),
  'updatedAt': entry.updatedAt.toUtc().toIso8601String(),
  'note': _boundedString(entry.note, 2000),
  'positionSeconds': entry.positionSeconds < 0 ? 0 : entry.positionSeconds,
  'durationSeconds': entry.durationSeconds < 0 ? 0 : entry.durationSeconds,
};

Map<String, dynamic> _playbackPositionPayload(Map<String, dynamic> json) {
  final subject = AnimeSubject.fromJson(_stringMap(json['subject']));
  final episode = AnimeEpisode.fromJson(_stringMap(json['episode']));
  final updatedAt = DateTime.tryParse(json['updatedAt']?.toString() ?? '');
  if (updatedAt == null) throw const FormatException('Invalid sync timestamp.');
  final duration = _boundedInt(json['durationSeconds'], min: 0);
  final completed = json['completed'] as bool? ?? false;
  var position = _boundedInt(json['positionSeconds'], min: 0);
  if (completed) position = 0;
  if (!completed && position > 0 && duration == 0) {
    throw const FormatException('Playback duration is required.');
  }
  return {
    'subject': _subjectPayload(subject),
    'episode': _episodePayload(episode, subject.identityKey),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'positionSeconds': position,
    'durationSeconds': duration,
    'completed': completed,
  };
}

Map<String, dynamic> _subjectPayload(AnimeSubject subject) {
  final title = _boundedString(subject.title, 500).trim();
  final source = _boundedString(subject.source, 120).trim();
  final stableKey = subject.identityKey.trim();
  if (title.isEmpty ||
      source.isEmpty ||
      stableKey.isEmpty ||
      stableKey.length > 300) {
    throw const FormatException('Invalid subject sync identity.');
  }
  return {
    'id': subject.id < 0 ? 0 : subject.id,
    'title': title,
    'originalTitle': _boundedString(subject.originalTitle, 500),
    'summary': _boundedString(subject.summary, 10000),
    'coverUrl': _nullableBoundedString(subject.coverUrl, 1000),
    'bannerUrl': _nullableBoundedString(subject.bannerUrl, 1000),
    'date': _nullableBoundedString(subject.date, 40),
    'platform': _boundedString(subject.platform, 40),
    'language': _boundedString(subject.language, 40),
    'region': _boundedString(subject.region, 80),
    'status': _boundedString(subject.status, 80),
    'categories': subject.categories
        .take(50)
        .map((item) => _namedImagePayload(item.name, item.count, item.imageUrl))
        .toList(growable: false),
    'tags': subject.tags
        .take(100)
        .map((item) => _namedImagePayload(item.name, item.count, item.imageUrl))
        .toList(growable: false),
    'totalEpisodes': subject.totalEpisodes.clamp(0, 100000),
    'ratingScore': subject.ratingScore == null || !subject.ratingScore!.isFinite
        ? null
        : subject.ratingScore!.clamp(0, double.infinity),
    'ratingRank': subject.ratingRank?.clamp(0, 0x7fffffff),
    'ratingTotal': subject.ratingTotal?.clamp(0, 0x7fffffff),
    'source': source,
    'stableKey': stableKey,
    if (subject.legacyId != null) 'legacyId': subject.legacyId,
    if (subject.legacyIds.isNotEmpty)
      'legacyIds': subject.legacyIds.take(50).toList(growable: false),
  };
}

Map<String, dynamic> _episodePayload(AnimeEpisode episode, String subjectKey) {
  final stableKey = episode.identityKey(subjectKey: subjectKey).trim();
  if (stableKey.isEmpty || stableKey.length > 300) {
    throw const FormatException('Invalid episode sync identity.');
  }
  return {
    'id': episode.id < 0 ? 0 : episode.id,
    'subjectId': episode.subjectId < 0 ? 0 : episode.subjectId,
    'number': episode.number.clamp(0, 100000),
    'title': _boundedString(episode.title, 500),
    'airdate': _nullableBoundedString(episode.airdate, 40),
    'duration': _boundedString(episode.duration, 40),
    'description': _boundedString(episode.description, 10000),
    'thumbnailUrl': _nullableBoundedString(episode.thumbnailUrl, 1000),
    'stableKey': stableKey,
    if (episode.legacyId != null) 'legacyId': episode.legacyId,
  };
}

Map<String, dynamic> _namedImagePayload(
  String name,
  int count,
  String? imageUrl,
) => {
  'name': _boundedString(name, 120),
  'count': count < 0 ? 0 : count,
  'imageUrl': _nullableBoundedString(imageUrl, 1000),
};

Map<String, dynamic> _playbackSettingsPayload(PlaybackSettings settings) => {
  'volumeBoost': settings.volumeBoost.clamp(0, 2),
  'superResolution': settings.superResolution,
  'superResolutionProfile': _boundedString(settings.superResolutionProfile, 40),
  'superResolutionCustomShaders': settings.superResolutionCustomShaders
      .where((item) => item.isNotEmpty)
      .map((item) => _boundedString(item, 160))
      .take(64)
      .toList(growable: false),
  'videoScale': _boundedString(settings.videoScale, 40),
  'speed': settings.speed.clamp(0.25, 4),
  'defaultSpeed': settings.defaultSpeed.clamp(0.25, 4),
  'holdSpeed': settings.holdSpeed.clamp(0.25, 8),
  'edgeDoubleTap': settings.edgeDoubleTap,
  'rewindSeconds': settings.rewindSeconds.clamp(1, 600),
  'forwardSeconds': settings.forwardSeconds.clamp(1, 600),
  'compatibilityMode': settings.compatibilityMode,
  'autoNext': settings.autoNext,
  'autoSwitchLine': settings.autoSwitchLine,
  'autoFullscreen': settings.autoFullscreen,
  'rememberLine': settings.rememberLine,
  'keyboardShortcutsEnabled': settings.keyboardShortcutsEnabled,
  'shortcutPlayPause': settings.shortcutPlayPause,
  'shortcutSeek': settings.shortcutSeek,
  'shortcutVolume': settings.shortcutVolume,
  'shortcutFullscreen': settings.shortcutFullscreen,
  'shortcutMute': settings.shortcutMute,
  'shortcutReload': settings.shortcutReload,
};

void _validateMutationId(String value) {
  if (value.length < 16 ||
      value.length > 100 ||
      !RegExp(r'^[A-Za-z0-9:_-]+$').hasMatch(value)) {
    throw const FormatException('Invalid cloud sync mutation identity.');
  }
}

void _validateRecordIdentity(
  CloudSyncRecordType type,
  String recordId,
  Map<String, dynamic> payload,
) {
  if (recordId.isEmpty || recordId.length > 300) {
    throw const FormatException('Invalid cloud sync record identity.');
  }
  final expected = switch (type) {
    CloudSyncRecordType.appearanceSettings => 'settings:appearance',
    CloudSyncRecordType.playbackSettings => 'settings:playback',
    CloudSyncRecordType.playbackPosition =>
      _stringMap(payload['episode'])['stableKey']?.toString() ?? '',
    _ => _stringMap(payload['subject'])['stableKey']?.toString() ?? '',
  };
  if (recordId != expected) {
    throw const FormatException('Cloud sync record identity mismatch.');
  }
}

Map<String, dynamic> _stringMap(Object? value) {
  if (value is! Map) throw const FormatException('Expected a JSON object.');
  return value.map((key, value) => MapEntry(key.toString(), value));
}

int _boundedInt(Object? value, {required int min}) {
  if (value is! num || !value.isFinite) {
    throw const FormatException('Expected a finite integer.');
  }
  final integer = value.toInt();
  if (integer != value || integer < min) {
    throw const FormatException('Integer is outside the allowed range.');
  }
  return integer;
}

String _boundedString(String value, int maxLength) =>
    value.length <= maxLength ? value : value.substring(0, maxLength);

String? _nullableBoundedString(String? value, int maxLength) =>
    value == null ? null : _boundedString(value, maxLength);
