"""
SQLAlchemy 异步引擎 + ORM 模型
"""

import datetime
from pathlib import Path

from alembic.config import Config
from alembic.script import ScriptDirectory
from sqlalchemy import event, inspect
from sqlalchemy.engine import make_url
from sqlalchemy.ext.asyncio import (
    AsyncEngine,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship
from sqlalchemy import (
    String, Integer, Float, Boolean, Text, ForeignKey, DateTime, func,
    UniqueConstraint, Index, select, text,
)
from sqlalchemy.exc import IntegrityError

from .config import (
    DATABASE_AUTO_CREATE,
    DATABASE_URL,
    SQLITE_BUSY_TIMEOUT_MS,
    SQLITE_CONNECT_TIMEOUT_SECONDS,
)


def create_database_engine(database_url: str = DATABASE_URL) -> AsyncEngine:
    parsed_url = make_url(database_url)
    engine_options: dict = {"echo": False}
    if parsed_url.get_backend_name() == "sqlite":
        engine_options["connect_args"] = {
            "timeout": SQLITE_CONNECT_TIMEOUT_SECONDS,
        }
    database_engine = create_async_engine(database_url, **engine_options)
    if parsed_url.get_backend_name() == "sqlite":

        @event.listens_for(database_engine.sync_engine, "connect")
        def _configure_sqlite_connection(dbapi_connection, _connection_record):
            cursor = dbapi_connection.cursor()
            try:
                cursor.execute("PRAGMA foreign_keys=ON")
                cursor.execute(f"PRAGMA busy_timeout={SQLITE_BUSY_TIMEOUT_MS}")
                cursor.execute("PRAGMA journal_mode=WAL")
                cursor.execute("PRAGMA synchronous=NORMAL")
            finally:
                cursor.close()
    return database_engine


engine = create_database_engine()
async_session = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)


class Base(DeclarativeBase):
    pass


# ---------------------------------------------------------------------------
# 用户
# ---------------------------------------------------------------------------
class User(Base):
    __tablename__ = "users"

    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    email: Mapped[str] = mapped_column(String(255), unique=True, index=True)
    name: Mapped[str] = mapped_column(String(100), unique=True, index=True)
    password_hash: Mapped[str] = mapped_column(String(255))
    role: Mapped[str] = mapped_column(String(20), default="user")
    sex: Mapped[str] = mapped_column(String(10), default="保密")
    avatar: Mapped[str] = mapped_column(String(500), default="")
    exp: Mapped[int] = mapped_column(Integer, default=0)
    coin: Mapped[int] = mapped_column(Integer, default=0)
    color: Mapped[str] = mapped_column(String(20), default="#FF6B6B")
    address: Mapped[str] = mapped_column(String(500), default="")
    created_at: Mapped[float] = mapped_column(Float, default=lambda: datetime.datetime.now(datetime.timezone.utc).timestamp())
    updated_at: Mapped[float] = mapped_column(Float, default=lambda: datetime.datetime.now(datetime.timezone.utc).timestamp())
    deletion_requested_at: Mapped[float] = mapped_column(
        Float, default=0.0, server_default="0"
    )
    deletion_due_at: Mapped[float] = mapped_column(
        Float, default=0.0, server_default="0"
    )

    tokens: Mapped[list["UserToken"]] = relationship("UserToken", back_populates="user", cascade="all, delete-orphan")
    danmaku: Mapped[list["Danmaku"]] = relationship("Danmaku", back_populates="user", cascade="all, delete-orphan")


class UserToken(Base):
    __tablename__ = "user_tokens"

    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"))
    token: Mapped[str] = mapped_column(String(500), unique=True, index=True)
    token_id: Mapped[str] = mapped_column(
        String(100), default="", server_default=""
    )
    expires_at: Mapped[float] = mapped_column(
        Float, default=0.0, server_default="0"
    )
    # New account sessions use these fields. Rows without a session_id are
    # retained only for bounded legacy JWT compatibility during migration.
    session_id: Mapped[str | None] = mapped_column(
        String(96), unique=True, index=True, nullable=True
    )
    device_id: Mapped[str] = mapped_column(
        String(128), default="", server_default=""
    )
    device_name: Mapped[str] = mapped_column(
        String(80), default="", server_default=""
    )
    platform: Mapped[str] = mapped_column(
        String(32), default="", server_default=""
    )
    token_family_id: Mapped[str] = mapped_column(
        String(96), default="", server_default="", index=True
    )
    last_used_at: Mapped[float] = mapped_column(
        Float, default=lambda: datetime.datetime.now(datetime.timezone.utc).timestamp(),
        server_default="0",
    )
    revoked_at: Mapped[float] = mapped_column(
        Float, default=0.0, server_default="0", index=True
    )
    refresh_rotated_at: Mapped[float] = mapped_column(
        Float, default=0.0, server_default="0"
    )
    created_at: Mapped[float] = mapped_column(Float, default=lambda: datetime.datetime.now(datetime.timezone.utc).timestamp())

    user: Mapped["User"] = relationship("User", back_populates="tokens")


