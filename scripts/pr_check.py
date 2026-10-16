#!/usr/bin/env python3
"""Run, on your machine, the checks CI runs on a pull request.

    make pr-check                          # everything CI's verify job runs (~5 min)
    make pr-check QUICK=1                  # same minus the full unit-test suite (~1 min)
    make pr-check BASE=origin/main PR_BODY=body.md PR_TITLE="feat(x): y"

One line per check (OK / FAIL / WARN), a summary, exit 1 if anything FAILed.
Nothing is duplicated here: the content checks are read from `make -n
verify-ci`, so this stays equal to CI by construction. Everything that needs
the network, a model, Docker or a cluster stays in CI (listed at the end).
See CONTRIBUTING.md -> "Check before you push".
"""
from __future__ import annotations

import argparse
import os
import shlex
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
VENV_PY = REPO / ".venv" / "bin" / "python3"
# The key shapes CI refuses (verify.yml, step "Secrets").
SECRET = r"\b(sk-[A-Za-z0-9_-]{20,}|sk-or-v1-[A-Za-z0-9]{32,}|AIza[A-Za-z0-9_-]{30,}|ghp_[A-Za-z0-9]{30,})"
LAB_PATHS = ("teach/lab/", "certs/", "deploy/study-lab/", "tests/lab/")
CI_ONLY = ("make test-e2e (clone, serve, Docker lab)", "docker image build (docker.yml)",
           "kind labs (labs.yml, slow)", "check_citations / check_api_facts (network)",
           "check_claims / groundedness (model quota)", "where-it-ran: the cited run (needs the pushed head)")

results: list[str] = []


def run(cmd, timeout: int = 900) -> tuple[int, str]:
    try:
        p = subprocess.run(cmd, shell=isinstance(cmd, str), cwd=REPO, capture_output=True,
                           text=True, encoding="utf-8", errors="replace", timeout=timeout)
    except subprocess.TimeoutExpired:
        return 124, "timed out"
    return p.returncode, (p.stdout + p.stderr).strip()


def report(status: str, name: str, secs: float = 0.0, detail: str = "") -> None:
    results.append(status)
    print(f"{status:<4}  {name}" + (f"  ({secs:.1f}s)" if secs else ""), flush=True)
    if detail and status != "OK":
        for line in detail.splitlines()[-12:]:
            print(f"        {line}")


def graph_status(code: int, out: str) -> str:
    """OK only when check_graph.py says so: exit 0 and its own `graph: OK` marker.

    It exits 0 for a stale graph too (warning only), so the exit code alone is not enough, and
    "any output" is wrong the other way: a fresh graph prints `graph: OK ...`."""
    return "OK" if code == 0 and out.lstrip().startswith("graph: OK") else "WARN"


def check(name: str, cmd, classify=None, fail_is_warn: bool = False) -> None:
    start = time.time()
    code, out = run(cmd)
    secs = time.time() - start
    if code != 0:
        report("WARN" if fail_is_warn else "FAIL", name, secs, out)
    elif classify and classify(code, out) != "OK":
        report("WARN", name, secs, out)
    else:
        report("OK", name, secs)


def verify_ci_commands() -> list[str]:
    """The recipe of `make verify-ci`, one command per entry (the single definition CI uses)."""
    code, out = run(["make", "--no-print-directory", "-n", "verify-ci"])
    if code != 0:
        return []
    return [ln.strip() for ln in out.splitlines() if ln.strip() and not ln.lstrip().startswith("#")]


def label(cmd: str) -> str:
    parts = shlex.split(cmd)
    if "unittest" in parts:
        return "unit tests (tests/)"
    return " ".join([Path(parts[1]).name] + parts[2:]) if len(parts) > 1 else cmd


def groundedness_cached() -> bool:
    models = Path(os.environ.get("GROUNDEDNESS_CACHE", REPO / ".cache" / "groundedness")) / "models"
    return models.is_dir() and any(models.iterdir())


