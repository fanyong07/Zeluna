"""Offline, barrier-driven regressions for SRV-003 password work."""

import asyncio
import threading
import time
from contextlib import asynccontextmanager

import bcrypt
import httpx
import pytest
from fastapi import FastAPI, HTTPException
from sqlalchemy import event, select, update
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine
from starlette.requests import Request

from server import account_api, auth, dependencies
from server.database import Base, User, UserToken, VerifyCode
from server.routers import legacy_account


def test_login_password_work_allows_heartbeat_before_completion(monkeypatch):
    """The watchdog only breaks a deadlock; success is an ordering assertion."""

    async def run():
        loop = asyncio.get_running_loop()
        released = threading.Event()
        heartbeat = threading.Event()
        observed = []

        def tick():
            heartbeat.set()
            released.set()

        def blocked_verify(password, hashed):
            loop.call_soon_threadsafe(tick)
            released.wait(5)
            observed.append(heartbeat.is_set())
            return False

        class MissingAccountSession:
            async def scalar(self, statement):
                return None

        monkeypatch.setattr(account_api, "verify_login_password", blocked_verify)
        account_api._attempts.clear()
        request = Request({"type": "http", "headers": [], "client": ("127.0.0.1", 1)})
        with pytest.raises(HTTPException) as rejected:
            await account_api.login(
                account_api.LoginRequest(
                    email="missing@example.com", password="fixture"
                ),
                request,
                MissingAccountSession(),
            )
        assert rejected.value.status_code == 401
        assert observed == [True], "password work prevented the scheduled heartbeat"

    asyncio.run(run())


# The integration fixtures below use only a temporary SQLite database and the
# in-process ASGI transport. There is no real account, SMTP or network access.

_HASH = "$bcrypt-sha256$fixture-old"
_REPLACEMENT = "$bcrypt-sha256$fixture-new"
_PASSWORD = "fixture-password"
_EMAIL = "fixture@example.com"


class PasswordGate:
    def __init__(self, result):
        self.loop = asyncio.get_running_loop()
        self.loop_thread = threading.get_ident()
        self.entered = asyncio.Event()
        self.finished = asyncio.Event()
        self.release = threading.Event()
        self.result = result
        self.worker_thread = None

    def __call__(self, *args):
        assert all(isinstance(arg, str) or arg is None for arg in args)
        self.worker_thread = threading.get_ident()
        self.loop.call_soon_threadsafe(self.entered.set)
        try:
            assert self.release.wait(10), "test failed to release password barrier"
            return self.result
        finally:
            self.loop.call_soon_threadsafe(self.finished.set)

    async def wait(self):
        await asyncio.wait_for(self.entered.wait(), 10)
        assert self.worker_thread != self.loop_thread


@asynccontextmanager
async def accounts(tmp_path, monkeypatch, *, old_hash=False, frozen=False):
    monkeypatch.setattr(auth, "SECRET_KEY", "fixture-signing-secret-at-least-32-bytes")
    monkeypatch.setattr(dependencies, "LEGACY_ACCOUNT_API_ENABLED", True)
    monkeypatch.setattr(account_api, "_rate_limiter", account_api._attempts)
    account_api._attempts.clear()
    loop_thread = threading.get_ident()
    database_threads = set()
    engine = create_async_engine(f"sqlite+aiosqlite:///{tmp_path / 'password.db'}")
    sessions = async_sessionmaker(engine, expire_on_commit=False)

    @event.listens_for(engine.sync_engine, "before_cursor_execute")
    def observe_orm_thread(*_args):
        database_threads.add(threading.get_ident())

    async with engine.begin() as connection:
        await connection.run_sync(Base.metadata.create_all)
    async with sessions() as session:
        session.add(
            User(
                id=1,
                email=_EMAIL,
                name="Fixture",
                password_hash="fixture-legacy" if old_hash else _HASH,
                deletion_requested_at=time.time() if frozen else 0,
                deletion_due_at=time.time() + 3600 if frozen else 0,
            )
        )
        await session.flush()
        credentials = await auth.issue_session_credentials(
            session, 1, device_id="first"
        )
        await auth.issue_session_credentials(session, 1, device_id="other")
        for email, purpose in (
            (_EMAIL, "reset_password"),
            ("new@example.com", "register"),
        ):
            session.add(
                VerifyCode(
                    email=email,
                    purpose=purpose,
                    code=account_api._code_digest(email, purpose, "123456"),
                    expires_at=time.time() + 3600,
                )
            )
            session.add(
                VerifyCode(
                    email=email,
                    purpose="legacy",
                    code="654321",
                    expires_at=time.time() + 3600,
                )
            )
        await session.commit()

    async def get_test_session():
        async with sessions() as session:
            yield session

    app = FastAPI()
    app.include_router(account_api.router)
    app.include_router(legacy_account.router)
    app.dependency_overrides[dependencies.get_session] = get_test_session
    for module in (account_api, legacy_account):
        monkeypatch.setattr(module, "hash_password", lambda password: _REPLACEMENT)
        monkeypatch.setattr(
            module, "verify_password", lambda password, hashed: password == _PASSWORD
        )
        monkeypatch.setattr(
            module,
            "verify_login_password",
            lambda password, hashed: hashed is not None and password == _PASSWORD,
        )
    try:
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app), base_url="http://fixture.invalid"
        ) as client:
            yield (
                client,
                sessions,
                {"Authorization": f"Bearer {credentials.access_token}"},
            )
        assert database_threads == {loop_thread}, "ORM work escaped into a worker"
    finally:
        account_api._attempts.clear()
        await engine.dispose()