class RefreshTokenHistory(Base):
    """Digest-only history used to detect reuse of rotated refresh tokens."""

    __tablename__ = "refresh_token_history"

    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    user_id: Mapped[int] = mapped_column(Integer, index=True)
    session_id: Mapped[str] = mapped_column(String(96), index=True)
    token_family_id: Mapped[str] = mapped_column(String(96), index=True)
    digest: Mapped[str] = mapped_column(String(128), unique=True, index=True)
    created_at: Mapped[float] = mapped_column(
        Float,
        default=lambda: datetime.datetime.now(datetime.timezone.utc).timestamp(),
    )
    used_at: Mapped[float] = mapped_column(Float, default=0.0, server_default="0")
    replaced_by_digest: Mapped[str] = mapped_column(
        String(128), default="", server_default=""
    )
    reuse_detected_at: Mapped[float] = mapped_column(
        Float, default=0.0, server_default="0"
    )


class EmailOutbox(Base):
    """Durable encrypted email work item; plaintext codes never persist here."""

    __tablename__ = "email_outbox"

    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    kind: Mapped[str] = mapped_column(String(32), index=True)
    recipient: Mapped[str] = mapped_column(String(255), index=True)
    encrypted_payload: Mapped[str] = mapped_column(Text)
    status: Mapped[str] = mapped_column(
        String(16), default="pending", server_default="pending", index=True
    )
    attempts: Mapped[int] = mapped_column(Integer, default=0, server_default="0")
    next_attempt_at: Mapped[float] = mapped_column(
        Float, default=lambda: datetime.datetime.now(datetime.timezone.utc).timestamp(),
        server_default="0",
        index=True,
    )
    created_at: Mapped[float] = mapped_column(
        Float, default=lambda: datetime.datetime.now(datetime.timezone.utc).timestamp()
    )
    delivered_at: Mapped[float] = mapped_column(
        Float, default=0.0, server_default="0"
    )
    last_error_code: Mapped[str] = mapped_column(
        String(64), default="", server_default=""
    )
    claim_token: Mapped[str] = mapped_column(
        String(96), default="", server_default="", index=True
    )
    locked_at: Mapped[float] = mapped_column(Float, default=0.0, server_default="0")


class VerifyCode(Base):
    __tablename__ = "verify_codes"

    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    email: Mapped[str] = mapped_column(String(255))
    # New account endpoints store an HMAC digest, never the plaintext code.
    code: Mapped[str] = mapped_column(String(64))
    purpose: Mapped[str] = mapped_column(
        String(32), default="legacy", server_default="legacy"
    )
    failed_attempts: Mapped[int] = mapped_column(
        Integer, default=0, server_default="0"
    )
    created_at: Mapped[float] = mapped_column(Float, default=lambda: datetime.datetime.now(datetime.timezone.utc).timestamp())
    expires_at: Mapped[float] = mapped_column(Float)


# ---------------------------------------------------------------------------
# 番剧
# ---------------------------------------------------------------------------
class Bangumi(Base):
    __tablename__ = "bangumi"

    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    title: Mapped[str] = mapped_column(String(500))
    summary: Mapped[str] = mapped_column(Text, default="")
    cover_url: Mapped[str] = mapped_column(String(1000), default="")
    banner_url: Mapped[str] = mapped_column(String(1000), default="")
    type: Mapped[str] = mapped_column(String(20), default="tv")  # tv, movie, ova
    lang: Mapped[str] = mapped_column(String(20), default="ja")   # ja, zh
    year: Mapped[int] = mapped_column(Integer, default=2024)
    status: Mapped[int] = mapped_column(Integer, default=0)       # 0=连载, 1=完结
    tags: Mapped[str] = mapped_column(Text, default="")           # JSON array string
    genres: Mapped[str] = mapped_column(Text, default="")         # JSON array string
    rating: Mapped[float] = mapped_column(Float, default=0.0)
    rating_count: Mapped[int] = mapped_column(Integer, default=0)
    bangumi_id: Mapped[str] = mapped_column(String(100), default="")  # 外部 ID
    created_at: Mapped[float] = mapped_column(Float, default=lambda: datetime.datetime.now(datetime.timezone.utc).timestamp())
    updated_at: Mapped[float] = mapped_column(Float, default=lambda: datetime.datetime.now(datetime.timezone.utc).timestamp())

    episodes: Mapped[list["BangumiEpisode"]] = relationship("BangumiEpisode", back_populates="bangumi", cascade="all, delete-orphan")
    collections: Mapped[list["BangumiCollection"]] = relationship("BangumiCollection", back_populates="bangumi", cascade="all, delete-orphan")
    danmaku: Mapped[list["Danmaku"]] = relationship("Danmaku", back_populates="bangumi", cascade="all, delete-orphan")


