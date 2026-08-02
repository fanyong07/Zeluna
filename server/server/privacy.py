"""Privacy lifecycle helpers for expired authentication artifacts."""

from dataclasses import dataclass
import time

from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from .database import (
    BangumiCollection,
    Comment,
    CommentLike,
    Danmaku,
    PlayHistory,
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
    danmaku = await owned(Danmaku, Danmaku.user_id == user.id)
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
