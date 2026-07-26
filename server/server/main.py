"""
AniCh API 复刻 — FastAPI 后端入口

启动方式:
  cd server && uvicorn server.main:app --reload --host 0.0.0.0 --port 8000
"""

import json
import logging
import math
import secrets
import time
from typing import Optional

from fastapi import FastAPI, Query, Request, Depends, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import Response, JSONResponse
from sqlalchemy import select, func, delete, and_
from sqlalchemy.orm import selectinload
from sqlalchemy.ext.asyncio import AsyncSession

from .config import ADMIN_TOKEN, CORS_ORIGINS
from .database import (
    async_session, init_db,
    User, UserToken, VerifyCode,
    Bangumi, BangumiEpisode, BangumiCollection,
    Character, Person,
    Danmaku,
    Thread, ThreadImage, ThreadCollection, ThreadLike,
    Comment, CommentLike,
    PlayHistory, PlaybackCache, upsert_playback_cache,
)
from .auth import (
    hash_password, verify_password, create_jwt, decode_jwt,
    generate_verify_code, parse_protobuf_token, get_current_user,
)
from . import protobuf_encoder as pb
from .scheduler import scheduler
from .scrapers import registry as scraper_registry
from .metadata_sync import sync_all_pending, sync_service
from .aggregator import aggregator
from .m3u8_resolver import resolver as m3u8_resolver
from .catalog import catalog_service, parse_stable_id
from .playback import playback_service

logger = logging.getLogger(__name__)

