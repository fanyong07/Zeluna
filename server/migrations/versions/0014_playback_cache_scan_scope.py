"""Record whether a playback cache row came from a quick or full scan.

A quick refresh only reaches the first wave of sources and fills the rest of
the inventory with ``not_queried`` placeholders. Without this marker a later
full request treats that partial row as a complete answer and skips its own
discovery, so unreached sources keep reporting "本轮未查询该来源" for the
whole TTL window.

Revision ID: 0014_playback_cache_scan_scope
Revises: 0013_managed_playback_lines
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "0014_playback_cache_scan_scope"
down_revision: Union[str, Sequence[str], None] = "0013_managed_playback_lines"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    existing = {
        column["name"]
        for column in sa.inspect(op.get_bind()).get_columns("playback_cache")
    }
    if "scan_scope" in existing:
        return
    with op.batch_alter_table("playback_cache") as batch_op:
        batch_op.add_column(
            sa.Column(
                "scan_scope",
                sa.String(length=10),
                nullable=False,
                server_default="full",
            )
        )
    # Existing rows predate the distinction. Marking them "quick" forces one
    # fresh full scan per subject instead of trusting a row that may have been
    # written by a quick refresh.
    op.execute(sa.text("UPDATE playback_cache SET scan_scope = 'quick'"))


def downgrade() -> None:
    with op.batch_alter_table("playback_cache") as batch_op:
        batch_op.drop_column("scan_scope")