class BangumiEpisode(Base):
    __tablename__ = "bangumi_episodes"

    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    bangumi_id: Mapped[int] = mapped_column(ForeignKey("bangumi.id"))
    number: Mapped[int] = mapped_column(Integer)
    title: Mapped[str] = mapped_column(String(500), default="")
    vod_url: Mapped[str] = mapped_column(Text, default="")     # JSON: [{"url":"...","type":"hls","caption":"1080p"}]
    duration: Mapped[int] = mapped_column(Integer, default=0)
    created_at: Mapped[float] = mapped_column(Float, default=lambda: datetime.datetime.now(datetime.timezone.utc).timestamp())

    bangumi: Mapped["Bangumi"] = relationship("Bangumi", back_populates="episodes")
    danmaku: Mapped[list["Danmaku"]] = relationship("Danmaku", back_populates="episode", cascade="all, delete-orphan")


class BangumiCollection(Base):
    __tablename__ = "bangumi_collections"

    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"))
    bangumi_id: Mapped[int] = mapped_column(ForeignKey("bangumi.id"))
    type: Mapped[str] = mapped_column(String(20), default="wish")  # wish, watch, watched
    created_at: Mapped[float] = mapped_column(Float, default=lambda: datetime.datetime.now(datetime.timezone.utc).timestamp())

    bangumi: Mapped["Bangumi"] = relationship("Bangumi", back_populates="collections")


# ---------------------------------------------------------------------------
# 角色 & 人物
# ---------------------------------------------------------------------------
class Character(Base):
    __tablename__ = "characters"

    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    bangumi_id: Mapped[int] = mapped_column(ForeignKey("bangumi.id"))
    name: Mapped[str] = mapped_column(String(200))
    role: Mapped[str] = mapped_column(String(100), default="")    # 主角/配角
    avatar_url: Mapped[str] = mapped_column(String(1000), default="")
    summary: Mapped[str] = mapped_column(Text, default="")
    seiyuu: Mapped[str] = mapped_column(String(200), default="")  # 声优


class Person(Base):
    __tablename__ = "persons"

    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    bangumi_id: Mapped[int] = mapped_column(ForeignKey("bangumi.id"))
    name: Mapped[str] = mapped_column(String(200))
    role: Mapped[str] = mapped_column(String(100), default="")    # 监督/脚本/音乐
    avatar_url: Mapped[str] = mapped_column(String(1000), default="")
    summary: Mapped[str] = mapped_column(Text, default="")


# ---------------------------------------------------------------------------
# 弹幕
# ---------------------------------------------------------------------------
class Danmaku(Base):
    __tablename__ = "danmaku"

    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    bangumi_id: Mapped[int] = mapped_column(ForeignKey("bangumi.id"))
    episode_id: Mapped[int] = mapped_column(ForeignKey("bangumi_episodes.id"))
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), nullable=True)
    type: Mapped[int] = mapped_column(Integer, default=0)  # 0=scroll, 1=top, 2=bottom
    time: Mapped[float] = mapped_column(Float, default=0.0)  # 弹幕出现时间(秒)
    text: Mapped[str] = mapped_column(Text)
    color: Mapped[str] = mapped_column(String(20), default="#FFFFFF")
    date: Mapped[float] = mapped_column(Float, default=lambda: datetime.datetime.now(datetime.timezone.utc).timestamp())
    danmaku_id: Mapped[str] = mapped_column(String(100), default="")  # 外部 ID

    bangumi: Mapped["Bangumi"] = relationship("Bangumi", back_populates="danmaku")
    episode: Mapped["BangumiEpisode"] = relationship("BangumiEpisode", back_populates="danmaku")
    user: Mapped["User"] = relationship("User", back_populates="danmaku")


