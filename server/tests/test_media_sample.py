"""Bounded CLI diagnostics must never buffer whole media responses."""
import unittest

import httpx

from tools.media_sample import MANIFEST_LIMIT, SAMPLE_LIMIT, probe_media


class CountingStream(httpx.AsyncByteStream):
    def __init__(self, content: bytes, chunks: int = 100):
        self.content = content
        self.chunks = chunks
        self.reads = 0
        self.closed = False

    async def __aiter__(self):
        for _ in range(self.chunks):
            self.reads += 1
            yield self.content

    async def aclose(self):
        self.closed = True


class MediaSampleTests(unittest.IsolatedAsyncioTestCase):
    async def test_ignored_range_mp4_stops_after_first_kib(self):
        stream = CountingStream(b'\x00\x00\x00\x18ftypisom' + b'x' * 1012)

        def handler(request):
            self.assertEqual(request.headers['range'], f'bytes=0-{MANIFEST_LIMIT - 1}')
            return httpx.Response(200, headers={'Content-Type': 'video/mp4'}, stream=stream)

        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            report = await probe_media(client, 'https://origin.test/video.mp4')
        self.assertTrue(report['ok'])
        self.assertEqual(report['hops'][0]['kind'], 'mp4')
        self.assertEqual(report['hops'][0]['bytes_read'], SAMPLE_LIMIT)
        self.assertEqual(stream.reads, 1)
        self.assertTrue(stream.closed)

    async def test_master_variant_and_segment_use_document_relative_urls(self):
        seen = []
        segment = CountingStream(b'\x47' + b'\x00' * 1023)

        def handler(request):
            seen.append(str(request.url))
            self.assertEqual(request.headers['referer'], 'https://site.test/play/1')
            if request.url.path == '/master.m3u8':
                return httpx.Response(200, text='#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=100\nsub/main.m3u8\n')
            if request.url.path == '/sub/main.m3u8':
                return httpx.Response(200, text='#EXTM3U\n#EXTINF:4.0,\n../segments/0001.ts\n')
            self.assertEqual(request.url.path, '/segments/0001.ts')
            return httpx.Response(206, stream=segment)

        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            report = await probe_media(client, 'https://origin.test/master.m3u8', {'Referer': 'https://site.test/play/1'})
        self.assertTrue(report['ok'])
        self.assertEqual(len(seen), 3)
        self.assertEqual([hop['kind'] for hop in report['hops']], ['hls', 'hls', 'binary'])
        self.assertEqual(segment.reads, 1)
        self.assertTrue(segment.closed)

    async def test_headerless_html_is_not_media(self):
        async with httpx.AsyncClient(transport=httpx.MockTransport(
            lambda request: httpx.Response(200, content=b' <!DOCTYPE html><html>denied</html>')
        )) as client:
            report = await probe_media(client, 'https://origin.test/video')
        self.assertFalse(report['ok'])
        self.assertEqual(report['stage'], 'non-media')

    async def test_error_content_type_does_not_read_body(self):
        for content_type in ('text/html', 'application/json; charset=utf-8'):
            with self.subTest(content_type=content_type):
                stream = CountingStream(b'[]')
                async with httpx.AsyncClient(transport=httpx.MockTransport(
                    lambda request: httpx.Response(200, headers={'Content-Type': content_type}, stream=stream)
                )) as client:
                    report = await probe_media(client, 'https://origin.test/video')
                self.assertFalse(report['ok'])
                self.assertEqual(stream.reads, 0)
                self.assertTrue(stream.closed)

    async def test_http_error_does_not_read_body(self):
        stream = CountingStream(b'not media')
        async with httpx.AsyncClient(transport=httpx.MockTransport(
            lambda request: httpx.Response(403, stream=stream)
        )) as client:
            report = await probe_media(client, 'https://origin.test/video')
        self.assertFalse(report['ok'])
        self.assertEqual(report['stage'], 'http')
        self.assertEqual(stream.reads, 0)
        self.assertTrue(stream.closed)

    async def test_playlists_are_read_and_depth_bounded(self):
        streams = []

        def handler(request):
            stream = CountingStream(b'#EXTM3U\nnext.m3u8\n' + b'#' * 1007)
            streams.append(stream)
            return httpx.Response(200, stream=stream)

        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            report = await probe_media(client, 'https://origin.test/loop.m3u8')
        self.assertFalse(report['ok'])
        self.assertEqual(report['stage'], 'playlist-depth')
        self.assertEqual(len(streams), 4)
        self.assertLessEqual(sum(hop['bytes_read'] for hop in report['hops']), 3 * MANIFEST_LIMIT + SAMPLE_LIMIT)
        self.assertTrue(all(stream.closed for stream in streams))

    async def test_empty_playlist_and_transport_failure(self):
        async with httpx.AsyncClient(transport=httpx.MockTransport(
            lambda request: httpx.Response(200, content=b'#EXTM3U\n#EXT-X-ENDLIST\n')
        )) as client:
            report = await probe_media(client, 'https://origin.test/empty.m3u8')
        self.assertFalse(report['ok'])
        self.assertEqual(report['stage'], 'empty-playlist')

        def fail(request):
            raise httpx.ConnectTimeout('fixture', request=request)

        async with httpx.AsyncClient(transport=httpx.MockTransport(fail)) as client:
            report = await probe_media(client, 'https://origin.test/video.mp4')
        self.assertFalse(report['ok'])
        self.assertEqual(report['hops'][0]['error'], 'ConnectTimeout')
