"""Add account-scoped incremental cloud synchronization tables.

Revision ID: 0007_incremental_cloud_sync
Revises: 0006_account_deletion_lifecycle
"""

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "0007_incremental_cloud_sync"
down_revision: Union[str, Sequence[str], None] = "0006_account_deletion_lifecycle"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    expected_tables = {"sync_revisions", "sync_records", "sync_mutations"}
    existing_tables = set(sa.inspect(op.get_bind()).get_table_names())
    existing_sync_tables = expected_tables & existing_tables
    if existing_sync_tables == expected_tables:
        return
    if existing_sync_tables:
        raise RuntimeError(
            "Partial cloud-sync schema detected; restore or complete the schema "
            "before retrying migration 0007"
        )
    op.create_table(
        "sync_revisions",
        sa.Column("revision", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("user_id", sa.Integer(), nullable=False),
        sa.Column("created_at", sa.Float(), nullable=False),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("revision"),
    )
    op.create_index(
        op.f("ix_sync_revisions_user_id"),
        "sync_revisions",
        ["user_id"],
        unique=False,
    )

    op.create_table(
        "sync_records",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("user_id", sa.Integer(), nullable=False),
        sa.Column("record_id", sa.String(length=300), nullable=False),
        sa.Column("record_type", sa.String(length=40), nullable=False),
        sa.Column("schema_version", sa.Integer(), nullable=False),
        sa.Column("payload_json", sa.Text(), nullable=False),
        sa.Column("created_at", sa.Float(), nullable=False),
        sa.Column("updated_at", sa.Float(), nullable=False),
        sa.Column("deleted", sa.Boolean(), nullable=False),
        sa.Column("last_mutation_id", sa.String(length=100), nullable=False),
        sa.Column("revision", sa.Integer(), nullable=False),
        sa.ForeignKeyConstraint(["revision"], ["sync_revisions.revision"]),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "user_id",
            "record_type",
            "record_id",
            name="uq_sync_record_owner_type_id",
        ),
    )
    op.create_index(
        op.f("ix_sync_records_revision"),
        "sync_records",
        ["revision"],
        unique=False,
    )
    op.create_index(
        op.f("ix_sync_records_user_id"),
        "sync_records",
        ["user_id"],
        unique=False,
    )
    op.create_index(
        "ix_sync_records_user_revision",
        "sync_records",
        ["user_id", "revision"],
        unique=False,
    )

    op.create_table(
        "sync_mutations",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("user_id", sa.Integer(), nullable=False),
        sa.Column("mutation_id", sa.String(length=100), nullable=False),
        sa.Column("payload_hash", sa.String(length=64), nullable=False),
        sa.Column("record_id", sa.String(length=300), nullable=False),
        sa.Column("record_type", sa.String(length=40), nullable=False),
        sa.Column("revision", sa.Integer(), nullable=False),
        sa.Column("created_at", sa.Float(), nullable=False),
        sa.ForeignKeyConstraint(["revision"], ["sync_revisions.revision"]),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "user_id", "mutation_id", name="uq_sync_mutation_owner_id"
        ),
    )
    op.create_index(
        op.f("ix_sync_mutations_revision"),
        "sync_mutations",
        ["revision"],
        unique=False,
    )
    op.create_index(
        op.f("ix_sync_mutations_user_id"),
        "sync_mutations",
        ["user_id"],
        unique=False,
    )


def downgrade() -> None:
    op.drop_index(op.f("ix_sync_mutations_user_id"), table_name="sync_mutations")
    op.drop_index(op.f("ix_sync_mutations_revision"), table_name="sync_mutations")
    op.drop_table("sync_mutations")
    op.drop_index("ix_sync_records_user_revision", table_name="sync_records")
    op.drop_index(op.f("ix_sync_records_user_id"), table_name="sync_records")
    op.drop_index(op.f("ix_sync_records_revision"), table_name="sync_records")
    op.drop_table("sync_records")
    op.drop_index(op.f("ix_sync_revisions_user_id"), table_name="sync_revisions")
    op.drop_table("sync_revisions")
