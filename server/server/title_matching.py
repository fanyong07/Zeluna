"""Trusted title-match evidence kept separate from candidate ranking."""

from __future__ import annotations

import re
from dataclasses import dataclass


_KNOWN_MEDIA_TYPES = {"anime", "movie", "tv"}
_CHINESE_DIGITS = {
    "一": 1,
    "二": 2,
    "两": 2,
    "三": 3,
    "四": 4,
    "五": 5,
    "六": 6,
    "七": 7,
    "八": 8,
    "九": 9,
}


#: 衍生内容标记。采集站会把预告、解说、花絮、合集当独立条目收录,标题与
#  正片高度相似(「流浪地球[电影解说]」「权力的游戏前传:龙族」),仅靠包含
#  关系判断会当成正片下发。这类条目播出来不是用户想看的内容,按身份冲突处理。
_DERIVATIVE_MARKS: tuple[str, ...] = (
    "预告", "預告", "先导", "先導", "抢先", "搶先", "花絮", "片花",
    "解说", "解說", "讲解", "吐槽", "盘点", "盤點", "混剪", "剪辑版",
    "reaction", "trailer", "teaser", "preview", "recap",
    "幕后", "幕後", "特辑", "特輯", "宣传", "宣傳", "pv", "cm",
    "合集", "全集解说", "速看", "看点", "看點",
)
#: 前传/衍生剧标记。与正片是不同作品,不能互相顶替。
_SPINOFF_MARKS: tuple[str, ...] = (
    "前传", "前傳", "外传", "外傳", "衍生", "番外", "spin-off", "spinoff",
)


def _derivative_kind(title: str) -> str:
    """→ ""(正片) / "derivative"(预告解说类) / "spinoff"(前传外传)"""
    lowered = (title or "").casefold()
    if any(mark in lowered for mark in _DERIVATIVE_MARKS):
        return "derivative"
    if any(mark in lowered for mark in _SPINOFF_MARKS):
        return "spinoff"
    return ""


@dataclass(frozen=True)
class SourceMatchEvidence:
    """Facts that may authorize correctness-sensitive playback decisions."""

    exact_title: bool = False
    safe_title_variant: bool = False
    matched_alias: str = ""
    expected_season: int | None = None
    candidate_season: int | None = None
    season_conflict: bool = False
    media_type_known: bool = False
    media_type_match: bool = False
    media_type_compatible: bool = False
    year_known: bool = False
    year_compatible: bool = False
    #: 候选是衍生内容(预告/解说/前传…)而请求的是正片
    derivative_conflict: bool = False
    derivative_kind: str = ""

    @property
    def has_explicit_identity_conflict(self) -> bool:
        return (
            self.season_conflict
            or self.derivative_conflict
            or (
                self.media_type_known
                and not (
                    self.media_type_match or self.media_type_compatible
                )
            )
            or (self.year_known and not self.year_compatible)
        )

    @property
    def allows_circuit_recovery(self) -> bool:
        return (
            (self.exact_title or self.safe_title_variant)
            and not self.has_explicit_identity_conflict
        )


@dataclass(frozen=True)
class SourceMatchAnalysis:
    ranking_score: int
    accepted: bool
    evidence: SourceMatchEvidence

    @property
    def playback_eligible(self) -> bool:
        """Allow ranking ambiguity, but never an explicit identity conflict."""
        return self.accepted and not self.evidence.has_explicit_identity_conflict


def _normalized_match_title(value: str) -> str:
    cleaned = (value or "").casefold()
    cleaned = re.sub(r"第\s*\d+\s*[季部期]", "", cleaned)
    cleaned = re.sub(r"\bseason\s*\d+\b", "", cleaned)
    return "".join(char for char in cleaned if char.isalnum())


def _normalized_evidence_title(value: str) -> str:
    return "".join(char for char in (value or "").casefold() if char.isalnum())


