"""Cross-runtime stable identities for persisted and API-visible entities."""

from __future__ import annotations

from hashlib import sha256
from typing import Mapping
from urllib.parse import urlsplit, urlunsplit


STABLE_IDENTITY_VERSION = "v1"

_VOLATILE_PLAYBACK_HEADERS = {
    "connection",
    "content-length",
    "if-range",
    "range",
}
_SENSITIVE_HEADER_NAMES = {
    "authorization",
    "cookie",
    "cookie2",
    "proxy-authorization",
    "x-api-key",
    "x-auth-token",
    "x-access-token",
    "access-token",
    "api-key",
}


def stable_digest(value: str) -> str:
    return sha256(value.encode("utf-8")).hexdigest()


def stable_subject_key(
    source: str,
    identifier: object,
    media_type: str | None = None,
) -> str:
    normalized_source = source.strip().lower()
    normalized_identifier = str(identifier).strip()
    if normalized_source == "bangumi":
        return f"bangumi:{normalized_identifier}"
    source_parts = normalized_source.split(":")
    if source_parts[0] == "bangumi" and len(source_parts) >= 2:
        return f"bangumi:{source_parts[1]}"
    if source_parts[0] == "tmdb":
        raw_type = (
            source_parts[1]
            if len(source_parts) >= 2
            else (media_type or "").strip().lower()
        )
        normalized_type = "tv" if raw_type == "series" else raw_type
        provider_identifier = (
            source_parts[2] if len(source_parts) >= 3 else normalized_identifier
        )
        if normalized_type in {"tv", "movie"} and provider_identifier:
            return f"tmdb:{normalized_type}:{provider_identifier}"
    if source_parts[0] == "archive" and len(source_parts) >= 2:
        return _generic_subject_key("archive", ":".join(source_parts[1:]))
    if source_parts[0] == "m3u-channel" and len(source_parts) >= 3:
        return _generic_subject_key(
            f"m3u-channel:{source_parts[1]}", ":".join(source_parts[2:])
        )
    if source_parts[0] == "cinemeta" and len(source_parts) >= 3:
        return _generic_subject_key(
            f"cinemeta:{source_parts[1]}", ":".join(source_parts[2:])
        )
    return _generic_subject_key(
        normalized_source,
        normalized_identifier,
        media_type,
    )


def _generic_subject_key(
    source: str,
    identifier: str,
    media_type: str | None = None,
) -> str:
    canonical = _frame_identity_parts(
        (
            source,
            identifier,
            (media_type or "").strip().lower(),
        )
    )
    digest = stable_digest(f"subject|{STABLE_IDENTITY_VERSION}|{canonical}")
    return f"subject:{STABLE_IDENTITY_VERSION}:{digest}"


def stable_episode_key(subject_key: str, normalized_number: object) -> str:
    return (
        f"{STABLE_IDENTITY_VERSION}|{subject_key.strip()}|"
        f"episode:{_normalize_number(normalized_number)}"
    )


def stable_playback_line_key(
    provider_id: str,
    episode_key: str,
    uri: str,
    headers: Mapping[str, str] | None = None,
) -> str:
    canonical = _frame_identity_parts(
        (
            provider_id.strip(),
            episode_key.strip(),
            canonical_identity_uri(uri),
            stable_header_fingerprint(headers or {}),
        )
    )
    digest = stable_digest(f"line|{STABLE_IDENTITY_VERSION}|{canonical}")
    return f"line:{STABLE_IDENTITY_VERSION}:{digest}"


def stable_download_task_key(
    subject_key: str,
    episode_key: str,
    provider_id: str = "",
) -> str:
    canonical = _frame_identity_parts(
        (subject_key.strip(), episode_key.strip(), provider_id.strip())
    )
    digest = stable_digest(f"download|{STABLE_IDENTITY_VERSION}|{canonical}")
    return f"download:{STABLE_IDENTITY_VERSION}:{digest}"


def stable_rule_key(
    rule_id: str,
    engine: str,
    source_repository: str = "",
    content_hash: str = "",
) -> str:
    canonical = _frame_identity_parts(
        (
            rule_id.strip(),
            engine.strip().lower(),
            _canonical_uri_or_text(source_repository),
            content_hash.strip().lower(),
        )
    )
    digest = stable_digest(f"rule|{STABLE_IDENTITY_VERSION}|{canonical}")
    return f"rule:{STABLE_IDENTITY_VERSION}:{digest}"


def stable_int63(value: str) -> int:
    result = int(stable_digest(value)[:16], 16) & ((1 << 63) - 1)
    return result or 1


def canonical_identity_uri(value: str) -> str:
    normalized = value.strip()
    parsed = urlsplit(normalized)
    if not parsed.scheme or not parsed.netloc or not parsed.hostname:
        raise ValueError("Identity URI must be absolute")
    scheme = parsed.scheme.lower()
    try:
        port = parsed.port
    except ValueError as error:
        raise ValueError("Identity URI contains an invalid port") from error
    if (scheme == "http" and port == 80) or (scheme == "https" and port == 443):
        port = None
    user_info = ""
    if "@" in parsed.netloc:
        user_info = parsed.netloc.rsplit("@", 1)[0] + "@"
    host = parsed.hostname.lower()
    if ":" in host and not host.startswith("["):
        host = f"[{host}]"
    netloc = f"{user_info}{host}{f':{port}' if port is not None else ''}"
    return urlunsplit((scheme, netloc, parsed.path, parsed.query, ""))


def stable_header_fingerprint(headers: Mapping[str, str]) -> str:
    entries = sorted(
        ((str(name), str(value)) for name, value in headers.items()),
        key=lambda item: (item[0].lower(), item[0], item[1]),
    )
    normalized: dict[str, str] = {}
    for raw_name, raw_value in entries:
        name = raw_name.strip().lower()
        value = raw_value.strip()
        if not name or not value or name in _VOLATILE_PLAYBACK_HEADERS:
            continue
        if name in {"referer", "origin"}:
            value = _canonical_uri_or_text(value)
        elif _is_sensitive_header(name):
            value = f"sha256:{stable_digest(value)}"
        normalized[name] = value
    canonical = _frame_identity_parts(
        f"{name}={normalized[name]}" for name in sorted(normalized)
    )
    return stable_digest(f"headers|{STABLE_IDENTITY_VERSION}|{canonical}")


def _is_sensitive_header(name: str) -> bool:
    return (
        name in _SENSITIVE_HEADER_NAMES
        or "token" in name
        or "secret" in name
        or name.endswith("-key")
    )


def _canonical_uri_or_text(value: str) -> str:
    normalized = value.strip()
    if not normalized:
        return ""
    try:
        return canonical_identity_uri(normalized)
    except ValueError:
        return normalized


def _frame_identity_parts(parts) -> str:
    return "|".join(f"{len(part.encode('utf-8'))}:{part}" for part in parts)


def _normalize_number(value: object) -> str:
    raw = str(value).strip()
    import re

    match = re.fullmatch(r"([+-]?)(\d+)(?:\.(\d+))?", raw)
    if match is None:
        return raw.lower()
    integer = match.group(2).lstrip("0") or "0"
    fraction = (match.group(3) or "").rstrip("0")
    is_zero = integer == "0" and not fraction
    sign = "-" if match.group(1) == "-" and not is_zero else ""
    return f"{sign}{integer}{f'.{fraction}' if fraction else ''}"
