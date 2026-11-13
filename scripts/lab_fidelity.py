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
- `reject: no-evidence`   no passing unit calls it: nothing shows the emulator behaves like AWS there;
- `reject: not-implemented` a known issue says the emulator answers NotImplemented (a scaffold stub);
- `reject: critical-issue`  a known issue of severity CRITICAL, about that one service, names it;
- `ok` otherwise. Failing units and lower-severity known issues are recorded, not hidden: `ops` prints them.

`check` (the gate over each lab, and the `fidelity:` block it records there) is the next PR of #325.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
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
    pin = live_pin(args.release)
    if args.check:
        have = load_pins()
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

def ensure_data(pin: dict) -> Path:
    """Download the pinned scores and known issues once; the sha256 and the commit are verified every time."""
    root = CACHE / EMULATOR / pin["release"]
    scores = root / "scores.json.gz"
    if not scores.exists():
        root.mkdir(parents=True, exist_ok=True)
        scores.write_bytes(fetch(pin["scores_url"]))
    if sha256(scores.read_bytes()) != pin["scores_sha256"]:
        raise SystemExit(f"{scores}: sha256 differs from the pin; delete it and run fetch again")
    repo = root / "repo"
    if not (repo / ".git").exists():
        url = f"https://github.com/{pin['repo']}.git"
        for cmd in (["git", "init", "-q", str(repo)],
                    ["git", "-C", str(repo), "remote", "add", "origin", url],
                    ["git", "-C", str(repo), "sparse-checkout", "set", "--no-cone", f"{ISSUES_DIR}/*"],
                    ["git", "-C", str(repo), "fetch", "-q", "--depth", "1", "--filter=blob:none", "origin", pin["commit"]],
                    ["git", "-C", str(repo), "checkout", "-q", "FETCH_HEAD"]):
            subprocess.run(cmd, check=True)
    head = subprocess.run(["git", "-C", str(repo), "rev-parse", "HEAD"], capture_output=True, text=True, check=True)
    if head.stdout.strip() != pin["commit"]:
        raise SystemExit(f"{repo}: at {head.stdout.strip()[:12]}, the pin says {pin['commit'][:12]}")
    return root


def namespace(shape_id: str) -> str:
    """com.amazonaws.s3#AmazonS3 -> s3 (the name `uses:` takes)."""
    return shape_id.split("#")[0].removeprefix("com.amazonaws.")


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


def issue_services(issue: dict, prefix_to_ns: dict[str, str]) -> set[str]:
    if issue["shape"]:
        return {namespace(issue["shape"])}
    return {prefix_to_ns.get(k.split("|")[0], k.split("|")[0]) for k in issue["keys"]}


def build_index(scores: dict, issues: list[dict]) -> dict:
    """{(service, Operation): {passing_units, failing_units, known_issues, severities, causes}}

    A step names an operation, not its service. A unit with one service attributes every call to it; a unit with
    several attributes a call only to the service(s) where that operation is already known (from a one-service unit
    or an Issue-Key), so `budgets:CreateRole` is not invented from a budgets+iam scenario. A known issue's severity
    counts for an operation only when the issue is about that one service (its Shape-Id, or all its keys): a
    CRITICAL "the CodeBuild chain never finishes" does not reject `iam:GetRole` because the chain calls it.
    """
    idx: dict = defaultdict(lambda: {"passing_units": 0, "failing_units": 0, "known_issues": 0,
                                     "severities": set(), "causes": set()})
    prefix_to_ns: dict[str, str] = {}
    for issue in issues:   # learn Issue-Key prefix -> namespace from the issues that carry both
        if issue["shape"]:
            for key in issue["keys"]:
                prefix_to_ns.setdefault(key.split("|")[0], namespace(issue["shape"]))
    units = []
    known: set[tuple[str, str]] = set()
    for unit in scores["units"]:
        steps = (unit.get("detail") or {}).get("steps") or []
        services = {namespace(s) for s in unit.get("services", []) if s.startswith("com.amazonaws.")}
        if not steps or not services:
            continue
        units.append((unit, steps, services))
        if len(services) == 1:
            known |= {(next(iter(services)), s["operation"]) for s in steps}
    for issue in issues:
        for key in issue["keys"]:
            parts = key.split("|")
            if len(parts) >= 2:
                known |= {(svc, parts[1]) for svc in issue_services(issue, prefix_to_ns)}
    for unit, steps, services in units:
        bad = {s["operation"] for s in steps if s["outcome"] in ("mismatch", "error")}
        for op in {s["operation"] for s in steps}:
            owners = services if len(services) == 1 else {svc for svc in services if (svc, op) in known}
            for svc in owners:
                if unit["outcome"] == "pass":
                    idx[(svc, op)]["passing_units"] += 1
                elif op in bad:
                    idx[(svc, op)]["failing_units"] += 1
    for issue in issues:
        owners = issue_services(issue, prefix_to_ns)
        named = set()
        for key in issue["keys"]:
            parts = key.split("|")
            if len(parts) < 2:
                continue
            svc = namespace(issue["shape"]) if issue["shape"] else prefix_to_ns.get(parts[0], parts[0])
            entry = idx[(svc, parts[1])]
            if (svc, parts[1]) not in named:
                named.add((svc, parts[1]))
                entry["known_issues"] += 1
                if len(owners) == 1:
                    entry["severities"].add(issue["severity"])
            if len(parts) > 2:
                entry["causes"].add(parts[2])
    return idx


def load_index(pin: dict) -> dict:
    root = ensure_data(pin)
    scores = json.loads(gzip.decompress((root / "scores.json.gz").read_bytes()))
    files = sorted((root / "repo" / ISSUES_DIR).glob("*.md"))
    return build_index(scores, [parse_issue(f.read_text(encoding="utf-8", errors="replace")) for f in files])


def verdict(entry: dict | None) -> str:
    if not entry or entry["passing_units"] == 0:
        return "reject: no-evidence"
    if "NotImplemented" in entry["causes"]:
        return "reject: not-implemented"
    if "CRITICAL" in entry["severities"]:
        return "reject: critical-issue"
    return "ok"


def cmd_ops(args) -> int:
    index = load_index(load_pins())
    rows = sorted((op, e) for (svc, op), e in index.items() if svc == args.service)
    if not rows:
        known = sorted({svc for svc, _ in index})
        print(f"no operation for service {args.service!r}; services: {' '.join(known)}")
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
    p.add_argument("--release", help="release tag (default: the latest)")
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
