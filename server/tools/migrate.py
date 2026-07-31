"""Apply Zeluna database migrations with a safe SQLite backup first."""
from __future__ import annotations

import argparse
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

from alembic import command
from alembic.config import Config
from sqlalchemy.engine import make_url

SERVER_ROOT = Path(__file__).resolve().parents[1]
if str(SERVER_ROOT) not in sys.path:
    sys.path.insert(0, str(SERVER_ROOT))

from server.config import DATABASE_URL  # noqa: E402


def _config() -> Config:
    config = Config(str(SERVER_ROOT / "alembic.ini"))
    config.set_main_option("script_location", str(SERVER_ROOT / "migrations"))
    return config


def _sqlite_database_path() -> Path | None:
    url = make_url(DATABASE_URL)
    if url.get_backend_name() != "sqlite" or not url.database:
        return None
    if url.database == ":memory:":
        return None
    path = Path(url.database)
    if not path.is_absolute():
        path = SERVER_ROOT / path
    return path.resolve()


def backup_sqlite_database() -> Path | None:
    source_path = _sqlite_database_path()
    if source_path is None or not source_path.exists():
        return None
    backup_dir = source_path.parent / "backups"
    backup_dir.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    backup_path = backup_dir / f"{source_path.stem}-{timestamp}.pre-migration.db"
    with sqlite3.connect(source_path) as source:
        with sqlite3.connect(backup_path) as destination:
            source.backup(destination)
    return backup_path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    upgrade = subparsers.add_parser("upgrade", help="Back up SQLite and upgrade")
    upgrade.add_argument("revision", nargs="?", default="head")
    current = subparsers.add_parser("current", help="Show current revision")
    current.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    config = _config()
    if args.command == "upgrade":
        backup_path = backup_sqlite_database()
        if backup_path is not None:
            print(f"SQLite backup: {backup_path}")
        command.upgrade(config, args.revision)
        print(f"Database upgraded to {args.revision}")
    else:
        command.current(config, verbose=args.verbose)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
