"""Retained character, person, and search routes."""

from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import JSONResponse, Response
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from .. import protobuf_encoder as pb
from ..database import Bangumi, Character, Person, Thread
from ..dependencies import get_session
from ..legacy_protocol import bangumi_to_dict, protobuf_bytes

router = APIRouter(tags=["legacy-lookup"])


@router.get("/bangumi/characters/{id}")
async def bangumi_characters(
    id: int,
    session: AsyncSession = Depends(get_session),
) -> Response:
    result = await session.execute(select(Character).where(Character.bangumi_id == id))
    items = [
        {
            "id": character.id,
            "name": character.name,
            "role": character.role,
            "avatar": character.avatar_url,
            "summary": character.summary,
        }
        for character in result.scalars().all()
    ]
    return protobuf_bytes(pb.encode_characters_list(items))


@router.get("/bangumi/character/{id}")
async def character_detail(
    id: int,
    session: AsyncSession = Depends(get_session),
) -> JSONResponse:
    result = await session.execute(select(Character).where(Character.id == id))
    character = result.scalar_one_or_none()
    if not character:
        raise HTTPException(404)
    return JSONResponse(
        {
            "id": character.id,
            "name": character.name,
            "role": character.role,
            "avatar_url": character.avatar_url,
            "summary": character.summary,
            "seiyuu": character.seiyuu,
        }
    )


@router.get("/bangumi/character/{id}/bangumi")
async def character_bangumi(
    id: int,
    skip: int = Query(0),
    session: AsyncSession = Depends(get_session),
) -> JSONResponse:
    result = await session.execute(select(Character).where(Character.id == id))
    character = result.scalar_one_or_none()
    if not character:
        raise HTTPException(404)
    result = await session.execute(
        select(Bangumi)
        .options(selectinload(Bangumi.episodes))
        .where(Bangumi.id == character.bangumi_id)
    )
    return JSONResponse([bangumi_to_dict(item) for item in result.scalars().all()])


@router.get("/bangumi/persons/{id}")
async def bangumi_persons(
    id: int,
    session: AsyncSession = Depends(get_session),
) -> Response:
    result = await session.execute(select(Person).where(Person.bangumi_id == id))
    items = [
        {
            "id": person.id,
            "name": person.name,
            "role": person.role,
            "avatar": person.avatar_url,
            "summary": person.summary,
        }
        for person in result.scalars().all()
    ]
    return protobuf_bytes(pb.encode_persons_list(items))


@router.get("/bangumi/person/{id}")
async def person_detail(
    id: int,
    session: AsyncSession = Depends(get_session),
) -> JSONResponse:
    result = await session.execute(select(Person).where(Person.id == id))
    person = result.scalar_one_or_none()
    if not person:
        raise HTTPException(404)
    return JSONResponse(
        {
            "id": person.id,
            "name": person.name,
            "role": person.role,
            "avatar_url": person.avatar_url,
            "summary": person.summary,
        }
    )


@router.get("/bangumi/person/{id}/bangumi")
async def person_bangumi(
    id: int,
    skip: int = Query(0),
    session: AsyncSession = Depends(get_session),
) -> JSONResponse:
    result = await session.execute(select(Person).where(Person.id == id))
    person = result.scalar_one_or_none()
    if not person:
        raise HTTPException(404)
    result = await session.execute(
        select(Bangumi)
        .options(selectinload(Bangumi.episodes))
        .where(Bangumi.id == person.bangumi_id)
    )
    return JSONResponse([bangumi_to_dict(item) for item in result.scalars().all()])


@router.get("/search")
async def search_picture(
    keyword: str = Query(""),
    skip: int = Query(0),
    session: AsyncSession = Depends(get_session),
) -> Response:
    stmt = (
        select(Thread)
        .options(selectinload(Thread.images))
        .where(Thread.title.contains(keyword) | Thread.tags.contains(keyword))
        .offset(skip)
        .limit(30)
    )
    threads = (await session.execute(stmt)).scalars().all()
    items = [
        {
            "color": image.color,
            "width": image.width,
            "height": image.height,
            "image": image.master or image.original,
        }
        for thread in threads
        for image in thread.images
    ]
    return protobuf_bytes(pb.encode_images_list(items))


@router.get("/bangumi/search")
async def search_bangumi(
    keyword: str = Query(""),
    skip: int = Query(0),
    session: AsyncSession = Depends(get_session),
) -> Response:
    stmt = (
        select(Bangumi)
        .options(selectinload(Bangumi.episodes))
        .where(Bangumi.title.contains(keyword))
        .offset(skip)
        .limit(20)
    )
    result = await session.execute(stmt)
    items = [bangumi_to_dict(item) for item in result.scalars().all()]
    return protobuf_bytes(pb.encode_bangumi_list(items))
