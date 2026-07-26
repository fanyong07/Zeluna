"""
爬虫基类

所有爬虫继承此基类，实现统一接口。
"""

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Optional


@dataclass
class SubjectResult:
    """搜索结果中的条目"""
    source_id: str            # 在爬虫源站中的 ID
    title: str                # 标题
    cover_url: str = ""       # 封面图
    summary: str = ""         # 简介
    type: str = "tv"          # tv | movie | ova
    lang: str = ""            # ja | zh | en
    year: int = 2024          # 年份
    status: int = 0           # 0=连载 1=完结
    episode_count: int = 0    # 总集数
    latest_episode: int = 0   # 最新集数
    tags: list[str] = field(default_factory=list)
    genres: list[str] = field(default_factory=list)
    rating: float = 0.0       # 评分
    extra: dict = field(default_factory=dict)  # 额外元数据


@dataclass
class EpisodeInfo:
    """剧集信息"""
    number: int               # 集数
    title: str = ""           # 剧集标题
    source_episode_id: str = ""  # 在源站中的剧集 ID
    duration: str = ""        # 时长
    thumbnail_url: str = ""   # 缩略图


@dataclass
class SubjectDetail:
    """条目详情"""
    source_id: str
    title: str
    cover_url: str = ""
    banner_url: str = ""
    summary: str = ""
    type: str = "tv"
    lang: str = ""
    year: int = 2024
    status: int = 0
    tags: list[str] = field(default_factory=list)
    genres: list[str] = field(default_factory=list)
    rating: float = 0.0
    rating_count: int = 0
    episodes: list[EpisodeInfo] = field(default_factory=list)
    characters: list[dict] = field(default_factory=list)
    staff: list[dict] = field(default_factory=list)
    extra: dict = field(default_factory=dict)


@dataclass
class VideoLine:
    """视频播放线路"""
    url: str                  # 视频 URL (m3u8/mp4)
    title: str = ""           # 线路名称
    quality: str = ""         # 画质: 1080p, 4K, etc.
    format: str = ""          # 格式: hls, mp4
    headers: dict = field(default_factory=dict)  # 请求头
    source_name: str = ""     # 来源爬虫名


class BaseScraper(ABC):
    """
    爬虫基类

    每个视频源站点实现一个子类。
    """

    def __init__(self):
        self._name: str = self.__class__.__name__

    @property
    def name(self) -> str:
        return self._name

    @property
    @abstractmethod
    def content_types(self) -> list[str]:
        """
        支持的内容类型列表。

        返回值应为以下的一个或多个:
          - "anime"   (番剧/动漫)
          - "series"  (电视剧/剧集)
          - "movie"   (电影)
        """
        ...

    @property
    @abstractmethod
    def base_url(self) -> str:
        """爬虫对应的源站 URL"""
        ...

    @abstractmethod
    async def search(self, keyword: str) -> list[SubjectResult]:
        """
        搜索内容。

        Args:
            keyword: 搜索关键词

        Returns:
            匹配的条目列表
        """
        ...

    @abstractmethod
    async def get_detail(self, source_id: str) -> Optional[SubjectDetail]:
        """
        获取条目详情（含剧集列表）。

        Args:
            source_id: 在源站中的条目 ID

        Returns:
            条目详情，含剧集信息
        """
        ...

    @abstractmethod
    async def get_video_urls(
        self, source_id: str, episode: int = 1
    ) -> list[VideoLine]:
        """
        获取视频播放地址。

        Args:
            source_id: 源站条目 ID
            episode: 集数

        Returns:
            视频线路列表 (通常含多条线路)
        """
        ...

    async def get_latest(self, page: int = 1) -> list[SubjectResult]:
        """
        获取最新更新。

        默认实现返回空列表，子类可覆盖。
        """
        return []

    async def get_home(self) -> list[SubjectResult]:
        """
        获取首页推荐。

        默认实现返回空列表，子类可覆盖。
        """
        return []

    async def aclose(self) -> None:
        """Release a scraper-owned async HTTP client when one exists."""
        client = getattr(self, "_client", None)
        close = getattr(client, "aclose", None)
        if callable(close):
            await close()

    def __repr__(self):
        return f"<{self.name} ({', '.join(self.content_types)})>"
