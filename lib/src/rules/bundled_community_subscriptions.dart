import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../core/network/network_http_client.dart';
import '../core/network/network_security.dart';
import 'rule_models.dart';

final bundledCommunitySubscriptionRepositoryProvider =
    Provider<BundledCommunitySubscriptionRepository>(
      (ref) => BundledCommunitySubscriptionRepository(),
    );

const _managedInternalUrlPrefix = 'zeluna://managed/';

String _normalizeSubscriptionUrl(String url) {
  final trimmed = url.trim().toLowerCase();
  if (trimmed.isEmpty) return '';
  return trimmed.replaceFirst(RegExp(r'/+$'), '');
}

/// Whether [url] uses Zeluna's internal managed namespace.
bool isBundledCommunitySubscriptionUrl(String url) {
  final normalized = _normalizeSubscriptionUrl(url);
  return normalized.startsWith(_managedInternalUrlPrefix);
}

/// Whether [record] was provisioned by the online service's managed bootstrap
/// and should stay hidden from user-facing rule lists while remaining active
/// in the playback engine.
bool isManagedInternalRepository(RuleRepositoryRecord record) {
  return record.managedInternal ||
      isBundledCommunitySubscriptionUrl(record.url);
}

/// Whether [rule] was provisioned by an internal managed subscription and
/// should stay hidden from user-facing rule lists while remaining active in
/// the playback engine.
bool isBundledCommunityRule(
  RulePlugin rule, {
  Iterable<RuleRepositoryRecord> repositories = const [],
}) {
  if (rule.managedInternal) return true;
  final manifestRepo = _normalizeSubscriptionUrl(
    rule.permissionManifest?.sourceRepository ?? '',
  );
  if (manifestRepo.startsWith(_managedInternalUrlPrefix)) return true;
  final effectiveRepo = _normalizeSubscriptionUrl(
    rule.effectiveManifest.sourceRepository,
  );
  if (effectiveRepo.startsWith(_managedInternalUrlPrefix)) return true;

  if (repositories.isNotEmpty) {
    final managedUrls = <String>{
      for (final record in repositories)
        if (isManagedInternalRepository(record))
          _normalizeSubscriptionUrl(record.url),
    }..remove('');
    if (managedUrls.isNotEmpty) {
      if (managedUrls.contains(manifestRepo) ||
          managedUrls.contains(effectiveRepo)) {
        return true;
      }
      final note = rule.note.trim().toLowerCase();
      if (note.isNotEmpty && managedUrls.any(note.contains)) {
        return true;
      }
    }
  }
  return false;
}

/// Filters out internal managed subscription records for settings UI.
List<RuleRepositoryRecord> visibleUserRuleRepositories(
  Iterable<RuleRepositoryRecord> repositories,
) {
  return repositories
      .where((record) => !isManagedInternalRepository(record))
      .toList(growable: false);
}

/// Filters out rules provisioned by internal managed subscriptions for
/// settings UI while leaving them active for playback lookup.
List<RulePlugin> visibleUserRules(
  Iterable<RulePlugin> rules, {
  Iterable<RuleRepositoryRecord> repositories = const [],
}) {
  return rules
      .where(
        (rule) => !isBundledCommunityRule(rule, repositories: repositories),
      )
      .toList(growable: false);
}

/// Current minimum revision expected from the remote rule bootstrap endpoint.
const currentCommunitySubscriptionSeedVersion = 3;

class BundledCommunitySubscriptionSeed {
  const BundledCommunitySubscriptionSeed({
    required this.version,
    required this.generatedAt,
    required this.bundles,
    this.includeOptionalBuiltInRules = false,
  });

  const BundledCommunitySubscriptionSeed.empty()
    : version = 0,
      generatedAt = null,
      bundles = const [],
      includeOptionalBuiltInRules = false;

  final int version;
  final DateTime? generatedAt;
  final List<RuleImportBundle> bundles;
  final bool includeOptionalBuiltInRules;

  bool get isEmpty => bundles.isEmpty && !includeOptionalBuiltInRules;

