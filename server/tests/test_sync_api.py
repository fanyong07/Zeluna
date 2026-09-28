import asyncio

import pytest

from httpx import ASGITransport, AsyncClient
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from server.account_api import current_account
from server.app import create_app
from server.database import Base, SyncMutation, SyncRecord, SyncRevision, User, UserToken
from server.dependencies import get_session


def _library_mutation(
    mutation_id: str,
    *,
    record_type: str = "favorite",
    record_id: str = "bangumi:1",
    updated_at: str = "2026-08-08T08:00:00Z",
    position: int = 0,
    deleted: bool = False,
    title: str = "Test subject",
) -> dict:
    return {
        "mutationId": mutation_id,
        "recordId": record_id,
        "type": record_type,
        "schemaVersion": 1,
        "deleted": deleted,
        "payload": {
            "subject": {
                "id": 1,
                "title": title,
                "source": "bangumi",
                "stableKey": record_id,
            },
            "updatedAt": updated_at,
            "positionSeconds": position,
            "durationSeconds": 1440 if position else 0,
        },
    }


async def _exercise_api(database_path, exercise):
    engine = create_async_engine(f"sqlite+aiosqlite:///{database_path}")
    sessions = async_sessionmaker(engine, expire_on_commit=False)
    async with engine.begin() as connection:
        await connection.run_sync(Base.metadata.create_all)
    async with sessions() as session:
        first = User(
            email="first@example.com", name="first-sync-user", password_hash="hash"
        )
        second = User(
            email="second@example.com", name="second-sync-user", password_hash="hash"
        )
        session.add_all([first, second])
        await session.commit()
        first_id, second_id = first.id, second.id

    active_user_id = first_id

    async def override_session():
        async with sessions() as session:
            yield session

    async def override_account():
        async with sessions() as session:
            user = await session.get(User, active_user_id)
            assert user is not None
            return user, UserToken(user_id=user.id, token="test")

    def switch_user(user_id: int) -> None:
        nonlocal active_user_id
        active_user_id = user_id

    app = create_app()
    app.dependency_overrides[get_session] = override_session
    app.dependency_overrides[current_account] = override_account
    try:
        async with AsyncClient(
            transport=ASGITransport(app=app), base_url="https://test"
        ) as client:
            await exercise(client, sessions, switch_user, first_id, second_id)
    finally:
        app.dependency_overrides.clear()
        await engine.dispose()


def test_push_is_idempotent_and_account_scoped(tmp_path):
    async def exercise(client, sessions, switch_user, first_id, second_id):
        mutation = _library_mutation("device-a-mutation-0001")
        first = await client.post("/api/v1/sync/push", json={"mutations": [mutation]})
        assert first.status_code == 200
        first_record = first.json()["acknowledged"][0]
        assert first_record["account_id"] == str(first_id)
        assert first.headers["cache-control"] == "no-store"

        retry = await client.post("/api/v1/sync/push", json={"mutations": [mutation]})
        assert retry.status_code == 200
        assert retry.json()["acknowledged"][0]["server_revision"] == first_record[
            "server_revision"
        ]

        changed_retry = dict(mutation, deleted=True)
        conflict = await client.post(
            "/api/v1/sync/push", json={"mutations": [changed_retry]}
        )
        assert conflict.status_code == 409

        async with sessions() as session:
            assert await session.scalar(select(func.count(SyncMutation.id))) == 1
            assert await session.scalar(select(func.count(SyncRevision.revision))) == 1
            assert await session.scalar(select(func.count(SyncRecord.id))) == 1

        switch_user(second_id)
        empty = await client.get("/api/v1/sync/pull")
        assert empty.status_code == 200
        assert empty.json()["records"] == []

        second_push = await client.post(
            "/api/v1/sync/push", json={"mutations": [mutation]}
        )
        assert second_push.status_code == 200
        assert second_push.json()["acknowledged"][0]["account_id"] == str(second_id)

    asyncio.run(_exercise_api(tmp_path / "sync-idempotency.db", exercise))


