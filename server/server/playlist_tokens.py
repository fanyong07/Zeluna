"""播放清单剪裁的签发式 token。

剪裁端点必须只接受**服务端签发过**的目标地址,绝不能接受调用方传入的
任意 URL——否则该端点就成了开放代理与 SSRF 跳板。

token = base64url(payload) + "." + base64url(HMAC-SHA256(payload))
payload 是紧凑 JSON:{"u": 媒体URL, "r": Referer, "e": 过期时间戳}
密钥复用账号体系的 ``SECRET_KEY``(已有强度校验),不新增凭据。
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import time
from dataclasses import dataclass

from .auth import AuthConfigurationError, signing_key

#: 签发有效期。清单剪裁只服务于"当前这次播放",不需要长期有效。
PLAYLIST_TOKEN_TTL_SECONDS = 6 * 3600
_MAX_TOKEN_BYTES = 4096


class PlaylistTokenError(ValueError):
    """token 缺失、损坏、签名不符或已过期。"""


@dataclass(frozen=True)
class PlaylistTarget:
    url: str
    referer: str = ""
    expires_at: float = 0.0


def _b64encode(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def _b64decode(text: str) -> bytes:
    padded = text + "=" * (-len(text) % 4)
    return base64.urlsafe_b64decode(padded.encode("ascii"))


def _sign(payload: bytes, key: str) -> str:
    digest = hmac.new(key.encode("utf-8"), payload, hashlib.sha256).digest()
    return _b64encode(digest)


def issue_playlist_token(
    url: str,
    *,
    referer: str = "",
    ttl_seconds: float = PLAYLIST_TOKEN_TTL_SECONDS,
    now: float | None = None,
) -> str:
    """为一条已验证的媒体地址签发 token。

    ``AuthConfigurationError`` 会向上抛出:SECRET_KEY 不合规时宁可不提供
    剪裁能力,也不用弱密钥签发。
    """
    clean_url = (url or "").strip()
    if not clean_url.lower().startswith(("http://", "https://")):
        raise PlaylistTokenError("只能为 HTTP(S) 媒体地址签发 token")
    key = signing_key()
    issued_at = time.time() if now is None else now
    payload_obj = {
        "u": clean_url,
        "e": round(issued_at + max(60.0, ttl_seconds), 3),
    }
    if referer:
        payload_obj["r"] = referer.strip()
    payload = json.dumps(
        payload_obj, ensure_ascii=False, separators=(",", ":")
    ).encode("utf-8")
    return f"{_b64encode(payload)}.{_sign(payload, key)}"


def parse_playlist_token(token: str, *, now: float | None = None) -> PlaylistTarget:
    """校验并解出目标。任何异常都归一成 ``PlaylistTokenError``。"""
    raw = (token or "").strip()
    if not raw or len(raw) > _MAX_TOKEN_BYTES or raw.count(".") != 1:
        raise PlaylistTokenError("token 格式不正确")
    encoded_payload, signature = raw.split(".", 1)
    try:
        key = signing_key()
    except AuthConfigurationError as error:
        raise PlaylistTokenError(str(error)) from error
    try:
        payload = _b64decode(encoded_payload)
    except (ValueError, TypeError) as error:
        raise PlaylistTokenError("token 编码损坏") from error
    if not hmac.compare_digest(signature, _sign(payload, key)):
        raise PlaylistTokenError("token 签名不符")
    try:
        data = json.loads(payload.decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as error:
        raise PlaylistTokenError("token 内容损坏") from error
    if not isinstance(data, dict):
        raise PlaylistTokenError("token 内容损坏")
    url = str(data.get("u") or "")
    if not url.lower().startswith(("http://", "https://")):
        raise PlaylistTokenError("token 未携带合法媒体地址")
    expires_at = float(data.get("e") or 0.0)
    current = time.time() if now is None else now
    if expires_at and expires_at <= current:
        raise PlaylistTokenError("token 已过期")
    return PlaylistTarget(
        url=url,
        referer=str(data.get("r") or ""),
        expires_at=expires_at,
    )
