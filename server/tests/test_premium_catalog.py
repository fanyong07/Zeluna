import unittest

from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from server.database import Base
from server.premium_catalog import (
    build_record,
    is_premium_quality,
    list_premium_lines,
    media_host,
    path_digest,
    record_premium_line,
)

_URL = "https://vod-cdn.example.net/video/zs/1080p/90effab4?token=abc&sign=xyz"


class QualityGateTests(unittest.TestCase):
    def test_premium_labels_are_recognized(self):
        for label in ("官方简中·1080P", "官方简中", "4K", "全高清", "蓝光", "1080P", "繁中"):
            self.assertTrue(is_premium_quality(label), label)

    def test_ordinary_labels_are_skipped(self):
        for label in ("", "第01集", "720P", "标准", "auto"):
            self.assertFalse(is_premium_quality(label), label)


class DigestTests(unittest.TestCase):
    def test_digest_excludes_query_string(self):
        with_query = path_digest(_URL)
        without_query = path_digest(_URL.split("?", 1)[0])
        self.assertEqual(with_query, without_query)
        self.assertEqual(len(with_query), 16)

    def test_digest_is_not_reversible_and_has_no_host(self):
        digest = path_digest(_URL)
        self.assertNotIn("vod-cdn", digest)
        self.assertNotIn("90effab4", digest)

    def test_host_is_lowercased(self):
        self.assertEqual(media_host("https://VOD-CDN.Example.NET/a"), "vod-cdn.example.net")

    def test_blank_inputs(self):
        self.assertEqual(path_digest(""), "")
        self.assertEqual(media_host(""), "")


class BuildRecordTests(unittest.TestCase):
    def test_premium_line_becomes_record_without_full_url(self):
        record = build_record(
            subject_stable_id="bangumi:37654",
            episode=1,
            url=_URL,
            quality_label="官方简中·1080P",
            source_tag="wk-21",
            provider_id="crawler.anich",
            subject_title="葬送的芙莉莲 第二季",
            container="hls",
            reachable=True,
        )
        self.assertIsNotNone(record)
        self.assertEqual(record.media_host, "vod-cdn.example.net")
        self.assertEqual(len(record.path_digest), 16)
        # 记录里绝不能出现完整地址或签名参数
        rendered = str(record)
        self.assertNotIn("token=", rendered)
        self.assertNotIn("/video/zs/", rendered)

    def test_non_premium_quality_is_refused(self):
        self.assertIsNone(
            build_record(
                subject_stable_id="bangumi:1",
                episode=1,
                url=_URL,
                quality_label="720P",
            )
        )

    def test_missing_subject_or_unusable_url_is_refused(self):
        self.assertIsNone(
            build_record(
                subject_stable_id="",
                episode=1,
                url=_URL,
                quality_label="官方简中",
            )
        )
        self.assertIsNone(
            build_record(
                subject_stable_id="bangumi:1",
                episode=1,
                url="not-a-url",
                quality_label="官方简中",
            )
        )

    def test_fields_are_truncated_and_episode_floored(self):
        record = build_record(
            subject_stable_id="bangumi:1",
            episode=-5,
            url=_URL,
            quality_label="官方简中" + "x" * 200,
            subject_title="标题" * 400,
        )
        self.assertEqual(record.episode, 0)
        self.assertLessEqual(len(record.quality_label), 60)
        self.assertLessEqual(len(record.subject_title), 300)


class CatalogPersistenceTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.engine = create_async_engine("sqlite+aiosqlite:///:memory:")
        async with self.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        self.sessions = async_sessionmaker(self.engine, expire_on_commit=False)

    async def asyncTearDown(self):
        await self.engine.dispose()

    def _record(self, **overrides):
        payload = {
            "subject_stable_id": "bangumi:37654",
            "episode": 1,
            "url": _URL,
            "quality_label": "官方简中·1080P",
            "source_tag": "wk-21",
            "provider_id": "crawler.anich",
            "subject_title": "葬送的芙莉莲 第二季",
            "container": "hls",
            "reachable": True,
        }
        payload.update(overrides)
        return build_record(**payload)

    async def test_first_record_is_created_then_deduplicated(self):
        async with self.sessions() as session:
            created = await record_premium_line(session, self._record(), now=1000.0)
            self.assertTrue(created)
            again = await record_premium_line(session, self._record(), now=2000.0)
            self.assertFalse(again)
            await session.commit()

            rows = await list_premium_lines(session)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["discovered_at"], 1000.0)
        self.assertEqual(rows[0]["last_seen_at"], 2000.0)

    async def test_reachability_stamp_only_set_when_verified(self):
        async with self.sessions() as session:
            await record_premium_line(
                session, self._record(reachable=False), now=500.0
            )
            await session.commit()
            rows = await list_premium_lines(session)
            self.assertEqual(rows[0]["reachable_at"], 0.0)

            await record_premium_line(
                session, self._record(reachable=True), now=900.0
            )
            await session.commit()
            rows = await list_premium_lines(session)
        self.assertEqual(rows[0]["reachable_at"], 900.0)

    async def test_different_source_tags_are_separate_rows(self):
        async with self.sessions() as session:
            await record_premium_line(session, self._record(source_tag="wk-21"))
            await record_premium_line(session, self._record(source_tag="ek-20"))
            await session.commit()
            rows = await list_premium_lines(session)
        self.assertEqual(len(rows), 2)

    async def test_export_contains_no_full_urls(self):
        async with self.sessions() as session:
            await record_premium_line(session, self._record())
            await session.commit()
            rows = await list_premium_lines(session)
        serialized = str(rows)
        self.assertNotIn("token=", serialized)
        self.assertNotIn("/video/zs/", serialized)
        self.assertIn("vod-cdn.example.net", serialized)

    async def test_filter_by_subject(self):
        async with self.sessions() as session:
            await record_premium_line(session, self._record())
            await record_premium_line(
                session, self._record(subject_stable_id="bangumi:999")
            )
            await session.commit()
            rows = await list_premium_lines(
                session, subject_stable_id="bangumi:999"
            )
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["subject_stable_id"], "bangumi:999")


if __name__ == "__main__":
    unittest.main()
