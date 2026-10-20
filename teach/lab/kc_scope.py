"""Killercoda scope and per-target evidence of each lab (data: deploy/killercoda/tracks.yaml, deploy/lab-targets.yaml,
deploy/lab-evidence.yaml).

Killercoda only has a kubeadm cluster and an Ubuntu VM, so not every lab can be on it. The rule:

- `tested`: deploy/lab-evidence.yaml has an entry for the lab on a target that allows publishing to the Killercoda mirror
  (`killercoda-*`, `human-killercoda`). If the lab's certification is in `scope` (CKA, CKAD) its parity check is a gate:
  CI fails when it stops passing. Only a tested lab may be pushed to the mirror (study-cybercirujas-killercoda), and the
  publish gate also needs a passing tested.json for the lab's current hash.
- `loaded-untested`: the lab is in the repo (it runs locally with `study-lab`, and may be exported locally) but has no
  Killercoda evidence: no reference fix, a failed run, or never run. It is never a CI failure and never reaches the mirror.

Evidence is per TARGET (issue #103): a lab is agnostic, and each proof says where it ran. The targets are defined once,
in deploy/lab-targets.yaml; an unknown id fails validation. No entry for a target means "not tested there", never "does
not work", and a pass on kind or k3s-incus proves the lab, not the Killercoda scenario.

`scope:` lists the certifications Killercoda supports. Any other lab with a reference fix (lpic-2/200.1) is optional:
proven and published when it can be. The workflows read all this through `study-lab test --target killercoda --plan`,
so no lab or certification is named in workflow YAML.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path

import yaml

TESTED, UNTESTED = "tested", "loaded-untested"
DEPLOY = Path(__file__).resolve().parents[2] / "deploy"
TARGETS_FILE = DEPLOY / "lab-targets.yaml"     # the ONE definition of the evidence targets
EVIDENCE_FILE = DEPLOY / "lab-evidence.yaml"   # lab -> target -> proof
FIELDS = ("date", "lab_hash", "evidence", "runner")
TARGET_KEYS = ("environment", "pinned", "runner_kind", "proves", "not_proves", "publishes_to_killercoda")
_FIX_VERB = re.compile(r"^\s*fix\)", re.M)
_LAB_ID = re.compile(r"^[a-z0-9-]+/[0-9.]+$")
_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
_SHA = re.compile(r"^[0-9a-f]{64}$")


class ScopeError(ValueError):
    pass


def load_targets(path: Path = TARGETS_FILE) -> dict[str, dict]:
    doc = (yaml.safe_load(path.read_text(encoding="utf-8")) or {}).get("targets") or {}
    for tid, d in doc.items():
        if not isinstance(d, dict) or set(d) != set(TARGET_KEYS) or not isinstance(d["publishes_to_killercoda"], bool):
            raise ScopeError(f"lab-targets.yaml {tid}: exactly the keys {', '.join(TARGET_KEYS)} (the last one a bool)")
        if d["publishes_to_killercoda"] and not tid.startswith(("killercoda-", "human-killercoda")):
            raise ScopeError(f"lab-targets.yaml {tid}: only killercoda-* and human-killercoda may allow the Killercoda mirror")
    return doc


@dataclass
class Scope:
    certs: list[str] = field(default_factory=list)           # certifications Killercoda supports
    failed: dict[str, str] = field(default_factory=dict)     # lab -> why it did not pass (documentation only)
    evidence: dict[str, dict] = field(default_factory=dict)  # lab -> target -> {date, lab_hash, evidence, runner}
    publishing: tuple = ()                                   # targets whose evidence allows the Killercoda mirror

    def tested(self, lab_id: str) -> bool:
        """Evidence on a Killercoda target (any hash: a changed lab is re-proven by the parity run, not unlisted)."""
        return any(t in self.evidence.get(lab_id, {}) for t in self.publishing)

    @property
    def required(self) -> list[str]:
        """The gate: tested labs of a certification in scope. A tested lab outside the scope (lpic-2) is optional."""
        return sorted(x for x in self.evidence if self.tested(x) and x.partition("/")[0] in self.certs)


def load(tracks: Path, evidence: Path | None = None, targets: Path | None = None) -> Scope:
    if not tracks.is_file():
        return Scope()
    doc = yaml.safe_load(tracks.read_text(encoding="utf-8")) or {}
    certs, failed = doc.get("scope") or [], doc.get("failed") or {}
    if not isinstance(certs, list) or not all(isinstance(c, str) and c and "/" not in c for c in certs):
        raise ScopeError("tracks.yaml `scope` must be a list of certification ids (e.g. cka)")
    if not isinstance(failed, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in failed.items()):
        raise ScopeError("tracks.yaml `failed` must map a lab to the reason it did not pass")
    tg = load_targets(targets or TARGETS_FILE)
    ev = load_evidence(evidence or EVIDENCE_FILE, tg)
    pub = tuple(sorted(t for t, d in tg.items() if d["publishes_to_killercoda"]))
    if set(failed) & {x for x in ev if any(t in ev[x] for t in pub)}:
        raise ScopeError("tracks.yaml `failed` lists a lab that has Killercoda evidence")
    return Scope(list(certs), dict(failed), ev, pub)


def load_evidence(path: Path, targets: dict[str, dict] | None = None) -> dict[str, dict]:
    """lab-evidence.yaml: {lab: {target: {date, lab_hash, evidence, runner}}}; a target id must exist in lab-targets.yaml."""
    targets = load_targets() if targets is None else targets
    if not path.is_file():
        return {}
    doc = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    if not isinstance(doc, dict):
        raise ScopeError("lab-evidence.yaml must map a lab to its targets")
    for lab, tgts in doc.items():
        if not _LAB_ID.match(str(lab)) or not isinstance(tgts, dict):
            raise ScopeError(f"lab-evidence.yaml: {lab!r} must be a lab like cka/1.1 with a mapping of targets")
        for tgt, e in tgts.items():
            if tgt not in targets:
                raise ScopeError(f"lab-evidence.yaml {lab}: unknown target {tgt!r}, use one of {', '.join(targets)} "
                                 "(defined in deploy/lab-targets.yaml)")
            if not isinstance(e, dict) or set(e) != set(FIELDS):
                raise ScopeError(f"lab-evidence.yaml {lab} {tgt}: exactly the keys {', '.join(FIELDS)}")
            if (not _DATE.match(str(e["date"])) or not _SHA.match(str(e["lab_hash"]))
                    or not str(e["evidence"]).strip() or not str(e["runner"]).strip()):
                raise ScopeError(f"lab-evidence.yaml {lab} {tgt}: date YYYY-MM-DD, lab_hash sha256, "
                                 "evidence (run link or log sha256), runner (with its version)")
    return {str(k): {t: {**e, "date": str(e["date"])} for t, e in v.items()} for k, v in doc.items()}


def check_known(scope: Scope, known_certs, lab_ids) -> None:
    """A typo would silently drop a lab from the gate: fail loudly instead."""
    known = set(known_certs)
    bad = [c for c in scope.certs if c not in known]
    if bad:
        raise ScopeError(f"tracks.yaml `scope` names certifications that are not in catalog.yaml: {bad}")
    labs = set(lab_ids)
    bad = [x for x in [*scope.evidence, *scope.failed] if x not in labs]
    if bad:
        raise ScopeError(f"tracks.yaml / lab-evidence.yaml name labs that do not exist: {bad}")


def has_fix_verb(script_text: str) -> bool:
    """The lab script itself carries a reference fix (a `fix)` case), so it can be proven without a fixes/ file."""
    return bool(_FIX_VERB.search(script_text))


def is_required(lab_id: str, scope: Scope) -> bool:
    return lab_id in scope.required


def status(lab_id: str, scope: Scope) -> str:
    return TESTED if scope.tested(lab_id) else UNTESTED


def reason(lab_id: str, scope: Scope, provable: bool) -> str:
    """Why a lab is not `tested` (empty for a tested one)."""
    if scope.tested(lab_id):
        return ""
    if lab_id in scope.failed:
        return scope.failed[lab_id]
    return "never run on a Killercoda-like host" if provable else "no reference fix yet"
