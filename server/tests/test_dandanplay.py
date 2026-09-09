import asyncio
import base64
import hashlib

import httpx
import pytest

from server.dandanplay import DandanplayClient, DandanplayError


_APP_ID = "test-app"
_APP_SECRET = "test-secret"
_FIXED_TIME = 1_700_000_000
_PUBLIC_IP = "93.184.216.34"


async def _public_resolver(_host: str) -> list[str]:
    return [_PUBLIC_IP]


def _client(handler, **overrides) -> DandanplayClient:
    options = {
        "enabled": True,
        "app_id": _APP_ID,
        "app_secret": _APP_SECRET,
        "transport": httpx.MockTransport(handler),
        "resolve_host": _public_resolver,
        "unix_time": lambda: _FIXED_TIME,
        "cache_seconds": 60,
        "empty_cache_seconds": 10,
        "max_response_bytes": 1024 * 1024,
    }
    options.update(overrides)
    return DandanplayClient(**options)


def _search_payload(
    *,
    title: str = "葬送的芙莉莲",
    episode_id: int = 12345,
    episode_title: str = "第1话 冒险的结束",
    media_type: str = "tvseries",
):
    return {
        "success": True,
        "animes": [
            {
                "animeTitle": title,
                "type": media_type,
                "episodes": [
                    {
                        "episodeId": episode_id,
                        "episodeTitle": episode_title,
                    }
                ],
            }
        ],
    }


def test_signature_uses_only_the_url_path():
    path = "/api/v2/search/episodes"
    expected = base64.b64encode(
        hashlib.sha256(f"{_APP_ID}{_FIXED_TIME}{path}{_APP_SECRET}".encode()).digest()
    ).decode("ascii")

    assert (
        DandanplayClient.signature(_APP_ID, _FIXED_TIME, path, _APP_SECRET) == expected
    )
    assert (
        DandanplayClient.signature(
            _APP_ID,
            _FIXED_TIME,
            f"{path}?anime=Frieren&episode=1",
            _APP_SECRET,
        )
        != expected
    )


def test_search_is_signed_and_comment_fields_are_parsed():
    async def exercise():
        requests: list[httpx.Request] = []

        async def handler(request: httpx.Request) -> httpx.Response:
            requests.append(request)
            if request.url.path == "/api/v2/search/episodes":
                assert request.url.params["anime"] == "葬送的芙莉莲"
                assert request.url.params["episode"] == "1"
                assert request.url.params["v2"] == "true"
                assert request.headers["X-AppId"] == _APP_ID
                assert request.headers["X-Timestamp"] == str(_FIXED_TIME)
                assert request.headers["X-Signature"] == DandanplayClient.signature(
                    _APP_ID,
                    _FIXED_TIME,
                    request.url.path,
                    _APP_SECRET,
                )
                assert "X-AppSecret" not in request.headers
                return httpx.Response(200, json=_search_payload())
            assert request.url.path == "/api/v2/comment/12345"
            assert request.url.params["from"] == "0"
            assert request.url.params["withRelated"] == "true"
            assert request.url.params["chConvert"] == "1"
            return httpx.Response(
                200,
                json={
                    "success": True,
                    "comments": [
                        {
                            "cid": 88,
                            "p": "12.5,5,16776960,user-hash",
                            "m": "真实弹幕",
                        },
                        {"cid": 0, "p": "bad", "m": "invalid"},
                    ],
                },
            )

        result = await _client(handler).comments_for_episode(
            title="葬送的芙莉莲",
            original_title="Frieren",
            episode_number=1,
            media_type="anime",
        )

        assert [request.url.path for request in requests] == [
            "/api/v2/search/episodes",
            "/api/v2/comment/12345",
        ]
        assert result.source["available"] is True
        assert result.source["episode_id"] == "12345"
        assert len(result.comments) == 1
        assert result.comments[0] == {
            "id": "dandanplay:12345:88",
            "provider": "弹弹play",
            "time_seconds": 12.5,
            "mode": "top",
            "color": 16776960,
            "text": "真实弹幕",
            "author": {"display_name": "user-hash", "is_mine": False},
        }

    asyncio.run(exercise())


