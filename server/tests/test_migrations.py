import asyncio
import sqlite3
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine, inspect, text
from sqlalchemy.ext.asyncio import create_async_engine

from server.database import (
    Base,
    create_database_engine,
    migration_head_revision,
    verify_database_schema,
)
from tools import migrate


SERVER_ROOT = Path(__file__).resolve().parents[1]


def _config(database_path: Path) -> Config:
    config = Config(str(SERVER_ROOT / "alembic.ini"))
    config.set_main_option("script_location", str(SERVER_ROOT / "migrations"))
    config.set_main_option(
        "sqlalchemy.url",
        f"sqlite:///{database_path.as_posix()}",
    )
    return config


def _revision(database_path: Path) -> str | None:
    with sqlite3.connect(database_path) as connection:
        row = connection.execute(
            "SELECT version_num FROM alembic_version"
        ).fetchone()
    return str(row[0]) if row else None


def test_empty_database_upgrades_to_head_and_rolls_back(tmp_path):
    database_path = tmp_path / "empty.db"
    config = _config(database_path)

    command.upgrade(config, "head")
    command.check(config)

    engine = create_engine(f"sqlite:///{database_path.as_posix()}")
    try:
        tables = set(inspect(engine).get_table_names())
        assert set(Base.metadata.tables).issubset(tables)
        assert _revision(database_path) == migration_head_revision()
    finally:
        engine.dispose()

    async_engine = create_async_engine(
        f"sqlite+aiosqlite:///{database_path.as_posix()}"
    )
    try:
        assert asyncio.run(verify_database_schema(async_engine)) == (
            migration_head_revision()
        )
    finally:
        asyncio.run(async_engine.dispose())

    command.downgrade(config, "base")
    engine = create_engine(f"sqlite:///{database_path.as_posix()}")
    try:
        assert not (set(Base.metadata.tables) & set(inspect(engine).get_table_names()))
    finally:
        engine.dispose()


