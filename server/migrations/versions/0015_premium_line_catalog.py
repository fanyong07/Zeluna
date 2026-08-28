"""Add a metadata-only catalog of premium (re-encoded) playback lines.

Operators want a record of which high-quality renditions were seen for a given
episode so they can source those files themselves. Storing the full signed URL
would be useless (these links rot within days) and would widen the exposure
surface, so the table keeps only the media host plus a short path digest.
It never contains media bytes.

Revision ID: 0015_premium_line_catalog
Revises: 0014_playback_cache_scan_scope
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "0015_premium_line_catalog"
down_revision: Union[str, Sequence[str], None] = "0014_playback_cache_scan_scope"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

_TABLE = "premium_line_catalog"


def upgrade() -> None:
    inspector = sa.inspect(op.get_bind())
    if _TABLE in set(inspector.get_table_names()):
        return
    op.create_table(
        _TABLE,
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("subject_stable_id", sa.String(length=200), nullable=False),
        sa.Column(
            "episode", sa.Integer(), nullable=False, server_default="0"
        ),
        sa.Column(
            "subject_title", sa.String(length=300), nullable=False,
            server_default="",
        ),
        sa.Column(
            "quality_label", sa.String(length=60), nullable=False,
            server_default="",
        ),
        sa.Column(
            "source_tag", sa.String(length=60), nullable=False, server_default=""
        ),
        sa.Column(
            "provider_id", sa.String(length=60), nullable=False, server_default=""
        ),
        sa.Column(
            "media_host", sa.String(length=200), nullable=False, server_default=""
        ),
        sa.Column(
            "path_digest", sa.String(length=32), nullable=False, server_default=""
        ),
        sa.Column(
            "container", sa.String(length=20), nullable=False, server_default=""
        ),
        sa.Column(
            "discovered_at", sa.Float(), nullable=False, server_default="0"
        ),
        sa.Column("last_seen_at", sa.Float(), nullable=False, server_default="0"),
        sa.Column("reachable_at", sa.Float(), nullable=False, server_default="0"),
        sa.Column("note", sa.Text(), nullable=False, server_default=""),
        sa.CheckConstraint("episode >= 0", name="ck_premium_line_episode"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "subject_stable_id",
            "episode",
            "source_tag",
            "path_digest",
            name="uq_premium_line_identity",
        ),
    )
    op.create_index(
        "ix_premium_line_catalog_subject_stable_id",
        _TABLE,
        ["subject_stable_id"],
    )
    op.create_index(
        "ix_premium_line_lookup",
        _TABLE,
        ["subject_stable_id", "episode", "quality_label"],
    )


def downgrade() -> None:
    inspector = sa.inspect(op.get_bind())
    if _TABLE not in set(inspector.get_table_names()):
        return
    op.drop_index("ix_premium_line_lookup", table_name=_TABLE)
    op.drop_index(
        "ix_premium_line_catalog_subject_stable_id", table_name=_TABLE
    )
    op.drop_table(_TABLE)
