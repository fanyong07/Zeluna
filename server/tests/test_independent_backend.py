"""AniCh 上游域名纪律测试。

项目纪律(2026-08 由维护者修订):运行时代码默认禁止引用 AniCh 及其
镜像后端主机名;唯一例外是按需代取 provider 的传输层模块
``scrapers/anime/anich_transport.py``(红线白名单),所有上游常量、
UA 与 URL 构造都收敛在该文件内,其余 ``server/server/**/*.py``
出现下列任何精确主机名即视为越界。

注意:扫描保持"精确主机名子串"语义不变——父域/CDN 子域
(``sends.eu.org``/``emmmm.eu.org`` 等形式)不在禁令范围,
``m3u8_resolver.py`` 等存量媒体行依赖此前提。
"""

from pathlib import Path


FORBIDDEN_ANICH_BACKENDS = (
    "anich.sends.eu.org",
    "ani.emmmm.eu.org",
    "api.emmmm.eu.org.cdn.cloudflare.net",
    "api.500403.xyz",
)

_WHITELIST_RELPATHS = frozenset(
    {"scrapers/anime/anich_transport.py"},
)


def _runtime_files():
    runtime_root = Path(__file__).resolve().parents[1] / "server"
    for path in sorted(runtime_root.rglob("*.py")):
        relative = path.relative_to(runtime_root).as_posix()
        yield path, relative


def test_runtime_backend_never_calls_anich_outside_whitelist_module():
    violations: list[str] = []
    for path, relative in _runtime_files():
        if relative in _WHITELIST_RELPATHS:
            continue
        text = path.read_text(encoding="utf-8").lower()
        for host in FORBIDDEN_ANICH_BACKENDS:
            if host in text:
                violations.append(f"{relative}: {host}")
    assert not violations, f"forbidden anich hosts leaked outside whitelist: {violations}"


def test_whitelist_module_remains_the_single_exception_point():
    whitelist_texts: dict[str, str] = {}
    for path, relative in _runtime_files():
        if relative in _WHITELIST_RELPATHS:
            whitelist_texts[relative] = path.read_text(encoding="utf-8").lower()

    missing = _WHITELIST_RELPATHS - set(whitelist_texts)
    assert not missing, f"whitelist module missing from runtime tree: {sorted(missing)}"

    # 白名单文件必须真实承载上游主域;否则豁免已与实现漂移,
    # 要么恢复单点收口,要么把整个 provider 连同纪律一起重新评审。
    # 注意只锚定主域:其余镜像会随上游轮换增删(已停用域按实测移出候选),
    # 那属于正常维护,不该让纪律测试失败。
    transport_text = whitelist_texts["scrapers/anime/anich_transport.py"]
    assert "anich.sends.eu.org" in transport_text, (
        "whitelist module no longer references the upstream primary host; "
        "the exception point has drifted"
    )
