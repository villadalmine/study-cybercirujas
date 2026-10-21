"""Killercoda scope and per-target evidence (data: deploy/killercoda/tracks.yaml, deploy/lab-targets.yaml, deploy/lab-evidence.yaml).

Killercoda is an optional publishing channel (RFC #210), never required and never blocking. `tested` (on Killercoda): the lab
has evidence on a target that allows the Killercoda mirror (killercoda-*, human-killercoda); only such a lab is ever pushed
to the mirror. `loaded-untested`: in the repo and runnable with `study-lab`, no Killercoda proof; never a CI failure.
Evidence is per target (#103); the ids are defined once, in deploy/lab-targets.yaml, and an unknown id fails validation.
No entry for a target means "not tested there", never "does not work".
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
TARGET_KEYS = ("role", "environment", "pinned", "runner_kind", "proves", "not_proves", "publishes_to_killercoda")
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
        if d["role"] not in ("primary", "optional-channel"):
            raise ScopeError(f"lab-targets.yaml {tid}: role is primary or optional-channel")
        if d["publishes_to_killercoda"] and not tid.startswith(("killercoda-", "human-killercoda")):
            raise ScopeError(f"lab-targets.yaml {tid}: only killercoda-* and human-killercoda may allow the Killercoda mirror")
    return doc


@dataclass
class Scope:
    certs: list[str] = field(default_factory=list)           # certifications whose lab scripts are scanned for a fix verb
    failed: dict[str, str] = field(default_factory=dict)     # lab -> why it did not pass (documentation only)
    evidence: dict[str, dict] = field(default_factory=dict)  # lab -> target -> {date, lab_hash, evidence, runner}
    publishing: tuple = ()                                   # targets whose evidence allows the Killercoda mirror

    def proven_for(self, lab_id: str, lab_hash: str) -> bool:
        """The publish gate: an entry on a target that allows the mirror, for THIS lab hash, and the lab is not under `failed`."""
        mine = self.evidence.get(lab_id, {})
        return lab_id not in self.failed and any(t in mine and mine[t]["lab_hash"] == lab_hash for t in self.publishing)

    def tested(self, lab_id: str) -> bool:
        """Evidence on a Killercoda target (any hash: a changed lab is re-proven by the parity run, not unlisted)."""
        return any(t in self.evidence.get(lab_id, {}) for t in self.publishing)


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


def status(lab_id: str, scope: Scope) -> str:
    return TESTED if scope.tested(lab_id) else UNTESTED


def reason(lab_id: str, scope: Scope, provable: bool) -> str:
    """Why a lab is not `tested` (empty for a tested one)."""
    if scope.tested(lab_id):
        return ""
    if lab_id in scope.failed:
        return scope.failed[lab_id]
    return "never run on a Killercoda-like host" if provable else "no reference fix yet"


def stale_entries(scope: Scope, hash_of) -> list[tuple[str, str, str, str]]:
    """(lab, target, recorded hash, current hash) for every evidence entry recorded for a lab that has changed since.

    A stale entry is history, not a lie: it says the lab was proven as it was. It stops counting for the Killercoda gate."""
    out = []
    for lab, targets in sorted(scope.evidence.items()):
        try:
            current = hash_of(lab)
        except (OSError, ValueError, KeyError):   # the lab no longer exists
            continue
        out += [(lab, tgt, e["lab_hash"], current) for tgt, e in sorted(targets.items()) if e["lab_hash"] != current]
    return out



def main() -> int:
    """`python -m teach.lab.kc_scope`: one ::warning:: per stale evidence entry. Never fails: stale evidence must be visible, not blocking."""
    from . import kc_meta, spec
    root = Path(__file__).resolve().parents[2]
    sc = load(root / "deploy" / "killercoda" / "tracks.yaml")
    def current(lab: str) -> str:
        c, _, topic = lab.partition("/")
        try:
            return kc_meta.lab_hash(spec.load(root / "certs" / c / topic / "lab", "curated"))
        except spec.SpecError as exc:
            raise OSError(str(exc)) from exc

    stale = stale_entries(sc, current)
    for lab, tgt, old, new in stale:
        print(f"::warning title=stale lab evidence::{lab} on {tgt} was proven for lab hash {old[:8]}, the lab is now {new[:8]}: "
              + ("it does not count for the Killercoda mirror until it is re-proven or re-tested on the current lab" if tgt in sc.publishing else "re-test it"))
    print(f"{len(stale)} stale evidence entr{'y' if len(stale) == 1 else 'ies'} of {sum(len(v) for v in sc.evidence.values())}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
