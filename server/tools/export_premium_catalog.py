"""导出高画质线路清单,供运维自行寻源留存。

清单只含元数据:作品、集数、画质标注、来源标识、媒体主机、路径摘要。
**不含可播地址**——这类直链天数级失效,存了也用不了;实际取流须现场解析。

从 ``server/`` 运行::

    python tools/export_premium_catalog.py --format table
    python tools/export_premium_catalog.py --format json --output premium.json
    python tools/export_premium_catalog.py --subject bangumi:37654 --format csv
"""

from __future__ import annotations

import argparse
import asyncio
import csv
import io
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from server.database import async_session  # noqa: E402
from server.premium_catalog import list_premium_lines  # noqa: E402

_COLUMNS = (
    "subject_stable_id",
    "subject_title",
    "episode",
    "quality_label",
    "source_tag",
    "provider_id",
    "media_host",
    "path_digest",
    "container",
    "discovered_at",
    "last_seen_at",
    "reachable_at",
)


def _stamp(value: float) -> str:
    if not value:
        return "-"
    return datetime.fromtimestamp(value, tz=timezone.utc).strftime("%Y-%m-%d %H:%M")


def render_table(rows: list[dict]) -> str:
    if not rows:
        return "清单为空。播放过带高画质标注的线路后会自动登记。"
    lines = [
        f"{'作品':<24}{'集':>4}  {'画质':<18}{'来源':<10}{'主机':<28}"
        f"{'摘要':<18}{'最近可达':<18}"
    ]
    lines.append("-" * 122)
    for row in rows:
        title = (row["subject_title"] or row["subject_stable_id"])[:22]
        lines.append(
            f"{title:<24}{row['episode']:>4}  {row['quality_label'][:16]:<18}"
            f"{row['source_tag'][:8]:<10}{row['media_host'][:26]:<28}"
            f"{row['path_digest']:<18}{_stamp(row['reachable_at']):<18}"
        )
    lines.append("")
    lines.append(f"共 {len(rows)} 条。清单不含可播地址,取流请现场解析。")
    return "\n".join(lines)


def render_csv(rows: list[dict]) -> str:
    buffer = io.StringIO()
    writer = csv.DictWriter(buffer, fieldnames=list(_COLUMNS), extrasaction="ignore")
    writer.writeheader()
    for row in rows:
        writer.writerow(row)
    return buffer.getvalue()


async def main_async(args: argparse.Namespace) -> int:
    async with async_session() as session:
        rows = await list_premium_lines(
            session,
            subject_stable_id=args.subject or "",
            limit=args.limit,
        )

    if args.format == "json":
        payload = json.dumps(
            {"schema_version": 1, "count": len(rows), "lines": rows},
            ensure_ascii=False,
            indent=2,
        )
    elif args.format == "csv":
        payload = render_csv(rows)
    else:
        payload = render_table(rows)

    if args.output:
        Path(args.output).write_text(payload, encoding="utf-8")
        print(f"已写出 {len(rows)} 条 → {args.output}")
    else:
        print(payload)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--subject", help="只导出某个 stable_id")
    parser.add_argument(
        "--format", choices=("table", "json", "csv"), default="table"
    )
    parser.add_argument("--limit", type=int, default=500)
    parser.add_argument("--output", help="写入文件而不是打印")
    args = parser.parse_args()
    try:
        return asyncio.run(main_async(args))
    except KeyboardInterrupt:  # pragma: no cover
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
