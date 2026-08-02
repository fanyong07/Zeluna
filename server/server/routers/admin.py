"""Fail-closed administrative routes."""

from fastapi import APIRouter, Depends, Query
from fastapi.responses import JSONResponse

from ..dependencies import require_admin
from ..metadata_sync import sync_all_pending
from ..playback import playback_service
from ..scheduler import scheduler
from ..scrapers import registry as scraper_registry

router = APIRouter(
    tags=["admin"],
    dependencies=[Depends(require_admin)],
)


@router.get("/admin/scrapers")
async def list_scrapers() -> JSONResponse:
    """列出所有爬虫。"""

    scrapers = [
        {
            "name": scraper.name,
            "content_types": scraper.content_types,
            "base_url": scraper.base_url,
        }
        for scraper in scraper_registry.all_scrapers
    ]
    return JSONResponse(scrapers)


@router.get("/admin/scrapers/search")
async def scraper_search(
    keyword: str = Query(""),
    content_type: str = Query(None),
) -> JSONResponse:
    """通过爬虫搜索内容。"""

    types = [content_type] if content_type else None
    results = await scraper_registry.search_all(keyword, types)
    return JSONResponse(
        [
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
        ]
    )


@router.post("/admin/scan")
async def trigger_scan(
    content_types: str = Query(None),
) -> JSONResponse:
    """手动触发内容扫描。"""

    types = content_types.split(",") if content_types else None
    await scheduler.scan_new_content(types)
    return JSONResponse({"message": "Scan triggered", "types": types})


@router.post("/admin/sync/metadata")
async def trigger_metadata_sync(
    content_types: str = Query(None),
) -> JSONResponse:
    """手动触发元数据同步。"""

    types = content_types.split(",") if content_types else None
    await sync_all_pending(types)
    return JSONResponse({"message": "Metadata sync triggered", "types": types})


@router.get("/admin/stats")
async def scheduler_stats() -> JSONResponse:
    """返回调度器统计信息。"""

    return JSONResponse(
        {
            "scheduler": scheduler.stats,
            "scrapers": {
                name: {
                    "subjects_found": stats.subjects_found,
                    "subjects_new": stats.subjects_new,
                    "duration_seconds": stats.duration_seconds,
                    "errors": stats.errors,
                    "finished_at": (
                        stats.finished_at.isoformat() if stats.finished_at else None
                    ),
                }
                for name, stats in scraper_registry.stats.items()
            },
        }
    )


@router.post("/admin/v3/playback/refresh")
async def refresh_playback_cache(
    limit: int = Query(12, ge=1, le=50),
) -> JSONResponse:
    return JSONResponse(await playback_service.refresh_due(limit=limit))
