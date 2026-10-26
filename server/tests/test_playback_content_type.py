import unittest
from unittest.mock import AsyncMock, patch

from server.playback import PlaybackService


class PlaybackContentTypeTests(unittest.IsolatedAsyncioTestCase):
    async def context(self, metadata, *, hint="anime"):
        service = PlaybackService(managed_lines_enabled=False)
        with (
            patch("server.playback.catalog_service.get_subject", AsyncMock(return_value=metadata)),
            patch("server.playback.catalog_service.playback_aliases", AsyncMock(return_value=[metadata["title"]])),
        ):
            return await service._playback_context(
                metadata["stable_id"], None,
                title=metadata["title"], original_title="", content_type=hint, year=2024,
            )

    async def test_tmdb_animated_tv_uses_anime_matching_not_live_action_tv(self):
        for genre in ("动画", "Animation", "anime"):
            with self.subTest(genre=genre):
                context = await self.context({
                    "stable_id": "tmdb:tv:241535", "media_type": "tv",
                    "title": "败犬女主太多了！", "genres": [genre, "喜剧"],
                })
                self.assertEqual(context[1], "anime")

    async def test_animation_movie_stays_movie(self):
        context = await self.context({
            "stable_id": "tmdb:movie:916224", "media_type": "movie",
            "title": "铃芽之旅", "genres": ["动画"],
        })
        self.assertEqual(context[1], "movie")

    async def test_live_action_metadata_is_not_overridden_by_anime_hint(self):
        context = await self.context({
            "stable_id": "tmdb:tv:95842", "media_type": "tv",
            "title": "开端", "genres": ["剧情"],
        })
        self.assertEqual(context[1], "tv")

    async def test_bangumi_remains_anime(self):
        context = await self.context({
            "stable_id": "bangumi:464376", "media_type": "anime",
            "title": "败犬女主太多了！", "genres": ["恋爱"],
        })
        self.assertEqual(context[1], "anime")
