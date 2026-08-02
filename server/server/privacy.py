"""Privacy lifecycle helpers for expired authentication artifacts."""

from dataclasses import dataclass
import time

from sqlalchemy import delete
from sqlalchemy.ext.asyncio import AsyncSession

from .database import UserToken, VerifyCode


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
