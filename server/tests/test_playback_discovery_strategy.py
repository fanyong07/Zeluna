import asyncio
import unittest
from dataclasses import dataclass

from server.playback_discovery.strategy import (
    DiscoverySource,
    progressive_alias_search,
)


@dataclass(frozen=True)
class Attempt:
    source: str
    alias: str
    terminal: bool = False


class ProgressiveAliasSearchTests(unittest.IsolatedAsyncioTestCase):
    async def test_inventory_sizes_obey_query_and_concurrency_budgets(self):
        for source_count in (20, 60, 100):
            with self.subTest(source_count=source_count):
                sources = [
                    DiscoverySource(
                        key=f"source-{index:03d}",
                        preferred=index < min(10, source_count),
                        weight=100 - index,
                    )
                    for index in range(source_count)
                ]
                attempts: list[Attempt] = []
                active = 0
                max_active = 0

                async def query(
                    source: DiscoverySource,
                    alias: str,
                ) -> Attempt:
                    nonlocal active, max_active
                    active += 1
                    max_active = max(max_active, active)
                    try:
                        await asyncio.sleep(0.002)
                        attempt = Attempt(source.key, alias)
                        attempts.append(attempt)
                        return attempt
                    finally:
                        active -= 1

                results = [
                    result
                    async for result in progressive_alias_search(
                        sources,
                        ["alias-a", "alias-b", "alias-c"],
                        query=query,
                        is_terminal=lambda _result: False,
                        query_budget=32,
                        max_concurrency=6,
                        fallback_delay_seconds=0,
                    )
                ]

                self.assertEqual(len(results), 32)
                self.assertEqual(len(attempts), 32)
                self.assertLessEqual(max_active, 6)
                self.assertEqual(active, 0)
                queried_sources = {item.source for item in attempts}
                self.assertGreaterEqual(
                    len(queried_sources),
                    min(20, source_count),
                )
                if source_count > 32:
                    self.assertLess(len(queried_sources), source_count)

    async def test_terminal_source_does_not_spend_more_aliases(self):
        sources = [
            DiscoverySource(key=f"source-{index}", preferred=True)
            for index in range(4)
        ]
        attempts: list[Attempt] = []

        async def query(source: DiscoverySource, alias: str) -> Attempt:
            attempt = Attempt(source.key, alias, terminal=True)
            attempts.append(attempt)
            return attempt

        results = [
            result
            async for result in progressive_alias_search(
                sources,
                ["first", "second", "third"],
                query=query,
                is_terminal=lambda result: result.terminal,
                query_budget=50,
                max_concurrency=2,
            )
        ]

        self.assertEqual(len(results), 4)
        self.assertEqual({item.alias for item in attempts}, {"first"})

    async def test_priority_group_orders_sources_before_weight(self):
        sources = [
            DiscoverySource(
                key="client-probe",
                priority_group=3,
                weight=1000,
            ),
            DiscoverySource(
                key="core",
                priority_group=0,
                weight=1,
            ),
            DiscoverySource(
                key="fallback",
                priority_group=1,
                weight=500,
            ),
        ]
        attempts: list[Attempt] = []

        async def query(source: DiscoverySource, alias: str) -> Attempt:
            attempt = Attempt(source.key, alias, terminal=True)
            attempts.append(attempt)
            return attempt

        results = [
            result
            async for result in progressive_alias_search(
                sources,
                ["first"],
                query=query,
                is_terminal=lambda result: result.terminal,
                query_budget=3,
                max_concurrency=1,
            )
        ]

        self.assertEqual(
            [item.source for item in results],
            ["core", "fallback", "client-probe"],
        )

    async def test_closing_consumer_cancels_every_pending_query(self):
        sources = [
            DiscoverySource(key="fast", preferred=True, weight=100),
            *[
                DiscoverySource(
                    key=f"slow-{index}",
                    preferred=True,
                    weight=90 - index,
                )
                for index in range(8)
            ],
        ]
        never = asyncio.Event()
        active = 0
        cancelled = 0

        async def query(source: DiscoverySource, alias: str) -> Attempt:
            nonlocal active, cancelled
            active += 1
            try:
                if source.key == "fast":
                    await asyncio.sleep(0)
                    return Attempt(source.key, alias, terminal=True)
                try:
                    await never.wait()
                except asyncio.CancelledError:
                    cancelled += 1
                    raise
                return Attempt(source.key, alias)
            finally:
                active -= 1

        iterator = progressive_alias_search(
            sources,
            ["first", "second"],
            query=query,
            is_terminal=lambda result: result.terminal,
            query_budget=18,
            max_concurrency=5,
        )
        first = await asyncio.wait_for(anext(iterator), timeout=0.2)
        await iterator.aclose()

        self.assertEqual(first.source, "fast")
        self.assertEqual(active, 0)
        self.assertGreaterEqual(cancelled, 1)


if __name__ == "__main__":
    unittest.main()
