"""Persist home-ranking evidence separately from catalog metadata freshness."""

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "0011_catalog_rankings"
down_revision: Union[str, Sequence[str], None] = "0010_account_deletion_retry_state"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _columns() -> set[str]:
    return {
        column["name"]
        for column in sa.inspect(op.get_bind()).get_columns("catalog_subjects")
    }


def _indexes() -> set[str]:
    return {
        index["name"]
        for index in sa.inspect(op.get_bind()).get_indexes("catalog_subjects")
    }


def upgrade() -> None:
    existing = _columns()
    with op.batch_alter_table("catalog_subjects") as batch_op:
        if "ranking_json" not in existing:
            batch_op.add_column(
                sa.Column(
                    "ranking_json",
                    sa.Text(),
                    nullable=False,
                    server_default="{}",
                )
            )
        if "ranking_score" not in existing:
            batch_op.add_column(
                sa.Column(
                    "ranking_score",
                    sa.Float(),
                    nullable=False,
                    server_default="0",
                )
            )
        if "ranked_at" not in existing:
            batch_op.add_column(
                sa.Column(
                    "ranked_at",
                    sa.Float(),
                    nullable=False,
                    server_default="0",
                )
            )
    if "ix_catalog_subjects_home_rank" not in _indexes():
        op.create_index(
            "ix_catalog_subjects_home_rank",
            "catalog_subjects",
            ["media_type", "ranked_at", "ranking_score"],
        )


def downgrade() -> None:
    if "ix_catalog_subjects_home_rank" in _indexes():
        op.drop_index("ix_catalog_subjects_home_rank", table_name="catalog_subjects")
    existing = _columns()
    with op.batch_alter_table("catalog_subjects") as batch_op:
        for name in ("ranked_at", "ranking_score", "ranking_json"):
            if name in existing:
                batch_op.drop_column(name)
