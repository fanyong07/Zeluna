"""高画质线路清单:记录"见过什么",不保存可播地址。

背景:部分上游会把作品转存成自己压制的高画质档(如"官方简中·1080P"),
这类档次的价值在于画质与字幕版本,而不在具体地址——直链天数级失效。
因此本模块只登记可长期复用的元数据:作品、集数、画质标注、来源标识、
媒体主机与路径摘要。运维据此自行寻源留存。

安全边界:
  * 不写完整 URL、不写查询串(签名/token 都在查询串里);
  * ``path_digest`` 是 sha256 前 16 位,单向、不可还原;
  * 表中永远不含媒体字节。
"""

from __future__ import annotations

import hashlib
import re
import time
from dataclasses import dataclass
from urllib.parse import urlparse

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from .database import PremiumLineCatalog

#: 视为"高画质档"的画质标注特征。命中任一即值得登记。
PREMIUM_QUALITY_PATTERNS: tuple[str, ...] = (
    r"官方",
    r"简中",
    r"繁中",
    r"国语",
    r"4K",
    r"2160",
    r"1080",
    r"全高清",
    r"蓝光",
    r"BD",
)
_PREMIUM_RE = re.compile("|".join(PREMIUM_QUALITY_PATTERNS), re.IGNORECASE)
_DIGEST_LENGTH = 16


def is_premium_quality(label: str) -> bool:
    """画质标注是否值得进清单。"""
    return bool(_PREMIUM_RE.search(label or ""))


def path_digest(url: str) -> str:
    """媒体路径的单向摘要。不含 host,也不含查询串。"""
    try:
        path = urlparse(url or "").path
    except ValueError:
        path = ""
    if not path:
        return ""
    return hashlib.sha256(path.encode("utf-8")).hexdigest()[:_DIGEST_LENGTH]


def media_host(url: str) -> str:
    try:
        return (urlparse(url or "").hostname or "").lower()
    except ValueError:
        return ""


@dataclass(frozen=True)
class PremiumLineRecord:
    """一条待登记的清单项(已脱敏,可安全落库)。"""

    subject_stable_id: str
    episode: int
    quality_label: str
    source_tag: str = ""
    provider_id: str = ""
    subject_title: str = ""
    media_host: str = ""
    path_digest: str = ""
    container: str = ""
    reachable: bool = False
    note: str = ""


def build_record(
    *,
    subject_stable_id: str,
    episode: int,
    url: str,
    quality_label: str,
    source_tag: str = "",
    provider_id: str = "",
    subject_title: str = "",
    container: str = "",
    reachable: bool = False,
    note: str = "",
) -> PremiumLineRecord | None:
    """把一条播放线路转成清单项。不合格返回 None。"""
    stable_id = (subject_stable_id or "").strip()
    if not stable_id or not is_premium_quality(quality_label):
        return None
    host = media_host(url)
    digest = path_digest(url)
    if not host or not digest:
        return None
    return PremiumLineRecord(
        subject_stable_id=stable_id,
        episode=max(0, int(episode or 0)),
        quality_label=(quality_label or "").strip()[:60],
        source_tag=(source_tag or "").strip()[:60],
        provider_id=(provider_id or "").strip()[:60],
        subject_title=(subject_title or "").strip()[:300],
        media_host=host[:200],
        path_digest=digest,
        container=(container or "").strip().lower()[:20],
        reachable=bool(reachable),
        note=(note or "").strip(),
    )


async def record_premium_line(
    session: AsyncSession,
    record: PremiumLineRecord,
    *,
    now: float | None = None,
) -> bool:
    """登记或刷新一条清单项。→ 是否新建。

    同一 (作品, 集, 来源标识, 路径摘要) 视为同一条,重复出现只刷新时间戳。
    """
    stamp = time.time() if now is None else now
    existing = (
        await session.execute(
            select(PremiumLineCatalog).where(
                PremiumLineCatalog.subject_stable_id == record.subject_stable_id,
                PremiumLineCatalog.episode == record.episode,
                PremiumLineCatalog.source_tag == record.source_tag,
                PremiumLineCatalog.path_digest == record.path_digest,
            )
        )
    ).scalar_one_or_none()

    if existing is not None:
        existing.last_seen_at = stamp
        if record.reachable:
            existing.reachable_at = stamp
        if record.quality_label:
            existing.quality_label = record.quality_label
        if record.subject_title and not existing.subject_title:
            existing.subject_title = record.subject_title
        await session.flush()
        return False

    row = PremiumLineCatalog(
        subject_stable_id=record.subject_stable_id,
        episode=record.episode,
        subject_title=record.subject_title,
        quality_label=record.quality_label,
        source_tag=record.source_tag,
        provider_id=record.provider_id,
        media_host=record.media_host,
        path_digest=record.path_digest,
        container=record.container,
        discovered_at=stamp,
        last_seen_at=stamp,
        reachable_at=stamp if record.reachable else 0.0,
        note=record.note,
    )
    session.add(row)
    try:
        await session.flush()
    except IntegrityError:
        # 并发下另一路已插入同一条:退回刷新语义
        await session.rollback()
        return False
    return True


async def list_premium_lines(
    session: AsyncSession,
    *,
    subject_stable_id: str = "",
    limit: int = 500,
) -> list[dict]:
    """导出清单(已脱敏,可直接写文件交给运维)。"""
    statement = select(PremiumLineCatalog).order_by(
        PremiumLineCatalog.subject_stable_id,
        PremiumLineCatalog.episode,
    )
    if subject_stable_id:
        statement = statement.where(
            PremiumLineCatalog.subject_stable_id == subject_stable_id
        )
    rows = (await session.execute(statement.limit(max(1, limit)))).scalars().all()
    return [
        {
            "subject_stable_id": row.subject_stable_id,
            "subject_title": row.subject_title,
            "episode": row.episode,
            "quality_label": row.quality_label,
            "source_tag": row.source_tag,
            "provider_id": row.provider_id,
            "media_host": row.media_host,
            "path_digest": row.path_digest,
            "container": row.container,
            "discovered_at": row.discovered_at,
            "last_seen_at": row.last_seen_at,
            "reachable_at": row.reachable_at,
            "note": row.note,
        }
        for row in rows
    ]
