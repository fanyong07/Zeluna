"""Privacy lifecycle helpers for expired authentication artifacts."""

from dataclasses import dataclass
import json
import time

from sqlalchemy import delete, func, select, update
from sqlalchemy.exc import DBAPIError, IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from .database import (
    BangumiCollection,
    Comment,
    CommentLike,
    CommunityDanmaku,
    Danmaku,
    PlayHistory,
    RefreshTokenHistory,
    SyncMutation,
    SyncRecord,
    SyncRevision,
    Thread,
    ThreadCollection,
    ThreadImage,
    ThreadLike,
    User,
    UserToken,
    VerifyCode,
)


@dataclass(frozen=True)
class AuthArtifactCleanup:
    verification_codes: int
    sessions: int


@dataclass(frozen=True)
class PrivacyCleanup:
    verification_codes: int
    sessions: int
    finalized_accounts: int
    processed_accounts: int = 0
    failed_accounts: int = 0
    deletion_errors: dict[str, int] | None = None


async def purge_expired_auth_artifacts(
    session: AsyncSession,
    *,
    now: float | None = None,
) -> AuthArtifactCleanup:
    """Delete only artifacts whose signed/code validity has already ended."""

    cutoff = time.time() if now is None else now
    codes = await session.execute(
        delete(VerifyCode).where(VerifyCode.expires_at <= cutoff)
    )
    sessions = await session.execute(
        delete(UserToken).where(
            UserToken.expires_at > 0,
            UserToken.expires_at <= cutoff,
        )
    )
    return AuthArtifactCleanup(
        verification_codes=max(0, codes.rowcount or 0),
        sessions=max(0, sessions.rowcount or 0),
    )


async def run_privacy_cleanup(
    session: AsyncSession,
    *,
    now: float | None = None,
    account_limit: int = 100,
    session_factory=None,
) -> PrivacyCleanup:
    """Purge expired auth rows and finalize a bounded due-account batch."""

    auth = await purge_expired_auth_artifacts(session, now=now)
    deletion_stats: dict[str, object] = {}
    finalized = await finalize_due_account_deletions(
        session,
        now=now,
        limit=account_limit,
        session_factory=session_factory,
        stats=deletion_stats,
    )
    return PrivacyCleanup(
        verification_codes=auth.verification_codes,
        sessions=auth.sessions,
        finalized_accounts=finalized,
        processed_accounts=int(deletion_stats.get("processed", finalized)),
        failed_accounts=int(deletion_stats.get("failed", 0)),
        deletion_errors=dict(deletion_stats.get("errors", {})),
    )


async def finalize_due_account_deletions(
    session: AsyncSession,
    *,
    now: float | None = None,
    limit: int = 100,
    session_factory=None,
    stats: dict[str, object] | None = None,
) -> int:
    """Anonymize public content and erase private data after the grace period."""

    cutoff = time.time() if now is None else now
    bounded_limit = max(1, min(1000, limit))
    counters: dict[str, int] = {"processed": 0, "finalized": 0, "failed": 0}
    errors: dict[str, int] = {}
    if session_factory is not None:
        # Selection must not retain a User row lock while an independent
        # finalizer transaction tries to modify the same account. Commit the
        # short selection transaction before opening any finalizer session.
        candidate_ids = list(
            await session.scalars(
                select(User.id)
                .where(
                    User.deletion_due_at > 0,
                    User.deletion_due_at <= cutoff,
                )
                .order_by(User.deletion_due_at.asc(), User.id.asc())
                .limit(bounded_limit)
            )
        )
        await session.commit()
        for user_id in candidate_ids:
            async with session_factory() as account_session:
                try:
                    account = await account_session.scalar(
                        select(User)
                        .where(
                            User.id == user_id,
                            User.deletion_due_at > 0,
                            User.deletion_due_at <= cutoff,
                        )
                        .with_for_update(skip_locked=True)
                    )
                    if account is None:
                        continue
                    counters["processed"] += 1
                    await _finalize_account_deletion(account_session, account)
                    await account_session.commit()
                    counters["finalized"] += 1
                except Exception as error:
                    await account_session.rollback()
                    error_code = _deletion_error_code(error)
                    errors[error_code] = errors.get(error_code, 0) + 1
                    await _record_deletion_failure(
                        account_session, user_id, now=now, error_code=error_code
                    )
                    counters["failed"] += 1
        if stats is not None:
            stats.update(counters)
            stats["errors"] = errors
        return counters["finalized"]

    # Direct callers/tests that already own a session retain the original
    # savepoint behavior and keep their selected rows locked in that session.
    users = list(
        await session.scalars(
            select(User)
            .where(
                User.deletion_due_at > 0,
                User.deletion_due_at <= cutoff,
            )
            .order_by(User.deletion_due_at.asc(), User.id.asc())
            .limit(bounded_limit)
            .with_for_update(skip_locked=True)
        )
    )
    for user in users:
        counters["processed"] += 1
        try:
            async with session.begin_nested():
                await _finalize_account_deletion(session, user)
            counters["finalized"] += 1
        except Exception as error:
            error_code = _deletion_error_code(error)
            errors[error_code] = errors.get(error_code, 0) + 1
            await _record_deletion_failure(session, user.id, now=now, error_code=error_code)
            counters["failed"] += 1
    if stats is not None:
        stats.update(counters)
        stats["errors"] = errors
    return counters["finalized"]


