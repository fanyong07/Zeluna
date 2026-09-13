import asyncio
from dataclasses import dataclass
from types import SimpleNamespace

from functools import wraps

from server.aggregator import AggregatedVideoLine
from tools.probe_all_routes import Sample, probe_sample, safe_label, verify_all_lines


def run_async(function):
    @wraps(function)
    def run():
        return asyncio.run(function())
    return run


@dataclass
class Check:
    status: str = "server_verified"
    error_category: str = ""


@run_async
async def test_verifies_all_routes_without_success_short_circuit_and_preserves_identity():
    class Verifier:
        calls = 0

        async def _line_verification_status(self, line, detailed=False):
            self.calls += 1
            return Check("unavailable" if line.url.endswith("bad") else "server_verified")

    verifier = Verifier()
    lines = [AggregatedVideoLine(url=f"https://media.example/{i}?token=secret", source=f"line-{i}") for i in range(58)]
    lines += [AggregatedVideoLine(url=lines[0].url, source="same-url-other-identity")]
    lines += [AggregatedVideoLine(url="https://media.example/bad", source="bad")]
    rows = await verify_all_lines(verifier, lines, asyncio.Semaphore(4), {})
    assert len(rows) == 60
    assert verifier.calls == 59
    assert rows[58]["route"] == "same-url-other-identity"
    assert rows[59]["verification"]["status"] == "unavailable"
    assert "secret" not in str(rows)
    assert "https://" not in str(rows)


@run_async
async def test_keeps_episode_three_when_episode_one_has_no_lines():
    class Scraper:
        content_types = ["series"]
        calls = []

        async def get_detail(self, source_id):
            return SimpleNamespace(episodes=[SimpleNamespace(number=n) for n in (1, 3)])

        async def get_video_urls(self, source_id, episode):
            self.calls.append(episode)
            return []

    class Aggregator:
        async def discover_source_matches(self, *args, **kwargs):
            return [SimpleNamespace(score=100, title="庆余年", content_type="tv", year=2019,
                    episode_count=46, source_id="crawler:test:abc")], {}

    scraper = Scraper()
    result = await probe_sample(Aggregator(), scraper, "test",
        Sample("庆余年", ("庆余年",), "series", 2019, (1, 3)), asyncio.Semaphore(1), {})
    assert scraper.calls == [1, 3]
    assert len(result["episodes"]) == 2
    assert all(ep["status"] == "no_media_candidates" for ep in result["episodes"])


@run_async
async def test_unsupported_category_is_explicit_not_invented_stock():
    result = await probe_sample(None, SimpleNamespace(content_types=["anime"]), "test",
        Sample("庆余年", ("庆余年",), "series", 2019, (1,)), asyncio.Semaphore(1), {})
    assert result["status"] == "unsupported_content_type"


def test_upstream_url_bearing_labels_are_redacted():
    assert safe_label("line https://host/media?token=abc") == "line [redacted-url]"