def changed(base: str) -> list[str]:
    code, out = run(["git", "-c", "core.quotePath=false", "diff", "--name-only", f"{base}...HEAD"])
    return out.splitlines() if code == 0 else []


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base", default="origin/main")
    ap.add_argument("--body-file", help="your draft PR description (checked with check_pr.py)")
    ap.add_argument("--fast", action="store_true", help=argparse.SUPPRESS)  # tests: skip the slow verify-ci block
    ap.add_argument("--quick", action="store_true", help="skip the full unit-test suite (~4 min); CI still runs it")
    ap.add_argument("--title", help="your PR title (default: the last commit subject)")
    args = ap.parse_args()
    t0 = time.time()

    if os.name == "nt":
        print("WARN  native Windows is not supported: use WSL (Ubuntu). See CONTRIBUTING.md.")
    global VENV_PY
    if not VENV_PY.exists():
        if not args.fast:
            print("FAIL  no .venv: run `make setup` first")
            return 1
        VENV_PY = Path(sys.executable)

    # 1. CRLF in a tracked text file changes every sha256 the source chain relies on.
    _, eol = run(["git", "ls-files", "--eol"])
    crlf = []
    for line in eol.splitlines():
        info, _, path = line.partition("\t")
        if "i/crlf" in info or "w/crlf" in info:
            crlf.append(path)
    if crlf:
        report("WARN", f"line endings: {len(crlf)} tracked text file(s) have CRLF, hashes will differ from CI "
               "(git config core.autocrlf false, then re-checkout)", 0, "\n".join(crlf[:5]))
    else:
        report("OK", "line endings (no CRLF in tracked text files)")

    # 2. CI step "Verify": the content checks and the unit tests, command by command.
    cmds = [] if args.fast else verify_ci_commands()
    if not cmds and not args.fast:
        report("FAIL", "could not read `make -n verify-ci`")
    for cmd in cmds:
        if args.quick and "unittest" in cmd:
            report("WARN", "unit tests skipped (QUICK=1): run plain `make pr-check` or `make test` before asking for review")
            continue
        check(label(cmd), cmd)

    # 3. CI step "Secrets".
    start = time.time()
    code, out = run(f"git grep -nE {shlex.quote(SECRET)} -- . ':!*.lock' | grep -v sk-ssh-")
    report("FAIL" if code == 0 else "OK", "secrets (key-shaped strings)", time.time() - start, out)

    # 4. CI workflow docs.yml: the documentation is true to the repository, and the code graph is
    # what the tree builds (a warning there too: main refreshes the graph, a PR must not rebuild it).
    check("docs consistency (check_docs.py)", [str(VENV_PY), "scripts/check_docs.py"])
    if (REPO / ".venv" / "bin" / "graphify").exists():
        check("code graph (check_graph.py --regenerate, warn-only)",
              [str(VENV_PY), "scripts/check_graph.py", "--regenerate"], classify=graph_status, fail_is_warn=True)
    else:
        report("WARN", "code graph not checked: graphify is not installed (`make graph-setup`); CI checks it, warn-only")

    # 5. CI workflow groundedness.yml is advisory and needs model weights and the network. Here it
    # only runs when the weights are already downloaded, on cached sources, writing nothing.
    if not groundedness_cached():
        report("WARN", "groundedness: CI-only here (weights not downloaded; `make groundedness-setup` once to run it)")
    else:
        start = time.time()
        code, out = run([str(VENV_PY), "scripts/check_groundedness.py", "--base", args.base])
        report("OK" if code == 0 else "WARN", "groundedness, advisory (changed topics, cached sources only)",
               time.time() - start, out)

    # 5b. Lab tests (workflow labs.yml) when the diff touches labs.
    if any(f.startswith(LAB_PATHS) for f in changed(args.base)):
        check("lab tests (labs.yml: lab-unit)", [str(VENV_PY), "-m", "pytest", "tests/lab", "-m", "not slow", "-q"])

    # 5. The PR description, offline (CI job pr-format).
    if args.body_file:
        _, subject = run(["git", "log", "-1", "--format=%s"])
        check("PR description (check_pr.py)", [str(VENV_PY), "scripts/check_pr.py", "--title", args.title or subject,
                                               "--body-file", args.body_file, "--base", args.base])
    else:
        report("WARN", "PR description not checked (add PR_BODY=<draft.md> [PR_TITLE=...])")

    fails, warns = results.count("FAIL"), results.count("WARN")
    print(f"\n{len(results) - fails - warns} OK, {warns} WARN, {fails} FAIL in {time.time() - t0:.0f}s")
    print("CI-only (not run here): " + "; ".join(CI_ONLY))
    if fails:
        print("Fix every FAIL, then run `make pr-check` again before you push.")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
