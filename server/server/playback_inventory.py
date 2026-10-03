"""Read-only registered-source visibility, separate from query admission.

No adapter calls, endpoint URLs, credentials, or source promotion belong here.
The playback service retains its bounded active-source discovery and cache scope.
"""
from __future__ import annotations

import hashlib
import json
import logging
from collections import defaultdict
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
from urllib.parse import urlsplit
import ipaddress

from .aggregator import aggregator
from .playback import public_source_label
from .scrapers.maccms_sites import MACCMS_SITES
from .scrapers.tvbox_adapter import KNOWN_TVBOX_APIS

logger = logging.getLogger(__name__)
_CANDIDATE_PATH = Path(__file__).resolve().parents[1] / "data" / "maccms_candidates.json"


@dataclass(frozen=True)
class RegisteredPlaybackSource:
    family: str
    name: str
    group: str
    status: str
    message: str

    @property
    def inventory_id(self) -> str:
        digest = hashlib.sha256(f"{self.family}:{self.name}".encode()).hexdigest()[:24]
        return f"registered:{digest}"

    @property
    def display_name(self) -> str:
        return public_source_label(self.name)

    def placeholder(self) -> dict:
        return {
            "inventory_source_id": self.inventory_id,
            "inventory_group": self.group,
            "source_inventory_entry": True,
            "source": f"{self.family}:{self.display_name}",
            "source_name": self.display_name,
            "title": self.display_name,
            "url": "",
            "headers": {},
            "quality": "",
            "format": "",
            "available": False,
            "status": "unavailable",
            "diagnostic_status": self.status,
            "queried": False,
            "matched": None,
            "episode_found": None,
            "message": self.message,
        }


@lru_cache(maxsize=1)
def _candidate_names() -> tuple[str, ...]:
    # Candidates are display data only: never parse/use their api, headers,
    # discovered_from, or executable rule fields in a user playback request.
    try:
        if _CANDIDATE_PATH.stat().st_size > 1024 * 1024:
            raise ValueError("oversized_candidate_inventory")
        document = json.loads(_CANDIDATE_PATH.read_text(encoding="utf-8"))
        sites = document.get("sites", [])
        if not isinstance(sites, list) or len(sites) > 512:
            raise ValueError("invalid_candidate_inventory")
        names = []
        for site in sites:
            if not isinstance(site, dict):
                continue
            raw_name = site.get("name")
            if not isinstance(raw_name, str):
                continue
            name = raw_name.strip()
            if (not name or len(name) > 80 or "://" in name
                    or any(ord(char) < 32 for char in name)):
                continue
            names.append(name)
        return tuple(dict.fromkeys(names))
    except (OSError, ValueError, AttributeError) as error:
        logger.warning("Candidate display inventory unavailable (%s)", type(error).__name__)
        return ()


def registered_playback_sources() -> tuple[RegisteredPlaybackSource, ...]:
    providers = {item.provider_id: item for item in aggregator.provider_metadata}
    result = []
    for provider in providers.values():
        if provider.family != "crawler":
            continue
        result.append(RegisteredPlaybackSource(
            "crawler", provider.display_name, "crawler",
            "not_queried" if provider.enabled else "source_disabled",
            "尚无本集查询结果；此行仅展示登记状态。" if provider.enabled
            else "已登记，但此适配器当前未启用，不会发起请求。",
        ))
    maccms = providers.get("aggregate.maccms")
    for site in MACCMS_SITES:
        enabled = bool(maccms and maccms.enabled and site.get("enabled", True))
        tier = site.get("tier", "")
        status = "not_queried" if enabled else (
            "retired" if tier == "retired" else
            "quarantined" if tier == "quarantine" else "source_disabled"
        )
        result.append(RegisteredPlaybackSource(
            "maccms", site["name"], "configured", status,
            "尚无本集查询结果；此行仅展示登记状态。" if enabled
            else "此采集源当前已停用；本集未查询，不代表本次测试失败。",
        ))
    tvbox = providers.get("aggregate.tvbox")
    for site in KNOWN_TVBOX_APIS:
        enabled = bool(tvbox and tvbox.enabled)
        result.append(RegisteredPlaybackSource(
            "tvbox", site["name"], "tvbox_compatibility",
            "not_queried" if enabled else "compatibility_inactive",
            "本集尚未查询。" if enabled else "旧兼容接口未启用；仅保留登记信息。",
        ))
    for name in _candidate_names():
        result.append(RegisteredPlaybackSource(
            "candidate", name, "candidate", "candidate_unadmitted",
            "候选源尚未接入生产查询；没有本集播放验证结果。",
        ))
    return tuple(result)


