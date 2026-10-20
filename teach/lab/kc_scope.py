"""Killercoda scope and status of each lab (data: deploy/killercoda/tracks.yaml).

Killercoda only has a kubeadm cluster and an Ubuntu VM, so not every lab can be on it. The rule, in two words:

- `tested`: the lab is in `required:` (an allowlist of labs, e.g. `cka/1.1`) because a batch parity run passed it.
  Its parity check is a gate: if it stops passing, CI fails, and it is the only kind that may be published to
  the Killercoda mirror (study-cybercirujas-killercoda).
- `loaded-untested`: the lab is in the repo (it runs locally with `study-lab`, and may be exported locally) but it is
  not proven on a Killercoda-like host: no reference fix, a failed run, or never run. It is never a CI failure and
  it is never pushed to the mirror (the publish gate needs a passing `tested.json` for the lab's current hash).

`scope:` lists the certifications Killercoda supports (CKA, CKAD): they are the ones the status table covers.
Any other lab that has a reference fix (lpic-2/200.1) is optional: proven and published when it can be.
The workflows read all this through `study-lab test --target killercoda --plan`, so no lab or certification is named
in workflow YAML.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path

import yaml

TESTED, UNTESTED = "tested", "loaded-untested"
_FIX_VERB = re.compile(r"^\s*fix\)", re.M)
_LAB_ID = re.compile(r"^[a-z0-9-]+/[0-9.]+$")


class ScopeError(ValueError):
    pass


@dataclass
class Scope:
    certs: list[str] = field(default_factory=list)       # certifications Killercoda supports
    required: list[str] = field(default_factory=list)    # labs that passed the batch run (the allowlist)
    failed: dict[str, str] = field(default_factory=dict)  # lab -> why it did not pass (documentation only)


def load(tracks: Path) -> Scope:
    if not tracks.is_file():
        return Scope()
    doc = yaml.safe_load(tracks.read_text(encoding="utf-8")) or {}
    certs, req, failed = doc.get("scope") or [], doc.get("required") or [], doc.get("failed") or {}
    if not isinstance(certs, list) or not all(isinstance(c, str) and c and "/" not in c for c in certs):
        raise ScopeError("tracks.yaml `scope` must be a list of certification ids (e.g. cka)")
    if not isinstance(req, list) or not all(isinstance(x, str) and _LAB_ID.match(x) for x in req):
        raise ScopeError("tracks.yaml `required` must be a list of labs like cka/1.1")
    if len(set(req)) != len(req):
        raise ScopeError("tracks.yaml `required` lists a lab twice")
    if not isinstance(failed, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in failed.items()):
        raise ScopeError("tracks.yaml `failed` must map a lab to the reason it did not pass")
    if set(failed) & set(req):
        raise ScopeError(f"tracks.yaml: a lab cannot be both required and failed: {sorted(set(failed) & set(req))}")
    return Scope(list(certs), list(req), dict(failed))


def check_known(scope: Scope, known_certs, lab_ids) -> None:
    """A typo would silently drop a lab from the gate: fail loudly instead."""
    known = set(known_certs)
    bad = [c for c in scope.certs if c not in known]
    if bad:
        raise ScopeError(f"tracks.yaml `scope` names certifications that are not in catalog.yaml: {bad}")
    labs = set(lab_ids)
    bad = [x for x in [*scope.required, *scope.failed] if x not in labs]
    if bad:
        raise ScopeError(f"tracks.yaml names labs that do not exist: {bad}")


def has_fix_verb(script_text: str) -> bool:
    """The lab script itself carries a reference fix (a `fix)` case), so it can be proven without a fixes/ file."""
    return bool(_FIX_VERB.search(script_text))


def is_required(lab_id: str, scope: Scope) -> bool:
    return lab_id in scope.required


def status(lab_id: str, scope: Scope) -> str:
    return TESTED if lab_id in scope.required else UNTESTED


def reason(lab_id: str, scope: Scope, provable: bool) -> str:
    """Why a lab is not `tested` (empty for a tested one)."""
    if lab_id in scope.required:
        return ""
    if lab_id in scope.failed:
        return scope.failed[lab_id]
    return "never run on a Killercoda-like host" if provable else "no reference fix yet"
