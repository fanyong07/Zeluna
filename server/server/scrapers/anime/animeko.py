"""Animeko 规则库适配器(``crawler.animeko``)。

一个爬虫背后是**一整个规则库**:订阅文件里的每条 ``mediaSource`` 都是一个独立
站点,各自有搜索模板、选择器、线路线与取流正则。本适配器把它们包装成 Zeluna 的
``BaseScraper`` 形态:

* ``search`` 扇出到全部规则,逐源隔离(单源失败/超时只丢该源);
* ``source_id`` 里同时携带**哪条规则**与**条目地址**,因为 21 个源共用一个爬虫名,
  只存站内 id 会撞车;
* ``get_detail`` 把线路名塞进剧集标题,``get_video_urls`` 再按集号回到该集的所有
  线路取流。

三条硬约束(踩过的坑都写在代码里):

1. 取流必须把站点的 cookie 与 Referer 带上**每一个分片请求**,所以它们必须落在
   ``VideoLine.headers`` 上,而不是只在取页面的那次请求里用掉;
2. 站点会回 403/468/验证码页,这时要跳开该源而不是抛异常炸掉整轮搜索;
3. 每个源按规则里的 ``requestInterval`` 限速,节流在 :mod:`animeko_engines` 里实现。
"""

from __future__ import annotations

import asyncio
import logging
import re
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Optional, Sequence

import httpx

from ... import config
from ..base import (
    BaseScraper,
    EpisodeInfo,
    SubjectDetail,
    SubjectResult,
    VideoLine,
    media_format_from_url,
)
from ..content_identity import classify_content
from .animeko_engines import (
    HttpFetcher,
    JsonApiEngine,
    RssEngine,
    SelectorEngine,
    SourceBlockedError,
    SourceUnavailableError,
    WebEpisode,
    WebSubject,
)
from .animeko_rules import MediaSourceRule, RuleRepository, guess_base_url

logger = logging.getLogger(__name__)

#: ``source_id`` 的分隔符。规则 id 里不会出现它(订阅里的 id 都是 slug)。
SOURCE_ID_SEPARATOR = "|"
_SOURCE_ID_RE = re.compile(r"^([A-Za-z0-9][A-Za-z0-9._-]{0,63})\|(https?://\S+)$")


@dataclass
class _RuleOutcome:
    """单条规则的搜索结果(或失败原因)。失败信息只用于日志,不参与返回。"""

    rule_id: str
    subjects: list[WebSubject]
    error: str = ""
    elapsed_seconds: float = 0.0