def request_password_action(client, action, headers):
    if action.startswith("legacy_"):
        operation = action.removeprefix("legacy_")
        email = "new@example.com" if operation == "register" else _EMAIL
        fields = [email, _PASSWORD, "654321", "NewFixture"]
        content = b"".join(
            bytes([(index << 3) | 2, len(value.encode())]) + value.encode()
            for index, value in enumerate(fields, 1)
        )
        return client.post(f"/{operation}", content=content)
    paths = {
        "login": ("login", {"email": _EMAIL, "password": _PASSWORD}),
        "register": (
            "register",
            {
                "email": "new@example.com",
                "nickname": "NewFixture",
                "password": _PASSWORD,
                "code": "123456",
            },
        ),
        "change": (
            "password",
            {"current_password": _PASSWORD, "new_password": "new-password"},
        ),
        "verify": ("password/verify", {"password": _PASSWORD}),
        "delete": ("privacy/deletion", {"password": _PASSWORD}),
        "cancel": ("privacy/deletion/cancel", {"email": _EMAIL, "password": _PASSWORD}),
        "reset": (
            "password/reset",
            {"email": _EMAIL, "code": "123456", "new_password": "new-password"},
        ),
    }
    path, payload = paths[action]
    return client.post(f"/api/v1/auth/{path}", json=payload, headers=headers)


# Every synchronous password call site, including both phases of a change and
# legacy-hash upgrade, has an independently controlled off-loop barrier.
_CHECKPOINTS = [
    ("login", "verify_login_password", False),
    ("login", "hash_password", True),
    ("register", "hash_password", False),
    ("change", "verify_password", False),
    ("change", "hash_password", False),
    ("verify", "verify_password", False),
    ("delete", "verify_password", False),
    ("cancel", "verify_login_password", False),
    ("cancel", "hash_password", True),
    ("reset", "hash_password", False),
    ("legacy_login", "verify_login_password", False),
    ("legacy_login", "hash_password", True),
    ("legacy_register", "hash_password", False),
    ("legacy_change_password", "hash_password", False),
]


def patch_gate(monkeypatch, action, helper):
    gate = PasswordGate(_REPLACEMENT if helper == "hash_password" else True)
    module = legacy_account if action.startswith("legacy_") else account_api
    monkeypatch.setattr(module, helper, gate)
    return gate


@pytest.mark.parametrize("action,helper,old_hash", _CHECKPOINTS)
def test_each_password_callsite_yields_to_heartbeat(
    tmp_path, monkeypatch, action, helper, old_hash
):
    async def run():
        async with accounts(tmp_path, monkeypatch, old_hash=old_hash) as (
            client,
            sessions,
            headers,
        ):
            gate = patch_gate(monkeypatch, action, helper)
            task = asyncio.create_task(request_password_action(client, action, headers))
            try:
                await gate.wait()
                heartbeat = asyncio.Event()
                asyncio.get_running_loop().call_soon(heartbeat.set)
                await heartbeat.wait()
                assert not task.done()  # CPU work is still blocked at the barrier.
            finally:
                gate.release.set()
            response = await asyncio.wait_for(task, 10)
            assert response.status_code in {200, 201, 202, 204}
            if action in {"legacy_register", "legacy_login"}:
                assert response.content != legacy_account.pb.encode_login_response(
                    {}, ""
                )
            if action == "legacy_change_password":
                assert response.json()["error"] is False

    asyncio.run(run())


