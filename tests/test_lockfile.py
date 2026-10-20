"""requirements.lock pins every dependency of pyproject.toml, with hashes, and installs use it.

Without a lockfile, `pip install -e .` resolved whatever was newest on PyPI that day, so two
clones a week apart could test different code. Found by an external security review.
Regenerate with `make lock` (uv); the lock keeps its pins unless pyproject.toml needs others.
"""
import re
import tomllib
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LOCK = REPO / "requirements.lock"


def norm(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def requirement_names() -> set[str]:
    project = tomllib.loads((REPO / "pyproject.toml").read_text(encoding="utf-8"))["project"]
    reqs = project["dependencies"] + project["optional-dependencies"]["lab"]
    return {norm(re.match(r"[A-Za-z0-9_.-]+", r).group(0)) for r in reqs}


def locked() -> dict[str, str]:
    pins = {}
    for line in LOCK.read_text(encoding="utf-8").splitlines():
        m = re.match(r"^([A-Za-z0-9_.-]+)==(\S+)", line)
        if m:
            pins[norm(m.group(1))] = m.group(2)
    return pins


class LockfileTests(unittest.TestCase):
    def test_every_direct_dependency_is_pinned(self):
        missing = requirement_names() - set(locked())
        self.assertEqual(missing, set(), "run `make lock` after changing pyproject.toml")

    def test_every_pin_has_a_hash(self):
        text = LOCK.read_text(encoding="utf-8")
        blocks = re.split(r"\n(?=[A-Za-z0-9_.-]+==)", text)
        unhashed = [b.split()[0] for b in blocks if "==" in b.split()[0] and "--hash=sha256:" not in b]
        self.assertEqual(unhashed, [])

    def test_installs_go_through_the_lock(self):
        # Each place that installs the project installs the lock first and the project with --no-deps,
        # so pip cannot resolve a newer version behind the lock's back. The optional `[mcp]` extra
        # (`make mcp-setup`, a workstation tool outside the app and CI) is not in the lock.
        files = [REPO / "Makefile"] + sorted((REPO / ".github/workflows").glob("*.yml"))
        loose = []
        for f in files:
            for n, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
                if "[mcp]" in line:
                    continue
                if re.search(r"pip install\b.*\s-e\s+['\"]?\.", line) and "--no-deps" not in line:
                    loose.append(f"{f.relative_to(REPO)}:{n}: {line.strip()}")
                if "--no-deps -e ." in line and "requirements.lock" not in line:
                    prev = f.read_text(encoding="utf-8").splitlines()[n - 2]
                    if "--require-hashes -r requirements.lock" not in prev:
                        loose.append(f"{f.relative_to(REPO)}:{n}: lock not installed first")
        self.assertEqual(loose, [])


if __name__ == "__main__":
    unittest.main()