def _deletion_error_code(error: Exception) -> str:
    if isinstance(error, IntegrityError):
        return "constraint_error"
    if isinstance(error, DBAPIError):
        return "transient_database_error" if error.connection_invalidated else "dependency_error"
    if isinstance(error, (TimeoutError, ConnectionError, OSError)):
        return "transient_database_error"
    return "unknown_internal"


async def _record_deletion_failure(
    session: AsyncSession,
    user_id: int,
    *,
    now: float | None,
    error_code: str,
) -> None:
    """Keep a poison account frozen and retryable without storing PII/errors."""

    try:
        await session.execute(
            update(User)
            .where(User.id == user_id)
            .values(
                deletion_attempts=User.deletion_attempts + 1,
                deletion_last_attempt_at=time.time() if now is None else now,
                deletion_last_error_code=error_code,
            )
        )
        await session.commit()
    except Exception:
        await session.rollback()


async def _finalize_account_deletion(session: AsyncSession, user: User) -> None:
    thread_collection_targets = set(
        await session.scalars(
            select(ThreadCollection.thread_id).where(
                ThreadCollection.user_id == user.id
            )
        )
    )
    thread_like_targets = set(
        await session.scalars(
            select(ThreadLike.thread_id).where(ThreadLike.user_id == user.id)
        )
    )
    comment_like_targets = set(
        await session.scalars(
            select(CommentLike.comment_id).where(CommentLike.user_id == user.id)
        )
    )
    authored_comment_ids = set(
        await session.scalars(select(Comment.id).where(Comment.user_id == user.id))
    )

    await session.execute(
        delete(ThreadCollection).where(ThreadCollection.user_id == user.id)
    )
    await session.execute(delete(ThreadLike).where(ThreadLike.user_id == user.id))
    await session.execute(delete(CommentLike).where(CommentLike.user_id == user.id))
    await session.execute(
        delete(BangumiCollection).where(BangumiCollection.user_id == user.id)
    )
    await session.execute(delete(PlayHistory).where(PlayHistory.user_id == user.id))
    await session.execute(delete(SyncMutation).where(SyncMutation.user_id == user.id))
    await session.execute(delete(SyncRecord).where(SyncRecord.user_id == user.id))
    await session.execute(delete(SyncRevision).where(SyncRevision.user_id == user.id))
    await session.execute(delete(UserToken).where(UserToken.user_id == user.id))
    await session.execute(
        delete(RefreshTokenHistory).where(RefreshTokenHistory.user_id == user.id)
    )
    await session.execute(delete(VerifyCode).where(VerifyCode.email == user.email))

    for thread_id in thread_collection_targets:
        count = (
            select(func.count(ThreadCollection.id))
            .where(ThreadCollection.thread_id == thread_id)
            .scalar_subquery()
        )
        await session.execute(
            update(Thread).where(Thread.id == thread_id).values(collect_count=count)
        )
    for thread_id in thread_like_targets:
        count = (
            select(func.count(ThreadLike.id))
            .where(ThreadLike.thread_id == thread_id)
            .scalar_subquery()
        )
        await session.execute(
            update(Thread).where(Thread.id == thread_id).values(like_count=count)
        )
    for comment_id in comment_like_targets:
        count = (
            select(func.count(CommentLike.id))
            .where(CommentLike.comment_id == comment_id)
            .scalar_subquery()
        )
        await session.execute(
            update(Comment).where(Comment.id == comment_id).values(like_count=count)
        )

    await session.execute(
        update(Danmaku).where(Danmaku.user_id == user.id).values(user_id=None)
    )
    await session.execute(
        update(CommunityDanmaku)
        .where(CommunityDanmaku.user_id == user.id)
        .values(user_id=None)
    )
    await session.execute(
        update(Thread).where(Thread.user_id == user.id).values(user_id=None)
    )
    await session.execute(
        update(Comment).where(Comment.user_id == user.id).values(user_id=None)
    )
    if authored_comment_ids:
        await session.execute(
            update(Comment)
            .where(Comment.parent_id.in_([str(item) for item in authored_comment_ids]))
            .values(reply_to="匿名")
        )
    await session.execute(delete(User).where(User.id == user.id))