def test_movie_search_does_not_send_episode_parameter():
    async def exercise():
        async def handler(request: httpx.Request) -> httpx.Response:
            if request.url.path == "/api/v2/search/episodes":
                assert request.url.params["anime"] == "流浪地球"
                assert "episode" not in request.url.params
                return httpx.Response(
                    200,
                    json=_search_payload(
                        title="流浪地球",
                        episode_id=700,
                        episode_title="电影",
                        media_type="movie",
                    ),
                )
            return httpx.Response(200, json={"success": True, "comments": []})

        result = await _client(handler).comments_for_episode(
            title="流浪地球",
            original_title="The Wandering Earth",
            episode_number=1,
            media_type="movie",
        )
        assert result.source["episode_id"] == "700"

    asyncio.run(exercise())


def test_search_falls_back_to_original_title_and_rejects_wrong_matches():
    async def exercise():
        keywords: list[str] = []
        comment_calls = 0

        async def handler(request: httpx.Request) -> httpx.Response:
            nonlocal comment_calls
            if request.url.path == "/api/v2/search/episodes":
                keyword = request.url.params["anime"]
                keywords.append(keyword)
                if keyword == "葬送的芙莉莲":
                    return httpx.Response(200, json={"success": True, "animes": []})
                return httpx.Response(
                    200,
                    json=_search_payload(
                        title="Frieren",
                        episode_id=44,
                        episode_title="Episode 1",
                    ),
                )
            comment_calls += 1
            return httpx.Response(200, json={"success": True, "comments": []})

        client = _client(handler)
        result = await client.comments_for_episode(
            title="葬送的芙莉莲",
            original_title="Frieren",
            episode_number=1,
            media_type="anime",
        )
        assert result.source["episode_id"] == "44"
        assert keywords == ["葬送的芙莉莲", "Frieren"]
        assert comment_calls == 1

        async def wrong_handler(request: httpx.Request) -> httpx.Response:
            nonlocal comment_calls
            if request.url.path == "/api/v2/search/episodes":
                return httpx.Response(
                    200,
                    json={
                        "success": True,
                        "animes": [
                            {
                                "animeTitle": "完全无关的作品",
                                "episodes": [
                                    {"episodeId": 91, "episodeTitle": "第1话"}
                                ],
                            },
                            {
                                "animeTitle": "葬送的芙莉莲",
                                "episodes": [
                                    {"episodeId": 92, "episodeTitle": "第2话"}
                                ],
                            },
                        ],
                    },
                )
            comment_calls += 1
            return httpx.Response(200, json={"success": True, "comments": []})

        comment_calls = 0
        rejected = await _client(wrong_handler).comments_for_episode(
            title="葬送的芙莉莲",
            original_title="Frieren",
            episode_number=1,
            media_type="anime",
        )
        assert rejected.source["available"] is False
        assert "没有可靠匹配" in str(rejected.source["message"])
        assert comment_calls == 0

    asyncio.run(exercise())


def test_safe_comment_redirect_does_not_forward_authentication_headers():
    async def exercise():
        redirect_requests: list[httpx.Request] = []

        async def handler(request: httpx.Request) -> httpx.Response:
            if request.url.path == "/api/v2/search/episodes":
                return httpx.Response(200, json=_search_payload())
            if request.url.host == "api.dandanplay.net":
                assert request.headers["X-AppId"] == _APP_ID
                assert request.headers["X-Signature"]
                return httpx.Response(
                    302,
                    headers={"location": "https://cdn.example/comments/12345.json"},
                )
            redirect_requests.append(request)
            assert request.url == httpx.URL("https://cdn.example/comments/12345.json")
            assert "X-AppId" not in request.headers
            assert "X-Timestamp" not in request.headers
            assert "X-Signature" not in request.headers
            return httpx.Response(
                200,
                json={
                    "success": True,
                    "comments": [{"cid": 1, "p": "1,1,16777215", "m": "redirected"}],
                },
            )

        result = await _client(handler).comments_for_episode(
            title="葬送的芙莉莲",
            original_title="Frieren",
            episode_number=1,
            media_type="anime",
        )
        assert len(redirect_requests) == 1
        assert result.comments[0]["text"] == "redirected"

    asyncio.run(exercise())


