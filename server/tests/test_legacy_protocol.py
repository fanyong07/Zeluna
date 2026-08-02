from server.legacy_protocol import parse_account_request, protobuf_bytes


def _string_field(number: int, value: str) -> bytes:
    encoded = value.encode("utf-8")
    return bytes([(number << 3) | 2, len(encoded)]) + encoded


def test_account_request_parser_preserves_legacy_field_mapping():
    payload = b"".join(
        [
            _string_field(1, "user@example.test"),
            _string_field(2, "password"),
            _string_field(3, "123456"),
            _string_field(4, "tester"),
        ]
    )

    assert parse_account_request(payload) == {
        "user": "user@example.test",
        "email": "user@example.test",
        "password": "password",
        "code": "123456",
        "name": "tester",
    }


def test_legacy_protocol_response_keeps_binary_media_type():
    response = protobuf_bytes(b"payload")

    assert response.body == b"payload"
    assert response.media_type == "application/octet-stream"
