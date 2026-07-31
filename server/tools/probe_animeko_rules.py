"""筛选公开 Animeko Web Selector 规则中的静态直链站点。

本工具只读取规则中的搜索和 DOM 选择器，直接访问每个原始站点；不会调用
Animeko、AniCh 或任何通用聚合解析服务。默认只做搜索阶段，找到候选后可用
``--full --name 站点名``继续验证详情、剧集、HLS 清单和首媒体分片。
"""

from __future__ import annotations

import argparse
import asyncio
import json
import re
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import quote, urljoin

import httpx
from bs4 import BeautifulSoup


PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

from server.aggregator import (  # noqa: E402
    CLIENT_PROBE_REQUIRED,
    SERVER_VERIFIED,
    AggregatedVideoLine,
    ContentAggregator,
)
from server.scrapers.anime.html_direct import (  # noqa: E402
    HtmlDirectAnimeScraper,
)


USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 Chrome/124.0.0.0 Safari/537.36"
)


@dataclass(frozen=True)
class Rule:
    name: str
    search_url: str
    subject_format: str
    subject_config: dict[str, Any]
    channel_format: str
    channel_config: dict[str, Any]
    cookies: str


def _load_rules(paths: list[Path]) -> list[Rule]:
    rules: dict[str, Rule] = {}
    for path in paths:
        data = json.loads(path.read_text(encoding="utf-8"))
        sources = data.get("exportedMediaSourceDataList", {}).get(
            "mediaSources", []
        )
        for source in sources:
            if source.get("factoryId") != "web-selector":
                continue
            arguments = source.get("arguments") or {}
            config = arguments.get("searchConfig") or {}
            search_url = str(config.get("searchUrl") or "").strip()
            name = str(arguments.get("name") or "").strip()
            subject_format = str(config.get("subjectFormatId") or "")
            channel_format = str(config.get("channelFormatId") or "")
            if not name or not search_url or subject_format not in {"a", "indexed"}:
                continue
            subject_key = (
                "selectorSubjectFormatA"
                if subject_format == "a"
                else "selectorSubjectFormatIndexed"
            )
            channel_key = (
                "selectorChannelFormatNoChannel"
                if channel_format == "no-channel"
                else "selectorChannelFormatFlattened"
            )
            match_video = config.get("matchVideo") or {}
            rule = Rule(
                name=name,
                search_url=search_url,
                subject_format=subject_format,
                subject_config=config.get(subject_key) or {},
                channel_format=channel_format,
                channel_config=config.get(channel_key) or {},
                cookies=str(match_video.get("cookies") or "").strip(),
            )
            rules.setdefault(search_url, rule)
    return list(rules.values())


def _search_url(rule: Rule, keyword: str) -> str:
    return (
        rule.search_url.replace("{keyword}", quote(keyword))
        .replace("{page}", "1")
        .replace("{keywordEncoded}", quote(keyword))
    )


def _element_href(element: Any) -> str:
    if element is None:
        return ""
    if getattr(element, "name", "") == "a":
        return str(element.get("href") or "").strip()
    anchor = element.find_parent("a") or element.select_one("a[href]")
    return str(anchor.get("href") or "").strip() if anchor else ""


def _search_items(rule: Rule, html: str, base_url: str) -> list[tuple[str, str]]:
    soup = BeautifulSoup(html, "lxml")
    items: list[tuple[str, str]] = []
    if rule.subject_format == "a":
        selector = str(rule.subject_config.get("selectLists") or "")
        for element in soup.select(selector):
            href = _element_href(element)
            title = element.get_text(" ", strip=True)
            if href and title:
                items.append((title, urljoin(base_url, href)))
    else:
        name_selector = str(rule.subject_config.get("selectNames") or "")
        link_selector = str(rule.subject_config.get("selectLinks") or "")
        names = soup.select(name_selector)
        links = soup.select(link_selector)
        for name_element, link_element in zip(names, links):
            title = name_element.get_text(" ", strip=True)
            href = _element_href(link_element)
            if href and title:
                items.append((title, urljoin(base_url, href)))
    unique: dict[str, tuple[str, str]] = {}
    for title, url in items:
        unique.setdefault(url, (title, url))
    return list(unique.values())


def _episode_urls(rule: Rule, html: str, base_url: str) -> list[str]:
    soup = BeautifulSoup(html, "lxml")
    config = rule.channel_config
    list_selector = str(
        config.get("selectEpisodeLists")
        or config.get("selectEpisodeList")
        or ""
    )
    episode_selector = str(
        config.get("selectEpisodesFromList")
        or config.get("selectEpisodes")
        or "a"
    )
    link_selector = str(config.get("selectEpisodeLinksFromList") or "")
    containers = soup.select(list_selector) if list_selector else [soup]
    urls: list[str] = []
    for container in containers:
        for episode in container.select(episode_selector):
            link_element = (
                episode.select_one(link_selector) if link_selector else episode
            )
            href = _element_href(link_element)
            if href:
                urls.append(urljoin(base_url, href))
    return list(dict.fromkeys(urls))


