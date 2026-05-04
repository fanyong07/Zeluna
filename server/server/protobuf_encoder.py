"""
简易 Protobuf 编码器 — 兼容 AniCh 客户端期望的二进制格式。

AniCh 使用自定的 protobuf schema，字段编号与定义参见各 .proto 文件。
这里手动实现编码以避免编译步骤。
"""

import struct
from typing import Any


def _varint(value: int) -> bytes:
    """编码为 protobuf varint."""
    result = bytearray()
    while value > 0x7F:
        result.append((value & 0x7F) | 0x80)
        value >>= 7
    result.append(value & 0x7F)
    return bytes(result)


def _field_bytes(field_number: int, data: bytes) -> bytes:
    """编码一个 length-delimited 字段."""
    tag = (field_number << 3) | 2  # wire type 2
    return _varint(tag) + _varint(len(data)) + data


def _field_varint(field_number: int, value: int) -> bytes:
    """编码一个 varint 字段."""
    tag = (field_number << 3) | 0  # wire type 0
    return _varint(tag) + _varint(value)


def _field_bool(field_number: int, value: bool) -> bytes:
    """编码一个 bool 字段 (varint wire type)."""
    tag = (field_number << 3) | 0
    return _varint(tag) + _varint(1 if value else 0)


def _field_double(field_number: int, value: float) -> bytes:
    """编码一个 double 字段 (fixed64)."""
    tag = (field_number << 3) | 1
    return _varint(tag) + struct.pack("<d", value)


def _string_field(field_number: int, value: str) -> bytes:
    return _field_bytes(field_number, value.encode("utf-8"))


# ── bangumi.proto ──────────────────────────────────────────

def encode_vod_item(item: dict) -> bytes:
    """vod_item_: url(1), sort(2), type(3), caption(4)"""
    result = bytearray()
    if url := item.get("url"):
        result += _string_field(1, url)
    if sort := item.get("sort"):
        result += _field_varint(2, sort)
    if t := item.get("type"):
        result += _string_field(3, t)
    if caption := item.get("caption"):
        result += _string_field(4, caption)
    return bytes(result)


def encode_episodes_list(items: list[dict]) -> bytes:
    """episodes_ body 字段:
       name(1), episodes(repeated 2 -> vod_item_), count(4), skip(5)
    """
    result = bytearray()
    result += _field_varint(4, len(items))  # count
    result += _field_varint(5, 0)            # skip
    for item in items:
        encoded = encode_vod_item(item)
        result += _field_bytes(2, encoded)   # episodes (repeated)
    return bytes(result)


def encode_related_list(items: list[dict]) -> bytes:
    """related_ body(2) 包含 repeated bangumi_item_:
       id(1), title(2), cover(3), status(4), type(5)
    """
    result = bytearray()
    for item in items:
        inner = bytearray()
        if v := item.get("id"):
            inner += _field_varint(1, v)
        if v := item.get("title"):
            inner += _string_field(2, v)
        if v := item.get("cover_url") or item.get("cover"):
            inner += _string_field(3, v)
        if v := item.get("status"):
            inner += _field_varint(4, v)
        if v := item.get("type"):
            inner += _string_field(5, v)
        result += _field_bytes(2, bytes(inner))
    return bytes(result)


def encode_characters_list(items: list[dict]) -> bytes:
    """characters_ body(2):
       id(1), name(2), role(3), avatar(4), summary(5)
    """
    result = bytearray()
    for item in items:
        inner = bytearray()
        if v := item.get("id"):
            inner += _field_varint(1, int(v))
        if v := item.get("name"):
            inner += _string_field(2, v)
        if v := item.get("role"):
            inner += _string_field(3, v)
        if v := item.get("avatar_url") or item.get("avatar"):
            inner += _string_field(4, v)
        if v := item.get("summary"):
            inner += _string_field(5, v)
        result += _field_bytes(2, bytes(inner))
    return bytes(result)


def encode_persons_list(items: list[dict]) -> bytes:
    """persons_ body(2):
       id(1), name(2), role(3), avatar(4), summary(5)
    """
    result = bytearray()
    for item in items:
        inner = bytearray()
        if v := item.get("id"):
            inner += _field_varint(1, int(v))
        if v := item.get("name"):
            inner += _string_field(2, v)
        if v := item.get("role"):
            inner += _string_field(3, v)
        if v := item.get("avatar_url") or item.get("avatar"):
            inner += _string_field(4, v)
        if v := item.get("summary"):
            inner += _string_field(5, v)
        result += _field_bytes(2, bytes(inner))
    return bytes(result)