async def build_account_data_export(
    session: AsyncSession,
    user: User,
    *,
    generated_at: float | None = None,
) -> dict:
    """Return a deterministic allowlisted export with no auth secrets."""

    async def owned(model, *where):
        return list(
            await session.scalars(
                select(model).where(*where).order_by(model.id.asc())
            )
        )

    collections = await owned(BangumiCollection, BangumiCollection.user_id == user.id)
    history = await owned(PlayHistory, PlayHistory.user_id == user.id)
    sync_records = list(
        await session.scalars(
            select(SyncRecord)
            .where(SyncRecord.user_id == user.id)
            .order_by(SyncRecord.revision.asc(), SyncRecord.id.asc())
        )
    )
    danmaku = await owned(Danmaku, Danmaku.user_id == user.id)
    community_danmaku = await owned(
        CommunityDanmaku, CommunityDanmaku.user_id == user.id
    )
    threads = await owned(Thread, Thread.user_id == user.id)
    thread_images = list(
        await session.scalars(
            select(ThreadImage)
            .join(Thread, Thread.id == ThreadImage.thread_id)
            .where(Thread.user_id == user.id)
            .order_by(ThreadImage.id.asc())
        )
    )
    comments = await owned(Comment, Comment.user_id == user.id)
    thread_collections = await owned(
        ThreadCollection, ThreadCollection.user_id == user.id
    )
    thread_likes = await owned(ThreadLike, ThreadLike.user_id == user.id)
    comment_likes = await owned(CommentLike, CommentLike.user_id == user.id)

    return {
        "schema_version": 1,
        "generated_at": time.time() if generated_at is None else generated_at,
        "account": {
            "id": str(user.id),
            "email": user.email,
            "nickname": user.name,
            "role": user.role,
            "sex": user.sex,
            "avatar": user.avatar,
            "experience": user.exp,
            "coin": user.coin,
            "color": user.color,
            "address": user.address,
            "created_at": user.created_at,
            "updated_at": user.updated_at,
        },
        "private_library": {
            "collections": [
                {
                    "id": item.id,
                    "bangumi_id": item.bangumi_id,
                    "type": item.type,
                    "created_at": item.created_at,
                }
                for item in collections
            ],
            "play_history": [
                {
                    "id": item.id,
                    "bangumi_id": item.bangumi_id,
                    "episode_id": item.episode_id,
                    "position": item.position,
                    "created_at": item.created_at,
                    "updated_at": item.updated_at,
                }
                for item in history
            ],
        },
        "cloud_sync": {
            "records": [
                {
                    "record_id": item.record_id,
                    "type": item.record_type,
                    "schema_version": item.schema_version,
                    "payload": json.loads(item.payload_json),
                    "created_at": item.created_at,
                    "updated_at": item.updated_at,
                    "deleted": item.deleted,
                    "server_revision": item.revision,
                }
                for item in sync_records
            ]
        },
        "authored_content": {
            "danmaku": [
                {
                    "id": item.id,
                    "bangumi_id": item.bangumi_id,
                    "episode_id": item.episode_id,
                    "type": item.type,
                    "time": item.time,
                    "text": item.text,
                    "color": item.color,
                    "created_at": item.date,
                    "external_id": item.danmaku_id,
                }
                for item in danmaku
            ],
            "community_danmaku": [
                {
                    "id": item.id,
                    "subject_key": item.subject_key,
                    "episode_key": item.episode_key,
                    "time_seconds": item.time_seconds,
                    "mode": item.mode,
                    "color": item.color,
                    "text": item.text,
                    "created_at": item.created_at,
                }
                for item in community_danmaku
            ],
            "threads": [
                {
                    "id": item.id,
                    "title": item.title,
                    "body": item.body,
                    "tags": item.tags,
                    "nsfw": item.nsfw,
                    "ai": item.ai,
                    "like_count": item.like_count,
                    "collect_count": item.collect_count,
                    "comment_count": item.comment_count,
                    "created_at": item.created_at,
                    "updated_at": item.updated_at,
                }
                for item in threads
            ],
            "thread_images": [
                {
                    "id": item.id,
                    "thread_id": item.thread_id,
                    "color": item.color,
                    "width": item.width,
                    "height": item.height,
                    "original": item.original,
                    "master": item.master,
                    "original_size": item.original_size,
                    "master_size": item.master_size,
                }
                for item in thread_images
            ],
            "comments": [
                {
                    "id": item.id,
                    "type": item.type,
                    "target_id": item.target_id,
                    "parent_id": item.parent_id,
                    "reply_to": item.reply_to,
                    "contents": item.contents,
                    "like_count": item.like_count,
                    "created_at": item.created_at,
                }
                for item in comments
            ],
        },
        "interactions": {
            "thread_collections": [
                {
                    "id": item.id,
                    "thread_id": item.thread_id,
                    "created_at": item.created_at,
                }
                for item in thread_collections
            ],
            "thread_likes": [
                {
                    "id": item.id,
                    "thread_id": item.thread_id,
                    "created_at": item.created_at,
                }
                for item in thread_likes
            ],
            "comment_likes": [
                {
                    "id": item.id,
                    "comment_id": item.comment_id,
                    "created_at": item.created_at,
                }
                for item in comment_likes
            ],
        },
    }
