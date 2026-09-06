"""Bounded progressive discovery strategies shared by playback providers."""

from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator, Awaitable, Callable, Sequence
from dataclasses import dataclass
from typing import TypeVar


T = TypeVar("T")


@dataclass(frozen=True)
class DiscoverySource:
    """Public identity and scheduling hints for one independently queried source."""

    key: str
    preferred: bool = False
    priority_group: int = 0
    weight: int = 0


async def progressive_alias_search(
    sources: Sequence[DiscoverySource],
    aliases: Sequence[str],
    *,
    query: Callable[[DiscoverySource, str], Awaitable[T]],
    is_terminal: Callable[[T], bool],
    query_budget: int,
    max_concurrency: int,
    fallback_delay_seconds: float = 0.0,
) -> AsyncIterator[T]:
    """Yield source attempts while enforcing alias, budget, and wave invariants.

    One source/alias pair consumes one query unit. Aliases for one source are
    attempted in order and stop after ``is_terminal`` returns true. Preferred
    sources start immediately; fallback sources join after the configured
    delay. Closing the iterator cancels every pending query before returning.
    """

    ordered_sources = sorted(
        (source for source in sources if source.key),
        key=lambda source: (
            0 if source.preferred else 1,
            source.priority_group,
            -source.weight,
            source.key,
        ),
    )
    ordered_aliases = tuple(alias for alias in aliases if alias)
    if not ordered_sources or not ordered_aliases or query_budget <= 0:
        return

    semaphore = asyncio.Semaphore(max(1, max_concurrency))
    budget_lock = asyncio.Lock()
    remaining_budget = query_budget
    queue: asyncio.Queue[T | object] = asyncio.Queue()
    completed = object()
    # Wake one fallback wave together. Per-worker timers can expire on
    # different event-loop turns and let the first worker spend a second
    # alias unit before its peers have even entered the semaphore queue.
    fallback_wave = (
        asyncio.create_task(asyncio.sleep(fallback_delay_seconds))
        if fallback_delay_seconds > 0
        and any(not source.preferred for source in ordered_sources)
        else None
    )

    async def claim_query_unit() -> bool:
        nonlocal remaining_budget
        async with budget_lock:
            if remaining_budget <= 0:
                return False
            remaining_budget -= 1
            return True

    async def run_source(source: DiscoverySource) -> None:
        if not source.preferred and fallback_wave is not None:
            await asyncio.shield(fallback_wave)
        for alias in ordered_aliases:
            async with semaphore:
                if not await claim_query_unit():
                    return
                result = await query(source, alias)
            await queue.put(result)
            if is_terminal(result):
                return
            # A zero-latency adapter or mock must not let one source consume
            # the whole global budget before peer sources receive their first
            # alias attempt. Yield once between aliases to preserve wave
            # fairness without serialising real network requests.
            await asyncio.sleep(0)

    workers = [
        asyncio.create_task(run_source(source))
        for source in ordered_sources
    ]

    async def finish_workers() -> None:
        try:
            await asyncio.gather(*workers, return_exceptions=True)
        finally:
            queue.put_nowait(completed)

    finisher = asyncio.create_task(finish_workers())
    try:
        while True:
            result = await queue.get()
            if result is completed:
                return
            yield result
    finally:
        tasks = [*workers, finisher]
        if fallback_wave is not None:
            tasks.append(fallback_wave)
        for task in tasks:
            if not task.done():
                task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
