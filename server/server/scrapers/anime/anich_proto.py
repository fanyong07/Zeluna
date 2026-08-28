"""AniCh 聚合源协议解码(纯函数,零 I/O)。

上游 wire 形态(逆向自 AniCh v1.5.x,线上实测见 D:\\下载\\AniCh-source-kit):
  * /bangumi/search|latest|list、/bangumi/episodes、/vod 均返回 protobuf;
  * /vod 的响应体可能再包一层 ``[10,243,...]`` JSON 字节数组外壳;
  * vod_item_.url 是变体 base64:原串在索引 3 处被插入一个垃圾字符。

本模块只做字节→dict;不做 HTTP,也不做任何业务判定。
风格与 ``protobuf_encoder.py`` 一致:手写 varint,不引入 google.protobuf 运行时依赖。
"""

from __future__ import annotations

import base64
import json
import struct
from typing import Iterator

_WIRE_VARINT = 0
_WIRE_FIXED64 = 1
_WIRE_LEN = 2
_WIRE_FIXED32 = 5


def read_varint(data: bytes, pos: int) -> tuple[int, int]:
    """Read one base-128 varint; return ``(value, next_pos)``."""
    result = 0
    shift = 0
    while True:
        if pos >= len(data):
            raise ValueError("truncated varint")
        byte = data[pos]
        pos += 1
        result |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return result, pos
        shift += 7
        if shift > 63:
            raise ValueError("varint too long")


def iter_fields(data: bytes) -> Iterator[tuple[int, int, object]]:
    """Yield ``(field_number, wire_type, value)`` for each protobuf field.

    Value is an ``int`` for varint fields and ``bytes`` otherwise.
    Unknown fields are skipped without failing the whole message.
    """
    pos = 0
    length = len(data)
    while pos < length:
        key, pos = read_varint(data, pos)
        field_number = key >> 3
        wire_type = key & 7
        if field_number <= 0:
            raise ValueError(f"invalid field number {field_number}")
        if wire_type == _WIRE_VARINT:
            value, pos = read_varint(data, pos)
        elif wire_type == _WIRE_FIXED64:
            if pos + 8 > length:
                raise ValueError("truncated fixed64")
            value = data[pos : pos + 8]
            pos += 8
        elif wire_type == _WIRE_LEN:
            size, pos = read_varint(data, pos)
            if pos + size > length:
                raise ValueError("truncated length-delimited field")
            value = data[pos : pos + size]
            pos += size
        elif wire_type == _WIRE_FIXED32:
            if pos + 4 > length:
                raise ValueError("truncated fixed32")
            value = data[pos : pos + 4]
            pos += 4
        else:
            raise ValueError(f"unsupported wire type {wire_type}")
        yield field_number, wire_type, value


def _text(value: object) -> str:
    return value.decode("utf-8", "replace") if isinstance(value, bytes) else ""


def _fixed64_double(value: object) -> float:
    if not isinstance(value, bytes) or len(value) != 8:
        return 0.0
    return struct.unpack("<d", value)[0]


# ── bangumi_list_ { repeated bangumi_list_item_ data = 1; } ──
def decode_bangumi_list(payload: bytes) -> list[dict]:
    """bangumi_list_item_: id=1,title=2,episode=3,episodesTotal=4,
    status=5,date=6(double),image=7,tagline=8"""
    items: list[dict] = []
    for field_number, wire_type, value in iter_fields(payload):
        if field_number != 1 or wire_type != _WIRE_LEN or not isinstance(value, bytes):
            continue
        entry = {
            "id": None,
            "title": "",
            "episode": 0,
            "episodes_total": 0,
            "status": "",
            "date": 0.0,
            "image": "",
            "tagline": "",
        }
        for fno, wtype, inner in iter_fields(value):
            if fno == 1 and wtype == _WIRE_VARINT:
                entry["id"] = int(inner)
            elif fno == 2 and wtype == _WIRE_LEN:
                entry["title"] = _text(inner)
            elif fno == 3 and wtype == _WIRE_VARINT:
                entry["episode"] = int(inner)
            elif fno == 4 and wtype == _WIRE_VARINT:
                entry["episodes_total"] = int(inner)
            elif fno == 5 and wtype == _WIRE_LEN:
                entry["status"] = _text(inner)
            elif fno == 6 and wtype == _WIRE_FIXED64:
                entry["date"] = _fixed64_double(inner)
            elif fno == 7 and wtype == _WIRE_LEN:
                entry["image"] = _text(inner)
            elif fno == 8 and wtype == _WIRE_LEN:
                entry["tagline"] = _text(inner)
        items.append(entry)
    return items


