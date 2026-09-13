"""Conservative per-title content identity for independent HTML origins.

Search capability is not a claim about a site's inventory. Only item-scoped
categories/metadata (or explicit edition markers) may expand a title into the
movie/series catalog; navigation menus, synopses and episode counts may not.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from collections.abc import Iterable

from bs4 import BeautifulSoup, Tag

from .base import SubjectResult
from .maccms import media_type_from_name, year_from_value

_ANIMATION = re.compile(
    r"动漫|動畫|动画|動漫|番剧|番劇|日番|新番|旧番|美漫|国漫|anime", re.I
)
_MOVIE_EDITION = re.compile(
    r"剧场版|劇場版|电影版|電影版|大电影|大電影|\bthe\s+movie\b", re.I
)
_TV_ANIMATION = re.compile(
    r"TV\s*动[画漫]|TV\s*動畫|电视动画|電視動畫|番剧|番劇|新番|旧番|日番", re.I
)
_LIVE_ACTION = re.compile(r"真人|特摄|特攝|live[ -]?action", re.I)
_CATEGORY_LABEL = re.compile(
    r"^(?:类型|類型|分类|分類|类别|類別|频道|頻道)\s*[:：]\s*(.+)"
)
_YEAR_LABEL = re.compile(r"^(?:年份|年代|上映|首播)\s*[:：]\s*(.+)")
_DETAIL_ROOT = ".detail-info, .stui-content__detail, .myui-content__detail, .module-info-main, .detail-right"


@dataclass(frozen=True)
class ContentIdentity:
    type: str
    year: int = 0
    media_format: str = ""
    animation: bool | None = None
    evidence: str = "default"

    def extra(self) -> dict:
        return {
            "content_identity": {
                "format": self.media_format,
                "animation": self.animation,
                "evidence": self.evidence,
            }
        }


def classify_content(
    title: str,
    categories: Iterable[str] = (),
    *,
    year: object = 0,
    default_type: str = "anime",
) -> ContentIdentity:
    # These inputs are categories, not free text or a whole HTML document.
    labels = [
        str(value).strip() for value in categories if 0 < len(str(value).strip()) <= 60
    ]
    if any(re.search(r"解说|解說|预告|預告|花絮", value) for value in labels):
        return ContentIdentity("unknown", year_from_value(year), evidence="conflict")
    text = " / ".join(labels)
    animation = True if _ANIMATION.search(text) else None
    mapped = {media_type_from_name(value) for value in labels}
    movie = (
        any(
            _MOVIE_EDITION.search(value) or re.search(r"电影|電影|movie", value, re.I)
            for value in labels
        )
        or "movie" in mapped
    )
    series = "tv" in mapped or (
        not movie and any(_LIVE_ACTION.search(value) for value in labels)
    )
    if _LIVE_ACTION.search(text) or re.search(
        r"真人版|真人电影|真人電影|\blive[ -]action\b", title, re.I
    ):
        animation = False
    if series and movie:
        return ContentIdentity("unknown", year_from_value(year), evidence="conflict")
    if movie:
        if animation is None and any(re.search(r"剧场版|劇場版", c) for c in labels):
            animation = True
        return ContentIdentity(
            "movie", year_from_value(year), "movie", animation, "category"
        )
    if series and animation is not True:
        return ContentIdentity("tv", year_from_value(year), "series", False, "category")
    if _MOVIE_EDITION.search(title):
        return ContentIdentity(
            "movie", year_from_value(year), "movie", animation, "title"
        )
    if animation is True or "anime" in mapped:
        media_format = "series" if _TV_ANIMATION.search(text) or series else ""
        return ContentIdentity(
            "anime", year_from_value(year), media_format, animation, "category"
        )
    return ContentIdentity(default_type, year_from_value(year), animation=animation)


def identity_from_html(
    root: BeautifulSoup | Tag | None,
    title: str,
    *,
    detail: bool = False,
    default_type: str = "anime",
) -> ContentIdentity:
    if root is None:
        return classify_content(title, default_type=default_type)
    categories: list[str] = []
    years: list[str] = []
    # Only recognized media fields, never description/keywords or update times.
    for meta in root.select("meta[property], meta[name]"):
        key = str(meta.get("property") or meta.get("name") or "").lower()
        value = str(meta.get("content") or "")
        if key in {"og:video:class", "og:video:type", "og:type"}:
            categories.append(value)
        elif key in {"og:video:release_date", "og:video:year"}:
            years.append(value)
    scope = root.select_one(_DETAIL_ROOT) if detail else root
    if scope is not None:
        for item in scope.select(
            '[itemprop="genre"], [data-content-type], .module-info-tag a, '
            ".module-info-tag-link, .detail-right__tags a"
        ):
            categories.append(
                str(
                    item.get("data-content-type")
                    or item.get("content")
                    or item.get_text(" ", strip=True)
                )
            )
        for item in scope.select(
            "p, li, .slide-info, .module-info-item, .detail-right__info"
        ):
            text = item.get_text(" ", strip=True)
            if len(text) > 160:
                continue
            match = _CATEGORY_LABEL.match(text)
            if match:
                categories.extend(re.split(r"[/|、,，\s]+", match.group(1)))
            match = _YEAR_LABEL.match(text)
            if match:
                years.append(match.group(1))
        for item in scope.select(
            '.slide-info-remarks, [itemprop="datePublished"], [data-year]'
        ):
            value = str(
                item.get("content")
                or item.get("data-year")
                or item.get_text(" ", strip=True)
            )
            if re.fullmatch(r"(?:18|19|20|21)\d{2}(?:-\d{2}-\d{2})?", value):
                years.append(value)
    if detail and not any(
        classify_content("", [c], default_type="unknown").evidence == "category"
        for c in categories
    ):
        # A selected category identifies THIS detail. Unselected menu items never do.
        selected = [
            item.get_text(" ", strip=True)
            for item in root.select(
                ".head-nav a.current, .stui-header__menu li.active a"
            )
        ]
        categories.extend(selected)
    return classify_content(
        title,
        categories,
        year=next((y for y in years if year_from_value(y)), 0),
        default_type=default_type,
    )


def needs_content_detail(
    result: SubjectResult, expected_type: str, *, expected_year: int = 0
) -> bool:
    identity = result.extra.get("content_identity")
    if not isinstance(identity, dict):
        return False
    return (
        bool(expected_year and not result.year)
        or identity.get("evidence") in {"default", "conflict"}
        or (expected_type == "movie" and identity.get("format") != "movie")
    )


def content_matches_request(result: SubjectResult, expected_type: str) -> bool:
    """Keep legacy providers compatible, but never promote a site's default type."""
    identity = result.extra.get("content_identity")
    if not isinstance(identity, dict):
        return True
    if identity.get("evidence") == "conflict":
        return False
    if expected_type == "movie":
        return result.type == "movie" and identity.get("format") == "movie"
    if expected_type in {"tv", "series"}:
        return result.type == "tv"
    if expected_type == "anime":
        return identity.get("animation") is not False and (
            result.type == "anime"
            or (result.type == "movie" and identity.get("animation") is not False)
        )
    return True


_MOVIE_VERSION_LABEL = re.compile(
    r"(?:HD|BD|SD|(?:480|720|1080|2160)[PI]?|[248]K|蓝光|藍光|高清|超清|正片|"
    r"国语|國語|粤语|粵語|日语|日語|英语|英語|中字|字幕|简体|簡體|繁体|繁體|"
    r"普通话|普通話|双语|雙語|完整版|修复版|修復版|国粤|國粵|中英|韩语|韓語|\s|[-_.（）()])+",
    re.I,
)


def movie_version_episode_number(
    identity: ContentIdentity, label: str, fallback: int
) -> int:
    """Full-film language/quality variants are alternate routes, not episodes 4/1080."""
    if identity.media_format == "movie" and _MOVIE_VERSION_LABEL.fullmatch(
        label.strip()
    ):
        return 1
    return fallback
