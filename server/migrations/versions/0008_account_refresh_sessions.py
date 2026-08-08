"""Add device-scoped refresh sessions and digest-only rotation history."""

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "0008_account_refresh_sessions"
down_revision: Union[str, Sequence[str], None] = "0007_incremental_cloud_sync"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _columns(table: str) -> set[str]:
    return {column["name"] for column in sa.inspect(op.get_bind()).get_columns(table)}


def upgrade() -> None:
    existing = _columns("user_tokens")
    with op.batch_alter_table("user_tokens") as batch_op:
        additions = {
            "session_id": sa.Column("session_id", sa.String(length=96), nullable=True),
            "device_id": sa.Column(
                "device_id", sa.String(length=128), nullable=False, server_default=""
            ),
            "device_name": sa.Column(
                "device_name", sa.String(length=80), nullable=False, server_default=""
            ),
            "platform": sa.Column(
                "platform", sa.String(length=32), nullable=False, server_default=""
            ),
            "token_family_id": sa.Column(
                "token_family_id", sa.String(length=96), nullable=False, server_default=""
            ),
            "last_used_at": sa.Column(
                "last_used_at", sa.Float(), nullable=False, server_default="0"
            ),
            "revoked_at": sa.Column(
                "revoked_at", sa.Float(), nullable=False, server_default="0"
            ),
            "refresh_rotated_at": sa.Column(
                "refresh_rotated_at", sa.Float(), nullable=False, server_default="0"
            ),
        }
        for name, column in additions.items():
            if name not in existing:
                batch_op.add_column(column)

    inspector = sa.inspect(op.get_bind())
    indexes = {index["name"] for index in inspector.get_indexes("user_tokens")}
    if "ix_user_tokens_session_id" not in indexes:
        op.create_index("ix_user_tokens_session_id", "user_tokens", ["session_id"], unique=True)
    if "ix_user_tokens_token_family_id" not in indexes:
        op.create_index(
            "ix_user_tokens_token_family_id", "user_tokens", ["token_family_id"], unique=False
        )
    if "ix_user_tokens_revoked_at" not in indexes:
        op.create_index("ix_user_tokens_revoked_at", "user_tokens", ["revoked_at"], unique=False)

    if "refresh_token_history" not in sa.inspect(op.get_bind()).get_table_names():
        op.create_table(
            "refresh_token_history",
            sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
            sa.Column("user_id", sa.Integer(), nullable=False),
            sa.Column("session_id", sa.String(length=96), nullable=False),
            sa.Column("token_family_id", sa.String(length=96), nullable=False),
            sa.Column("digest", sa.String(length=128), nullable=False),
            sa.Column("created_at", sa.Float(), nullable=False),
            sa.Column("used_at", sa.Float(), nullable=False, server_default="0"),
            sa.Column(
                "replaced_by_digest", sa.String(length=128), nullable=False, server_default=""
            ),
            sa.Column("reuse_detected_at", sa.Float(), nullable=False, server_default="0"),
            sa.PrimaryKeyConstraint("id"),
            sa.UniqueConstraint("digest"),
        )
        op.create_index(
            "ix_refresh_token_history_user_id", "refresh_token_history", ["user_id"], unique=False
        )
        op.create_index(
            "ix_refresh_token_history_session_id",
            "refresh_token_history",
            ["session_id"],
            unique=False,
        )
        op.create_index(
            "ix_refresh_token_history_token_family_id",
            "refresh_token_history",
            ["token_family_id"],
            unique=False,
        )
        op.create_index(
            "ix_refresh_token_history_digest", "refresh_token_history", ["digest"], unique=True
        )


def downgrade() -> None:
    if "refresh_token_history" in sa.inspect(op.get_bind()).get_table_names():
        for name in (
            "ix_refresh_token_history_digest",
            "ix_refresh_token_history_token_family_id",
            "ix_refresh_token_history_session_id",
            "ix_refresh_token_history_user_id",
        ):
            op.drop_index(name, table_name="refresh_token_history")
        op.drop_table("refresh_token_history")

    existing_indexes = {
        index["name"] for index in sa.inspect(op.get_bind()).get_indexes("user_tokens")
    }
    for name in (
        "ix_user_tokens_revoked_at",
        "ix_user_tokens_token_family_id",
        "ix_user_tokens_session_id",
    ):
        if name in existing_indexes:
            op.drop_index(name, table_name="user_tokens")

    existing = _columns("user_tokens")
    for name in (
        "refresh_rotated_at",
        "revoked_at",
        "last_used_at",
        "token_family_id",
        "platform",
        "device_name",
        "device_id",
        "session_id",
    ):
        if name in existing:
            with op.batch_alter_table("user_tokens") as batch_op:
                batch_op.drop_column(name)
