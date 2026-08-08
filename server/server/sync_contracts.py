"""Versioned, allowlisted contracts for account-owned cloud synchronization."""

from __future__ import annotations

from datetime import datetime
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


class _StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)


class NamedImage(_StrictModel):
    name: str = Field(max_length=120)
    count: int = Field(default=0, ge=0)
    image_url: str | None = Field(default=None, alias="imageUrl", max_length=1000)


class SubjectSnapshot(_StrictModel):
    id: int = Field(ge=0)
    title: str = Field(min_length=1, max_length=500)
    original_title: str = Field(default="", alias="originalTitle", max_length=500)
    summary: str = Field(default="", max_length=10_000)
    cover_url: str | None = Field(default=None, alias="coverUrl", max_length=1000)
    banner_url: str | None = Field(default=None, alias="bannerUrl", max_length=1000)
    date: str | None = Field(default=None, max_length=40)
    platform: str = Field(default="TV", max_length=40)
    language: str = Field(default="", max_length=40)
    region: str = Field(default="", max_length=80)
    status: str = Field(default="", max_length=80)
    categories: list[NamedImage] = Field(default_factory=list, max_length=50)
    tags: list[NamedImage] = Field(default_factory=list, max_length=100)
    total_episodes: int = Field(default=0, alias="totalEpisodes", ge=0, le=100_000)
    rating_score: float | None = Field(default=None, alias="ratingScore", ge=0)
    rating_rank: int | None = Field(default=None, alias="ratingRank", ge=0)
    rating_total: int | None = Field(default=None, alias="ratingTotal", ge=0)
    source: str = Field(min_length=1, max_length=120)
    stable_key: str = Field(alias="stableKey", min_length=1, max_length=300)
    legacy_id: int | None = Field(default=None, alias="legacyId")
    legacy_ids: list[int] = Field(default_factory=list, alias="legacyIds", max_length=50)


class EpisodeSnapshot(_StrictModel):
    id: int = Field(ge=0)
    subject_id: int = Field(alias="subjectId", ge=0)
    number: int = Field(ge=0, le=100_000)
    title: str = Field(default="", max_length=500)
    airdate: str | None = Field(default=None, max_length=40)
    duration: str = Field(default="", max_length=40)
    description: str = Field(default="", max_length=10_000)
    thumbnail_url: str | None = Field(
        default=None, alias="thumbnailUrl", max_length=1000
    )
    stable_key: str = Field(alias="stableKey", min_length=1, max_length=300)
    legacy_id: int | None = Field(default=None, alias="legacyId")


class LibraryPayload(_StrictModel):
    subject: SubjectSnapshot
    episode: EpisodeSnapshot | None = None
    updated_at: datetime = Field(alias="updatedAt")
    note: str = Field(default="", max_length=2000)
    position_seconds: int = Field(default=0, alias="positionSeconds", ge=0)
    duration_seconds: int = Field(default=0, alias="durationSeconds", ge=0)


class PlaybackPositionPayload(_StrictModel):
    subject: SubjectSnapshot
    episode: EpisodeSnapshot
    updated_at: datetime = Field(alias="updatedAt")
    position_seconds: int = Field(default=0, alias="positionSeconds", ge=0)
    duration_seconds: int = Field(default=0, alias="durationSeconds", ge=0)
    completed: bool = False

    @model_validator(mode="after")
    def normalize_completion(self) -> "PlaybackPositionPayload":
        if self.completed and self.position_seconds != 0:
            raise ValueError("completed playback positions must use positionSeconds=0")
        if self.position_seconds > 0 and self.duration_seconds <= 0:
            raise ValueError("durationSeconds is required for a resumable position")
        return self


class AppearanceSettingsPayload(_StrictModel):
    follow_system: bool = Field(default=False, alias="followSystem")
    dark_mode: bool = Field(default=True, alias="darkMode")
    compact_mode: bool = Field(default=False, alias="compactMode")
    reduce_motion: bool = Field(default=False, alias="reduceMotion")