@pytest.mark.parametrize(
    "location,addresses",
    [
        ("http://cdn.example/comments.json", [_PUBLIC_IP]),
        ("https://localhost/comments.json", ["127.0.0.1"]),
        ("https://private.example/comments.json", ["10.0.0.8"]),
        ("https://cdn.example:444/comments.json", [_PUBLIC_IP]),
        ("https://user:pass@cdn.example/comments.json", [_PUBLIC_IP]),
    ],
)
def test_redirect_ssrf_guards_reject_unsafe_targets(location, addresses):
    async def exercise():
        async def resolve(_host: str) -> list[str]:
            return addresses

        async def handler(_request: httpx.Request) -> httpx.Response:
            raise AssertionError("unsafe redirect must not be requested")

        client = _client(handler, resolve_host=resolve)
        with pytest.raises(DandanplayError):
            await client._ensure_safe_redirect(location)

    asyncio.run(exercise())


@pytest.mark.parametrize("has_comments,ttl", [(True, 60), (False, 10)])
def test_success_and_empty_results_use_their_own_cache_ttl(has_comments, ttl):
    async def exercise():
        now = [100.0]
        search_calls = 0
        comment_calls = 0

        async def handler(request: httpx.Request) -> httpx.Response:
            nonlocal search_calls, comment_calls
            if request.url.path == "/api/v2/search/episodes":
                search_calls += 1
                return httpx.Response(200, json=_search_payload())
            comment_calls += 1
            comments = (
                [{"cid": 1, "p": "1,1,16777215", "m": "cached"}] if has_comments else []
            )
            return httpx.Response(200, json={"success": True, "comments": comments})

        client = _client(handler, clock=lambda: now[0])
        arguments = {
            "title": "葬送的芙莉莲",
            "original_title": "Frieren",
            "episode_number": 1,
            "media_type": "anime",
        }
        await client.comments_for_episode(**arguments)
        await client.comments_for_episode(**arguments)
        assert (search_calls, comment_calls) == (1, 1)

        now[0] += ttl + 1
        await client.comments_for_episode(**arguments)
        assert (search_calls, comment_calls) == (2, 2)

    asyncio.run(exercise())


def test_cache_has_a_hard_entry_limit_and_evicts_the_oldest_result():
    async def exercise():
        search_calls = 0

        async def handler(request: httpx.Request) -> httpx.Response:
            nonlocal search_calls
            if request.url.path == "/api/v2/search/episodes":
                search_calls += 1
                return httpx.Response(
                    200,
                    json=_search_payload(title=request.url.params["anime"]),
                )
            return httpx.Response(
                200,
                json={
                    "success": True,
                    "comments": [{"cid": 1, "p": "1,1,16777215", "m": "cached"}],
                },
            )

        client = _client(handler, cache_max_entries=2)

        async def load(title: str):
            return await client.comments_for_episode(
                title=title,
                original_title="",
                episode_number=1,
                media_type="anime",
            )

        await load("作品甲")
        await load("作品乙")
        await load("作品丙")
        await load("作品甲")

        assert search_calls == 4
        assert len(client._cache) == 2

    asyncio.run(exercise())


def test_concurrent_identical_requests_share_one_upstream_flight():
    async def exercise():
        search_started = asyncio.Event()
        release_search = asyncio.Event()
        search_calls = 0
        comment_calls = 0

        async def handler(request: httpx.Request) -> httpx.Response:
            nonlocal search_calls, comment_calls
            if request.url.path == "/api/v2/search/episodes":
                search_calls += 1
                search_started.set()
                await release_search.wait()
                return httpx.Response(200, json=_search_payload())
            comment_calls += 1
            return httpx.Response(
                200,
                json={
                    "success": True,
                    "comments": [{"cid": 1, "p": "1,1,16777215", "m": "shared"}],
                },
            )

        client = _client(handler)
        arguments = {
            "title": "葬送的芙莉莲",
            "original_title": "Frieren",
            "episode_number": 1,
            "media_type": "anime",
        }
        first = asyncio.create_task(client.comments_for_episode(**arguments))
        await search_started.wait()
        second = asyncio.create_task(client.comments_for_episode(**arguments))
        await asyncio.sleep(0)
        release_search.set()
        first_result, second_result = await asyncio.gather(first, second)

        assert search_calls == 1
        assert comment_calls == 1
        assert first_result == second_result

    asyncio.run(exercise())


