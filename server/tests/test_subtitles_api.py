import asyncio

import httpx
from httpx import ASGITransport, AsyncClient
import pytest

from server.app import create_app
from server.subtitles import (
    MAX_FILE_BYTES,
    ProviderCandidate,
    SubtitleSearchRequest,
    SubtitleService,
    SubtitleServiceError,
    candidate_match,
    get_subtitle_service,
)


def request(**overrides):
    return SubtitleSearchRequest(
        **(
            {
                "subject_key": "bangumi:100",
                "episode_key": "v1|bangumi:100|episode:1",
                "title": "Example",
                "original_title": "Example",
                "language": "ja",
                "episode_number": 1,
                "year": 2026,
                "media_type": "anime",
            }
            | overrides
        )
    )


def candidate(**overrides):
    return ProviderCandidate(
        **(
            {
                "entry_id": "sample",
                "file_name": "Example.01.srt",
                "language": "ja",
                "download_url": "https://subtitles.example/01.srt",
                "identity_verified": True,
                "episode_verified": True,
                "subject_key": "bangumi:100",
                "title": "Example",
                "year": 2026,
                "media_type": "anime",
                "episode_number": 1,
            }
            | overrides
        )
    )


class Provider:
    id = "test"
    allowed_hosts = frozenset({"subtitles.example"})
    policy_approved = True

    def __init__(self, items=()):
        self.items = items
        self.calls = 0

    async def search(self, body):
        self.calls += 1
        return self.items


def test_default_never_requests_blocked_site_and_distinguishes_statuses():
    async def exercise():
        service = SubtitleService()
        japanese = await service.search(request())
        assert japanese["status"] == "provider_unavailable"
        assert japanese["sources"][0]["reason"] == "policy_blocked"
        assert japanese["candidates"] == []
        english = await service.search(request(language="en"))
        assert english["status"] == "manual_required"
        blocked = Provider([candidate()])
        blocked.policy_approved = False
        assert (await SubtitleService((blocked,)).search(request()))[
            "status"
        ] == "provider_unavailable"
        assert blocked.calls == 0
        empty = Provider()
        result = await SubtitleService((empty,)).search(request(language="en"))
        assert result["status"] == "not_found"

    asyncio.run(exercise())


def test_matching_conflicts_missing_season_and_movie():
    assert candidate_match(request(), candidate())[0]
    for item in [
        candidate(year=1999),
        candidate(subject_key="bangumi:200"),
        candidate(special=True),
        candidate(episode_number=2),
        candidate(season_number=1),
        candidate(subject_key="", year=None),
    ]:
        assert not candidate_match(request(), item)[0]
    assert candidate_match(
        request(season_number=2, season_episode_number=1), candidate(season_number=2)
    )[0]
    assert not candidate_match(
        request(season_number=2, season_episode_number=1), candidate(season_number=1)
    )[0]
    assert candidate_match(
        request(media_type="movie"), candidate(media_type="movie", episode_number=None)
    )[0]


def test_download_opaque_ids_cache_and_no_cookie_or_authorization():
    async def exercise():
        calls = []

        def handler(req):
            calls.append(req)
            assert "authorization" not in req.headers
            assert "cookie" not in req.headers
            return httpx.Response(
                200,
                content=b"1\n00:00:01,000 --> 00:00:02,000\nhello",
                headers={"Content-Type": "application/x-subrip"},
            )

        service = SubtitleService(
            (Provider([candidate()]),), transport=httpx.MockTransport(handler)
        )
        result = await service.search(request())
        found = result["candidates"][0]
        assert "download_url" not in found
        assert found["auto_match"] and not found["timing_verified"]
        one = await service.content(found["id"])
        two = await service.content(found["id"])
        assert one == two and len(calls) == 1
        with pytest.raises(SubtitleServiceError, match="candidate_expired"):
            await service.content("https://127.0.0.1/secret")

    asyncio.run(exercise())


@pytest.mark.parametrize(
    "url",
    [
        "http://subtitles.example/a.srt",
        "https://evil.example/a.srt",
        "https://subtitles.example:444/a.srt",
        "https://a:b@subtitles.example/a.srt",
        "https://subtitles.example/%2e%2e/a.srt",
        "https://subtitles.example:bad/a.srt",
    ],
)
def test_allowlist_rejects_unsafe_urls(url):
    with pytest.raises(SubtitleServiceError):
        SubtitleService._validate_url(url, frozenset({"subtitles.example"}))


@pytest.mark.parametrize("kind", ["redirect", "html", "oversize", "forbidden"])
def test_malicious_or_protected_content_is_not_downloaded(kind):
    async def exercise():
        calls = []

        def handler(req):
            calls.append(str(req.url))
            if kind == "redirect":
                return httpx.Response(
                    302, headers={"Location": "https://127.0.0.1/admin"}
                )
            if kind == "html":
                return httpx.Response(
                    200,
                    content=b"<html>captcha</html>",
                    headers={"Content-Type": "text/html"},
                )
            if kind == "oversize":
                return httpx.Response(200, content=b"x" * (MAX_FILE_BYTES + 1))
            return httpx.Response(403)

        service = SubtitleService(
            (Provider([candidate()]),), transport=httpx.MockTransport(handler)
        )
        identifier = (await service.search(request()))["candidates"][0]["id"]
        with pytest.raises(SubtitleServiceError):
            await service.content(identifier)
        assert len(calls) == 1

    asyncio.run(exercise())


def test_candidate_expiry_and_provider_failure():
    class Broken(Provider):
        async def search(self, body):
            raise httpx.ConnectError("upstream secret detail")

    async def exercise():
        result = await SubtitleService((Broken(),)).search(request())
        assert "upstream secret detail" not in str(result)
        assert result["status"] == "provider_unavailable"
        now = [0]
        service = SubtitleService((Provider([candidate()]),), clock=lambda: now[0])
        identifier = (await service.search(request()))["candidates"][0]["id"]
        now[0] = 601
        with pytest.raises(SubtitleServiceError, match="candidate_expired"):
            await service.content(identifier)

    asyncio.run(exercise())


def test_routes_validation_compatibility_and_no_url_proxy():
    async def exercise():
        app = create_app()
        app.dependency_overrides[get_subtitle_service] = lambda: SubtitleService()
        async with AsyncClient(
            transport=ASGITransport(app=app), base_url="http://test"
        ) as client:
            response = await client.post(
                "/api/v3/subtitles/search", json=request().model_dump()
            )
            assert response.status_code == 200
            assert response.json()["status"] == "provider_unavailable"
            response = await client.post(
                "/api/v3/subtitles/search",
                json=request().model_dump() | {"video_url": "https://private/video"},
            )
            assert response.status_code == 422
            response = await client.get(
                "/api/v3/subtitles/unknown/content", params={"url": "https://127.0.0.1"}
            )
            assert response.status_code == 404

    asyncio.run(exercise())