  factory BundledCommunitySubscriptionSeed.fromJson(Map<String, dynamic> json) {
    final version = switch (json['version']) {
      int value => value,
      num value => value.round(),
      _ => 0,
    };
    final generatedAt = DateTime.tryParse(
      json['generatedAt']?.toString() ?? '',
    );
    final rawSubscriptions = json['subscriptions'];
    final bundles = <RuleImportBundle>[];
    if (rawSubscriptions is List) {
      for (final entry in rawSubscriptions.whereType<Map>()) {
        final map = entry.cast<String, dynamic>();
        final name = map['name']?.toString().trim() ?? '';
        final sourceUrl = map['sourceUrl']?.toString().trim() ?? '';
        final managedInternal = map['managedInternal'] != false;
        final rawRules = map['rules'];
        if (name.isEmpty || sourceUrl.isEmpty || rawRules is! List) continue;
        final rules = rawRules
            .whereType<Map>()
            .map((item) => RulePlugin.fromJson(item.cast<String, dynamic>()))
            .where(
              (rule) =>
                  rule.id.trim().isNotEmpty && rule.name.trim().isNotEmpty,
            )
            .map(
              (rule) => managedInternal && !rule.managedInternal
                  ? rule.copyWith(managedInternal: true)
                  : rule,
            )
            .toList(growable: false);
        if (rules.isEmpty) continue;
        bundles.add(
          RuleImportBundle(
            name: name,
            sourceUrl: sourceUrl,
            rules: List<RulePlugin>.unmodifiable(rules),
            managedInternal: managedInternal,
          ),
        );
      }
    }
    return BundledCommunitySubscriptionSeed(
      version: version,
      generatedAt: generatedAt,
      bundles: List<RuleImportBundle>.unmodifiable(bundles),
      includeOptionalBuiltInRules: json['includeOptionalBuiltInRules'] == true,
    );
  }
}

BundledCommunitySubscriptionSeed _parseBundledCommunitySubscriptionSeed(
  String text,
) {
  final decoded = jsonDecode(text);
  if (decoded is! Map) {
    throw const FormatException('rules bootstrap root is not an object');
  }
  return BundledCommunitySubscriptionSeed.fromJson(
    decoded.cast<String, dynamic>(),
  );
}

/// Fetches managed default rules silently from the configured online service's
/// `/api/v3/rules/bootstrap` endpoint so the open-source client stays free of
/// embedded third-party site catalogs.
class BundledCommunitySubscriptionRepository {
  BundledCommunitySubscriptionRepository({
    http.Client? client,
    this.timeout = const Duration(seconds: 6),
    this.bootstrapPath = '/api/v3/rules/bootstrap',
  }) : _client = client;

  final http.Client? _client;
  final Duration timeout;
  final String bootstrapPath;
  final Map<String, BundledCommunitySubscriptionSeed> _cachedByBaseUrl = {};

  /// Whether [SourceController.loadForAccount] should wait on [loadSeed]
  /// even if the account already cached an earlier seed revision.
  bool get alwaysFetchOnStartup => false;

  Future<BundledCommunitySubscriptionSeed> loadSeed({
    String? backendBaseUrl,
    http.Client? client,
    bool forceRefresh = false,
  }) async {
    final normalizedBase = (backendBaseUrl ?? '').trim().replaceFirst(
      RegExp(r'/+$'),
      '',
    );
    if (normalizedBase.isEmpty) {
      return const BundledCommunitySubscriptionSeed.empty();
    }
    if (!forceRefresh) {
      final cached = _cachedByBaseUrl[normalizedBase];
      if (cached != null) return cached;
    }
    final uri = Uri.tryParse('$normalizedBase$bootstrapPath');
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return const BundledCommunitySubscriptionSeed.empty();
    }
    final effectiveClient = client ?? _client;
    final ownedClient = effectiveClient == null;
    final activeClient =
        effectiveClient ??
        createNetworkHttpClient(
          NetworkRequestPolicy.forService(NetworkServiceKind.metadataApi),
        );
    try {
      final response = await activeClient
          .get(uri, headers: const {'Accept': 'application/json'})
          .timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return const BundledCommunitySubscriptionSeed.empty();
      }
      final body = utf8.decode(response.bodyBytes, allowMalformed: false);
      final seed = await compute(_parseBundledCommunitySubscriptionSeed, body);
      if (!seed.isEmpty) {
        _cachedByBaseUrl[normalizedBase] = seed;
      }
      return seed;
    } catch (_) {
      return const BundledCommunitySubscriptionSeed.empty();
    } finally {
      if (ownedClient) activeClient.close();
    }
  }
}

class EmptyBundledCommunitySubscriptionRepository
    extends BundledCommunitySubscriptionRepository {
  EmptyBundledCommunitySubscriptionRepository();

  @override
  Future<BundledCommunitySubscriptionSeed> loadSeed({
    String? backendBaseUrl,
    http.Client? client,
    bool forceRefresh = false,
  }) async => const BundledCommunitySubscriptionSeed.empty();
}
