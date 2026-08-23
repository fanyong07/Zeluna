"""Add administrator-managed remote playback lines."""

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "0013_managed_playback_lines"
down_revision: Union[str, Sequence[str], None] = "0012_community_danmaku"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    inspector = sa.inspect(op.get_bind())
    if "managed_playback_lines" not in inspector.get_table_names():
        op.create_table(
            "managed_playback_lines",
            sa.Column("id", sa.String(length=64), nullable=False),
            sa.Column("stable_id", sa.String(length=200), nullable=False),
            sa.Column("episode", sa.Integer(), nullable=False),
            sa.Column(
                "provider_key",
                sa.String(length=100),
                server_default="managed.main",
                nullable=False,
            ),
            sa.Column("label", sa.String(length=200), server_default="", nullable=False),
            sa.Column("quality", sa.String(length=50), server_default="", nullable=False),
            sa.Column(
                "format_hint", sa.String(length=20), server_default="auto", nullable=False
            ),
            sa.Column("canonical_url", sa.Text(), nullable=False),
            sa.Column(
                "url_kind",
                sa.String(length=30),
                server_default="static_direct",
                nullable=False,
            ),
            sa.Column("expires_at", sa.Float(), server_default="0", nullable=False),
            sa.Column("headers_json", sa.Text(), server_default="{}", nullable=False),
            sa.Column("priority", sa.Integer(), server_default="500", nullable=False),
            sa.Column("status", sa.String(length=20), server_default="draft", nullable=False),
            sa.Column(
                "review_status",
                sa.String(length=20),
                server_default="pending",
                nullable=False,
            ),
            sa.Column("enabled", sa.Boolean(), server_default="0", nullable=False),
            sa.Column("provenance_kind", sa.String(length=40), nullable=False),
            sa.Column(
                "rights_reference",
                sa.String(length=500),
                server_default="",
                nullable=False,
            ),
            sa.Column("operator_note", sa.Text(), server_default="", nullable=False),
            sa.Column(
                "last_verified_status",
                sa.String(length=40),
                server_default="unverified",
                nullable=False,
            ),
            sa.Column("last_verified_at", sa.Float(), server_default="0", nullable=False),
            sa.Column(
                "last_error_category",
                sa.String(length=50),
                server_default="",
                nullable=False,
            ),
            sa.Column("last_latency_ms", sa.Integer(), server_default="0", nullable=False),
            sa.Column("created_at", sa.Float(), nullable=False),
            sa.Column("updated_at", sa.Float(), nullable=False),
            sa.Column("published_at", sa.Float(), server_default="0", nullable=False),
            sa.Column("revoked_at", sa.Float(), server_default="0", nullable=False),
            sa.CheckConstraint(
                "episode >= 1", name="ck_managed_line_episode_positive"
            ),
            sa.CheckConstraint(
                "priority >= 0 AND priority <= 1000",
                name="ck_managed_line_priority_range",
            ),
            sa.CheckConstraint(
                "url_kind IN ('static_direct')", name="ck_managed_line_url_kind"
            ),
            sa.CheckConstraint(
                "status IN ('draft', 'active', 'degraded', 'quarantined', 'revoked')",
                name="ck_managed_line_status",
            ),
            sa.CheckConstraint(
                "review_status IN ('pending', 'approved', 'rejected')",
                name="ck_managed_line_review_status",
            ),
            sa.CheckConstraint(
                "provenance_kind IN ('owned', 'licensed', 'public_domain', "
                "'open_license', 'authorized_third_party', 'user_managed')",
                name="ck_managed_line_provenance_kind",
            ),
            sa.PrimaryKeyConstraint("id"),
        )
    indexes = {
        index["name"]
        for index in sa.inspect(op.get_bind()).get_indexes("managed_playback_lines")
    }
    for name, columns in (
        ("ix_managed_playback_lines_stable_id", ["stable_id"]),
        ("ix_managed_playback_lines_status", ["status"]),
        ("ix_managed_playback_lines_review_status", ["review_status"]),
        ("ix_managed_playback_lines_enabled", ["enabled"]),
        (
            "ix_managed_playback_lines_lookup",
            ["stable_id", "episode", "enabled", "status", "review_status"],
        ),
    ):
        if name not in indexes:
            op.create_index(name, "managed_playback_lines", columns)


def downgrade() -> None:
    if "managed_playback_lines" in sa.inspect(op.get_bind()).get_table_names():
        op.drop_table("managed_playback_lines")
