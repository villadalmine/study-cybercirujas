#!/usr/bin/env python3
"""Fidelity gate for cloud labs on a local emulator (#303). No model: every verdict comes from pinned, hashed data.

    scripts/lab_fidelity.py pin [--release v1.0.345] [--check]   # write/compare deploy/lab-emulators.yaml
    scripts/lab_fidelity.py fetch                                 # download the pinned data into .cache/lab-fidelity/
    scripts/lab_fidelity.py ops s3 [--grep Bucket]                # which operations of a service have evidence

A cloud lab runs against AWS Emulator (https://github.com/aws/aws-emulator), not AWS. The emulator only teaches
the truth where it behaves like AWS, so a lab declares the API operations it calls in `uses:` (`s3:CreateBucket`,
service = the Smithy namespace, as `ops` prints it) and this script decides, per operation, from two sources the
emulator publishes for the pinned release:

- `scores.json.gz` (a release asset): the fidelity units AWS runs on every release. A wire unit is a sequence of API
  calls whose expected answers were first recorded against real AWS; a unit that passes on the emulator is evidence
  that each operation in it answers like AWS. `passing_units` counts the passing units that call the operation,
  `failing_units` the units whose step on that operation did not match AWS.
- `issues/things-that-do-not-work/` at the release commit: known gaps, one file each, with machine-readable
  `Issue-Key: <service>|<Operation>|<cause>...` lines. `known_issues` counts the files that name the operation.

Verdict per operation (the only rule; change it here, with its test):
- `reject: no-evidence`     no passing unit calls it: nothing shows the emulator behaves like AWS there;
- `reject: not-implemented` the same, and a known issue says the emulator answers NotImplemented (a stub);
- `warn: critical-issue`    it has passing units, but a CRITICAL known issue about that one service names it. The
  data is per operation, not per way of calling it (`s3|GetObject|NotImplemented` is only the If-Match path), so
  this does not reject: it is recorded, and the runner's break/fix proof decides;
- `ok` otherwise. Failing units and known issues are counted, never hidden: `ops` prints them.

`check` (the gate over each lab, and the `fidelity:` block it records there) is the next PR of #325.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.request
from collections import defaultdict
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
PINS = REPO / "deploy" / "lab-emulators.yaml"
CACHE = Path(os.environ.get("LAB_FIDELITY_CACHE", REPO / ".cache" / "lab-fidelity"))
EMULATOR = "aws-emulator"
GH_REPO = "aws/aws-emulator"
API = f"https://api.github.com/repos/{GH_REPO}"
ISSUES_DIR = "issues/things-that-do-not-work"
PINS_HEADER = (
    "# Written by scripts/lab_fidelity.py pin, never by hand (#303). The emulator release whose published\n"
    "# fidelity data decides which API operations a cloud lab may use. Move it with\n"
    "#   scripts/lab_fidelity.py pin --release <tag>   then   scripts/lab_fidelity.py check --write\n"
)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def fetch(url: str) -> bytes:
    if not url.startswith("https://"):
        raise SystemExit(f"refusing to read {url}: only https URLs")
    headers = {"User-Agent": "study-cybercirujas lab_fidelity"}
    if url.startswith("https://api.github.com/") and os.environ.get("GITHUB_TOKEN"):
        headers["Authorization"] = f"Bearer {os.environ['GITHUB_TOKEN']}"
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=120) as r:
            return r.read()
    except OSError as e:
        raise SystemExit(f"cannot read {url}: {e}")


# ---------------------------------------------------------------- pins

def live_pin(release: str | None) -> dict:
    rel = json.loads(fetch(f"{API}/releases/{'tags/' + release if release else 'latest'}"))
    asset = next((a for a in rel.get("assets", []) if a["name"] == "scores.json.gz"), None)
    if not asset:
        raise SystemExit(f"{rel['tag_name']}: the release has no scores.json.gz asset")
    blob = fetch(asset["browser_download_url"])
    scores = json.loads(gzip.decompress(blob))
    return {
        "repo": GH_REPO,
        "release": rel["tag_name"],
        "commit": scores["commit"],
        "scores_url": asset["browser_download_url"],
        "scores_sha256": sha256(blob),
        "scored_at": scores["scoredAt"],
    }


def load_pins(path: Path = PINS) -> dict:
    if not path.exists():
        raise SystemExit(f"{path.relative_to(REPO)} is missing: run scripts/lab_fidelity.py pin")
    return (yaml.safe_load(path.read_text(encoding="utf-8")) or {})[EMULATOR]


def cmd_pin(args) -> int:
    have = load_pins() if args.check else {}
    pin = live_pin(args.release or have.get("release"))
    if args.check:
        diff = [k for k in pin if have.get(k) != pin[k]]
        if diff:
            print(f"STALE: {PINS.relative_to(REPO)} differs from {pin['release']} in {', '.join(diff)}")
            return 1
        print(f"OK: {PINS.relative_to(REPO)} pins {pin['release']} ({pin['commit'][:12]})")
        return 0
    PINS.write_text(PINS_HEADER + yaml.safe_dump({EMULATOR: pin}, sort_keys=False), encoding="utf-8")
    print(f"wrote {PINS.relative_to(REPO)}: {pin['release']} ({pin['commit'][:12]}), scores {pin['scores_sha256'][:12]}")
    return 0


# ---------------------------------------------------------------- data

def git(repo: Path, *args: str) -> str:
    out = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)
    if out.returncode:
        raise SystemExit(f"git {' '.join(args)} in {repo}: {out.stderr.strip()}")
    return out.stdout


def ensure_data(pin: dict) -> Path:
    """Download the pinned scores and the emulator's tree once; both are verified on every run.

    Every download goes to a temporary name and is renamed only when complete and verified, so an interrupted run
    leaves nothing a later run would trust; a cached copy that fails its check is downloaded again."""
    root = CACHE / EMULATOR / pin["release"]
    root.mkdir(parents=True, exist_ok=True)
    scores = root / "scores.json.gz"
    if not scores.exists() or sha256(scores.read_bytes()) != pin["scores_sha256"]:
        blob = fetch(pin["scores_url"])
        if sha256(blob) != pin["scores_sha256"]:
            raise SystemExit(f"{pin['scores_url']}: sha256 differs from the pin")
        (root / "scores.json.gz.part").write_bytes(blob)
        (root / "scores.json.gz.part").replace(scores)
    repo = root / "repo"
    if repo.exists() and subprocess.run(["git", "-C", str(repo), "rev-parse", "HEAD"], capture_output=True,
                                        text=True).stdout.strip() != pin["commit"]:
        shutil.rmtree(repo)
    if not repo.exists():
        tmp = root / "repo.part"
        shutil.rmtree(tmp, ignore_errors=True)
        tmp.mkdir()
        git(tmp, "init", "-q")
        git(tmp, "remote", "add", "origin", f"https://github.com/{pin['repo']}.git")
        git(tmp, "sparse-checkout", "set", "--no-cone", f"{ISSUES_DIR}/*")
        git(tmp, "fetch", "-q", "--depth", "1", "--filter=blob:none", "origin", pin["commit"])
        git(tmp, "checkout", "-q", "FETCH_HEAD")
        tmp.rename(repo)
    if git(repo, "rev-parse", "HEAD").strip() != pin["commit"]:
        raise SystemExit(f"{repo}: not at the pinned commit {pin['commit'][:12]}")
    return root


def namespace(shape_id: str) -> str:
    """com.amazonaws.s3#AmazonS3 -> s3 (the name `uses:` takes)."""
    return shape_id.split("#")[0].removeprefix("com.amazonaws.")


