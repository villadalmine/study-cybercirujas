#!/usr/bin/env python3
"""Write an upgrade's pins file from live sources (#287). No model, no version typed by hand.

    scripts/upgrade_pins.py docs/upgrades/cks-1.37.yaml -o docs/upgrades/cks-1.37.pins.yaml
    scripts/upgrade_pins.py docs/upgrades/cks-1.37.yaml -o docs/upgrades/cks-1.37.pins.yaml --check

`scripts/upgrade_versions.py` rewrites the version lines a plan lists from ONE pins file. This script is the only
writer of that file. Every value comes from the spec, the repo, or a source read when it runs:

- `tracked`: the `version` of each cert's tracked syllabus the spec names (what the plan diffs; they must agree),
  `target`: the target snapshot's `version`, `shift`: the minors between them;
- `patch`: `https://dl.k8s.io/release/stable-<target>.txt`, kept only when kubeadm, kubelet and kubectl all exist at
  that version in `https://pkgs.k8s.io/core:/stable:/v<target>/deb/Packages`; otherwise the newest patch all three
  have there;
- `kindest_node`: the newest `kindest/node:v<target>.*` image the latest kind release lists (its release notes);
- `tool_sha256`: the sha256 of `scripts/upgrade_versions.py` now; `curriculum_commit`: each target PDF's commit, keyed
  by the file's exam prefix (`CKS_Curriculum v1.37.pdf` -> `CKS`);
- `date`: the day of the lookup (UTC; `--date` to reproduce one), which is what a tool edit stamps in meta.yaml;
- `live`: the URLs read, each with what it said.

--check reads the sources again and exits 1 when a pin differs from the file (`date` and the `live:` notes are not
compared): upstream moved, or the editor changed. The file is then re-written by running this without --check, never
by hand. A GitHub token in GITHUB_TOKEN, when set, is used for the kind release (the API allows 60 anonymous calls an hour).
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import sys
import urllib.request
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
TOOL = "scripts/upgrade_versions.py"
STABLE = "https://dl.k8s.io/release/stable-{target}.txt"
APT = "https://pkgs.k8s.io/core:/stable:/v{target}/deb/Packages"
KIND = "https://api.github.com/repos/kubernetes-sigs/kind/releases/latest"
PACKAGES = ("kubeadm", "kubelet", "kubectl")


def fetch(url: str) -> str:
    headers = {"User-Agent": "study-cybercirujas upgrade_pins"}
    if url.startswith("https://api.github.com/") and os.environ.get("GITHUB_TOKEN"):
        headers["Authorization"] = f"Bearer {os.environ['GITHUB_TOKEN']}"
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60) as r:
            return r.read().decode("utf-8")
    except OSError as e:                         # HTTPError, URLError, timeouts: one line, not a traceback
        raise SystemExit(f"cannot read {url}: {e}")


def _key(v: str) -> tuple[int, ...]:
    return tuple(int(x) for x in v.split("."))


def apt_versions(packages_text: str, target: str) -> dict[str, set[str]]:
    """package -> the upstream versions (1.N.P, without the -rev) it has on the target minor."""
    found: dict[str, set[str]] = {p: set() for p in PACKAGES}
    pkg = None
    for line in packages_text.splitlines():
        if line.startswith("Package:"):
            pkg = line.split(":", 1)[1].strip()
        elif line.startswith("Version:") and pkg in found:
            v = line.split(":", 1)[1].strip().split("-", 1)[0]
            if re.fullmatch(rf"{re.escape(target)}\.\d+", v):
                found[pkg].add(v)
    return found


def pick_patch(stable_text: str, packages_text: str, target: str) -> tuple[str, str]:
    """(patch, note): the stable release when apt has all three packages at it, else the newest they share."""
    stable = stable_text.strip().lstrip("v")
    if not re.fullmatch(rf"{re.escape(target)}\.\d+", stable):
        raise SystemExit(f"stable-{target}.txt says {stable_text.strip()!r}, not a {target}.P release")
    have = apt_versions(packages_text, target)
    common = set.intersection(*have.values())
    if not common:
        raise SystemExit(f"no {target}.P version has kubeadm, kubelet and kubectl in the apt repo")
    patch = stable if stable in common else max(common, key=_key)
    listed = ", ".join(sorted(common, key=_key))
    return patch, f"kubeadm, kubelet, kubectl: {listed}"


def pick_kind(release_json: str, target: str) -> tuple[str, str, str]:
    """(kindest_node tag, release tag, note) from the latest kind release's notes."""
    rel = json.loads(release_json)
    images = sorted(set(re.findall(r"kindest/node:(v\d+\.\d+\.\d+)", rel.get("body") or "")),
                    key=lambda t: _key(t[1:]))
    ours = [t for t in images if t[1:].startswith(f"{target}.")]
    if not ours:
        raise SystemExit(f"kind {rel.get('tag_name')} lists no kindest/node v{target}.* image")
    return ours[-1], rel["tag_name"], "node images " + ", ".join(t[1:] for t in reversed(images))


