"""Truthful, request-scoped source discovery state."""

from dataclasses import dataclass
from enum import StrEnum


class SourceDiscoveryStatus(StrEnum):
    NOT_QUERIED = "not_queried"
    SEARCHING = "searching"
    SEARCH_TIMEOUT = "search_timeout"
    SEARCH_ERROR = "search_error"
    SEARCH_MISS = "search_miss"
    SEARCH_HIT_NO_MATCH = "search_hit_no_match"
    MATCHED = "matched"
    MATCHED_NO_EPISODE = "matched_no_episode"
    CIRCUIT_SUPPRESSED = "circuit_suppressed"
    ROUTE_UNAVAILABLE = "route_unavailable"
    CLIENT_PROBE_REQUIRED = "client_probe_required"
    SERVER_VERIFIED = "server_verified"
    QUARANTINED = "quarantined"
    RETIRED = "retired"


@dataclass
class SourceDiscoveryDiagnostic:
    source_name: str
    provider_id: str
    queried: bool = False
    aliases_attempted: int = 0
    search_hit_count: int = 0
    best_match_score: int | None = None
    matched: bool = False
    episode_found: bool | None = None
    status: SourceDiscoveryStatus = SourceDiscoveryStatus.NOT_QUERIED
    error_category: str = ""
    elapsed_ms: int = 0