@pytest.mark.parametrize(
    "failure", ["timeout", "401", "403", "invalid-json", "oversized"]
)
def test_upstream_failures_are_not_cached(failure):
    async def exercise():
        calls = 0

        async def handler(request: httpx.Request) -> httpx.Response:
            nonlocal calls
            calls += 1
            if failure == "timeout":
                raise httpx.ReadTimeout("timeout", request=request)
            if failure in {"401", "403"}:
                return httpx.Response(int(failure), json={"success": False})
            if failure == "invalid-json":
                return httpx.Response(200, content=b"not-json")
            return httpx.Response(200, content=b"x" * 256)

        client = _client(handler, max_response_bytes=32)
        arguments = {
            "title": "葬送的芙莉莲",
            "original_title": "Frieren",
            "episode_number": 1,
            "media_type": "anime",
        }
        for _ in range(2):
            with pytest.raises(DandanplayError):
                await client.comments_for_episode(**arguments)
        assert calls == 2

    asyncio.run(exercise())


def test_cancelled_initiator_keeps_shared_flight_and_populates_cache():
    async def exercise():
        search_started = asyncio.Event()
        release_search = asyncio.Event()
        search_calls = 0
        comment_calls = 0
        guard_calls = 0

        async def handler(request: httpx.Request) -> httpx.Response:
            nonlocal search_calls, comment_calls
            if request.url.path == "/api/v2/search/episodes":
                search_calls += 1
                search_started.set()
                await release_search.wait()
                return httpx.Response(200, json=_search_payload())
            comment_calls += 1
            return httpx.Response(
                200,
                json={
                    "success": True,
                    "comments": [{"cid": 1, "p": "1,1,16777215", "m": "shared"}],
                },
            )

        async def guard():
            nonlocal guard_calls
            guard_calls += 1

        client = _client(handler)
        arguments = {
            "title": "葬送的芙莉莲",
            "original_title": "Frieren",
            "episode_number": 1,
            "media_type": "anime",
            "before_upstream": guard,
        }
        first = asyncio.create_task(client.comments_for_episode(**arguments))
        await search_started.wait()
        first.cancel()
        with pytest.raises(asyncio.CancelledError):
            await first

        second = asyncio.create_task(client.comments_for_episode(**arguments))
        await asyncio.sleep(0)
        assert search_calls == 1
        assert guard_calls == 1

        release_search.set()
        second_result = await second
        cached_result = await client.comments_for_episode(**arguments)
        await asyncio.sleep(0)

        assert second_result == cached_result
        assert (search_calls, comment_calls, guard_calls) == (1, 1, 1)
        assert client._in_flight == {}
        assert len(client._cache) == 1

    asyncio.run(exercise())


@pytest.mark.parametrize("stage", ["search", "comments", "redirect"])
@pytest.mark.parametrize(
    "status,code,retryable",
    [
        (401, "authorization", False),
        (403, "authorization", False),
        (429, "rate_limited", False),
        (422, "upstream_error", False),
        (408, "timeout", True),
        (502, "upstream_unavailable", True),
        (503, "upstream_unavailable", True),
        (504, "timeout", True),
    ],
)
def test_http_failure_retryability_is_explicit(stage, status, code, retryable):
    async def exercise():
        async def handler(request):
            if stage != "search" and request.url.path == "/api/v2/search/episodes":
                return httpx.Response(200, json=_search_payload())
            if stage == "redirect" and request.url.path.startswith("/api/v2/comment/"):
                return httpx.Response(
                    302, headers={"location": "https://cdn.example/comments"}
                )
            return httpx.Response(status)

        with pytest.raises(DandanplayError) as caught:
            await _client(handler).comments_for_episode(
                title="葬送的芙莉莲",
                original_title="Frieren",
                episode_number=1,
                media_type="anime",
            )
        assert caught.value.code == code
        assert caught.value.retryable is retryable

    asyncio.run(exercise())


@pytest.mark.parametrize(
    "error,code,retryable",
    [
        (httpx.ReadTimeout("slow"), "timeout", True),
        (httpx.ConnectError("offline"), "transport", True),
        (httpx.UnsupportedProtocol("bad protocol"), "upstream_error", False),
    ],
)
def test_transport_failure_retryability_is_explicit(error, code, retryable):
    async def exercise():
        async def handler(_request):
            raise error

        with pytest.raises(DandanplayError) as caught:
            await _client(handler).comments_for_episode(
                title="葬送的芙莉莲",
                original_title="Frieren",
                episode_number=1,
                media_type="anime",
            )
        assert caught.value.code == code
        assert caught.value.retryable is retryable

    asyncio.run(exercise())