class AnimekoScraper(BaseScraper):
    """把 animeko-subs 规则库当成一个(多源)爬虫接入。"""

    def __init__(
        self,
        *,
        rules: Optional[Sequence[MediaSourceRule]] = None,
        repository: Optional[RuleRepository] = None,
        client: Optional[httpx.AsyncClient] = None,
        transport: Optional[httpx.AsyncBaseTransport] = None,
        enabled: Optional[bool] = None,
        source_ids: Optional[Iterable[str]] = None,
        fetcher: Optional[HttpFetcher] = None,
    ) -> None:
        super().__init__()
        self._name = "animeko"
        self._enabled = config.ANIMEKO_ENABLED if enabled is None else bool(enabled)
        self._rules: tuple[MediaSourceRule, ...] = tuple(rules or ())
        self._rules_injected = rules is not None
        self._repository = repository
        self._transport = transport
        self._client = client
        # 只启用订阅里的部分源(排查期很有用,默认全开)。
        self._source_ids = (
            frozenset(item.strip() for item in source_ids if item.strip())
            if source_ids is not None
            else frozenset(config.ANIMEKO_SOURCE_IDS)
        )
        self._fetcher = fetcher or HttpFetcher(
            client=client,
            transport=transport,
            timeout_seconds=config.ANIMEKO_REQUEST_TIMEOUT_SECONDS,
            retries=config.ANIMEKO_REQUEST_RETRIES,
            default_user_agent=config.ANIMEKO_USER_AGENT,
        )
        self._engines: dict[str, SelectorEngine | JsonApiEngine | RssEngine] = {}
        #: (规则, 条目地址) → (写入时间, 剧集表)。详情与取流在同一轮里紧挨着发生,
        #  不缓存就会把一个详情页抓两遍,还多吃一次站点限速。
        self._episode_cache: dict[str, tuple[float, list[WebEpisode]]] = {}
        self._subject_cache: dict[str, WebSubject] = {}
        self._closed = False

    # ── 元信息 ──────────────────────────────────────────────

    @property
    def content_types(self) -> list[str]:
        return list(config.ANIMEKO_CONTENT_TYPES)

    @property
    def base_url(self) -> str:
        urls = config.ANIMEKO_SUBSCRIPTION_URLS
        if urls:
            return guess_base_url(urls[0]) or "https://sub.creamycake.org"
        return "https://sub.creamycake.org"

    @property
    def enabled(self) -> bool:
        return self._enabled

    async def rules(self, *, force: bool = False) -> tuple[MediaSourceRule, ...]:
        """取规则集合:注入的 rules 优先,否则从订阅仓储拉。"""
        if self._rules_injected and not force:
            return self._filtered_rules(self._rules)
        if self._repository is None:
            self._repository = RuleRepository(
                config.ANIMEKO_SUBSCRIPTION_URLS,
                client=self._client,
                cache_path=_rules_cache_path(),
                memory_ttl_seconds=config.ANIMEKO_RULES_CACHE_SECONDS,
                timeout_seconds=config.ANIMEKO_REQUEST_TIMEOUT_SECONDS,
                proxy=config.ANIMEKO_SUBSCRIPTION_PROXY,
            )
        loaded = tuple(await self._repository.load(force=force))
        if loaded != self._rules:
            # 相同 id 的规则升级也应重建引擎,否则仍沿用旧选择器和详情缓存。
            self._engines.clear()
            self._episode_cache.clear()
        self._rules = loaded
        self._rules_injected = False
        return self._filtered_rules(self._rules)

    def _filtered_rules(
        self, rules: Sequence[MediaSourceRule]
    ) -> tuple[MediaSourceRule, ...]:
        if not self._source_ids:
            return tuple(rules)
        return tuple(rule for rule in rules if rule.id in self._source_ids)

    async def aclose(self) -> None:
        if self._closed:
            return
        self._closed = True
        await self._fetcher.aclose()
        if self._repository is not None:
            await self._repository.aclose()

    # ── source_id 编解码 ────────────────────────────────────

    @staticmethod
    def encode_source_id(rule_id: str, subject_url: str) -> str:
        return f"{rule_id}{SOURCE_ID_SEPARATOR}{subject_url}"

    @staticmethod
    def decode_source_id(source_id: str) -> Optional[tuple[str, str]]:
        """拆出 (规则 id, 条目地址)。形态不符时返回 ``None``。

        对外部传入的 id 一律做白名单校验:规则 id 只认 slug 形态,地址只认
        http(s)。否则 ``../../etc/passwd`` 这种值会被当成地址去 fetch。
        """
        match = _SOURCE_ID_RE.match((source_id or "").strip())
        if not match:
            return None
        return match.group(1), match.group(2)

    # ── 搜索 ────────────────────────────────────────────────

    async def search(self, keyword: str) -> list[SubjectResult]:
        keyword = (keyword or "").strip()
        if not keyword or not self._enabled:
            return []
        try:
            rules = await self.rules()
        except Exception as error:  # noqa: BLE001 - 规则库不可用不该炸搜索
            logger.warning("animeko 规则库不可用: %s", type(error).__name__)
            return []
        playable = [rule for rule in rules if rule.is_playable]
        if not playable:
            return []

        # 每个源一个协程,自带超时;gather 用 return_exceptions 兜住任何漏网异常,
        # 单源失败只会让它自己的结果为空。
        outcomes = await asyncio.gather(
            *(self._search_rule(rule, keyword) for rule in playable),
            return_exceptions=True,
        )

        results: list[SubjectResult] = []
        failed: list[str] = []
        for outcome in outcomes:
            if isinstance(outcome, BaseException):
                failed.append(type(outcome).__name__)
                continue
            if outcome.error:
                failed.append(f"{outcome.rule_id}:{outcome.error}")
            results.extend(self._to_subject_results(outcome))
        if failed:
            logger.info(
                "animeko 搜索 %s:%d/%d 个源不可用(%s)",
                keyword,
                len(failed),
                len(playable),
                ", ".join(failed[:6]),
            )
        return results

    async def _search_rule(self, rule: MediaSourceRule, keyword: str) -> _RuleOutcome:
        started = time.monotonic()
        try:
            engine = self._engine_for(rule)
            if isinstance(engine, RssEngine):
                items = await asyncio.wait_for(
                    engine.search(keyword),
                    timeout=config.ANIMEKO_SOURCE_TIMEOUT_SECONDS,
                )
                return _RuleOutcome(rule.id, [], elapsed_seconds=time.monotonic() - started)
            subjects = await asyncio.wait_for(
                engine.search(keyword), timeout=config.ANIMEKO_SOURCE_TIMEOUT_SECONDS
            )
            return _RuleOutcome(
                rule.id, list(subjects), elapsed_seconds=time.monotonic() - started
            )
        except asyncio.TimeoutError:
            return _RuleOutcome(
                rule.id, [], "timeout", elapsed_seconds=time.monotonic() - started
            )
        except (SourceBlockedError, SourceUnavailableError) as error:
            return _RuleOutcome(
                rule.id, [], error.reason, elapsed_seconds=time.monotonic() - started
            )
        except Exception as error:  # noqa: BLE001 - 单源异常必须隔离
            logger.debug("animeko 源 %s 搜索异常", rule.id, exc_info=error)
            return _RuleOutcome(
                rule.id,
                [],
                type(error).__name__,
                elapsed_seconds=time.monotonic() - started,
            )

    def _to_subject_results(self, outcome: _RuleOutcome) -> list[SubjectResult]:
        rule = self._rule_by_id(outcome.rule_id)
        if rule is None:
            return []
        results: list[SubjectResult] = []
        for subject in outcome.subjects[: config.ANIMEKO_MAX_SUBJECTS_PER_SOURCE]:
            identity = classify_content(
                subject.name, [rule.name, *rule.tags], default_type="anime"
            )
            source_id = self.encode_source_id(rule.id, subject.url)
            self._subject_cache[source_id] = subject
            results.append(
                SubjectResult(
                    source_id=source_id,
                    title=subject.name,
                    cover_url=rule.icon_url,
                    type=identity.type,
                    lang="ja" if identity.type == "anime" else "",
                    year=identity.year,
                    extra={
                        "animeko_source": rule.id,
                        "animeko_source_name": rule.display_name,
                        "animeko_url": subject.url,
                        **identity.extra(),
                    },
                )
            )
        return results

    def _rule_by_id(self, rule_id: str) -> Optional[MediaSourceRule]:
        for rule in self._rules:
            if rule.id == rule_id:
                return rule
        return None

    # ── 详情 ────────────────────────────────────────────────

    async def get_detail(self, source_id: str) -> Optional[SubjectDetail]:
        decoded = self.decode_source_id(source_id)
        if decoded is None or not self._enabled:
            return None
        rule_id, subject_url = decoded
        rule = self._rule_by_id(rule_id) or await self._load_rule(rule_id)
        if rule is None or not rule.is_playable:
            return None
        subject = self._subject_cache.get(source_id) or WebSubject(
            internal_id="", name="", url=subject_url
        )
        try:
            episodes = await self._episodes_for(rule, subject)
        except (SourceBlockedError, SourceUnavailableError) as error:
            logger.info("animeko 详情失败 %s: %s", source_id, error.reason)
            return None
        except asyncio.TimeoutError:
            logger.info("animeko 详情超时 %s", source_id)
            return None
        if not episodes:
            return None

        identity = classify_content(
            subject.name or rule.display_name, [rule.name], default_type="anime"
        )
        # 同一集在多条线路上各出现一次;详情只列一次,线路信息留在 extra 里,
        # 由 get_video_urls 回到该集的所有线路。
        by_number: dict[int, WebEpisode] = {}
        play_urls: dict[str, list[str]] = {}
        for episode in sorted(episodes, key=lambda item: (item.number, item.index)):
            by_number.setdefault(episode.number, episode)
            play_urls.setdefault(str(episode.number), []).append(episode.play_url)
        detail_episodes = [
            EpisodeInfo(
                number=number,
                title=_episode_title(episode),
                source_episode_id=episode.play_url,
            )
            for number, episode in sorted(by_number.items())
        ]
        return SubjectDetail(
            source_id=source_id,
            title=subject.name or rule.display_name,
            cover_url=rule.icon_url,
            summary=rule.description,
            type=identity.type,
            lang="ja" if identity.type == "anime" else "",
            year=identity.year,
            episodes=detail_episodes,
            extra={
                "animeko_source": rule.id,
                "animeko_source_name": rule.display_name,
                "animeko_url": subject_url,
                "animeko_channels": _channels_of(episodes),
                "animeko_episode_play_urls": play_urls,
                **identity.extra(),
            },
        )

    async def _load_rule(self, rule_id: str) -> Optional[MediaSourceRule]:
        """缓存未命中时补一次规则库加载(进程重启后直接按 id 取流的情况)。"""
        try:
            # repository 负责空结果的短负缓存;常规按 id 补载不应强制绕过冷却。
            await self.rules()
        except Exception as error:  # noqa: BLE001
            logger.debug("animeko 规则补载失败: %s", type(error).__name__)
        return self._rule_by_id(rule_id)

    async def _episodes_for(
        self, rule: MediaSourceRule, subject: WebSubject
    ) -> list[WebEpisode]:
        key = f"{rule.id}{SOURCE_ID_SEPARATOR}{subject.url}"
        cached = self._episode_cache.get(key)
        now = time.monotonic()
        if cached is not None and now - cached[0] < config.ANIMEKO_DETAIL_CACHE_SECONDS:
            return cached[1]
        engine = self._engine_for(rule)
        if isinstance(engine, SelectorEngine):
            episodes = await asyncio.wait_for(
                engine.episodes(subject.url),
                timeout=config.ANIMEKO_SOURCE_TIMEOUT_SECONDS,
            )
        elif isinstance(engine, JsonApiEngine):
            episodes = await asyncio.wait_for(
                engine.episodes(subject), timeout=config.ANIMEKO_SOURCE_TIMEOUT_SECONDS
            )
        else:
            episodes = []
        if episodes:
            self._episode_cache[key] = (now, list(episodes))
        return list(episodes)

    # ── 取流 ────────────────────────────────────────────────

    async def get_video_urls(
        self, source_id: str, episode: int = 1
    ) -> list[VideoLine]:
        decoded = self.decode_source_id(source_id)
        if decoded is None or not self._enabled:
            return []
        rule_id, subject_url = decoded
        rule = self._rule_by_id(rule_id) or await self._load_rule(rule_id)
        if rule is None or not rule.is_playable:
            return []
        subject = self._subject_cache.get(source_id) or WebSubject(
            internal_id="", name="", url=subject_url
        )
        wanted = max(1, int(episode or 1))
        try:
            episodes = await self._episodes_for(rule, subject)
        except (SourceBlockedError, SourceUnavailableError):
            return []
        except asyncio.TimeoutError:
            return []
        candidates = [
            item for item in episodes if item.number == wanted
        ]
        if not candidates:
            return []
        # 一次只探前几条线路:每条都要多抓一个播放页,站点限速不会被绕过。
        candidates = _ordered_candidates(rule, candidates)[
            : config.ANIMEKO_PLAY_MAX_CHANNELS
        ]

        engine = self._engine_for(rule)
        results = await asyncio.gather(
            *(self._media_from_episode(rule, engine, subject, item) for item in candidates),
            return_exceptions=True,
        )
        lines: list[VideoLine] = []
        seen: set[str] = set()
        for item, outcome in zip(candidates, results):
            if isinstance(outcome, BaseException) or not outcome:
                continue
            for url in outcome:
                if url in seen:
                    continue
                seen.add(url)
                lines.append(self._build_line(rule, item, url))
        return lines

    async def _media_from_episode(
        self,
        rule: MediaSourceRule,
        engine: SelectorEngine | JsonApiEngine | RssEngine,
        subject: WebSubject,
        episode: WebEpisode,
    ) -> list[str]:
        try:
            if isinstance(engine, SelectorEngine):
                return await asyncio.wait_for(
                    engine.media_urls(episode.play_url),
                    timeout=config.ANIMEKO_PLAY_TIMEOUT_SECONDS,
                )
            if isinstance(engine, JsonApiEngine):
                return await asyncio.wait_for(
                    engine.media_urls(episode, subject),
                    timeout=config.ANIMEKO_PLAY_TIMEOUT_SECONDS,
                )
        except (SourceBlockedError, SourceUnavailableError) as error:
            logger.debug("animeko 取流失败 %s: %s", rule.id, error.reason)
        except asyncio.TimeoutError:
            logger.debug("animeko 取流超时 %s", rule.id)
        return []

    def _build_line(
        self, rule: MediaSourceRule, episode: WebEpisode, url: str
    ) -> VideoLine:
        match_video = rule.selector.match_video if rule.selector else None
        headers: dict[str, str] = {}
        if match_video is not None:
            # Referer 与 Cookie 都要跟着**每一个分片请求**走:CDN 只认这两个头,
            # 播放页取到了地址、分片却 403 的根源就在这里。
            referer = match_video.referer.strip() or episode.play_url
            headers["Referer"] = referer
            cookie = match_video.cookie_header
            if cookie:
                headers["Cookie"] = cookie
            user_agent = match_video.user_agent.strip()
            if user_agent:
                headers["User-Agent"] = user_agent
        headers.setdefault("User-Agent", config.ANIMEKO_USER_AGENT)
        title = episode.channel or f"线路{episode.index + 1}"
        return VideoLine(
            url=url,
            title=title,
            quality=_resolution_of(rule),
            format=media_format_from_url(url),
            headers=headers,
            source_name=f"{rule.id}:{title}",
        )

    # ── 引擎工厂 ────────────────────────────────────────────

    def _engine_for(
        self, rule: MediaSourceRule
    ) -> SelectorEngine | JsonApiEngine | RssEngine:
        engine = self._engines.get(rule.id)
        if engine is not None:
            return engine
        if rule.selector is not None:
            engine = SelectorEngine(rule, self._fetcher)
        elif rule.json_api is not None:
            engine = JsonApiEngine(rule, self._fetcher)
        elif rule.rss is not None:
            engine = RssEngine(rule, self._fetcher)
        else:
            raise SourceUnavailableError(rule.id, rule.id, "规则类型不可执行")
        self._engines[rule.id] = engine
        return engine


