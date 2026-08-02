"""Zeluna FastAPI lifecycle and compatibility seed composition."""

from contextlib import asynccontextmanager

from sqlalchemy import func, select

from .database import (
    async_session, init_db,
    User,
    Bangumi, BangumiEpisode,
    Character,
    Thread,
    PlayHistory,
)
from .scheduler import scheduler
from .aggregator import aggregator
from .m3u8_resolver import resolver as m3u8_resolver
from .catalog import catalog_service
from .playback import playback_service
from .app import create_app

@asynccontextmanager
async def lifespan(_app):
    await init_db()
    await scheduler.start()
    try:
        await _seed_data()
        yield
    finally:
        await scheduler.stop()
        await playback_service.aclose()
        await aggregator.aclose()
        await catalog_service.aclose()
        await m3u8_resolver.aclose()


app = create_app(lifespan=lifespan)


# ────────────────────────────────────────────────────────────
# 辅助函数
# ────────────────────────────────────────────────────────────

async def _seed_data():
    """初始化一些示例数据."""
    async with async_session() as session:
        # Remove the historical fixed-password demo identity. Production
        # account creation is exclusively handled by the email API.
        demo_user = await session.scalar(
            select(User).where(User.email == "admin@anich.local")
        )
        if demo_user is not None:
            await session.delete(demo_user)
            await session.commit()
        # 检查是否已有数据
        result = await session.execute(select(func.count(Bangumi.id)))
        if result.scalar() > 0:
            return

        # 创建示例番剧
        anime_data = [
            {
                "title": "星港回声",
                "summary": "少年在轨道都市追踪失踪信号，发现一段被隐藏的宇宙航线。",
                "type": "tv", "lang": "ja", "year": 2024, "status": 0,
                "tags": '["科幻","冒险","机甲"]',
                "genres": '["科幻","冒险"]',
                "rating": 8.4,
                "episodes": [
                    {"number": 1, "title": "信号", "vod_url": '[{"url":"https://user-images.githubusercontent.com/28951144/229373695-22f88f13-d18f-4288-9bf1-c3e078d83722.mp4","type":"mp4","caption":"1080p"}]'},
                    {"number": 2, "title": "轨道都市", "vod_url": '[{"url":"https://user-images.githubusercontent.com/28951144/229373709-603a7a89-2105-4e1b-a5a5-a6c3567c9a59.mp4","type":"mp4","caption":"1080p"}]'},
                    {"number": 3, "title": "隐藏航线", "vod_url": '[{"url":"https://user-images.githubusercontent.com/28951144/229373716-76da0a4e-225a-44e4-3e9006dbc3e3.mp4","type":"mp4","caption":"1080p"}]'},
                ],
            },
            {
                "title": "山海流光",
                "summary": "现代修复师进入山海异境，寻找散落在古画里的神兽线索。",
                "type": "tv", "lang": "zh", "year": 2024, "status": 1,
                "tags": '["国风","奇幻","冒险"]',
                "genres": '["国风","奇幻"]',
                "rating": 8.8,
                "episodes": [
                    {"number": 1, "title": "古画异境", "vod_url": '[{"url":"https://user-images.githubusercontent.com/28951144/229373695-22f88f13-d18f-4288-9bf1-c3e078d83722.mp4","type":"mp4","caption":"1080p"}]'},
                ],
            },
            {
                "title": "夜幕骑士",
                "summary": "现代都市中隐藏着古老骑士团的后裔，他们在夜幕下保护世界。",
                "type": "movie", "lang": "ja", "year": 2023, "status": 1,
                "tags": '["动作","奇幻","都市"]',
                "genres": '["动作","奇幻"]',
                "rating": 7.9,
                "episodes": [
                    {"number": 1, "title": "正片", "vod_url": '[{"url":"https://user-images.githubusercontent.com/28951144/229373709-603a7a89-2105-4e1b-a5a5-a6c3567c9a59.mp4","type":"mp4","caption":"1080p"}]'},
                ],
            },
            {
                "title": "命运轮回",
                "summary": "在时间循环中寻找真相的高中生，每次轮回都会发现新的线索。",
                "type": "tv", "lang": "ja", "year": 2025, "status": 0,
                "tags": '["悬疑","推理","时间循环","校园"]',
                "genres": '["悬疑","推理"]',
                "rating": 9.1,
                "episodes": [
                    {"number": 1, "title": "第一次醒来", "vod_url": '[{"url":"https://user-images.githubusercontent.com/28951144/229373695-22f88f13-d18f-4288-9bf1-c3e078d83722.mp4","type":"mp4","caption":"1080p"}]'},
                    {"number": 2, "title": "既视感", "vod_url": '[{"url":"https://user-images.githubusercontent.com/28951144/229373709-603a7a89-2105-4e1b-a5a5-a6c3567c9a59.mp4","type":"mp4","caption":"1080p"}]'},
                ],
            },
            {
                "title": "琉璃之梦",
                "summary": "少女追寻着破碎的琉璃碎片穿梭于平行世界。",
                "type": "tv", "lang": "zh", "year": 2025, "status": 0,
                "tags": '["奇幻","治愈","平行世界"]',
                "genres": '["奇幻","治愈"]',
                "rating": 8.6,
                "episodes": [
                    {"number": 1, "title": "破碎琉璃", "vod_url": '[{"url":"https://user-images.githubusercontent.com/28951144/229373716-76da0a4e-225a-44e4-3e9006dbc3e3.mp4","type":"mp4","caption":"1080p"}]'},
                ],
            },
            {
                "title": "机械纪元 ZERO",
                "summary": "人类与AI共存的未来，一场突如其来的战争改变了世界的平衡。",
                "type": "tv", "lang": "ja", "year": 2025, "status": 0,
                "tags": '["科幻","战斗","AI","未来"]',
                "genres": '["科幻","战斗"]',
                "rating": 8.3,
                "episodes": [
                    {"number": 1, "title": "觉醒", "vod_url": '[{"url":"https://user-images.githubusercontent.com/28951144/229373695-22f88f13-d18f-4288-9bf1-c3e078d83722.mp4","type":"mp4","caption":"1080p"}]'},
                    {"number": 2, "title": "冲突", "vod_url": '[{"url":"https://user-images.githubusercontent.com/28951144/229373709-603a7a89-2105-4e1b-a5a5-a6c3567c9a59.mp4","type":"mp4","caption":"1080p"}]'},
                ],
            },
        ]

        for ad in anime_data:
            episodes = ad.pop("episodes", [])
            bangumi = Bangumi(**ad)
            session.add(bangumi)
            await session.flush()

            for ep in episodes:
                session.add(BangumiEpisode(bangumi_id=bangumi.id, **ep))

            # 添加角色
            if ad["title"] == "星港回声":
                session.add(Character(bangumi_id=bangumi.id, name="星辰", role="主角", avatar_url="", summary="追寻信号源的少年", seiyuu="花江夏树"))
                session.add(Character(bangumi_id=bangumi.id, name="月影", role="女主角", avatar_url="", summary="谜之少女", seiyuu="早见沙织"))
            elif ad["title"] == "山海流光":
                session.add(Character(bangumi_id=bangumi.id, name="画卷", role="主角", avatar_url="", summary="古籍修复师", seiyuu=""))

        # 添加示例帖子
        threads_data = [
            {"title": "星港回声 角色设定集", "body": "分享一些官方的角色设定资料...", "tags": '["cosplay","artwork"]', "nsfw": False},
            {"title": "山海流光 海报合集", "body": "官方发布的高清海报...", "tags": '["artwork"]', "nsfw": False},
            {"title": "COS 夜幕骑士", "body": "还原了骑士装甲的细节...", "tags": '["cosplay"]', "nsfw": False},
        ]
        for td in threads_data:
            thread = Thread(**td)
            session.add(thread)

        await session.commit()
        print("[seed] 已插入示例数据")
