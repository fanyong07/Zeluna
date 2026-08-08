"""Add durable encrypted verification-email outbox."""

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "0009_email_outbox"
down_revision: Union[str, Sequence[str], None] = "0008_account_refresh_sessions"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    inspector = sa.inspect(op.get_bind())
    if "email_outbox" in inspector.get_table_names():
        return
    op.create_table(
        "email_outbox",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("kind", sa.String(length=32), nullable=False),
        sa.Column("recipient", sa.String(length=255), nullable=False),
        sa.Column("encrypted_payload", sa.Text(), nullable=False),
        sa.Column(
            "status", sa.String(length=16), nullable=False, server_default="pending"
        ),
        sa.Column("attempts", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("next_attempt_at", sa.Float(), nullable=False, server_default="0"),
        sa.Column("created_at", sa.Float(), nullable=False),
        sa.Column("delivered_at", sa.Float(), nullable=False, server_default="0"),
        sa.Column("last_error_code", sa.String(length=64), nullable=False, server_default=""),
        sa.Column("claim_token", sa.String(length=96), nullable=False, server_default=""),
        sa.Column("locked_at", sa.Float(), nullable=False, server_default="0"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_email_outbox_kind", "email_outbox", ["kind"])
    op.create_index("ix_email_outbox_recipient", "email_outbox", ["recipient"])
    op.create_index("ix_email_outbox_status", "email_outbox", ["status"])
    op.create_index("ix_email_outbox_next_attempt_at", "email_outbox", ["next_attempt_at"])
    op.create_index("ix_email_outbox_claim_token", "email_outbox", ["claim_token"])


def downgrade() -> None:
    inspector = sa.inspect(op.get_bind())
    if "email_outbox" not in inspector.get_table_names():
        return
    for name in (
        "ix_email_outbox_claim_token",
        "ix_email_outbox_next_attempt_at",
        "ix_email_outbox_status",
        "ix_email_outbox_recipient",
        "ix_email_outbox_kind",
    ):
        op.drop_index(name, table_name="email_outbox")
    op.drop_table("email_outbox")
