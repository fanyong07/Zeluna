import unittest

from server.protobuf_encoder import (
    _field_bytes,
    _field_double,
    _field_varint,
    _string_field,
    _varint,
)
from server.scrapers.anime import anich_proto


def _write_varint(value: int) -> bytes:
    return _varint(int(value))


class VarintTests(unittest.TestCase):
    def test_varint_roundtrip_multibyte_values(self):
        for value in (0, 1, 127, 128, 300, 243, 2**32 - 1):
            data = _write_varint(value)
            decoded, pos = anich_proto.read_varint(data, 0)
            self.assertEqual((decoded, pos), (value, len(data)))

    def test_truncated_varint_raises(self):
        with self.assertRaises(ValueError):
            anich_proto.read_varint(b"\x80", 0)

    def test_iter_fields_skips_unknown_fields(self):
        # field1=len-str("ab") + unknown field7=varint + field2=varint
        data = _field_bytes(1, b"ab") + _field_varint(7, 5) + _field_varint(2, 300)
        collected = {}
        for fno, wire, value in anich_proto.iter_fields(data):
            collected[fno] = value
        self.assertEqual(collected[1], b"ab")
        self.assertEqual(collected[2], 300)


class BangumiListDecodingTests(unittest.TestCase):
    def test_decode_bangumi_list_golden_fields(self):
        inner = (
            _field_varint(1, 37654)
            + _string_field(2, "葬送的芙莉莲 第二季")
            + _field_varint(3, 58)
            + _field_varint(4, 68)
            + _string_field(5, "standard")
            + _field_double(6, 1735689600.0)
            + _string_field(8, "魔法使旅程再开")
        )
        payload = _field_bytes(1, inner)

        items = anich_proto.decode_bangumi_list(payload)

        self.assertEqual(len(items), 1)
        entry = items[0]
        self.assertEqual(entry["id"], 37654)
        self.assertEqual(entry["title"], "葬送的芙莉莲 第二季")
        self.assertEqual(entry["episode"], 58)
        self.assertEqual(entry["episodes_total"], 68)
        self.assertEqual(entry["status"], "standard")
        self.assertAlmostEqual(entry["date"], 1735689600.0)
        self.assertEqual(entry["tagline"], "魔法使旅程再开")


class EpisodesDecodingTests(unittest.TestCase):
    def test_decode_episodes_with_sites_and_dirty_duration(self):
        site = _string_field(1, "tmdb") + _string_field(2, "121212")
        good = (
            _field_varint(1, 1)
            + _field_varint(2, 38)
            + _field_double(3, 1700000000.0)
            + _field_varint(4, 1440)
            + _field_bytes(5, site)
            + _string_field(8, "黄金乡的居民")
        )
        dirty = _field_varint(1, 0) + _field_varint(2, 999999)
        payload = _field_bytes(1, good) + _field_bytes(1, dirty)

        episodes = anich_proto.decode_episodes(payload)

        self.assertEqual(len(episodes), 2)
        self.assertTrue(episodes[0]["status"])
        self.assertEqual(episodes[0]["sort"], 38)
        self.assertEqual(episodes[0]["duration"], 1440)
        self.assertEqual(episodes[0]["sites"][0]["site"], "tmdb")
        self.assertFalse(episodes[1]["status"])


class VodDecodingTests(unittest.TestCase):
    def _body(self) -> bytes:
        item_a = (
            _string_field(1, "aHR0cDovL29r")
            + _field_varint(2, 38)
            + _string_field(4, "第10集(官方简中-全高清-1080P)")
        )
        item_b = _string_field(1, "bm90aGluZw==") + _string_field(4, "第10集")
        return _field_bytes(1, item_a) + _field_bytes(1, item_b)

    def test_decode_vod_keeps_raw_url_for_variant_decoding(self):
        items = anich_proto.decode_vod(self._body())
        self.assertEqual(items[0]["url_raw"], "aHR0cDovL29r")
        self.assertEqual(items[0]["caption"], "第10集(官方简中-全高清-1080P)")
        self.assertEqual(items[1]["sort"], 0)


class UnwrapVodBodyTests(unittest.TestCase):
    def test_json_byte_array_wrapper_is_unwrapped(self):
        body = self._pb()
        wrapped = f"[{','.join(str(b) for b in body)}]".encode()
        self.assertEqual(anich_proto.unwrap_vod_body(wrapped), body)

    def _pb(self) -> bytes:
        return _field_bytes(1, _string_field(4, "x"))

    def test_raw_protobuf_passthrough(self):
        body = self._pb()
        self.assertEqual(anich_proto.unwrap_vod_body(body), body)

    def test_invalid_wrappers_raise_value_error(self):
        # 非 "[" 开头的输入一律按裸 protobuf 透传,不在此抛错
        for raw in (b'["nope"]', b"[]", b"["):
            with self.assertRaises(ValueError):
                anich_proto.unwrap_vod_body(raw)


class VariantBase64Tests(unittest.TestCase):
    def test_roundtrip_with_junk_at_index_three(self):
        import base64

        original = "https://cdn.example/video/zs/abc.m3u8"
        b64 = base64.b64encode(original.encode()).decode()
        variant = b64[:3] + "0" + b64[3:]
        self.assertEqual(anich_proto.decode_variant_base64(variant), original)

    def test_malformed_payloads_raise_value_error(self):
        for raw in ("abc", "--", "\x01\x02\x03\x04"):
            with self.assertRaises(ValueError):
                anich_proto.decode_variant_base64(raw)


if __name__ == "__main__":
    unittest.main()
