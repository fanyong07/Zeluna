"""Fail-closed administrator interface for managed remote playback URLs."""

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.ext.asyncio import AsyncSession

from ..dependencies import get_session, require_admin
from ..managed_lines.schemas import (
    ManagedLineCreate,
    ManagedLineImportRequest,
    ManagedLineResponse,
    ManagedLineUpdate,
)
from ..managed_lines.service import (
    ManagedLineInputError,
    ManagedLineNotFoundError,
    ManagedLineStateError,
    managed_line_service,
)
from ..managed_lines.validation import ManagedLineValidationError


router = APIRouter(
    prefix="/admin/managed-lines",
    tags=["admin-managed-lines"],
    dependencies=[Depends(require_admin)],
)


def _input_error(error: Exception) -> HTTPException:
    code = getattr(error, "code", "invalid_managed_line")
    return HTTPException(
        status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
        detail={"code": code, "message": str(error)},
    )


def _state_error(error: ManagedLineStateError) -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_409_CONFLICT,
        detail={"code": error.code, "message": str(error)},
    )


@router.post("", response_model=ManagedLineResponse, status_code=status.HTTP_201_CREATED)
async def create_managed_line(
    data: ManagedLineCreate,
    session: AsyncSession = Depends(get_session),
) -> ManagedLineResponse:
    try:
        record = await managed_line_service.create(session, data)
    except (ManagedLineInputError, ManagedLineValidationError) as error:
        raise _input_error(error) from error
    return ManagedLineResponse.model_validate(record)


@router.post(
    "/import",
    response_model=list[ManagedLineResponse],
    status_code=status.HTTP_201_CREATED,
)
async def import_managed_lines(
    data: ManagedLineImportRequest,
    session: AsyncSession = Depends(get_session),
) -> list[ManagedLineResponse]:
    try:
        records = await managed_line_service.import_many(
            session,
            [item.as_create() for item in data.items],
        )
    except (ManagedLineInputError, ManagedLineValidationError) as error:
        raise _input_error(error) from error
    return [ManagedLineResponse.model_validate(record) for record in records]


@router.get("", response_model=list[ManagedLineResponse])
async def list_managed_lines(
    stable_id: str | None = Query(default=None, max_length=200),
    episode: int | None = Query(default=None, ge=1),
    limit: int = Query(default=100, ge=1, le=500),
    offset: int = Query(default=0, ge=0),
    session: AsyncSession = Depends(get_session),
) -> list[ManagedLineResponse]:
    try:
        records = await managed_line_service.list(
            session,
            stable_id=stable_id,
            episode=episode,
            limit=limit,
            offset=offset,
        )
    except ManagedLineInputError as error:
        raise _input_error(error) from error
    return [ManagedLineResponse.model_validate(record) for record in records]


@router.get("/{line_id}", response_model=ManagedLineResponse)
async def get_managed_line(
    line_id: str,
    session: AsyncSession = Depends(get_session),
) -> ManagedLineResponse:
    try:
        record = await managed_line_service.get(session, line_id)
    except ManagedLineNotFoundError as error:
        raise HTTPException(status_code=404, detail="管理线路不存在") from error
    return ManagedLineResponse.model_validate(record)


@router.patch("/{line_id}", response_model=ManagedLineResponse)
async def update_managed_line(
    line_id: str,
    data: ManagedLineUpdate,
    session: AsyncSession = Depends(get_session),
) -> ManagedLineResponse:
    try:
        record = await managed_line_service.update(session, line_id, data)
    except ManagedLineNotFoundError as error:
        raise HTTPException(status_code=404, detail="管理线路不存在") from error
    except ManagedLineStateError as error:
        raise _state_error(error) from error
    except (ManagedLineInputError, ManagedLineValidationError) as error:
        raise _input_error(error) from error
    return ManagedLineResponse.model_validate(record)


async def _run_action(
    action,
    session: AsyncSession,
    line_id: str,
) -> ManagedLineResponse:
    try:
        record = await action(session, line_id)
    except ManagedLineNotFoundError as error:
        raise HTTPException(status_code=404, detail="管理线路不存在") from error
    except ManagedLineStateError as error:
        raise _state_error(error) from error
    except ManagedLineValidationError as error:
        raise _input_error(error) from error
    return ManagedLineResponse.model_validate(record)


@router.post("/{line_id}/verify", response_model=ManagedLineResponse)
async def verify_managed_line(
    line_id: str,
    session: AsyncSession = Depends(get_session),
) -> ManagedLineResponse:
    return await _run_action(managed_line_service.verify, session, line_id)


@router.post("/{line_id}/approve", response_model=ManagedLineResponse)
async def approve_managed_line(
    line_id: str,
    session: AsyncSession = Depends(get_session),
) -> ManagedLineResponse:
    return await _run_action(managed_line_service.approve, session, line_id)


@router.post("/{line_id}/enable", response_model=ManagedLineResponse)
async def enable_managed_line(
    line_id: str,
    session: AsyncSession = Depends(get_session),
) -> ManagedLineResponse:
    return await _run_action(managed_line_service.enable, session, line_id)


@router.post("/{line_id}/disable", response_model=ManagedLineResponse)
async def disable_managed_line(
    line_id: str,
    session: AsyncSession = Depends(get_session),
) -> ManagedLineResponse:
    return await _run_action(managed_line_service.disable, session, line_id)


@router.post("/{line_id}/revoke", response_model=ManagedLineResponse)
async def revoke_managed_line(
    line_id: str,
    session: AsyncSession = Depends(get_session),
) -> ManagedLineResponse:
    return await _run_action(managed_line_service.revoke, session, line_id)
