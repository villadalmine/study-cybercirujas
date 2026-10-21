#!/usr/bin/env python3
"""Apply a Kubernetes version bump to exactly the lines an upgrade plan lists (#51, #63). No model, no network.

    scripts/upgrade_versions.py PLAN PINS --scope material|labs [--cert cka] [--check]

The plan (scripts/curriculum_diff.py plan) lists every file:line that names the tracked version. This rewrites
only those lines and nothing else, from the one pins file:

- a version token 1.N, v1.N, 1.N.P, 1.N.x with N in {tracked-shift .. tracked} moves up by shift minors, so a
  sample upgrade "1.34 -> 1.35" becomes "1.36 -> 1.37" and still skips nothing;
- a target-minor patch of 1 or more becomes the pinned patch; .0 and .x stay (a sample keeps its shape);
- "kindest/node v1.35.8" becomes the pinned kindest/node tag; nothing else in the output of a command is invented;
- a line already naming the target minor is skipped, so a second run changes nothing; so is a companion line
  ("Cluster version: v1.34.1", where a sample upgrade starts from) once it shows a minor above the tracked one;
- an unexpected shape (a target-minor patch other than 0, 1 or x) stops the run: nothing is guessed;
- a `cncf/curriculum/raw/master/..._v1.35.pdf` link becomes the v1.37 PDF pinned by commit (pins `curriculum_commit`);
- lab.yaml's `verified:` block is never rewritten: it records a proof on its date, and the 1.37 proofs are new evidence.

A material file whose lines moved gets a tool_edit block in the meta.yaml next to it (tool, script sha256, plan
and pins sha256, the pins date), which is what curriculum_diff.py guard accepts in place of a model's effort and
prompt hash. --check prints what would change and exits 1 if anything would.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
TOKEN = re.compile(r"(?<![\d.])(v?)1\.(\d{2})(?:\.(\d+|x))?(?!\d)")
KINDEST = re.compile(r"kindest/node v1\.\d+\.\d+")
CURRICULUM = re.compile(r"(https://github\.com/cncf/curriculum)/raw/master/(CKAD?)_Curriculum_v1\.35\.pdf")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def rewrite(line: str, pins: dict) -> str:
    """The line with its version tokens moved, or unchanged when it already names the target."""
    tracked, target, shift = pins["tracked"], pins["target"], int(pins["shift"])
    t_minor = int(tracked.split(".")[1])
    minors = [int(m.group(2)) for m in TOKEN.finditer(line)]
    if re.search(rf"(?<![\d.])v?{re.escape(target)}(?!\d)", line):
        return line                              # already on the target
    if t_minor not in minors and (not t_minor - 1 in minors or any(m > t_minor for m in minors)):
        # A companion line ("Cluster version: v1.34.1", the version a sample upgrade starts from) moves only
        # while it still shows the minor below the tracked one; once moved it shows a minor above it.
        return line
    line = KINDEST.sub(f"kindest/node {pins['kindest_node']}", line)
    line = CURRICULUM.sub(lambda m: f"{m.group(1)}/raw/{pins['curriculum_commit'][m.group(2)]}/{m.group(2)}_Curriculum_v{target}.pdf",
                          line)

    def move(m: re.Match) -> str:
        v, minor, patch = m.group(1), int(m.group(2)), m.group(3)
        if not t_minor - shift <= minor <= t_minor:
            return m.group(0)
        out = f"{v}1.{minor + shift}"
        if patch is None:
            return out
        if minor == t_minor and patch not in ("0", "x"):
            if patch != "1":
                raise SystemExit(f"unexpected patch .{patch} on the tracked minor: {line.strip()!r}")
            patch = pins["patch"].rsplit(".", 1)[1]
        return f"{out}.{patch}"

    return TOKEN.sub(move, line)


def in_scope(rel: str, scope: str, cert: str | None) -> bool:
    parts = rel.split("/")
    if cert and parts[1] != cert:
        return False
    is_lab = len(parts) > 3 and parts[3] == "lab"
    return is_lab if scope == "labs" else not is_lab


def evidence_lines(text: str) -> set[int]:
    """Line numbers inside lab.yaml's `verified:` block: the record of a proof that happened on its date, with
    the node it ran on. A version bump never rewrites it; the 1.37 proofs are new evidence, not an edit."""
    out, inside = set(), False
    for n, line in enumerate(text.splitlines(), 1):
        if line and not line[0].isspace():
            inside = line.startswith("verified:")
        if inside:
            out.add(n)
    return out


def stamp(meta_text: str, block: str) -> str:
    """meta.yaml text with its tool_edit block replaced (or appended): a top-level key and its indented lines."""
    out, skipping = [], False
    for line in meta_text.splitlines():
        if line.startswith("tool_edit:"):
            skipping = True
            continue
        if skipping and (line.startswith(" ") or not line.strip()):
            continue
        skipping = False
        out.append(line)
    return "\n".join(out).rstrip("\n") + "\n" + block


def run(plan_file: Path, pins_file: Path, scope: str, cert: str | None, check: bool, root: Path = REPO) -> int:
    plan = json.loads(plan_file.read_text(encoding="utf-8"))
    pins = yaml.safe_load(pins_file.read_text(encoding="utf-8"))
    by_file: dict[str, set[int]] = {}
    for c in plan["certs"].values():
        for t in c["topics"]:
            if t["class"] in ("keep", "revalidate"):
                for ref in t["version_lines"]["technical"]:
                    f, n = ref.rsplit(":", 1)
                    if in_scope(f, scope, cert):
                        by_file.setdefault(f, set()).add(int(n))
    changed, dirs = {}, set()
    for f, numbers in sorted(by_file.items()):
        text = (root / f).read_text(encoding="utf-8")
        lines = text.splitlines(keepends=True)
        skip = evidence_lines(text) if f.endswith("/lab.yaml") else set()
        for n in sorted(numbers - skip):
            body = lines[n - 1].rstrip("\r\n")
            new = rewrite(body, pins)
            if new != body:
                lines[n - 1] = new + lines[n - 1][len(body):]
                changed[f] = changed.get(f, 0) + 1
        if f in changed:
            if not check:
                (root / f).write_text("".join(lines), encoding="utf-8", newline="")
            parts = f.split("/")
            if len(parts) > 3 and parts[3] != "lab":
                dirs.add("/".join(parts[:4]))
    block = (f"tool_edit:\n  tool: scripts/upgrade_versions.py\n  script_sha256: {sha256(Path(__file__))}\n"
             f"  plan: {plan_file.resolve().relative_to(root).as_posix()}\n  plan_sha256: {sha256(plan_file)}\n"
             f"  pins_sha256: {sha256(pins_file)}\n  date: '{pins['date']}'\n")
    for d in sorted(dirs):
        meta = root / d / "meta.yaml"
        old = meta.read_text(encoding="utf-8")
        new = stamp(old, block)
        if new != old and not check:
            meta.write_text(new, encoding="utf-8", newline="")
    print(f"{sum(changed.values())} line(s) in {len(changed)} file(s), {len(dirs)} meta.yaml stamped"
          + (" (check: nothing written)" if check else ""))
    return 1 if check and changed else 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("plan", type=Path)
    ap.add_argument("pins", type=Path)
    ap.add_argument("--scope", choices=("material", "labs"), required=True)
    ap.add_argument("--cert")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args(argv)
    return run(a.plan.resolve(), a.pins.resolve(), a.scope, a.cert, a.check)


if __name__ == "__main__":
    sys.exit(main())
