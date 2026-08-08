"""Authenticated incremental synchronization endpoints."""

from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import JSONResponse
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from ..account_api import current_account
from ..database import User, UserToken
from ..dependencies import get_session
from ..sync_contracts import SyncPushRequest
from ..sync_repository import SyncRepository
from ..sync_service import SyncMutationConflict, SyncService


router = APIRouter(prefix="/api/v1/sync", tags=["sync"])


@router.post("/push")
async def push_sync(
    payload: SyncPushRequest,
    account: tuple[User, UserToken] = Depends(current_account),
    session: AsyncSession = Depends(get_session),
):
    service = SyncService(SyncRepository(session))
    try:
        try:
            result = await service.push(account[0].id, payload.mutations)
        except IntegrityError:
            await session.rollback()
            result = await service.push(account[0].id, payload.mutations)
    except IntegrityError as error:
        await session.rollback()
        raise HTTPException(
            status_code=409, detail="同步写入发生冲突，请安全重试"
        ) from error
    except SyncMutationConflict as error:
        await session.rollback()
        raise HTTPException(status_code=409, detail=str(error)) from error
    except ValueError as error:
        await session.rollback()
        raise HTTPException(status_code=422, detail=str(error)) from error
    return JSONResponse(
        {
            "acknowledged": result.records,
            "next_revision": result.next_revision,
        },
        headers={"Cache-Control": "no-store"},
    )


@router.get("/pull")
async def pull_sync(
    after_revision: int = Query(default=0, ge=0),
    limit: int = Query(default=200, ge=1, le=500),
    account: tuple[User, UserToken] = Depends(current_account),
    session: AsyncSession = Depends(get_session),
):
    result = await SyncService(SyncRepository(session)).pull(
        account[0].id,
        after_revision=after_revision,
        limit=limit,
    )
    return JSONResponse(result, headers={"Cache-Control": "no-store"})
