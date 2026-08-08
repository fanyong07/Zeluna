"""Add low-cardinality retry state for isolated account deletion."""

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "0010_account_deletion_retry_state"
down_revision: Union[str, Sequence[str], None] = "0009_email_outbox"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _columns() -> set[str]:
    return {column["name"] for column in sa.inspect(op.get_bind()).get_columns("users")}


def upgrade() -> None:
    existing = _columns()
    with op.batch_alter_table("users") as batch_op:
        if "deletion_attempts" not in existing:
            batch_op.add_column(
                sa.Column("deletion_attempts", sa.Integer(), nullable=False, server_default="0")
            )
        if "deletion_last_attempt_at" not in existing:
            batch_op.add_column(
                sa.Column(
                    "deletion_last_attempt_at",
                    sa.Float(),
                    nullable=False,
                    server_default="0",
                )
            )
        if "deletion_last_error_code" not in existing:
            batch_op.add_column(
                sa.Column(
                    "deletion_last_error_code",
                    sa.String(length=64),
                    nullable=False,
                    server_default="",
                )
            )


def downgrade() -> None:
    existing = _columns()
    with op.batch_alter_table("users") as batch_op:
        for name in (
            "deletion_last_error_code",
            "deletion_last_attempt_at",
            "deletion_attempts",
        ):
            if name in existing:
                batch_op.drop_column(name)
