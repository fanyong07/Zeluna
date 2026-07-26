"""
元数据同步服务

从 TMDB、Bangumi、TVMaze 等开放 API 拉取元数据，
补充本地数据库中的番剧/剧集/电影信息。

使用方式:
  - 手动触发: POST /admin/sync/metadata
  - 自动: 新内容入库时自动触发
"""

import asyncio
import json
import logging
import time
from typing import Optional

import httpx

from .database import Bangumi, BangumiEpisode, async_session

logger = logging.getLogger(__name__)


# ============================================================
# API 客户端
# ============================================================

class TmdbClient:
    """TMDB API v3 客户端"""

    BASE = "https://api.themoviedb.org/3"
    IMAGE_BASE = "https://image.tmdb.org/t/p"

    def __init__(self, api_key: str = ""):
        self.api_key = api_key
        self._client = httpx.AsyncClient(
            headers={"Accept": "application/json"},
            timeout=15,
        )

    async def search_multi(self, query: str) -> list[dict]:
        """搜索电影+电视剧"""
        if not self.api_key:
            return []
        resp = await self._client.get(
            f"{self.BASE}/search/multi",
            params={
                "api_key": self.api_key,
                "query": query,
                "language": "zh-CN",
            },
        )
        if resp.status_code != 200:
            return []
        return resp.json().get("results", [])

    async def get_tv(self, tmdb_id: int) -> Optional[dict]:
        """获取电视剧详情"""
        if not self.api_key:
            return None
        resp = await self._client.get(
            f"{self.BASE}/tv/{tmdb_id}",
            params={
                "api_key": self.api_key,
                "language": "zh-CN",
                "append_to_response": "external_ids,credits",
            },
        )
        if resp.status_code != 200:
            return None
        return resp.json()

    async def get_movie(self, tmdb_id: int) -> Optional[dict]:
        """获取电影详情"""
        if not self.api_key:
            return None
        resp = await self._client.get(
            f"{self.BASE}/movie/{tmdb_id}",
            params={
                "api_key": self.api_key,
                "language": "zh-CN",
                "append_to_response": "external_ids,credits",
            },
        )
        if resp.status_code != 200:
            return None
        return resp.json()

    async def get_tv_episodes(
        self, tmdb_id: int, season: int
    ) -> list[dict]:
        """获取电视剧某季的剧集"""
        if not self.api_key:
            return []
        resp = await self._client.get(
            f"{self.BASE}/tv/{tmdb_id}/season/{season}",
            params={
                "api_key": self.api_key,
                "language": "zh-CN",
            },
        )
        if resp.status_code != 200:
            return []
        return resp.json().get("episodes", [])


class BangumiClient:
    """Bangumi API 客户端 (api.bgm.tv)"""

    BASE = "https://api.bgm.tv"

    def __init__(self):
        self._client = httpx.AsyncClient(
            headers={
                "User-Agent": "anich/anime-app (https://github.com/user/anime)",
                "Accept": "application/json",
            },
            timeout=15,
        )

    async def search(self, keyword: str, type_filter: int = None) -> list[dict]:
        """
        搜索番剧。
        type_filter: 1=书籍, 2=动画, 3=音乐, 4=游戏, 6=三次元
        """
        params = {
            "keyword": keyword,
            "responseGroup": "medium",
        }
        if type_filter:
            params["type"] = type_filter

        resp = await self._client.get(
            f"{self.BASE}/search/subject/{keyword}",
            params={"type": type_filter or 2, "responseGroup": "medium", "max_results": 10},
        )
        if resp.status_code != 200:
            return []
        data = resp.json()
        return data.get("list", []) if isinstance(data, dict) else data

    async def get_subject(self, subject_id: int) -> Optional[dict]:
        """获取番剧详情"""
        resp = await self._client.get(
            f"{self.BASE}/v0/subjects/{subject_id}",
        )
        if resp.status_code != 200:
            return None
        return resp.json()

    async def get_episodes(self, subject_id: int) -> list[dict]:
        """获取番剧剧集"""
        resp = await self._client.get(
            f"{self.BASE}/v0/episodes",
            params={"subject_id": subject_id, "limit": 100},
        )
        if resp.status_code != 200:
            return []
        return resp.json().get("data", [])