@pytest.mark.parametrize(
    "action,helper,old_hash",
    [
        checkpoint
        for checkpoint in _CHECKPOINTS
        if checkpoint[0] not in {"register", "legacy_register"}
    ],
)
@pytest.mark.parametrize("change", ["password", "freeze"])
def test_pending_password_work_rejects_changed_authoritative_state(
    tmp_path, monkeypatch, action, helper, old_hash, change
):
    async def run():
        async with accounts(tmp_path, monkeypatch, old_hash=old_hash) as (
            client,
            sessions,
            headers,
        ):
            gate = patch_gate(monkeypatch, action, helper)
            task = asyncio.create_task(request_password_action(client, action, headers))
            try:
                await gate.wait()
                values = (
                    {"password_hash": "$bcrypt-sha256$concurrently-changed"}
                    if change == "password"
                    else {
                        "deletion_requested_at": time.time(),
                        "deletion_due_at": time.time() + 3600,
                    }
                )
                async with sessions() as other:
                    await other.execute(
                        update(User).where(User.id == 1).values(**values)
                    )
                    await other.commit()
            finally:
                gate.release.set()
            response = await asyncio.wait_for(task, 10)
            if action == "legacy_login":
                assert response.content == legacy_account.pb.encode_login_response(
                    {}, ""
                )
            elif action == "legacy_change_password":
                assert response.json()["error"] is True
            else:
                assert response.status_code in {400, 401, 410, 423}
            async with sessions() as check:
                user = await check.get(User, 1)
                for key, value in values.items():
                    assert getattr(user, key) == value
                # Neither obsolete login/upgrade nor destructive actions create
                # credentials, revoke sessions, or overwrite the newer state.
                assert len(list(await check.scalars(select(UserToken)))) == 2

    asyncio.run(run())


@pytest.mark.parametrize(
    "action,helper",
    [
        ("change", "verify_password"),
        ("change", "hash_password"),
        ("verify", "verify_password"),
        ("delete", "verify_password"),
    ],
)
@pytest.mark.parametrize("change", ["revoke", "remove", "rotate", "expire"])
def test_pending_authenticated_password_work_rechecks_session(
    tmp_path, monkeypatch, action, helper, change
):
    async def run():
        async with accounts(tmp_path, monkeypatch) as (client, sessions, headers):
            gate = patch_gate(monkeypatch, action, helper)
            task = asyncio.create_task(request_password_action(client, action, headers))
            try:
                await gate.wait()
                async with sessions() as other:
                    current = await other.scalar(
                        select(UserToken).where(UserToken.device_id == "first")
                    )
                    if change == "remove":
                        await other.delete(current)
                    elif change == "revoke":
                        current.revoked_at = time.time()
                    elif change == "expire":
                        current.expires_at = time.time() - 1
                    else:
                        current.token_id = "rotated-fixture-jti"
                        current.token = "v1:rotated-fixture-refresh-digest"
                    await other.commit()
            finally:
                gate.release.set()
            response = await asyncio.wait_for(task, 10)
            assert response.status_code == 401
            async with sessions() as check:
                user = await check.get(User, 1)
                assert user.password_hash == _HASH
                assert user.deletion_due_at == 0
                assert (
                    await check.scalar(
                        select(UserToken).where(UserToken.device_id == "other")
                    )
                    is not None
                )

    asyncio.run(run())


@pytest.mark.parametrize("action,helper,old_hash", _CHECKPOINTS)
def test_cancelled_password_request_cannot_issue_or_mutate(
    tmp_path, monkeypatch, action, helper, old_hash
):
    async def run():
        async with accounts(tmp_path, monkeypatch, old_hash=old_hash) as (
            client,
            sessions,
            headers,
        ):
            async with sessions() as before:
                expected_updated_at = (await before.get(User, 1)).updated_at
            gate = patch_gate(monkeypatch, action, helper)
            task = asyncio.create_task(request_password_action(client, action, headers))
            try:
                await gate.wait()
                task.cancel()
                with pytest.raises(asyncio.CancelledError):
                    await task
            finally:
                gate.release.set()
            await asyncio.wait_for(gate.finished.wait(), 10)
            async with sessions() as check:
                user = await check.get(User, 1)
                assert user.password_hash == ("fixture-legacy" if old_hash else _HASH)
                assert user.deletion_due_at == 0
                assert user.updated_at == expected_updated_at
                assert len(list(await check.scalars(select(UserToken)))) == 2
                assert (
                    await check.scalar(
                        select(User).where(User.email == "new@example.com")
                    )
                    is None
                )

    asyncio.run(run())