def test_upgrade_head_is_idempotent_and_preserves_rows(tmp_path):
    database_path = tmp_path / "repeated.db"
    config = _config(database_path)
    command.upgrade(config, "head")
    with sqlite3.connect(database_path) as connection:
        connection.execute(
            """
            INSERT INTO users (
                email, name, password_hash, role, sex, avatar, exp, coin,
                color, address, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                "repeat@example.com",
                "repeat-user",
                "hash",
                "user",
                "",
                "",
                0,
                0,
                "#000000",
                "",
                1,
                1,
            ),
        )

    command.upgrade(config, "head")
    command.check(config)

    with sqlite3.connect(database_path) as connection:
        count = connection.execute(
            "SELECT COUNT(*) FROM users WHERE email = ?",
            ("repeat@example.com",),
        ).fetchone()[0]
    assert count == 1
    assert _revision(database_path) == migration_head_revision()


def test_verification_attempt_migration_preserves_legacy_codes(tmp_path):
    database_path = tmp_path / "verification-attempts.db"
    config = _config(database_path)
    command.upgrade(config, "0003_source_health_diagnostics")
    with sqlite3.connect(database_path) as connection:
        connection.execute(
            """
            INSERT INTO verify_codes (email, code, created_at, expires_at)
            VALUES (?, ?, ?, ?)
            """,
            ("legacy@example.com", "legacy-digest", 1.0, 2.0),
        )

    command.upgrade(config, "head")
    with sqlite3.connect(database_path) as connection:
        row = connection.execute(
            """
            SELECT code, purpose, failed_attempts
            FROM verify_codes WHERE email = ?
            """,
            ("legacy@example.com",),
        ).fetchone()

    assert row == ("legacy-digest", "legacy", 0)
    assert _revision(database_path) == migration_head_revision()


def test_existing_schema_deduplicates_cache_and_preserves_data(tmp_path):
    database_path = tmp_path / "existing.db"
    url = f"sqlite:///{database_path.as_posix()}"
    engine = create_engine(url)
    Base.metadata.create_all(engine)
    with engine.begin() as connection:
        connection.execute(text("DROP INDEX uq_playback_cache_subject_episode"))
        connection.execute(text("""
            INSERT INTO users (
                email, name, password_hash, role, sex, avatar, exp, coin,
                color, address, created_at, updated_at
            ) VALUES (
                'kept@example.com', 'kept-user', 'hash', 'user', '', '', 0, 0,
                '#000000', '', 1, 1
            )
        """))
        connection.execute(text("""
            INSERT INTO playback_cache (
                subject_id, episode, title, lines_json, line_count,
                verified_at, created_at
            ) VALUES
                ('bangumi:1', 1, 'old', '[1]', 1, 1, 1),
                ('bangumi:1', 1, 'new', '[2]', 1, 2, 2)
        """))
    engine.dispose()

    command.upgrade(_config(database_path), "head")

    engine = create_engine(url)
    try:
        with engine.connect() as connection:
            rows = connection.execute(text(
                "SELECT title FROM playback_cache WHERE subject_id='bangumi:1'"
            )).all()
            user_count = connection.scalar(text(
                "SELECT COUNT(*) FROM users WHERE email='kept@example.com'"
            ))
        indexes = inspect(engine).get_indexes("playback_cache")
        assert rows == [("new",)]
        assert user_count == 1
        assert any(
            item["name"] == "uq_playback_cache_subject_episode"
            and item["unique"]
            for item in indexes
        )
        assert _revision(database_path) == migration_head_revision()
    finally:
        engine.dispose()


def test_source_health_diagnostics_upgrade_preserves_existing_health(tmp_path):
    database_path = tmp_path / "source-health.db"
    config = _config(database_path)
    command.upgrade(config, "0002_playback_cache_unique")

    url = f"sqlite:///{database_path.as_posix()}"
    engine = create_engine(url)
    with engine.begin() as connection:
        connection.execute(text("""
            INSERT INTO source_health (
                source_name, success_count, failure_count,
                consecutive_failures, last_status, last_checked_at, latency_ms
            ) VALUES (
                'kept-source', 9, 2, 0, 'healthy', 1234, 640
            )
        """))
    engine.dispose()

    command.upgrade(config, "head")

    engine = create_engine(url)
    try:
        with engine.connect() as connection:
            row = connection.execute(text("""
                SELECT success_count, failure_count, latency_ms,
                       recent_success_rate, last_success_at,
                       last_failure_at, last_error_category
                FROM source_health
                WHERE source_name = 'kept-source'
            """)).one()
        assert row == (9, 2, 640, 1.0, 1234.0, 0.0, "")
        assert _revision(database_path) == migration_head_revision()
    finally:
        engine.dispose()


def test_incompatible_existing_schema_is_not_stamped(tmp_path):
    database_path = tmp_path / "incompatible.db"
    with sqlite3.connect(database_path) as connection:
        connection.execute("CREATE TABLE users (id INTEGER PRIMARY KEY)")

    with pytest.raises(RuntimeError, match="does not match the Zeluna baseline"):
        command.upgrade(_config(database_path), "head")

    with sqlite3.connect(database_path) as connection:
        row = connection.execute(
            "SELECT name FROM sqlite_master WHERE name='alembic_version'"
        ).fetchone()
        if row:
            assert connection.execute(
                "SELECT version_num FROM alembic_version"
            ).fetchone() is None


def test_legacy_unique_constraint_is_normalized_to_named_index(tmp_path):
    database_path = tmp_path / "legacy-constraint.db"
    url = f"sqlite:///{database_path.as_posix()}"
    engine = create_engine(url)
    Base.metadata.create_all(engine)
    with engine.begin() as connection:
        connection.execute(text("DROP TABLE playback_cache"))
        connection.execute(text("""
            CREATE TABLE playback_cache (
                id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                subject_id VARCHAR(200) NOT NULL,
                episode INTEGER NOT NULL,
                title VARCHAR(500) NOT NULL,
                lines_json TEXT NOT NULL,
                line_count INTEGER NOT NULL,
                verified_at FLOAT NOT NULL,
                created_at FLOAT NOT NULL,
                CONSTRAINT uq_playback_cache_subject_episode
                    UNIQUE (subject_id, episode)
            )
        """))
        connection.execute(text(
            "CREATE INDEX ix_playback_cache_subject_id "
            "ON playback_cache (subject_id)"
        ))
        connection.execute(text("""
            INSERT INTO playback_cache (
                subject_id, episode, title, lines_json, line_count,
                verified_at, created_at
            ) VALUES ('bangumi:1', 1, 'kept', '[]', 0, 1, 1)
        """))
    engine.dispose()

    config = _config(database_path)
    command.upgrade(config, "head")
    command.check(config)

    engine = create_engine(url)
    try:
        inspector = inspect(engine)
        assert any(
            item["name"] == "uq_playback_cache_subject_episode"
            for item in inspector.get_indexes("playback_cache")
        )
        assert not any(
            item["name"] == "uq_playback_cache_subject_episode"
            for item in inspector.get_unique_constraints("playback_cache")
        )
        with engine.connect() as connection:
            assert connection.scalar(text(
                "SELECT title FROM playback_cache WHERE subject_id='bangumi:1'"
            )) == "kept"
    finally:
        engine.dispose()


def test_schema_verification_rejects_unversioned_database(tmp_path):
    database_path = tmp_path / "unversioned.db"
    sync_engine = create_engine(f"sqlite:///{database_path.as_posix()}")
    Base.metadata.create_all(sync_engine)
    sync_engine.dispose()
    async_engine = create_async_engine(
        f"sqlite+aiosqlite:///{database_path.as_posix()}"
    )
    try:
        with pytest.raises(RuntimeError, match="not managed by Alembic"):
            asyncio.run(verify_database_schema(async_engine))
    finally:
        asyncio.run(async_engine.dispose())


def test_sqlite_connections_enable_reliability_pragmas(tmp_path):
    database_path = tmp_path / "pragmas.db"
    async_engine = create_database_engine(
        f"sqlite+aiosqlite:///{database_path.as_posix()}"
    )

    async def read_pragmas():
        async with async_engine.connect() as connection:
            return {
                "journal_mode": await connection.scalar(text("PRAGMA journal_mode")),
                "foreign_keys": await connection.scalar(text("PRAGMA foreign_keys")),
                "busy_timeout": await connection.scalar(text("PRAGMA busy_timeout")),
                "synchronous": await connection.scalar(text("PRAGMA synchronous")),
            }

    try:
        values = asyncio.run(read_pragmas())
        assert str(values["journal_mode"]).lower() == "wal"
        assert values["foreign_keys"] == 1
        assert values["busy_timeout"] >= 1000
        assert values["synchronous"] == 1
    finally:
        asyncio.run(async_engine.dispose())


def test_migration_tool_backs_up_existing_sqlite_database(tmp_path, monkeypatch):
    database_path = tmp_path / "source.db"
    with sqlite3.connect(database_path) as connection:
        connection.execute("CREATE TABLE preserved (value TEXT NOT NULL)")
        connection.execute("INSERT INTO preserved VALUES ('kept')")
    monkeypatch.setattr(
        migrate,
        "DATABASE_URL",
        f"sqlite+aiosqlite:///{database_path.as_posix()}",
    )

    backup_path = migrate.backup_sqlite_database()

    assert backup_path is not None
    assert backup_path.parent == tmp_path / "backups"
    with sqlite3.connect(backup_path) as connection:
        assert connection.execute("SELECT value FROM preserved").fetchone() == (
            "kept",
        )
