"""Deduplicate playback cache rows and enforce one row per episode.

Revision ID: 0002_playback_cache_unique
Revises: 0001_baseline
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "0002_playback_cache_unique"
down_revision: Union[str, Sequence[str], None] = "0001_baseline"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

_INDEX_NAME = "uq_playback_cache_subject_episode"


def _has_unique_index() -> bool:
    inspector = sa.inspect(op.get_bind())
    return any(
        item.get("name") == _INDEX_NAME
        for item in inspector.get_indexes("playback_cache")
    )


def _has_legacy_unique_constraint() -> bool:
    inspector = sa.inspect(op.get_bind())
    return any(
        item.get("name") == _INDEX_NAME
        for item in inspector.get_unique_constraints("playback_cache")
    )


def upgrade() -> None:
    op.execute(sa.text("""
        DELETE FROM playback_cache
        WHERE id NOT IN (
            SELECT MAX(id)
            FROM playback_cache
            GROUP BY subject_id, episode
        )
    """))
    if _has_legacy_unique_constraint() and not _has_unique_index():
        with op.batch_alter_table("playback_cache") as batch_op:
            batch_op.drop_constraint(_INDEX_NAME, type_="unique")
    if not _has_unique_index():
        op.create_index(
            _INDEX_NAME,
            "playback_cache",
            ["subject_id", "episode"],
            unique=True,
        )


def downgrade() -> None:
    inspector = sa.inspect(op.get_bind())
    if any(
        item.get("name") == _INDEX_NAME
        for item in inspector.get_indexes("playback_cache")
    ):
        op.drop_index(_INDEX_NAME, table_name="playback_cache")
