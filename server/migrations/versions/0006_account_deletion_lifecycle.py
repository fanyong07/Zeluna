"""Add the reversible cloud-account deletion grace-period state.

Revision ID: 0006_account_deletion_lifecycle
Revises: 0005_account_session_metadata
"""

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "0006_account_deletion_lifecycle"
down_revision: Union[str, Sequence[str], None] = "0005_account_session_metadata"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    existing = {
        column["name"] for column in sa.inspect(op.get_bind()).get_columns("users")
    }
    with op.batch_alter_table("users") as batch_op:
        if "deletion_requested_at" not in existing:
            batch_op.add_column(
                sa.Column(
                    "deletion_requested_at",
                    sa.Float(),
                    nullable=False,
                    server_default="0",
                )
            )
        if "deletion_due_at" not in existing:
            batch_op.add_column(
                sa.Column(
                    "deletion_due_at",
                    sa.Float(),
                    nullable=False,
                    server_default="0",
                )
            )


def downgrade() -> None:
    existing = {
        column["name"] for column in sa.inspect(op.get_bind()).get_columns("users")
    }
    with op.batch_alter_table("users") as batch_op:
        if "deletion_due_at" in existing:
            batch_op.drop_column("deletion_due_at")
        if "deletion_requested_at" in existing:
            batch_op.drop_column("deletion_requested_at")
