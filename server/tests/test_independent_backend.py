from pathlib import Path


FORBIDDEN_ANICH_BACKENDS = (
    "anich.sends.eu.org",
    "ani.emmmm.eu.org",
    "api.emmmm.eu.org.cdn.cloudflare.net",
    "api.500403.xyz",
)


def test_runtime_backend_never_calls_anich_or_its_mirrors():
    runtime_root = Path(__file__).resolve().parents[1] / "server"
    runtime_text = "\n".join(
        path.read_text(encoding="utf-8")
        for path in runtime_root.rglob("*.py")
    ).lower()

    for host in FORBIDDEN_ANICH_BACKENDS:
        assert host not in runtime_text