async def _probe_rule(
    rule: Rule,
    *,
    keyword: str,
    full: bool,
    timeout: float,
    aggregator: ContentAggregator,
) -> dict[str, Any]:
    result: dict[str, Any] = {
        "name": rule.name,
        "status": 0,
        "results": 0,
        "episodes": 0,
        "candidates": 0,
        "verified": 0,
        "client_probe": 0,
        "latency": 0.0,
        "note": "",
    }
    started = time.monotonic()
    headers = {"User-Agent": USER_AGENT, "Accept-Language": "zh-CN,zh;q=0.9"}
    if rule.cookies:
        headers["Cookie"] = rule.cookies
    try:
        async with httpx.AsyncClient(
            headers=headers,
            timeout=httpx.Timeout(timeout, connect=min(timeout, 6)),
            follow_redirects=True,
        ) as client:
            response = await client.get(_search_url(rule, keyword))
            result["status"] = response.status_code
            if response.status_code != 200:
                result["note"] = f"HTTP {response.status_code}"
                return result
            items = _search_items(rule, response.text, str(response.url))
            result["results"] = len(items)
            if not items or not full:
                return result

            selected = min(
                items[:8],
                key=lambda item: (
                    0 if item[0].strip() == keyword else 1,
                    abs(len(item[0]) - len(keyword)),
                ),
            )
            detail = await client.get(selected[1])
            if detail.status_code != 200:
                result["note"] = f"详情 HTTP {detail.status_code}"
                return result
            episode_urls = _episode_urls(rule, detail.text, str(detail.url))
            result["episodes"] = len(episode_urls)
            for play_url in episode_urls[:3]:
                play = await client.get(play_url, headers={"Referer": str(detail.url)})
                if play.status_code != 200:
                    continue
                media_urls = HtmlDirectAnimeScraper._player_urls(play.text)
                for media_url in media_urls:
                    result["candidates"] += 1
                    line = AggregatedVideoLine(
                        url=media_url,
                        title=rule.name,
                        format="hls" if "m3u8" in media_url.lower() else "mp4",
                        source=f"rule:{rule.name}",
                        headers={"Referer": str(play.url)},
                    )
                    status = await aggregator._line_verification_status(line)
                    if status == SERVER_VERIFIED:
                        result["verified"] += 1
                    elif status == CLIENT_PROBE_REQUIRED:
                        result["client_probe"] += 1
                if result["verified"] or result["client_probe"]:
                    break
    except Exception as error:
        result["note"] = type(error).__name__
    finally:
        result["latency"] = round(time.monotonic() - started, 1)
    return result


async def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", action="append", type=Path, required=True)
    parser.add_argument("--name", action="append", default=[])
    parser.add_argument("--keyword", default="葬送的芙莉莲")
    parser.add_argument("--full", action="store_true")
    parser.add_argument("--concurrency", type=int, default=3)
    parser.add_argument("--timeout", type=float, default=10.0)
    parser.add_argument("--source-timeout", type=float, default=35.0)
    args = parser.parse_args()

    rules = _load_rules(args.config)
    if args.name:
        wanted = set(args.name)
        rules = [rule for rule in rules if rule.name in wanted]
    semaphore = asyncio.Semaphore(max(1, args.concurrency))
    aggregator = ContentAggregator()

    async def run(rule: Rule) -> dict[str, Any]:
        async with semaphore:
            try:
                return await asyncio.wait_for(
                    _probe_rule(
                        rule,
                        keyword=args.keyword,
                        full=args.full,
                        timeout=max(3.0, args.timeout),
                        aggregator=aggregator,
                    ),
                    timeout=max(5.0, args.source_timeout),
                )
            except TimeoutError:
                return {
                    "name": rule.name,
                    "status": 0,
                    "results": 0,
                    "episodes": 0,
                    "candidates": 0,
                    "verified": 0,
                    "client_probe": 0,
                    "latency": round(max(5.0, args.source_timeout), 1),
                    "note": "整站超时",
                }

    try:
        results = await asyncio.gather(*(run(rule) for rule in rules))
    finally:
        await aggregator.aclose()

    results.sort(
        key=lambda item: (
            item["verified"],
            item["client_probe"],
            item["results"],
            -item["latency"],
        ),
        reverse=True,
    )
    print(
        f"{'来源':<20} {'HTTP':<6} {'搜索':<6} {'剧集':<6} {'候选':<6} "
        f"{'服务端':<7} {'客户端':<7} {'耗时':<7} 备注"
    )
    print("-" * 94)
    for item in results:
        print(
            f"{item['name']:<20} {item['status']:<6} {item['results']:<6} "
            f"{item['episodes']:<6} {item['candidates']:<6} "
            f"{item['verified']:<7} {item['client_probe']:<7} "
            f"{str(item['latency']) + 's':<7} {item['note']}"
        )


if __name__ == "__main__":
    asyncio.run(main())
