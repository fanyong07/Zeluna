"""Health scopes shared by playback resolution and persistence."""

from enum import StrEnum


class SourceFailureScope(StrEnum):
    PROVIDER = "provider"
    ROUTE = "route"