def _normalized_media_type(value: str) -> str:
    normalized = (value or "").strip().lower()
    return "tv" if normalized == "series" else normalized


def _media_types_compatible(candidate_type: str, expected_type: str) -> bool:
    if candidate_type == expected_type:
        return True
    return {candidate_type, expected_type} == {"anime", "movie"}


def _is_safe_short_title_variant(candidate: str, target: str) -> bool:
    if len(target) < 3 or not candidate.startswith(target):
        return False
    suffix = candidate[len(target):]
    return bool(
        suffix
        and re.fullmatch(
            r"(?:"
            r"第?[一二三四五六七八九十\d]+[季部期]"
            r"|season\d+|s\d+"
            r"|特别版|完整版|导演剪辑版|国语|粤语|日语|英语"
            r")+",
            suffix,
        )
    )


def _chinese_number(value: str) -> int | None:
    clean = value.strip()
    if clean.isdigit():
        return int(clean)
    if clean == "十":
        return 10
    if "十" in clean:
        tens, ones = clean.split("十", 1)
        tens_value = _CHINESE_DIGITS.get(tens, 1 if not tens else 0)
        ones_value = _CHINESE_DIGITS.get(ones, 0 if not ones else -1)
        if tens_value > 0 and ones_value >= 0:
            return tens_value * 10 + ones_value
        return None
    return _CHINESE_DIGITS.get(clean)


def _season_number(value: str) -> int | None:
    match = re.search(
        r"(?:第\s*([一二三四五六七八九十两\d]+)\s*季"
        r"|\bseason\s*0*(\d+)\b"
        r"|\bs\s*0*(\d+)\b)",
        value or "",
        flags=re.IGNORECASE,
    )
    if match is None:
        return None
    raw = next((group for group in match.groups() if group is not None), "")
    return _chinese_number(raw)


def _title_evidence(candidate: str, aliases: list[str]) -> tuple[str, bool, bool]:
    normalized_candidate = _normalized_evidence_title(candidate)
    best: tuple[int, str, bool, bool] = (0, "", False, False)
    for alias in aliases:
        clean_alias = str(alias or "").strip()
        normalized_alias = _normalized_evidence_title(clean_alias)
        if not normalized_alias:
            continue
        exact = normalized_candidate == normalized_alias
        safe_variant = _is_safe_short_title_variant(
            normalized_candidate,
            normalized_alias,
        )
        related = (
            min(len(normalized_candidate), len(normalized_alias)) >= 4
            and (
                normalized_candidate in normalized_alias
                or normalized_alias in normalized_candidate
            )
        )
        rank = 3 if exact else 2 if safe_variant else 1 if related else 0
        if rank > best[0]:
            best = (rank, clean_alias, exact, safe_variant)
    return best[1], best[2], best[3]


def _ranking_score(
    candidate: str,
    aliases: list[str],
    *,
    candidate_type: str,
    expected_type: str,
    candidate_year: int,
    expected_year: int,
) -> int:
    normalized = _normalized_match_title(candidate)
    targets = [_normalized_match_title(alias) for alias in aliases]
    season_specific_bases: dict[str, str] = {}
    for target in targets:
        match = re.search(
            r"(?:第?[一二三四五六七八九十百两\d]+季|season\d+|s\d+)$",
            target,
        )
        if match and target[:match.start()]:
            season_specific_bases[target] = target[:match.start()]
    season_bases = set(season_specific_bases.values())
    score = 0
    for target in targets:
        if not target:
            continue
        if normalized == season_specific_bases.get(target):
            continue
        if target in season_bases and (
            normalized == target or normalized.startswith(target)
        ):
            continue
        if normalized == target:
            score = max(score, 100)
        elif min(len(normalized), len(target)) >= 4 and (
            normalized in target or target in normalized
        ):
            score = max(score, 72)
        elif _is_safe_short_title_variant(normalized, target):
            score = max(score, 68)

    normalized_candidate_type = _normalized_media_type(candidate_type)
    normalized_expected_type = _normalized_media_type(expected_type)
    if (
        normalized_candidate_type in _KNOWN_MEDIA_TYPES
        and normalized_expected_type in _KNOWN_MEDIA_TYPES
    ):
        if normalized_candidate_type == normalized_expected_type:
            score += 8
        elif not _media_types_compatible(
            normalized_candidate_type,
            normalized_expected_type,
        ):
            score -= 25
    if expected_year and candidate_year:
        distance = abs(expected_year - candidate_year)
        score += 10 if distance == 0 else (4 if distance == 1 else -12)
    return score