class TvmazeClient:
    """TVMaze API 客户端 (免费，无需 key)"""

    BASE = "https://api.tvmaze.com"

    def __init__(self):
        self._client = httpx.AsyncClient(
            headers={"Accept": "application/json"},
            timeout=15,
        )

    async def search(self, query: str) -> list[dict]:
        """搜索电视剧"""
        resp = await self._client.get(
            f"{self.BASE}/search/shows",
            params={"q": query},
        )
        if resp.status_code != 200:
            return []
        return resp.json()

    async def get_show(self, show_id: int) -> Optional[dict]:
        """获取电视剧详情（含剧集）"""
        resp = await self._client.get(
            f"{self.BASE}/shows/{show_id}",
            params={"embed[]": "episodes"},
        )
        if resp.status_code != 200:
            return None
        return resp.json()


# ============================================================
# 同步服务
# ============================================================

class MetadataSyncService:
    """
    元数据同步服务

    使用多个外部 API 补充内容的元数据信息。
    """

    def __init__(
        self,
        tmdb_key: str = "",
        bgm_token: str = "",
    ):
        self.tmdb = TmdbClient(tmdb_key)
        self.bangumi = BangumiClient()
        self.tvmaze = TvmazeClient()

    async def enrich_bangumi(self, bangumi: Bangumi) -> Optional[Bangumi]:
        """
        补充番剧/剧集/电影的元数据。

        根据内容类型使用不同的 API:
          - anime → Bangumi API (优先) + TMDB
          - series → TMDB (优先) + TVMaze
          - movie → TMDB
        """
        title = bangumi.title
        content_type = bangumi.type  # tv, movie, ova

        async with async_session() as session:
            if content_type == "movie":
                await self._enrich_from_tmdb(bangumi, session, is_movie=True)
            elif bangumi.lang == "en":
                # 美剧 → TVMaze
                await self._enrich_from_tvmaze(bangumi, session)
                if not bangumi.cover_url:
                    await self._enrich_from_tmdb(bangumi, session)
            else:
                # 默认: 动漫从 Bangumi, 电视剧从 TMDB
                if content_type in ("tv", "ova") and bangumi.lang in ("ja", ""):
                    await self._enrich_from_bangumi(bangumi, session)
                if not bangumi.summary or not bangumi.cover_url:
                    await self._enrich_from_tmdb(bangumi, session)

        return bangumi

    async def _enrich_from_tmdb(
        self, bangumi: Bangumi, session, is_movie: bool = False
    ):
        """从 TMDB 补充元数据"""
        if not self.tmdb.api_key:
            return

        results = await self.tmdb.search_multi(bangumi.title)
        if not results:
            return

        best = results[0]
        media_type = best.get("media_type", "movie" if is_movie else "tv")
        tmdb_id = best.get("id")

        if not tmdb_id:
            return

        if media_type == "movie":
            detail = await self.tmdb.get_movie(tmdb_id)
        else:
            detail = await self.tmdb.get_tv(tmdb_id)

        if not detail:
            return

        # 更新封面
        poster = detail.get("poster_path", "")
        if poster and not bangumi.cover_url:
            bangumi.cover_url = f"{TmdbClient.IMAGE_BASE}/w500{poster}"

        backdrop = detail.get("backdrop_path", "")
        if backdrop and not bangumi.banner_url:
            bangumi.banner_url = f"{TmdbClient.IMAGE_BASE}/original{backdrop}"

        # 更新简介
        overview = detail.get("overview", "")
        if overview and not bangumi.summary:
            bangumi.summary = overview[:2000]

        # 更新评分
        vote_avg = detail.get("vote_average", 0)
        if vote_avg and not bangumi.rating:
            bangumi.rating = float(vote_avg)
            bangumi.rating_count = detail.get("vote_count", 0)

        # 更新年份和语言
        date_key = "release_date" if media_type == "movie" else "first_air_date"
        date_str = detail.get(date_key, "")
        if date_str:
            bangumi.year = int(date_str[:4])

        orig_lang = detail.get("original_language", "")
        if orig_lang and not bangumi.lang:
            bangumi.lang = orig_lang

        # 更新标签
        genres = [g.get("name", "") for g in detail.get("genres", [])]
        if genres:
            bangumi.genres = json.dumps(genres, ensure_ascii=False)
            bangumi.tags = json.dumps(genres, ensure_ascii=False)

        # 添加 external ID
        external_ids = detail.get("external_ids", {})
        imdb_id = external_ids.get("imdb_id", "")
        if imdb_id:
            bangumi.bangumi_id = f"tmdb_{tmdb_id}"

        await session.commit()
        logger.info(f"TMDB enriched: {bangumi.title} (id={tmdb_id})")

    async def _enrich_from_bangumi(self, bangumi: Bangumi, session):
        """从 Bangumi 补充番剧元数据"""
        results = await self.bangumi.search(bangumi.title, type_filter=2)
        if not results:
            return

        best = results[0]
        subject_id = best.get("id")

        if not subject_id:
            return

        detail = await self.bangumi.get_subject(subject_id)
        if not detail:
            return

        # 更新封面
        images = detail.get("images", {})
        if images:
            large = images.get("large", images.get("common", ""))
            if large and not bangumi.cover_url:
                bangumi.cover_url = large

        # 更新简介
        summary = detail.get("summary", "")
        if summary and not bangumi.summary:
            bangumi.summary = summary[:2000]

        # 更新评分
        rating = detail.get("rating", {})
        score = rating.get("score", 0)
        if score and not bangumi.rating:
            bangumi.rating = float(score)
            bangumi.rating_count = rating.get("total", 0)

        # 更新标签
        tags_list = [t.get("name", "") for t in detail.get("tags", [])]
        if tags_list:
            bangumi.tags = json.dumps(tags_list, ensure_ascii=False)

        # 外部 ID
        bangumi.bangumi_id = f"bgm_{subject_id}"

        await session.commit()
        logger.info(f"Bangumi enriched: {bangumi.title} (id={subject_id})")

    async def _enrich_from_tvmaze(self, bangumi: Bangumi, session):
        """从 TVMaze 补充电视剧元数据"""
        results = await self.tvmaze.search(bangumi.title)
        if not results:
            return

        show = results[0].get("show", {})
        show_id = show.get("id")

        if not show_id:
            return

        detail = await self.tvmaze.get_show(show_id)
        if not detail:
            return

        # 更新封面
        image = detail.get("image", {})
        if image:
            orig = image.get("original", image.get("medium", ""))
            if orig and not bangumi.cover_url:
                bangumi.cover_url = orig

        # 更新简介
        summary = detail.get("summary", "")
        if summary and not bangumi.summary:
            # 去除 HTML 标签
            import re
            clean = re.sub(r'<[^>]+>', '', summary)
            bangumi.summary = clean[:2000]

        # 更新评分
        rating = detail.get("rating", {})
        avg = rating.get("average") if rating else None
        if avg is not None and not bangumi.rating:
            bangumi.rating = float(avg)

        # 更新标签
        genres = detail.get("genres", [])
        if genres:
            bangumi.genres = json.dumps(genres, ensure_ascii=False)
            bangumi.tags = json.dumps(genres, ensure_ascii=False)

        # 语言
        lang = detail.get("language", "")
        if lang and not bangumi.lang:
            bangumi.lang = lang

        bangumi.bangumi_id = f"tvmaze_{show_id}"

        await session.commit()
        logger.info(f"TVMaze enriched: {bangumi.title} (id={show_id})")


# 全局同步服务实例
sync_service = MetadataSyncService()


async def sync_all_pending(types: list[str] = None):
    """
    同步所有缺少元数据的内容。

    Args:
        types: 要同步的内容类型列表，如 ["tv", "movie"]。
               默认同步所有类型。
    """
    async with async_session() as session:
        from sqlalchemy import select, or_

        stmt = select(Bangumi).where(
            or_(
                Bangumi.summary == "",
                Bangumi.cover_url == "",
                Bangumi.rating == 0.0,
            )
        ).limit(50)

        if types:
            stmt = stmt.where(Bangumi.type.in_(types))

        result = await session.execute(stmt)
        bangumi_list = result.scalars().all()

        for bangumi in bangumi_list:
            try:
                await sync_service.enrich_bangumi(bangumi)
                await asyncio.sleep(0.3)  # rate limiting
            except Exception as e:
                logger.error(f"Sync error for {bangumi.title}: {e}")

    logger.info(f"Metadata sync complete: {len(bangumi_list)} items processed")