def _episode_title(episode: WebEpisode) -> str:
    name = (episode.name or "").strip()
    if episode.channel and name:
        return f"{episode.channel} · {name}"
    return name or f"第{episode.number}集"


def _channels_of(episodes: Sequence[WebEpisode]) -> list[str]:
    channels: list[str] = []
    for episode in episodes:
        channel = (episode.channel or "").strip()
        if channel and channel not in channels:
            channels.append(channel)
    return channels


def _ordered_candidates(
    rule: MediaSourceRule, candidates: Sequence[WebEpisode]
) -> list[WebEpisode]:
    """按规则里的线路档位排序:``tier`` 越小越优先,同档位保持页面顺序。"""
    return sorted(
        candidates,
        key=lambda item: (rule.channel_tier(item.channel), item.index),
    )


def _resolution_of(rule: MediaSourceRule) -> str:
    if rule.selector is not None:
        return rule.selector.default_resolution
    if rule.json_api is not None:
        return rule.json_api.default_resolution
    return ""


def _rules_cache_path() -> Optional[Path]:
    directory = config.ANIMEKO_RULES_CACHE_DIR
    if not directory:
        return None
    return Path(directory) / "animeko_rules_cache.json"


__all__ = ["AnimekoScraper", "SOURCE_ID_SEPARATOR"]