def analyze_source_match(
    candidate: str,
    aliases: list[str],
    *,
    candidate_type: str,
    expected_type: str,
    candidate_year: int,
    expected_year: int,
) -> SourceMatchAnalysis:
    """Return ranking and correctness evidence through one pure interface."""

    ranking_score = _ranking_score(
        candidate,
        aliases,
        candidate_type=candidate_type,
        expected_type=expected_type,
        candidate_year=candidate_year,
        expected_year=expected_year,
    )
    matched_alias, exact_title, safe_title_variant = _title_evidence(
        candidate,
        aliases,
    )
    expected_season = next(
        (
            season
            for alias in aliases
            if (season := _season_number(str(alias or ""))) is not None
        ),
        None,
    )
    candidate_season = _season_number(candidate)
    normalized_candidate_type = _normalized_media_type(candidate_type)
    normalized_expected_type = _normalized_media_type(expected_type)
    media_type_known = (
        normalized_candidate_type in _KNOWN_MEDIA_TYPES
        and normalized_expected_type in _KNOWN_MEDIA_TYPES
    )
    year_known = candidate_year > 0 and expected_year > 0
    # 衍生内容判据:候选带预告/解说/前传标记而请求的别名都不带,说明用户要的
    # 是正片而候选不是。两边都带则是用户本就在找衍生内容,不算冲突。
    candidate_derivative = _derivative_kind(candidate)
    wanted_derivative = any(_derivative_kind(str(alias or "")) for alias in aliases)
    evidence = SourceMatchEvidence(
        exact_title=exact_title,
        safe_title_variant=safe_title_variant,
        matched_alias=matched_alias,
        derivative_kind=candidate_derivative,
        derivative_conflict=bool(candidate_derivative) and not wanted_derivative,
        expected_season=expected_season,
        candidate_season=candidate_season,
        season_conflict=(
            expected_season is not None
            and candidate_season is not None
            and expected_season != candidate_season
        ),
        media_type_known=media_type_known,
        media_type_match=(
            media_type_known
            and normalized_candidate_type == normalized_expected_type
        ),
        media_type_compatible=(
            media_type_known
            and _media_types_compatible(
                normalized_candidate_type,
                normalized_expected_type,
            )
        ),
        year_known=year_known,
        year_compatible=(
            year_known
            and (
                abs(candidate_year - expected_year) <= 1
                # 双方季号明确且一致时年份不再否决:各库年份基准不同(制作年
                # vs 播出年),多季作品的季播出年可以相差数年,实测因此误杀过
                # 正确的季。仅标题相同不算 —— 同名重制片是另一部作品,那种
                # 情况年份必须继续有否决权。
                or (
                    expected_season is not None
                    and candidate_season is not None
                    and candidate_season == expected_season
                )
            )
        ),
    )
    # 衍生内容即便标题分很高也不该顶替正片:扣到接受线以下,
    # 让它既不被选中播放,也不会挤占正片的排名位置。
    if evidence.derivative_conflict:
        penalty = 45 if candidate_derivative == "derivative" else 30
        ranking_score = max(0, ranking_score - penalty)
    return SourceMatchAnalysis(
        ranking_score=ranking_score,
        accepted=ranking_score >= 65,
        evidence=evidence,
    )
