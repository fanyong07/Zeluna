"""Shared fail-closed activation policy for playback providers."""

from __future__ import annotations

from collections.abc import Iterable
from dataclasses import dataclass


LEGACY_SCRAPER_PROVIDER_IDS = {
    "maccms": "aggregate.maccms",
    "tvbox": "aggregate.tvbox",
    "vod_common": "aggregate.vod",
}


def normalize_provider_ids(values: Iterable[str]) -> frozenset[str]:
    return frozenset(
        value.strip().lower()
        for value in values
        if isinstance(value, str) and value.strip()
    )


def provider_id_for_scraper(name: str) -> str:
    normalized = str(name).strip().lower()
    return LEGACY_SCRAPER_PROVIDER_IDS.get(normalized, f"crawler.{normalized}")


@dataclass(frozen=True)
class ProviderActivationPolicy:
    """Whether a provider has outbound authority in this process."""

    enabled_provider_ids: frozenset[str]
    allow_all: bool = False

    @classmethod
    def from_ids(cls, values: Iterable[str]) -> "ProviderActivationPolicy":
        return cls(normalize_provider_ids(values))

    @classmethod
    def all(cls) -> "ProviderActivationPolicy":
        return cls(frozenset(), allow_all=True)

    def is_enabled(self, provider_id: str) -> bool:
        return self.allow_all or (
            str(provider_id).strip().lower() in self.enabled_provider_ids
        )

    @property
    def has_active_provider(self) -> bool:
        return self.allow_all or bool(self.enabled_provider_ids)
