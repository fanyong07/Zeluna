import '../domain/anime_models.dart';
import '../recommendations/recommendation_models.dart';

int comparePopularCatalogCandidates(
  CatalogCandidate first,
  CatalogCandidate second,
) {
  final byScore = _catalogPopularityScore(
    second,
  ).compareTo(_catalogPopularityScore(first));
  return byScore != 0 ? byScore : first.workKey.compareTo(second.workKey);
}

int compareTopRatedCatalogCandidates(
  CatalogCandidate first,
  CatalogCandidate second,
) {
  final byRating = (second.subject.ratingScore ?? -1).compareTo(
    first.subject.ratingScore ?? -1,
  );
  if (byRating != 0) return byRating;
  final byVotes = (second.subject.ratingTotal ?? 0).compareTo(
    first.subject.ratingTotal ?? 0,
  );
  return byVotes != 0 ? byVotes : first.workKey.compareTo(second.workKey);
}

int compareLatestCatalogCandidates(
  CatalogCandidate first,
  CatalogCandidate second,
) {
  final firstDate = _catalogDate(first.subject);
  final secondDate = _catalogDate(second.subject);
  if (firstDate != null || secondDate != null) {
    if (firstDate == null) return 1;
    if (secondDate == null) return -1;
    final byDate = secondDate.compareTo(firstDate);
    if (byDate != 0) return byDate;
  }
  return comparePopularCatalogCandidates(first, second);
}

DateTime? _catalogDate(AnimeSubject subject) {
  final raw = subject.date?.trim() ?? '';
  final parsed = DateTime.tryParse(raw);
  if (parsed != null) return parsed;
  final year = int.tryParse(subject.year);
  return year == null ? null : DateTime.utc(year);
}

double _catalogPopularityScore(CatalogCandidate candidate) {
  final chart = candidate.evidence.chartScore;
  if (chart > 0) return chart;
  final rating = ((candidate.subject.ratingScore ?? 0) / 10).clamp(0.0, 1.0);
  final votes = candidate.subject.ratingTotal ?? 0;
  final voteConfidence = votes <= 0 ? 0.0 : votes / (votes + 500);
  return (rating * 0.8 + voteConfidence * 0.2).clamp(0.0, 1.0);
}