def norm(name: str) -> str:
    """CreateBucket, create_bucket -> createbucket: how an operation is matched to its handler file."""
    return re.sub(r"[^a-z0-9]", "", name.lower())


def service_dir(shape_id: str) -> str:
    """com.amazonaws.s3#AmazonS3 -> service-com-amazonaws-s3-amazons3, the emulator's crate for that service."""
    return "service-" + re.sub(r"[^a-z0-9]+", "-", shape_id.lower()).strip("-")


def ownership(handler_paths: list[str], shapes: set[str]) -> dict[str, set[str]]:
    """normalized operation -> the namespaces whose crate has a handler for it (services/<crate>/src/ops/<op>.rs).

    The emulator has one handler file per operation, so this is the source of truth for which service an
    operation belongs to. Crates of services no unit or issue names are left out: they have no evidence anyway."""
    crate_ns = {service_dir(s): namespace(s) for s in shapes}
    owners: dict[str, set[str]] = defaultdict(set)
    for path in handler_paths:
        parts = path.split("/")
        if len(parts) >= 5 and parts[0] == "services" and parts[2:4] == ["src", "ops"] and path.endswith(".rs"):
            stem = parts[-1][:-3]
            if stem != "mod" and parts[1] in crate_ns:
                owners[norm(stem)].add(crate_ns[parts[1]])
    return owners


def parse_issue(text: str) -> dict:
    head = {}
    keys = []
    for line in text.splitlines():
        if not line.strip():
            break
        k, sep, v = line.partition(":")
        if not sep:
            break
        if k == "Issue-Key":
            keys.append(v.strip())
        else:
            head[k] = v.strip()
    return {"severity": head.get("Issue-Severity", ""), "shape": head.get("Issue-Shape-Id", ""), "keys": keys}