# ── bangumi_episodes_ { repeated bangumi_episodes_data_ data = 1; } ──
def decode_sites(payload: bytes) -> dict[str, str]:
    site = {"site": "", "id": ""}
    for fno, _wire, value in iter_fields(payload):
        if fno == 1 and isinstance(value, bytes):
            site["site"] = _text(value)
        elif fno == 2 and isinstance(value, bytes):
            site["id"] = _text(value)
    return site


def decode_episodes(payload: bytes) -> list[dict]:
    """bangumi_episodes_data_: status=1(bool),sort=2,airdate=3(double),
    duration=4,sites=5(repeated),rating=6(repeated),image=7,title=8,
    overview=9"""
    episodes: list[dict] = []
    for field_number, wire_type, value in iter_fields(payload):
        if field_number != 1 or wire_type != _WIRE_LEN or not isinstance(value, bytes):
            continue
        entry = {
            "status": False,
            "sort": 0,
            "airdate": 0.0,
            "duration": 0,
            "sites": [],
            "image": "",
            "title": "",
            "overview": "",
        }
        for fno, wtype, inner in iter_fields(value):
            if fno == 1 and wtype == _WIRE_VARINT:
                entry["status"] = bool(inner)
            elif fno == 2 and wtype == _WIRE_VARINT:
                entry["sort"] = int(inner)
            elif fno == 3 and wtype == _WIRE_FIXED64:
                entry["airdate"] = _fixed64_double(inner)
            elif fno == 4 and wtype == _WIRE_VARINT:
                entry["duration"] = int(inner)
            elif fno == 5 and wtype == _WIRE_LEN and isinstance(inner, bytes):
                try:
                    entry["sites"].append(decode_sites(inner))
                except ValueError:
                    continue
            elif fno == 7 and wtype == _WIRE_LEN:
                entry["image"] = _text(inner)
            elif fno == 8 and wtype == _WIRE_LEN:
                entry["title"] = _text(inner)
            elif fno == 9 and wtype == _WIRE_LEN:
                entry["overview"] = _text(inner)
        episodes.append(entry)
    return episodes


# ── vod_ { repeated vod_item_ data = 1; } ──
def decode_vod(payload: bytes) -> list[dict]:
    """vod_item_: url=1(raw variant base64),sort=2,type=3,caption=4.

    URL 字段保持原样返回(``url_raw``);变体解码由调用方决定是否套用。
    """
    items: list[dict] = []
    for field_number, wire_type, value in iter_fields(payload):
        if field_number != 1 or wire_type != _WIRE_LEN or not isinstance(value, bytes):
            continue
        item = {"url_raw": "", "sort": 0, "type": "", "caption": ""}
        for fno, _wtype, inner in iter_fields(value):
            if fno == 1 and isinstance(inner, bytes):
                item["url_raw"] = _text(inner)
            elif fno == 2 and isinstance(inner, int):
                item["sort"] = inner
            elif fno == 3 and isinstance(inner, bytes):
                item["type"] = _text(inner)
            elif fno == 4 and isinstance(inner, bytes):
                item["caption"] = _text(inner)
        items.append(item)
    return items


def unwrap_vod_body(raw: bytes) -> bytes:
    """v1.5.x 会把 /vod 响应包成 ``[10,243,1,...]`` 字节数组外壳。

    数组外壳与裸 protobuf 两态都接受;数组元素必须都在 0..255 内。
    """
    stripped = (raw or b"").lstrip()
    if not stripped.startswith(b"["):
        return raw or b""
    try:
        values = json.loads(stripped.decode("utf-8", "strict"))
    except (UnicodeDecodeError, ValueError) as error:
        raise ValueError(f"invalid vod wrapper: {error}") from error
    if (
        not isinstance(values, list)
        or not values
        or not all(isinstance(item, int) and 0 <= item <= 255 for item in values)
    ):
        raise ValueError("invalid vod wrapper payload")
    return bytes(values)


def decode_variant_base64(text: str) -> str:
    """还原 ``原串[:3] + 垃圾字符 + 原串[3:]`` 式变体 base64。

    解不出合法 UTF-8 时抛 ``ValueError``,由调用方按脏数据丢弃。
    """
    cleaned = (text or "").strip()
    if len(cleaned) < 4:
        raise ValueError("variant base64 payload too short")
    cut = cleaned[:3] + cleaned[4:]
    padded = cut + "=" * (-len(cut) % 4)
    decoded = base64.b64decode(padded, validate=True)
    return decoded.decode("utf-8")
