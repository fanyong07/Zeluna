"""Add stable-identity community danmaku storage."""

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "0012_community_danmaku"
down_revision: Union[str, Sequence[str], None] = "0011_catalog_rankings"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    inspector = sa.inspect(op.get_bind())
    if "community_danmaku" not in inspector.get_table_names():
        op.create_table(
            "community_danmaku",
            sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
            sa.Column("subject_key", sa.String(length=300), nullable=False),
            sa.Column("episode_key", sa.String(length=300), nullable=False),
            sa.Column("user_id", sa.Integer(), nullable=True),
            sa.Column("time_seconds", sa.Float(), nullable=False),
            sa.Column("mode", sa.String(length=16), nullable=False),
            sa.Column("color", sa.Integer(), nullable=False),
            sa.Column("text", sa.String(length=200), nullable=False),
            sa.Column("created_at", sa.Float(), nullable=False),
            sa.ForeignKeyConstraint(
                ["user_id"], ["users.id"], ondelete="SET NULL"
            ),
            sa.PrimaryKeyConstraint("id"),
        )
    existing_indexes = {
        index["name"]
        for index in sa.inspect(op.get_bind()).get_indexes("community_danmaku")
    }
    if "ix_community_danmaku_created_at" not in existing_indexes:
        op.create_index(
            "ix_community_danmaku_created_at",
            "community_danmaku",
            ["created_at"],
        )
    if "ix_community_danmaku_episode_cursor" not in existing_indexes:
        op.create_index(
            "ix_community_danmaku_episode_cursor",
            "community_danmaku",
            ["subject_key", "episode_key", "id"],
        )
    if "ix_community_danmaku_user_id" not in existing_indexes:
        op.create_index(
            "ix_community_danmaku_user_id", "community_danmaku", ["user_id"]
        )


def downgrade() -> None:
    if "community_danmaku" in sa.inspect(op.get_bind()).get_table_names():
        op.drop_table("community_danmaku")