# ---------------------------------------------------------------------------
# 帖子 / 图片社区
# ---------------------------------------------------------------------------
class Thread(Base):
    __tablename__ = "threads"

    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    title: Mapped[str] = mapped_column(String(500))
    body: Mapped[str] = mapped_column(Text, default="")
    tags: Mapped[str] = mapped_column(Text, default="")      # JSON array
    nsfw: Mapped[bool] = mapped_column(Boolean, default=False)
    ai: Mapped[bool] = mapped_column(Boolean, default=False)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), nullable=True)
    like_count: Mapped[int] = mapped_column(Integer, default=0)
    collect_count: Mapped[int] = mapped_column(Integer, default=0)
    comment_count: Mapped[int] = mapped_column(Integer, default=0)
    created_at: Mapped[float] = mapped_column(Float, default=lambda: datetime.datetime.now(datetime.timezone.utc).timestamp())
    updated_at: Mapped[float] = mapped_column(Float, default=lambda: datetime.datetime.now(datetime.timezone.utc).timestamp())

    images: Mapped[list["ThreadImage"]] = relationship("ThreadImage", back_populates="thread", cascade="all, delete-orphan")


class ThreadImage(Base):
    __tablename__ = "thread_images"

    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    thread_id: Mapped[int] = mapped_column(ForeignKey("threads.id"))
    color: Mapped[str] = mapped_column(String(20), default="")
    width: Mapped[int] = mapped_column(Integer, default=0)
    height: Mapped[int] = mapped_column(Integer, default=0)
    original: Mapped[str] = mapped_column(String(1000), default="")
    master: Mapped[str] = mapped_column(String(1000), default="")
    original_size: Mapped[int] = mapped_column(Integer, default=0)
    master_size: Mapped[int] = mapped_column(Integer, default=0)

    thread: Mapped["Thread"] = relationship("Thread", back_populates="images")


class ThreadCollection(Base):
    __tablename__ = "thread_collections"

    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"))
    thread_id: Mapped[int] = mapped_column(ForeignKey("threads.id"))
    created_at: Mapped[float] = mapped_column(Float, default=lambda: datetime.datetime.now(datetime.timezone.utc).timestamp())


class ThreadLike(Base):
    __tablename__ = "thread_likes"

    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"))
    thread_id: Mapped[int] = mapped_column(ForeignKey("threads.id"))
    created_at: Mapped[float] = mapped_column(Float, default=lambda: datetime.datetime.now(datetime.timezone.utc).timestamp())


# ---------------------------------------------------------------------------
# 评论
# ---------------------------------------------------------------------------
class Comment(Base):
    __tablename__ = "comments"

    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    type: Mapped[str] = mapped_column(String(50))                 # "thread" | "bangumi_episode"
    target_id: Mapped[str] = mapped_column(String(100))
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), nullable=True)
    parent_id: Mapped[str] = mapped_column(String(100), default="")  # 父评论 ID
    reply_to: Mapped[str] = mapped_column(String(200), default="")   # 回复给谁
    contents: Mapped[str] = mapped_column(Text, default="[]")        # JSON array
    like_count: Mapped[int] = mapped_column(Integer, default=0)
    created_at: Mapped[float] = mapped_column(Float, default=lambda: datetime.datetime.now(datetime.timezone.utc).timestamp())


class CommentLike(Base):
    __tablename__ = "comment_likes"

    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"))
    comment_id: Mapped[int] = mapped_column(ForeignKey("comments.id"))
    created_at: Mapped[float] = mapped_column(Float, default=lambda: datetime.datetime.now(datetime.timezone.utc).timestamp())


# ---------------------------------------------------------------------------
# 播放历史
# ---------------------------------------------------------------------------
class PlayHistory(Base):
    __tablename__ = "play_history"

    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"))
    bangumi_id: Mapped[int] = mapped_column(ForeignKey("bangumi.id"))
    episode_id: Mapped[int] = mapped_column(ForeignKey("bangumi_episodes.id"))
    position: Mapped[float] = mapped_column(Float, default=0.0)
    created_at: Mapped[float] = mapped_column(Float, default=lambda: datetime.datetime.now(datetime.timezone.utc).timestamp())
    updated_at: Mapped[float] = mapped_column(Float, default=lambda: datetime.datetime.now(datetime.timezone.utc).timestamp())


