import '../core/identity/stable_identity.dart';
import '../domain/anime_models.dart';
import '../domain/subject_content_type.dart';

/// Returns a provider-neutral, privacy-safe key used only by recommendation
/// ranking and de-duplication.
///
/// Explicit cross-provider identifiers win, followed by the provider's stable
/// identity. Title, release year and content type are only a conservative
/// fallback for records without a stable source identity. Raw values are
/// hashed and never appear in the key.
String canonicalWorkKey(
  AnimeSubject subject, {
  Map<String, String> externalIds = const <String, String>{},
}) {
  final normalizedIds = <String, String>{
    for (final entry in externalIds.entries)
      _normalizeExternalIdName(entry.key): entry.value.trim().toLowerCase(),
  }..removeWhere((key, value) => key.isEmpty || value.isEmpty);

  final imdb = normalizedIds['imdb'];
  if (imdb != null) return _externalWorkKey('imdb', imdb);

  final tmdbMovie = normalizedIds['tmdb:movie'];
  if (tmdbMovie != null) return _externalWorkKey('tmdb:movie', tmdbMovie);
  final tmdbTv = normalizedIds['tmdb:tv'];
  if (tmdbTv != null) return _externalWorkKey('tmdb:tv', tmdbTv);

  final sourceIdentity = _sourceExternalIdentity(subject);
  if (sourceIdentity != null) {
    return _externalWorkKey(sourceIdentity.$1, sourceIdentity.$2);
  }
  final title = _normalizeWorkTitle(
    subject.originalTitle.trim().isNotEmpty
        ? subject.originalTitle
        : subject.title,
  );
  final year = _releaseYear(subject.date);
  final contentType = subjectContentTypeOf(subject).name;
  if (title.isNotEmpty && year != null) {
    return 'work:$stableIdentityVersion:${stableDigest('work|$stableIdentityVersion|title:$title|year:$year|type:$contentType')}';
  }

  if (title.isNotEmpty) {
    return 'work:$stableIdentityVersion:${stableDigest('work|$stableIdentityVersion|title:$title|type:$contentType')}';
  }
  return 'work:$stableIdentityVersion:${stableDigest('work|$stableIdentityVersion|subject:${subject.identityKey}')}';
}

String _externalWorkKey(String provider, String identifier) =>
    'work:$stableIdentityVersion:${stableDigest('work|$stableIdentityVersion|$provider|$identifier')}';

(String, String)? _sourceExternalIdentity(AnimeSubject subject) {
  final source = subject.source.trim().toLowerCase();
  final parts = source.split(':');
  if (parts.firstOrNull == 'tmdb') {
    final type = parts.length >= 2
        ? switch (parts[1]) {
            'series' => 'tv',
            final value => value,
          }
        : '';
    final id = parts.length >= 3 ? parts[2] : '${subject.id}';
    if ((type == 'tv' || type == 'movie') && id.isNotEmpty) {
      return ('tmdb:$type', id);
    }
  }
  if (source == 'bangumi' || parts.firstOrNull == 'bangumi') {
    final id = parts.length >= 2 ? parts[1] : '${subject.id}';
    if (id.isNotEmpty) return ('bangumi', id);
  }
  return null;
}

String _normalizeExternalIdName(String value) {
  final normalized = value.trim().toLowerCase().replaceAll('_', ':');
  return switch (normalized) {
    'imdbid' || 'imdb:id' => 'imdb',
    'tmdbmovie' || 'tmdb:film' || 'tmdb:movie:id' => 'tmdb:movie',
    'tmdbtv' || 'tmdb:series' || 'tmdb:show' || 'tmdb:tv:id' => 'tmdb:tv',
    _ => normalized,
  };
}

String _normalizeWorkTitle(String value) =>
    value.trim().toLowerCase().replaceAll(
      RegExp(
        r'''[\s\-_.,:;!?/\\|()\[\]{}<>~`'"·・—–…，。！？：；（）【】《》「」『』、]+''',
        unicode: true,
      ),
      '',
    );

int? _releaseYear(String? value) {
  final match = RegExp(
    r'(^|\D)((?:19|20)\d{2})(?:\D|$)',
  ).firstMatch(value?.trim() ?? '');
  return int.tryParse(match?.group(2) ?? '');
}
