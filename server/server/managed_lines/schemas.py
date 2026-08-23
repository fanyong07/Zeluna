"""HTTP schemas for the managed remote playback line interface."""

from typing import Literal

from pydantic import AliasChoices, BaseModel, ConfigDict, Field


ManagedFormat = Literal[
    "auto",
    "hls",
    "m3u8",
    "dash",
    "mpd",
    "mp4",
    "m4v",
    "mov",
    "mkv",
    "flv",
    "webm",
]
ProvenanceKind = Literal[
    "owned",
    "licensed",
    "public_domain",
    "open_license",
    "authorized_third_party",
    "user_managed",
]


class ManagedLineCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    stable_id: str = Field(min_length=1, max_length=200)
    episode: int = Field(default=1, ge=1)
    provider_key: str = Field(
        default="managed.main",
        min_length=3,
        max_length=100,
        pattern=r"^[a-z0-9][a-z0-9._-]*$",
    )
    label: str = Field(default="管理线路", max_length=200)
    quality: str = Field(default="", max_length=50)
    format_hint: ManagedFormat = "auto"
    canonical_url: str = Field(min_length=1, max_length=4096)
    url_kind: Literal["static_direct"] = "static_direct"
    expires_at: float = Field(default=0, ge=0)
    headers: dict[str, str] = Field(default_factory=dict)
    priority: int = Field(default=500, ge=0, le=1000)
    provenance_kind: ProvenanceKind
    rights_reference: str = Field(min_length=1, max_length=500)
    operator_note: str = Field(default="", max_length=4000)


class ManagedLineUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    stable_id: str | None = Field(default=None, min_length=1, max_length=200)
    episode: int | None = Field(default=None, ge=1)
    provider_key: str | None = Field(
        default=None,
        min_length=3,
        max_length=100,
        pattern=r"^[a-z0-9][a-z0-9._-]*$",
    )
    label: str | None = Field(default=None, max_length=200)
    quality: str | None = Field(default=None, max_length=50)
    format_hint: ManagedFormat | None = None
    canonical_url: str | None = Field(default=None, min_length=1, max_length=4096)
    expires_at: float | None = Field(default=None, ge=0)
    headers: dict[str, str] | None = None
    priority: int | None = Field(default=None, ge=0, le=1000)
    provenance_kind: ProvenanceKind | None = None
    rights_reference: str | None = Field(default=None, min_length=1, max_length=500)
    operator_note: str | None = Field(default=None, max_length=4000)


class ManagedLineImportItem(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)

    stable_id: str = Field(min_length=1, max_length=200)
    episode: int = Field(ge=1)
    provider_key: str = Field(
        default="managed.main",
        min_length=3,
        max_length=100,
        pattern=r"^[a-z0-9][a-z0-9._-]*$",
    )
    label: str = Field(min_length=1, max_length=200)
    quality: str = Field(default="", max_length=50)
    format_hint: ManagedFormat = Field(
        validation_alias=AliasChoices("format_hint", "format")
    )
    canonical_url: str = Field(
        min_length=1,
        max_length=4096,
        validation_alias=AliasChoices("canonical_url", "url"),
    )
    url_kind: Literal["static_direct"] = "static_direct"
    expires_at: float = Field(default=0, ge=0)
    headers: dict[str, str] = Field(default_factory=dict)
    priority: int = Field(ge=0, le=1000)
    provenance_kind: ProvenanceKind = Field(
        validation_alias=AliasChoices("provenance_kind", "provenance")
    )
    rights_reference: str = Field(min_length=1, max_length=500)
    operator_note: str = Field(default="", max_length=4000)

    def as_create(self) -> ManagedLineCreate:
        return ManagedLineCreate.model_validate(self.model_dump())


class ManagedLineImportRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    items: list[ManagedLineImportItem] = Field(min_length=1, max_length=500)


class ManagedLineResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    stable_id: str
    episode: int
    provider_key: str
    label: str
    quality: str
    format_hint: str
    canonical_url: str
    url_kind: str
    expires_at: float
    headers: dict[str, str]
    priority: int
    status: str
    review_status: str
    enabled: bool
    provenance_kind: str
    rights_reference: str
    operator_note: str
    last_verified_status: str
    last_verified_at: float
    last_error_category: str
    last_latency_ms: int
    created_at: float
    updated_at: float
    published_at: float
    revoked_at: float
