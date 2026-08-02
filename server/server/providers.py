"""Structural provider contracts and safe server-side registrations."""

from __future__ import annotations

import asyncio
import re
from dataclasses import dataclass
from typing import Protocol

from .scrapers.base import SubjectDetail, SubjectResult, VideoLine

_IDENTIFIER = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")
_CONTENT_TYPES = frozenset({"anime", "series", "movie"})
_CAPABILITY_METHODS = {
    "search": "search",
    "detail": "get_detail",
    "resolve": "get_video_urls",
    "latest": "get_latest",
    "home": "get_home",
}
_PRIVATE_METADATA_MARKERS = ("://", "authorization", "cookie", "header", "token")


class MediaProvider(Protocol):
    """Minimum adapter surface consumed by the aggregation domain."""

    @property
    def content_types(self) -> list[str]: ...

    async def search(self, keyword: str) -> list[SubjectResult]: ...

    async def get_detail(self, source_id: str) -> SubjectDetail | None: ...

    async def get_video_urls(
        self,
        source_id: str,
        episode: int = 1,
    ) -> list[VideoLine]: ...

    async def get_latest(self, page: int = 1) -> list[SubjectResult]: ...

    async def get_home(self) -> list[SubjectResult]: ...

    async def aclose(self) -> None: ...


@dataclass(frozen=True)
class ProviderMetadata:
    """Non-sensitive metadata safe for diagnostics and contract checks."""

    provider_id: str
    family: str
    display_name: str
    content_types: tuple[str, ...]
    capabilities: tuple[str, ...]

    def as_public_dict(self) -> dict[str, object]:
        return {
            "id": self.provider_id,
            "family": self.family,
            "display_name": self.display_name,
            "content_types": list(self.content_types),
            "capabilities": list(self.capabilities),
        }


@dataclass(frozen=True)
class RegisteredProvider:
    metadata: ProviderMetadata
    adapter: MediaProvider


class ProviderRegistry:
    """Validate and own provider adapters without publishing their internals."""

    def __init__(self) -> None:
        self._registrations: dict[str, RegisteredProvider] = {}

    def register(
        self,
        *,
        provider_id: str,
        family: str,
        display_name: str,
        adapter: MediaProvider,
        capabilities: tuple[str, ...] = ("search", "detail", "resolve", "latest"),
    ) -> RegisteredProvider:
        provider_id = provider_id.strip().lower()
        family = family.strip().lower()
        display_name = display_name.strip()
        if not _IDENTIFIER.fullmatch(provider_id):
            raise ValueError(f"Invalid provider id: {provider_id!r}")
        if not _IDENTIFIER.fullmatch(family):
            raise ValueError(f"Invalid provider family: {family!r}")
        if provider_id in self._registrations:
            raise ValueError(f"Duplicate provider id: {provider_id}")
        lowered_display_name = display_name.casefold()
        if (
            not display_name
            or len(display_name) > 80
            or any(
                marker in lowered_display_name for marker in _PRIVATE_METADATA_MARKERS
            )
            or any(ord(character) < 32 for character in display_name)
        ):
            raise ValueError("Provider display name is empty or contains private data")

        content_types = tuple(
            dict.fromkeys(str(item).strip().lower() for item in adapter.content_types)
        )
        if not content_types or not set(content_types) <= _CONTENT_TYPES:
            raise ValueError(f"Invalid provider content types: {content_types!r}")
        normalized_capabilities = tuple(
            dict.fromkeys(str(item).strip().lower() for item in capabilities)
        )
        if not normalized_capabilities:
            raise ValueError("Provider capabilities cannot be empty")
        for capability in normalized_capabilities:
            method_name = _CAPABILITY_METHODS.get(capability)
            if method_name is None:
                raise ValueError(f"Unknown provider capability: {capability}")
            if not callable(getattr(adapter, method_name, None)):
                raise TypeError(
                    f"Provider {provider_id} lacks required method {method_name}"
                )
        if not callable(getattr(adapter, "aclose", None)):
            raise TypeError(f"Provider {provider_id} lacks required method aclose")

        registration = RegisteredProvider(
            metadata=ProviderMetadata(
                provider_id=provider_id,
                family=family,
                display_name=display_name,
                content_types=content_types,
                capabilities=normalized_capabilities,
            ),
            adapter=adapter,
        )
        self._registrations[provider_id] = registration
        return registration

    @property
    def metadata(self) -> tuple[ProviderMetadata, ...]:
        return tuple(item.metadata for item in self._registrations.values())

    def get(self, provider_id: str) -> MediaProvider | None:
        registration = self._registrations.get(provider_id)
        return registration.adapter if registration is not None else None

    async def aclose(self) -> None:
        await asyncio.gather(
            *(item.adapter.aclose() for item in self._registrations.values()),
            return_exceptions=True,
        )