# ---------------------------------------------------------------------------
# 播放线路缓存 (预爬 + 可达性验证后写入, 供 /api/v2/vod 秒回)
# ---------------------------------------------------------------------------
class PlaybackCache(Base):
    __tablename__ = "playback_cache"
    __table_args__ = (
        Index(
            "uq_playback_cache_subject_episode",
            "subject_id",
            "episode",
            unique=True,
        ),
    )

    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    subject_id: Mapped[str] = mapped_column(String(200), index=True)  # 如 maccms:iKun:123
    episode: Mapped[int] = mapped_column(Integer, default=1)
    title: Mapped[str] = mapped_column(String(500), default="")
    # JSON: [{"url","title","format","source"}] —— 只存验证过可达的线路
    lines_json: Mapped[str] = mapped_column(Text, default="[]")
    line_count: Mapped[int] = mapped_column(Integer, default=0)
    verified_at: Mapped[float] = mapped_column(Float, default=lambda: datetime.datetime.now(datetime.timezone.utc).timestamp())
    created_at: Mapped[float] = mapped_column(Float, default=lambda: datetime.datetime.now(datetime.timezone.utc).timestamp())


# ---------------------------------------------------------------------------
# 统一内容目录与播放源绑定
# ---------------------------------------------------------------------------
class CatalogSubject(Base):
    """Bangumi/TMDB 元数据的本地目录项，stable_id 是客户端唯一作品 ID。"""

    __tablename__ = "catalog_subjects"

    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    stable_id: Mapped[str] = mapped_column(String(200), unique=True, index=True)
    provider: Mapped[str] = mapped_column(String(30), index=True)
    provider_id: Mapped[str] = mapped_column(String(100), index=True)
    media_type: Mapped[str] = mapped_column(String(20), index=True)
    title: Mapped[str] = mapped_column(String(500), index=True)
    original_title: Mapped[str] = mapped_column(String(500), default="")
    aliases_json: Mapped[str] = mapped_column(Text, default="[]")
    metadata_json: Mapped[str] = mapped_column(Text, default="{}")
    popularity: Mapped[float] = mapped_column(Float, default=0.0)
    updated_at: Mapped[float] = mapped_column(
        Float,
        default=lambda: datetime.datetime.now(datetime.timezone.utc).timestamp(),
        index=True,
    )


class SourceBinding(Base):
    """稳定作品 ID 到某个采集站条目的映射。"""

    __tablename__ = "source_bindings"
    __table_args__ = (
        UniqueConstraint("stable_id", "source_id", name="uq_source_binding"),
    )

    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    stable_id: Mapped[str] = mapped_column(String(200), index=True)
    source_id: Mapped[str] = mapped_column(String(300), index=True)
    source_name: Mapped[str] = mapped_column(String(100), index=True)
    matched_title: Mapped[str] = mapped_column(String(500), default="")
    media_type: Mapped[str] = mapped_column(String(20), default="")
    year: Mapped[int] = mapped_column(Integer, default=0)
    score: Mapped[int] = mapped_column(Integer, default=0)
    episode_count: Mapped[int] = mapped_column(Integer, default=0)
    enabled: Mapped[bool] = mapped_column(Boolean, default=True)
    success_count: Mapped[int] = mapped_column(Integer, default=0)
    failure_count: Mapped[int] = mapped_column(Integer, default=0)
    last_success_at: Mapped[float] = mapped_column(Float, default=0.0)
    last_failure_at: Mapped[float] = mapped_column(Float, default=0.0)
    updated_at: Mapped[float] = mapped_column(
        Float,
        default=lambda: datetime.datetime.now(datetime.timezone.utc).timestamp(),
    )


class SourceHealth(Base):
    """采集站的长期健康分，用于自动降权和恢复。"""

    __tablename__ = "source_health"

    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    source_name: Mapped[str] = mapped_column(String(100), unique=True, index=True)
    success_count: Mapped[int] = mapped_column(Integer, default=0)
    failure_count: Mapped[int] = mapped_column(Integer, default=0)
    consecutive_failures: Mapped[int] = mapped_column(Integer, default=0)
    last_status: Mapped[str] = mapped_column(String(30), default="unknown")
    last_error_category: Mapped[str] = mapped_column(String(50), default="")
    last_checked_at: Mapped[float] = mapped_column(Float, default=0.0)
    last_success_at: Mapped[float] = mapped_column(Float, default=0.0)
    last_failure_at: Mapped[float] = mapped_column(Float, default=0.0)
    latency_ms: Mapped[int] = mapped_column(Integer, default=0)
    recent_success_rate: Mapped[float] = mapped_column(Float, default=0.5)


