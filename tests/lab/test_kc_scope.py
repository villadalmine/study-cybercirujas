"""Killercoda scope and per-target evidence: `tested` labs (evidence on a target that allows the mirror) are a gate,
everything else is `loaded-untested` and never fails CI nor reaches the mirror. Scope and targets are data."""
from __future__ import annotations

import json
import re
from pathlib import Path

import pytest
import yaml

from teach.lab import cli, kc_scope
from teach.lab import export_killercoda as kc

ROOT = Path(__file__).resolve().parents[2]
KD = ROOT / "deploy" / "killercoda"
TRACKS = KD / "tracks.yaml"
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
    assert kc_scope.FIELDS == ("date", "lab_hash", "evidence", "runner")


def test_cka_and_ckad_are_the_supported_certifications():
    assert kc_scope.load(TRACKS).certs == ["cka", "ckad"]


def test_the_data_names_only_labs_and_certifications_that_exist():
    lab_ids = [f"{d.parts[-3]}/{d.parts[-2]}" for d in ROOT.glob("certs/*/*/lab")]
    kc_scope.check_known(kc_scope.load(TRACKS), kc.cert_names(ROOT), lab_ids)


def test_every_tested_lab_has_a_way_to_be_proven():
    """A lab with Killercoda evidence and no reference fix would fail its own gate: catch it here."""
    sc = kc_scope.load(TRACKS)
    provable = {f"{c}/{t}" for c, t in cli.provable_labs(KD, sc)}
    assert {x for x in sc.evidence if sc.tested(x)} <= provable


def test_status_is_tested_only_with_killercoda_evidence():
    sc = kc_scope.Scope(["cka"], {"cka/1.2": "verify never passed"},
                        {"cka/1.1": _ev("killercoda-kubeadm"), "cka/1.3": _ev("k3s-incus", "kind")}, ("killercoda-kubeadm",))
    assert kc_scope.status("cka/1.1", sc) == kc_scope.TESTED and kc_scope.is_required("cka/1.1", sc)
    assert kc_scope.status("cka/1.2", sc) == kc_scope.UNTESTED and not kc_scope.is_required("cka/1.2", sc)
    # a pass on k3s-incus or kind proves the lab, not the Killercoda scenario: not tested THERE (never "broken")
    assert kc_scope.status("cka/1.3", sc) == kc_scope.UNTESTED and "cka/1.3" not in sc.required
    assert kc_scope.reason("cka/1.1", sc, True) == "" and kc_scope.reason("cka/1.2", sc, True) == "verify never passed"
    assert "no reference fix" in kc_scope.reason("cka/9.9", sc, False) and "never run" in kc_scope.reason("cka/9.8", sc, True)


def test_a_tested_lab_outside_the_scope_is_optional_not_required():
    sc = kc_scope.Scope(["cka"], {}, {"lpic-2/200.1": _ev("killercoda-ubuntu"), "cka/1.1": _ev("human-killercoda")},
                        ("human-killercoda", "killercoda-ubuntu"))
    assert sc.required == ["cka/1.1"] and kc_scope.status("lpic-2/200.1", sc) == kc_scope.TESTED


def test_nothing_is_tested_without_files(tmp_path):
    sc = kc_scope.load(tmp_path / "missing.yaml")
    assert sc == kc_scope.Scope() and kc_scope.status("cka/1.1", sc) == kc_scope.UNTESTED


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


def test_an_evidence_key_that_is_not_a_lab_fails(tmp_path):
    with pytest.raises(kc_scope.ScopeError, match="lab like"):
        kc_scope.load_evidence(_evfile(tmp_path, {"cka": _ev("kind")}))


def test_failed_and_tested_are_mutually_exclusive(tmp_path):
    ev = _evfile(tmp_path, {"cka/1.1": _ev("killercoda-ubuntu")})
    with pytest.raises(kc_scope.ScopeError, match="failed"):
        kc_scope.load(_tracks(tmp_path, "scope: [cka]\nfailed: {cka/1.1: x}\n"), ev)


def test_only_killercoda_targets_may_allow_the_mirror(tmp_path):
    t = {"targets": {"kind": {k: ("x" if k != "publishes_to_killercoda" else True) for k in kc_scope.TARGET_KEYS}}}
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


def test_labs_with_a_fix_verb_or_a_fix_file_are_provable():
    got = cli.provable_labs(KD, kc_scope.load(TRACKS))
    assert ("cka", "1.1") in got and ("lpic-2", "200.1") in got   # fix files
    assert ("ckad", "4.4") in got and ("ckad", "5.2") in got      # fix verb in the script
    assert ("cka", "1.2") not in got                              # nothing to prove it with: loaded-untested


def test_the_plan_marks_only_the_gated_labs_as_required(capsys):
    assert cli.main(["test", "--target", "killercoda", "--plan", "--today", "2026-10-16"]) == 0
    rows = {m["lab"]: m["required"] for m in json.loads(capsys.readouterr().out)}
    sc = kc_scope.load(TRACKS)
    assert {k for k, v in rows.items() if v} == set(sc.required) & set(rows)
    assert rows["lpic-2/200.1"] is False   # tested but outside the scope: optional


def test_publish_gate_refuses_a_scenario_without_passing_evidence_for_any_cert():
    """Untested never reaches the mirror, whatever the certification: no tested.json, no scenario."""
    labs, _ = kc.select(ROOT, ["cka"])
    gated: list = []
    files = kc.tree(labs[:3], kc.cert_names(ROOT), True, {}, {}, "2026-10-16", gated, decorate=True)
    assert len(gated) == 3 and not [k for k in files if k.startswith("cka/")]


def test_workflows_name_no_lab_they_read_the_plan():
    """The scope is data (tracks.yaml). A workflow that lists labs or certs by hand drifts from it."""
    for name in ("killercoda-parity.yml", "killercoda-publish.yml"):
        text = (ROOT / ".github" / "workflows" / name).read_text(encoding="utf-8")
        assert "--plan" in text and re.search(r"fromJSON\(needs\.[a-z-]+\.outputs\.labs\)", text), name
        assert "continue-on-error: ${{ !matrix.required }}" in text, name
        assert not re.search(r"lab:\s*'?(cka|ckad|lpic)", text), f"{name} lists a lab by hand"


def test_lpic_2_stays_in_the_default_export():
    pilot = yaml.safe_load(TRACKS.read_text(encoding="utf-8"))["pilot"]
    assert "lpic-2/200.1" in pilot and "cka/1.1" in pilot
