import unittest

from server.m3u8_resolver import M3U8Resolver


class M3U8ResolverTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.resolver = M3U8Resolver()

    async def asyncTearDown(self):
        await self.resolver.aclose()

    async def test_direct_media_url_is_recognized_without_external_parser(self):
        results = await self.resolver.resolve_via_parse_services(
            "https://cdn.example/video/index.m3u8?token=public"
        )

        self.assertEqual(len(results), 1)
        self.assertEqual(results[0]["format"], "hls")
        self.assertEqual(results[0]["source"], "generic")

    async def test_non_media_page_is_not_forwarded_to_an_external_parser(self):
        results = await self.resolver.resolve_via_parse_services(
            "https://source.example/watch/123"
        )

        self.assertEqual(results, [])


if __name__ == "__main__":
    unittest.main()