def test_password_admission_stays_occupied_until_cancelled_threads_finish(monkeypatch):
    async def run():
        real_submit = auth._password_executor.submit
        submitted = []

        def observe_submit(function, *args):
            submitted.append(function)
            return real_submit(function, *args)

        monkeypatch.setattr(auth._password_executor, "submit", observe_submit)
        gates = [PasswordGate(True) for _ in range(auth._PASSWORD_WORKERS + 2)]
        tasks = [
            asyncio.create_task(auth.run_password_work(gate, "fixture"))
            for gate in gates[:2]
        ]
        try:
            await asyncio.gather(*(gate.wait() for gate in gates[:2]))
            tasks[0].cancel()
            with pytest.raises(asyncio.CancelledError):
                await tasks[0]
            waiting = asyncio.create_task(auth.run_password_work(gates[2], "fixture"))
            tasks.append(waiting)
            # This scheduler barrier places the new waiter at admission; it is
            # not a timing threshold or a guess about bcrypt's duration.
            await asyncio.sleep(0)
            assert len(submitted) == 2
            assert not gates[2].entered.is_set()
            waiting.cancel()
            with pytest.raises(asyncio.CancelledError):
                await waiting
            queued = asyncio.create_task(auth.run_password_work(gates[3], "fixture"))
            tasks.append(queued)
            await asyncio.sleep(0)
            assert len(submitted) == 2
            gates[1].release.set()
            await tasks[1]
            await gates[3].wait()
            assert len(submitted) == 3
            assert not gates[0].finished.is_set()  # canceled CPU job still owns slot
            assert not gates[2].entered.is_set()  # canceled queue entry never ran
        finally:
            for gate in gates:
                gate.release.set()
            await asyncio.gather(*tasks, return_exceptions=True)
            await asyncio.gather(
                *(gate.finished.wait() for gate in (gates[0], gates[1], gates[3]))
            )

    asyncio.run(run())


def test_password_worker_failure_returns_capacity():
    async def run():
        def fail(*_args):
            raise ValueError("synthetic-password-failure")

        results = await asyncio.gather(
            *(auth.run_password_work(fail, "fixture") for _ in range(6)),
            return_exceptions=True,
        )
        assert all(isinstance(error, ValueError) for error in results)
        assert await auth.run_password_work(lambda value: value, "fixture") == "fixture"

    asyncio.run(run())


@pytest.mark.parametrize("action", ["legacy_register", "legacy_change_password"])
@pytest.mark.parametrize("change", ["consume", "expire", "replace"])
def test_legacy_code_is_rechecked_after_hash_wait(
    tmp_path, monkeypatch, action, change
):
    async def run():
        async with accounts(tmp_path, monkeypatch) as (client, sessions, headers):
            gate = patch_gate(monkeypatch, action, "hash_password")
            task = asyncio.create_task(request_password_action(client, action, headers))
            try:
                await gate.wait()
                async with sessions() as other:
                    email = "new@example.com" if action == "legacy_register" else _EMAIL
                    code = await other.scalar(
                        select(VerifyCode).where(
                            VerifyCode.email == email, VerifyCode.purpose == "legacy"
                        )
                    )
                    if change == "consume":
                        await other.delete(code)
                    elif change == "expire":
                        code.expires_at = time.time() - 1
                    else:
                        code.code = "111111"
                    await other.commit()
            finally:
                gate.release.set()
            response = await asyncio.wait_for(task, 10)
            if action == "legacy_register":
                assert response.content == legacy_account.pb.encode_login_response(
                    {}, ""
                )
            else:
                assert response.json()["error"] is True
            async with sessions() as check:
                assert (await check.get(User, 1)).password_hash == _HASH
                assert len(list(await check.scalars(select(UserToken)))) == 2
                assert (
                    await check.scalar(
                        select(User).where(User.email == "new@example.com")
                    )
                    is None
                )

    asyncio.run(run())