def encode_bangumi_list(items: list[dict]) -> bytes:
    """bangumi_list body:
       id(1), title(2), status(3), type(4), lang(5), cover(6), summary(7),
       year(8), count(9), tags(10), genres(11)
    """
    result = bytearray()
    for item in items:
        inner = bytearray()
        if v := item.get("id"):
            inner += _field_varint(1, int(v))
        if v := item.get("title"):
            inner += _string_field(2, v)
        if (v := item.get("status")) is not None:
            inner += _field_varint(3, int(v))
        if v := item.get("type"):
            inner += _string_field(4, v)
        if v := item.get("lang"):
            inner += _string_field(5, v)
        if v := item.get("cover_url") or item.get("cover"):
            inner += _string_field(6, v)
        if v := item.get("summary"):
            inner += _string_field(7, v)
        if v := item.get("year"):
            inner += _field_varint(8, int(v))
        if v := item.get("episode_count") or item.get("count"):
            inner += _field_varint(9, int(v))
        result += _field_bytes(2, bytes(inner))
    return bytes(result)


# ── list.proto ─────────────────────────────────────────────

def encode_thread_list(items: list[dict]) -> bytes:
    """thread_list_data_: ai(1), id(2), nsfw(3), title(4), image(5),
       count(6), color(7), width(8), height(9)
       body 字段: 2
    """
    result = bytearray()
    for item in items:
        inner = bytearray()
        if v := item.get("ai"):
            inner += _field_bool(1, bool(v))
        if v := item.get("id"):
            inner += _field_varint(2, int(v))
        if v := item.get("nsfw"):
            inner += _field_bool(3, bool(v))
        if v := item.get("title"):
            inner += _string_field(4, v)
        if v := item.get("image"):
            inner += _string_field(5, v)
        if v := item.get("count"):
            inner += _field_varint(6, int(v))
        if v := item.get("color"):
            inner += _string_field(7, v)
        if v := item.get("width"):
            inner += _field_varint(8, int(v))
        if v := item.get("height"):
            inner += _field_varint(9, int(v))
        result += _field_bytes(2, bytes(inner))  # body repeated
    return bytes(result)


# ── danmaku.proto ──────────────────────────────────────────

def encode_danmaku_list(items: list[dict]) -> bytes:
    """data_: id(1), color(2), date(3), text(4), t(5), time(6), type(7), from(8)
       body 字段: 2
    """
    result = bytearray()
    for item in items:
        inner = bytearray()
        if v := item.get("id"):
            inner += _string_field(1, str(v))
        if v := item.get("color"):
            inner += _string_field(2, v)
        if v := item.get("date"):
            inner += _field_double(3, float(v))
        if v := item.get("text"):
            inner += _string_field(4, v)
        if v := item.get("t"):
            inner += _string_field(5, v)
        if (v := item.get("time")) is not None:
            inner += _field_double(6, float(v))
        if (v := item.get("type")) is not None:
            inner += _field_varint(7, int(v))
        if v := item.get("from"):
            inner += _string_field(8, v)
        result += _field_bytes(2, bytes(inner))
    return bytes(result)


# ── random.proto ───────────────────────────────────────────

def encode_images_list(items: list[dict]) -> bytes:
    """images_body_: color(1), width(2), height(3), image(4)
       body 字段: 3
    """
    result = bytearray()
    for item in items:
        inner = bytearray()
        if v := item.get("color"):
            inner += _string_field(1, v)
        if v := item.get("width"):
            inner += _field_varint(2, int(v))
        if v := item.get("height"):
            inner += _field_varint(3, int(v))
        if v := item.get("image"):
            inner += _string_field(4, v)
        result += _field_bytes(3, bytes(inner))
    return bytes(result)


# ── thread.proto ───────────────────────────────────────────

def encode_thread_detail(item: dict) -> bytes:
    """thread_detail_: id(1), title(2), body(3), tags(4), nsfw(5),
       images(6) -> Images { color(1), height(2), width(3), originalSize(4), masterSize(5), original(6), master(7) }
    """
    inner = bytearray()
    if v := item.get("id"):
        inner += _field_varint(1, int(v))
    if v := item.get("title"):
        inner += _string_field(2, v)
    if v := item.get("body"):
        inner += _string_field(3, v)
    if v := item.get("tags"):
        inner += _string_field(4, v)
    if v := item.get("nsfw"):
        inner += _field_bool(5, bool(v))
    for img in item.get("images", []):
        img_inner = bytearray()
        if v := img.get("color"):
            img_inner += _string_field(1, v)
        if v := img.get("height"):
            img_inner += _field_varint(2, int(v))
        if v := img.get("width"):
            img_inner += _field_varint(3, int(v))
        if v := img.get("original_size") or img.get("originalSize"):
            img_inner += _field_varint(4, int(v))
        if v := img.get("master_size") or img.get("masterSize"):
            img_inner += _field_varint(5, int(v))
        if v := img.get("original"):
            img_inner += _string_field(6, v)
        if v := img.get("master"):
            img_inner += _string_field(7, v)
        inner += _field_bytes(6, bytes(img_inner))
    return bytes(inner)