def test_history_conflict_and_tombstone_are_incremental(tmp_path):
    async def exercise(client, _sessions, _switch_user, _first_id, _second_id):
        older = _library_mutation(
            "history-device-a-0001",
            record_type="history",
            updated_at="2026-08-08T08:00:00Z",
            position=120,
            title="Older metadata",
        )
        first = await client.post("/api/v1/sync/push", json={"mutations": [older]})
        assert first.status_code == 200
        first_revision = first.json()["next_revision"]

        newer = _library_mutation(
            "history-device-b-0001",
            record_type="history",
            updated_at="2026-08-08T09:00:00Z",
            position=30,
            title="Newer metadata",
        )
        second = await client.post("/api/v1/sync/push", json={"mutations": [newer]})
        assert second.status_code == 200
        merged = second.json()["acknowledged"][0]["payload"]
        assert merged["positionSeconds"] == 120
        assert merged["subject"]["title"] == "Newer metadata"

        delta = await client.get(
            "/api/v1/sync/pull", params={"after_revision": first_revision}
        )
        assert delta.status_code == 200
        assert len(delta.json()["records"]) == 1
        assert delta.json()["records"][0]["payload"]["positionSeconds"] == 120

        favorite = _library_mutation("favorite-device-a-0002")
        created = await client.post(
            "/api/v1/sync/push", json={"mutations": [favorite]}
        )
        created_revision = created.json()["next_revision"]
        tombstone = _library_mutation(
            "favorite-device-a-0003",
            deleted=True,
            updated_at="2026-08-08T10:00:00Z",
        )
        deleted = await client.post(
            "/api/v1/sync/push", json={"mutations": [tombstone]}
        )
        assert deleted.status_code == 200
        assert deleted.json()["acknowledged"][0]["deleted"] is True

        deletion_delta = await client.get(
            "/api/v1/sync/pull", params={"after_revision": created_revision}
        )
        assert deletion_delta.json()["records"][0]["deleted"] is True

    asyncio.run(_exercise_api(tmp_path / "sync-conflicts.db", exercise))


def test_playback_completion_ignores_stale_device_update(tmp_path):
    async def exercise(client, _sessions, _switch_user, _first_id, _second_id):
        episode_key = "episode:v1:stable-episode"
        base = {
            "recordId": episode_key,
            "type": "playback_position",
            "schemaVersion": 1,
            "deleted": False,
            "payload": {
                "subject": {
                    "id": 1,
                    "title": "Test subject",
                    "source": "bangumi",
                    "stableKey": "bangumi:1",
                },
                "episode": {
                    "id": 101,
                    "subjectId": 1,
                    "number": 1,
                    "stableKey": episode_key,
                },
                "durationSeconds": 1440,
            },
        }
        completed = {
            **base,
            "mutationId": "position-device-a-0001",
            "payload": {
                **base["payload"],
                "updatedAt": "2026-08-08T11:00:00Z",
                "positionSeconds": 0,
                "completed": True,
            },
        }
        accepted = await client.post(
            "/api/v1/sync/push", json={"mutations": [completed]}
        )
        completed_revision = accepted.json()["next_revision"]

        stale = {
            **base,
            "mutationId": "position-device-b-0001",
            "payload": {
                **base["payload"],
                "updatedAt": "2026-08-08T10:00:00Z",
                "positionSeconds": 600,
                "completed": False,
            },
        }
        ignored = await client.post(
            "/api/v1/sync/push", json={"mutations": [stale]}
        )
        assert ignored.status_code == 200
        ignored_record = ignored.json()["acknowledged"][0]
        assert ignored_record["client_mutation_id"] == stale["mutationId"]
        current = accepted.json()["acknowledged"][0]
        assert ignored_record == {
            **current,
            "client_mutation_id": stale["mutationId"],
        }
        assert ignored_record["server_revision"] == completed_revision
        assert ignored_record["payload"]["completed"] is True

        replay = await client.post(
            "/api/v1/sync/push", json={"mutations": [stale]}
        )
        assert replay.status_code == 200
        assert replay.json() == ignored.json()
        pulled = await client.get("/api/v1/sync/pull")
        assert pulled.status_code == 200
        assert pulled.json()["records"] == [current]

        # Equal-time completion must also reject a regressing progress update.
        equal_time = {
            **stale,
            "mutationId": "position-device-c-0001",
            "payload": {
                **stale["payload"],
                "updatedAt": completed["payload"]["updatedAt"],
            },
        }
        same_time = await client.post(
            "/api/v1/sync/push", json={"mutations": [equal_time]}
        )
        assert same_time.status_code == 200
        assert same_time.json()["acknowledged"] == [
            {**current, "client_mutation_id": equal_time["mutationId"]}
        ]
        assert same_time.json()["next_revision"] == completed_revision

    asyncio.run(_exercise_api(tmp_path / "sync-position.db", exercise))


def test_sync_payload_is_allowlisted_and_identity_bound(tmp_path):
    async def exercise(client, _sessions, _switch_user, _first_id, _second_id):
        mismatched = _library_mutation(
            "invalid-identity-0001", record_id="bangumi:unexpected"
        )
        mismatched["payload"]["subject"]["stableKey"] = "bangumi:1"
        response = await client.post(
            "/api/v1/sync/push", json={"mutations": [mismatched]}
        )
        assert response.status_code == 422

        secret_bearing = _library_mutation("invalid-payload-0001")
        secret_bearing["payload"]["cookie"] = "must-not-be-accepted"
        rejected = await client.post(
            "/api/v1/sync/push", json={"mutations": [secret_bearing]}
        )
        assert rejected.status_code == 422

    asyncio.run(_exercise_api(tmp_path / "sync-validation.db", exercise))


