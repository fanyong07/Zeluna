"""Persist account-session expiry and JWT identifiers.

Revision ID: 0005_account_session_metadata
Revises: 0004_verification_code_attempts
"""

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "0005_account_session_metadata"
down_revision: Union[str, Sequence[str], None] = "0004_verification_code_attempts"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    existing = {
        column["name"]
        for column in sa.inspect(op.get_bind()).get_columns("user_tokens")
    }
    with op.batch_alter_table("user_tokens") as batch_op:
        if "token_id" not in existing:
            batch_op.add_column(
                sa.Column(
                    "token_id",
                    sa.String(length=100),
                    nullable=False,
                    server_default="",
                )
            )
        if "expires_at" not in existing:
            batch_op.add_column(
                sa.Column(
                    "expires_at",
                    sa.Float(),
                    nullable=False,
                    server_default="0",
                )
            )


def downgrade() -> None:
    existing = {
        column["name"]
        for column in sa.inspect(op.get_bind()).get_columns("user_tokens")
    }
    with op.batch_alter_table("user_tokens") as batch_op:
        if "expires_at" in existing:
            batch_op.drop_column("expires_at")
        if "token_id" in existing:
            batch_op.drop_column("token_id")
