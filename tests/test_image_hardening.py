"""Static guards on the app image: pinned base, non-root user, no .env in the build context."""
import re
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def test_app_image_base_is_pinned_by_digest():
    text = (REPO / "deploy" / "Dockerfile").read_text(encoding="utf-8")
    froms = re.findall(r"^FROM\s+(\S+)", text, re.M)
    assert froms and all(re.search(r"@sha256:[0-9a-f]{64}$", f) for f in froms), froms


def test_app_image_does_not_run_as_root():
    lines = (REPO / "deploy" / "Dockerfile").read_text(encoding="utf-8").splitlines()
    users = [l.split()[1] for l in lines if l.startswith("USER ")]
    assert users and users[-1] not in ("root", "0"), users


def test_dockerignore_keeps_env_files_out_of_the_context():
    entries = (REPO / ".dockerignore").read_text(encoding="utf-8").split()
    assert {".env", ".env.*", "*.env"} <= set(entries)