app = FastAPI(title="Zeluna API", version="3.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=CORS_ORIGINS,
    allow_credentials="*" not in CORS_ORIGINS,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.on_event("startup")
async def startup():
    await init_db()
    # 启动爬虫调度器
    await scheduler.start()
    await _seed_data()


@app.on_event("shutdown")
async def shutdown():
    await scheduler.stop()
    await aggregator.aclose()
    await catalog_service.aclose()


async def get_session():
    async with async_session() as session:
        yield session


async def require_admin(request: Request):
    """管理端点默认关闭；生产环境必须通过环境变量显式配置。"""
    supplied = request.headers.get("X-Zeluna-Admin", "").strip()
    if not ADMIN_TOKEN or not secrets.compare_digest(supplied, ADMIN_TOKEN):
        raise HTTPException(status_code=404, detail="Not found")


# ────────────────────────────────────────────────────────────
# 账户
# ────────────────────────────────────────────────────────────

@app.post("/login")
async def login(request: Request, session: AsyncSession = Depends(get_session)):
    """登录 — protobuf 响应."""
    body = await request.body()
    decoded = _pb_login_request(body)

    stmt = select(User).where(User.email == decoded.get("user", ""))
    result = await session.execute(stmt)
    user = result.scalar_one_or_none()

    if not user or not verify_password(decoded.get("password", ""), user.password_hash):
        return _pb_bytes(pb.encode_login_response({}, ""))

    jwt_token = create_jwt(user.id)
    user_token = UserToken(user_id=user.id, token=jwt_token)
    session.add(user_token)
    await session.commit()

    user_dict = _user_to_dict(user)
    return _pb_bytes(pb.encode_login_response(user_dict, jwt_token))


@app.post("/code")
async def send_code(request: Request, session: AsyncSession = Depends(get_session)):
    """发送验证码."""
    try:
        form = await request.form()
        email = form.get("email", "")
    except Exception:
        body = await request.json()
        email = body.get("email", "")

    if not email:
        return JSONResponse({"error": True, "message": "邮箱不能为空"})

    code = generate_verify_code()
    expires = time.time() + 600  # 10 分钟有效
    vc = VerifyCode(email=email, code=code, expires_at=expires)
    session.add(vc)
    await session.commit()

    print(f"[CODE] {email} -> {code}")  # 生产环境应发送邮件
    return JSONResponse({"error": False, "message": "验证码已发送"})


@app.post("/register")
async def register(request: Request, session: AsyncSession = Depends(get_session)):
    """注册 — protobuf 响应."""
    body = await request.body()
    decoded = _pb_login_request(body)  # register_request_ 结构与 login_request_ 类似

    email = decoded.get("email", "")
    code = decoded.get("code", "")
    name = decoded.get("name", "")
    password = decoded.get("password", "")

    if not all([email, code, name, password]):
        return _pb_bytes(pb.encode_login_response({}, ""))

    # 验证码
    stmt = select(VerifyCode).where(
        VerifyCode.email == email,
        VerifyCode.code == code,
        VerifyCode.expires_at > time.time(),
    )
    result = await session.execute(stmt)
    vc = result.scalar_one_or_none()
    if not vc:
        return _pb_bytes(pb.encode_login_response({}, ""))

    # 检查重复
    for check_stmt in [
        select(User).where(User.email == email),
        select(User).where(User.name == name),
    ]:
        result = await session.execute(check_stmt)
        if result.scalar_one_or_none():
            return _pb_bytes(pb.encode_login_response({}, ""))

    user = User(
        email=email,
        name=name,
        password_hash=hash_password(password),
    )
    session.add(user)
    await session.commit()
    await session.refresh(user)

    jwt_token = create_jwt(user.id)
    user_token = UserToken(user_id=user.id, token=jwt_token)
    session.add(user_token)
    await session.delete(vc)
    await session.commit()

    user_dict = _user_to_dict(user)
    return _pb_bytes(pb.encode_login_response(user_dict, jwt_token))


@app.post("/user/check")
async def check_user(request: Request, session: AsyncSession = Depends(get_session)):
    """检查邮箱/用户名可用性."""
    try:
        form = await request.form()
    except Exception:
        form = await request.json()
    email = form.get("email", "")
    name = form.get("name", "")

    if email:
        result = await session.execute(select(User).where(User.email == email))
        if result.scalar_one_or_none():
            return JSONResponse({"error": True, "message": "邮箱已被注册"})
    if name:
        result = await session.execute(select(User).where(User.name == name))
        if result.scalar_one_or_none():
            return JSONResponse({"error": True, "message": "用户名已被使用"})

    return JSONResponse({"error": False, "message": "可用"})


@app.post("/change_password")
async def change_password(request: Request, session: AsyncSession = Depends(get_session)):
    """修改密码."""
    body = await request.body()
    decoded = _pb_login_request(body)
    email = decoded.get("email", "")
    code = decoded.get("code", "")
    password = decoded.get("password", "")

    stmt = select(VerifyCode).where(
        VerifyCode.email == email,
        VerifyCode.code == code,
        VerifyCode.expires_at > time.time(),
    )
    result = await session.execute(stmt)
    vc = result.scalar_one_or_none()
    if not vc:
        return JSONResponse({"error": True, "message": "验证码无效"})

    result = await session.execute(select(User).where(User.email == email))
    user = result.scalar_one_or_none()
    if not user:
        return JSONResponse({"error": True, "message": "用户不存在"})

    user.password_hash = hash_password(password)
    user.updated_at = time.time()
    await session.delete(vc)
    await session.commit()

    return JSONResponse({"error": False, "message": "密码修改成功"})


@app.get("/init")
async def init_user(request: Request, session: AsyncSession = Depends(get_session)):
    """获取用户信息 — protobuf 响应."""
    token_header = request.headers.get("_", "")
    user = await get_current_user(token_header, session)
    if not user:
        return _pb_bytes(pb.encode_init_response({}))

    user_dict = _user_to_dict(user)
    return _pb_bytes(pb.encode_init_response(user_dict))


# ────────────────────────────────────────────────────────────
# 番剧
# ────────────────────────────────────────────────────────────

@app.get("/bangumi/list")
async def bangumi_list(
    skip: int = Query(0),
    type: str = Query(None),
    lang: str = Query(None),
    year: int = Query(None),
    genre: str = Query(None),
    mark: str = Query(None),
    session: AsyncSession = Depends(get_session),
):
    """番剧列表 — protobuf 响应."""
    stmt = select(Bangumi).options(selectinload(Bangumi.episodes)).limit(40).offset(skip)
    if type:
        stmt = stmt.where(Bangumi.type == type)
    if lang:
        stmt = stmt.where(Bangumi.lang == lang)
    if year:
        stmt = stmt.where(Bangumi.year == year)

    result = await session.execute(stmt)
    bangumi_list = result.scalars().all()

    items = [_bangumi_to_dict(b) for b in bangumi_list]
    return _pb_bytes(pb.encode_bangumi_list(items))


@app.get("/bangumi/tag")
async def bangumi_tags(
    type: str = Query("genre"),
    skip: int = Query(0),
    session: AsyncSession = Depends(get_session),
):
    """番剧标签 — JSON 响应."""
    result = await session.execute(select(Bangumi).limit(100))
    all_bangumi = result.scalars().all()

    genre_counts: dict[str, int] = {}
    for b in all_bangumi:
        try:
            genres = json.loads(b.genres or "[]")
        except (json.JSONDecodeError, TypeError):
            genres = []
        for g in genres:
            genre_counts[g] = genre_counts.get(g, 0) + 1

    tags = [
        {"id": i + 1, "name": name, "count": count}
        for i, (name, count) in enumerate(sorted(genre_counts.items()))
    ]
    return JSONResponse(tags)


@app.get("/bangumi/latest")
async def bangumi_latest(session: AsyncSession = Depends(get_session)):
    """最新番剧 — protobuf 响应."""
    stmt = select(Bangumi).options(selectinload(Bangumi.episodes)).order_by(Bangumi.updated_at.desc()).limit(20)
    result = await session.execute(stmt)
    items = [_bangumi_to_dict(b) for b in result.scalars().all()]
    return _pb_bytes(pb.encode_bangumi_list(items))


@app.get("/bangumi/detail/{id}")
async def bangumi_detail(id: int, session: AsyncSession = Depends(get_session)):
    """番剧详情 — JSON 响应."""
    result = await session.execute(select(Bangumi).where(Bangumi.id == id))
    bangumi = result.scalar_one_or_none()
    if not bangumi:
        raise HTTPException(404, "番剧不存在")

    episodes_result = await session.execute(
        select(BangumiEpisode).where(BangumiEpisode.bangumi_id == id).order_by(BangumiEpisode.number)
    )
    episodes = episodes_result.scalars().all()

    tags = json.loads(bangumi.tags or "[]") if bangumi.tags else []
    genres = json.loads(bangumi.genres or "[]") if bangumi.genres else []

    return JSONResponse({
        "id": bangumi.id,
        "title": bangumi.title,
        "summary": bangumi.summary,
        "cover_url": bangumi.cover_url,
        "banner_url": bangumi.banner_url,
        "type": bangumi.type,
        "lang": bangumi.lang,
        "year": bangumi.year,
        "status": bangumi.status,
        "tags": tags,
        "genres": genres,
        "rating": bangumi.rating,
        "rating_count": bangumi.rating_count,
        "episode_count": len(episodes),
        "episodes": [
            {
                "id": ep.id,
                "number": ep.number,
                "title": ep.title,
                "duration": ep.duration,
            }
            for ep in episodes
        ],
        "created_at": bangumi.created_at,
        "updated_at": bangumi.updated_at,
    })


@app.get("/bangumi/episodes/{id}")
async def bangumi_episodes(id: int, session: AsyncSession = Depends(get_session)):
    """剧集列表 — protobuf 响应."""
    result = await session.execute(
        select(BangumiEpisode).where(BangumiEpisode.bangumi_id == id).order_by(BangumiEpisode.number)
    )
    episodes = result.scalars().all()

    items = []
    for ep in episodes:
        vod_data = []
        try:
            vod_data = json.loads(ep.vod_url or "[]")
        except (json.JSONDecodeError, TypeError):
            vod_data = [{"url": ep.vod_url, "type": "auto", "caption": f"EP{ep.number}"}]
        items.extend(vod_data)

    return _pb_bytes(pb.encode_episodes_list(items))


@app.get("/bangumi/related/{id}")
async def bangumi_related(id: int, session: AsyncSession = Depends(get_session)):
    """相关推荐 — protobuf 响应."""
    bangumi = (await session.execute(select(Bangumi).where(Bangumi.id == id))).scalar_one_or_none()
    if not bangumi:
        return _pb_bytes(pb.encode_related_list([]))

    result = await session.execute(
        select(Bangumi).options(selectinload(Bangumi.episodes)).where(Bangumi.id != id).limit(10)
    )
    items = [_bangumi_to_dict(b) for b in result.scalars().all()]
    return _pb_bytes(pb.encode_related_list(items))


@app.get("/vod/{id}/{episode}")
async def vod_detail(id: int, episode: int, session: AsyncSession = Depends(get_session)):
    """视频详情 — JSON 响应."""
    result = await session.execute(
        select(BangumiEpisode).where(
            BangumiEpisode.bangumi_id == id,
            BangumiEpisode.number == episode,
        )
    )
    ep = result.scalar_one_or_none()
    if not ep:
        raise HTTPException(404, "剧集不存在")

    vod_data = []
    try:
        vod_data = json.loads(ep.vod_url or "[]")
    except (json.JSONDecodeError, TypeError):
        vod_data = [{"url": ep.vod_url, "type": "auto", "caption": f"EP{ep.number}"}]

    return JSONResponse({
        "id": ep.id,
        "bangumi_id": ep.bangumi_id,
        "number": ep.number,
        "title": ep.title,
        "vod": vod_data,
    })


# ────────────────────────────────────────────────────────────
# 弹幕
# ────────────────────────────────────────────────────────────

@app.get("/danmaku")
async def get_danmaku(
    bangumi: int = Query(0),
    episode: int = Query(0),
    skip: int = Query(0),
    session: AsyncSession = Depends(get_session),
):
    """获取弹幕 — protobuf 响应."""
    stmt = select(Danmaku).options(selectinload(Danmaku.user)).where(
        Danmaku.bangumi_id == bangumi,
        Danmaku.episode_id == episode,
    ).order_by(Danmaku.time).offset(skip).limit(200)
    result = await session.execute(stmt)
    items = result.scalars().all()

    danmaku_list = [
        {
            "id": d.danmaku_id or str(d.id),
            "color": d.color,
            "date": d.date,
            "text": d.text,
            "t": "",
            "time": d.time,
            "type": d.type,
            "from": d.user.name if d.user else "",
        }
        for d in items
    ]
    return _pb_bytes(pb.encode_danmaku_list(danmaku_list))


@app.post("/danmaku")
async def post_danmaku(
    request: Request,
    bangumi: int = Query(0),
    episode: int = Query(0),
    session: AsyncSession = Depends(get_session),
):
    """发送弹幕."""
    token_header = request.headers.get("_", "")
    user = await get_current_user(token_header, session)
    if not user:
        raise HTTPException(401, "请先登录")

    try:
        body = await request.form()
    except Exception:
        body = await request.json()

    danmaku = Danmaku(
        bangumi_id=bangumi,
        episode_id=episode,
        user_id=user.id,
        type=int(body.get("type", 0)),
        time=float(body.get("time", 0.0)),
        text=str(body.get("text", "")),
        color=str(body.get("color", "#FFFFFF")),
        danmaku_id=str(int(time.time() * 1000)),
    )
    session.add(danmaku)
    await session.commit()

    return JSONResponse({"error": False, "message": "弹幕已发送"})


# ────────────────────────────────────────────────────────────
# 收藏 (番剧)
# ────────────────────────────────────────────────────────────

@app.get("/bangumi/{id}/collect/status")
async def collect_status(
    id: int,
    request: Request,
    session: AsyncSession = Depends(get_session),
):
    user = await get_current_user(request.headers.get("_", ""), session)
    if not user:
        return JSONResponse({"collected": False, "type": ""})

    result = await session.execute(
        select(BangumiCollection).where(
            BangumiCollection.user_id == user.id,
            BangumiCollection.bangumi_id == id,
        )
    )
    col = result.scalar_one_or_none()
    return JSONResponse({
        "collected": col is not None,
        "type": col.type if col else "",
    })


@app.get("/bangumi/{id}/collect/{type}")
async def change_collect(
    id: int,
    type: str,
    request: Request,
    session: AsyncSession = Depends(get_session),
):
    user = await get_current_user(request.headers.get("_", ""), session)
    if not user:
        raise HTTPException(401)

    result = await session.execute(
        select(BangumiCollection).where(
            BangumiCollection.user_id == user.id,
            BangumiCollection.bangumi_id == id,
        )
    )
    existing = result.scalar_one_or_none()

    if existing:
        existing.type = type
    else:
        col = BangumiCollection(user_id=user.id, bangumi_id=id, type=type)
        session.add(col)
    await session.commit()

    return JSONResponse({"error": False, "message": "收藏成功"})


@app.delete("/bangumi/{id}/collect/cancel")
async def cancel_collect(
    id: int,
    request: Request,
    session: AsyncSession = Depends(get_session),
):
    user = await get_current_user(request.headers.get("_", ""), session)
    if not user:
        raise HTTPException(401)

    await session.execute(
        delete(BangumiCollection).where(
            BangumiCollection.user_id == user.id,
            BangumiCollection.bangumi_id == id,
        )
    )
    await session.commit()
    return JSONResponse({"error": False, "message": "已取消收藏"})


@app.get("/action/collect/{type}")
async def collect_list(
    type: str,
    request: Request,
    page: int = Query(1),
    session: AsyncSession = Depends(get_session),
):
    user = await get_current_user(request.headers.get("_", ""), session)
    if not user:
        raise HTTPException(401)

    stmt = (
        select(BangumiCollection, Bangumi)
        .join(Bangumi, BangumiCollection.bangumi_id == Bangumi.id)
        .options(selectinload(Bangumi.episodes))
        .where(BangumiCollection.user_id == user.id, BangumiCollection.type == type)
        .offset((page - 1) * 20)
        .limit(20)
    )
    result = await session.execute(stmt)
    rows = result.all()

    items = [
        {
            **_bangumi_to_dict(row[1]),
            "collection_type": row[0].type,
        }
        for row in rows
    ]
    return JSONResponse(items)


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
# 帖子 / 图片社区
# ────────────────────────────────────────────────────────────

@app.get("/latest")
async def thread_latest(
    sort: int = Query(-1),
    type: str = Query("all"),
    skip: int = Query(0),
    session: AsyncSession = Depends(get_session),
):
    """最新帖子 — protobuf."""
    stmt = select(Thread).options(selectinload(Thread.images)).order_by(Thread.created_at.desc()).offset(skip).limit(30)
    if type != "all":
        try:
            filter_tags = json.dumps([type])
        except Exception:
            filter_tags = type
        stmt = stmt.where(Thread.tags.contains(filter_tags))

    result = await session.execute(stmt)
    threads = result.scalars().all()

    items = []
    for t in threads:
        image_dict = {}
        if t.images:
            first_img = t.images[0]
            image_dict = {
                "image": first_img.master or first_img.original,
                "color": first_img.color,
                "width": first_img.width,
                "height": first_img.height,
            }
        items.append({
            "id": t.id,
            "ai": t.ai,
            "nsfw": t.nsfw,
            "title": t.title,
            "count": t.images[0].id if t.images else 1,
            **image_dict,
        })
    return _pb_bytes(pb.encode_thread_list(items))


@app.get("/tags")
async def thread_tags(skip: int = Query(0), session: AsyncSession = Depends(get_session)):
    """标签列表 — JSON."""
    return JSONResponse([
        {"id": 1, "name": "cosplay", "count": 50},
        {"id": 2, "name": "artwork", "count": 30},
        {"id": 3, "name": "all", "count": 100},
    ])


@app.get("/t/{tag}/info")
async def tag_info(tag: str, session: AsyncSession = Depends(get_session)):
    """标签信息 — protobuf."""
    result = await session.execute(select(Thread))
    count = len([t for t in result.scalars().all() if tag in (t.tags or "")])

    info = {"title": tag, "description": f"#{tag}", "count": count, "nsfw": False}
    return _pb_bytes(pb.encode_tag_info_response(info))


@app.get("/t/{tag}")
async def tag_list(
    tag: str,
    type: str = Query("all"),
    sort: int = Query(-1),
    skip: int = Query(0),
    session: AsyncSession = Depends(get_session),
):
    """标签帖子列表 — protobuf."""
    result = await session.execute(
        select(Thread).options(selectinload(Thread.images)).order_by(Thread.created_at.desc()).offset(skip).limit(30)
    )
    threads = [t for t in result.scalars().all() if tag in (t.tags or "")]

    items = []
    for t in threads:
        image_dict = {}
        if t.images:
            first_img = t.images[0]
            image_dict = {
                "image": first_img.master or first_img.original,
                "color": first_img.color,
                "width": first_img.width,
                "height": first_img.height,
            }
        items.append({
            "id": t.id, "ai": t.ai, "nsfw": t.nsfw,
            "title": t.title,
            "count": t.images[0].id if t.images else 1,
            **image_dict,
        })
    return _pb_bytes(pb.encode_thread_list(items))


@app.get("/r/{id}")
async def thread_detail(id: int, session: AsyncSession = Depends(get_session)):
    """帖子详情 — protobuf."""
    result = await session.execute(select(Thread).options(selectinload(Thread.images)).where(Thread.id == id))
    t = result.scalar_one_or_none()
    if not t:
        raise HTTPException(404)

    item = {
        "id": t.id, "title": t.title, "body": t.body,
        "tags": t.tags, "nsfw": t.nsfw,
        "images": [
            {
                "color": img.color, "height": img.height, "width": img.width,
                "original": img.original, "master": img.master,
                "original_size": img.original_size, "master_size": img.master_size,
            }
            for img in t.images
        ],
    }
    return _pb_bytes(pb.encode_thread_detail(item))


# ────────────────────────────────────────────────────────────
# 帖子收藏/喜欢
# ────────────────────────────────────────────────────────────

@app.get("/r/{id}/collect/status")
async def thread_collect_status(id: int, request: Request, session: AsyncSession = Depends(get_session)):
    user = await get_current_user(request.headers.get("_", ""), session)
    if not user:
        return JSONResponse({"collected": False})
    result = await session.execute(
        select(ThreadCollection).where(
            ThreadCollection.user_id == user.id, ThreadCollection.thread_id == id
        )
    )
    return JSONResponse({"collected": result.scalar_one_or_none() is not None})


@app.get("/r/{id}/collect")
async def thread_collect(id: int, request: Request, session: AsyncSession = Depends(get_session)):
    user = await get_current_user(request.headers.get("_", ""), session)
    if not user:
        raise HTTPException(401)
    existing = (await session.execute(
        select(ThreadCollection).where(ThreadCollection.user_id == user.id, ThreadCollection.thread_id == id)
    )).scalar_one_or_none()
    if not existing:
        session.add(ThreadCollection(user_id=user.id, thread_id=id))
        await session.commit()
    return JSONResponse({"error": False})


@app.delete("/r/{id}/collect/cancel")
async def thread_collect_cancel(id: int, request: Request, session: AsyncSession = Depends(get_session)):
    user = await get_current_user(request.headers.get("_", ""), session)
    if not user:
        raise HTTPException(401)
    await session.execute(
        delete(ThreadCollection).where(ThreadCollection.user_id == user.id, ThreadCollection.thread_id == id)
    )
    await session.commit()
    return JSONResponse({"error": False})


@app.get("/r/{id}/like/status")
async def thread_like_status(id: int, request: Request, session: AsyncSession = Depends(get_session)):
    user = await get_current_user(request.headers.get("_", ""), session)
    if not user:
        return JSONResponse({"liked": False})
    result = await session.execute(
        select(ThreadLike).where(ThreadLike.user_id == user.id, ThreadLike.thread_id == id)
    )
    return JSONResponse({"liked": result.scalar_one_or_none() is not None})


@app.get("/r/{id}/like")
async def thread_like(id: int, request: Request, session: AsyncSession = Depends(get_session)):
    user = await get_current_user(request.headers.get("_", ""), session)
    if not user:
        raise HTTPException(401)
    existing = (await session.execute(
        select(ThreadLike).where(ThreadLike.user_id == user.id, ThreadLike.thread_id == id)
    )).scalar_one_or_none()
    if not existing:
        session.add(ThreadLike(user_id=user.id, thread_id=id))
        await session.commit()
    return JSONResponse({"error": False})


@app.delete("/r/{id}/like/cancel")
async def thread_like_cancel(id: int, request: Request, session: AsyncSession = Depends(get_session)):
    user = await get_current_user(request.headers.get("_", ""), session)
    if not user:
        raise HTTPException(401)
    await session.execute(
        delete(ThreadLike).where(ThreadLike.user_id == user.id, ThreadLike.thread_id == id)
    )
    await session.commit()
    return JSONResponse({"error": False})


@app.get("/action/collects/{type}")
async def thread_collect_list(
    type: str, request: Request, page: int = Query(1),
    session: AsyncSession = Depends(get_session),
):
    user = await get_current_user(request.headers.get("_", ""), session)
    if not user:
        raise HTTPException(401)
    result = await session.execute(
        select(ThreadCollection).where(ThreadCollection.user_id == user.id)
        .offset((page - 1) * 20).limit(20)
    )
    ids = [row.thread_id for row in result.scalars().all()]
    threads = (await session.execute(
        select(Thread).options(selectinload(Thread.images)).where(Thread.id.in_(ids))
    )).scalars().all() if ids else []

    items = []
    for t in threads:
        image_dict = {}
        if t.images:
            fi = t.images[0]
            image_dict = {"image": fi.master or fi.original, "color": fi.color, "width": fi.width, "height": fi.height}
        items.append({
            "id": t.id, "ai": t.ai, "nsfw": t.nsfw,
            "title": t.title, "count": t.images[0].id if t.images else 1,
            **image_dict,
        })
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
# 评论
# ────────────────────────────────────────────────────────────

@app.get("/comment")
async def get_comments(
    type: str = Query("thread"),
    id: str = Query(""),
    skip: int = Query(0),
    request: Request = None,
    session: AsyncSession = Depends(get_session),
):
    """评论列表 — JSON."""
    stmt = select(Comment).where(
        Comment.type == type,
        Comment.target_id == id,
        Comment.parent_id == "",
    ).order_by(Comment.created_at.desc()).offset(skip).limit(30)
    result = await session.execute(stmt)
    comments = result.scalars().all()

    items = []
    for c in comments:
        user = (await session.execute(select(User).where(User.id == c.user_id))).scalar_one_or_none()
        # Check if current user liked this comment
        user_liked = False
        token_header = request.headers.get("_", "") if request else ""
        if token_header:
            current_user = await get_current_user(token_header, session)
            if current_user:
                like = (await session.execute(
                    select(CommentLike).where(
                        CommentLike.user_id == current_user.id,
                        CommentLike.comment_id == c.id,
                    )
                )).scalar_one_or_none()
                user_liked = like is not None

        contents = []
        try:
            contents = json.loads(c.contents or "[]")
        except (json.JSONDecodeError, TypeError):
            contents = [c.contents] if c.contents else []

        items.append({
            "id": str(c.id),
            "user": {
                "id": user.id if user else 0,
                "name": user.name if user else "匿名",
                "avatar": user.avatar if user else "",
            },
            "contents": contents,
            "like_count": c.like_count,
            "user_liked": user_liked,
            "created_at": c.created_at,
            "parent_id": c.parent_id,
            "reply_to": c.reply_to,
        })
    return JSONResponse(items)


@app.post("/comment")
async def post_comment(request: Request, session: AsyncSession = Depends(get_session)):
    """发送评论."""
    token_header = request.headers.get("_", "")
    user = await get_current_user(token_header, session)
    if not user:
        raise HTTPException(401)

    body = await request.json()
    comment = Comment(
        type=body.get("type", "thread"),
        target_id=str(body.get("id", "")),
        user_id=user.id,
        parent_id=str(body.get("parent", "")),
        reply_to=str(body.get("reply", "")),
        contents=json.dumps(body.get("contents", []), ensure_ascii=False),
    )
    session.add(comment)
    await session.commit()
    await session.refresh(comment)
    return JSONResponse({"id": str(comment.id), "error": False})


@app.get("/comment/{id}/replies")
async def comment_replies(
    id: str, skip: int = Query(0),
    request: Request = None,
    session: AsyncSession = Depends(get_session),
):
    """评论回复列表 — JSON."""
    stmt = select(Comment).where(
        Comment.parent_id == id,
    ).order_by(Comment.created_at).offset(skip).limit(20)
    result = await session.execute(stmt)
    comments = result.scalars().all()

    items = []
    for c in comments:
        user = (await session.execute(select(User).where(User.id == c.user_id))).scalar_one_or_none()
        contents = []
        try:
            contents = json.loads(c.contents or "[]")
        except (json.JSONDecodeError, TypeError):
            contents = [c.contents] if c.contents else []

        user_liked = False
        if request:
            token_header = request.headers.get("_", "")
            if token_header:
                current_user = await get_current_user(token_header, session)
                if current_user:
                    like = (await session.execute(
                        select(CommentLike).where(
                            CommentLike.user_id == current_user.id,
                            CommentLike.comment_id == c.id,
                        )
                    )).scalar_one_or_none()
                    user_liked = like is not None

        items.append({
            "id": str(c.id),
            "user": {"id": user.id if user else 0, "name": user.name if user else "匿名", "avatar": user.avatar if user else ""},
            "contents": contents,
            "like_count": c.like_count,
            "user_liked": user_liked,
            "created_at": c.created_at,
            "reply_to": c.reply_to,
        })
    return JSONResponse(items)


@app.get("/comment/like")
async def like_comment(
    id: str = Query(""),
    request: Request = None,
    session: AsyncSession = Depends(get_session),
):
    """点赞评论."""
    token_header = request.headers.get("_", "") if request else ""
    user = await get_current_user(token_header, session)
    if not user:
        raise HTTPException(401)

    existing = (await session.execute(
        select(CommentLike).where(CommentLike.user_id == user.id, CommentLike.comment_id == int(id))
    )).scalar_one_or_none()

    if not existing:
        session.add(CommentLike(user_id=user.id, comment_id=int(id)))
        comment = (await session.execute(select(Comment).where(Comment.id == int(id)))).scalar_one_or_none()
        if comment:
            comment.like_count += 1
        await session.commit()

    return JSONResponse({"error": False})


@app.delete("/comment/like")
async def cancel_like_comment(
    id: str = Query(""),
    request: Request = None,
    session: AsyncSession = Depends(get_session),
):
    """取消点赞评论."""
    token_header = request.headers.get("_", "") if request else ""
    user = await get_current_user(token_header, session)
    if not user:
        raise HTTPException(401)

    await session.execute(
        delete(CommentLike).where(CommentLike.user_id == user.id, CommentLike.comment_id == int(id))
    )
    comment = (await session.execute(select(Comment).where(Comment.id == int(id)))).scalar_one_or_none()
    if comment and comment.like_count > 0:
        comment.like_count -= 1
    await session.commit()
    return JSONResponse({"error": False})


# ────────────────────────────────────────────────────────────
# 辅助函数
# ────────────────────────────────────────────────────────────

def _pb_bytes(data: bytes) -> Response:
    return Response(content=data, media_type="application/octet-stream")


def _user_to_dict(user: User) -> dict:
    return {
        "id": user.id,
        "email": user.email,
        "name": user.name,
        "role": user.role,
        "sex": user.sex,
        "avatar": user.avatar,
        "exp": user.exp,
        "coin": user.coin,
        "color": user.color,
        "address": user.address,
        "created_at": user.created_at,
        "updated_at": user.updated_at,
    }


def _bangumi_to_dict(b: Bangumi) -> dict:
    return {
        "id": b.id,
        "title": b.title,
        "summary": b.summary,
        "cover_url": b.cover_url,
        "banner_url": b.banner_url,
        "type": b.type,
        "lang": b.lang,
        "year": b.year,
        "status": b.status,
        "tags": b.tags,
        "genres": b.genres,
        "rating": b.rating,
        "episode_count": len(b.episodes) if b.episodes else 0,
    }


def _pb_login_request(data: bytes) -> dict:
    """解析 login_request_ / register_request_ / change_password_request_ protobuf.
    字段: user/email(1), password(2), code(3), name(4)
    """
    fields = {}
    pos = 0
    while pos < len(data):
        if pos >= len(data):
            break
        tag = data[pos]
        pos += 1
        field_number = tag >> 3
        wire_type = tag & 0x07
        if wire_type == 2:
            if pos >= len(data):
                break
            length = data[pos]
            pos += 1
            value = data[pos: pos + length].decode("utf-8", errors="replace")
            pos += length
            if field_number == 1:
                fields["user"] = value
                fields["email"] = value  # register_request_ 的 email 在字段 1
            elif field_number == 2:
                fields["password"] = value
            elif field_number == 3:
                fields["code"] = value
            elif field_number == 4:
                fields["name"] = value
        elif wire_type == 0:
            value = 0
            shift = 0
            while pos < len(data):
                byte = data[pos]
                pos += 1
                value |= (byte & 0x7F) << shift
                if not (byte & 0x80):
                    break
                shift += 7
        else:
            break
    return fields


async def _seed_data():
    """初始化一些示例数据."""
    async with async_session() as session:
        # 检查是否已有数据
        result = await session.execute(select(func.count(User.id)))
        if result.scalar() > 0:
            return

        # 创建管理员
        admin = User(
            email="admin@anich.local",
            name="admin",
            password_hash=hash_password("admin123"),
            role="admin",
            sex="保密",
            exp=1000,
            coin=100,
            color="#FF6B6B",
        )
        session.add(admin)
        await session.flush()

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


# ────────────────────────────────────────────────────────────
# 爬虫管理端点
# ────────────────────────────────────────────────────────────

@app.get("/admin/scrapers", dependencies=[Depends(require_admin)])
async def list_scrapers():
    """列出所有爬虫"""
    scrapers = []
    for s in scraper_registry.all_scrapers:
        scrapers.append({
            "name": s.name,
            "content_types": s.content_types,
            "base_url": s.base_url,
        })
    return JSONResponse(scrapers)


@app.get("/admin/scrapers/search", dependencies=[Depends(require_admin)])
async def scraper_search(
    keyword: str = Query(""),
    content_type: str = Query(None),
):
    """通过爬虫搜索内容"""
    types = [content_type] if content_type else None
    results = await scraper_registry.search_all(keyword, types)
    return JSONResponse([
        {
            "scraper": name,
            "count": len(items),
            "items": [
                {
                    "source_id": item.source_id,
                    "title": item.title,
                    "cover_url": item.cover_url,
                    "type": item.type,
                    "lang": item.lang,
                    "year": item.year,
                    "episode_count": item.episode_count,
                }
                for item in items[:10]
            ],
        }
        for name, items in results
    ])


@app.post("/admin/scan", dependencies=[Depends(require_admin)])
async def trigger_scan(
    content_types: str = Query(None),
):
    """手动触发内容扫描"""
    types = content_types.split(",") if content_types else None
    await scheduler.scan_new_content(types)
    return JSONResponse({"message": "Scan triggered", "types": types})


@app.post("/admin/sync/metadata", dependencies=[Depends(require_admin)])
async def trigger_metadata_sync(
    content_types: str = Query(None),
):
    """手动触发元数据同步"""
    types = content_types.split(",") if content_types else None
    await sync_all_pending(types)
    return JSONResponse({"message": "Metadata sync triggered", "types": types})


@app.get("/admin/stats", dependencies=[Depends(require_admin)])
async def scheduler_stats():
    """调度器统计信息"""
    return JSONResponse({
        "scheduler": scheduler.stats,
        "scrapers": {
            name: {
                "subjects_found": s.subjects_found,
                "subjects_new": s.subjects_new,
                "duration_seconds": s.duration_seconds,
                "errors": s.errors,
                "finished_at": s.finished_at.isoformat() if s.finished_at else None,
            }
            for name, s in scraper_registry.stats.items()
        },
    })


@app.get("/check/api")
async def check_api():
    """API 配置检查 (兼容 AniCh 客户端)"""
    import os
    public = os.getenv("PUBLIC_BASE_URL", "http://localhost:8000").rstrip("/")
    return JSONResponse({
        "baseUrl": public,
        "bilibiliApiUrl": "https://bili-dm.emmmm.eu.org",
        "qqVideoApiUrl": "https://dm.video.qq.com",
        "dandanApiUrl": "https://dandan.emmmm.eu.org",
        "updateUrl": "https://api.github.com/repos/Sle2p/AniCh/releases/latest",
        "githubProxyUrl": "https://gh.llkk.cc",
        "apis": [public],
        "ghproxy": ["https://gh.llkk.cc"],
    })


@app.get("/vod/{id}/{episode}")
async def vod_from_scrapers(
    id: int,
    episode: int,
    session: AsyncSession = Depends(get_session),
):
    """从爬虫获取视频源 (覆盖原 VOD 端点)"""
    # 先从数据库获取番剧信息
    result = await session.execute(
        select(Bangumi).where(Bangumi.id == id)
    )
    bangumi = result.scalar_one_or_none()
    if not bangumi:
        raise HTTPException(404, "番剧不存在")

    # 从爬虫获取视频源
    source_id = bangumi.bangumi_id
    if not source_id:
        # 没有外部 ID, 返回数据库中的 vod_url
        result = await session.execute(
            select(BangumiEpisode).where(
                BangumiEpisode.bangumi_id == id,
                BangumiEpisode.number == episode,
            )
        )
        ep = result.scalar_one_or_none()
        vod_data = []
        if ep and ep.vod_url:
            try:
                vod_data = json.loads(ep.vod_url)
            except (json.JSONDecodeError, TypeError):
                vod_data = [{"url": ep.vod_url, "type": "auto", "caption": f"EP{ep.number}"}]

        return JSONResponse({
            "id": ep.id if ep else 0,
            "bangumi_id": id,
            "number": episode,
            "title": ep.title if ep else "",
            "vod": vod_data,
        })

    # 从爬虫获取
    lines = await scraper_registry.get_video_sources_all(
        source_id, episode,
    )

    vod_data = [
        {
            "url": line.url,
            "type": line.format or "auto",
            "caption": line.title or f"线路{i+1}",
        }
        for i, line in enumerate(lines)
    ]

    return JSONResponse({
        "id": 0,
        "bangumi_id": id,
        "number": episode,
        "title": "",
        "vod": vod_data,
    })


# ────────────────────────────────────────────────────────────
# 统一聚合 API (核心)
# ────────────────────────────────────────────────────────────

@app.get("/api/v2/search")
async def unified_search(
    keyword: str = Query(""),
    content_type: str = Query(None),
    max_results: int = Query(30),
):
    """
    统一搜索 - 聚合所有源。

    content_type: anime, tv, movie (逗号分隔)
    """
    types = content_type.split(",") if content_type else None
    results = await aggregator.search(keyword, types, max_results)

    return JSONResponse([
        {
            "id": r.id,
            "title": r.title,
            "original_title": r.original_title,
            "cover_url": r.cover_url,
            "banner_url": r.banner_url,
            "summary": r.summary,
            "content_type": r.content_type,
            "language": r.language,
            "year": r.year,
            "regions": r.regions,
            "genres": r.genres,
            "rating": r.rating,
            "rating_count": r.rating_count,
            "total_episodes": r.total_episodes,
            "status": r.status,
            "sources": r.sources,
        }
        for r in results
    ])


@app.get("/api/v2/episodes/{subject_id:path}")
async def unified_episodes(subject_id: str):
    """统一剧集列表"""
    episodes = await aggregator.get_episodes(subject_id)
    return JSONResponse([
        {"number": ep.number, "title": ep.title,
         "thumbnail": ep.thumbnail, "duration": ep.duration}
        for ep in episodes
    ])


@app.get("/api/v2/vod/{subject_id:path}")
async def unified_vod(
    subject_id: str,
    episode: int = Query(1),
    title: str = Query(""),
    session: AsyncSession = Depends(get_session),
):
    """
    统一视频源获取 - 返回所有可用播放线路。

    先查预爬缓存 (PlaybackCache): 命中且未过期则秒回验证过的活链;
    未命中再实时解析+可达性验证, 并回填缓存。
    """
    import time as _time
    CACHE_TTL = 6 * 3600  # 缓存 6 小时有效

    # 1. 查缓存
    result = await session.execute(
        select(PlaybackCache).where(
            PlaybackCache.subject_id == subject_id,
            PlaybackCache.episode == episode,
        )
    )
    row = result.scalar_one_or_none()
    if row and row.line_count > 0 and (_time.time() - row.verified_at) < CACHE_TTL:
        try:
            cached_lines = json.loads(row.lines_json)
            return JSONResponse([
                {"url": l.get("url", ""), "title": l.get("title", ""),
                 "quality": l.get("quality", ""),
                 "format": l.get("format", ""),
                 "source": l.get("source", ""),
                 "headers": l.get("headers", {}),
                 "cached": True}
                for l in cached_lines
            ])
        except (json.JSONDecodeError, TypeError):
            pass

    # 2. 未命中: 实时解析 + 可达性验证
    lines = await aggregator.resolve_verified_lines(
        subject_id, episode, title, verify=True
    )
    lines_data = [
        {"url": l.url, "title": l.title, "quality": l.quality,
         "format": l.format, "source": l.source, "headers": l.headers}
        for l in lines
    ]

    # 3. 回填缓存
    if lines_data:
        try:
            now = _time.time()
            await upsert_playback_cache(
                session,
                subject_id=subject_id,
                episode=episode,
                title=title,
                lines_json=json.dumps(lines_data, ensure_ascii=False),
                line_count=len(lines_data),
                verified_at=now,
            )
        except Exception as error:
            logger.warning("Playback cache write failed: %s", error)

    return JSONResponse([{**d, "cached": False} for d in lines_data])


@app.get("/api/v2/home")
async def unified_home():
    """统一首页推荐"""
    feed = await aggregator.get_home_feed()
    return JSONResponse(feed)


@app.get("/api/v2/resolve")
async def resolve_m3u8(
    url: str = Query(""),
    keyword: str = Query(""),
):
    """
    M3U8 解析端点

    给定一个视频站 URL 或关键词，返回解析出的 m3u8/mp4 地址。
    """
    if url:
        results = await m3u8_resolver.resolve_via_parse_services(url)
    elif keyword:
        results = await m3u8_resolver.search_and_resolve(keyword)
    else:
        results = []

    return JSONResponse([
        {"url": r["url"], "format": r.get("format", "hls"),
         "source": r.get("source", "unknown")}
        for r in results
    ])


# ────────────────────────────────────────────────────────────
# Zeluna v3：稳定作品 ID + 服务端元数据 + 服务端播放聚合
# ────────────────────────────────────────────────────────────

@app.get("/api/v3/status")
async def unified_status():
    return JSONResponse({
        "service": "zeluna",
        "version": 3,
        "providers": catalog_service.provider_status,
        "playback": "server-only",
    })


@app.get("/api/v3/catalog/search")
async def catalog_search(
    query: str = Query(""),
    content_type: str = Query("anime,tv,movie"),
    limit: int = Query(40, ge=1, le=100),
    session: AsyncSession = Depends(get_session),
):
    requested = [
        value.strip()
        for value in content_type.split(",")
        if value.strip() in {"anime", "tv", "movie"}
    ]
    return JSONResponse(
        await catalog_service.search(query, requested, session, limit=limit)
    )


@app.get("/api/v3/catalog/home/{content_type}")
async def catalog_home(
    content_type: str,
    limit: int = Query(60, ge=1, le=100),
    session: AsyncSession = Depends(get_session),
):
    if content_type not in {"anime", "tv", "movie"}:
        raise HTTPException(400, "不支持的内容类型")
    return JSONResponse(
        await catalog_service.home(content_type, session, limit=limit)
    )


@app.get("/api/v3/catalog/subject/{stable_id:path}")
async def catalog_subject(
    stable_id: str,
    session: AsyncSession = Depends(get_session),
):
    if parse_stable_id(stable_id) is None:
        raise HTTPException(400, "作品 ID 格式不正确")
    item = await catalog_service.get_subject(stable_id, session)
    if item is None:
        raise HTTPException(404, "作品信息暂不可用")
    return JSONResponse(item)


@app.get("/api/v3/playback/{stable_id:path}")
async def stable_playback(
    stable_id: str,
    episode: int = Query(1, ge=1),
    title: str = Query("", max_length=500),
    original_title: str = Query("", max_length=500),
    content_type: str = Query("", max_length=20),
    year: int = Query(0, ge=0, le=9999),
    session: AsyncSession = Depends(get_session),
):
    if parse_stable_id(stable_id) is None:
        raise HTTPException(400, "作品 ID 格式不正确")
    lines = await playback_service.lines(
        stable_id,
        episode,
        session,
        title=title,
        original_title=original_title,
        content_type=content_type,
        year=year,
    )
    return JSONResponse(lines)


@app.post(
    "/admin/v3/playback/refresh",
    dependencies=[Depends(require_admin)],
)
async def refresh_playback_cache(
    limit: int = Query(12, ge=1, le=50),
):
    return JSONResponse(await playback_service.refresh_due(limit=limit))