class SyncRevision(Base):
    """Globally monotonic revision allocated for an accepted sync change."""

    __tablename__ = "sync_revisions"

    revision: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), index=True
    )
    created_at: Mapped[float] = mapped_column(
        Float,
        default=lambda: datetime.datetime.now(datetime.timezone.utc).timestamp(),
    )


class SyncRecord(Base):
    """Latest account-owned snapshot for one stable sync record."""

    __tablename__ = "sync_records"
    __table_args__ = (
        UniqueConstraint(
            "user_id",
            "record_type",
            "record_id",
            name="uq_sync_record_owner_type_id",
        ),
        Index("ix_sync_records_user_revision", "user_id", "revision"),
    )

    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), index=True
    )
    record_id: Mapped[str] = mapped_column(String(300))
    record_type: Mapped[str] = mapped_column(String(40))
    schema_version: Mapped[int] = mapped_column(Integer, default=1)
    payload_json: Mapped[str] = mapped_column(Text)
    created_at: Mapped[float] = mapped_column(Float)
    updated_at: Mapped[float] = mapped_column(Float)
    deleted: Mapped[bool] = mapped_column(Boolean, default=False)
    last_mutation_id: Mapped[str] = mapped_column(String(100))
    revision: Mapped[int] = mapped_column(
        ForeignKey("sync_revisions.revision"), index=True
    )


class SyncMutation(Base):
    """Account-scoped idempotency receipt for one client mutation."""

    __tablename__ = "sync_mutations"
    __table_args__ = (
        UniqueConstraint(
            "user_id",
            "mutation_id",
            name="uq_sync_mutation_owner_id",
        ),
    )

    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), index=True
    )
    mutation_id: Mapped[str] = mapped_column(String(100))
    payload_hash: Mapped[str] = mapped_column(String(64))
    record_id: Mapped[str] = mapped_column(String(300))
    record_type: Mapped[str] = mapped_column(String(40))
    revision: Mapped[int] = mapped_column(
        ForeignKey("sync_revisions.revision"), index=True
    )
    created_at: Mapped[float] = mapped_column(Float)


def migration_head_revision() -> str:
    server_root = Path(__file__).resolve().parents[1]
    config = Config(str(server_root / "alembic.ini"))
    script = ScriptDirectory.from_config(config)
    head = script.get_current_head()
    if not head:
        raise RuntimeError("Alembic migration head is not configured")
    return head


async def verify_database_schema(database_engine: AsyncEngine | None = None) -> str:
    selected_engine = database_engine or engine
    async with selected_engine.begin() as conn:
        tables = await conn.run_sync(
            lambda sync_conn: set(inspect(sync_conn).get_table_names())
        )
        if "alembic_version" not in tables:
            raise RuntimeError(
                "Database schema is not managed by Alembic. "
                "Run `python tools/migrate.py upgrade` before starting Zeluna."
            )
        revision = await conn.scalar(text("SELECT version_num FROM alembic_version"))
    head = migration_head_revision()
    if revision != head:
        raise RuntimeError(
            f"Database schema revision {revision or 'unknown'} is outdated; "
            f"expected {head}. Run `python tools/migrate.py upgrade`."
        )
    return str(revision)


async def init_db():
    if DATABASE_AUTO_CREATE:
        async with engine.begin() as conn:
            await conn.run_sync(Base.metadata.create_all)
        return
    await verify_database_schema()


async def upsert_playback_cache(
    session: AsyncSession,
    *,
    subject_id: str,
    episode: int,
    title: str,
    lines_json: str,
    line_count: int,
    verified_at: float,
) -> PlaybackCache:
    """Store one cache row and recover cleanly from concurrent inserts."""
    query = select(PlaybackCache).where(
        PlaybackCache.subject_id == subject_id,
        PlaybackCache.episode == episode,
    )
    row = (await session.execute(query)).scalar_one_or_none()
    if row is None:
        row = PlaybackCache(subject_id=subject_id, episode=episode)
        session.add(row)
    row.title = title
    row.lines_json = lines_json
    row.line_count = line_count
    row.verified_at = verified_at
    try:
        await session.commit()
        return row
    except IntegrityError:
        await session.rollback()
        row = (await session.execute(query)).scalar_one()
        row.title = title
        row.lines_json = lines_json
        row.line_count = line_count
        row.verified_at = verified_at
        await session.commit()
        return row