class PlaybackSettingsPayload(_StrictModel):
    volume_boost: float = Field(default=0.26, alias="volumeBoost", ge=0, le=2)
    super_resolution: bool = Field(default=False, alias="superResolution")
    super_resolution_profile: str = Field(
        default="auto", alias="superResolutionProfile", max_length=40
    )
    super_resolution_custom_shaders: list[str] = Field(
        default_factory=list,
        alias="superResolutionCustomShaders",
        max_length=64,
    )
    video_scale: str = Field(default="适应", alias="videoScale", max_length=40)
    speed: float = Field(default=1.0, ge=0.25, le=4)
    default_speed: float = Field(default=1.0, alias="defaultSpeed", ge=0.25, le=4)
    hold_speed: float = Field(default=2.0, alias="holdSpeed", ge=0.25, le=8)
    edge_double_tap: bool = Field(default=True, alias="edgeDoubleTap")
    rewind_seconds: int = Field(default=10, alias="rewindSeconds", ge=1, le=600)
    forward_seconds: int = Field(default=10, alias="forwardSeconds", ge=1, le=600)
    compatibility_mode: bool = Field(default=True, alias="compatibilityMode")
    auto_next: bool = Field(default=True, alias="autoNext")
    auto_switch_line: bool = Field(default=True, alias="autoSwitchLine")
    auto_fullscreen: bool = Field(default=False, alias="autoFullscreen")
    remember_line: bool = Field(default=True, alias="rememberLine")
    keyboard_shortcuts_enabled: bool = Field(
        default=True, alias="keyboardShortcutsEnabled"
    )
    shortcut_play_pause: bool = Field(default=True, alias="shortcutPlayPause")
    shortcut_seek: bool = Field(default=True, alias="shortcutSeek")
    shortcut_volume: bool = Field(default=True, alias="shortcutVolume")
    shortcut_fullscreen: bool = Field(default=True, alias="shortcutFullscreen")
    shortcut_mute: bool = Field(default=True, alias="shortcutMute")
    shortcut_reload: bool = Field(default=True, alias="shortcutReload")

    @field_validator("super_resolution_custom_shaders")
    @classmethod
    def bound_shader_names(cls, value: list[str]) -> list[str]:
        if any(not item or len(item) > 160 for item in value):
            raise ValueError("shader names must contain 1 to 160 characters")
        return value


class _MutationBase(_StrictModel):
    mutation_id: str = Field(
        alias="mutationId",
        min_length=16,
        max_length=100,
        pattern=r"^[A-Za-z0-9:_-]+$",
    )
    record_id: str = Field(alias="recordId", min_length=1, max_length=300)
    schema_version: Literal[1] = Field(default=1, alias="schemaVersion")
    deleted: bool = False

    @field_validator("record_id")
    @classmethod
    def normalize_record_id(cls, value: str) -> str:
        normalized = value.strip()
        if not normalized:
            raise ValueError("recordId is empty")
        return normalized


class FavoriteMutation(_MutationBase):
    type: Literal["favorite"]
    payload: LibraryPayload


class FollowingMutation(_MutationBase):
    type: Literal["following"]
    payload: LibraryPayload


class HistoryMutation(_MutationBase):
    type: Literal["history"]
    payload: LibraryPayload


class PlaybackPositionMutation(_MutationBase):
    type: Literal["playback_position"]
    payload: PlaybackPositionPayload


class AppearanceSettingsMutation(_MutationBase):
    type: Literal["settings_appearance"]
    payload: AppearanceSettingsPayload


class PlaybackSettingsMutation(_MutationBase):
    type: Literal["settings_playback"]
    payload: PlaybackSettingsPayload


SyncMutation = Annotated[
    FavoriteMutation
    | FollowingMutation
    | HistoryMutation
    | PlaybackPositionMutation
    | AppearanceSettingsMutation
    | PlaybackSettingsMutation,
    Field(discriminator="type"),
]


class SyncPushRequest(_StrictModel):
    mutations: list[SyncMutation] = Field(min_length=1, max_length=100)

    @model_validator(mode="after")
    def reject_duplicate_mutation_ids(self) -> "SyncPushRequest":
        ids = [item.mutation_id for item in self.mutations]
        if len(ids) != len(set(ids)):
            raise ValueError("mutationId values must be unique within one push")
        return self


SyncMutationRequest = (
    FavoriteMutation
    | FollowingMutation
    | HistoryMutation
    | PlaybackPositionMutation
    | AppearanceSettingsMutation
    | PlaybackSettingsMutation
)
