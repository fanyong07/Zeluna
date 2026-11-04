"""Cache resolved addresses for the upstream self-hosted CDN wrapper hosts.

The aggregator's self-hosted lines are 302 wrappers: the URL in the line pool
points at a resolver (``v-cdn.emmmm.eu.org`` / ``vod-cdn.sends.eu.org``) which
redirects to a real media object on a third-party CDN. The wrapper itself
answers 403 to this deployment's egress IP (Cloudflare error 1006, an IP-level
ban), so the redirect has to be resolved through a separate outbound and the
result cached here.

Two lifetimes coexist and must not be conflated:
  * ``emmmm`` family redirects carry ``x-expires`` — signed, roughly 30 days;
  * ``sends`` family redirects carry no signature and stay valid far longer.

``expires_at = 0`` therefore means "no signature observed, treat as durable"
rather than "unknown", so readers can distinguish it from a real deadline.

Only the resolved address is stored; no media bytes ever land in this table.

Revision ID: 0016_anich_resolved_addresses
Revises: 0015_premium_line_catalog
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "0016_anich_resolved_addresses"
down_revision: Union[str, Sequence[str], None] = "0015_premium_line_catalog"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

_TABLE = "anich_resolved_addresses"


def upgrade() -> None:
    inspector = sa.inspect(op.get_bind())
    if _TABLE in set(inspector.get_table_names()):
        return
    op.create_table(
        _TABLE,
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        # 包装地址(线路池里那条自建域地址)是稳定键:实测连续三次取线路池
        # 返回完全相同的地址,所以它可以直接当缓存键。
        sa.Column("wrap_url", sa.Text(), nullable=False),
        sa.Column("real_url", sa.Text(), nullable=False),
        sa.Column(
            "host_family", sa.String(length=30), nullable=False,
            server_default="",
        ),
        sa.Column(
            "resolved_at", sa.Float(), nullable=False, server_default="0",
        ),
        # 0 = 重定向未带签名参数,按长期有效处理;>0 = 签名到期时刻。
        sa.Column(
            "expires_at", sa.Float(), nullable=False, server_default="0",
        ),
        sa.Column(
            "verify_ok", sa.Boolean(), nullable=False, server_default="0",
        ),
        sa.Column(
            "verified_at", sa.Float(), nullable=False, server_default="0",
        ),
        sa.Column(
            "fail_count", sa.Integer(), nullable=False, server_default="0",
        ),
        sa.Column(
            "last_error", sa.String(length=200), nullable=False,
            server_default="",
        ),
        sa.Column(
            "latency_ms", sa.Integer(), nullable=False, server_default="0",
        ),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(
        "uq_anich_resolved_wrap_url",
        _TABLE,
        ["wrap_url"],
        unique=True,
    )
    op.create_index(
        "ix_anich_resolved_expires_at",
        _TABLE,
        ["expires_at"],
        unique=False,
    )


def downgrade() -> None:
    op.drop_index("ix_anich_resolved_expires_at", table_name=_TABLE)
    op.drop_index("uq_anich_resolved_wrap_url", table_name=_TABLE)
    op.drop_table(_TABLE)