def local_query_descriptor(
    inventory_id: str,
    *,
    sources: tuple[RegisteredPlaybackSource, ...] | None = None,
) -> dict | None:
    """Only admitted, active public HTTPS MacCMS APIs, never rules or secrets."""
    sources = registered_playback_sources() if sources is None else sources
    source = next((item for item in sources if item.inventory_id == inventory_id), None)
    if source is None or source.family != "maccms" or source.status != "not_queried":
        return None
    site = next((item for item in MACCMS_SITES if item["name"] == source.name), None)
    if site is None or not site.get("enabled", True):
        return None
    endpoint = str(site.get("api") or "")
    try:
        uri = urlsplit(endpoint)
        host = uri.hostname or ""
        if (uri.scheme != "https" or not host or uri.username or uri.password
                or uri.query or uri.fragment or uri.port not in (None, 443)
                or host.lower().rstrip(".") == "localhost"
                or host.lower().rstrip(".").endswith((".localhost", ".local", ".internal"))):
            return None
        try:
            address = ipaddress.ip_address(host)
        except ValueError:
            if "." not in host:
                return None
        else:
            if not address.is_global:
                return None
    except ValueError:
        return None
    return {"inventory_source_id": inventory_id, "name": source.display_name,
            "protocol": "maccms-json", "endpoint": endpoint}


def complete_registered_playback_inventory(
    lines: list[dict],
    *,
    sources: tuple[RegisteredPlaybackSource, ...] | None = None,
) -> list[dict]:
    """Retain every returned route and append non-playable missing-source rows.

    catalog_source is essential: AniCh may return many upstream route labels
    for a single registered adapter. A route is not another registered source.
    """
    sources = registered_playback_sources() if sources is None else sources
    by_id = {source.inventory_id: source for source in sources}
    by_origin = {(source.family, source.display_name): source for source in sources}
    by_name = defaultdict(list)
    for source in sources:
        by_name[source.display_name].append(source)
    local_supported = {source.inventory_id for source in sources
                       if local_query_descriptor(source.inventory_id, sources=sources) is not None}
    represented = set()
    result = []
    for original in lines:
        if not isinstance(original, dict):
            continue
        item = dict(original)
        source = by_id.get(str(item.get("inventory_source_id") or ""))
        if source is None:
            label = str(item.get("source") or "")
            family, _, tail = label.partition(":")
            origin = public_source_label(
                item.get("catalog_source") or item.get("source_name")
                or tail.split(":", 1)[0]
            )
            source = by_origin.get((family, origin))
            if source is None and len(by_name.get(origin, [])) == 1:
                source = by_name[origin][0]
        if source is None and item.get("source_inventory_entry") is True:
            # Unregistered visibility data cannot become an extra playable source.
            continue
        if source is not None:
            if item.get("source_inventory_entry") is True:
                # Even a malformed visibility marker cannot acquire media,
                # headers, or a successful query/playback status on refresh.
                item = source.placeholder()
            else:
                item["inventory_source_id"] = source.inventory_id
                item["inventory_group"] = source.group
            item["client_query_supported"] = source.inventory_id in local_supported
            item["query_location"] = "vps"
            represented.add(source.inventory_id)
        result.append(item)
    for source in sources:
        if source.inventory_id not in represented:
            placeholder = source.placeholder()
            placeholder["client_query_supported"] = source.inventory_id in local_supported
            placeholder["query_location"] = "vps"
            result.append(placeholder)
            represented.add(source.inventory_id)
    return result
