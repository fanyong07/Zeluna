"""Add recent source health diagnostics used for playback ordering.

Revision ID: 0003_source_health_diagnostics
Revises: 0002_playback_cache_unique
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "0003_source_health_diagnostics"
down_revision: Union[str, Sequence[str], None] = "0002_playback_cache_unique"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    existing = {
        column["name"]
        for column in sa.inspect(op.get_bind()).get_columns("source_health")
    }
    with op.batch_alter_table("source_health") as batch_op:
        if "last_error_category" not in existing:
            batch_op.add_column(sa.Column(
                "last_error_category",
                sa.String(length=50),
                nullable=False,
                server_default="",
            ))
        if "last_success_at" not in existing:
            batch_op.add_column(sa.Column(
                "last_success_at",
                sa.Float(),
                nullable=False,
                server_default="0",
            ))
        if "last_failure_at" not in existing:
            batch_op.add_column(sa.Column(
                "last_failure_at",
                sa.Float(),
                nullable=False,
                server_default="0",
            ))
        if "recent_success_rate" not in existing:
            batch_op.add_column(sa.Column(
                "recent_success_rate",
                sa.Float(),
                nullable=False,
                server_default="0.5",
            ))

    if "recent_success_rate" not in existing:
        op.execute(sa.text("""
            UPDATE source_health
            SET recent_success_rate = CASE
                WHEN last_status = 'healthy' THEN 1.0
                WHEN last_status = 'client_probe_required' THEN 0.65
                WHEN last_status = 'unhealthy' THEN 0.0
                ELSE 0.5
            END
        """))
    if "last_success_at" not in existing:
        op.execute(sa.text("""
            UPDATE source_health
            SET last_success_at = CASE
                WHEN last_status = 'healthy' THEN last_checked_at
                ELSE 0
            END
        """))
    if "last_failure_at" not in existing:
        op.execute(sa.text("""
            UPDATE source_health
            SET last_failure_at = CASE
                WHEN last_status = 'unhealthy' THEN last_checked_at
                ELSE 0
            END
        """))


def downgrade() -> None:
    with op.batch_alter_table("source_health") as batch_op:
        batch_op.drop_column("recent_success_rate")
        batch_op.drop_column("last_failure_at")
        batch_op.drop_column("last_success_at")
        batch_op.drop_column("last_error_category")
