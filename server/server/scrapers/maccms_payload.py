"""Parse bounded MacCMS JSON/XML without executing entities or trusting HTML."""

from __future__ import annotations

import json
import socket
import ssl

import httpx
from lxml import etree

MAX_CATALOG_BYTES = 4 * 1024 * 1024


class CatalogSearchUnsupported(ValueError):
    """The upstream explicitly disables keyword search; not an empty catalog."""


def catalog_error_category(error: BaseException) -> str:
    if isinstance(error, CatalogSearchUnsupported):
        return "search_unsupported"
    chain = []
    seen = set()
    current = error
    while current is not None and id(current) not in seen:
        seen.add(id(current))
        chain.append(current)
        current = current.__cause__ or current.__context__
    if any(isinstance(item, socket.gaierror) for item in chain):
        return "dns_failure"
    if any(isinstance(item, ssl.SSLError) for item in chain):
        return "tls_error"
    if isinstance(error, httpx.ConnectError):
        message = str(error).lower()
        if "certificate" in message or "ssl" in message:
            return "tls_error"
        if any(
            word in message for word in ("getaddrinfo", "name or service", "nodename")
        ):
            return "dns_failure"
        return "connect_timeout"
    if isinstance(error, httpx.ConnectTimeout):
        return "connect_timeout"
    if isinstance(error, (httpx.TimeoutException, TimeoutError)):
        return "read_timeout"
    if isinstance(error, (ValueError, KeyError, TypeError)):
        return "parser_mismatch"
    return "unknown_exception"


def _search_disabled_notice(text: str) -> bool:
    return any(
        marker in text.casefold()
        for marker in (
            "暂不支持搜索",
            "不支持关键字搜索",
            "禁止关键词搜索",
            "forbids keyword search",
            "keyword search is disabled",
        )
    )


def parse_catalog_response(response: httpx.Response) -> dict:
    body = response.content
    if len(body) > MAX_CATALOG_BYTES:
        raise ValueError("catalog_response_too_large")
    if len(body) < 4096 and _search_disabled_notice(
        body.decode("utf-8", errors="replace")
    ):
        raise CatalogSearchUnsupported("upstream_keyword_search_disabled")
    try:
        data = json.loads(body)
    except (ValueError, UnicodeDecodeError):
        data = None
    else:
        if isinstance(data, dict) and _search_disabled_notice(str(data.get("msg", ""))):
            raise CatalogSearchUnsupported("upstream_keyword_search_disabled")
        items = data.get("list") if isinstance(data, dict) else data
        if not isinstance(items, list):
            raise ValueError("catalog_list_missing")
        if not all(isinstance(item, dict) for item in items):
            raise ValueError("catalog_invalid_item")
        return {"list": items}

    # Reject DTDs/entities even with UTF-16/32 input before parsing. The parser
    # also prohibits network and entity expansion as defense in depth.
    compact = body.replace(b"\x00", b"").lower()
    if b"<!doctype" in compact or b"<!entity" in compact:
        raise ValueError("catalog_xml_dtd_disallowed")
    parser = etree.XMLParser(
        resolve_entities=False,
        load_dtd=False,
        no_network=True,
        recover=False,
        huge_tree=False,
    )
    try:
        root = etree.fromstring(body, parser=parser)
    except etree.XMLSyntaxError as error:
        raise ValueError("catalog_not_json_or_xml") from error
    if root.tag != "rss" or root.find("list") is None:
        raise ValueError("catalog_xml_schema_mismatch")
    fields = {
        "id": "vod_id",
        "name": "vod_name",
        "type": "type_name",
        "year": "vod_year",
        "pic": "vod_pic",
        "des": "vod_content",
        "note": "vod_remarks",
        "lang": "vod_lang",
        "area": "vod_area",
    }
    items = []
    for node in root.findall("./list/video"):
        item = {target: node.findtext(source, "") for source, target in fields.items()}
        groups = node.findall("./dl/dd")
        item["vod_play_from"] = "$$$".join(group.get("flag", "") for group in groups)
        item["vod_play_url"] = "$$$".join(group.text or "" for group in groups)
        items.append(item)
    return {"list": items}