def test_verify_password_internal_session_dependency_keeps_api_and_session_state(
    tmp_path, monkeypatch
):
    async def run():
        async with accounts(tmp_path, monkeypatch) as (client, sessions, headers):
            spec = (await client.get("/openapi.json")).json()
            operation = spec["paths"]["/api/v1/auth/password/verify"]["post"]
            assert not operation.get("parameters")
            assert operation["requestBody"]["content"]["application/json"][
                "schema"
            ] == {"$ref": "#/components/schemas/VerifyPasswordRequest"}
            body_schema = spec["components"]["schemas"]["VerifyPasswordRequest"]
            assert body_schema["required"] == ["password"]
            assert set(body_schema["properties"]) == {"password"}
            assert body_schema["properties"]["password"]["minLength"] == 1
            assert body_schema["properties"]["password"]["maxLength"] == 128
            assert "204" in operation["responses"]
            async with sessions() as check:
                before = (await check.get(User, 1)).updated_at
            response = await request_password_action(client, "verify", headers)
            assert response.status_code == 204 and response.content == b""
            me = await client.get("/api/v1/auth/me", headers=headers)
            assert me.status_code == 200 and me.json()["user"]["nickname"] == "Fixture"
            assert (
                await client.post(
                    "/api/v1/auth/password/verify",
                    json={"password": "wrong"},
                    headers=headers,
                )
            ).status_code == 400
            assert (
                await client.post(
                    "/api/v1/auth/password/verify",
                    json={"password": ""},
                    headers=headers,
                )
            ).status_code == 422
            assert (
                await client.post(
                    "/api/v1/auth/password/verify", json={"password": _PASSWORD}
                )
            ).status_code == 401
            async with sessions() as check:
                assert (await check.get(User, 1)).updated_at == before
                rows = list(await check.scalars(select(UserToken)))
                assert len(rows) == 2 and all(row.revoked_at == 0 for row in rows)

            # Directly observe the dependency session before teardown: the
            # read-only verification fence is rolled back by the handler itself.
            async with sessions() as session:
                account = await account_api.current_account(
                    Request(
                        {
                            "type": "http",
                            "headers": [
                                (b"authorization", headers["Authorization"].encode())
                            ],
                        }
                    ),
                    session,
                )
                assert (
                    await account_api.verify_account_password(
                        account_api.VerifyPasswordRequest(password=_PASSWORD),
                        account,
                        session,
                    )
                    is None
                )
                assert not session.in_transaction()
                # Independent writer progresses even before this session closes.
                async with sessions() as other:
                    await other.execute(
                        update(User).where(User.id == 1).values(name="AfterVerify")
                    )
                    await other.commit()
            me = await client.get("/api/v1/auth/me", headers=headers)
            assert (
                me.status_code == 200 and me.json()["user"]["nickname"] == "AfterVerify"
            )

    asyncio.run(run())


def test_actual_password_workers_remain_bounded_across_cancelled_loops(monkeypatch):
    """A new loop cannot replace CPU jobs whose original awaiters were cancelled."""
    limit = auth._PASSWORD_WORKERS
    started = [threading.Event() for _ in range(limit * 2)]
    released = [threading.Event() for _ in started]
    completed = [threading.Event() for _ in started]
    futures = []
    lock = threading.Lock()
    active = 0
    peak = 0
    real_submit = auth._password_executor.submit

    def observe_submit(function, *args):
        future = real_submit(function, *args)
        futures.append(future)
        return future

    monkeypatch.setattr(auth._password_executor, "submit", observe_submit)

    def blocked(index):
        def work(_password):
            nonlocal active, peak
            with lock:
                active += 1
                peak = max(peak, active)
            started[index].set()
            try:
                assert released[index].wait(10), "test failed to release worker"
                return True
            finally:
                with lock:
                    active -= 1
                completed[index].set()

        return work

    async def start_then_cancel_original_loop():
        tasks = [
            asyncio.create_task(auth.run_password_work(blocked(i), "fixture"))
            for i in range(limit)
        ]
        try:
            for signal in started[:limit]:
                assert await asyncio.to_thread(signal.wait, 10)
        finally:
            for task in tasks:
                task.cancel()
            results = await asyncio.gather(*tasks, return_exceptions=True)
            assert all(isinstance(result, asyncio.CancelledError) for result in results)

    async def new_loop_still_shares_real_worker_bound():
        tasks = [
            asyncio.create_task(auth.run_password_work(blocked(i), "fixture"))
            for i in range(limit, limit * 2)
        ]
        try:
            await asyncio.sleep(0)  # all new calls reached pool admission
            assert len(futures) == limit * 2
            assert sum(future.running() for future in futures) == limit
            assert not any(signal.is_set() for signal in started[limit:])
            assert not any(signal.is_set() for signal in completed[:limit])
            released[0].set()
            assert await asyncio.to_thread(started[limit].wait, 10)
            assert completed[0].is_set()
            assert not started[-1].is_set()
        finally:
            for signal in released:
                signal.set()
            await asyncio.gather(*tasks, return_exceptions=True)

    try:
        asyncio.run(start_then_cancel_original_loop())
        asyncio.run(new_loop_still_shares_real_worker_bound())
        for future in futures:
            assert future.result(timeout=10) is True
        assert peak == limit and active == 0
    finally:
        for signal in released:
            signal.set()
        for future in futures:
            future.result(timeout=10)