@pytest.mark.parametrize("deleted", [False, True])
def test_lost_ack_replay_keeps_submitted_id_and_current_record(tmp_path, deleted):
    async def exercise(client, sessions, switch_user, first_id, second_id):
        original = _library_mutation("lost-ack-device-a-0001", title="Before update")
        accepted = await client.post(
            "/api/v1/sync/push", json={"mutations": [original]}
        )
        assert accepted.status_code == 200
        original_revision = accepted.json()["next_revision"]
        # Device A loses this response; B supersedes the record before A retries.
        newer = _library_mutation(
            "lost-ack-device-b-0001",
            title="Current remote metadata",
            updated_at="2026-08-08T10:00:00Z",
            deleted=deleted,
        )
        updated = await client.post(
            "/api/v1/sync/push", json={"mutations": [newer]}
        )
        assert updated.status_code == 200
        current = updated.json()["acknowledged"][0]
        assert current["server_revision"] > original_revision

        replay = await client.post(
            "/api/v1/sync/push", json={"mutations": [original]}
        )
        assert replay.status_code == 200
        acknowledgement = replay.json()["acknowledged"][0]
        assert acknowledgement["client_mutation_id"] == original["mutationId"]
        assert acknowledgement == {
            **current,
            "client_mutation_id": original["mutationId"],
        }
        assert replay.json()["next_revision"] == current["server_revision"]

        pulled = await client.get(
            "/api/v1/sync/pull", params={"after_revision": original_revision}
        )
        assert pulled.status_code == 200
        assert pulled.json()["records"] == [current]
        assert pulled.json()["next_revision"] == current["server_revision"]
        repeated = await client.post(
            "/api/v1/sync/push", json={"mutations": [original]}
        )
        assert repeated.status_code == 200
        assert repeated.json() == replay.json()

        altered = _library_mutation(original["mutationId"], title="Different input")
        conflict = await client.post(
            "/api/v1/sync/push", json={"mutations": [altered]}
        )
        assert conflict.status_code == 409
        async with sessions() as session:
            assert await session.scalar(select(func.count(SyncMutation.id))) == 2
            assert await session.scalar(select(func.count(SyncRevision.revision))) == 2
            assert await session.scalar(select(func.count(SyncRecord.id))) == 1

        # Identical mutation IDs have independent content and receipts per account.
        switch_user(second_id)
        empty = await client.get("/api/v1/sync/pull")
        assert empty.status_code == 200
        assert empty.json()["records"] == []
        other_account = await client.post(
            "/api/v1/sync/push", json={"mutations": [altered]}
        )
        assert other_account.status_code == 200
        other_record = other_account.json()["acknowledged"][0]
        assert other_record["account_id"] == str(second_id)
        assert other_record["client_mutation_id"] == original["mutationId"]
        assert other_record["payload"]["subject"]["title"] == "Different input"

        switch_user(first_id)
        original_account = await client.post(
            "/api/v1/sync/push", json={"mutations": [original]}
        )
        assert original_account.status_code == 200
        assert original_account.json() == replay.json()
        unchanged = await client.get("/api/v1/sync/pull")
        assert unchanged.status_code == 200
        assert unchanged.json()["records"] == [current]

    asyncio.run(_exercise_api(tmp_path / "sync-lost-ack.db", exercise))


def test_same_record_batch_replay_and_hash_conflict_remain_atomic(tmp_path):
    async def exercise(client, sessions, _switch_user, _first_id, _second_id):
        original = _library_mutation("batch-device-a-0001", title="First value")
        newer = _library_mutation(
            "batch-device-b-0001",
            title="Second value",
            updated_at="2026-08-08T10:00:00Z",
        )
        accepted = await client.post(
            "/api/v1/sync/push", json={"mutations": [original, newer]}
        )
        assert accepted.status_code == 200
        first, current = accepted.json()["acknowledged"]
        assert first["client_mutation_id"] == original["mutationId"]
        assert current["client_mutation_id"] == newer["mutationId"]
        assert first["payload"]["subject"]["title"] == "First value"
        assert current["payload"]["subject"]["title"] == "Second value"
        assert current["server_revision"] > first["server_revision"]

        replay = await client.post(
            "/api/v1/sync/push", json={"mutations": [original, newer]}
        )
        assert replay.status_code == 200
        assert replay.json()["acknowledged"] == [
            {**current, "client_mutation_id": original["mutationId"]},
            current,
        ]
        assert replay.json()["next_revision"] == current["server_revision"]

        uncommitted = _library_mutation(
            "batch-device-c-0001", title="Must be rolled back"
        )
        altered = _library_mutation(original["mutationId"], title="Hash conflict")
        conflict = await client.post(
            "/api/v1/sync/push", json={"mutations": [uncommitted, altered]}
        )
        assert conflict.status_code == 409
        pulled = await client.get("/api/v1/sync/pull")
        assert pulled.status_code == 200
        assert pulled.json()["records"] == [current]
        async with sessions() as session:
            assert await session.scalar(select(func.count(SyncMutation.id))) == 2
            assert await session.scalar(select(func.count(SyncRevision.revision))) == 2
            assert await session.scalar(select(func.count(SyncRecord.id))) == 1

    asyncio.run(_exercise_api(tmp_path / "sync-batch-replay.db", exercise))
