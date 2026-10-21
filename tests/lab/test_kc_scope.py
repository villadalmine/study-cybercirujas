"""Per-target lab evidence (#103): the targets are one fixed list, the evidence is validated against it."""
from __future__ import annotations

import pytest
import yaml

from teach.lab import kc_scope

H = "a" * 64


def _ev(*targets):
    return {t: {"date": "2026-10-21", "lab_hash": H, "evidence": "https://example.test/run/1", "runner": "ubuntu-24.04 1"}
            for t in targets}


def _tracks(tmp_path, body):
    f = tmp_path / "tracks.yaml"
    f.write_text(body, encoding="utf-8")
    return f


def _evfile(tmp_path, doc):
    f = tmp_path / "lab-evidence.yaml"
    f.write_text(yaml.safe_dump(doc), encoding="utf-8")
    return f


def test_the_standard_targets_are_fixed():
    """Other agents record proofs with these ids. Changing this list is a decision, not a typo."""
    t = kc_scope.load_targets()
    assert list(t) == ["kind", "k3s-incus", "docker-linux", "killercoda-kubeadm", "killercoda-ubuntu", "human-killercoda"]
    assert {k for k, v in t.items() if v["publishes_to_killercoda"]} == {"killercoda-kubeadm", "killercoda-ubuntu", "human-killercoda"}
    assert {k for k, v in t.items() if v["role"] == "primary"} == {"kind", "k3s-incus", "docker-linux"}   # our infra proves; Killercoda only publishes
    assert kc_scope.FIELDS == ("date", "lab_hash", "evidence", "runner")


def test_status_is_tested_only_with_killercoda_evidence():
    sc = kc_scope.Scope(["cka"], {"cka/1.2": "verify never passed"},
                        {"cka/1.1": _ev("killercoda-kubeadm"), "cka/1.3": _ev("k3s-incus", "kind")}, ("killercoda-kubeadm",))
    assert kc_scope.status("cka/1.1", sc) == kc_scope.TESTED
    assert kc_scope.status("cka/1.2", sc) == kc_scope.UNTESTED
    # a pass on k3s-incus or kind proves the lab, not the Killercoda scenario: not tested THERE (never "broken")
    assert kc_scope.status("cka/1.3", sc) == kc_scope.UNTESTED
    assert kc_scope.reason("cka/1.1", sc, True) == "" and kc_scope.reason("cka/1.2", sc, True) == "verify never passed"
    assert "no reference fix" in kc_scope.reason("cka/9.9", sc, False) and "never run" in kc_scope.reason("cka/9.8", sc, True)


@pytest.mark.parametrize("body", ["scope: [cka/1.1]\n", "scope: cka\n", "failed: [a]\n"])
def test_a_malformed_tracks_file_fails_loudly(tmp_path, body):
    with pytest.raises(kc_scope.ScopeError):
        kc_scope.load(_tracks(tmp_path, body), _evfile(tmp_path, {}))


@pytest.mark.parametrize("mutate", [
    lambda e: {"kindd": e["kind"]},                              # unknown target id
    lambda e: {"kind": {**e["kind"], "date": "yesterday"}},
    lambda e: {"kind": {**e["kind"], "lab_hash": "abc"}},
    lambda e: {"kind": {k: v for k, v in e["kind"].items() if k != "runner"}},   # missing field
    lambda e: {"kind": {**e["kind"], "extra": 1}},               # unknown field
    lambda e: {"kind": {**e["kind"], "evidence": " "}},
])
def test_a_malformed_evidence_entry_fails_loudly(tmp_path, mutate):
    with pytest.raises(kc_scope.ScopeError):
        kc_scope.load_evidence(_evfile(tmp_path, {"cka/1.1": mutate(_ev("kind"))}))



def test_failed_and_tested_are_mutually_exclusive(tmp_path):
    ev = _evfile(tmp_path, {"cka/1.1": _ev("killercoda-ubuntu")})
    with pytest.raises(kc_scope.ScopeError, match="failed"):
        kc_scope.load(_tracks(tmp_path, "scope: [cka]\nfailed: {cka/1.1: x}\n"), ev)


def test_only_killercoda_targets_may_allow_the_mirror(tmp_path):
    t = {"targets": {"kind": {k: ("primary" if k == "role" else True if k == "publishes_to_killercoda" else "x") for k in kc_scope.TARGET_KEYS}}}
    f = tmp_path / "targets.yaml"
    f.write_text(yaml.safe_dump(t), encoding="utf-8")
    with pytest.raises(kc_scope.ScopeError, match="only killercoda"):
        kc_scope.load_targets(f)


def test_a_typo_fails_instead_of_dropping_a_lab_from_the_gate():
    with pytest.raises(kc_scope.ScopeError, match="not in catalog.yaml"):
        kc_scope.check_known(kc_scope.Scope(["cka", "ckda"]), ["cka", "ckad"], ["cka/1.1"])
    with pytest.raises(kc_scope.ScopeError, match="do not exist"):
        kc_scope.check_known(kc_scope.Scope(["cka"], {}, {"cka/7.7": _ev("kind")}), ["cka"], ["cka/1.1"])


def test_fix_verb_detection():
    assert kc_scope.has_fix_verb('case "$1" in\n  verify) v ;;\n  fix)    fix_lab ;;\nesac\n')
    assert not kc_scope.has_fix_verb("# fix) in a comment\nverify) v ;;\n")


def test_the_committed_evidence_file_is_valid():
    """The real file, not a fixture: an unknown target id or a malformed entry fails CI."""
    ev = kc_scope.load_evidence(kc_scope.EVIDENCE_FILE)
    assert ev and all(set(e) == set(kc_scope.FIELDS) for tgts in ev.values() for e in tgts.values())


def test_proven_for_needs_the_current_hash_and_a_publishing_target():
    sc = kc_scope.Scope(["cka"], {"cka/1.3": "failed"},
                        {"cka/1.1": _ev("killercoda-kubeadm", "kind"), "cka/1.2": _ev("kind"), "cka/1.3": _ev("killercoda-kubeadm")},
                        ("killercoda-kubeadm",))
    assert sc.proven_for("cka/1.1", H)
    assert not sc.proven_for("cka/1.1", "b" * 64)     # the lab changed since the proof
    assert not sc.proven_for("cka/1.2", H)            # only kind: not Killercoda evidence
    assert not sc.proven_for("cka/1.3", H)            # listed under failed
    assert not sc.proven_for("cka/9.9", H)            # no entry


def test_stale_evidence_is_listed_never_silent():
    sc = kc_scope.Scope(["cka"], {}, {"cka/1.1": _ev("killercoda-kubeadm", "human-killercoda"), "cka/1.2": _ev("kind")}, ("killercoda-kubeadm",))
    now = {"cka/1.1": H, "cka/1.2": "c" * 64}
    stale = kc_scope.stale_entries(sc, lambda lab: now[lab])
    assert stale == [("cka/1.2", "kind", H, "c" * 64)]
    gone = kc_scope.stale_entries(sc, lambda lab: (_ for _ in ()).throw(OSError("no lab")))
    assert gone == []   # a lab that no longer exists is not reported as stale


def test_the_stale_report_runs_on_the_real_repo_and_never_fails(capsys):
    assert kc_scope.main() == 0
    assert "stale evidence entr" in capsys.readouterr().out