# ── account.proto ──────────────────────────────────────────

def encode_login_response(user: dict, token: str) -> bytes:
    """login_ proto: error(1), message(2), body(3) -> login_user_
       login_user_: avatar(1), email(2), name(3), role(4), sex(5), exp(6),
                     coin(7), color(8), created(9), updated(10), id(11), address(12)
    """
    # body (login_user_)
    body = bytearray()
    if v := user.get("avatar"):
        body += _string_field(1, v)
    if v := user.get("email"):
        body += _string_field(2, v)
    if v := user.get("name"):
        body += _string_field(3, v)
    if v := user.get("role"):
        body += _string_field(4, v)
    if v := user.get("sex"):
        body += _string_field(5, v)
    if (v := user.get("exp")) is not None:
        body += _field_varint(6, int(v))
    if (v := user.get("coin")) is not None:
        body += _field_varint(7, int(v))
    if v := user.get("color"):
        body += _string_field(8, v)
    if (v := user.get("created_at")) is not None:
        body += _field_double(9, float(v))
    if (v := user.get("updated_at")) is not None:
        body += _field_double(10, float(v))
    if (v := user.get("id")) is not None:
        body += _field_varint(11, int(v))
    if v := user.get("address"):
        body += _string_field(12, v)

    token_inner = bytearray()
    token_inner += _string_field(1, token)  # token
    token_inner += _string_field(2, "0")     # time

    # login_ wrapper
    result = bytearray()
    result += _field_bool(1, False)  # error = false
    result += _string_field(2, "ok")  # message
    result += _field_bytes(3, bytes(body))  # body
    result += _field_bytes(4, bytes(token_inner))  # key (token_)
    return bytes(result)


def encode_init_response(user: dict) -> bytes:
    """init_ 响应，与 login_ 类似但没有 key 字段."""
    body = bytearray()
    if v := user.get("avatar"):
        body += _string_field(1, v)
    if v := user.get("email"):
        body += _string_field(2, v)
    if v := user.get("name"):
        body += _string_field(3, v)
    if v := user.get("role"):
        body += _string_field(4, v)
    if v := user.get("sex"):
        body += _string_field(5, v)
    if (v := user.get("exp")) is not None:
        body += _field_varint(6, int(v))
    if (v := user.get("coin")) is not None:
        body += _field_varint(7, int(v))
    if v := user.get("color"):
        body += _string_field(8, v)
    if (v := user.get("created_at")) is not None:
        body += _field_double(9, float(v))
    if (v := user.get("updated_at")) is not None:
        body += _field_double(10, float(v))
    if (v := user.get("id")) is not None:
        body += _field_varint(11, int(v))
    if v := user.get("address"):
        body += _string_field(12, v)

    result = bytearray()
    result += _field_bool(1, False)
    result += _string_field(2, "ok")
    result += _field_bytes(3, bytes(body))
    return bytes(result)


# ── tags.proto ─────────────────────────────────────────────

def encode_tag_list_response(items: list[dict]) -> bytes:
    """tag_list: body(2):
       id(1), name(2), count(3)
    """
    result = bytearray()
    for item in items:
        inner = bytearray()
        if v := item.get("id"):
            inner += _field_varint(1, int(v))
        if v := item.get("name"):
            inner += _string_field(2, v)
        if v := item.get("count"):
            inner += _field_varint(3, int(v))
        result += _field_bytes(2, bytes(inner))
    return bytes(result)


def encode_tag_info_response(item: dict) -> bytes:
    """tag_info: title(1), description(2), count(3), nsfw(4)"""
    result = bytearray()
    if v := item.get("title"):
        result += _string_field(1, v)
    if v := item.get("description"):
        result += _string_field(2, v)
    if v := item.get("count"):
        result += _field_varint(3, int(v))
    if v := item.get("nsfw"):
        result += _field_bool(4, bool(v))
    return bytes(result)
