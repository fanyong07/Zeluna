"""Persist verification-code purpose and failed-attempt budgets.

Revision ID: 0004_verification_code_attempts
Revises: 0003_source_health_diagnostics
"""

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "0004_verification_code_attempts"
down_revision: Union[str, Sequence[str], None] = "0003_source_health_diagnostics"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    existing = {
        column["name"]
        for column in sa.inspect(op.get_bind()).get_columns("verify_codes")
    }
    with op.batch_alter_table("verify_codes") as batch_op:
        if "purpose" not in existing:
            batch_op.add_column(
                sa.Column(
                    "purpose",
                    sa.String(length=32),
                    nullable=False,
                    server_default="legacy",
                )
            )
        if "failed_attempts" not in existing:
            batch_op.add_column(
                sa.Column(
                    "failed_attempts",
                    sa.Integer(),
                    nullable=False,
                    server_default="0",
                )
            )


def downgrade() -> None:
    existing = {
        column["name"]
        for column in sa.inspect(op.get_bind()).get_columns("verify_codes")
    }
    with op.batch_alter_table("verify_codes") as batch_op:
        if "failed_attempts" in existing:
            batch_op.drop_column("failed_attempts")
        if "purpose" in existing:
            batch_op.drop_column("purpose")
