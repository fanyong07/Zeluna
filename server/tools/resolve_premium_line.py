"""按清单条目现场重新解析出可下载地址。

清单只记元数据(见 ``premium_catalog``),因为这类直链天级失效。真要下载时
用本工具现调上游拿当下有效的地址,并可直接生成下载命令。

从 ``server/`` 运行::

    # 列出该集当前所有高画质档及其真实地址
    python tools/resolve_premium_line.py --subject anich:37654 --episode 1

    # 只要某个画质档,并生成 aria2c 命令
    python tools/resolve_premium_line.py --subject anich:37654 --episode 1 \
        --quality 官方简中 --emit aria2c

    # HLS 源用 ffmpeg 落地成 mp4
    python tools/resolve_premium_line.py --subject anich:37654 --episode 1 \
        --emit ffmpeg --out-dir /srv/media

地址只打印到标准输出,不写入数据库。
"""

from __future__ import annotations

import argparse
import asyncio
import shlex
import sys
import time
from pathlib import Path
from urllib.parse import urlparse

PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

import httpx  # noqa: E402

from server.premium_catalog import is_premium_quality  # noqa: E402
from server.scrapers.anime.anich import AniChScraper  # noqa: E402


def _safe_name(title: str, episode: int, quality: str) -> str:
    keep = "".join(
        ch for ch in f"{title}-E{episode:02d}-{quality}"
        if ch.isalnum() or ch in "-_.·"
    )
    return keep[:120] or f"episode-{episode:02d}"


def emit_command(kind: str, url: str, name: str, out_dir: str) -> str:
    target = Path(out_dir) if out_dir else Path(".")
    if kind == "aria2c":
        return (
            f"aria2c -x 8 -s 8 --dir={shlex.quote(str(target))} "
            f"--out={shlex.quote(name + Path(urlparse(url).path).suffix or '.mp4')} "
            f"{shlex.quote(url)}"
        )
    if kind == "ffmpeg":
        return (
            f"ffmpeg -i {shlex.quote(url)} -c copy -bsf:a aac_adtstoasc "
            f"{shlex.quote(str(target / (name + '.mp4')))}"
        )
    return url


async def probe(client: httpx.AsyncClient, url: str) -> tuple[bool, str, int]:
    """Range 探测:确认地址此刻真的可用,并顺带报告体积。"""
    try:
        response = await client.get(
            url, headers={"Range": "bytes=0-2047"}, timeout=15
        )
    except Exception as error:  # noqa: BLE001
        return False, type(error).__name__, 0
    head = response.content[:2048]
    text = head.lstrip()
    if text.startswith(b"#EXTM3U"):
        kind = "hls"
    elif b"ftyp" in head[:64]:
        kind = "mp4"
    elif text[:1] == b"<":
        kind = "html(非媒体)"
    else:
        kind = "bin"
    size = 0
    content_range = response.headers.get("content-range", "")
    if "/" in content_range:
        try:
            size = int(content_range.rsplit("/", 1)[-1])
        except ValueError:
            size = 0
    ok = response.status_code in (200, 206) and not kind.startswith("html")
    return ok, kind, size


async def main_async(args: argparse.Namespace) -> int:
    subject_id = args.subject.split(":", 1)[-1] if ":" in args.subject else args.subject
    scraper = AniChScraper()
    try:
        started = time.monotonic()
        lines = await scraper.get_video_urls(subject_id, args.episode)
        elapsed = (time.monotonic() - started) * 1000
        if not lines:
            print(f"该集没有可用线路(subject={args.subject} episode={args.episode})")
            return 1

        premium = [line for line in lines if is_premium_quality(line.quality)]
        pool = premium if premium else lines
        if args.quality:
            pool = [
                line for line in pool
                if args.quality.lower() in (line.quality or "").lower()
            ]
            if not pool:
                have = sorted({line.quality for line in premium if line.quality})
                print(f"没有匹配「{args.quality}」的档次。当前可选: {have}")
                return 1

        print(
            f"解析耗时 {elapsed:.0f}ms;共 {len(lines)} 条线路,"
            f"高画质 {len(premium)} 条,匹配 {len(pool)} 条\n"
        )

        async with httpx.AsyncClient(follow_redirects=True) as client:
            print(f"{'#':<4}{'线路':<12}{'画质':<16}{'延迟':>8}{'体积':>10}  状态")
            print("-" * 72)
            usable: list[tuple] = []
            for index, line in enumerate(pool[: args.limit], 1):
                start = time.monotonic()
                ok, kind, size = await probe(client, line.url)
                ms = (time.monotonic() - start) * 1000
                mb = f"{size / 1048576:.0f}MB" if size else "-"
                mark = "可用" if ok else f"不可用({kind})"
                print(
                    f"{index:<4}{line.source_name[:10]:<12}"
                    f"{(line.quality or '-')[:14]:<16}{ms:>7.0f}ms{mb:>10}  {mark}"
                )
                if ok:
                    usable.append((line, kind, size))
                await asyncio.sleep(0.3)

        if not usable:
            print("\n没有当下可用的线路,稍后重试或换画质档")
            return 1

        if args.emit:
            print(f"\n── {args.emit} 命令(地址为此刻有效,尽快执行)──")
            title = usable[0][0].title or subject_id
            for line, kind, _size in usable:
                name = _safe_name(
                    args.name or title, args.episode, line.quality or line.source_name
                )
                tool = args.emit
                if tool == "auto":
                    tool = "ffmpeg" if kind == "hls" else "aria2c"
                print(f"\n# {line.source_name}  {line.quality or '-'}  ({kind})")
                print(emit_command(tool, line.url, name, args.out_dir))
        else:
            print("\n── 直链(此刻有效)──")
            for line, kind, _size in usable:
                print(f"\n# {line.source_name}  {line.quality or '-'}  ({kind})")
                print(line.url)
    finally:
        await scraper.aclose()
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--subject", required=True, help="清单里的 subject_stable_id")
    parser.add_argument("--episode", type=int, default=1)
    parser.add_argument("--quality", help="只要含该词的画质档,如 官方简中 / 4K")
    parser.add_argument("--limit", type=int, default=8, help="最多探测几条")
    parser.add_argument(
        "--emit", choices=("auto", "aria2c", "ffmpeg"),
        help="生成下载命令而不是只打印地址",
    )
    parser.add_argument("--out-dir", default=".", help="下载命令的目标目录")
    parser.add_argument("--name", help="覆盖输出文件名的作品名部分")
    args = parser.parse_args()
    try:
        return asyncio.run(main_async(args))
    except KeyboardInterrupt:  # pragma: no cover
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
