#!/usr/bin/env python3
"""Generate a bounded batch of topics, honouring the budget in pipeline.yaml.

Replaces the ad-hoc scripts that had batch size and retry policy written by
hand. Everything deciding how much work to do, and which errors deserve another
attempt, comes from the YAML rather than from here.

    scripts/run_batch.py cks --lang en
    scripts/run_batch.py cks --lang en --topics 4

Idempotent: it asks the auditor what is missing, so re-running continues where
it left off without keeping any state of its own.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

# Exclusion lives in teach/core/claims.py and is per (cert, topic, lang), not
# global: two agents on different topics are two agents working. The global lock
# that used to be here made them queue behind each other, which is how an
# unsynchronised orchestrator came to be written in the first place.
from teach.core import claims, pipeline  # noqa: E402

import fix_corrupted_content as audit  # noqa: E402

TEACH = REPO / ".venv" / "bin" / "teach"


def _sort_key(topic: str) -> list[int]:
    try:
        return [int(part) for part in topic.split(".")]
    except ValueError:
        return [10**6]


def pending(cert: str, lang: str) -> list[str]:
    """Topics still missing for this combination, in syllabus order."""
    return sorted(
        (t for c, t, l in audit.find_bad_combos() if c == cert and l == lang),
        key=_sort_key,
    )


# A topic generated and moved to its own branch by scripts/topic_pr.py is gone from this checkout until its PR
# merges, so the auditor reports it missing and the next batch authored it again (#339: 1.6-1.8 of nca-aiio on
# 2026-11-13). It is in flight while an open PR carries its files, or a local topic_pr worktree holds it unpushed
# (origin has no branch of that name yet).
TOPIC_FILE = re.compile(r"^certs/([^/]+)/([^/]+)/([^/]+)/content\.md$")


def topics_in_files(paths: list[str], cert: str, lang: str) -> set[str]:
    """Topics of `cert` whose `<lang>/content.md` is among `paths` (an open PR's files)."""
    return {m[2] for m in map(TOPIC_FILE.match, paths) if m and m[1] == cert and m[3] == lang}


def topics_in_worktrees(porcelain: str, cert: str, lang: str, repo: Path = REPO,
                        pushed: frozenset[str] = frozenset()) -> set[str]:
    """Topics held by another worktree on a topic_pr branch (`feat/[<issue>-]<cert>-<topic>`) that has the file and
    is not pushed yet (`pushed`: local branches origin also has). Once pushed, its open PR is what counts, so a worktree
    left behind after its PR was closed holds nothing (#361 review)."""
    branch = re.compile(rf"^refs/heads/feat/(?:\d+-)?{re.escape(cert)}-(\d+(?:\.\d+)*)$")
    found, path = set(), None
    for line in porcelain.splitlines():
        if line.startswith("worktree "):
            path = Path(line[len("worktree "):])
        elif line.startswith("branch ") and path and path.resolve() != repo.resolve():
            ref = line[len("branch "):]
            m = branch.match(ref)
            if m and ref not in pushed and (path / "certs" / cert / m[1] / lang / "content.md").is_file():
                found.add(m[1])
    return found


def _quiet(cmd: list[str], repo: Path, timeout: int = 60) -> subprocess.CompletedProcess | None:
    """The command's result, or None when it cannot run at all (no `gh` on PATH, a hung network call)."""
    try:
        return subprocess.run(cmd, cwd=repo, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return None


def in_flight(cert: str, lang: str, repo: Path = REPO) -> set[str]:
    """Topics of this combination already on their way in an open PR or a local topic_pr worktree.

    Advisory: when the PR list cannot be read (no `gh`, not logged in, offline) it warns and the batch goes on."""
    found: set[str] = set()
    prs = _quiet(["gh", "pr", "list", "--state", "open", "--limit", "200", "--json", "number,changedFiles,files"], repo)
    try:
        if prs is None or prs.returncode != 0:
            raise ValueError((prs.stderr.strip()[:200] if prs else "gh did not run") or "gh failed")
        for pr in json.loads(prs.stdout or "[]"):
            paths = [f["path"] for f in pr.get("files") or []]
            if (pr.get("changedFiles") or 0) > len(paths):
                # `gh pr list --json files` stops at 100 files a PR: a switch or re-snapshot PR (305 in #357)
                # would hide most of its topics. The REST listing pages through all of them.
                full = _quiet(["gh", "api", "--paginate", f"repos/{{owner}}/{{repo}}/pulls/{pr['number']}/files",
                               "--jq", ".[].filename"], repo, timeout=120)
                if full is not None and full.returncode == 0:
                    paths = full.stdout.split()
                else:
                    print(f"WARNING: PR #{pr['number']} lists {len(paths)} of its {pr['changedFiles']} files; "
                          "its other topics may be authored again", file=sys.stderr, flush=True)
            found |= topics_in_files(paths, cert, lang)
    except ValueError as why:   # json.JSONDecodeError is a ValueError too
        print(f"WARNING: could not list open PRs ({why}); topics already in a PR may be authored again",
              file=sys.stderr, flush=True)
    wts = _quiet(["git", "worktree", "list", "--porcelain"], repo)
    # Pushed = origin has a branch of the same name. Not "has an upstream": `git worktree add -b feat/... origin/main`
    # (topic_pr.py) sets the upstream to origin/main before anything is pushed (#361 review, round 2).
    remote = _quiet(["git", "for-each-ref", "--format=%(refname:lstrip=3)", "refs/remotes/origin/"], repo)
    if wts is not None and wts.returncode == 0:
        pushed = frozenset(f"refs/heads/{name}" for name in (remote.stdout if remote and remote.returncode == 0
                                                             else "").split())
        found |= topics_in_worktrees(wts.stdout, cert, lang, repo, pushed)
    return found


def lab_only(cert: str, topic: str, lang: str, repo: Path = REPO) -> bool:
    """True when the topic is pending ONLY because its lab is missing.

    A lab the runner's contract rejects is not written (generator._write_lab,
    #297) while the content and exercises already are. Regenerating with
    --force would pay for both again; `teach cert lab` writes just the lab.
    """
    from teach.core import certs, quality

    if lang != certs.DEFAULT_LANG:
        return False
    topic_dir = repo / "certs" / cert / topic
    return not (topic_dir / "lab" / "break_fix.sh").exists() and quality.authored(topic_dir / lang)


def command(cert: str, topic: str, lang: str, backend: str) -> list[str]:
    if lab_only(cert, topic, lang):
        return [str(TEACH), "cert", "lab", cert, "--topic", topic, "--backend", backend]
    return [str(TEACH), "cert", "generate", cert, "--topic", topic,
            "--lang", lang, "--backend", backend, "--force"]


def generate(cert: str, topic: str, lang: str, backend: str) -> tuple[bool, str]:
    result = subprocess.run(command(cert, topic, lang, backend), cwd=REPO, capture_output=True, text=True)
    return result.returncode == 0, (result.stdout + result.stderr).strip()


def generate_with_retries(topic: str, args, attempts: int, delay: int) -> str:
    """One topic, start to finish. Returns done | failed | skipped | fatal.

    The claim is held for exactly as long as the work takes, so a second agent
    sees this topic as busy and moves to the next one instead of duplicating it.
    """
    with claims.claim(args.cert, topic, args.lang) as mine:
        if not mine:
            # Claimed between listing and starting. Not an error — someone else
            # is doing it, which is exactly what should happen.
            print(f"--- {topic}: claimed by another run, skipping ---", flush=True)
            return "skipped"
        for attempt in range(1, attempts + 1):
            print(f"--- {topic} (attempt {attempt}/{attempts}) ---", flush=True)
            ok, output = generate(topic=topic, cert=args.cert, lang=args.lang,
                                  backend=args.backend)
            if ok:
                return "done"
            # Only a fatal error stops the batch: with quota exhausted, every
            # remaining call would fail the same way.
            if pipeline.is_fatal(output):
                print(f"FATAL: retrying cannot help, stopping the batch.\n{output}", flush=True)
                return "fatal"
            if not pipeline.is_retryable(output) or attempt == attempts:
                # One stubborn topic must not hold up the rest. Nothing was
                # written for it, so the next pass simply finds it pending again.
                print(f"GIVING UP on {topic}, moving on:\n{output}", flush=True)
                return "failed"
            print(f"transient error, retrying in {delay}s", flush=True)
            time.sleep(delay)
    return "failed"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cert")
    parser.add_argument("--lang", default="es")
    parser.add_argument("--backend", default="claude")
    parser.add_argument(
        "--topics", type=int, default=None,
        help="how many topics to generate (default: budget.topics_per_run from pipeline.yaml)",
    )
    parser.add_argument("--anyway", action="store_true",
                        help="generate a certification owned by another agent")
    args = parser.parse_args()

    limit = args.topics if args.topics is not None else pipeline.topics_per_run()
    attempts = int(pipeline.budget().get("retry_attempts") or 1)
    delay = int(pipeline.budget().get("retry_delay_seconds") or 0)

    # Ownership is advisory and skippable, not a lock — the claim system is what
    # prevents collisions. This only stops two agents spending two quota windows
    # on the same certification, which is what happened when the split lived in
    # prose: a stale line in docs/AGENTS_SYNC.md outlived the split that replaced it.
    if not pipeline.mine(args.cert) and not args.anyway:
        print(f"{args.cert} belongs to '{pipeline.owner(args.cert)}' and you are "
              f"'{pipeline.me()}' (pipeline.yaml -> certs.{args.cert}.owner).\n"
              f"Take it anyway with --anyway, or set TEACH_AGENT.", file=sys.stderr)
        return 3

    queue = pending(args.cert, args.lang)
    flying = (in_flight(args.cert, args.lang) & set(queue)) if queue else set()
    if flying:
        print(f"{args.cert} ({args.lang}): {len(flying)} topics already in an open PR or a topic_pr worktree "
              f"({', '.join(sorted(flying, key=_sort_key)[:5])}), skipping them", flush=True)
        queue = [t for t in queue if t not in flying]
    if not queue:
        print(f"{args.cert} ({args.lang}): nothing pending")
        return 0

    # Skip what another agent is already producing rather than queueing behind
    # it. Two runs on different topics are two agents working; only the same
    # topic is a collision.
    busy = [t for t in queue if claims.is_claimed(args.cert, t, args.lang)]
    free = [t for t in queue if t not in busy]
    if busy:
        print(f"{args.cert} ({args.lang}): {len(busy)} topics claimed by another "
              f"run ({', '.join(busy[:5])}), skipping them", flush=True)
    if not free:
        print(f"{args.cert} ({args.lang}): everything pending is already claimed")
        return 0

    # Probe quota before paying to load the heavy context window for the first topic.
    probe = subprocess.run(
        [sys.executable, str(REPO / "scripts" / "quota.py"), "--quiet", "--backend", args.backend]
    )
    if probe.returncode == 1:
        print(f"FATAL: {args.backend} quota is exhausted, stopping the batch before starting.", flush=True)
        return 2
    elif probe.returncode != 0:
        print(f"WARNING: quota probe failed (exit {probe.returncode}), proceeding anyway.", flush=True)

    batch = free[:limit] if limit else free
    print(f"{args.cert} ({args.lang}): {len(queue)} pending, "
          f"generating {len(batch)}: {', '.join(batch)}", flush=True)

    done = 0
    failed: list[str] = []
    for topic in batch:
        outcome = generate_with_retries(topic, args, attempts, delay)
        if outcome == "fatal":
            print(f"generated {done}/{len(batch)}", flush=True)
            return 2
        if outcome == "done":
            done += 1
        elif outcome == "failed":
            failed.append(topic)

    remaining = len(queue) - done
    print(f"batch complete: {done} generated, {remaining} left in {args.cert} ({args.lang})")
    if failed:
        print(f"not generated this pass: {', '.join(failed)}")
    # Exit 1 only when the whole batch failed, so a caller looping over batches
    # can tell "no progress at all" from "partial progress".
    return 1 if done == 0 else 0


if __name__ == "__main__":
    sys.exit(main())
