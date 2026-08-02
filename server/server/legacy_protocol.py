"""Small helpers shared by retained protobuf compatibility routes."""

from fastapi.responses import Response

from .database import User


def protobuf_bytes(data: bytes) -> Response:
    return Response(content=data, media_type="application/octet-stream")


def user_to_dict(user: User) -> dict:
    return {
        "id": user.id,
        "email": user.email,
        "name": user.name,
        "role": user.role,
        "sex": user.sex,
        "avatar": user.avatar,
        "exp": user.exp,
        "coin": user.coin,
        "color": user.color,
        "address": user.address,
        "created_at": user.created_at,
        "updated_at": user.updated_at,
    }


def parse_account_request(data: bytes) -> dict:
    """Parse retained login/register/change-password protobuf fields."""

    fields = {}
    pos = 0
    while pos < len(data):
        tag = data[pos]
        pos += 1
        field_number = tag >> 3
        wire_type = tag & 0x07
        if wire_type == 2:
            if pos >= len(data):
                break
            length = data[pos]
            pos += 1
            value = data[pos : pos + length].decode("utf-8", errors="replace")
            pos += length
            if field_number == 1:
                fields["user"] = value
                fields["email"] = value
            elif field_number == 2:
                fields["password"] = value
            elif field_number == 3:
                fields["code"] = value
            elif field_number == 4:
                fields["name"] = value
        elif wire_type == 0:
            shift = 0
            while pos < len(data):
                byte = data[pos]
                pos += 1
                if not (byte & 0x80):
                    break
                shift += 7
        else:
            break
    return fields