@pytest.mark.parametrize(
    "action,limited_check",
    [
        ("login", 1),
        ("login", 2),
        ("register", 1),
        ("reset", 1),
        ("delete", 1),
        ("delete", 2),
        ("cancel", 1),
        ("cancel", 2),
    ],
)
def test_rate_limits_reject_before_password_admission(
    tmp_path, monkeypatch, action, limited_check
):
    async def run():
        async with accounts(tmp_path, monkeypatch) as (client, sessions, headers):
            checks = []
            password_calls = []

            async def reject_at_limit(key, **kwargs):
                checks.append(key.split(":")[:2])
                if len(checks) == limited_check:
                    raise account_api._too_many_requests(60)

            async def forbidden_password_work(*_args):
                password_calls.append(True)
                raise AssertionError("rate-limited request reached expensive work")

            monkeypatch.setattr(account_api, "_rate_limit", reject_at_limit)
            monkeypatch.setattr(
                account_api, "run_password_work", forbidden_password_work
            )
            response = await request_password_action(client, action, headers)
            assert response.status_code == 429
            assert response.headers["Retry-After"] == "60"
            prefix = "cancel-delete" if action == "cancel" else action
            expected = [
                [prefix, "ip"],
                [prefix, "user" if action == "delete" else "email"],
            ]
            assert checks == expected[:limited_check]
            assert not password_calls

    asyncio.run(run())


@pytest.mark.parametrize("action", ["login", "cancel", "legacy_login"])
def test_missing_account_performs_real_dummy_check_off_loop(
    tmp_path, monkeypatch, action
):
    async def run():
        async with accounts(tmp_path, monkeypatch) as (client, sessions, headers):
            module = legacy_account if action.startswith("legacy_") else account_api
            monkeypatch.setattr(
                module, "verify_login_password", auth.verify_login_password
            )
            calls = []
            loop_thread = threading.get_ident()

            def capture_check(password_bytes, bcrypt_hash):
                calls.append((threading.get_ident(), password_bytes, bcrypt_hash))
                return False

            monkeypatch.setattr(auth.bcrypt, "checkpw", capture_check)
            async with sessions() as other:
                await other.execute(
                    update(User).where(User.id == 1).values(email="moved@example.com")
                )
                await other.commit()
            response = await request_password_action(client, action, headers)
            if action == "legacy_login":
                assert response.content == legacy_account.pb.encode_login_response(
                    {}, ""
                )
            else:
                assert response.status_code == 401
            assert len(calls) == 1
            thread_id, password_bytes, hashed = calls[0]
            assert thread_id != loop_thread
            assert password_bytes == auth._password_bytes(_PASSWORD)
            assert (
                hashed
                == auth._DUMMY_PASSWORD_HASH.removeprefix(
                    auth._BCRYPT_SHA256_PREFIX
                ).encode()
            )

    asyncio.run(run())


def test_async_password_work_preserves_cost_unicode_and_legacy_compatibility():
    async def run():
        password = "很长的中文密码🌙" * 12
        hashed = await auth.run_password_work(auth.hash_password, password)
        assert hashed.startswith(auth._BCRYPT_SHA256_PREFIX)
        assert (
            hashed.removeprefix(auth._BCRYPT_SHA256_PREFIX).split("$")[2]
            == bcrypt.gensalt().decode().split("$")[2]
        )
        assert await auth.run_password_work(auth.verify_password, password, hashed)
        assert not await auth.run_password_work(
            auth.verify_password, password + "错", hashed
        )
        legacy = await auth.run_password_work(
            lambda value: bcrypt.hashpw(value.encode(), bcrypt.gensalt()).decode(),
            _PASSWORD,
        )
        assert auth.password_hash_needs_upgrade(legacy)
        assert await auth.run_password_work(auth.verify_password, _PASSWORD, legacy)
        assert not await auth.run_password_work(auth.verify_password, "wrong", legacy)
        assert not await auth.run_password_work(auth.verify_password, password, legacy)
        assert not await auth.run_password_work(
            auth.verify_password, _PASSWORD, "invalid-format"
        )

    asyncio.run(run())