def build(spec_file: Path, date: str, get=fetch, root: Path = REPO) -> dict:
    spec = yaml.safe_load(spec_file.read_text(encoding="utf-8"))
    tracked, targets, commits = set(), set(), {}
    for cert, c in spec["certs"].items():
        syllabus = (root / c.get("tracked", f"certs/{cert}.md")).read_text(encoding="utf-8")
        tracked.add(str(yaml.safe_load(syllabus.split("---")[1])["version"]))
        snap = yaml.safe_load((root / c["target"]).read_text(encoding="utf-8"))
        targets.add(str(snap["version"]))
        commits[snap["source"]["path"].split("_Curriculum")[0]] = snap["source"]["commit"]
    if len(tracked) != 1 or len(targets) != 1:
        raise SystemExit(f"the spec's certs disagree: tracked {sorted(tracked)}, target {sorted(targets)}")
    tracked_v, target = tracked.pop(), targets.pop()
    shift = int(target.split(".")[1]) - int(tracked_v.split(".")[1])
    if shift < 1:
        raise SystemExit(f"target {target} is not above tracked {tracked_v}: this upgrade is already switched "
                         "(its pins file is the record of the lookup it used)")
    stable_url, apt_url = STABLE.format(target=target), APT.format(target=target)
    stable_text = get(stable_url)
    patch, apt_note = pick_patch(stable_text, get(apt_url), target)
    kind_tag, kind_rel, kind_note = pick_kind(get(KIND), target)
    return {
        "upgrade": spec_file.name.removesuffix(".yaml"),
        "date": date,
        "tracked": tracked_v,
        "target": target,
        "shift": shift,
        "patch": patch,
        "kindest_node": kind_tag,
        "tool": TOOL,
        "tool_sha256": hashlib.sha256((root / TOOL).read_bytes()).hexdigest(),
        "curriculum_commit": dict(sorted(commits.items())),
        "live": {
            "stable_txt": f"{stable_url}   # {stable_text.strip()}",
            "apt_repo": f"{apt_url}   # {apt_note}",
            "kind_release": f"https://github.com/kubernetes-sigs/kind/releases/tag/{kind_rel}   # {kind_note}",
        },
    }


HEADER = """\
# The one place the {upgrade} upgrade pins its versions. scripts/upgrade_versions.py reads only this file
# and the plan. Written by scripts/upgrade_pins.py from live sources on `date`; never edited by hand
# (`scripts/upgrade_pins.py {spec} -o {out} --check` says whether upstream moved since).
"""


def render(pins: dict, spec: str, out: str) -> str:
    live = pins["live"]
    body = {k: v for k, v in pins.items() if k != "live"}
    text = HEADER.format(upgrade=pins["upgrade"], spec=spec, out=out)
    text += yaml.safe_dump(body, sort_keys=False, default_flow_style=False, allow_unicode=True)
    text += "live:\n" + "".join(f"  {k}: {v}\n" for k, v in live.items())
    return text


def comparable(pins: dict) -> dict:
    return {k: v for k, v in pins.items() if k not in ("date", "live")}


def rel(p: Path) -> str:
    """The path as the repo names it, so the header does not depend on how the command was typed."""
    try:
        return str(p.resolve().relative_to(REPO))
    except ValueError:
        return str(p)


def main(argv: list[str] | None = None, get=fetch) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("spec", type=Path)
    ap.add_argument("-o", "--out", type=Path, required=True)
    ap.add_argument("--date", help="the lookup date to record (default: today, UTC)")
    ap.add_argument("--check", action="store_true", help="exit 1 if the sources now give other pins than the file")
    a = ap.parse_args(argv)
    date = a.date or dt.datetime.now(dt.timezone.utc).date().isoformat()
    if a.check and not a.out.is_file():
        print(f"{a.out}: missing")
        return 1
    pins = build(a.spec, date, get=get, root=REPO)    # REPO read now, not bound at import (tests point it at a fixture)
    if a.check:
        have = comparable(yaml.safe_load(a.out.read_text(encoding="utf-8")))
        want = comparable(pins)
        drift = {k: (have.get(k), want[k]) for k in want if have.get(k) != want[k]}
        for k, (old, new) in drift.items():
            print(f"{a.out}: {k}: {old!r} -> {new!r}")
        print("pins: STALE" if drift else f"pins: current ({a.out})")
        return 1 if drift else 0
    a.out.write_text(render(pins, rel(a.spec), rel(a.out)), encoding="utf-8")
    print(f"wrote {a.out}: patch {pins['patch']}, kindest/node {pins['kindest_node']}, shift {pins['shift']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