def key_services(key: str, owners: dict[str, set[str]]) -> tuple[str, set[str]]:
    """An Issue-Key `<service id>|<Operation>|<cause>...` -> (Operation, its namespaces). The first segment is the
    called service (an SDK id such as `s3` or `cloudwatch-logs`), not the issue's Shape-Id, which is the scenario's.
    An operation one service owns goes to it; one several own goes to the owner whose name is that id, or to all
    of them (a known issue then counts for each: it can only make a verdict stricter). A key whose operation has no
    handler anywhere (`<check-id>|run#N|...`) names no operation and is skipped."""
    parts = key.split("|")
    if len(parts) < 2:
        return "", set()
    cands = owners.get(norm(parts[1]), set())
    named = {ns for ns in cands if norm(ns) == norm(parts[0])}
    return parts[1], (cands if len(cands) <= 1 else named or cands)


def build_index(scores: dict, issues: list[dict], owners: dict[str, set[str]]) -> dict:
    """{(service, Operation): {passing_units, failing_units, known_issues, severities, causes}}

    A wire unit is filed under the scenario's service, but its steps may call other services (a budgets scenario
    calls iam:CreateRole). Each call is credited to the service that owns the operation: the unit's own service when
    it has a handler for it, else the only owner; an operation with several other owners is not credited. A known
    issue's severity counts only when all its keys are about one service, so a CRITICAL "the CodeBuild chain never
    finishes" does not reject `iam:GetRole` because the chain calls it.
    """
    idx: dict = defaultdict(lambda: {"passing_units": 0, "failing_units": 0, "known_issues": 0,
                                     "severities": set(), "causes": set()})
    for unit in scores["units"]:
        steps = (unit.get("detail") or {}).get("steps") or []
        services = {namespace(s) for s in unit.get("services", []) if s.startswith("com.amazonaws.")}
        bad = {s["operation"] for s in steps if s["outcome"] in ("mismatch", "error")}
        for op in sorted({s["operation"] for s in steps}):
            cands = owners.get(norm(op), set())
            mine = cands & services
            for svc in mine or (cands if len(cands) == 1 else set()):
                if unit["outcome"] == "pass":
                    idx[(svc, op)]["passing_units"] += 1
                elif op in bad:
                    idx[(svc, op)]["failing_units"] += 1
    for issue in issues:
        resolved = [(key, *key_services(key, owners)) for key in issue["keys"]]
        about = set().union(*(svcs for _, _, svcs in resolved)) if resolved else set()
        named = set()
        for key, op, svcs in resolved:
            for svc in svcs:
                entry = idx[(svc, op)]
                if (svc, op) not in named:
                    named.add((svc, op))
                    entry["known_issues"] += 1
                    if len(about) == 1:
                        entry["severities"].add(issue["severity"])
                if len(key.split("|")) > 2:
                    entry["causes"].add(key.split("|")[2])
    return idx


def load_index(pin: dict) -> dict:
    root = ensure_data(pin)
    scores = json.loads(gzip.decompress((root / "scores.json.gz").read_bytes()))
    issues = [parse_issue(f.read_text(encoding="utf-8", errors="replace"))
              for f in sorted((root / "repo" / ISSUES_DIR).glob("*.md"))]
    shapes = {s for u in scores["units"] for s in u.get("services", []) if s.startswith("com.amazonaws.")}
    shapes |= {i["shape"] for i in issues if i["shape"].startswith("com.amazonaws.")}
    handlers = git(root / "repo", "ls-tree", "-r", "--name-only", "HEAD", "--", "services").splitlines()
    return build_index(scores, issues, ownership(handlers, shapes))


def verdict(entry: dict | None) -> str:
    if not entry or entry["passing_units"] == 0:
        return "reject: not-implemented" if entry and "NotImplemented" in entry["causes"] else "reject: no-evidence"
    if "CRITICAL" in entry["severities"]:
        return "warn: critical-issue"
    return "ok"


def cmd_ops(args) -> int:
    index = load_index(load_pins())
    rows = sorted((op, e) for (svc, op), e in index.items() if svc == args.service)
    if not rows:
        print(f"no operation with evidence or known issues for service {args.service!r} (the Smithy namespace, "
              "e.g. s3, iam, ec2)")
        return 1
    for op, e in rows:
        if args.grep and args.grep.lower() not in op.lower():
            continue
        print(f"{args.service}:{op:44} {verdict(e):24} pass {e['passing_units']:4}  fail {e['failing_units']:4}  "
              f"known {e['known_issues']}")
    return 0


def cmd_fetch(_args) -> int:
    pin = load_pins()
    root = ensure_data(pin)
    print(f"OK: {pin['release']} data in {root}")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("pin", help="write or compare deploy/lab-emulators.yaml")
    p.add_argument("--release", help="release tag (default: the latest; with --check, the pinned one)")
    p.add_argument("--check", action="store_true")
    p.set_defaults(func=cmd_pin)
    p = sub.add_parser("fetch", help="download the pinned scores and known issues")
    p.set_defaults(func=cmd_fetch)
    p = sub.add_parser("ops", help="operations of a service and their verdict")
    p.add_argument("service")
    p.add_argument("--grep")
    p.set_defaults(func=cmd_ops)
    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
