"""
AniCh API 复刻 — FastAPI 后端入口

启动方式:
  cd server && uvicorn server.main:app --reload --host 0.0.0.0 --port 8000
"""

from contextlib import asynccontextmanager

from fastapi import Depends, HTTPException, Query
from fastapi.responses import JSONResponse
from sqlalchemy import func, select
from sqlalchemy.orm import selectinload
from sqlalchemy.ext.asyncio import AsyncSession

from .database import (
    async_session, init_db,
    User,
    Bangumi, BangumiEpisode,
    Character, Person,
    Thread,
    PlayHistory,
)
from . import protobuf_encoder as pb
from .scheduler import scheduler
from .aggregator import aggregator
from .m3u8_resolver import resolver as m3u8_resolver
from .catalog import catalog_service
from .playback import playback_service
from .app import create_app
from .dependencies import get_session
from .legacy_protocol import bangumi_to_dict as _bangumi_to_dict
from .legacy_protocol import protobuf_bytes as _pb_bytes

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
# 角色 & 人物
# ────────────────────────────────────────────────────────────

@app.get("/bangumi/characters/{id}")
async def bangumi_characters(id: int, session: AsyncSession = Depends(get_session)):
    """角色列表 — protobuf."""
    result = await session.execute(
        select(Character).where(Character.bangumi_id == id)
    )
    items = [
        {"id": c.id, "name": c.name, "role": c.role, "avatar": c.avatar_url, "summary": c.summary}
        for c in result.scalars().all()
    ]
    return _pb_bytes(pb.encode_characters_list(items))


@app.get("/bangumi/character/{id}")
async def character_detail(id: int, session: AsyncSession = Depends(get_session)):
    """角色详情 — JSON."""
    result = await session.execute(select(Character).where(Character.id == id))
    c = result.scalar_one_or_none()
    if not c:
        raise HTTPException(404)
    return JSONResponse({
        "id": c.id, "name": c.name, "role": c.role,
        "avatar_url": c.avatar_url, "summary": c.summary, "seiyuu": c.seiyuu,
    })


@app.get("/bangumi/character/{id}/bangumi")
async def character_bangumi(
    id: int, skip: int = Query(0),
    session: AsyncSession = Depends(get_session),
):
    """角色作品列表 — JSON."""
    result = await session.execute(select(Character).where(Character.id == id))
    c = result.scalar_one_or_none()
    if not c:
        raise HTTPException(404)

    result = await session.execute(
        select(Bangumi).options(selectinload(Bangumi.episodes)).where(Bangumi.id == c.bangumi_id)
    )
    items = [_bangumi_to_dict(b) for b in result.scalars().all()]
    return JSONResponse(items)


@app.get("/bangumi/persons/{id}")
async def bangumi_persons(id: int, session: AsyncSession = Depends(get_session)):
    """制作人员 — protobuf."""
    result = await session.execute(
        select(Person).where(Person.bangumi_id == id)
    )
    items = [
        {"id": p.id, "name": p.name, "role": p.role, "avatar": p.avatar_url, "summary": p.summary}
        for p in result.scalars().all()
    ]
    return _pb_bytes(pb.encode_persons_list(items))


@app.get("/bangumi/person/{id}")
async def person_detail(id: int, session: AsyncSession = Depends(get_session)):
    """人物详情 — JSON."""
    result = await session.execute(select(Person).where(Person.id == id))
    p = result.scalar_one_or_none()
    if not p:
        raise HTTPException(404)
    return JSONResponse({
        "id": p.id, "name": p.name, "role": p.role,
        "avatar_url": p.avatar_url, "summary": p.summary,
    })


@app.get("/bangumi/person/{id}/bangumi")
async def person_bangumi(
    id: int, skip: int = Query(0),
    session: AsyncSession = Depends(get_session),
):
    """人物作品列表 — JSON."""
    result = await session.execute(select(Person).where(Person.id == id))
    p = result.scalar_one_or_none()
    if not p:
        raise HTTPException(404)

    result = await session.execute(
        select(Bangumi).options(selectinload(Bangumi.episodes)).where(Bangumi.id == p.bangumi_id)
    )
    items = [_bangumi_to_dict(b) for b in result.scalars().all()]
    return JSONResponse(items)


# ────────────────────────────────────────────────────────────
# 搜索
# ────────────────────────────────────────────────────────────

@app.get("/search")
async def search_picture(
    keyword: str = Query(""),
    skip: int = Query(0),
    session: AsyncSession = Depends(get_session),
):
    """搜索帖子/图片 — protobuf."""
    stmt = select(Thread).options(selectinload(Thread.images)).where(
        Thread.title.contains(keyword) | Thread.tags.contains(keyword)
    ).offset(skip).limit(30)
    result = await session.execute(stmt)
    threads = result.scalars().all()

    items = []
    for t in threads:
        for img in t.images:
            items.append({
                "color": img.color, "width": img.width, "height": img.height, "image": img.master or img.original,
            })
    return _pb_bytes(pb.encode_images_list(items))


@app.get("/bangumi/search")
async def search_bangumi(
    keyword: str = Query(""),
    skip: int = Query(0),
    session: AsyncSession = Depends(get_session),
):
    """搜索番剧 — protobuf."""
    stmt = select(Bangumi).options(selectinload(Bangumi.episodes)).where(
        Bangumi.title.contains(keyword)
    ).offset(skip).limit(20)
    result = await session.execute(stmt)
    items = [_bangumi_to_dict(b) for b in result.scalars().all()]
    return _pb_bytes(pb.encode_bangumi_list(items))


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
